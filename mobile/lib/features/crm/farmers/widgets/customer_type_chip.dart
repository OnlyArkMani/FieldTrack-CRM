import 'package:flutter/material.dart';

import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../models/farmer.dart';

class CustomerTypeChip extends StatelessWidget {
  const CustomerTypeChip({super.key, required this.type});
  final CustomerType type;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final scheme = Theme.of(context).colorScheme;
    final color = switch (type) {
      CustomerType.farmer => colors.statusActive,
      CustomerType.fpo => scheme.primary,
      CustomerType.vlcc => scheme.secondary,
      CustomerType.retailer => colors.statusLowBattery,
      CustomerType.distributor => scheme.tertiary,
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        type.label,
        style: AppTextStyles.caption.copyWith(
          color: color,
          fontWeight: FontWeight.w700,
          fontSize: 10,
        ),
      ),
    );
  }
}
