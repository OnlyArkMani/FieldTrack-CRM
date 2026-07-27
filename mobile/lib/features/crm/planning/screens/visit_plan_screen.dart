import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_button.dart';
import '../../../../core/widgets/shimmer_card.dart';
import '../../../../core/widgets/state_views.dart';
import '../../../attendance/providers/attendance_provider.dart';
import '../models/visit_plan.dart';
import '../providers/visit_plan_provider.dart';
import '../widgets/add_visit_sheet.dart';
import '../widgets/edit_visit_sheet.dart';
import '../widgets/plan_item_card.dart';

/// Pre-day visit planning. Date selector, save-status bar, reorderable visit
/// list (swipe to remove + undo), add-visit sheet, sticky save, and a map view
/// toggle for sequencing the route.
class VisitPlanScreen extends ConsumerWidget {
  const VisitPlanScreen({super.key});

  Future<void> _pickDate(
      BuildContext context, WidgetRef ref, DateTime currentDate) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: currentDate,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked != null) {
      ref.read(visitPlanProvider.notifier).setDate(picked);
    }
  }

  String _dateLabel(DateTime d) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final diff = d.difference(today).inDays;
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    const weekdays = [
      'Monday', 'Tuesday', 'Wednesday', 'Thursday',
      'Friday', 'Saturday', 'Sunday',
    ];
    final prefix = switch (diff) {
      0 => 'Today',
      1 => 'Tomorrow',
      -1 => 'Yesterday',
      _ => weekdays[d.weekday - 1],
    };
    return '$prefix, ${d.day} ${months[d.month - 1]}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(visitPlanProvider);
    final notifier = ref.read(visitPlanProvider.notifier);
    // Checked out / on leave today, or the selected plan day itself is a
    // leave day => can't start (or plan) a visit for it. Kept as a reason
    // string (not just a bool) so the disabled Start Visit button can say
    // *why* instead of just going grey with no explanation.
    final attendanceState = ref.watch(attendanceProvider).state;
    final onLeaveThisDay = !state.isLoading && state.isOnLeave;
    // Viewing a future day (via the date selector's forward chevron) is for
    // previewing/editing the plan ahead of time — visits can only actually
    // be started once that day arrives. Past days are already unreachable
    // (canGoPrev stops at today), so this only ever fires for the future.
    final visitBlockedReason = !state.isLoading && !state.isToday
        ? "You can only start a visit from today's plan"
        : onLeaveThisDay
            ? 'This day is marked as leave'
            : attendanceState.isEnded
                ? "You've checked out for today"
                : attendanceState.isOnLeave
                    ? "You're on leave today"
                    : null;
    // An added/edited stop only exists locally until "Save Plan" is tapped —
    // starting a visit against it before that sends a plan_item_id the
    // server has never seen, so the visit's target/purpose land as null in
    // admin. Follow-ups aren't backed by a plan item, so they're exempt.
    final planNotSavedReason =
        !state.isLoading && !state.isSaved ? 'Save the plan first' : null;

    // Scoped ScaffoldMessenger: without this, "removed"/"saved" SnackBars are
    // hosted by the app-root messenger (above the Navigator) and keep showing
    // — undismissed, timer still running — on whatever screen the user
    // navigates to next. Popping this route now tears the messenger (and any
    // pending SnackBar/timer) down with it instead of leaking it forward.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          if (context.canPop()) {
            context.pop();
          } else {
            context.go('/home/dashboard');
          }
        }
      },
      child: ScaffoldMessenger(
        child: Scaffold(
          appBar: AppBar(
            leading: IconButton(
              icon: const Icon(Icons.arrow_back_rounded),
              onPressed: () =>
                  context.canPop() ? context.pop() : context.go('/home/dashboard'),
            ),
            title: const Text('Visit plan',
                maxLines: 1, overflow: TextOverflow.ellipsis),
            actions: [
              IconButton(
                tooltip: 'Map view',
                icon: const Icon(Icons.map_rounded),
                onPressed: () => context.push('/planning/map'),
              ),
            ],
          ),
        body: SafeArea(
          child: Column(
            children: [
              _DateSelector(
                label: _dateLabel(state.date),
                canGoPrev: notifier.canGoPrev,
                onPrev: notifier.prevDay,
                onNext: notifier.nextDay,
                onSelectDate: () => _pickDate(context, ref, state.date),
              ),
              if (onLeaveThisDay)
                const _LeaveBanner()
              else
                _StatusBar(state: state),
              Expanded(
                  child: _body(context, ref, state, notifier,
                      visitBlockedReason, planNotSavedReason, onLeaveThisDay)),
              _BottomBar(
                  state: state, notifier: notifier, blocked: onLeaveThisDay),
            ],
          ),
        ),
      ),
    ),
  );
}

  Widget _body(
    BuildContext context,
    WidgetRef ref,
    VisitPlanState state,
    VisitPlanNotifier notifier,
    String? visitBlockedReason,
    String? planNotSavedReason,
    bool onLeaveThisDay,
  ) {
    if (state.isLoading) return const ShimmerList(count: 4);

    if (state.error != null && state.items.isEmpty) {
      return ErrorStateView(message: state.error!, onRetry: notifier.load);
    }

    final carryOver = notifier.carryOverItems;

    if (state.items.isEmpty) {
      return EmptyStateView(
        icon: onLeaveThisDay
            ? Icons.event_busy_rounded
            : Icons.event_note_rounded,
        title: onLeaveThisDay ? "You're on leave this day" : 'No visits planned',
        message: onLeaveThisDay
            ? "Visits can't be planned for a leave day."
            : 'Add the farmers you intend to visit on this day.',
        actionLabel: onLeaveThisDay ? null : 'Add Visit',
        onAction: onLeaveThisDay ? null : () => AddVisitSheet.show(context),
      );
    }

    final main = _mainList(context, ref, notifier, carryOver,
        visitBlockedReason, planNotSavedReason, state.date, onLeaveThisDay);
    if (carryOver.isEmpty) return main;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Carry-over stops are already persisted from an earlier day, so an
        // unsaved edit made to *other* items in today's draft doesn't block
        // them — only the leave/attendance reason applies here.
        _CarryOverSection(
            items: carryOver,
            notifier: notifier,
            blockedReason: visitBlockedReason),
        Expanded(child: main),
      ],
    );
  }

  Widget _mainList(
    BuildContext context,
    WidgetRef ref,
    VisitPlanNotifier notifier,
    List<PlanItem> carryOver,
    String? visitBlockedReason,
    String? planNotSavedReason,
    DateTime planDate,
    bool onLeaveThisDay,
  ) {
    final active = notifier.activeItems;
    final completed = notifier.completedItems;

    if (active.isEmpty && completed.isEmpty) {
      // Only carry-over stops remain — nothing to edit below the section.
      return const SizedBox.shrink();
    }

    // Planning mode (nothing completed yet): keep the full reorderable /
    // swipe-to-remove editing experience.
    if (completed.isEmpty) {
      return ReorderableListView.builder(
        padding: const EdgeInsets.fromLTRB(
          AppDimens.grid * 2,
          AppDimens.grid,
          AppDimens.grid * 2,
          AppDimens.grid * 2,
        ),
        itemCount: active.length,
        onReorder: notifier.reorder,
        itemBuilder: (context, index) {
          final item = active[index];
          return Padding(
            key: ValueKey(item.key),
            padding: const EdgeInsets.only(bottom: AppDimens.grid * 1.5),
            child: Dismissible(
              key: ValueKey('dismiss-${item.key}'),
              direction: DismissDirection.endToStart,
              background: _swipeBg(context),
              onDismissed: (_) =>
                  _removeWithUndo(context, notifier, index, item),
              child: PlanItemCard(
                item: item,
                index: index,
                onStartVisit: () => _startVisit(context, item, completed),
                disabledReason: _startReason(
                    item, visitBlockedReason, planNotSavedReason),
                onEdit: _editCallback(context, item, planDate, onLeaveThisDay),
                trailing: ReorderableDragStartListener(
                  index: index,
                  child: Icon(Icons.drag_handle_rounded,
                      color: context.appColors.textSecondary),
                ),
              ),
            ),
          );
        },
      );
    }

    // Execution mode: Active (actionable) and Completed (done today) sections.
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppDimens.grid * 2,
        AppDimens.grid,
        AppDimens.grid * 2,
        AppDimens.grid * 2,
      ),
      children: [
        if (active.isNotEmpty) ...[
          _sectionHeader(context, 'Active', active.length),
          for (var i = 0; i < active.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: AppDimens.grid * 1.5),
              child: PlanItemCard(
                item: active[i],
                index: i,
                onStartVisit: () => _startVisit(context, active[i], completed),
                disabledReason: _startReason(
                    active[i], visitBlockedReason, planNotSavedReason),
                onEdit:
                    _editCallback(context, active[i], planDate, onLeaveThisDay),
              ),
            ),
        ],
        if (completed.isNotEmpty) ...[
          const SizedBox(height: AppDimens.grid),
          _sectionHeader(context, 'Completed today', completed.length),
          for (var i = 0; i < completed.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: AppDimens.grid * 1.5),
              child: Opacity(
                opacity: 0.7,
                child: PlanItemCard(item: completed[i], index: i),
              ),
            ),
        ],
      ],
    );
  }

  Widget _sectionHeader(BuildContext context, String label, int count) {
    return Padding(
      padding: const EdgeInsets.only(
          top: AppDimens.grid, bottom: AppDimens.grid),
      child: Text(
        '$label · $count',
        style: AppTextStyles.caption.copyWith(
          color: context.appColors.textSecondary,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  /// Pencil-icon callback for a plan item, or null to hide it. Only a real,
  /// still-PLANNED saved stop is editable — follow-ups aren't backed by a
  /// visit-plan-item id, and a checked-in/skipped stop is locked server-side
  /// anyway, so there's no point offering the pencil for either.
  VoidCallback? _editCallback(
    BuildContext context,
    PlanItem item,
    DateTime planDate,
    bool onLeaveThisDay,
  ) {
    if (item.isFollowUp ||
        item.isCarryOver ||
        VisitPlanNotifier.isDone(item) ||
        onLeaveThisDay) {
      return null;
    }
    return () => EditVisitSheet.show(context, item, planDate);
  }

  /// Reason (if any) "Start Visit" is disabled for [item]. Leave/attendance
  /// blocks everything; the unsaved-plan block only applies to real plan
  /// items — a follow-up isn't backed by one, so it's never affected by it.
  String? _startReason(
    PlanItem item,
    String? visitBlockedReason,
    String? planNotSavedReason,
  ) {
    if (visitBlockedReason != null) return visitBlockedReason;
    if (item.isFollowUp) return null;
    return planNotSavedReason;
  }

  /// Same-day revisit guard: if this farmer was already completed today, warn
  /// (soft — the user can continue) before launching the visit flow.
  Future<void> _startVisit(
    BuildContext context,
    PlanItem item,
    List<PlanItem> completedToday,
  ) async {
    final already = completedToday.any((c) => c.farmerId == item.farmerId);
    if (already) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Already visited today'),
          content: Text(
            'You have already visited ${item.farmerName} today. '
            'Do you want to continue?',
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Continue')),
          ],
        ),
      );
      if (proceed != true || !context.mounted) return;
    }
    context.push(
      '/visit/start/${item.farmerId}'
      '${item.isFollowUp ? '' : '?plan_item=${item.id}'
          '${item.targetOrderBags != null ? '&target_bags=${item.targetOrderBags}' : ''}'
          '${item.purpose != null ? '&purpose=${Uri.encodeComponent(item.purpose!)}' : ''}'}',
    );
  }

  Widget _swipeBg(BuildContext context) {
    return Container(
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.symmetric(horizontal: AppDimens.grid * 2),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.error.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppDimens.cardRadius),
      ),
      child: Icon(Icons.delete_rounded,
          color: Theme.of(context).colorScheme.error),
    );
  }

  // The autosave-after-undo-window timer lives on the notifier itself, not
  // here — this SnackBar is purely the Undo affordance now. It used to also
  // schedule the deferred save via `.closed.then(...)`, but that ties the
  // save to this ScaffoldMessenger's lifecycle, which gets torn down the
  // moment the route pops (see the PopScope comment above) — so navigating
  // away within the undo window silently dropped the save. The notifier's
  // own Timer isn't tied to this widget and fires regardless.
  void _removeWithUndo(
    BuildContext context,
    VisitPlanNotifier notifier,
    int index,
    PlanItem item,
  ) {
    notifier.removeAt(index);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('${item.farmerName} removed'),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () => notifier.insertAt(index, item),
          ),
        ),
      );
  }
}

/// Missed stops carried over from earlier days. Each can be started now,
/// rescheduled onto another day, or dropped.
class _CarryOverSection extends StatelessWidget {
  const _CarryOverSection({
    required this.items,
    required this.notifier,
    this.blockedReason,
  });
  final List<PlanItem> items;
  final VisitPlanNotifier notifier;

  /// Non-null when the Start action is disabled — checked out for today, on
  /// leave today, or this day is a leave day. Doubles as the tooltip text.
  final String? blockedReason;

  Future<void> _reschedule(BuildContext context, PlanItem item) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.now().add(const Duration(days: 1)),
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 90)),
    );
    if (picked == null) return;
    final ok = await notifier.rescheduleCarryOver(item, picked);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ok
            ? '${item.farmerName} moved to a new day'
            : 'Could not reschedule'),
      ));
    }
  }

  Future<void> _drop(BuildContext context, PlanItem item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Drop this visit?'),
        content: Text(
            "${item.farmerName} won't be carried over anymore."),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Drop')),
        ],
      ),
    );
    if (ok != true) return;
    final done = await notifier.dropCarryOver(item);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(done ? '${item.farmerName} dropped' : 'Could not drop'),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(AppDimens.grid * 2, AppDimens.grid,
          AppDimens.grid * 2, AppDimens.grid),
      padding: const EdgeInsets.all(AppDimens.grid * 1.5),
      decoration: BoxDecoration(
        color: scheme.secondary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppDimens.cardRadius),
        border: Border.all(color: scheme.secondary.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.history_rounded, size: 16, color: scheme.secondary),
              const SizedBox(width: AppDimens.grid),
              Text('Carried over · ${items.length}',
                  style: AppTextStyles.caption.copyWith(
                      color: scheme.secondary, fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: AppDimens.grid),
          for (final item in items)
            Padding(
              padding: const EdgeInsets.only(bottom: AppDimens.grid),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(item.farmerName,
                            style: AppTextStyles.bodyMedium
                                .copyWith(color: scheme.onSurface),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                        Text(
                          item.village ?? 'Missed earlier',
                          style: AppTextStyles.caption
                              .copyWith(color: colors.textSecondary),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: blockedReason ?? 'Start',
                    visualDensity: VisualDensity.compact,
                    icon: Icon(Icons.play_arrow_rounded, color: scheme.primary),
                    onPressed: blockedReason != null
                        ? null
                        : () => context.push(
                            '/visit/start/${item.farmerId}?plan_item=${item.id}'
                            '${item.targetOrderBags != null ? '&target_bags=${item.targetOrderBags}' : ''}'
                            '${item.purpose != null ? '&purpose=${Uri.encodeComponent(item.purpose!)}' : ''}'),
                  ),
                  IconButton(
                    tooltip: 'Reschedule',
                    visualDensity: VisualDensity.compact,
                    icon: Icon(Icons.event_rounded, color: scheme.secondary),
                    onPressed: () => _reschedule(context, item),
                  ),
                  IconButton(
                    tooltip: 'Drop',
                    visualDensity: VisualDensity.compact,
                    icon: Icon(Icons.close_rounded, color: colors.textSecondary),
                    onPressed: () => _drop(context, item),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _DateSelector extends StatelessWidget {
  const _DateSelector({
    required this.label,
    required this.canGoPrev,
    required this.onPrev,
    required this.onNext,
    required this.onSelectDate,
  });

  final String label;
  final bool canGoPrev;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onSelectDate;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppDimens.grid * 2,
        AppDimens.grid * 1.5,
        AppDimens.grid * 2,
        AppDimens.grid * 0.5,
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: canGoPrev ? onPrev : null,
            icon: const Icon(Icons.chevron_left_rounded),
            color: scheme.primary,
            disabledColor: colors.textSecondary.withValues(alpha: 0.4),
          ),
          Expanded(
            child: InkWell(
              onTap: onSelectDate,
              borderRadius: BorderRadius.circular(AppDimens.buttonRadius),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  vertical: AppDimens.grid * 0.5,
                  horizontal: AppDimens.grid,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Planning for',
                        style: AppTextStyles.caption
                            .copyWith(color: colors.textSecondary)),
                    const SizedBox(height: 2),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            label,
                            style: AppTextStyles.bodyMedium.copyWith(
                              color: scheme.onSurface,
                              fontWeight: FontWeight.w600,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(
                          Icons.calendar_month_rounded,
                          size: 16,
                          color: scheme.primary,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          IconButton(
            onPressed: onNext,
            icon: const Icon(Icons.chevron_right_rounded),
            color: scheme.primary,
          ),
        ],
      ),
    );
  }
}

/// Shown instead of the save-status bar when the selected day is marked
/// leave — visits can't be planned for it (mirrors the server-side guard).
class _LeaveBanner extends StatelessWidget {
  const _LeaveBanner();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(horizontal: AppDimens.grid * 2),
      padding: const EdgeInsets.symmetric(
          horizontal: AppDimens.grid * 1.5, vertical: AppDimens.grid),
      decoration: BoxDecoration(
        color: scheme.error.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppDimens.buttonRadius),
      ),
      child: Row(
        children: [
          Icon(Icons.event_busy_rounded, size: 16, color: scheme.error),
          const SizedBox(width: AppDimens.grid),
          Expanded(
            child: Text(
              "You're on leave this day — visits can't be planned",
              style: AppTextStyles.caption
                  .copyWith(color: scheme.error, fontWeight: FontWeight.w600),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({required this.state});
  final VisitPlanState state;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final saved = state.isSaved;
    final color = saved ? colors.statusActive : colors.statusIdle;
    final count = state.items.length;
    final text = saved
        ? 'Plan saved · $count visit${count == 1 ? '' : 's'} planned'
        : 'Plan not saved yet';
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(horizontal: AppDimens.grid * 2),
      padding: const EdgeInsets.symmetric(
          horizontal: AppDimens.grid * 1.5, vertical: AppDimens.grid),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppDimens.buttonRadius),
      ),
      child: Row(
        children: [
          Icon(saved ? Icons.check_circle_rounded : Icons.warning_amber_rounded,
              size: 16, color: color),
          const SizedBox(width: AppDimens.grid),
          Expanded(
            child: Text(
              text,
              style: AppTextStyles.caption
                  .copyWith(color: color, fontWeight: FontWeight.w600),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.state,
    required this.notifier,
    this.blocked = false,
  });
  final VisitPlanState state;
  final VisitPlanNotifier notifier;

  /// The selected day is a leave day — Add/Save are disabled.
  final bool blocked;

  Future<void> _save(BuildContext context) async {
    final ok = await notifier.save();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(ok ? 'Plan saved' : (state.error ?? 'Could not save')),
      ));
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    return Container(
      padding: const EdgeInsets.all(AppDimens.grid * 2),
      decoration: BoxDecoration(
        color: colors.card,
        boxShadow: AppDimens.shadow(Theme.of(context).brightness),
      ),
      child: Row(
        children: [
          Expanded(
            child: AppButton(
              label: 'Add Visit',
              icon: Icons.add_rounded,
              variant: AppButtonVariant.secondary,
              onPressed:
                  blocked ? null : () => AddVisitSheet.show(context),
            ),
          ),
          const SizedBox(width: AppDimens.grid * 1.5),
          Expanded(
            child: AppButton(
              label: 'Save Plan',
              icon: Icons.check_rounded,
              isLoading: state.isSaving,
              // dirty, not "has at least one active item" — that used to
              // disable this button the moment the last stop was removed,
              // so there was no way to manually persist an intentionally
              // emptied plan; an empty plan is a valid, save-able state.
              onPressed: !blocked && state.dirty ? () => _save(context) : null,
            ),
          ),
        ],
      ),
    );
  }
}
