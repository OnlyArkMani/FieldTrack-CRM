import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_text_styles.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_card.dart';
// import '../../../core/widgets/shimmer_card.dart';
import '../../attendance/widgets/attendance_status_tile.dart';
import '../../auth/providers/auth_provider.dart';
import '../../notifications/widgets/notification_bell.dart';
import '../../teams/models/team.dart';
import '../../teams/providers/team_provider.dart';

/// Role-aware dashboard: managers get the team view (with quick access to
/// the team directory & team management), employees the personal view. The
/// remaining live-metric content ships with later tracking phases — these
/// shimmer cards hold its place.
class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authProvider).user;
    final isManager = user?.isManager ?? false;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          isManager ? 'Team Dashboard' : 'My Dashboard',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: const [NotificationBell()],
      ),
      body: SafeArea(
        child: ListView(
          physics: const ClampingScrollPhysics(),
          padding: const EdgeInsets.all(AppDimens.grid * 2),
          children: [
            // "Am I checked in?" at a glance — most prominent, top of dashboard.
            const AttendanceStatusTile(),
            const SizedBox(height: AppDimens.grid * 1.5),
            // Prominent entry to pre-day visit planning (CRM).
            _QuickAction(
              icon: Icons.event_note_rounded,
              label: 'My Visit',
              subtitle: "Plan tomorrow's farmer visits",
              onTap: () => context.push('/planning'),
            ),
            const SizedBox(height: AppDimens.grid * 1.5),
            Row(
              children: [
                Expanded(
                  child: _QuickAction(
                    icon: Icons.flag_rounded,
                    label: 'Leads',
                    subtitle: 'Hot / Warm / Cold pipeline',
                    onTap: () => context.push('/leads'),
                  ),
                ),
                const SizedBox(width: AppDimens.grid * 1.5),
                Expanded(
                  child: _QuickAction(
                    icon: Icons.event_repeat_rounded,
                    label: 'Follow-ups',
                    subtitle: 'Upcoming reminders',
                    onTap: () => context.push('/followups'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppDimens.grid * 1.5),
            _QuickAction(
              icon: Icons.medical_services_rounded,
              label: 'Vet requests',
              subtitle: 'Customers needing a vet',
              onTap: () => context.push('/vet'),
            ),
            const SizedBox(height: AppDimens.grid * 1.5),
            if (isManager) ...[
              const _TeamOrdersTodayCard(),
              const SizedBox(height: AppDimens.grid * 1.5),
              Row(
                children: [
                  Expanded(
                    child: _QuickAction(
                      icon: Icons.groups_2_rounded,
                      label: 'Team directory',
                      subtitle: 'People & live status',
                      onTap: () => context.push('/employees'),
                    ),
                  ),
                  const SizedBox(width: AppDimens.grid * 1.5),
                  Expanded(
                    child: _QuickAction(
                      icon: Icons.workspaces_rounded,
                      label: 'Teams',
                      subtitle: 'Manage & performance',
                      onTap: () => context.push('/teams'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppDimens.grid * 1.5),
              _QuickAction(
                icon: Icons.receipt_long_rounded,
                label: 'Team DSR',
                subtitle: 'Daily sales reports by member',
                onTap: () => context.push('/dsr/team'),
              ),
              const SizedBox(height: AppDimens.grid * 1.5),
              _QuickAction(
                icon: Icons.event_note_rounded,
                label: 'Team Visit Plans',
                subtitle: "Who's planned tomorrow's visits",
                onTap: () => context.push('/planning/team'),
              ),
              const SizedBox(height: AppDimens.grid * 1.5),
              _QuickAction(
                icon: Icons.fact_check_rounded,
                label: 'Order approvals',
                subtitle: 'Approve or reject field orders',
                onTap: () => context.push('/orders/approvals'),
              ),
              const SizedBox(height: AppDimens.grid * 1.5),
            ],
            _QuickAction(
              icon: Icons.assessment_rounded,
              label: 'Reports',
              subtitle: isManager
                  ? 'Attendance, distance & team exports'
                  : 'Export your attendance & distance',
              onTap: () => context.push('/reports'),
            ),
            const SizedBox(height: AppDimens.grid * 1.5),
            // // Shimmer placeholders until the remaining live metrics land.
            // const ShimmerCard(),
            // const SizedBox(height: AppDimens.grid * 1.5),
            // const ShimmerCard(),
          ],
        ),
      ),
    );
  }
}

/// Manager-only: this team's target vs completed order bags for today.
/// GET /teams/orders-summary — a manager's account only ever gets back the
/// team(s) they manage, so this renders one row per team in scope.
class _TeamOrdersTodayCard extends ConsumerWidget {
  const _TeamOrdersTodayCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.appColors;
    final scheme = Theme.of(context).colorScheme;
    final summary = ref.watch(teamOrdersSummaryProvider);

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Team Orders Today',
            style: AppTextStyles.bodyMedium.copyWith(color: scheme.onSurface),
          ),
          const SizedBox(height: AppDimens.grid),
          summary.when(
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: AppDimens.grid * 2),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (_, __) => Text(
              'Could not load today\'s order progress.',
              style: AppTextStyles.caption.copyWith(color: colors.textSecondary),
            ),
            data: (teams) => teams.isEmpty
                ? Text(
                    'No team to show.',
                    style: AppTextStyles.caption
                        .copyWith(color: colors.textSecondary),
                  )
                : Column(
                    children: [
                      for (var i = 0; i < teams.length; i++) ...[
                        if (i > 0) const SizedBox(height: AppDimens.grid),
                        _TeamOrdersRow(team: teams[i]),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _TeamOrdersRow extends StatelessWidget {
  const _TeamOrdersRow({required this.team});
  final TeamOrdersSummary team;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final scheme = Theme.of(context).colorScheme;
    final target = team.targetOrderBags;
    final completed = team.completedOrderBags;
    final pct = target > 0 ? (completed / target * 100).clamp(0, 100) : 0.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                team.teamName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.bodyMedium
                    .copyWith(color: scheme.onSurface),
              ),
            ),
            Text(
              '$completed / $target bags',
              style: AppTextStyles.caption.copyWith(color: colors.textSecondary),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(
            value: target > 0 ? completed / target : 0,
            minHeight: 6,
            backgroundColor: scheme.primary.withValues(alpha: 0.12),
            valueColor: AlwaysStoppedAnimation(scheme.primary),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          target > 0 ? '${pct.round()}% of target' : 'No target set today',
          style: AppTextStyles.caption.copyWith(color: colors.textSecondary),
        ),
      ],
    );
  }
}

class _QuickAction extends StatelessWidget {
  const _QuickAction({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final scheme = Theme.of(context).colorScheme;
    return AppCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(AppDimens.buttonRadius),
            ),
            child: Icon(icon, size: 22, color: scheme.primary),
          ),
          const SizedBox(height: AppDimens.grid * 1.5),
          Text(
            label,
            style: AppTextStyles.bodyMedium.copyWith(color: scheme.onSurface),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            subtitle,
            style: AppTextStyles.caption.copyWith(color: colors.textSecondary),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
