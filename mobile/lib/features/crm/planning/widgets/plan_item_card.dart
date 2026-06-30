import 'package:flutter/material.dart';

import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_card.dart';
import '../../farmers/widgets/lead_status_badge.dart';
import '../models/visit_plan.dart';

/// "FIRST_VISIT" -> "First visit". Null -> "Visit".
String purposeLabel(String? purpose) {
  if (purpose == null || purpose.isEmpty) return 'Visit';
  return purpose
      .toLowerCase()
      .split('_')
      .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
      .join(' ');
}

/// Status -> (color, label) for the plan item indicator.
(Color, String) _statusMeta(BuildContext context, String status) {
  final colors = context.appColors;
  final scheme = Theme.of(context).colorScheme;
  return switch (status.toUpperCase()) {
    'COMPLETED' => (colors.statusActive, 'Done'),
    'SKIPPED' => (scheme.error, 'Skipped'),
    'PENDING' => (scheme.primary, 'Follow-up'),
    _ => (colors.textSecondary, 'Planned'),
  };
}

/// Reusable card for one visit-plan stop. Shows sequence number, time slot,
/// farmer name, purpose chip, village, last-visit note (2 lines), follow-up
/// badge, and a status indicator.
class PlanItemCard extends StatelessWidget {
  const PlanItemCard({
    super.key,
    required this.item,
    required this.index,
    this.trailing,
    this.onTap,
    this.onStartVisit,
  });

  final PlanItem item;
  final int index;

  /// Optional trailing widget (e.g. a drag handle on the reorderable list).
  final Widget? trailing;
  final VoidCallback? onTap;

  /// When set, a "Start Visit" button is shown that launches the visit flow.
  final VoidCallback? onStartVisit;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final scheme = Theme.of(context).colorScheme;
    final (statusColor, statusLabel) = _statusMeta(context, item.status);

    return AppCard(
      onTap: onTap,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Sequence number bubble.
          Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.16),
              shape: BoxShape.circle,
            ),
            child: Text(
              '${index + 1}',
              style: AppTextStyles.caption
                  .copyWith(color: scheme.primary, fontWeight: FontWeight.w700),
            ),
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
                      Icon(Icons.schedule_rounded,
                          size: 13, color: colors.textSecondary),
                      const SizedBox(width: 3),
                      Text(
                        item.timeLabel!,
                        style: AppTextStyles.caption.copyWith(
                            color: colors.textSecondary,
                            fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(width: AppDimens.grid),
                    ],
                    Expanded(
                      child: Text(
                        item.farmerName,
                        style: AppTextStyles.bodyMedium
                            .copyWith(color: scheme.onSurface),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (item.isFollowUp) ...[
                      const SizedBox(width: AppDimens.grid * 0.5),
                      Icon(Icons.notifications_active_rounded,
                          size: 16, color: scheme.secondary),
                    ],
                  ],
                ),
                const SizedBox(height: AppDimens.grid * 0.75),
                Row(
                  children: [
                    _chip(context, purposeLabel(item.purpose),
                        scheme.secondary),
                    const SizedBox(width: AppDimens.grid * 0.75),
                    if (item.leadStatus != null)
                      LeadStatusBadge(status: item.leadStatus),
                    const Spacer(),
                    _statusDot(statusColor, statusLabel),
                  ],
                ),
                if (item.village != null && item.village!.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(Icons.place_rounded,
                          size: 12, color: colors.textSecondary),
                      const SizedBox(width: 3),
                      Expanded(
                        child: Text(
                          item.village!,
                          style: AppTextStyles.caption
                              .copyWith(color: colors.textSecondary),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
                if (item.lastVisitNote != null &&
                    item.lastVisitNote!.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Last note: ${item.lastVisitNote!}',
                    style: AppTextStyles.caption
                        .copyWith(color: colors.textSecondary),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                if (onStartVisit != null) ...[
                  const SizedBox(height: AppDimens.grid * 0.5),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: onStartVisit,
                      icon: const Icon(Icons.play_arrow_rounded, size: 18),
                      label: const Text('Start Visit'),
                      style: TextButton.styleFrom(
                        foregroundColor: scheme.primary,
                        padding: const EdgeInsets.symmetric(
                            horizontal: AppDimens.grid),
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: AppDimens.grid * 0.5),
            trailing!,
          ],
        ],
      ),
    );
  }

  Widget _chip(BuildContext context, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppDimens.grid, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: AppTextStyles.caption
            .copyWith(color: color, fontWeight: FontWeight.w600),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  Widget _statusDot(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: AppTextStyles.caption
              .copyWith(color: color, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}
