import 'package:flutter/material.dart';

import '../../../core/theme/app_text_styles.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_button.dart';

const _kMaxChars = 500;

class WorkSummaryResult {
  const WorkSummaryResult({this.workSummary, this.lateCheckoutReason});
  final String? workSummary;
  final String? lateCheckoutReason;
}

/// Work-summary capture on END. Non-dismissible by barrier tap or drag — the
/// user must submit or explicitly Cancel. Returns WorkSummaryResult on submit,
/// or null on cancel. If checking out post 7:00 PM (19:00), requires a reason.
Future<WorkSummaryResult?> showWorkSummarySheet(BuildContext context) {
  return showModalBottomSheet<WorkSummaryResult>(
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
  final _lateReasonController = TextEditingController();

  late final AnimationController _spring = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  )..forward();

  @override
  void initState() {
    super.initState();
    _controller.addListener(() => setState(() {}));
    _lateReasonController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _controller.dispose();
    _lateReasonController.dispose();
    _spring.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final scheme = Theme.of(context).colorScheme;
    final isLateCheckout = DateTime.now().hour >= 19;

    final overLimit = _controller.text.characters.length > _kMaxChars;
    final lateReasonProvided =
        !isLateCheckout || _lateReasonController.text.trim().isNotEmpty;
    final canSubmit = !overLimit && lateReasonProvided;

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
            child: SingleChildScrollView(
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
                    'What did you accomplish today? (Optional)',
                    style: AppTextStyles.body.copyWith(color: colors.textSecondary),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: AppDimens.grid * 2),
                  TextField(
                    controller: _controller,
                    autofocus: !isLateCheckout,
                    maxLines: 5,
                    minLines: 3,
                    maxLength: _kMaxChars,
                    textCapitalization: TextCapitalization.sentences,
                    style: AppTextStyles.body.copyWith(color: scheme.onSurface),
                    decoration: const InputDecoration(
                      hintText: 'e.g. Completed 12 site inspections in the north zone…',
                      alignLabelWithHint: true,
                      counterText: '',
                    ),
                  ),
                  const SizedBox(height: AppDimens.grid),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Work summary is optional',
                          style: AppTextStyles.caption.copyWith(
                            color: colors.textSecondary,
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

                  // ── Mandatory Late Checkout Reason (Post 7:00 PM) ──────
                  if (isLateCheckout) ...[
                    const SizedBox(height: AppDimens.grid * 2.5),
                    Container(
                      padding: const EdgeInsets.all(AppDimens.grid * 1.5),
                      decoration: BoxDecoration(
                        color: scheme.error.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(AppDimens.cardRadius),
                        border: Border.all(color: scheme.error.withValues(alpha: 0.3)),
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
                    Text(
                      'Reason for Late Checkout *',
                      style: AppTextStyles.body.copyWith(
                        color: scheme.onSurface,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: AppDimens.grid * 0.5),
                    TextField(
                      controller: _lateReasonController,
                      autofocus: isLateCheckout,
                      maxLines: 2,
                      minLines: 2,
                      maxLength: 200,
                      textCapitalization: TextCapitalization.sentences,
                      style: AppTextStyles.body.copyWith(color: scheme.onSurface),
                      decoration: InputDecoration(
                        hintText: 'e.g. Overtime site visit, delayed customer meeting…',
                        alignLabelWithHint: true,
                        counterText: '',
                        errorText: isLateCheckout &&
                                _lateReasonController.text.isEmpty &&
                                _controller.text.isNotEmpty
                            ? 'Reason required for post 7:00 PM checkout'
                            : null,
                      ),
                    ),
                  ],

                  const SizedBox(height: AppDimens.grid * 2.5),
                  AppButton(
                    label: 'End day & submit',
                    icon: Icons.check_rounded,
                    onPressed: canSubmit
                        ? () {
                            final workSummary = _controller.text.trim();
                            final lateReason =
                                _lateReasonController.text.trim();
                            Navigator.of(context).pop(
                              WorkSummaryResult(
                                workSummary: workSummary.isNotEmpty
                                    ? workSummary
                                    : null,
                                lateCheckoutReason:
                                    isLateCheckout && lateReason.isNotEmpty
                                        ? lateReason
                                        : null,
                              ),
                            );
                          }
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
