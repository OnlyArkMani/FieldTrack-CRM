import 'package:flutter/material.dart';

import '../theme/app_text_styles.dart';
import '../theme/app_theme.dart';

enum EmployeeStatus { active, idle, offline, gpsDisabled, lowBattery, noInternet }

/// Colored pill for live-status display. Color logic lives HERE, once.
class StatusBadge extends StatelessWidget {
  const StatusBadge({super.key, required this.status, this.compact = false});

  final EmployeeStatus status;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;

    final (Color color, String label) = switch (status) {
      EmployeeStatus.active => (colors.statusActive, 'Active'),
      EmployeeStatus.idle => (colors.statusIdle, 'Idle'),
      EmployeeStatus.offline => (colors.statusOffline, 'Offline'),
      EmployeeStatus.gpsDisabled => (colors.statusGpsDisabled, 'GPS Off'),
      EmployeeStatus.lowBattery => (colors.statusLowBattery, 'Low Battery'),
      EmployeeStatus.noInternet => (colors.statusOffline, 'No Internet'),
    };

    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOutCubic,
      padding: EdgeInsets.symmetric(
        horizontal: compact ? AppDimens.grid : AppDimens.grid * 1.5,
        vertical: compact ? 2 : AppDimens.grid * 0.5,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: AppDimens.grid * 0.75),
          Flexible(
            child: Text(
              label,
              style: AppTextStyles.caption.copyWith(
                color: color,
                fontWeight: FontWeight.w500,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
