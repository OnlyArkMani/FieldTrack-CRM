import 'package:flutter/material.dart';

import '../theme/app_text_styles.dart';
import '../theme/app_theme.dart';

enum AppButtonVariant { primary, secondary, danger }

/// The ONLY button in the app. Loading + disabled states are mandatory by
/// construction; press feedback is a 0.96 scale with spring-back.
class AppButton extends StatefulWidget {
  const AppButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.variant = AppButtonVariant.primary,
    this.isLoading = false,
    this.expanded = true,
    this.icon,
  });

  final String label;

  /// null => disabled.
  final VoidCallback? onPressed;
  final AppButtonVariant variant;

  /// true => spinner, taps ignored.
  final bool isLoading;
  final bool expanded;
  final IconData? icon;

  @override
  State<AppButton> createState() => _AppButtonState();
}

class _AppButtonState extends State<AppButton> {
  bool _pressed = false;

  bool get _enabled => widget.onPressed != null && !widget.isLoading;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    final (Color bg, Color fg) = switch (widget.variant) {
      AppButtonVariant.primary => (scheme.primary, scheme.onPrimary),
      AppButtonVariant.secondary => (scheme.secondary, scheme.onSecondary),
      AppButtonVariant.danger => (scheme.error, scheme.onError),
    };

    return GestureDetector(
      onTapDown: _enabled ? (_) => setState(() => _pressed = true) : null,
      onTapUp: _enabled ? (_) => setState(() => _pressed = false) : null,
      onTapCancel: _enabled ? () => setState(() => _pressed = false) : null,
      onTap: _enabled ? widget.onPressed : null,
      child: AnimatedScale(
        scale: _pressed ? 0.96 : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOutBack, // spring-back on release
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOutCubic,
          width: widget.expanded ? double.infinity : null,
          padding: const EdgeInsets.symmetric(
            horizontal: AppDimens.grid * 3,
            vertical: AppDimens.grid * 1.75,
          ),
          decoration: BoxDecoration(
            color: _enabled ? bg : bg.withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(AppDimens.buttonRadius),
            boxShadow: _enabled
                ? AppDimens.shadow(Theme.of(context).brightness)
                : null,
          ),
          child: Row(
            mainAxisSize:
                widget.expanded ? MainAxisSize.max : MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (widget.isLoading) ...[
                SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.2,
                    valueColor: AlwaysStoppedAnimation(fg),
                  ),
                ),
                const SizedBox(width: AppDimens.grid * 1.5),
              ] else if (widget.icon != null) ...[
                Icon(widget.icon, size: 18, color: fg),
                const SizedBox(width: AppDimens.grid),
              ],
              Flexible(
                child: Text(
                  widget.label,
                  style: AppTextStyles.button.copyWith(color: fg),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
