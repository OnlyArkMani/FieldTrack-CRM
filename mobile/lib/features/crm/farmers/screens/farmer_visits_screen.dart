import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/shimmer_card.dart';
import '../../../../core/widgets/state_views.dart';
import '../models/farmer.dart';
import '../providers/farmer_provider.dart';
import 'farmer_detail_screen.dart' show visitStatusColor, prettyPurpose;
import '../utils.dart';

/// Full visit history for a farmer, newest first.
class FarmerVisitsScreen extends ConsumerWidget {
  const FarmerVisitsScreen({super.key, required this.farmerId});

  final int farmerId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(farmerVisitsProvider(farmerId));
    return Scaffold(
      appBar: AppBar(
        title: const Text('Visit history',
            maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: SafeArea(
        child: async.when(
          loading: () => const ShimmerList(count: 5),
          error: (e, _) => ErrorStateView(
            message: e.toString(),
            onRetry: () => ref.invalidate(farmerVisitsProvider(farmerId)),
          ),
          data: (rows) {
            if (rows.isEmpty) {
              return const EmptyStateView(
                icon: Icons.event_note_rounded,
                title: 'No visits yet',
                message: 'Visits to this farmer will appear here.',
              );
            }
            return ListView.separated(
              padding: const EdgeInsets.all(AppDimens.grid * 2),
              itemCount: rows.length,
              separatorBuilder: (_, __) =>
                  const SizedBox(height: AppDimens.grid * 1.5),
              itemBuilder: (context, i) => _VisitCard(
                visit: rows[i],
                onTap: () => context.push('/visit/${rows[i].id}/summary'),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _VisitCard extends StatelessWidget {
  const _VisitCard({required this.visit, this.onTap});
  final VisitSummary visit;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final scheme = Theme.of(context).colorScheme;
    final statusColor = visitStatusColor(context, visit.status);
    return AppCard(
      onTap: onTap,
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.14),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.place_rounded, size: 20, color: statusColor),
          ),
          const SizedBox(width: AppDimens.grid * 1.5),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  shortDate(visit.checkInAt ?? visit.createdAt),
                  style:
                      AppTextStyles.bodyMedium.copyWith(color: scheme.onSurface),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  prettyPurpose(visit.purpose),
                  style: AppTextStyles.caption
                      .copyWith(color: colors.textSecondary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: AppDimens.grid),
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: AppDimens.grid * 1.25, vertical: 3),
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              prettyStatus(visit.status),
              style: AppTextStyles.caption
                  .copyWith(color: statusColor, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

/// "CHECKED_IN" -> "Checked in", etc.
String prettyStatus(String s) {
  return s
      .toLowerCase()
      .split('_')
      .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
      .join(' ');
}
