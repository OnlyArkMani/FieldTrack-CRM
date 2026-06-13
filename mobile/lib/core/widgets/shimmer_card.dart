import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';

import '../theme/app_theme.dart';

/// Loading placeholder. Lists show 3-5 of these instead of a spinner.
class ShimmerCard extends StatelessWidget {
  const ShimmerCard({super.key, this.height = 84, this.lines = 2});

  final double height;
  final int lines;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final base = colors.textSecondary.withValues(alpha: 0.12);
    final highlight = colors.textSecondary.withValues(alpha: 0.05);

    return Container(
      height: height,
      padding: const EdgeInsets.all(AppDimens.grid * 2),
      decoration: BoxDecoration(
        color: colors.card,
        borderRadius: BorderRadius.circular(AppDimens.cardRadius),
        boxShadow: AppDimens.shadow(Theme.of(context).brightness),
      ),
      child: Shimmer.fromColors(
        baseColor: base,
        highlightColor: highlight,
        period: const Duration(milliseconds: 1200),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: base,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: AppDimens.grid * 2),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: List.generate(lines, (i) {
                  final isLast = i == lines - 1;
                  return Padding(
                    padding: EdgeInsets.only(
                        bottom: isLast ? 0 : AppDimens.grid),
                    child: FractionallySizedBox(
                      widthFactor: isLast ? 0.5 : 0.85,
                      child: Container(
                        height: 12,
                        decoration: BoxDecoration(
                          color: base,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Named alias: a list-row shimmer (avatar + name + subtitle). Used on the
/// employee/team lists while the directory loads.
class EmployeeListItemShimmer extends StatelessWidget {
  const EmployeeListItemShimmer({super.key});

  @override
  Widget build(BuildContext context) => const ShimmerCard(height: 84, lines: 2);
}

/// Large placeholder for the attendance status card (timer + action row).
class AttendanceCardShimmer extends StatelessWidget {
  const AttendanceCardShimmer({super.key});

  @override
  Widget build(BuildContext context) => const ShimmerCard(height: 200, lines: 3);
}

/// Small square placeholder for dashboard stat tiles — no avatar circle, just
/// a label line and a big number line, sized to match StatCard.
class StatCardShimmer extends StatelessWidget {
  const StatCardShimmer({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final base = colors.textSecondary.withValues(alpha: 0.12);
    final highlight = colors.textSecondary.withValues(alpha: 0.05);

    return Container(
      height: 92,
      padding: const EdgeInsets.all(AppDimens.grid * 2),
      decoration: BoxDecoration(
        color: colors.card,
        borderRadius: BorderRadius.circular(AppDimens.cardRadius),
        boxShadow: AppDimens.shadow(Theme.of(context).brightness),
      ),
      child: Shimmer.fromColors(
        baseColor: base,
        highlightColor: highlight,
        period: const Duration(milliseconds: 1200),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(color: base, shape: BoxShape.circle),
            ),
            FractionallySizedBox(
              widthFactor: 0.5,
              child: Container(
                height: 16,
                decoration:
                    BoxDecoration(color: base, borderRadius: BorderRadius.circular(4)),
              ),
            ),
            FractionallySizedBox(
              widthFactor: 0.7,
              child: Container(
                height: 10,
                decoration:
                    BoxDecoration(color: base, borderRadius: BorderRadius.circular(4)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Rectangular placeholder for the map while tiles/markers load.
class MapShimmer extends StatelessWidget {
  const MapShimmer({super.key, this.height = 220});

  final double height;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final base = colors.textSecondary.withValues(alpha: 0.12);
    final highlight = colors.textSecondary.withValues(alpha: 0.05);

    return Shimmer.fromColors(
      baseColor: base,
      highlightColor: highlight,
      period: const Duration(milliseconds: 1200),
      child: Container(
        height: height,
        decoration: BoxDecoration(
          color: base,
          borderRadius: BorderRadius.circular(AppDimens.cardRadius),
        ),
      ),
    );
  }
}

/// Convenience: a shimmering list for full-screen loading states.
class ShimmerList extends StatelessWidget {
  const ShimmerList({super.key, this.count = 4});

  final int count;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      physics: const ClampingScrollPhysics(),
      padding: const EdgeInsets.all(AppDimens.grid * 2),
      itemCount: count,
      separatorBuilder: (_, __) => const SizedBox(height: AppDimens.grid * 1.5),
      itemBuilder: (_, __) => const ShimmerCard(),
    );
  }
}
