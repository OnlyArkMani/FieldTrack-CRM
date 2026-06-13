import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_text_styles.dart';
import '../../../core/theme/app_theme.dart';
import '../../../services/notification/fcm_service.dart';
import '../../../services/sync/sync_engine.dart';

/// Bottom-nav shell around the 4 tabs. The active indicator is a pill that
/// glides between items (AnimatedAlign, easeInOutCubic — same water feel as
/// page transitions; a cross-route Hero can't animate inside a persistent
/// shell, so the glide IS the hero treatment here).
///
/// This is the authenticated root: watching [syncEngineProvider] here keeps the
/// background sync engine alive for the whole logged-in session and disposes it
/// (stopping sync) when the shell unmounts on logout.
class HomeShell extends ConsumerWidget {
  const HomeShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  static const _tabs = [
    (icon: Icons.dashboard_rounded, label: 'Dashboard'),
    (icon: Icons.fingerprint_rounded, label: 'Attendance'),
    (icon: Icons.map_rounded, label: 'Map'),
    (icon: Icons.person_rounded, label: 'Profile'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(syncEngineProvider); // keep the sync engine running while logged in
    ref.watch(fcmControllerProvider); // register FCM token + route taps while logged in
    final colors = context.appColors;
    final scheme = Theme.of(context).colorScheme;
    final index = navigationShell.currentIndex;

    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: colors.card,
          boxShadow: AppDimens.shadow(Theme.of(context).brightness),
          border: Border(
            top: BorderSide(
              color: colors.textSecondary.withValues(alpha: 0.12),
            ),
          ),
        ),
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: 64,
            child: Stack(
              children: [
                // Gliding active indicator
                AnimatedAlign(
                  duration: const Duration(milliseconds: 350),
                  curve: Curves.easeInOutCubic,
                  alignment: Alignment(
                    -1 + (index * 2 / (_tabs.length - 1)),
                    0,
                  ),
                  child: FractionallySizedBox(
                    widthFactor: 1 / _tabs.length,
                    child: Center(
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 350),
                        curve: Curves.easeInOutCubic,
                        width: 56,
                        height: 32,
                        decoration: BoxDecoration(
                          color: scheme.primary.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                    ),
                  ),
                ),
                Row(
                  children: List.generate(_tabs.length, (i) {
                    final tab = _tabs[i];
                    final selected = i == index;
                    return Expanded(
                      child: InkWell(
                        onTap: () => navigationShell.goBranch(
                          i,
                          initialLocation: i == index,
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            AnimatedScale(
                              scale: selected ? 1.1 : 1.0,
                              duration: const Duration(milliseconds: 200),
                              curve: Curves.easeInOutCubic,
                              child: Icon(
                                tab.icon,
                                size: 24,
                                color: selected
                                    ? scheme.primary
                                    : colors.textSecondary,
                              ),
                            ),
                            const SizedBox(height: 2),
                            AnimatedSwitcher(
                              duration: const Duration(milliseconds: 200),
                              child: selected
                                  ? Text(
                                      tab.label,
                                      key: const ValueKey('label'),
                                      style: AppTextStyles.caption.copyWith(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w600,
                                        color: scheme.primary,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    )
                                  : const SizedBox(
                                      key: ValueKey('no_label'), height: 12),
                            ),
                          ],
                        ),
                      ),
                    );
                  }),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
