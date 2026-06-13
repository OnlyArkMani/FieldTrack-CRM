import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_exceptions.dart';
import '../data/notification_repository.dart';
import '../models/app_notification.dart';

/// Lightweight unread badge source for the bell. autoDispose so it refetches
/// when the bell re-mounts; the list notifier invalidates it after any
/// read/dismiss so the badge and list never drift.
final unreadCountProvider = FutureProvider.autoDispose<int>((ref) async {
  return ref.watch(notificationRepositoryProvider).unreadCount();
});

class NotificationsState {
  const NotificationsState({
    this.items = const [],
    this.isLoading = true,
    this.isLoadingMore = false,
    this.error,
    this.hasMore = false,
    this.nextCursor,
  });

  final List<AppNotification> items;
  final bool isLoading;
  final bool isLoadingMore;
  final String? error;
  final bool hasMore;
  final String? nextCursor;

  int get unread => items.where((n) => !n.isRead).length;

  NotificationsState copyWith({
    List<AppNotification>? items,
    bool? isLoading,
    bool? isLoadingMore,
    String? error,
    bool clearError = false,
    bool? hasMore,
    String? nextCursor,
    bool clearCursor = false,
  }) =>
      NotificationsState(
        items: items ?? this.items,
        isLoading: isLoading ?? this.isLoading,
        isLoadingMore: isLoadingMore ?? this.isLoadingMore,
        error: clearError ? null : (error ?? this.error),
        hasMore: hasMore ?? this.hasMore,
        nextCursor: clearCursor ? null : (nextCursor ?? this.nextCursor),
      );
}

class NotificationsNotifier extends Notifier<NotificationsState> {
  @override
  NotificationsState build() {
    Future.microtask(load);
    return const NotificationsState();
  }

  NotificationRepository get _repo => ref.read(notificationRepositoryProvider);

  Future<void> load({bool silent = false}) async {
    if (!silent) state = state.copyWith(isLoading: true, clearError: true);
    try {
      final page = await _repo.list();
      state = state.copyWith(
        items: page.items,
        isLoading: false,
        hasMore: page.hasMore,
        nextCursor: page.nextCursor,
        clearError: true,
        clearCursor: !page.hasMore,
      );
    } on ApiException catch (e) {
      state = state.copyWith(isLoading: false, error: e.message);
    }
  }

  Future<void> loadMore() async {
    if (state.isLoadingMore || !state.hasMore || state.nextCursor == null) {
      return;
    }
    state = state.copyWith(isLoadingMore: true);
    try {
      final page = await _repo.list(cursor: state.nextCursor);
      state = state.copyWith(
        items: [...state.items, ...page.items],
        isLoadingMore: false,
        hasMore: page.hasMore,
        nextCursor: page.nextCursor,
        clearCursor: !page.hasMore,
      );
    } on ApiException {
      state = state.copyWith(isLoadingMore: false);
    }
  }

  /// Optimistically mark one read, then reconcile with the server. A failure
  /// silently rolls the row back (the next load() corrects any drift).
  Future<void> markRead(int id) async {
    final idx = state.items.indexWhere((n) => n.id == id);
    if (idx < 0 || state.items[idx].isRead) return;
    final updated = [...state.items];
    updated[idx] = updated[idx].copyWith(isRead: true);
    state = state.copyWith(items: updated);
    try {
      await _repo.markRead(id);
      ref.invalidate(unreadCountProvider);
    } on ApiException {
      final rollback = [...state.items];
      final j = rollback.indexWhere((n) => n.id == id);
      if (j >= 0) rollback[j] = rollback[j].copyWith(isRead: false);
      state = state.copyWith(items: rollback);
    }
  }

  Future<void> markAllRead() async {
    if (state.unread == 0) return;
    final snapshot = state.items;
    state = state.copyWith(
      items: [for (final n in snapshot) n.copyWith(isRead: true)],
    );
    try {
      await _repo.markAllRead();
      ref.invalidate(unreadCountProvider);
    } on ApiException {
      state = state.copyWith(items: snapshot);
    }
  }

  /// Swipe-to-dismiss: drop the row locally and mark it read server-side (no
  /// hard delete on the backend — read state is enough to clear the badge).
  Future<void> dismiss(int id) async {
    final removed = state.items.firstWhere((n) => n.id == id);
    state = state.copyWith(items: state.items.where((n) => n.id != id).toList());
    if (!removed.isRead) {
      try {
        await _repo.markRead(id);
        ref.invalidate(unreadCountProvider);
      } on ApiException {
        // best-effort; the next load() re-syncs.
      }
    }
  }
}

final notificationsProvider =
    NotifierProvider<NotificationsNotifier, NotificationsState>(
        NotificationsNotifier.new);
