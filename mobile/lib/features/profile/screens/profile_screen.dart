import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/config/env.dart';
import '../../../core/widgets/app_bottom_sheet.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_card.dart';
import '../../auth/providers/auth_provider.dart';

final _appVersionProvider = FutureProvider<String>((ref) async {
  final info = await PackageInfo.fromPlatform();
  return 'v${info.version} (${info.buildNumber})';
});

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authProvider).user;
    final themeMode = ref.watch(themeModeProvider);
    final version = ref.watch(_appVersionProvider);
    final scheme = Theme.of(context).colorScheme;
    final colors = context.appColors;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Profile', maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: SafeArea(
        child: ListView(
          physics: const ClampingScrollPhysics(),
          padding: const EdgeInsets.all(AppDimens.grid * 2),
          children: [
            // ── Identity header ─────────────────────────────────────────
            AppCard(
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 32,
                    backgroundColor: scheme.secondary.withValues(alpha: 0.2),
                    foregroundImage: user?.profilePhotoUrl != null
                        ? CachedNetworkImageProvider(user!.profilePhotoUrl!)
                        : null,
                    child: Text(
                      (user?.name.isNotEmpty ?? false)
                          ? user!.name[0].toUpperCase()
                          : '?',
                      style: AppTextStyles.heading
                          .copyWith(color: scheme.secondary),
                    ),
                  ),
                  const SizedBox(width: AppDimens.grid * 2),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          user?.name ?? '—',
                          style: Theme.of(context).textTheme.headlineSmall,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: AppDimens.grid * 0.5),
                        Text(
                          user?.email ?? '',
                          style: Theme.of(context).textTheme.bodySmall,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: AppDimens.grid),
                        // Role badge
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppDimens.grid * 1.5,
                            vertical: AppDimens.grid * 0.5,
                          ),
                          decoration: BoxDecoration(
                            color: scheme.primary.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            user?.role.label ?? '',
                            style: AppTextStyles.caption.copyWith(
                              color: scheme.primary,
                              fontWeight: FontWeight.w600,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppDimens.grid * 3),

            // ── Settings ────────────────────────────────────────────────
            _SectionLabel('Settings'),
            AppCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  _SettingsTile(
                    icon: Icons.person_outline_rounded,
                    title: 'Edit Profile',
                    onTap: () {/* edit-profile ships with profile phase */},
                  ),
                  const Divider(),
                  _SettingsTile(
                    icon: Icons.notifications_none_rounded,
                    title: 'Notifications',
                    onTap: () => context.push('/notifications'),
                  ),
                  const Divider(),
                  _SettingsTile(
                    icon: Icons.assessment_outlined,
                    title: 'Reports',
                    onTap: () => context.push('/reports'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppDimens.grid * 3),

            // ── App ─────────────────────────────────────────────────────
            _SectionLabel('App'),
            AppCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  // Theme toggle: instant + persisted (ThemeNotifier).
                  SwitchListTile(
                    secondary: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 350),
                      transitionBuilder: (child, anim) => RotationTransition(
                        turns: Tween(begin: 0.75, end: 1.0).animate(anim),
                        child: ScaleTransition(scale: anim, child: child),
                      ),
                      switchInCurve: Curves.easeInOutCubic,
                      switchOutCurve: Curves.easeInOutCubic,
                      child: Icon(
                        themeMode == ThemeMode.dark
                            ? Icons.dark_mode_rounded
                            : Icons.light_mode_rounded,
                        key: ValueKey(themeMode),
                        color: colors.textSecondary,
                      ),
                    ),
                    title: Text(
                      'Dark Mode',
                      style: Theme.of(context).textTheme.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    value: themeMode == ThemeMode.dark,
                    onChanged: (_) =>
                        ref.read(themeModeProvider.notifier).toggle(),
                  ),
                  const Divider(),
                  _SettingsTile(
                    icon: Icons.info_outline_rounded,
                    title: 'App Version',
                    trailing: Text(
                      version.valueOrNull ?? '…',
                      style: Theme.of(context).textTheme.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const Divider(),
                  _SettingsTile(
                    icon: Icons.description_outlined,
                    title: 'Terms & Conditions',
                    onTap: () => launchUrl(
                      Uri.parse(Env.termsUrl),
                      mode: LaunchMode.externalApplication,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppDimens.grid * 3),

            // ── Account ─────────────────────────────────────────────────
            _SectionLabel('Account'),
            AppCard(
              padding: EdgeInsets.zero,
              child: _SettingsTile(
                icon: Icons.logout_rounded,
                title: 'Log Out',
                iconColor: scheme.error,
                titleColor: scheme.error,
                onTap: () async {
                  final confirmed = await _showLogoutSheet(context);
                  if (confirmed) {
                    await HapticFeedback.mediumImpact();
                    await ref.read(authProvider.notifier).logout();
                  }
                },
              ),
            ),
            const SizedBox(height: AppDimens.grid * 4),
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(
        left: AppDimens.grid,
        bottom: AppDimens.grid,
      ),
      child: Text(
        text.toUpperCase(),
        style: AppTextStyles.caption.copyWith(
          color: context.appColors.textSecondary,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.8,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  const _SettingsTile({
    required this.icon,
    required this.title,
    this.onTap,
    this.trailing,
    this.iconColor,
    this.titleColor,
  });

  final IconData icon;
  final String title;
  final VoidCallback? onTap;
  final Widget? trailing;
  final Color? iconColor;
  final Color? titleColor;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: iconColor ?? context.appColors.textSecondary),
      title: Text(
        title,
        style: Theme.of(context)
            .textTheme
            .titleMedium
            ?.copyWith(color: titleColor),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: trailing ??
          (onTap != null
              ? Icon(Icons.chevron_right_rounded,
                  color: context.appColors.textSecondary)
              : null),
      onTap: onTap,
    );
  }
}

/// Logout confirmation as a bottom sheet (not a dialog) — drag handle,
/// coral confirm, grey cancel. Returns true if the user confirmed.
Future<bool> _showLogoutSheet(BuildContext context) async {
  final result = await AppBottomSheet.show<bool>(
    context,
    title: 'Log out?',
    initialSize: 0.32,
    minSize: 0.28,
    maxSize: 0.45,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Attendance tracking stops until you log in again.',
          style: AppTextStyles.body.copyWith(color: context.appColors.textSecondary),
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: AppDimens.grid * 3),
        Row(
          children: [
            Expanded(
              child: AppButton(
                label: 'Cancel',
                variant: AppButtonVariant.secondary,
                onPressed: () => Navigator.of(context).pop(false),
              ),
            ),
            const SizedBox(width: AppDimens.grid * 1.5),
            Expanded(
              child: AppButton(
                label: 'Log Out',
                variant: AppButtonVariant.danger,
                onPressed: () => Navigator.of(context).pop(true),
              ),
            ),
          ],
        ),
      ],
    ),
  );
  return result ?? false;
}
