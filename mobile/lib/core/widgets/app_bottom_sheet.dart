import 'package:flutter/material.dart';

import '../theme/app_text_styles.dart';
import '../theme/app_theme.dart';

/// Standard bottom sheet: 24px top radius, drag handle, theme-aware.
/// Usage: AppBottomSheet.show(context, title: ..., child: ...)
class AppBottomSheet {
  AppBottomSheet._();

  static Future<T?> show<T>(
    BuildContext context, {
    required Widget child,
    String? title,
    bool isDismissible = true,

    /// 0..1 fractions for the draggable sheet.
    double initialSize = 0.5,
    double minSize = 0.3,
    double maxSize = 0.92,
  }) {
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      isDismissible: isDismissible,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final colors = context.appColors;
        return DraggableScrollableSheet(
          initialChildSize: initialSize,
          minChildSize: minSize,
          maxChildSize: maxSize,
          expand: false,
          builder: (context, scrollController) {
            return Container(
              decoration: BoxDecoration(
                color: colors.card,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(AppDimens.sheetRadius),
                ),
              ),
              child: SafeArea(
                top: false,
                child: Column(
                  children: [
                    // Drag handle
                    Container(
                      margin:
                          const EdgeInsets.only(top: AppDimens.grid * 1.5),
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: colors.textSecondary.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    if (title != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          AppDimens.grid * 2,
                          AppDimens.grid * 2,
                          AppDimens.grid * 2,
                          AppDimens.grid,
                        ),
                        child: Text(
                          title,
                          style: AppTextStyles.heading.copyWith(
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    Expanded(
                      child: ListView(
                        controller: scrollController,
                        physics: const ClampingScrollPhysics(),
                        padding: const EdgeInsets.all(AppDimens.grid * 2),
                        children: [child],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}
