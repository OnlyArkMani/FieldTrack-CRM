import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_text_styles.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_card.dart';
import '../models/attendance.dart';
import '../providers/attendance_provider.dart';

/// Compact checked-in/checked-out indicator for the home dashboard. The
/// Attendance tab owns the full START/BREAK/RESUME/END flow; this just
/// answers "am I clocked in right now?" at a glance and jumps there on tap.
class AttendanceStatusTile extends ConsumerWidget {
  const AttendanceStatusTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ui = ref.watch(attendanceProvider);
    final colors = context.appColors;
    final scheme = Theme.of(context).colorScheme;

    final (Color tint, IconData icon, String label, String subtitle) =
        switch (ui.state) {
      MachineState.started ||
      MachineState.resumed =>
        (
          colors.statusActive,
          Icons.play_circle_fill_rounded,
          'Checked in',
          'Working since ${_hhmm(ui.attendance?.startedAt)}',
        ),
      MachineState.onBreak => (
          colors.statusIdle,
          Icons.pause_circle_filled_rounded,
          'On break',
          'Checked in — currently on break',
        ),
      MachineState.ended => (
          colors.statusOffline,
          Icons.check_circle_rounded,
          'Checked out',
          "Day complete",
        ),
      MachineState.none => (
          colors.statusOffline,
          Icons.radio_button_unchecked_rounded,
          'Not checked in',
          'Tap to start your day',
        ),
    };

    return AppCard(
      onTap: () => context.go('/home/attendance'),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: tint.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(AppDimens.buttonRadius),
            ),
            child: Icon(icon, size: 22, color: tint),
          ),
          const SizedBox(width: AppDimens.grid * 1.5),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style:
                      AppTextStyles.bodyMedium.copyWith(color: scheme.onSurface),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: AppTextStyles.caption
                      .copyWith(color: colors.textSecondary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_right_rounded, color: colors.textSecondary),
        ],
      ),
    );
  }
}

String _hhmm(DateTime? dt) {
  if (dt == null) return '--:--';
  final l = dt.toLocal();
  return '${l.hour.toString().padLeft(2, '0')}:'
      '${l.minute.toString().padLeft(2, '0')}';
}
