import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/state_views.dart';
import '../../farmers/utils.dart';
import '../../farmers/widgets/lead_status_badge.dart';
import '../data/visit_repository.dart';
import '../models/visit.dart';

/// Read-only summary of a (usually completed) visit — all four steps' data in a
/// clean card layout. Reached from a farmer's visit history.
class VisitSummaryScreen extends ConsumerWidget {
  const VisitSummaryScreen({super.key, required this.visitId});

  final int visitId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(visitDetailProvider(visitId));
    return Scaffold(
      appBar: AppBar(
        title: const Text('Visit summary',
            maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: SafeArea(
        child: async.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ErrorStateView(
            message: e.toString(),
            onRetry: () => ref.invalidate(visitDetailProvider(visitId)),
          ),
          data: (visit) => _Body(visit: visit),
        ),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.visit});
  final VisitDetail visit;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(AppDimens.grid * 2),
      children: [
        // Header
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(visit.farmerName ?? 'Visit',
                        style: AppTextStyles.heading
                            .copyWith(color: scheme.onSurface),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                  ),
                  if (visit.lead != null) LeadStatusBadge(status: visit.lead),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '${shortDate(visit.checkInAt)} · ${_prettyStatus(visit.status)}'
                '${visit.purpose != null ? ' · ${_pretty(visit.purpose!)}' : ''}',
                style:
                    AppTextStyles.caption.copyWith(color: colors.textSecondary),
              ),
              if (visit.locationWarning) ...[
                const SizedBox(height: AppDimens.grid),
                Row(
                  children: [
                    Icon(Icons.warning_amber_rounded,
                        size: 14, color: scheme.error),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        visit.distanceAtCheckinMeters != null
                            ? 'Checked in ${visit.distanceAtCheckinMeters!.round()}m away'
                                '${visit.locationWarningRemark != null ? ' — ${visit.locationWarningRemark}' : ''}'
                            : 'Out-of-range check-in',
                        style: AppTextStyles.caption
                            .copyWith(color: scheme.error),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: AppDimens.grid * 2),

        // Notes
        if (visit.notes != null &&
            (_has(visit.notes!.meetingHighlights) ||
                _has(visit.notes!.farmerConcerns) ||
                _has(visit.notes!.productInterest)))
          _Section(title: 'Meeting notes', children: [
            _kv(context, 'Highlights', visit.notes!.meetingHighlights),
            _kv(context, 'Concerns', visit.notes!.farmerConcerns),
            _kv(context, 'Product interest', visit.notes!.productInterest),
          ]),

        // Livestock
        if (visit.livestock != null)
          _Section(title: 'Livestock', children: [
            _kv(context, 'Total cattle',
                visit.livestock!.totalCattle?.toString()),
            _kv(context, 'Breed', visit.livestock!.breed),
            _kv(context, 'Age group', visit.livestock!.ageGroup),
            _kv(context, 'Current brand', visit.livestock!.currentBrand),
            _kv(context, 'Bags / month',
                visit.livestock!.bagsPerMonth?.toString()),
            _kv(context, 'Price / bag', money(visit.livestock!.currentPricePerBag)),
            _kv(context, 'Health', visit.livestock!.healthStatus),
          ]),

        // Orders
        if (visit.orders.isNotEmpty)
          _Section(
            title: 'Orders',
            children: [
              for (final o in visit.orders)
                _kv(
                  context,
                  '${o.bagsCount} bag${o.bagsCount == 1 ? '' : 's'}',
                  'Deliver ${shortDate(o.deliveryDate)}'
                      '${o.paymentMode != null ? ' · ${_pretty(o.paymentMode!)}' : ''}',
                ),
            ],
          ),
      ],
    );
  }

  bool _has(String? s) => s != null && s.trim().isNotEmpty;

  Widget _kv(BuildContext context, String k, String? v) {
    if (v == null || v.trim().isEmpty || v == '—') return const SizedBox.shrink();
    final colors = context.appColors;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppDimens.grid),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(k,
              style:
                  AppTextStyles.caption.copyWith(color: colors.textSecondary)),
          Text(v,
              style: AppTextStyles.body
                  .copyWith(color: Theme.of(context).colorScheme.onSurface)),
        ],
      ),
    );
  }

  static String _pretty(String s) => s
      .toLowerCase()
      .split('_')
      .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
      .join(' ');

  static String _prettyStatus(String s) => _pretty(s);
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppDimens.grid * 2),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: AppTextStyles.bodyMedium
                    .copyWith(color: Theme.of(context).colorScheme.onSurface)),
            const SizedBox(height: AppDimens.grid),
            ...children,
          ],
        ),
      ),
    );
  }
}
