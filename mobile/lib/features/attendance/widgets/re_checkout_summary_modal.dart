import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/app_text_styles.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_card.dart';
import '../models/attendance.dart';
import 'work_summary_sheet.dart';

/// Shows a summary modal when checking out from a Re-Checked In session.
/// Displays all existing check-in/out timestamps, re-checkin time & remark,
/// and allows inputting the work summary before confirming final checkout.
/// Requires a reason if checking out post 7:00 PM (19:00).
Future<WorkSummaryResult?> showReCheckOutSummaryModal(
  BuildContext context, {
  required Attendance attendance,
}) {
  return showModalBottomSheet<WorkSummaryResult>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).cardColor,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => _ReCheckOutSummaryModal(attendance: attendance),
  );
}

class _ReCheckOutSummaryModal extends StatefulWidget {
  const _ReCheckOutSummaryModal({required this.attendance});
  final Attendance attendance;

  @override
  State<_ReCheckOutSummaryModal> createState() =>
      _ReCheckOutSummaryModalState();
}

class _ReCheckOutSummaryModalState extends State<_ReCheckOutSummaryModal> {
  final _workSummaryController = TextEditingController();
  final _lateReasonController = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _workSummaryController.dispose();
    _lateReasonController.dispose();
    super.dispose();
  }

  void _confirm() {
    final isLateCheckout = DateTime.now().hour >= 19;
    final workSummary = _workSummaryController.text.trim();
    final lateReason = _lateReasonController.text.trim();

    if (workSummary.length > 500) {
      setState(() => _error = 'Work summary must be 500 characters or less.');
      return;
    }

    if (isLateCheckout && lateReason.isEmpty) {
      setState(() => _error =
          'Please provide a reason for late checkout (required after 7:00 PM).');
      return;
    }

    Navigator.of(context).pop(
      WorkSummaryResult(
        workSummary: workSummary.isNotEmpty ? workSummary : null,
        lateCheckoutReason:
            isLateCheckout && lateReason.isNotEmpty ? lateReason : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final scheme = Theme.of(context).colorScheme;
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final timeFmt = DateFormat('hh:mm a');
    final isLateCheckout = DateTime.now().hour >= 19;

    // Extract sessions. There's exactly one START per day, so "first" is
    // correct for that — but END and RE_CHECKIN can each occur more than
    // once on a multi-cycle day (check out, re-check in, check out again,
    // re-check in again, ...). This modal summarizes the CURRENT cycle being
    // closed, so it needs the LAST checkout and the LAST re-check-in, not
    // the day's very first ones — firstWhere here would show a stale
    // checkout time and the wrong remark on a 2nd+ re-check-in.
    final sessions = widget.attendance.sessions;
    final initialCheckIn = sessions.firstWhere(
      (s) => s.type == SessionType.start,
      orElse: () => sessions.first,
    );
    final initialCheckOut = sessions.lastWhere(
      (s) => s.type == SessionType.end,
      orElse: () => sessions.last,
    );
    final reCheckIn = sessions.lastWhere(
      (s) => s.type == SessionType.reCheckIn,
      orElse: () => sessions.last,
    );

    return SingleChildScrollView(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          AppDimens.grid * 2,
          AppDimens.grid * 2,
          AppDimens.grid * 2,
          AppDimens.grid * 2 + bottomInset,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: scheme.error.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.logout_rounded, color: scheme.error),
                ),
                const SizedBox(width: AppDimens.grid * 1.5),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Confirm Final Checkout',
                        style: AppTextStyles.heading
                            .copyWith(color: scheme.onSurface, fontSize: 18),
                      ),
                      Text(
                        'Review today\'s session timeline before checking out.',
                        style: AppTextStyles.caption
                            .copyWith(color: colors.textSecondary),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppDimens.grid * 2),

            // Timeline Card
            AppCard(
              child: Column(
                children: [
                  _TimelineRow(
                    icon: Icons.login_rounded,
                    iconColor: colors.statusActive,
                    label: 'Initial Check-In',
                    time: timeFmt.format(initialCheckIn.timestamp.toLocal()),
                  ),
                  const Divider(height: 16),
                  _TimelineRow(
                    icon: Icons.logout_rounded,
                    iconColor: colors.statusOffline,
                    label: 'Initial Check-Out',
                    time: timeFmt.format(initialCheckOut.timestamp.toLocal()),
                  ),
                  const Divider(height: 16),
                  _TimelineRow(
                    icon: Icons.replay_rounded,
                    iconColor: scheme.primary,
                    label: 'Re-Check In',
                    time: timeFmt.format(reCheckIn.timestamp.toLocal()),
                    subtitle: reCheckIn.notes?.isNotEmpty == true
                        ? 'Remark: ${reCheckIn.notes}'
                        : null,
                  ),
                  const Divider(height: 16),
                  _TimelineRow(
                    icon: Icons.stop_circle_rounded,
                    iconColor: scheme.error,
                    label: 'Final Check-Out',
                    time: timeFmt.format(DateTime.now()),
                    isCurrent: true,
                  ),
                ],
              ),
            ),

            const SizedBox(height: AppDimens.grid * 2),

            // Work Summary Field
            TextField(
              controller: _workSummaryController,
              minLines: 2,
              maxLines: 4,
              style: AppTextStyles.body.copyWith(color: scheme.onSurface),
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
              decoration: InputDecoration(
                hintText:
                    'Work Summary (Optional, summarizing your evening session)...',
                errorText: _error,
              ),
            ),

            // ── Mandatory Late Checkout Reason Field (Post 7:00 PM) ─────
            if (isLateCheckout) ...[
              const SizedBox(height: AppDimens.grid * 2),
              Container(
                padding: const EdgeInsets.all(AppDimens.grid * 1.5),
                decoration: BoxDecoration(
                  color: scheme.error.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(AppDimens.cardRadius),
                  border:
                      Border.all(color: scheme.error.withValues(alpha: 0.3)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.schedule_rounded, color: scheme.error, size: 20),
                    const SizedBox(width: AppDimens.grid * 1.5),
                    Expanded(
                      child: Text(
                        'Late Checkout Notice: Checking out post 7:00 PM requires a reason.',
                        style: AppTextStyles.caption.copyWith(
                          color: scheme.error,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppDimens.grid * 1.5),
              TextField(
                controller: _lateReasonController,
                minLines: 2,
                maxLines: 3,
                style: AppTextStyles.body.copyWith(color: scheme.onSurface),
                onChanged: (_) {
                  if (_error != null) setState(() => _error = null);
                },
                decoration: const InputDecoration(
                  labelText: 'Reason for Late Checkout *',
                  hintText: 'e.g. Extended client visit, site delay…',
                ),
              ),
            ],

            const SizedBox(height: AppDimens.grid * 2),

            Row(
              children: [
                Expanded(
                  child: AppButton(
                    label: 'Cancel',
                    variant: AppButtonVariant.secondary,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ),
                const SizedBox(width: AppDimens.grid * 1.5),
                Expanded(
                  child: AppButton(
                    label: 'Confirm Checkout',
                    variant: AppButtonVariant.danger,
                    onPressed: _confirm,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TimelineRow extends StatelessWidget {
  const _TimelineRow({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.time,
    this.subtitle,
    this.isCurrent = false,
  });

  final IconData icon;
  final Color iconColor;
  final String label;
  final String time;
  final String? subtitle;
  final bool isCurrent;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final scheme = Theme.of(context).colorScheme;

    return Row(
      children: [
        Icon(icon, size: 20, color: iconColor),
        const SizedBox(width: AppDimens.grid * 1.5),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: AppTextStyles.bodyMedium.copyWith(
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface,
                ),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(
                  subtitle!,
                  style: AppTextStyles.caption
                      .copyWith(color: colors.textSecondary),
                ),
              ],
            ],
          ),
        ),
        Text(
          time,
          style: AppTextStyles.body.copyWith(
            fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
            color: isCurrent ? scheme.error : colors.textSecondary,
          ),
        ),
      ],
    );
  }
}
