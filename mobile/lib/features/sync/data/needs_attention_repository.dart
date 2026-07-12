import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../local_db/database_helper.dart';
import '../models/needs_attention_item.dart';

final needsAttentionRepositoryProvider = Provider<NeedsAttentionRepository>((ref) {
  return NeedsAttentionRepository();
});

/// Aggregates every `sync_status = needs_attention` row across the four
/// offline queues (farmers, visits, visit plans, leave requests) into one
/// list for the "Needs attention" screen — these rows exist and are
/// correctly excluded from auto-retry (see docs/OFFLINE_SYNC_PLAN.md), but
/// were previously invisible to the user; nothing surfaced them.
class NeedsAttentionRepository {
  final _db = DatabaseHelper.instance;

  Future<List<NeedsAttentionItem>> list() async {
    final farmers = await _db.getFarmersNeedingAttention();
    final visits = await _db.getVisitsNeedingAttention();
    final plans = await _db.getVisitPlansNeedingAttention();
    final leaves = await _db.getLeaveRequestsNeedingAttention();
    final planItemActions = await _db.getPlanItemActionsNeedingAttention();

    final items = <NeedsAttentionItem>[
      for (final f in farmers)
        NeedsAttentionItem(
          kind: NeedsAttentionKind.farmer,
          key: f.localId,
          title: _farmerName(f.payloadJson),
          subtitle: 'New customer',
          error: f.syncError ?? 'Rejected by the server.',
          createdAt: f.createdAt,
        ),
      for (final v in visits)
        NeedsAttentionItem(
          kind: NeedsAttentionKind.visit,
          key: v.localId,
          title: 'Visit',
          subtitle: await _visitSubtitle(v),
          error: v.syncError ?? 'Rejected by the server.',
          createdAt: v.createdAt,
        ),
      for (final p in plans)
        NeedsAttentionItem(
          kind: NeedsAttentionKind.visitPlan,
          key: p.planDate,
          title: 'Visit plan — ${p.planDate}',
          subtitle: _planSubtitle(p.itemsJson),
          error: p.syncError ?? 'Rejected by the server.',
          createdAt: p.createdAt,
        ),
      for (final l in leaves)
        NeedsAttentionItem(
          kind: NeedsAttentionKind.leaveRequest,
          key: l.leaveDate,
          title: 'Leave request — ${l.leaveDate}',
          error: l.syncError ?? 'Rejected by the server.',
          createdAt: l.createdAt,
        ),
      for (final p in planItemActions)
        NeedsAttentionItem(
          kind: NeedsAttentionKind.planItemAction,
          key: p.localId,
          title: _planActionTitle(p.action),
          subtitle: 'Plan item #${p.itemId}',
          error: p.syncError ?? 'Rejected by the server.',
          createdAt: p.createdAt,
        ),
    ];
    items.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return items;
  }

  String _planActionTitle(String action) => switch (action) {
        'skip' => 'Skip visit plan stop',
        'carry_over' => 'Reschedule visit plan stop',
        'update_item' => 'Move visit plan stop',
        'update_status' => 'Update visit plan stop',
        _ => 'Visit plan change',
      };

  String _farmerName(String payloadJson) {
    try {
      final payload = jsonDecode(payloadJson) as Map<String, dynamic>;
      return (payload['name'] as String?)?.trim().isNotEmpty == true
          ? payload['name'] as String
          : 'Unnamed customer';
    } catch (_) {
      return 'Unnamed customer';
    }
  }

  String _planSubtitle(String itemsJson) {
    try {
      final items = jsonDecode(itemsJson) as List<dynamic>;
      return '${items.length} stop${items.length == 1 ? '' : 's'}';
    } catch (_) {
      return 'Visit plan';
    }
  }

  Future<String> _visitSubtitle(PendingVisit v) async {
    final farmerName = await _resolveFarmerName(v.farmerServerId, v.farmerLocalId);
    if (v.completeJson != null) return '$farmerName · completing visit';
    return '$farmerName · checking in';
  }

  Future<String> _resolveFarmerName(int? farmerServerId, String? farmerLocalId) async {
    if (farmerServerId != null) {
      final json = await _db.getCachedFarmerJson(farmerServerId);
      if (json == null) return 'Unknown farmer';
      final f = jsonDecode(json) as Map<String, dynamic>;
      return (f['name'] as String?) ?? 'Unknown farmer';
    }
    if (farmerLocalId != null) {
      final row = await _db.getPendingFarmer(farmerLocalId);
      if (row != null) {
        final f = jsonDecode(row.payloadJson) as Map<String, dynamic>;
        return (f['name'] as String?) ?? 'Unknown farmer';
      }
    }
    return 'Unknown farmer';
  }

  /// The row is un-flagged (flips back to pending, sync_error cleared) so
  /// the sync engine's next pass retries it — used both for a plain "try
  /// again" and after an edit (e.g. FarmerRepository.updatePending).
  Future<void> retry(NeedsAttentionItem item) async {
    switch (item.kind) {
      case NeedsAttentionKind.farmer:
        await _db.requeueFarmer(item.key);
      case NeedsAttentionKind.visit:
        await _db.requeueVisit(item.key);
      case NeedsAttentionKind.visitPlan:
        await _db.requeueVisitPlan(item.key);
      case NeedsAttentionKind.leaveRequest:
        await _db.requeueLeaveRequest(item.key);
      case NeedsAttentionKind.planItemAction:
        await _db.requeuePlanItemAction(item.key);
    }
  }

  /// Abandons the change entirely — the row is deleted, nothing is sent to
  /// the server. Irreversible; the screen confirms before calling this.
  Future<void> discard(NeedsAttentionItem item) async {
    switch (item.kind) {
      case NeedsAttentionKind.farmer:
        await _db.deletePendingFarmer(item.key);
      case NeedsAttentionKind.visit:
        await _db.deletePendingVisit(item.key);
      case NeedsAttentionKind.visitPlan:
        await _db.deletePendingVisitPlan(item.key);
      case NeedsAttentionKind.leaveRequest:
        await _db.deletePendingLeaveRequest(item.key);
      case NeedsAttentionKind.planItemAction:
        await _db.deletePendingPlanItemAction(item.key);
    }
  }
}
