import 'package:flutter/material.dart';

import '../../../core/theme/app_text_styles.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_button.dart';

/// Shows a modal bottom sheet prompting the user for a mandatory remark when
/// performing a Re-Check In. Returns the remark string or `null` if cancelled.
Future<String?> showReCheckInRemarkSheet(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).cardColor,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => const _ReCheckInRemarkSheet(),
  );
}

class _ReCheckInRemarkSheet extends StatefulWidget {
  const _ReCheckInRemarkSheet();

  @override
  State<_ReCheckInRemarkSheet> createState() => _ReCheckInRemarkSheetState();
}

class _ReCheckInRemarkSheetState extends State<_ReCheckInRemarkSheet> {
  final _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    if (text.length < 5) {
      setState(() => _error = 'Remark must be at least 5 characters long');
      return;
    }
    Navigator.of(context).pop(text);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final scheme = Theme.of(context).colorScheme;
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
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
                  color: scheme.primary.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.replay_rounded, color: scheme.primary),
              ),
              const SizedBox(width: AppDimens.grid * 1.5),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Re-Check In',
                      style: AppTextStyles.heading
                          .copyWith(color: scheme.onSurface, fontSize: 18),
                    ),
                    Text(
                      'Please provide a mandatory remark to re-check in.',
                      style: AppTextStyles.caption
                          .copyWith(color: colors.textSecondary),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppDimens.grid * 2),
          TextField(
            controller: _controller,
            autofocus: true,
            minLines: 2,
            maxLines: 4,
            style: AppTextStyles.body.copyWith(color: scheme.onSurface),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            decoration: InputDecoration(
              hintText: 'Remark (Required, e.g. Returning for evening shift)',
              errorText: _error,
            ),
          ),
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
                  label: 'Re-Check In',
                  onPressed: _submit,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
