import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_text_styles.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/shimmer_card.dart';
import '../../../core/widgets/state_views.dart';
import '../models/app_notification.dart';
import '../providers/notification_provider.dart';

class NotificationsScreen extends ConsumerWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(notificationsProvider);
    final notifier = ref.read(notificationsProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/home/dashboard'),
        ),
        title: const Text(
          'Notifications',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (state.unread > 0)
            TextButton(
              onPressed: notifier.markAllRead,
              child: const Text('Mark all read'),
            ),
        ],
      ),
      body: SafeArea(
        child: _body(context, ref, state, notifier),
      ),
    );
  }

  Widget _body(
    BuildContext context,
    WidgetRef ref,
    NotificationsState state,
    NotificationsNotifier notifier,
  ) {
    if (state.isLoading) return const ShimmerList(count: 6);

    if (state.error != null && state.items.isEmpty) {
      return ErrorStateView(
        message: state.error!,
        onRetry: () => notifier.load(),
      );
    }

    if (state.items.isEmpty) {
      return const _AllCaughtUp();
    }

    return RefreshIndicator(
      onRefresh: () => notifier.load(silent: true),
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n.metrics.pixels >= n.metrics.maxScrollExtent - 240) {
            notifier.loadMore();
          }
          return false;
        },
        child: ListView.separated(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(AppDimens.grid * 2),
          itemCount: state.items.length + (state.isLoadingMore ? 1 : 0),
          separatorBuilder: (_, __) =>
              const SizedBox(height: AppDimens.grid * 1.5),
          itemBuilder: (context, i) {
            if (i >= state.items.length) {
              return const Padding(
                padding: EdgeInsets.all(AppDimens.grid * 2),
                child: Center(
                  child: SizedBox(
                    height: 22,
                    width: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              );
            }
            final item = state.items[i];
            return StaggeredEntrance(
              index: i,
              child: _NotificationTile(
                item: item,
                onTap: () => _onTap(context, notifier, item),
                onDismiss: () => notifier.dismiss(item.id),
              ),
            );
          },
        ),
      ),
    );
  }

  void _onTap(
    BuildContext context,
    NotificationsNotifier notifier,
    AppNotification item,
  ) {
    notifier.markRead(item.id);
    final route = item.type.inAppRoute;
    if (route != null) context.go(route);
  }
}

class _NotificationTile extends StatelessWidget {
  const _NotificationTile({
    required this.item,
    required this.onTap,
    required this.onDismiss,
  });

  final AppNotification item;
  final VoidCallback onTap;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final scheme = Theme.of(context).colorScheme;
    // Type-specific accent (e.g. geofence enter=green / exit=coral) takes
    // priority while unread; read rows mute to the secondary text colour.
    final accent = item.isRead
        ? colors.textSecondary
        : (item.type.accentColor ?? scheme.primary);

    return Dismissible(
      key: ValueKey(item.id),
      direction: DismissDirection.endToStart,
      onDismissed: (_) => onDismiss(),
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: AppDimens.grid * 3),
        decoration: BoxDecoration(
          color: scheme.error.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(AppDimens.cardRadius),
        ),
        child: Icon(Icons.check_circle_outline_rounded, color: scheme.error),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppDimens.cardRadius),
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeInOutCubic,
            padding: const EdgeInsets.all(AppDimens.grid * 2),
            decoration: BoxDecoration(
              color: colors.card,
              borderRadius: BorderRadius.circular(AppDimens.cardRadius),
              boxShadow: AppDimens.shadow(Theme.of(context).brightness),
              border: item.isRead
                  ? null
                  : Border.all(color: scheme.primary.withValues(alpha: 0.25)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: accent.withValues(alpha: 0.14),
                  ),
                  child: Icon(item.type.icon, color: accent, size: 22),
                ),
                const SizedBox(width: AppDimens.grid * 1.5),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              item.title,
                              style: AppTextStyles.bodyMedium.copyWith(
                                color: scheme.onSurface,
                                fontWeight: item.isRead
                                    ? FontWeight.w500
                                    : FontWeight.w700,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: AppDimens.grid),
                          Text(
                            item.relativeTime,
                            style: AppTextStyles.caption
                                .copyWith(color: colors.textSecondary),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (!item.isRead) ...[
                            const SizedBox(width: AppDimens.grid),
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: scheme.primary,
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: AppDimens.grid * 0.5),
                      Text(
                        item.body,
                        style: AppTextStyles.body
                            .copyWith(color: colors.textSecondary),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Empty state — "You're all caught up" with a soft checkmark badge.
class _AllCaughtUp extends StatelessWidget {
  const _AllCaughtUp();

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(AppDimens.grid * 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: scheme.primary.withValues(alpha: 0.12),
              ),
              child: Icon(
                Icons.check_circle_rounded,
                size: 48,
                color: scheme.primary,
              ),
            ),
            const SizedBox(height: AppDimens.grid * 3),
            Text(
              "You're all caught up",
              textAlign: TextAlign.center,
              style: AppTextStyles.heading.copyWith(color: scheme.onSurface),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: AppDimens.grid),
            Text(
              'New reminders and updates will show up here.',
              textAlign: TextAlign.center,
              style: AppTextStyles.body.copyWith(color: colors.textSecondary),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}
