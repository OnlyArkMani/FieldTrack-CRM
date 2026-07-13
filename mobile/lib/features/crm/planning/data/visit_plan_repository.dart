import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/network/api_client.dart';
import '../../../../core/network/api_exceptions.dart';
import '../../../../core/theme/app_theme.dart' show sharedPreferencesProvider;
import '../../../../local_db/database_helper.dart';
import '../../../../services/sync/connectivity_service.dart';
import '../../farmers/models/farmer.dart' show placeholderIdFromLocalId;
import '../models/visit_plan.dart';

final visitPlanRepositoryProvider = Provider<VisitPlanRepository>((ref) {
  return VisitPlanRepository(
    ref.watch(apiClientProvider),
    ref.watch(sharedPreferencesProvider),
    ref.watch(connectivityServiceProvider),
  );
});

/// Wrapper over the /visit-plans API. Reads (myPlan/teamPlans) fall back to
/// the last successful response when offline instead of surfacing a raw
/// "Something went wrong". `savePlan()` also queues offline now — see
/// docs/OFFLINE_SYNC_PLAN.md.
class VisitPlanRepository {
  VisitPlanRepository(this._api, this._prefs, this._connectivity);
  final ApiClient _api;
  final SharedPreferences _prefs;
  final ConnectivityService _connectivity;
  final _db = DatabaseHelper.instance;
  static const _uuid = Uuid();

  static String ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  static String _myPlanCacheKey(DateTime d) => 'cached_my_plan_${ymd(d)}';
  static String _teamPlansCacheKey(DateTime d) => 'cached_team_plans_${ymd(d)}';

  Future<MyPlan> myPlan(DateTime date) async {
    // Bug this fixes (same class as the Round 4 Leads/Vet throw-before-merge
    // bug): a missing cache used to throw immediately, before ever reaching
    // the merge steps below — so a plan-item action queued against a day
    // that was never opened online (e.g. the target date of a cross-day
    // move) could never surface here, since there was no base plan to
    // synthesize onto. Absence of a cache now only means "no base plan," it
    // no longer skips the merge; only throws if there's truly nothing (no
    // cache/server response AND nothing pending) to show.
    MyPlan? base;
    ApiException? networkError;
    // A whole-day resave (e.g. a delete-triggered save() that got queued
    // because the device was offline, or the online POST hit a transient
    // NoConnectionException/TimeoutException at save time) can still be
    // sitting unsynced here even though we're online right now — the sync
    // engine doesn't necessarily push it instantly. If so, the fetch below
    // would return the server's stale, pre-edit data.
    final queued = await _db.getPendingVisitPlan(ymd(date));
    try {
      final data = await _api.get('/visit-plans/my/${ymd(date)}');
      if (queued != null) {
        // Trust the cached optimistic result savePlan() wrote when it
        // queued this — it already reflects the edit — instead of the
        // fetch above, and don't let that stale fetch clobber the cache.
        base = _cachedMyPlan(date) ?? MyPlan.fromJson(data);
      } else {
        unawaited(_prefs.setString(_myPlanCacheKey(date), jsonEncode(data)));
        base = MyPlan.fromJson(data);
      }
    } on NoConnectionException catch (e) {
      base = _cachedMyPlan(date);
      networkError = e;
    } on TimeoutException catch (e) {
      base = _cachedMyPlan(date);
      networkError = e;
    }
    final withVisits = await _applyPendingVisitProgress(base ?? MyPlan(planDate: date));
    final result = await _applyPendingPlanItemActions(withVisits);
    if (base == null && result.items.isEmpty) throw networkError!;
    return result;
  }

  /// Neither a fresh server response nor a cached one can know about a
  /// skip/carry-over/cross-day-move/status-update queued offline against one
  /// of this plan's items (see docs/OFFLINE_SYNC_PLAN.md — these have no
  /// whole-day upsert to piggyback on the way same-day field edits do via
  /// savePlan(), so they get their own small queue,
  /// `pending_plan_item_actions`). Matched purely by item id — whichever
  /// day's plan happens to contain that item gets the pending effect, no
  /// date bookkeeping needed on the action itself.
  ///
  /// Scope: a queued 'skip'/'carry_over'/'update_status' patches the item's
  /// status to SKIPPED (or whatever `update_status` asked for) so it drops
  /// out of the carry-over section immediately, matching what the server
  /// actually does on skip/carry-over. A queued cross-day 'update_item'
  /// removes the item from its *source* day's list (it moved away, same as
  /// what a fresh server reload would show) and, if the day currently being
  /// viewed IS the move's target date, synthesizes it there instead from
  /// the snapshot captured when the move was queued — so the item shows up
  /// on the day you moved it to immediately, not just once sync completes.
  Future<MyPlan> _applyPendingPlanItemActions(MyPlan plan) async {
    final actions = await _db.getAllUnsyncedPlanItemActions();
    if (actions.isEmpty) return plan;

    final statusPatch = <int, String>{};
    final removedIds = <int>{};
    final toAppend = <PlanItem>[];
    final planDateStr = ymd(plan.planDate);
    for (final a in actions) {
      final payload = jsonDecode(a.payloadJson) as Map<String, dynamic>;
      switch (a.action) {
        case 'skip':
        case 'carry_over':
          statusPatch[a.itemId] = 'SKIPPED';
        case 'update_status':
          final status = payload['status'] as String?;
          if (status != null) statusPatch[a.itemId] = status;
        case 'update_item':
          final targetDate = payload['plan_date'] as String?;
          if (targetDate == null) break;
          removedIds.add(a.itemId);
          if (targetDate == planDateStr && a.itemSnapshotJson != null) {
            final snapshot = jsonDecode(a.itemSnapshotJson!) as Map<String, dynamic>;
            toAppend.add(PlanItem.fromJson({
              ...snapshot,
              ...payload,
              'status': 'PLANNED',
            }));
          }
      }
    }
    if (statusPatch.isEmpty && removedIds.isEmpty && toAppend.isEmpty) return plan;

    final existingIds = plan.items.map((i) => i.id).toSet();
    return MyPlan(
      id: plan.id,
      planDate: plan.planDate,
      status: plan.status,
      submittedAt: plan.submittedAt,
      isOnLeave: plan.isOnLeave,
      items: [
        for (final item in plan.items)
          if (!removedIds.contains(item.id))
            statusPatch.containsKey(item.id)
                ? item.copyWith(status: statusPatch[item.id])
                : item,
        // Guards against showing it twice if it somehow already synced onto
        // this day by the time this particular myPlan() call landed.
        for (final synth in toAppend)
          if (!existingIds.contains(synth.id)) synth,
      ],
    );
  }

  /// Neither a fresh server response nor a cached one can know about a
  /// check-in/complete that only exists locally in `pending_visits` and
  /// hasn't synced yet (this applies even when freshly fetched online — if
  /// the visit itself was completed offline, the server genuinely doesn't
  /// know yet either). Patches matching plan items' status directly so
  /// completing a visit is reflected here immediately instead of waiting
  /// for the whole visit to sync.
  Future<MyPlan> _applyPendingVisitProgress(MyPlan plan) async {
    final visits = await _db.getAllUnsyncedVisits();
    if (visits.isEmpty) return plan;
    final statusByPlanItemId = <int, String>{};
    for (final v in visits) {
      final checkIn = v.checkInPayloadJson.isEmpty || v.checkInPayloadJson == '{}'
          ? const <String, dynamic>{}
          : jsonDecode(v.checkInPayloadJson) as Map<String, dynamic>;
      // plan_item_id: real server ID (online check-in or resolved after sync).
      // _local_plan_item_id: negative timestamp set during offline check-in
      // from an offline-created plan. The synthesized PlanItem in the plan list
      // already carries that same negative ID, so matching by it works here.
      final planItemId =
          (checkIn['plan_item_id'] as int?) ?? (checkIn['_local_plan_item_id'] as int?);
      if (planItemId == null) continue;
      statusByPlanItemId[planItemId] = v.completeJson != null ? 'COMPLETED' : 'IN_PROGRESS';
    }
    if (statusByPlanItemId.isEmpty) return plan;
    return MyPlan(
      id: plan.id,
      planDate: plan.planDate,
      status: plan.status,
      submittedAt: plan.submittedAt,
      isOnLeave: plan.isOnLeave,
      items: [
        for (final item in plan.items)
          statusByPlanItemId.containsKey(item.id)
              ? item.copyWith(status: statusByPlanItemId[item.id])
              : item,
      ],
    );
  }

  MyPlan? _cachedMyPlan(DateTime date) {
    final json = _prefs.getString(_myPlanCacheKey(date));
    if (json == null) return null;
    try {
      return MyPlan.fromJson(jsonDecode(json) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// Manager/admin only: the caller's team's plans for a date.
  Future<TeamPlans> teamPlans(DateTime date) async {
    try {
      final data = await _api.get('/visit-plans/team/${ymd(date)}');
      unawaited(_prefs.setString(_teamPlansCacheKey(date), jsonEncode(data)));
      return TeamPlans.fromJson(data);
    } on NoConnectionException catch (e) {
      return _cachedTeamPlans(date) ?? (throw e);
    } on TimeoutException catch (e) {
      return _cachedTeamPlans(date) ?? (throw e);
    }
  }

  TeamPlans? _cachedTeamPlans(DateTime date) {
    final json = _prefs.getString(_teamPlansCacheKey(date));
    if (json == null) return null;
    try {
      return TeamPlans.fromJson(jsonDecode(json) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// Upsert the day's plan. Items are sent in their current order; the server
  /// stores sequence_order and flips status to SUBMITTED.
  ///
  /// Falls back to the offline queue on network failure even if
  /// ConnectivityService.current says online — that cached value can be stale
  /// by up to 30s + 3s ping, so a device that just went offline may still read
  /// current=true for a short window.
  Future<MyPlan> savePlan(DateTime date, List<PlanItem> items) async {
    final itemInputs = [
      for (var i = 0; i < items.length; i++) items[i].toInput(i),
    ];
    if (_connectivity.current) {
      try {
        final data = await _api.post('/visit-plans',
            body: {'plan_date': ymd(date), 'items': itemInputs});
        return MyPlan.fromJson(data);
      } on NoConnectionException {
        // stale connectivity cache — fall through to offline save below
      } on TimeoutException {
        // stale connectivity cache — fall through to offline save below
      }
    }
    // A farmer_id here can be a placeholder (an offline-created farmer,
    // not yet synced). By the time this plan itself syncs, that farmer
    // may have already synced AND been removed from pending_farmers — so
    // the placeholder can no longer be resolved by scanning the unsynced
    // set the way VisitRepository does. Stash the farmer's local_id
    // alongside the placeholder so the sync engine can resolve it via
    // id_mappings regardless (that mapping persists permanently).
    final unsynced = await _db.getAllUnsyncedFarmers();
    // Fixes the farmer-race gap: id_mappings now gets a row the moment a
    // farmer is created offline (see
    // DatabaseHelper.insertIdMappingPlaceholder), not only once it syncs,
    // so this scan still finds the local_id even if the farmer synced
    // away in a blip between being created and this plan being saved —
    // pending_farmers alone can no longer answer that by then.
    final allFarmerLocalIds = await _db.getFarmerIdMappingLocalIds();
    String? findLocalId(int placeholderId) {
      for (final f in unsynced) {
        if (placeholderIdFromLocalId(f.localId) == placeholderId) return f.localId;
      }
      for (final localId in allFarmerLocalIds) {
        if (placeholderIdFromLocalId(localId) == placeholderId) return localId;
      }
      return null;
    }
    final offlineItems = [
      for (var i = 0; i < itemInputs.length; i++)
        {
          ...itemInputs[i],
          // Stash the negative local item ID so the sync engine can store the
          // server ID in id_mappings after the plan POSTs, enabling the visit
          // check-in to inject the real plan_item_id when it syncs later.
          if (items[i].id < 0) '_local_item_id': items[i].id,
          if ((itemInputs[i]['farmer_id'] as int) < 0)
            '_farmer_local_id': findLocalId(itemInputs[i]['farmer_id'] as int),
        },
    ];
    await _db.upsertPendingVisitPlan(
      planDate: ymd(date),
      itemsJson: jsonEncode(offlineItems),
    );
    // Optimistic: same items back with an incremented sequence + SUBMITTED
    // status, so the screen's "saved" state (isSaved: plan.isSubmitted &&
    // !dirty) reflects the save immediately, same as the online path.
    final optimistic = MyPlan(
      planDate: date,
      status: 'SUBMITTED',
      submittedAt: DateTime.now(),
      items: [
        for (var i = 0; i < items.length; i++)
          items[i].copyWith(sequenceOrder: i),
      ],
    );
    // Bug this fixes: without this, myPlan(date)'s offline fallback found
    // no cache for a date that was only ever saved offline (never
    // successfully fetched from the server), threw, and the screen's
    // clearPlan-on-failed-fetch behavior made the just-saved plan appear
    // to vanish the moment you navigated back to it. Cache the optimistic
    // result exactly like an online fetch would, so it's found on return.
    unawaited(
        _prefs.setString(_myPlanCacheKey(date), jsonEncode(optimistic.toJson())));
    return optimistic;
  }

  /// Every caller of updateItemStatus/updateItem/carryOver/skipItem
  /// discards the returned MyPlan and calls myPlan() again right after (see
  /// VisitPlanNotifier.editItem/rescheduleCarryOver/dropCarryOver) — so the
  /// offline branches below only need to queue the action; the placeholder
  /// they return is never read. The real effect surfaces through
  /// _applyPendingPlanItemActions on that next myPlan() call.
  static final _unusedOfflinePlaceholder =
      MyPlan(planDate: DateTime.fromMillisecondsSinceEpoch(0));

  Future<void> _queuePlanItemAction(
    int itemId,
    String action,
    Map<String, dynamic> payload, {
    String? itemSnapshotJson,
  }) {
    return _db.insertPendingPlanItemAction(
      localId: _uuid.v4(),
      itemId: itemId,
      action: action,
      payloadJson: jsonEncode(payload),
      itemSnapshotJson: itemSnapshotJson,
    );
  }

  Future<MyPlan> updateItemStatus(
    int planId,
    int itemId, {
    required String status,
  }) async {
    if (!_connectivity.current) {
      // planId travels inside the payload (not a dedicated column) since
      // the PATCH endpoint this eventually replays against needs both ids.
      await _queuePlanItemAction(
          itemId, 'update_status', {'status': status, 'plan_id': planId});
      return _unusedOfflinePlaceholder;
    }
    final data = await _api.patch(
      '/visit-plans/$planId/items/$itemId',
      body: {'status': status},
    );
    return MyPlan.fromJson(data);
  }

  /// Edit a still-PLANNED item's time, purpose, target bags, or day. Only the
  /// fields passed are changed; a non-null [planDate] moves it onto that day's
  /// plan. Rejected server-side once the item's been checked in.
  ///
  /// Same-day offline edits never reach here — VisitPlanNotifier.editItem
  /// intercepts that case itself via the already-offline-capable savePlan().
  /// This offline branch only ever actually fires for a cross-day move.
  /// [sourceItem] (the full item being moved, as currently displayed) is
  /// only used to snapshot enough to synthesize the item on its target
  /// day's plan before the move syncs — see
  /// _applyPendingPlanItemActions. Ignored for the online call.
  Future<MyPlan> updateItem(
    int itemId, {
    String? timeSlot, // "HH:MM:SS"
    String? purpose,
    String? notes,
    int? targetOrderBags,
    DateTime? planDate,
    PlanItem? sourceItem,
  }) async {
    if (!_connectivity.current) {
      await _queuePlanItemAction(
        itemId,
        'update_item',
        {
          if (timeSlot != null) 'time_slot': timeSlot,
          if (purpose != null) 'purpose': purpose,
          if (notes != null) 'notes': notes,
          if (targetOrderBags != null) 'target_order_bags': targetOrderBags,
          if (planDate != null) 'plan_date': ymd(planDate),
        },
        itemSnapshotJson:
            planDate != null && sourceItem != null ? jsonEncode(sourceItem.toJson()) : null,
      );
      return _unusedOfflinePlaceholder;
    }
    final data = await _api.patch('/visit-plans/items/$itemId', body: {
      if (timeSlot != null) 'time_slot': timeSlot,
      if (purpose != null) 'purpose': purpose,
      if (notes != null) 'notes': notes,
      if (targetOrderBags != null) 'target_order_bags': targetOrderBags,
      if (planDate != null) 'plan_date': ymd(planDate),
    });
    return MyPlan.fromJson(data);
  }

  /// Reschedule a missed (carried-over) item onto [targetDate] with an optional
  /// time. The source item is skipped server-side. Returns the target plan.
  ///
  /// Offline: the source item drops out of today's carry-over section
  /// immediately (see _applyPendingPlanItemActions), same as a real skip.
  /// The target day won't show the rescheduled item until this syncs —
  /// known, accepted scope cut (see docs/OFFLINE_SYNC_PLAN.md); it fails
  /// toward "briefly incomplete," never toward a duplicated item.
  Future<MyPlan> carryOver(
    int itemId, {
    required DateTime targetDate,
    String? timeSlot, // "HH:MM:SS"
  }) async {
    if (!_connectivity.current) {
      await _queuePlanItemAction(itemId, 'carry_over', {
        'target_date': ymd(targetDate),
        if (timeSlot != null) 'time_slot': timeSlot,
      });
      return _unusedOfflinePlaceholder;
    }
    final data = await _api.post('/visit-plans/items/$itemId/carry-over', body: {
      'target_date': ymd(targetDate),
      if (timeSlot != null) 'time_slot': timeSlot,
    });
    return MyPlan.fromJson(data);
  }

  /// Drop a missed (carried-over) item — marks it SKIPPED server-side.
  Future<MyPlan> skipItem(int itemId) async {
    if (!_connectivity.current) {
      await _queuePlanItemAction(itemId, 'skip', const {});
      return _unusedOfflinePlaceholder;
    }
    final data = await _api.post('/visit-plans/items/$itemId/skip');
    return MyPlan.fromJson(data);
  }
}
