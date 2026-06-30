import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_button.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/state_views.dart';
import '../../../auth/models/user.dart';
import '../../../auth/providers/auth_provider.dart';
import '../models/farmer.dart';
import '../providers/farmer_provider.dart';
import '../utils.dart';
import '../widgets/lead_status_badge.dart';
import '../widgets/farmer_edit_sheet.dart';
import '../widgets/update_lead_sheet.dart';

/// Visit status -> color. Shared with the visit-history screen.
Color visitStatusColor(BuildContext context, String status) {
  final colors = context.appColors;
  return switch (status.toUpperCase()) {
    'COMPLETED' => colors.statusActive,
    'ABANDONED' => Theme.of(context).colorScheme.error,
    _ => Theme.of(context).colorScheme.primary, // CHECKED_IN / unknown
  };
}

/// "FIRST_VISIT" -> "First visit". Null -> "Visit".
String prettyPurpose(String? purpose) {
  if (purpose == null || purpose.isEmpty) return 'Visit';
  return purpose
      .toLowerCase()
      .split('_')
      .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
      .join(' ');
}

class FarmerDetailScreen extends ConsumerWidget {
  const FarmerDetailScreen({super.key, required this.farmerId});

  final int farmerId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(farmerDetailProvider(farmerId));
    return Scaffold(
      appBar: AppBar(
        title: const Text('Farmer', maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: SafeArea(
        child: async.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ErrorStateView(
            message: e.toString(),
            onRetry: () =>
                ref.read(farmerDetailProvider(farmerId).notifier).refresh(),
          ),
          data: (farmer) => _Content(farmer: farmer),
        ),
      ),
    );
  }
}

class _Content extends ConsumerWidget {
  const _Content({required this.farmer});
  final FarmerDetail farmer;

  bool _canEdit(User? user) {
    if (user == null) return false;
    if (user.role != UserRole.employee) return true;
    return farmer.createdBy == user.id;
  }

  Future<void> _call(BuildContext context, String phone) async {
    final uri = Uri(scheme: 'tel', path: phone);
    if (!await launchUrl(uri)) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not start a call to $phone')),
        );
      }
    }
  }

  void _comingSoon(BuildContext context, String what) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$what is coming soon')),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authProvider).user;
    final canEdit = _canEdit(user);

    return RefreshIndicator(
      onRefresh: () =>
          ref.read(farmerDetailProvider(farmer.id).notifier).refresh(),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(AppDimens.grid * 2),
        children: [
          _HeaderCard(
            farmer: farmer,
            canEdit: canEdit,
            onCall: () => _call(context, farmer.phone!),
            onEdit: () => FarmerEditSheet.show(context, farmer: farmer),
          ),
          const SizedBox(height: AppDimens.grid * 2),
          _StatsRow(farmer: farmer),
          const SizedBox(height: AppDimens.grid * 2),
          _LivestockCard(
            farmer: farmer,
            onTap: () => context.push('/farmer/${farmer.id}/livestock'),
          ),
          const SizedBox(height: AppDimens.grid * 2),
          _LeadCard(
            farmer: farmer,
            onUpdate: () => UpdateLeadSheet.show(
              context,
              farmerId: farmer.id,
              current: farmer.currentLead?.status,
            ),
          ),
          const SizedBox(height: AppDimens.grid * 2),
          _VisitHistory(
            farmer: farmer,
            onViewAll: () => context.push('/farmer/${farmer.id}/visits'),
          ),
          if (farmer.pendingFollowUps.isNotEmpty) ...[
            const SizedBox(height: AppDimens.grid * 2),
            _FollowUps(items: farmer.pendingFollowUps),
          ],
          const SizedBox(height: AppDimens.grid * 2),
          _ActionButtons(
            onPlan: () => context.push('/planning'),
            onStart: () => context.push('/visit/start/${farmer.id}'),
            onReport: () => _comingSoon(context, 'Farmer reports'),
          ),
          const SizedBox(height: AppDimens.grid * 2),
        ],
      ),
    );
  }
}

// ── Header ─────────────────────────────────────────────────────────────────
class _HeaderCard extends StatelessWidget {
  const _HeaderCard({
    required this.farmer,
    required this.canEdit,
    required this.onCall,
    required this.onEdit,
  });

  final FarmerDetail farmer;
  final bool canEdit;
  final VoidCallback onCall;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final scheme = Theme.of(context).colorScheme;
    final hasPhone = farmer.phone != null && farmer.phone!.isNotEmpty;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Hero(
                  tag: 'farmer-name-${farmer.id}',
                  child: Material(
                    type: MaterialType.transparency,
                    child: Text(
                      farmer.name,
                      style: AppTextStyles.heading
                          .copyWith(color: scheme.onSurface),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: AppDimens.grid),
              LeadStatusBadge(status: farmer.currentLead?.status),
              if (canEdit) ...[
                const SizedBox(width: AppDimens.grid * 0.5),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: Icon(Icons.edit_rounded,
                      size: 20, color: scheme.primary),
                  onPressed: onEdit,
                  tooltip: 'Edit',
                ),
              ],
            ],
          ),
          const SizedBox(height: AppDimens.grid),
          if (farmer.village != null && farmer.village!.isNotEmpty)
            _line(context, Icons.home_work_rounded,
                [farmer.village, farmer.district].whereType<String>().where((s) => s.isNotEmpty).join(', ')),
          if (farmer.teamName != null)
            _line(context, Icons.groups_rounded, farmer.teamName!),
          if (hasPhone)
            InkWell(
              onTap: onCall,
              borderRadius: BorderRadius.circular(AppDimens.buttonRadius),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Icon(Icons.phone_rounded, size: 16, color: scheme.primary),
                    const SizedBox(width: AppDimens.grid),
                    Text(
                      farmer.phone!,
                      style: AppTextStyles.bodyMedium
                          .copyWith(color: scheme.primary),
                    ),
                    const SizedBox(width: AppDimens.grid * 0.5),
                    Icon(Icons.call_made_rounded,
                        size: 12, color: colors.textSecondary),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _line(BuildContext context, IconData icon, String text) {
    final colors = context.appColors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 16, color: colors.textSecondary),
          const SizedBox(width: AppDimens.grid),
          Expanded(
            child: Text(
              text,
              style:
                  AppTextStyles.body.copyWith(color: colors.textSecondary),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Quick stats (animated count-up) ─────────────────────────────────────────
class _StatsRow extends StatelessWidget {
  const _StatsRow({required this.farmer});
  final FarmerDetail farmer;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
            child: _StatTile(
                label: 'Visits',
                value: farmer.totalVisits,
                icon: Icons.place_rounded)),
        const SizedBox(width: AppDimens.grid * 1.5),
        Expanded(
            child: _StatTile(
                label: 'Orders',
                value: farmer.totalOrders,
                icon: Icons.shopping_bag_rounded)),
        const SizedBox(width: AppDimens.grid * 1.5),
        Expanded(
            child: _StatTile(
                label: 'Cattle',
                value: farmer.totalCattle,
                icon: Icons.pets_rounded)),
      ],
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile(
      {required this.label, required this.value, required this.icon});

  final String label;
  final int value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final scheme = Theme.of(context).colorScheme;
    return AppCard(
      padding: const EdgeInsets.symmetric(
          vertical: AppDimens.grid * 1.75, horizontal: AppDimens.grid),
      child: Column(
        children: [
          Icon(icon, size: 22, color: scheme.primary),
          const SizedBox(height: AppDimens.grid),
          TweenAnimationBuilder<int>(
            tween: IntTween(begin: 0, end: value),
            duration: const Duration(milliseconds: 650),
            curve: Curves.easeOutCubic,
            builder: (context, v, _) => Text(
              '$v',
              style: AppTextStyles.display
                  .copyWith(color: scheme.onSurface, fontSize: 22),
            ),
          ),
          Text(label,
              style:
                  AppTextStyles.caption.copyWith(color: colors.textSecondary)),
        ],
      ),
    );
  }
}

// ── Livestock summary ────────────────────────────────────────────────────────
class _LivestockCard extends StatelessWidget {
  const _LivestockCard({required this.farmer, required this.onTap});
  final FarmerDetail farmer;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final scheme = Theme.of(context).colorScheme;
    final ls = farmer.latestLivestock;
    return AppCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.pets_rounded, size: 18, color: scheme.primary),
              const SizedBox(width: AppDimens.grid),
              Text('Livestock',
                  style: AppTextStyles.bodyMedium
                      .copyWith(color: scheme.onSurface)),
              const Spacer(),
              Icon(Icons.chevron_right_rounded,
                  size: 18, color: colors.textSecondary),
            ],
          ),
          const SizedBox(height: AppDimens.grid),
          if (ls == null)
            Text('No livestock recorded yet.',
                style:
                    AppTextStyles.body.copyWith(color: colors.textSecondary))
          else ...[
            Wrap(
              spacing: AppDimens.grid * 2,
              runSpacing: AppDimens.grid,
              children: [
                _kv(context, 'Breed', ls.breed ?? '—'),
                _kv(context, 'Brand', ls.currentBrand ?? '—'),
                _kv(context, 'Bags/mo', ls.bagsPerMonth?.toString() ?? '—'),
                _kv(context, 'Price/bag', money(ls.currentPricePerBag)),
              ],
            ),
            const SizedBox(height: AppDimens.grid),
            Text('Updated ${timeAgo(ls.recordedAt)}',
                style: AppTextStyles.caption
                    .copyWith(color: colors.textSecondary)),
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

// ── Lead status ──────────────────────────────────────────────────────────────
class _LeadCard extends StatelessWidget {
  const _LeadCard({required this.farmer, required this.onUpdate});
  final FarmerDetail farmer;
  final VoidCallback onUpdate;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final scheme = Theme.of(context).colorScheme;
    final lead = farmer.currentLead;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Lead status',
                  style: AppTextStyles.bodyMedium
                      .copyWith(color: scheme.onSurface)),
              const Spacer(),
              LeadStatusBadge(status: lead?.status, large: true),
            ],
          ),
          if (lead != null) ...[
            const SizedBox(height: AppDimens.grid),
            Text('Last changed: ${timeAgo(lead.changedAt)}',
                style: AppTextStyles.caption
                    .copyWith(color: colors.textSecondary)),
            if (lead.reasonNote != null && lead.reasonNote!.isNotEmpty) ...[
              const SizedBox(height: AppDimens.grid * 0.5),
              Text(lead.reasonNote!,
                  style:
                      AppTextStyles.body.copyWith(color: scheme.onSurface)),
            ],
          ] else ...[
            const SizedBox(height: AppDimens.grid),
            Text('No lead status set yet.',
                style:
                    AppTextStyles.body.copyWith(color: colors.textSecondary)),
          ],
          const SizedBox(height: AppDimens.grid * 1.5),
          AppButton(
            label: 'Update Status',
            icon: Icons.flag_rounded,
            variant: AppButtonVariant.secondary,
            expanded: false,
            onPressed: onUpdate,
          ),
        ],
      ),
    );
  }
}

// ── Visit history (last 3) ───────────────────────────────────────────────────
class _VisitHistory extends StatelessWidget {
  const _VisitHistory({required this.farmer, required this.onViewAll});
  final FarmerDetail farmer;
  final VoidCallback onViewAll;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final scheme = Theme.of(context).colorScheme;
    final visits = farmer.recentVisits;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Recent visits',
                  style: AppTextStyles.bodyMedium
                      .copyWith(color: scheme.onSurface)),
              const Spacer(),
              if (farmer.totalVisits > visits.length)
                GestureDetector(
                  onTap: onViewAll,
                  child: Text('View all',
                      style: AppTextStyles.caption.copyWith(
                          color: scheme.primary, fontWeight: FontWeight.w600)),
                ),
            ],
          ),
          const SizedBox(height: AppDimens.grid),
          if (visits.isEmpty)
            Text('No visits yet.',
                style: AppTextStyles.body.copyWith(color: colors.textSecondary))
          else
            for (int i = 0; i < visits.length; i++)
              _timelineRow(context, visits[i], isLast: i == visits.length - 1),
        ],
      ),
    );
  }

  Widget _timelineRow(BuildContext context, VisitSummary v,
      {required bool isLast}) {
    final colors = context.appColors;
    final scheme = Theme.of(context).colorScheme;
    final statusColor = visitStatusColor(context, v.status);
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            children: [
              Container(
                width: 12,
                height: 12,
                margin: const EdgeInsets.only(top: 2),
                decoration:
                    BoxDecoration(color: statusColor, shape: BoxShape.circle),
              ),
              if (!isLast)
                Expanded(
                  child: Container(
                    width: 2,
                    color: colors.textSecondary.withValues(alpha: 0.2),
                  ),
                ),
            ],
          ),
          const SizedBox(width: AppDimens.grid * 1.5),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: isLast ? 0 : AppDimens.grid * 1.5),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          shortDate(v.checkInAt ?? v.createdAt),
                          style: AppTextStyles.bodyMedium
                              .copyWith(color: scheme.onSurface),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        v.status[0].toUpperCase() +
                            v.status.substring(1).toLowerCase().replaceAll('_', ' '),
                        style: AppTextStyles.caption.copyWith(
                            color: statusColor, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                  Text(prettyPurpose(v.purpose),
                      style: AppTextStyles.caption
                          .copyWith(color: colors.textSecondary)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Pending follow-ups ───────────────────────────────────────────────────────
class _FollowUps extends StatelessWidget {
  const _FollowUps({required this.items});
  final List<FollowUp> items;

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
              Icon(Icons.notifications_active_rounded,
                  size: 18, color: scheme.secondary),
              const SizedBox(width: AppDimens.grid),
              Text('Pending follow-ups',
                  style: AppTextStyles.bodyMedium
                      .copyWith(color: scheme.onSurface)),
            ],
          ),
          const SizedBox(height: AppDimens.grid),
          for (final f in items)
            Padding(
              padding: const EdgeInsets.only(bottom: AppDimens.grid),
              child: Row(
                children: [
                  Icon(Icons.event_rounded, size: 14, color: colors.textSecondary),
                  const SizedBox(width: AppDimens.grid),
                  Expanded(
                    child: Text(
                      '${shortDate(f.scheduledDate)}'
                      '${f.scheduledTime != null ? ' · ${f.scheduledTime!.substring(0, 5)}' : ''}'
                      '${f.purpose != null && f.purpose!.isNotEmpty ? ' — ${f.purpose}' : ''}',
                      style: AppTextStyles.caption
                          .copyWith(color: colors.textSecondary),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ── Action buttons ───────────────────────────────────────────────────────────
class _ActionButtons extends StatelessWidget {
  const _ActionButtons(
      {required this.onPlan, required this.onStart, required this.onReport});
  final VoidCallback onPlan;
  final VoidCallback onStart;
  final VoidCallback onReport;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: AppButton(
                label: 'Plan a Visit',
                icon: Icons.event_note_rounded,
                variant: AppButtonVariant.secondary,
                onPressed: onPlan,
              ),
            ),
            const SizedBox(width: AppDimens.grid * 1.5),
            Expanded(
              child: AppButton(
                label: 'Start Visit',
                icon: Icons.play_arrow_rounded,
                onPressed: onStart,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppDimens.grid * 1.5),
        AppButton(
          label: 'Generate Report',
          icon: Icons.bar_chart_rounded,
          variant: AppButtonVariant.secondary,
          onPressed: onReport,
        ),
      ],
    );
  }
}
