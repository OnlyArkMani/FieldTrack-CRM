import 'package:flutter/material.dart';

import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';

/// 4-step progress header for the guided visit form.
/// - active   : amber filled circle with the step number
/// - completed: green circle with a checkmark
/// - upcoming : grey outlined circle
/// Transitions animate (color + the connecting bar fill).
class StepIndicator extends StatelessWidget {
  const StepIndicator({
    super.key,
    required this.current, // 1..4 (0 = pre-check-in, nothing highlighted)
    this.labels = const ['Notes', 'Livestock', 'Order', 'Lead'],
  });

  final int current;
  final List<String> labels;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: AppDimens.grid * 2, vertical: AppDimens.grid * 1.5),
      child: Row(
        children: [
          for (var i = 0; i < labels.length; i++) ...[
            _StepCircle(
              index: i + 1,
              label: labels[i],
              state: _stateFor(i + 1),
            ),
            if (i < labels.length - 1)
              Expanded(
                child: Container(
                  height: 2,
                  margin: const EdgeInsets.only(bottom: 16),
                  color: (i + 1) < current
                      ? colors.statusActive
                      : colors.textSecondary.withValues(alpha: 0.2),
                ),
              ),
          ],
        ],
      ),
    );
  }

  _StepState _stateFor(int step) {
    if (step < current) return _StepState.completed;
    if (step == current) return _StepState.active;
    return _StepState.upcoming;
  }
}

enum _StepState { active, completed, upcoming }

class _StepCircle extends StatelessWidget {
  const _StepCircle({
    required this.index,
    required this.label,
    required this.state,
  });

  final int index;
  final String label;
  final _StepState state;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final scheme = Theme.of(context).colorScheme;

    final (Color bg, Widget child) = switch (state) {
      _StepState.active => (
          scheme.primary,
          Text('$index',
              style: AppTextStyles.caption.copyWith(
                  color: scheme.onPrimary, fontWeight: FontWeight.w700)),
        ),
      _StepState.completed => (
          colors.statusActive,
          const Icon(Icons.check_rounded, size: 16, color: Colors.white),
        ),
      _StepState.upcoming => (
          colors.card,
          Text('$index',
              style: AppTextStyles.caption
                  .copyWith(color: colors.textSecondary)),
        ),
    };

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOutCubic,
          width: 30,
          height: 30,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: bg,
            shape: BoxShape.circle,
            border: state == _StepState.upcoming
                ? Border.all(
                    color: colors.textSecondary.withValues(alpha: 0.3))
                : null,
          ),
          child: child,
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: AppTextStyles.caption.copyWith(
            color: state == _StepState.active
                ? scheme.primary
                : colors.textSecondary,
            fontWeight:
                state == _StepState.active ? FontWeight.w700 : FontWeight.w400,
            fontSize: 10,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}
