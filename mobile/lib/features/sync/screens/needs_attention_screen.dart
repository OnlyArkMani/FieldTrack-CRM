import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_text_styles.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/confirm_dialog.dart';
import '../../../core/widgets/shimmer_card.dart';
import '../../../core/widgets/state_views.dart';
import '../../../features/crm/farmers/widgets/edit_pending_farmer_sheet.dart';
import '../../../services/sync/sync_engine.dart';
import '../data/needs_attention_repository.dart';
import '../models/needs_attention_item.dart';
import '../providers/needs_attention_provider.dart';

/// Lists every locally-queued row (farmer, visit, visit plan, leave
/// request) that the server rejected and stopped auto-retrying — these
/// exist correctly today but were previously invisible to the user (see
/// docs/OFFLINE_SYNC_PLAN.md "Known gaps"). Each row offers Retry (try the
/// same data again — useful once whatever the server objected to is fixed
/// elsewhere, e.g. a duplicate phone number was freed up) or Discard
/// (abandon the change, deletes the local row).
class NeedsAttentionScreen extends ConsumerWidget {
  const NeedsAttentionScreen({super.key});

  IconData _icon(NeedsAttentionKind kind) => switch (kind) {
        NeedsAttentionKind.farmer => Icons.person_add_alt_1_rounded,
        NeedsAttentionKind.visit => Icons.place_rounded,
        NeedsAttentionKind.visitPlan => Icons.event_note_rounded,
        NeedsAttentionKind.leaveRequest => Icons.beach_access_rounded,
        NeedsAttentionKind.planItemAction => Icons.event_note_rounded,
      };

  Future<void> _retry(BuildContext context, WidgetRef ref, NeedsAttentionItem item) async {
    await ref.read(needsAttentionRepositoryProvider).retry(item);
    // Kick a sync pass immediately rather than waiting for the next
    // connectivity event / periodic tick — the user just asked for this.
    unawaited(ref.read(syncEngineProvider).syncNow());
    HapticFeedback.selectionClick();
    ref.invalidate(needsAttentionProvider);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Retrying — will sync when back online.')),
      );
    }
  }

  Future<void> _edit(BuildContext context, WidgetRef ref, NeedsAttentionItem item) async {
    final saved = await EditPendingFarmerSheet.show(context, localId: item.key);
    if (saved) ref.invalidate(needsAttentionProvider);
  }

  Future<void> _discard(BuildContext context, WidgetRef ref, NeedsAttentionItem item) async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Discard this change?',
      message:
          "This can't be undone — it will never be sent to the server.",
      confirmLabel: 'Discard',
      danger: true,
    );
    if (!confirmed) return;
    await ref.read(needsAttentionRepositoryProvider).discard(item);
    HapticFeedback.mediumImpact();
    ref.invalidate(needsAttentionProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(needsAttentionProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Needs attention',
            maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: SafeArea(
        child: async.when(
          loading: () => const ShimmerList(count: 3),
          error: (e, _) => ErrorStateView(
            message: e.toString(),
            onRetry: () => ref.invalidate(needsAttentionProvider),
          ),
          data: (items) {
            if (items.isEmpty) {
              return const EmptyStateView(
                icon: Icons.task_alt_rounded,
                title: 'Nothing needs attention',
                message: 'Rejected offline changes will show up here.',
              );
            }
            return RefreshIndicator(
              onRefresh: () async => ref.invalidate(needsAttentionProvider),
              child: ListView.separated(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(AppDimens.grid * 2),
                itemCount: items.length,
                separatorBuilder: (_, __) =>
                    const SizedBox(height: AppDimens.grid * 1.5),
                itemBuilder: (context, i) {
                  final item = items[i];
                  final colors = context.appColors;
                  final scheme = Theme.of(context).colorScheme;
                  return AppCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(_icon(item.kind), size: 18, color: scheme.error),
                            const SizedBox(width: AppDimens.grid),
                            Expanded(
                              child: Text(
                                item.title,
                                style: AppTextStyles.bodyMedium
                                    .copyWith(color: scheme.onSurface),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        if (item.subtitle != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            item.subtitle!,
                            style: AppTextStyles.caption
                                .copyWith(color: colors.textSecondary),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                        const SizedBox(height: AppDimens.grid),
                        Container(
                          padding: const EdgeInsets.all(AppDimens.grid),
                          decoration: BoxDecoration(
                            color: scheme.error.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(AppDimens.buttonRadius),
                          ),
                          child: Text(
                            item.error,
                            style: AppTextStyles.caption.copyWith(color: scheme.error),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(height: AppDimens.grid * 1.5),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: () => _discard(context, ref, item),
                                icon: const Icon(Icons.delete_outline_rounded, size: 16),
                                label: const Text('Discard'),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: scheme.error,
                                  side: BorderSide(color: scheme.error.withValues(alpha: 0.5)),
                                ),
                              ),
                            ),
                            const SizedBox(width: AppDimens.grid),
                            Expanded(
                              child: item.kind == NeedsAttentionKind.farmer
                                  ? FilledButton.icon(
                                      onPressed: () => _edit(context, ref, item),
                                      icon: const Icon(Icons.edit_rounded, size: 16),
                                      label: const Text('Edit'),
                                    )
                                  : FilledButton.icon(
                                      onPressed: () => _retry(context, ref, item),
                                      icon: const Icon(Icons.refresh_rounded, size: 16),
                                      label: const Text('Retry'),
                                    ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  );
                },
              ),
            );
          },
        ),
      ),
    );
  }
}
