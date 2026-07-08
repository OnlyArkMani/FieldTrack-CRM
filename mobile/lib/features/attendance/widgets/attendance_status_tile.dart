import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_text_styles.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_card.dart';
import '../../../services/permission/permission_service.dart';
import '../models/attendance.dart';
import '../providers/attendance_provider.dart';
import '../widgets/attendance_timer.dart';
import '../widgets/work_summary_sheet.dart';

/// Dashboard attendance control. Not checked in => Check In / On Leave
/// buttons; checked in (incl. on break) => a running timer + Checkout;
/// checked out => a total-hours badge that opens the full Attendance tab.
/// The Attendance tab still owns the full START/BREAK/RESUME/END flow and
/// history — this drives the same day's state machine from the home screen.
class AttendanceStatusTile extends ConsumerWidget {
  const AttendanceStatusTile({super.key});

  Future<void> _checkIn(BuildContext context, WidgetRef ref) async {
    final result =
        await PermissionService.instance.requestLocationPermissions(context);
    if (result == PermissionResult.denied ||
        result == PermissionResult.deniedForever) {
      return; // PermissionService already showed the messaging.
    }
    await ref.read(attendanceProvider.notifier).start();
  }

  Future<void> _checkOut(BuildContext context, WidgetRef ref) async {
    final summary = await showWorkSummarySheet(context);
    if (summary == null || !context.mounted) return;
    await ref.read(attendanceProvider.notifier).end(summary);
    if (!context.mounted) return;
    final state = ref.read(attendanceProvider);
    final attendanceId = state.attendance?.id;
    if (attendanceId != null && state.state == MachineState.ended) {
      final today = DateTime.now();
      final reportDate = DateTime(today.year, today.month, today.day);
      // Give the background DSR generation a moment to complete before loading.
      await Future<void>.delayed(const Duration(seconds: 2));
      if (!context.mounted) return;
      context.push('/dsr/review', extra: {'report_date': reportDate});
    }
  }

  Future<void> _markLeave(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Mark today as on leave?'),
        content: const Text(
          "You won't be able to check in today after marking leave.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Mark leave'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    await ref.read(attendanceProvider.notifier).markLeave();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ui = ref.watch(attendanceProvider);
    final colors = context.appColors;

    return switch (ui.state) {
      MachineState.none => AppCard(
          child: Row(
            children: [
              Expanded(
                child: AppButton(
                  label: 'Check In',
                  icon: Icons.login_rounded,
                  isLoading: ui.isSubmitting,
                  onPressed: ui.isSubmitting || ui.isMarkingLeave
                      ? null
                      : () => _checkIn(context, ref),
                ),
              ),
              const SizedBox(width: AppDimens.grid * 1.5),
              Expanded(
                child: AppButton(
                  label: 'On Leave',
                  variant: AppButtonVariant.secondary,
                  isLoading: ui.isMarkingLeave,
                  onPressed: ui.isSubmitting || ui.isMarkingLeave
                      ? null
                      : () => _markLeave(context, ref),
                ),
              ),
            ],
          ),
        ),
      MachineState.started || MachineState.resumed || MachineState.onBreak =>
        AppCard(
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Checked in',
                      style: AppTextStyles.caption.copyWith(
                        color: colors.textSecondary,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.3,
                      ),
                    ),
                    const SizedBox(height: 4),
                    AttendanceTimer(
                      start: ui.attendance?.startedAt ?? DateTime.now(),
                      fontSize: 26,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppDimens.grid * 1.5),
              AppButton(
                label: 'Checkout',
                icon: Icons.logout_rounded,
                variant: AppButtonVariant.danger,
                expanded: false,
                isLoading: ui.isSubmitting,
                onPressed:
                    ui.isSubmitting ? null : () => _checkOut(context, ref),
              ),
            ],
          ),
        ),
      MachineState.ended => _BadgeCard(
          icon: Icons.check_circle_rounded,
          tint: colors.statusOffline,
          label: 'Checked out',
          subtitle:
              'Total today: ${_fmtMinutes(ui.attendance?.totalDurationMinutes ?? 0)}',
        ),
      MachineState.onLeave => _BadgeCard(
          icon: Icons.beach_access_rounded,
          tint: colors.statusIdle,
          label: 'On leave',
          subtitle: 'Marked as on leave today',
        ),
    };
  }
}

/// Icon + label/subtitle badge, tappable through to the full Attendance tab
/// (chevron on the right makes that affordance explicit).
class _BadgeCard extends StatelessWidget {
  const _BadgeCard({
    required this.icon,
    required this.tint,
    required this.label,
    required this.subtitle,
  });

  final IconData icon;
  final Color tint;
  final String label;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final scheme = Theme.of(context).colorScheme;
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

String _fmtMinutes(int minutes) {
  if (minutes <= 0) return '0m';
  final h = minutes ~/ 60;
  final m = minutes % 60;
  if (h == 0) return '${m}m';
  return m == 0 ? '${h}h' : '${h}h ${m}m';
}
