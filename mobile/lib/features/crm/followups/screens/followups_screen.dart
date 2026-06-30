import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/shimmer_card.dart';
import '../../../../core/widgets/state_views.dart';
import '../data/follow_up_repository.dart';
import '../models/follow_up.dart';

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// Calendar-style follow-ups: a horizontal date strip (today + 7 days) over the
/// list of that day's follow-ups. Tap → farmer detail; long-press → complete.
class FollowUpsScreen extends ConsumerWidget {
  const FollowUpsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(myFollowUpsProvider);
    final selected = ref.watch(selectedFollowUpDateProvider);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final days = [for (var i = 0; i < 8; i++) today.add(Duration(days: i))];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Follow-ups',
            maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: SafeArea(
        child: async.when(
          loading: () => const ShimmerList(count: 5),
          error: (e, _) => ErrorStateView(
            message: e.toString(),
            onRetry: () => ref.invalidate(myFollowUpsProvider),
          ),
          data: (items) {
            final byDay = <String, int>{};
            for (final f in items) {
              final k = _key(f.scheduledDate);
              byDay[k] = (byDay[k] ?? 0) + 1;
            }
            final dayItems =
                items.where((f) => _sameDay(f.scheduledDate, selected)).toList();

            return Column(
              children: [
                _DateStrip(
                  days: days,
                  selected: selected,
                  countFor: (d) => byDay[_key(d)] ?? 0,
                  onSelect: (d) => ref
                      .read(selectedFollowUpDateProvider.notifier)
                      .state = d,
                ),
                Expanded(
                  child: dayItems.isEmpty
                      ? const EmptyStateView(
                          icon: Icons.event_available_rounded,
                          title: 'Nothing scheduled',
                          message: 'No follow-ups for this day.',
                        )
                      : RefreshIndicator(
                          onRefresh: () async =>
                              ref.invalidate(myFollowUpsProvider),
                          child: ListView.separated(
                            physics: const AlwaysScrollableScrollPhysics(),
                            padding: const EdgeInsets.all(AppDimens.grid * 2),
                            itemCount: dayItems.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: AppDimens.grid * 1.5),
                            itemBuilder: (context, i) => _FollowUpCard(
                              item: dayItems[i],
                              onTap: dayItems[i].farmerId != null
                                  ? () => context
                                      .push('/farmer/${dayItems[i].farmerId}')
                                  : null,
                              onComplete: () =>
                                  _complete(context, ref, dayItems[i]),
                            ),
                          ),
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  static String _key(DateTime d) => '${d.year}-${d.month}-${d.day}';

  Future<void> _complete(
      BuildContext context, WidgetRef ref, FollowUpItem item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Mark as completed?'),
        content: Text('Complete the follow-up with ${item.farmerName ?? 'this farmer'}?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Complete')),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(followUpRepositoryProvider).complete(item.id);
    HapticFeedback.selectionClick();
    ref.invalidate(myFollowUpsProvider);
  }
}

class _DateStrip extends StatelessWidget {
  const _DateStrip({
    required this.days,
    required this.selected,
    required this.countFor,
    required this.onSelect,
  });

  final List<DateTime> days;
  final DateTime selected;
  final int Function(DateTime) countFor;
  final ValueChanged<DateTime> onSelect;

  static const _wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 76,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(
            horizontal: AppDimens.grid * 2, vertical: AppDimens.grid),
        itemCount: days.length,
        separatorBuilder: (_, __) => const SizedBox(width: AppDimens.grid),
        itemBuilder: (context, i) {
          final d = days[i];
          final isSel = _sameDay(d, selected);
          final count = countFor(d);
          return GestureDetector(
            onTap: () => onSelect(d),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 52,
              padding: const EdgeInsets.symmetric(vertical: AppDimens.grid),
              decoration: BoxDecoration(
                color: isSel ? scheme.primary : colors.card,
                borderRadius: BorderRadius.circular(AppDimens.cardRadius),
                border: Border.all(
                  color: isSel
                      ? scheme.primary
                      : colors.textSecondary.withValues(alpha: 0.2),
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(_wd[d.weekday - 1],
                      style: AppTextStyles.caption.copyWith(
                          color: isSel ? scheme.onPrimary : colors.textSecondary,
                          fontSize: 10)),
                  const SizedBox(height: 2),
                  Text('${d.day}',
                      style: AppTextStyles.bodyMedium.copyWith(
                          color:
                              isSel ? scheme.onPrimary : scheme.onSurface,
                          fontWeight: FontWeight.w700)),
                  const SizedBox(height: 3),
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: count > 0
                          ? (isSel ? scheme.onPrimary : scheme.primary)
                          : Colors.transparent,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _FollowUpCard extends StatelessWidget {
  const _FollowUpCard({
    required this.item,
    this.onTap,
    required this.onComplete,
  });

  final FollowUpItem item;
  final VoidCallback? onTap;
  final VoidCallback onComplete;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final scheme = Theme.of(context).colorScheme;
    final (icon, iconColor) = _statusIcon(context);

    return GestureDetector(
      onLongPress: onComplete,
      child: AppCard(
        onTap: onTap,
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.14),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 18, color: iconColor),
            ),
            const SizedBox(width: AppDimens.grid * 1.5),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      if (item.timeLabel != null) ...[
                        Text(item.timeLabel!,
                            style: AppTextStyles.caption.copyWith(
                                color: colors.textSecondary,
                                fontWeight: FontWeight.w700)),
                        const SizedBox(width: AppDimens.grid),
                      ],
                      Expanded(
                        child: Text(item.farmerName ?? 'Farmer',
                            style: AppTextStyles.bodyMedium
                                .copyWith(color: scheme.onSurface),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                      ),
                    ],
                  ),
                  if (item.purpose != null && item.purpose!.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(item.purpose!,
                        style: AppTextStyles.caption
                            .copyWith(color: colors.textSecondary),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  (IconData, Color) _statusIcon(BuildContext context) {
    final colors = context.appColors;
    final scheme = Theme.of(context).colorScheme;
    if (item.status == 'COMPLETED') {
      return (Icons.check_circle_rounded, colors.statusActive);
    }
    if (item.status == 'ESCALATED' || item.isOverdue) {
      return (Icons.warning_amber_rounded, scheme.error);
    }
    if (item.status == 'ACKNOWLEDGED') {
      return (Icons.check_rounded, colors.textSecondary);
    }
    return (Icons.schedule_rounded, scheme.primary); // upcoming
  }
}
