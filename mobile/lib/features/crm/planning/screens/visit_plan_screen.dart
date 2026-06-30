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

    return Scaffold(
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

    return ReorderableListView.builder(
      padding: const EdgeInsets.fromLTRB(
        AppDimens.grid * 2,
        AppDimens.grid,
        AppDimens.grid * 2,
        AppDimens.grid * 2,
      ),
      itemCount: state.items.length,
      onReorder: notifier.reorder,
      itemBuilder: (context, index) {
        final item = state.items[index];
        return Padding(
          key: ValueKey(item.key),
          padding: const EdgeInsets.only(bottom: AppDimens.grid * 1.5),
          child: Dismissible(
            key: ValueKey('dismiss-${item.key}'),
            direction: DismissDirection.endToStart,
            background: _swipeBg(context),
            onDismissed: (_) => _removeWithUndo(context, notifier, index, item),
            child: PlanItemCard(
              item: item,
              index: index,
              onStartVisit: () => context.push(
                '/visit/start/${item.farmerId}'
                '${item.isFollowUp ? '' : '?plan_item=${item.id}'}',
              ),
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
              onPressed: state.items.isEmpty ? null : () => _save(context),
            ),
          ),
        ],
      ),
    );
  }
}
