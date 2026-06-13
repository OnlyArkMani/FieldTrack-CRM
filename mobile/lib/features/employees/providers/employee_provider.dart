import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_exceptions.dart';
import '../data/employee_repository.dart';
import '../models/employee.dart';

/// Immutable list state. `items` is the loaded page(s); separate flags let the
/// UI distinguish first-load shimmer from append-spinner from refresh.
class EmployeeListState {
  const EmployeeListState({
    this.items = const [],
    this.isLoading = false,
    this.isLoadingMore = false,
    this.isRefreshing = false,
    this.error,
    this.nextCursor,
    this.hasMore = false,
    this.total = 0,
    this.search = '',
    this.teamId,
  });

  final List<Employee> items;
  final bool isLoading; // first load (no items yet)
  final bool isLoadingMore; // appending next page
  final bool isRefreshing; // pull-to-refresh over existing items
  final String? error;
  final String? nextCursor;
  final bool hasMore;
  final int total;
  final String search;
  final int? teamId;

  bool get isEmpty => items.isEmpty && !isLoading && error == null;

  EmployeeListState copyWith({
    List<Employee>? items,
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
    int? teamId,
    bool clearTeam = false,
  }) =>
      EmployeeListState(
        items: items ?? this.items,
        isLoading: isLoading ?? this.isLoading,
        isLoadingMore: isLoadingMore ?? this.isLoadingMore,
        isRefreshing: isRefreshing ?? this.isRefreshing,
        error: clearError ? null : (error ?? this.error),
        nextCursor: clearCursor ? null : (nextCursor ?? this.nextCursor),
        hasMore: hasMore ?? this.hasMore,
        total: total ?? this.total,
        search: search ?? this.search,
        teamId: clearTeam ? null : (teamId ?? this.teamId),
      );
}

/// Owns pagination + debounced search. Search is debounced HERE (300ms) so the
/// screen just calls setSearch on every keystroke and the notifier coalesces.
class EmployeeNotifier extends Notifier<EmployeeListState> {
  Timer? _debounce;
  int _requestSeq = 0; // guards against out-of-order responses

  @override
  EmployeeListState build() {
    ref.onDispose(() => _debounce?.cancel());
    // Kick off the first load after construction.
    Future.microtask(refresh);
    return const EmployeeListState(isLoading: true);
  }

  EmployeeRepository get _repo => ref.read(employeeRepositoryProvider);

  /// First page / full reload. `isRefresh` keeps existing items visible under
  /// the pull-to-refresh spinner instead of flashing shimmer.
  Future<void> refresh({bool isRefresh = false}) async {
    final seq = ++_requestSeq;
    state = state.copyWith(
      isLoading: !isRefresh && state.items.isEmpty,
      isRefreshing: isRefresh,
      clearError: true,
    );
    try {
      final page = await _repo.list(
        limit: 20,
        teamId: state.teamId,
        search: state.search,
      );
      if (seq != _requestSeq) return; // a newer request superseded this one
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
      if (seq != _requestSeq) return;
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
    final seq = ++_requestSeq;
    state = state.copyWith(isLoadingMore: true, clearError: true);
    try {
      final page = await _repo.list(
        cursor: state.nextCursor,
        limit: 20,
        teamId: state.teamId,
        search: state.search,
      );
      if (seq != _requestSeq) return;
      state = state.copyWith(
        items: [...state.items, ...page.items],
        isLoadingMore: false,
        nextCursor: page.nextCursor,
        clearCursor: page.nextCursor == null,
        hasMore: page.hasMore,
        total: page.total,
      );
    } on ApiException catch (e) {
      if (seq != _requestSeq) return;
      state = state.copyWith(isLoadingMore: false, error: e.message);
    }
  }

  /// Called on every keystroke; debounced to one request per 300ms pause.
  void setSearch(String value) {
    state = state.copyWith(search: value);
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => refresh());
  }

  void setTeamFilter(int? teamId) {
    state = teamId == null
        ? state.copyWith(clearTeam: true)
        : state.copyWith(teamId: teamId);
    refresh();
  }

  /// Merge a freshly polled status snapshot into the loaded rows in place,
  /// preserving scroll/order. Only `live` changes — identity fields don't.
  void applyLiveSnapshot(Map<int, LiveStatus> snapshot) {
    if (snapshot.isEmpty) return;
    final updated = [
      for (final e in state.items)
        snapshot.containsKey(e.id)
            ? Employee(
                id: e.id,
                name: e.name,
                email: e.email,
                role: e.role,
                isActive: e.isActive,
                phone: e.phone,
                teamId: e.teamId,
                profilePhotoUrl: e.profilePhotoUrl,
                createdAt: e.createdAt,
                team: e.team,
                live: snapshot[e.id],
              )
            : e,
    ];
    state = state.copyWith(items: updated);
  }
}

final employeeListProvider =
    NotifierProvider<EmployeeNotifier, EmployeeListState>(EmployeeNotifier.new);

/// Single employee detail — family by id. AsyncNotifier-free: a simple
/// FutureProvider.family is enough (the screen owns refresh via ref.invalidate).
final employeeDetailProvider =
    FutureProvider.family<Employee, int>((ref, id) async {
  return ref.watch(employeeRepositoryProvider).detail(id);
});

/// Monthly attendance summary for the detail screen, keyed by employee id.
final attendanceSummaryProvider =
    FutureProvider.family<AttendanceSummary, int>((ref, id) async {
  final now = DateTime.now();
  return ref
      .watch(employeeRepositoryProvider)
      .attendanceSummary(id, year: now.year, month: now.month);
});

/// Last-known location point for the detail mini-map (today's track, last
/// point). Null when there's no location for the range.
final lastLocationProvider =
    FutureProvider.family<LocationPoint?, int>((ref, id) async {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final points = await ref.watch(employeeRepositoryProvider).locationHistory(
        id,
        from: today,
        to: today,
        limit: 1,
      );
  return points.isEmpty ? null : points.last;
});

/// Lifecycle-aware live-status poller. Polls the employees list every 30s, but
/// ONLY while the screen is mounted AND the app is foregrounded — it observes
/// WidgetsBinding lifecycle and parks the timer on background/pause, so a
/// pocketed phone isn't hammering the API.
///
/// Usage: a screen calls `ref.read(liveStatusPollerProvider).attach()` in
/// initState and `detach()` in dispose (see EmployeeListScreen).
class LiveStatusPoller with WidgetsBindingObserver {
  LiveStatusPoller(this._ref);
  final Ref _ref;

  Timer? _timer;
  bool _attached = false;
  bool _foreground = true;

  static const _interval = Duration(seconds: 30);

  void attach() {
    if (_attached) return;
    _attached = true;
    _foreground =
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.paused;
    WidgetsBinding.instance.addObserver(this);
    _start();
  }

  void detach() {
    if (!_attached) return;
    _attached = false;
    WidgetsBinding.instance.removeObserver(this);
    _stop();
  }

  void _start() {
    _stop();
    if (!_foreground) return;
    _timer = Timer.periodic(_interval, (_) => _poll());
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final nowForeground = state == AppLifecycleState.resumed;
    if (nowForeground == _foreground) return;
    _foreground = nowForeground;
    if (_foreground) {
      _poll(); // immediate refresh on resume
      _start();
    } else {
      _stop();
    }
  }

  Future<void> _poll() async {
    try {
      // Re-fetch the loaded rows; the list endpoint carries live status per
      // row. Cap at 100 so a long, paged list still refreshes in one call.
      final current = _ref.read(employeeListProvider);
      final limit = current.items.length.clamp(20, 100).toInt();
      final page = await _ref.read(employeeRepositoryProvider).list(
            limit: limit,
            teamId: current.teamId,
            search: current.search,
          );
      final snapshot = <int, LiveStatus>{
        for (final e in page.items)
          if (e.live != null) e.id: e.live!,
      };
      _ref.read(employeeListProvider.notifier).applyLiveSnapshot(snapshot);
    } on ApiException {
      // Silent: polling failures must not surface an error banner — the next
      // tick (or a manual pull-to-refresh) retries.
    }
  }
}

final liveStatusPollerProvider =
    Provider<LiveStatusPoller>((ref) => LiveStatusPoller(ref));
