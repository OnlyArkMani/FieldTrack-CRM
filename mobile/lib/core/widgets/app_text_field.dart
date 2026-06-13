import 'package:flutter/material.dart';

import '../theme/app_text_styles.dart';
import '../theme/app_theme.dart';

/// Standard text input. Styling flows from InputDecorationTheme in
/// app_theme.dart — this widget only adds behavior (obscure toggle, etc.).
class AppTextField extends StatelessWidget {
  const AppTextField({
    super.key,
    required this.label,
    this.controller,
    this.hint,
    this.errorText,
    this.obscureText = false,
    this.prefixIcon,
    this.suffixIcon,
    this.onSuffixTap,
    this.keyboardType,
    this.textInputAction,
    this.onSubmitted,
    this.enabled = true,
    this.autofillHints,
  });

  final String label;
  final TextEditingController? controller;
  final String? hint;
  final String? errorText;
  final bool obscureText;
  final IconData? prefixIcon;
  final IconData? suffixIcon;
  final VoidCallback? onSuffixTap;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;
  final bool enabled;
  final Iterable<String>? autofillHints;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: AppTextStyles.bodyMedium
              .copyWith(color: Theme.of(context).colorScheme.onSurface),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: AppDimens.grid),
        TextField(
          controller: controller,
          obscureText: obscureText,
          enabled: enabled,
          keyboardType: keyboardType,
          textInputAction: textInputAction,
          onSubmitted: onSubmitted,
          autofillHints: autofillHints,
          style: AppTextStyles.body
              .copyWith(color: Theme.of(context).colorScheme.onSurface),
          decoration: InputDecoration(
            hintText: hint,
            errorText: errorText,
            errorMaxLines: 2,
            prefixIcon: prefixIcon != null
                ? Icon(prefixIcon, size: 20, color: colors.textSecondary)
                : null,
            suffixIcon: suffixIcon != null
                ? IconButton(
                    icon: Icon(suffixIcon, size: 20, color: colors.textSecondary),
                    onPressed: onSuffixTap,
                  )
                : null,
          ),
        ),
      ],
    );
  }
}
