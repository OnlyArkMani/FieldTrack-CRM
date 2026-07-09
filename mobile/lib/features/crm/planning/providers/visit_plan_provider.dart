import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/network/api_exceptions.dart';
import '../../../auth/providers/auth_provider.dart';
import '../data/visit_plan_repository.dart';
import '../models/visit_plan.dart';

DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

/// Working state for the planning screen: the selected date, the server plan,
/// and a mutable draft item list the user edits before saving.
class VisitPlanState {
  const VisitPlanState({
    required this.date,
    this.plan,
    this.items = const [],
    this.isLoading = false,
    this.isSaving = false,
    this.error,
    this.dirty = false,
  });

  final DateTime date;
  final MyPlan? plan;
  final List<PlanItem> items;
  final bool isLoading;
  final bool isSaving;
  final String? error;
  final bool dirty;

  /// Saved == a submitted plan exists AND there are no unsaved edits.
  bool get isSaved => plan != null && plan!.isSubmitted && !dirty;

  /// The employee is on leave for the selected [date] — mirrors the
  /// server-side guard that blocks planning visits for a leave day.
  bool get isOnLeave => plan?.isOnLeave ?? false;

  VisitPlanState copyWith({
    DateTime? date,
    MyPlan? plan,
    List<PlanItem>? items,
    bool? isLoading,
    bool? isSaving,
    String? error,
    bool clearError = false,
    bool? dirty,
  }) =>
      VisitPlanState(
        date: date ?? this.date,
        plan: plan ?? this.plan,
        items: items ?? this.items,
        isLoading: isLoading ?? this.isLoading,
        isSaving: isSaving ?? this.isSaving,
        error: clearError ? null : (error ?? this.error),
        dirty: dirty ?? this.dirty,
      );
}

class VisitPlanNotifier extends Notifier<VisitPlanState> {
  @override
  VisitPlanState build() {
    final date = _initialDate();
    final auth = ref.watch(authProvider);
    if (auth.status != AuthStatus.authenticated) {
      return VisitPlanState(date: date);
    }
    Future.microtask(load);
    return VisitPlanState(date: date, isLoading: true);
  }

  VisitPlanRepository get _repo => ref.read(visitPlanRepositoryProvider);

  /// A stop is "resolved" (not actionable) once completed or skipped.
  static bool isDone(PlanItem i) {
    final s = i.status.toUpperCase();
    return s == 'COMPLETED' || s == 'SKIPPED';
  }

  /// Actionable stops (PLANNED / IN_PROGRESS + pending follow-ups). Carried-over
  /// items are excluded — they render in their own section and aren't re-saved.
  List<PlanItem> get activeItems =>
      state.items.where((i) => !isDone(i) && !i.isCarryOver).toList();

  /// Resolved stops (COMPLETED / SKIPPED) — shown in a separate section.
  List<PlanItem> get completedItems =>
      state.items.where(isDone).toList();

  /// Missed PLANNED stops carried over from earlier days.
  List<PlanItem> get carryOverItems =>
      state.items.where((i) => i.isCarryOver && !isDone(i)).toList();

  /// Reschedule a missed item onto [targetDate] (source skipped server-side).
  Future<bool> rescheduleCarryOver(
    PlanItem item,
    DateTime targetDate, {
    String? timeSlot,
  }) async {
    try {
      await _repo.carryOver(item.id, targetDate: targetDate, timeSlot: timeSlot);
      await load();
      return true;
    } on ApiException catch (e) {
      state = state.copyWith(error: e.message);
      return false;
    }
  }

  /// Drop a missed item (marks it SKIPPED) so it stops carrying over.
  Future<bool> dropCarryOver(PlanItem item) async {
    try {
      await _repo.skipItem(item.id);
      await load();
      return true;
    } on ApiException catch (e) {
      state = state.copyWith(error: e.message);
      return false;
    }
  }

  /// Defaults to tomorrow after 4 PM (planning for the next day), else today.
  static DateTime _initialDate() {
    final now = DateTime.now();
    final base = _dateOnly(now);
    return now.hour >= 16 ? base.add(const Duration(days: 1)) : base;
  }

  /// Earliest plannable day is today — you can't plan the past.
  bool get canGoPrev => state.date.isAfter(_dateOnly(DateTime.now()));

  Future<void> load() async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final plan = await _repo.myPlan(state.date);
      state = state.copyWith(
        plan: plan,
        items: plan.items,
        isLoading: false,
        dirty: false,
      );
    } on ApiException catch (e) {
      state = state.copyWith(isLoading: false, error: e.message);
    }
  }

  void setDate(DateTime date) {
    state = state.copyWith(date: _dateOnly(date), isLoading: true);
    load();
  }

  void nextDay() => setDate(state.date.add(const Duration(days: 1)));

  void prevDay() {
    if (!canGoPrev) return;
    setDate(state.date.subtract(const Duration(days: 1)));
  }

  void addItem(PlanItem item) {
    // Skip if this farmer is already in the plan.
    if (state.items.any((i) => i.farmerId == item.farmerId)) return;
    state = state.copyWith(items: [...state.items, item], dirty: true);
  }

  /// Removes the active item at [index] (index into activeItems) and returns
  /// it (for undo). Completed items are untouched.
  PlanItem removeAt(int index) {
    final active = activeItems;
    final removed = active.removeAt(index);
    state = state.copyWith(items: [...active, ...completedItems], dirty: true);
    return removed;
  }

  void insertAt(int index, PlanItem item) {
    final active = activeItems;
    active.insert(index.clamp(0, active.length), item);
    state = state.copyWith(items: [...active, ...completedItems], dirty: true);
  }

  /// Reorder within the active list only (completed stay in their section).
  void reorder(int oldIndex, int newIndex) {
    final active = activeItems;
    if (newIndex > oldIndex) newIndex -= 1;
    final moved = active.removeAt(oldIndex);
    active.insert(newIndex, moved);
    state = state.copyWith(items: [...active, ...completedItems], dirty: true);
  }

  /// Edit a still-PLANNED item's time/purpose/target bags/day. Reloads the
  /// currently viewed date afterward — if [planDate] moved the item to a
  /// different day, it simply drops out of this list.
  Future<bool> editItem(
    PlanItem item, {
    String? timeSlot,
    String? purpose,
    int? targetOrderBags,
    DateTime? planDate,
  }) async {
    try {
      await _repo.updateItem(
        item.id,
        timeSlot: timeSlot,
        purpose: purpose,
        targetOrderBags: targetOrderBags,
        planDate: planDate,
      );
      await load();
      return true;
    } on ApiException catch (e) {
      state = state.copyWith(error: e.message);
      return false;
    }
  }

  Future<bool> save() async {
    // Only real, unresolved plan stops are persisted — follow-ups (which the
    // server injects for the date) and completed/skipped stops must not be
    // re-submitted as plan items.
    final toSave = state.items
        .where((i) => !i.isFollowUp && !i.isCarryOver && !isDone(i))
        .toList();
    if (toSave.isEmpty || state.isSaving) return false;
    state = state.copyWith(isSaving: true, clearError: true);
    try {
      final plan = await _repo.savePlan(state.date, toSave);
      state = state.copyWith(
        plan: plan,
        items: plan.items,
        isSaving: false,
        dirty: false,
      );
      return true;
    } on ApiException catch (e) {
      state = state.copyWith(isSaving: false, error: e.message);
      return false;
    }
  }
}

final visitPlanProvider =
    NotifierProvider<VisitPlanNotifier, VisitPlanState>(VisitPlanNotifier.new);

/// Marker positions for the plan map: farmers in the current draft that have a
/// known location. (Built lazily by the map view from the item list + farmer
/// detail lookups isn't needed — the list already carries farmer_id; the map
/// view fetches farmer coordinates via the farmers repo.)
final plannedItemsProvider = Provider<List<PlanItem>>((ref) {
  return ref.watch(visitPlanProvider).items;
});
