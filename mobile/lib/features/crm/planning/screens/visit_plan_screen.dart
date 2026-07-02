import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_button.dart';
import '../../../../core/widgets/shimmer_card.dart';
import '../../../../core/widgets/state_views.dart';
import '../models/visit_plan.dart';
import '../providers/visit_plan_provider.dart';
import '../widgets/add_visit_sheet.dart';
import '../widgets/plan_item_card.dart';

/// Pre-day visit planning. Date selector, save-status bar, reorderable visit
/// list (swipe to remove + undo), add-visit sheet, sticky save, and a map view
/// toggle for sequencing the route.
class VisitPlanScreen extends ConsumerWidget {
  const VisitPlanScreen({super.key});

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
      _ => weekdays[d.weekday - 1],
    };
    return '$prefix, ${d.day} ${months[d.month - 1]}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(visitPlanProvider);
    final notifier = ref.read(visitPlanProvider.notifier);

    // Scoped ScaffoldMessenger: without this, "removed"/"saved" SnackBars are
    // hosted by the app-root messenger (above the Navigator) and keep showing
    // — undismissed, timer still running — on whatever screen the user
    // navigates to next. Popping this route now tears the messenger (and any
    // pending SnackBar/timer) down with it instead of leaking it forward.
    return ScaffoldMessenger(
      child: Scaffold(
        appBar: AppBar(
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
              ),
              _StatusBar(state: state),
              Expanded(child: _body(context, ref, state, notifier)),
              _BottomBar(state: state, notifier: notifier),
            ],
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
  ) {
    if (state.isLoading) return const ShimmerList(count: 4);

    if (state.error != null && state.items.isEmpty) {
      return ErrorStateView(message: state.error!, onRetry: notifier.load);
    }

    if (state.items.isEmpty) {
      return EmptyStateView(
        icon: Icons.event_note_rounded,
        title: 'No visits planned',
        message: 'Add the farmers you intend to visit on this day.',
        actionLabel: 'Add Visit',
        onAction: () => AddVisitSheet.show(context),
      );
    }

    final active = notifier.activeItems;
    final completed = notifier.completedItems;

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
      '${item.isFollowUp ? '' : '?plan_item=${item.id}'}',
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

class _DateSelector extends StatelessWidget {
  const _DateSelector({
    required this.label,
    required this.canGoPrev,
    required this.onPrev,
    required this.onNext,
  });

  final String label;
  final bool canGoPrev;
  final VoidCallback onPrev;
  final VoidCallback onNext;

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
            child: Column(
              children: [
                Text('Planning for',
                    style: AppTextStyles.caption
                        .copyWith(color: colors.textSecondary)),
                Text(
                  label,
                  style: AppTextStyles.bodyMedium
                      .copyWith(color: scheme.onSurface),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
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
  const _BottomBar({required this.state, required this.notifier});
  final VisitPlanState state;
  final VisitPlanNotifier notifier;

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
              onPressed: () => AddVisitSheet.show(context),
            ),
          ),
          const SizedBox(width: AppDimens.grid * 1.5),
          Expanded(
            child: AppButton(
              label: 'Save Plan',
              icon: Icons.check_rounded,
              isLoading: state.isSaving,
              onPressed: state.items.any(
                      (i) => !i.isFollowUp && !VisitPlanNotifier.isDone(i))
                  ? () => _save(context)
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}
