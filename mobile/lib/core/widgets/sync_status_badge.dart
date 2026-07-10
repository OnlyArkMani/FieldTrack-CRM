import 'package:flutter/material.dart';

import '../theme/app_text_styles.dart';
import '../theme/app_theme.dart';

/// Small pill marking a row that only exists in the local offline queue —
/// `syncStatus` mirrors `DatabaseHelper`'s `*StatusPending` (0) /
/// `*StatusFailed` (2, still auto-retrying) / `*StatusNeedsAttention` (3)
/// convention across `pending_farmers`/`pending_visits`/etc. Pass `null`
/// (already synced, or not a locally-queued row) to render nothing.
class SyncStatusBadge extends StatelessWidget {
  const SyncStatusBadge({super.key, required this.syncStatus, this.compact = false});

  final int? syncStatus;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (syncStatus == null || syncStatus == 1) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final needsAttention = syncStatus == 3;
    final color = needsAttention ? scheme.error : scheme.primary;
    final label = needsAttention ? 'Needs attention' : 'Pending sync';
    final icon =
        needsAttention ? Icons.error_outline_rounded : Icons.cloud_upload_rounded;

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? AppDimens.grid * 0.75 : AppDimens.grid,
        vertical: compact ? 1 : 2,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: compact ? 10 : 12, color: color),
          const SizedBox(width: 3),
          Text(
            label,
            style: AppTextStyles.caption.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
              fontSize: compact ? 10 : null,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
