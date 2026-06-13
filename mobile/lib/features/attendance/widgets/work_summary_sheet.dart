import 'package:flutter/material.dart';

import '../../../core/theme/app_text_styles.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_button.dart';

const _kMinChars = 10;
const _kMaxChars = 500;

/// Work-summary capture on END. Non-dismissible by barrier tap or drag — the
/// user must either submit (≥10 chars) or explicitly Cancel. Returns the
/// summary string on submit, or null on cancel.
Future<String?> showWorkSummarySheet(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    isDismissible: false, // can't tap-away
    enableDrag: false, // can't swipe-away
    backgroundColor: Colors.transparent,
    builder: (_) => const _WorkSummarySheet(),
  );
}

class _WorkSummarySheet extends StatefulWidget {
  const _WorkSummarySheet();

  @override
  State<_WorkSummarySheet> createState() => _WorkSummarySheetState();
}

class _WorkSummarySheetState extends State<_WorkSummarySheet>
    with SingleTickerProviderStateMixin {
  final _controller = TextEditingController();
  late final AnimationController _spring = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  )..forward();

  @override
  void initState() {
    super.initState();
    _controller.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _controller.dispose();
    _spring.dispose();
    super.dispose();
  }

  int get _len => _controller.text.trim().length;
  bool get _valid => _len >= _kMinChars;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final scheme = Theme.of(context).colorScheme;
    final overLimit = _controller.text.characters.length > _kMaxChars;

    // Spring slide-up + slight overshoot on entrance.
    final curved = CurvedAnimation(parent: _spring, curve: Curves.easeOutBack);

    return AnimatedPadding(
      duration: const Duration(milliseconds: 150),
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 1),
          end: Offset.zero,
        ).animate(curved),
        child: Container(
          decoration: BoxDecoration(
            color: colors.card,
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(AppDimens.sheetRadius),
            ),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(AppDimens.grid * 3),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: colors.textSecondary.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: AppDimens.grid * 2.5),
                  Text(
                    'Wrap up your day',
                    style: AppTextStyles.heading.copyWith(color: scheme.onSurface),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: AppDimens.grid * 0.5),
                  Text(
                    'What did you accomplish today?',
                    style: AppTextStyles.body.copyWith(color: colors.textSecondary),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: AppDimens.grid * 2),
                  TextField(
                    controller: _controller,
                    autofocus: true,
                    maxLines: 5,
                    minLines: 3,
                    maxLength: _kMaxChars,
                    textCapitalization: TextCapitalization.sentences,
                    style: AppTextStyles.body.copyWith(color: scheme.onSurface),
                    decoration: InputDecoration(
                      hintText: 'e.g. Completed 12 site inspections in the north zone…',
                      alignLabelWithHint: true,
                      counterText: '', // we render our own counter below
                    ),
                  ),
                  const SizedBox(height: AppDimens.grid),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _valid
                              ? 'Looks good'
                              : 'At least ${_kMinChars - _len} more character'
                                  '${(_kMinChars - _len) == 1 ? '' : 's'}',
                          style: AppTextStyles.caption.copyWith(
                            color: _valid ? colors.statusActive : colors.textSecondary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        '${_controller.text.characters.length}/$_kMaxChars',
                        style: AppTextStyles.caption.copyWith(
                          color: overLimit ? scheme.error : colors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppDimens.grid * 2.5),
                  AppButton(
                    label: 'End day & submit',
                    icon: Icons.check_rounded,
                    onPressed: (_valid && !overLimit)
                        ? () => Navigator.of(context).pop(_controller.text.trim())
                        : null,
                  ),
                  const SizedBox(height: AppDimens.grid),
                  AppButton(
                    label: 'Cancel',
                    variant: AppButtonVariant.secondary,
                    onPressed: () => Navigator.of(context).pop(null),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
