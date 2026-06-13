import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Standard card: 12px radius, soft 4px/8% shadow, theme-driven background.
/// AnimatedContainer so any color/size state change animates for free.
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppDimens.grid * 2),
    this.color,
    this.onTap,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  /// Override for state-colored cards (e.g. alert tint); defaults to theme.
  final Color? color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final card = AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOutCubic,
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? context.appColors.card,
        borderRadius: BorderRadius.circular(AppDimens.cardRadius),
        boxShadow: AppDimens.shadow(Theme.of(context).brightness),
      ),
      child: child,
    );

    if (onTap == null) return card;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppDimens.cardRadius),
        onTap: onTap,
        child: card,
      ),
    );
  }
}
