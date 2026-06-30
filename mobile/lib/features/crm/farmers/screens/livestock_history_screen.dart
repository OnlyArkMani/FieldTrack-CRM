import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/shimmer_card.dart';
import '../../../../core/widgets/state_views.dart';
import '../models/farmer.dart';
import '../providers/farmer_provider.dart';
import '../utils.dart';

/// All livestock snapshots for a farmer, newest first — shows how the herd /
/// feed data evolved across visits.
class LivestockHistoryScreen extends ConsumerWidget {
  const LivestockHistoryScreen({super.key, required this.farmerId});

  final int farmerId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(livestockHistoryProvider(farmerId));
    return Scaffold(
      appBar: AppBar(
        title: const Text('Livestock history',
            maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: SafeArea(
        child: async.when(
          loading: () => const ShimmerList(count: 4),
          error: (e, _) => ErrorStateView(
            message: e.toString(),
            onRetry: () => ref.invalidate(livestockHistoryProvider(farmerId)),
          ),
          data: (rows) {
            if (rows.isEmpty) {
              return const EmptyStateView(
                icon: Icons.pets_rounded,
                title: 'No livestock records',
                message: 'Livestock data is captured during visits.',
              );
            }
            return ListView.separated(
              padding: const EdgeInsets.all(AppDimens.grid * 2),
              itemCount: rows.length,
              separatorBuilder: (_, __) =>
                  const SizedBox(height: AppDimens.grid * 1.5),
              itemBuilder: (context, i) =>
                  _LivestockCard(profile: rows[i], isLatest: i == 0),
            );
          },
        ),
      ),
    );
  }
}

class _LivestockCard extends StatelessWidget {
  const _LivestockCard({required this.profile, required this.isLatest});

  final LivestockProfile profile;
  final bool isLatest;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final scheme = Theme.of(context).colorScheme;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                shortDate(profile.recordedAt),
                style: AppTextStyles.bodyMedium
                    .copyWith(color: scheme.onSurface),
              ),
              const SizedBox(width: AppDimens.grid),
              if (isLatest)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: AppDimens.grid, vertical: 2),
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text('Latest',
                      style: AppTextStyles.caption.copyWith(
                          color: scheme.primary, fontWeight: FontWeight.w600)),
                ),
            ],
          ),
          const SizedBox(height: AppDimens.grid),
          Wrap(
            spacing: AppDimens.grid * 2,
            runSpacing: AppDimens.grid,
            children: [
              _kv(context, 'Cattle', profile.totalCattle?.toString() ?? '—'),
              _kv(context, 'Breed', profile.breed ?? '—'),
              _kv(context, 'Age group', profile.ageGroup ?? '—'),
              _kv(context, 'Brand', profile.currentBrand ?? '—'),
              _kv(context, 'Bags/mo', profile.bagsPerMonth?.toString() ?? '—'),
              _kv(context, 'Price/bag', money(profile.currentPricePerBag)),
              _kv(context, 'Health', profile.healthStatus ?? '—'),
            ],
          ),
          if (profile.healthNotes != null &&
              profile.healthNotes!.isNotEmpty) ...[
            const SizedBox(height: AppDimens.grid),
            Text(profile.healthNotes!,
                style:
                    AppTextStyles.caption.copyWith(color: colors.textSecondary)),
          ],
        ],
      ),
    );
  }

  Widget _kv(BuildContext context, String k, String v) {
    final colors = context.appColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(k,
            style: AppTextStyles.caption.copyWith(color: colors.textSecondary)),
        Text(v,
            style: AppTextStyles.bodyMedium
                .copyWith(color: Theme.of(context).colorScheme.onSurface)),
      ],
    );
  }
}
