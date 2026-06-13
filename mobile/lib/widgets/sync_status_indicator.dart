import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/app_text_styles.dart';
import '../core/theme/app_theme.dart';
import '../services/sync/sync_engine.dart';
import '../services/sync/sync_status_provider.dart';

/// Compact, unobtrusive sync chip for app bars / screen tops.
///   • green dot   + "Synced"                 — caught up
///   • amber dot   + "N pending"               — queued, waiting (online)
///   • spinner     + "Syncing…"                — a pass is running
///   • red dot     + "Sync failed"             — tap to retry now
///   • grey cloud  + "Offline · N saved locally" — offline w/ buffered data;
///                  tap → reassurance bottom sheet
/// States cross-fade via AnimatedSwitcher so it never jumps or distracts.
class SyncStatusIndicator extends ConsumerWidget {
  const SyncStatusIndicator({super.key, this.compact = false});

  /// compact = dot only (for tight app bars); full = dot + label pill.
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sync = ref.watch(syncStatusProvider);
    final colors = context.appColors;

    // Offline-with-pending takes precedence: it's the reassuring "your GPS is
    // still recording" state, more important than a stale "N pending".
    final _Visual v;
    if (sync.isOfflineWithPending) {
      v = _Visual(
        color: colors.statusOffline,
        label: 'Offline · ${sync.pendingCount} saved locally',
        icon: Icons.cloud_off_rounded,
      );
    } else {
      v = switch (sync.phase) {
        SyncPhase.syncing => _Visual(
            color: Theme.of(context).colorScheme.secondary,
            label: 'Syncing…',
            spinner: true,
          ),
        SyncPhase.failed => _Visual(
            color: colors.statusGpsDisabled,
            label: 'Sync failed',
          ),
        SyncPhase.idle => sync.pendingCount > 0
            ? _Visual(color: colors.statusIdle, label: '${sync.pendingCount} pending')
            : _Visual(color: colors.statusActive, label: 'Synced'),
      };
    }

    final offline = sync.isOfflineWithPending;
    final retryable = !offline && sync.phase == SyncPhase.failed;

    final child = Container(
      key: ValueKey('${offline ? 'offline' : sync.phase}-${sync.pendingCount}'),
      padding: EdgeInsets.symmetric(
        horizontal: compact ? AppDimens.grid : AppDimens.grid * 1.5,
        vertical: AppDimens.grid * 0.5,
      ),
      decoration: BoxDecoration(
        color: v.color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 12,
            height: 12,
            child: v.spinner
                ? CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation(v.color),
                  )
                : v.icon != null
                    ? Icon(v.icon, size: 12, color: v.color)
                    : Center(
                        child: Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                              color: v.color, shape: BoxShape.circle),
                        ),
                      ),
          ),
          if (!compact) ...[
            const SizedBox(width: AppDimens.grid),
            Flexible(
              child: Text(
                v.label,
                style: AppTextStyles.caption.copyWith(
                  color: v.color,
                  fontWeight: FontWeight.w500,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (retryable) ...[
              const SizedBox(width: 2),
              Icon(Icons.refresh_rounded, size: 13, color: v.color),
            ],
          ],
        ],
      ),
    );

    final indicator = AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      switchInCurve: Curves.easeInOutCubic,
      switchOutCurve: Curves.easeInOutCubic,
      transitionBuilder: (c, a) => FadeTransition(
        opacity: a,
        child: ScaleTransition(scale: a, child: c),
      ),
      child: child,
    );

    if (!offline && !retryable) return indicator;
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: () {
        if (offline) {
          _showOfflineSheet(context);
        } else {
          ref.read(syncEngineProvider).syncNow();
        }
      },
      child: indicator,
    );
  }

  void _showOfflineSheet(BuildContext context) {
    final colors = context.appColors;
    final scheme = Theme.of(context).colorScheme;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: colors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppDimens.sheetRadius)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppDimens.grid * 3),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.cloud_off_rounded, color: colors.statusOffline),
                  const SizedBox(width: AppDimens.grid * 1.5),
                  Text(
                    'Saving locally',
                    style: AppTextStyles.heading.copyWith(color: scheme.onSurface),
                  ),
                ],
              ),
              const SizedBox(height: AppDimens.grid * 1.5),
              Text(
                'Your location is being saved on your device. It will '
                'automatically upload when internet is restored. No data will '
                'be lost.',
                style: AppTextStyles.body.copyWith(color: colors.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Visual {
  const _Visual({
    required this.color,
    required this.label,
    this.spinner = false,
    this.icon,
  });
  final Color color;
  final String label;
  final bool spinner;
  final IconData? icon;
}
