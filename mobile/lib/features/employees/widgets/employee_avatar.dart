import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/app_text_styles.dart';
import '../../../core/theme/app_theme.dart';

/// Circular avatar with a cached network photo and an initials fallback.
/// Wrapped in a Hero so it flies from the list row to the detail header —
/// the tag is shared via [heroTag] (null disables the hero, e.g. in lists
/// where the same employee could appear twice).
class EmployeeAvatar extends StatelessWidget {
  const EmployeeAvatar({
    super.key,
    required this.initials,
    this.photoUrl,
    this.radius = 22,
    this.heroTag,
  });

  final String initials;
  final String? photoUrl;
  final double radius;
  final Object? heroTag;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final avatar = Container(
      width: radius * 2,
      height: radius * 2,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: scheme.secondary.withValues(alpha: 0.18),
      ),
      clipBehavior: Clip.antiAlias,
      alignment: Alignment.center,
      child: (photoUrl != null && photoUrl!.isNotEmpty)
          ? CachedNetworkImage(
              imageUrl: photoUrl!,
              width: radius * 2,
              height: radius * 2,
              fit: BoxFit.cover,
              placeholder: (_, __) => _initials(scheme),
              errorWidget: (_, __, ___) => _initials(scheme),
            )
          : _initials(scheme),
    );

    if (heroTag == null) return avatar;
    return Hero(tag: heroTag!, child: avatar);
  }

  Widget _initials(ColorScheme scheme) => Center(
        child: Text(
          initials,
          style: AppTextStyles.bodyMedium.copyWith(
            color: scheme.secondary,
            fontWeight: FontWeight.w600,
            fontSize: radius * 0.62,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      );
}

/// Small role pill (Admin / Supervisor / Employee).
class RoleBadge extends StatelessWidget {
  const RoleBadge({super.key, required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppDimens.grid,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: colors.textSecondary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: AppTextStyles.caption.copyWith(
          color: colors.textSecondary,
          fontWeight: FontWeight.w500,
          fontSize: 11,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}
