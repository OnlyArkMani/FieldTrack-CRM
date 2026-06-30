import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_text_styles.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/shimmer_card.dart';
import '../../auth/providers/auth_provider.dart';
import '../../notifications/widgets/notification_bell.dart';

/// Role-aware dashboard: supervisors get the team view (with quick access to
/// the team directory & team management), employees the personal view. The
/// live-metric content ships with the attendance/tracking phases — these
/// shimmer cards hold its place.
class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authProvider).user;
    final isSupervisor = user?.isSupervisor ?? false;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          isSupervisor ? 'Team Dashboard' : 'My Dashboard',
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
            // Prominent entry to pre-day visit planning (CRM).
            _QuickAction(
              icon: Icons.event_note_rounded,
              label: 'Plan visits',
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
            if (isSupervisor) ...[
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
            ],
            _QuickAction(
              icon: Icons.assessment_rounded,
              label: 'Reports',
              subtitle: isSupervisor
                  ? 'Attendance, distance & team exports'
                  : 'Export your attendance & distance',
              onTap: () => context.push('/reports'),
            ),
            const SizedBox(height: AppDimens.grid * 1.5),
            // Shimmer placeholders until the live data phase lands.
            const ShimmerCard(),
            const SizedBox(height: AppDimens.grid * 1.5),
            const ShimmerCard(),
            const SizedBox(height: AppDimens.grid * 1.5),
            const ShimmerCard(),
          ],
        ),
      ),
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
