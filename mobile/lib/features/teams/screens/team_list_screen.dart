import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_text_styles.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/shimmer_card.dart';
import '../../../core/widgets/state_views.dart';
import '../../auth/models/user.dart';
import '../../auth/providers/auth_provider.dart';
import '../models/team.dart';
import '../providers/team_provider.dart';
import '../widgets/create_team_sheet.dart';

/// Team management. Admins manage all teams (create + delete); supervisors see
/// their own team(s) read-only. The create FAB is admin-only.
class TeamListScreen extends ConsumerWidget {
  const TeamListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(teamListProvider);
    final notifier = ref.read(teamListProvider.notifier);
    final user = ref.watch(authProvider).user;
    final isAdmin = user?.role == UserRole.admin;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Teams', maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      floatingActionButton: isAdmin
          ? FloatingActionButton.extended(
              onPressed: () => showCreateTeamSheet(context),
              backgroundColor: Theme.of(context).colorScheme.primary,
              foregroundColor: Theme.of(context).colorScheme.onPrimary,
              icon: const Icon(Icons.add_rounded),
              label: const Text('New team'),
            )
          : null,
      body: SafeArea(
        child: _body(context, ref, state, notifier, isAdmin),
      ),
    );
  }

  Widget _body(
    BuildContext context,
    WidgetRef ref,
    TeamListState state,
    TeamNotifier notifier,
    bool isAdmin,
  ) {
    if (state.isLoading) return const ShimmerList(count: 4);

    if (state.error != null && state.teams.isEmpty) {
      return ErrorStateView(message: state.error!, onRetry: () => notifier.load());
    }

    if (state.isEmpty) {
      return RefreshIndicator(
        onRefresh: () => notifier.load(isRefresh: true),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(height: MediaQuery.of(context).size.height * 0.1),
            EmptyStateView(
              icon: Icons.groups_2_rounded,
              title: 'No teams yet',
              message: isAdmin
                  ? 'Create a team to group employees and assign a supervisor.'
                  : 'You have not been assigned to a team yet.',
              actionLabel: isAdmin ? 'Create team' : null,
              onAction: isAdmin ? () => showCreateTeamSheet(context) : null,
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () => notifier.load(isRefresh: true),
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(
          AppDimens.grid * 2,
          AppDimens.grid * 2,
          AppDimens.grid * 2,
          AppDimens.grid * 10,
        ),
        itemCount: state.teams.length,
        separatorBuilder: (_, __) =>
            const SizedBox(height: AppDimens.grid * 1.5),
        itemBuilder: (context, index) => StaggeredEntrance(
          index: index,
          child: _TeamCard(
            team: state.teams[index],
            canDelete: isAdmin,
            onDelete: () => _confirmDelete(context, ref, state.teams[index]),
          ),
        ),
      ),
    );
  }

  Future<void> _confirmDelete(
      BuildContext context, WidgetRef ref, Team team) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete team?'),
        content: Text(
          '"${team.name}" will be deactivated and its ${team.memberCount} '
          'member(s) unassigned. This cannot be undone.',
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(
                foregroundColor: Theme.of(ctx).colorScheme.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final err = await ref.read(teamListProvider.notifier).delete(team.id);
    if (err != null && context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(err)));
    }
  }
}

class _TeamCard extends StatelessWidget {
  const _TeamCard({
    required this.team,
    required this.canDelete,
    required this.onDelete,
  });

  final Team team;
  final bool canDelete;
  final VoidCallback onDelete;

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
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      team.name,
                      style: AppTextStyles.bodyMedium
                          .copyWith(color: scheme.onSurface, fontSize: 16),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (team.supervisorName != null) ...[
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Icon(Icons.shield_rounded,
                              size: 13, color: colors.textSecondary),
                          const SizedBox(width: 3),
                          Flexible(
                            child: Text(
                              team.supervisorName!,
                              style: AppTextStyles.caption
                                  .copyWith(color: colors.textSecondary),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: AppDimens.grid * 1.5),
              _PerformanceRing(percent: team.performancePct),
              if (canDelete)
                IconButton(
                  icon: Icon(Icons.delete_outline_rounded,
                      size: 20, color: colors.textSecondary),
                  onPressed: onDelete,
                  tooltip: 'Delete team',
                ),
            ],
          ),
          if (team.description != null && team.description!.isNotEmpty) ...[
            const SizedBox(height: AppDimens.grid),
            Text(
              team.description!,
              style: AppTextStyles.caption.copyWith(color: colors.textSecondary),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: AppDimens.grid * 1.5),
          Divider(color: colors.textSecondary.withValues(alpha: 0.15)),
          const SizedBox(height: AppDimens.grid),
          Row(
            children: [
              _Pill(
                icon: Icons.people_alt_rounded,
                label: '${team.memberCount} member${team.memberCount == 1 ? '' : 's'}',
              ),
              const SizedBox(width: AppDimens.grid * 1.5),
              _Pill(
                icon: Icons.check_circle_rounded,
                label: '${team.presentToday} present today',
                color: scheme.secondary,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Circular performance gauge (present today / members). Color shifts
/// green → amber → coral as attendance drops.
class _PerformanceRing extends StatelessWidget {
  const _PerformanceRing({required this.percent});
  final double percent;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final fraction = (percent / 100).clamp(0.0, 1.0);
    final color = percent >= 75
        ? colors.statusActive
        : percent >= 40
            ? colors.statusIdle
            : colors.statusGpsDisabled;

    return SizedBox(
      width: 48,
      height: 48,
      child: Stack(
        alignment: Alignment.center,
        children: [
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: fraction),
            duration: const Duration(milliseconds: 700),
            curve: Curves.easeInOutCubic,
            builder: (context, value, _) => SizedBox(
              width: 48,
              height: 48,
              child: CircularProgressIndicator(
                value: value,
                strokeWidth: 4,
                backgroundColor: colors.textSecondary.withValues(alpha: 0.15),
                valueColor: AlwaysStoppedAnimation(color),
              ),
            ),
          ),
          Text(
            '${percent.round()}%',
            style: AppTextStyles.caption.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
              fontSize: 11,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.icon, required this.label, this.color});
  final IconData icon;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final c = color ?? colors.textSecondary;
    return Flexible(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: c),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              style: AppTextStyles.caption.copyWith(color: c),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
