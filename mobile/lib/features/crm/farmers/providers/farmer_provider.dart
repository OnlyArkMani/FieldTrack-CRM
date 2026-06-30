import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/network/api_exceptions.dart';
import '../data/farmer_repository.dart';
import '../models/farmer.dart';

/// Immutable list state. Separate flags let the UI tell first-load shimmer from
/// append-spinner from pull-to-refresh.
class FarmerListState {
  const FarmerListState({
    this.items = const [],
    this.isLoading = false,
    this.isLoadingMore = false,
    this.isRefreshing = false,
    this.error,
    this.nextCursor,
    this.hasMore = false,
    this.total = 0,
    this.search = '',
    this.leadFilter,
  });

  final List<FarmerListItem> items;
  final bool isLoading;
  final bool isLoadingMore;
  final bool isRefreshing;
  final String? error;
  final String? nextCursor;
  final bool hasMore;
  final int total;
  final String search;
  final LeadStatus? leadFilter;

  bool get isEmpty => items.isEmpty && !isLoading && error == null;

  FarmerListState copyWith({
    List<FarmerListItem>? items,
    bool? isLoading,
    bool? isLoadingMore,
    bool? isRefreshing,
    String? error,
    bool clearError = false,
    String? nextCursor,
    bool clearCursor = false,
    bool? hasMore,
    int? total,
    String? search,
    LeadStatus? leadFilter,
    bool clearLeadFilter = false,
  }) =>
      FarmerListState(
        items: items ?? this.items,
        isLoading: isLoading ?? this.isLoading,
        isLoadingMore: isLoadingMore ?? this.isLoadingMore,
        isRefreshing: isRefreshing ?? this.isRefreshing,
        error: clearError ? null : (error ?? this.error),
        nextCursor: clearCursor ? null : (nextCursor ?? this.nextCursor),
        hasMore: hasMore ?? this.hasMore,
        total: total ?? this.total,
        search: search ?? this.search,
        leadFilter: clearLeadFilter ? null : (leadFilter ?? this.leadFilter),
      );
}

/// Owns pagination + debounced search + lead-status filter. Search is debounced
/// HERE (300ms); the screen just calls setSearch on every keystroke.
class FarmerListNotifier extends Notifier<FarmerListState> {
  Timer? _debounce;
  int _seq = 0; // guards against out-of-order responses

  @override
  FarmerListState build() {
    ref.onDispose(() => _debounce?.cancel());
    Future.microtask(refresh);
    return const FarmerListState(isLoading: true);
  }

  FarmerRepository get _repo => ref.read(farmerRepositoryProvider);

  Future<void> refresh({bool isRefresh = false}) async {
    final seq = ++_seq;
    state = state.copyWith(
      isLoading: !isRefresh && state.items.isEmpty,
      isRefreshing: isRefresh,
      clearError: true,
    );
    try {
      final page = await _repo.list(
        limit: 20,
        search: state.search,
        leadStatus: state.leadFilter,
      );
      if (seq != _seq) return;
      state = state.copyWith(
        items: page.items,
        isLoading: false,
        isRefreshing: false,
        nextCursor: page.nextCursor,
        clearCursor: page.nextCursor == null,
        hasMore: page.hasMore,
        total: page.total,
      );
    } on ApiException catch (e) {
      if (seq != _seq) return;
      state = state.copyWith(
        isLoading: false,
        isRefreshing: false,
        error: e.message,
      );
    }
  }

  Future<void> loadMore() async {
    if (!state.hasMore || state.isLoadingMore || state.nextCursor == null) {
      return;
    }
    final seq = ++_seq;
    state = state.copyWith(isLoadingMore: true, clearError: true);
    try {
      final page = await _repo.list(
        cursor: state.nextCursor,
        limit: 20,
        search: state.search,
        leadStatus: state.leadFilter,
      );
      if (seq != _seq) return;
      state = state.copyWith(
        items: [...state.items, ...page.items],
        isLoadingMore: false,
        nextCursor: page.nextCursor,
        clearCursor: page.nextCursor == null,
        hasMore: page.hasMore,
        total: page.total,
      );
    } on ApiException catch (e) {
      if (seq != _seq) return;
      state = state.copyWith(isLoadingMore: false, error: e.message);
    }
  }

  void setSearch(String value) {
    state = state.copyWith(search: value);
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), refresh);
  }

  void setLeadFilter(LeadStatus? status) {
    state = status == null
        ? state.copyWith(clearLeadFilter: true)
        : state.copyWith(leadFilter: status);
    refresh();
  }
}

final farmerListProvider =
    NotifierProvider<FarmerListNotifier, FarmerListState>(
        FarmerListNotifier.new);

/// Single farmer full profile. AsyncNotifier gives loading/error/data for free;
/// `updateLeadStatus` mutates then reloads so the profile card reflects the new
/// status immediately.
class FarmerDetailNotifier extends FamilyAsyncNotifier<FarmerDetail, int> {
  FarmerRepository get _repo => ref.read(farmerRepositoryProvider);

  @override
  Future<FarmerDetail> build(int farmerId) => _repo.detail(farmerId);

  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(() => _repo.detail(arg));
  }

  Future<void> updateLeadStatus({
    required LeadStatus status,
    required String reason,
  }) async {
    await _repo.updateLeadStatus(arg, status: status, reason: reason);
    await refresh();
    // Lead change is visible on the list (current status column) — refresh it.
    ref.invalidate(leadHistoryProvider(arg));
    ref.read(farmerListProvider.notifier).refresh(isRefresh: true);
  }
}

final farmerDetailProvider =
    AsyncNotifierProvider.family<FarmerDetailNotifier, FarmerDetail, int>(
        FarmerDetailNotifier.new);

/// Full livestock history (newest first) for the dedicated history screen.
final livestockHistoryProvider =
    FutureProvider.family<List<LivestockProfile>, int>((ref, id) async {
  return ref.watch(farmerRepositoryProvider).livestockHistory(id);
});

/// Full lead status-change history.
final leadHistoryProvider =
    FutureProvider.family<List<LeadHistoryItem>, int>((ref, id) async {
  return ref.watch(farmerRepositoryProvider).leadHistory(id);
});

/// First page of full visit history (for the "View all visits" screen).
final farmerVisitsProvider =
    FutureProvider.family<List<VisitSummary>, int>((ref, id) async {
  final page = await ref.watch(farmerRepositoryProvider).visitList(id, limit: 50);
  return page.items;
});
