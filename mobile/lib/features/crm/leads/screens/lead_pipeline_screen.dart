import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/shimmer_card.dart';
import '../../../../core/widgets/state_views.dart';
import '../../farmers/models/farmer.dart' show LeadStatus;
import '../../farmers/utils.dart';
import '../../farmers/widgets/lead_status_badge.dart';
import '../data/lead_repository.dart';
import '../models/lead.dart';

/// Lead pipeline: Hot/Warm/Cold summary cards (tap to filter) over a farmer
/// list. Reached from a dashboard card.
class LeadPipelineScreen extends ConsumerWidget {
  const LeadPipelineScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(myLeadsProvider);
    final filter = ref.watch(leadFilterProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Lead pipeline',
            maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: SafeArea(
        child: async.when(
          loading: () => const ShimmerList(count: 6),
          error: (e, _) => ErrorStateView(
            message: e.toString(),
            onRetry: () => ref.invalidate(myLeadsProvider),
          ),
          data: (leads) {
            final hot = leads.where((l) => l.status == LeadStatus.hot).length;
            final warm = leads.where((l) => l.status == LeadStatus.warm).length;
            final cold = leads.where((l) => l.status == LeadStatus.cold).length;
            final shown = filter == null
                ? leads
                : leads.where((l) => l.status == filter).toList();

            return RefreshIndicator(
              onRefresh: () async => ref.invalidate(myLeadsProvider),
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(AppDimens.grid * 2),
                children: [
                  _SummaryRow(
                    hot: hot,
                    warm: warm,
                    cold: cold,
                    selected: filter,
                    onSelect: (s) => ref.read(leadFilterProvider.notifier).state =
                        filter == s ? null : s,
                  ),
                  const SizedBox(height: AppDimens.grid * 2),
                  if (shown.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: AppDimens.grid * 6),
                      child: EmptyStateView(
                        icon: Icons.flag_rounded,
                        title: filter == null ? 'No leads yet' : 'No matches',
                        message: filter == null
                            ? 'Lead statuses you set on visits appear here.'
                            : 'No ${filter!.label.toLowerCase()} leads right now.',
                      ),
                    )
                  else
                    ...shown.map((l) => Padding(
                          padding:
                              const EdgeInsets.only(bottom: AppDimens.grid * 1.5),
                          child: _LeadCard(
                            lead: l,
                            onTap: () => context.push('/farmer/${l.farmerId}'),
                          ),
                        )),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({
    required this.hot,
    required this.warm,
    required this.cold,
    required this.selected,
    required this.onSelect,
  });

  final int hot;
  final int warm;
  final int cold;
  final LeadStatus? selected;
  final ValueChanged<LeadStatus> onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(
            child: _StatCard(
                label: 'Hot',
                count: hot,
                color: scheme.error,
                selected: selected == LeadStatus.hot,
                onTap: () => onSelect(LeadStatus.hot))),
        const SizedBox(width: AppDimens.grid * 1.5),
        Expanded(
            child: _StatCard(
                label: 'Warm',
                count: warm,
                color: scheme.primary,
                selected: selected == LeadStatus.warm,
                onTap: () => onSelect(LeadStatus.warm))),
        const SizedBox(width: AppDimens.grid * 1.5),
        Expanded(
            child: _StatCard(
                label: 'Cold',
                count: cold,
                color: scheme.secondary,
                selected: selected == LeadStatus.cold,
                onTap: () => onSelect(LeadStatus.cold))),
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.label,
    required this.count,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final int count;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    return AppCard(
      onTap: onTap,
      color: selected ? color.withValues(alpha: 0.16) : null,
      padding: const EdgeInsets.symmetric(
          vertical: AppDimens.grid * 1.75, horizontal: AppDimens.grid),
      child: Column(
        children: [
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(height: AppDimens.grid),
          Text('$count',
              style: AppTextStyles.display.copyWith(color: color, fontSize: 24)),
          Text(label,
              style:
                  AppTextStyles.caption.copyWith(color: colors.textSecondary)),
        ],
      ),
    );
  }
}

class _LeadCard extends StatelessWidget {
  const _LeadCard({required this.lead, required this.onTap});

  final LeadItem lead;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final scheme = Theme.of(context).colorScheme;
    return AppCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(lead.farmerName,
                    style: AppTextStyles.bodyMedium
                        .copyWith(color: scheme.onSurface),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ),
              LeadStatusBadge(status: lead.status),
            ],
          ),
          if (lead.village != null && lead.village!.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(lead.village!,
                style:
                    AppTextStyles.caption.copyWith(color: colors.textSecondary),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ],
          const SizedBox(height: AppDimens.grid),
          Row(
            children: [
              Icon(Icons.schedule_rounded, size: 13, color: colors.textSecondary),
              const SizedBox(width: 4),
              Text(lastVisitedLabel(lead.lastVisitAt),
                  style: AppTextStyles.caption
                      .copyWith(color: colors.textSecondary)),
              const Spacer(),
              if (lead.followUpDate != null) _followUpChip(context, lead),
            ],
          ),
        ],
      ),
    );
  }

  Widget _followUpChip(BuildContext context, LeadItem lead) {
    final soon = lead.followUpSoon;
    final color = soon
        ? Theme.of(context).colorScheme.primary
        : context.appColors.textSecondary;
    final label =
        'Follow-up ${shortDate(lead.followUpDate)}${lead.followUpTimeLabel != null ? ' · ${lead.followUpTimeLabel}' : ''}';
    return Container(
      padding:
          const EdgeInsets.symmetric(horizontal: AppDimens.grid, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: soon ? 0.16 : 0.08),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.event_rounded, size: 12, color: color),
          const SizedBox(width: 3),
          Text(label,
              style: AppTextStyles.caption.copyWith(
                  color: color,
                  fontWeight: soon ? FontWeight.w700 : FontWeight.w400)),
        ],
      ),
    );
  }
}
