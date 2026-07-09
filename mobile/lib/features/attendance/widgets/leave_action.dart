import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/attendance_provider.dart';

/// Shared "apply for leave" flow used by both the home dashboard tile and
/// the full Attendance screen. `restrictToFuture` must be true whenever
/// today already has an attendance row (checked in/out, or already on
/// leave) — the backend rejects a leave request for a date that's already
/// claimed, so today is not a selectable option in that case.
Future<void> applyForLeave(
  BuildContext context,
  WidgetRef ref, {
  required bool restrictToFuture,
}) async {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final firstDate = restrictToFuture ? today.add(const Duration(days: 1)) : today;
  final picked = await showDatePicker(
    context: context,
    initialDate: firstDate,
    firstDate: firstDate,
    lastDate: today.add(const Duration(days: 90)),
    helpText: 'Select leave date',
  );
  if (picked == null || !context.mounted) return;
  final isToday = picked == today;

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(isToday
          ? 'Mark today as on leave?'
          : 'Mark ${picked.day}/${picked.month}/${picked.year} as on leave?'),
      content: Text(
        isToday
            ? "You won't be able to check in today after marking leave."
            : "If you have planned visits on that date you'll need to "
                'reschedule or skip them first.',
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
  await ref
      .read(attendanceProvider.notifier)
      .markLeave(date: isToday ? null : picked);
}
