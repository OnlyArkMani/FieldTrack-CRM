import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'app_button.dart';

/// Standard confirmation dialog. Returns true if confirmed.
/// Destructive actions pass `danger: true` (coral confirm button).
Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Confirm',
  String cancelLabel = 'Cancel',
  bool danger = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
      content: Text(message, maxLines: 4, overflow: TextOverflow.ellipsis),
      actionsPadding: const EdgeInsets.all(AppDimens.grid * 2),
      actions: [
        Row(
          children: [
            Expanded(
              child: AppButton(
                label: cancelLabel,
                variant: AppButtonVariant.secondary,
                onPressed: () => Navigator.of(context).pop(false),
              ),
            ),
            const SizedBox(width: AppDimens.grid * 1.5),
            Expanded(
              child: AppButton(
                label: confirmLabel,
                variant: danger
                    ? AppButtonVariant.danger
                    : AppButtonVariant.primary,
                onPressed: () => Navigator.of(context).pop(true),
              ),
            ),
          ],
        ),
      ],
    ),
  );
  return result ?? false;
}
