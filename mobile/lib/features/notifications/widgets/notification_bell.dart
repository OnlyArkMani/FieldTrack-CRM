import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/notification_provider.dart';

/// AppBar bell with an unread badge. Reads [unreadCountProvider] (best-effort:
/// a failed/loading count just shows no badge). Tapping opens the list.
class NotificationBell extends ConsumerWidget {
  const NotificationBell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    // Prefer the live list count when the screen is mounted; otherwise the
    // standalone badge query. Both converge after any read.
    final listUnread = ref.watch(notificationsProvider).unread;
    final fetched = ref.watch(unreadCountProvider).valueOrNull ?? 0;
    final count = listUnread > 0 ? listUnread : fetched;

    return Stack(
      alignment: Alignment.center,
      children: [
        IconButton(
          icon: const Icon(Icons.notifications_none_rounded),
          tooltip: 'Notifications',
          onPressed: () => context.push('/notifications'),
        ),
        if (count > 0)
          Positioned(
            top: 8,
            right: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
              decoration: BoxDecoration(
                color: scheme.error,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: scheme.surface, width: 1.5),
              ),
              child: Text(
                count > 99 ? '99+' : '$count',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: scheme.onError,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  height: 1.2,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
      ],
    );
  }
}
