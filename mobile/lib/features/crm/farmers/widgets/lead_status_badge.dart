import 'package:flutter/material.dart';

import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../models/farmer.dart';

/// Colored pill for a farmer's lead status. Color mapping lives HERE, once:
///   Hot  -> coral  (scheme.error)
///   Warm -> amber  (scheme.primary)
///   Cold -> purple (scheme.secondary)
/// All theme-driven — no hardcoded hex.
Color leadStatusColor(BuildContext context, LeadStatus status) {
  final scheme = Theme.of(context).colorScheme;
  return switch (status) {
    LeadStatus.hot => scheme.error,
    LeadStatus.warm => scheme.primary,
    LeadStatus.cold => scheme.secondary,
  };
}

class LeadStatusBadge extends StatelessWidget {
  const LeadStatusBadge({
    super.key,
    required this.status,
    this.large = false,
  });

  final LeadStatus? status;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    if (status == null) {
      // "No lead set yet" — a muted, neutral chip.
      return _pill(
        context,
        color: colors.textSecondary,
        label: 'No lead',
      );
    }
    return _pill(
      context,
      color: leadStatusColor(context, status!),
      label: status!.label,
    );
  }

  Widget _pill(BuildContext context,
      {required Color color, required String label}) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: large ? AppDimens.grid * 2 : AppDimens.grid * 1.25,
        vertical: large ? AppDimens.grid : AppDimens.grid * 0.5,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: large ? 9 : 7,
            height: large ? 9 : 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          SizedBox(width: AppDimens.grid * 0.75),
          Flexible(
            child: Text(
              label,
              style: (large ? AppTextStyles.bodyMedium : AppTextStyles.caption)
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
