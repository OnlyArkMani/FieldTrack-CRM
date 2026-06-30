import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/network/api_exceptions.dart';
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
    Future.microtask(load);
    return VisitPlanState(date: date, isLoading: true);
  }

  VisitPlanRepository get _repo => ref.read(visitPlanRepositoryProvider);

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

  /// Removes the item at [index] and returns it (for undo).
  PlanItem removeAt(int index) {
    final removed = state.items[index];
    final next = [...state.items]..removeAt(index);
    state = state.copyWith(items: next, dirty: true);
    return removed;
  }

  void insertAt(int index, PlanItem item) {
    final next = [...state.items];
    next.insert(index.clamp(0, next.length), item);
    state = state.copyWith(items: next, dirty: true);
  }

  void reorder(int oldIndex, int newIndex) {
    final next = [...state.items];
    if (newIndex > oldIndex) newIndex -= 1;
    final moved = next.removeAt(oldIndex);
    next.insert(newIndex, moved);
    state = state.copyWith(items: next, dirty: true);
  }

  Future<bool> save() async {
    if (state.items.isEmpty || state.isSaving) return false;
    state = state.copyWith(isSaving: true, clearError: true);
    try {
      final plan = await _repo.savePlan(state.date, state.items);
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
