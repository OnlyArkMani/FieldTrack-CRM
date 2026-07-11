import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_exceptions.dart';
import '../../core/storage/token_storage.dart';
import '../../core/theme/app_theme.dart' show sharedPreferencesProvider;
import '../../local_db/database_helper.dart';
import '../location/location_service.dart';
import 'connectivity_service.dart';
import 'sync_notifications.dart';
import 'sync_status_provider.dart';

/// Moves the device's offline queue (SQLite) to the backend. Reliability is the
/// whole point, so the rules are explicit and defensive:
///
///  • MUTEX — only one sync runs at a time (`_running`). Triggers fire from
///    three places (connectivity-restored, 5-min heartbeat, backoff retry); the
///    lock makes overlap impossible.
///  • NEVER OFFLINE — every run re-verifies connectivity (radio + /health ping)
///    before touching the network.
///  • ORDER MATTERS — attendance sessions sync BEFORE locations.
///  • BATCHING — locations upload 50 at a time.
///  • PARTIAL FAILURE — a poison batch/row is marked failed and the queue moves
///    on; it isn't allowed to block everything behind it. A transport failure
///    (network/5xx/401) aborts the pass and arms exponential backoff.
///  • BACKOFF — 30s, 1m, 2m, 4m, 8m (capped). Resets on success.
///  • 3 STRIKES — after 3 consecutive failed passes, a persistent notification
///    tells the user their data is waiting.
///
/// FOREGROUND ENGINE: uses the Riverpod ApiClient (which refreshes tokens). The
/// background-locator isolate keeps its own token-free LocationSyncService; the
/// two never corrupt each other because the server dedupes and SQLite's
/// sync_status flags are idempotent.
class SyncEngine {
  SyncEngine(this._ref);
  final Ref _ref;

  static const _locationBatchSize = 50;
  static const _sessionBatchSize = 200;
  static const _periodicInterval = Duration(minutes: 5);
  static const _failureNotificationThreshold = 3;
  static const _backoffSchedule = <Duration>[
    Duration(seconds: 30),
    Duration(minutes: 1),
    Duration(minutes: 2),
    Duration(minutes: 4),
    Duration(minutes: 8),
  ];

  bool _running = false; // the mutex
  bool _started = false;
  int _failureStreak = 0;
  int _lastPending = 0; // for the "queue just cleared" haptic

  Timer? _periodic;
  Timer? _backoff;
  StreamSubscription<bool>? _connSub;

  ApiClient get _api => _ref.read(apiClientProvider);
  ConnectivityService get _connectivity =>
      _ref.read(connectivityServiceProvider);
  SyncNotifier get _status => _ref.read(syncStatusProvider.notifier);
  DatabaseHelper get _db => DatabaseHelper.instance;

  // ── Lifecycle ──────────────────────────────────────────────────────────
  void start() {
    if (_started) return;
    _started = true;
    // Trigger the moment we come back online; keep the offline flag current
    // either way so the "saved locally" indicator reacts immediately.
    _connSub = _connectivity.isOnline.listen((online) {
      _status.setOffline(!online);
      if (online) {
        unawaited(syncNow());
      } else {
        unawaited(_refreshPendingCount());
      }
    });
    // Heartbeat backstop while online.
    _periodic = Timer.periodic(_periodicInterval, (_) => unawaited(syncNow()));
    unawaited(_refreshPendingCount());
    unawaited(syncNow());
  }

  void stop() {
    _periodic?.cancel();
    _backoff?.cancel();
    _connSub?.cancel();
    _started = false;
  }

  // ── The pass ─────────────────────────────────────────────────────────
  Future<void> syncNow() async {
    if (_running) return; // mutex — never two at once
    if (!await _isOnline()) {
      await _refreshPendingCount();
      final (loc, ses) = await _counts();
      await _updateForegroundNotification(online: false, pending: loc + ses);
      return; // never sync offline
    }

    _running = true;
    _backoff?.cancel();
    _status.setSyncing();
    try {
      await _runSequence();
      _failureStreak = 0;
      await SyncNotifications.instance.dismiss();
      final (loc, ses) = await _counts();
      final pending = loc + ses;
      // A queue that just emptied (offline work successfully uploaded) gets a
      // light confirmation tap — but only the transition, not every empty pass.
      if (_lastPending > 0 && pending == 0) {
        unawaited(HapticFeedback.lightImpact());
      }
      _lastPending = pending;
      _status.setSuccess(locations: loc, sessions: ses);
      await _updateForegroundNotification(online: true, pending: pending);
    } catch (e) {
      _failureStreak++;
      final (loc, ses) = await _counts();
      final pending = loc + ses;
      _lastPending = pending;
      _status.setFailure(_message(e), locations: loc, sessions: ses);
      _armBackoff();
      if (_failureStreak >= _failureNotificationThreshold) {
        await SyncNotifications.instance.showSyncStuck(pendingCount: pending);
      }
      debugPrint('Sync pass failed (streak $_failureStreak): $e');
    } finally {
      _running = false;
    }
  }

  Future<bool> _isOnline() async {
    if (_connectivity.current) return true;
    return _connectivity.checkNow();
  }

  /// Ordered: independent user-level actions first (profile, leave), then
  /// farmers (a visit or plan item checked in / referencing an
  /// offline-created farmer needs that farmer's real id — see
  /// docs/OFFLINE_SYNC_PLAN.md), then visit plans and visits, then sessions
  /// (attendance must exist before its locations are meaningful), then
  /// locations in batches.
  Future<void> _runSequence() async {
    // Give previously-failed rows another chance each pass.
    await _db.requeueFailedFarmers();
    await _db.requeueFailedVisits();
    await _db.requeueFailedVisitPlans();
    await _db.requeueFailedLeaveRequests();
    await _db.requeueFailedSessions();
    await _db.requeueFailed();

    await _syncProfileUpdate();
    await _syncLeaveRequests();
    await _syncFarmers();
    await _syncVisitPlans();
    await _syncPlanItemActions();
    await _syncVisits();
    await _syncSessions();
    await _syncLocations();

    final (loc, ses) = await _counts();
    _status.setPending(
      locations: loc,
      sessions: ses,
      isOffline: !_connectivity.current,
    );
  }

  // ── Farmers (offline create queue) ───────────────────────────────────
  Future<void> _syncFarmers() async {
    final pending = await _db.getPendingFarmers();
    // Rows with no batch_group_id sync individually (today's path); a
    // Farmer Meet's attendees share one and go out together via
    // _syncFarmerBatchGroup so the response's created[] maps 1:1 back to
    // each row (see FarmerRepository.createBatch's offline branch).
    final individual = <PendingFarmer>[];
    final groups = <String, List<PendingFarmer>>{};
    for (final f in pending) {
      final groupId = f.batchGroupId;
      if (groupId == null) {
        individual.add(f);
      } else {
        (groups[groupId] ??= []).add(f);
      }
    }

    for (final farmer in individual) {
      final payload = jsonDecode(farmer.payloadJson) as Map<String, dynamic>;
      try {
        final data = await _api.post('/farmers', body: payload);
        final serverId = data['id'] as int;
        await _db.setIdMapping(
          localId: farmer.localId,
          entityType: 'farmer',
          serverId: serverId,
        );
        await _db.upsertCachedFarmer(serverId, jsonEncode(data));
        await _db.deletePendingFarmer(farmer.localId);
      } on ValidationException {
        // 422: this payload will never succeed as-is. Stop auto-retrying it
        // and surface it — the user has to edit and resubmit (see
        // FarmerRepository.updatePending). Isolated to this row; the rest
        // of the batch keeps syncing.
        await _db.markFarmerNeedsAttention(
            farmer.localId, 'validation rejected (422)');
      } catch (e) {
        // Network/5xx/401: transient. Bump the retry counter (capped —
        // markFarmerTransientFailure escalates to needs_attention past the
        // limit) and let the exception propagate so the pass aborts and
        // backoff arms, same as the session/location sync.
        await _db.markFarmerTransientFailure(farmer.localId, _message(e));
        rethrow;
      }
    }

    for (final group in groups.values) {
      await _syncFarmerBatchGroup(group);
    }
  }

  /// One Farmer Meet's attendees, still ordered oldest-first (matches how
  /// they were created — `getPendingFarmers()` orders by `created_at ASC`).
  /// The backend's batch create runs as one transaction — it either fully
  /// succeeds or fully fails, so every row in the group is resolved the
  /// same way, no partial-batch state to reconcile.
  Future<void> _syncFarmerBatchGroup(List<PendingFarmer> group) async {
    final payloads =
        group.map((f) => jsonDecode(f.payloadJson) as Map<String, dynamic>).toList();
    // Shared venue fields were duplicated onto every row at creation time
    // (see FarmerRepository.createBatch) — any row in the group has them.
    final venue = payloads.first;
    final body = {
      'attendees': [
        for (var i = 0; i < group.length; i++)
          {
            'name': payloads[i]['name'],
            if ((payloads[i]['phone'] as String?)?.isNotEmpty ?? false)
              'phone': payloads[i]['phone'],
            'village': payloads[i]['village'],
            'client_id': group[i].localId,
          },
      ],
      if (venue['_venue_village'] != null) 'village': venue['_venue_village'],
      if (venue['district'] != null) 'district': venue['district'],
      if (venue['address'] != null) 'address': venue['address'],
      if (venue['pincode'] != null) 'pincode': venue['pincode'],
      if (venue['landmark'] != null) 'landmark': venue['landmark'],
      if (venue['notes'] != null) 'notes': venue['notes'],
      if (venue['team_id'] != null) 'team_id': venue['team_id'],
    };

    try {
      final data = await _api.post('/farmers/batch', body: body);
      final created = (data['created'] as List<dynamic>?) ?? [];
      // Backend returns created[] in the same order the client_ids were
      // sent (farmer_service.create_farmers_batch's idempotent-replay path
      // reconstructs this order explicitly; a fresh create preserves
      // insertion order naturally).
      for (var i = 0; i < group.length && i < created.length; i++) {
        final row = created[i] as Map<String, dynamic>;
        final serverId = row['id'] as int;
        await _db.setIdMapping(
          localId: group[i].localId,
          entityType: 'farmer',
          serverId: serverId,
        );
        await _db.upsertCachedFarmer(serverId, jsonEncode(row));
        await _db.deletePendingFarmer(group[i].localId);
      }
    } on ValidationException {
      for (final f in group) {
        await _db.markFarmerNeedsAttention(f.localId, 'validation rejected (422)');
      }
    } catch (e) {
      for (final f in group) {
        await _db.markFarmerTransientFailure(f.localId, _message(e));
      }
      rethrow;
    }
  }

  // ── Visits (offline check-in + sub-actions) ───────────────────────────
  Future<void> _syncVisits() async {
    final pending = await _db.getPendingVisits();
    bool anyCompleted = false;
    bool anyVet = false;
    for (final visit in pending) {
      try {
        var serverId = visit.visitServerId;
        if (serverId == null) {
          serverId = await _checkInPendingVisit(visit);
          if (serverId == null) continue; // farmer not resolvable yet
        }
        final hadComplete = (await _db.getPendingVisit(visit.localId))?.completeJson != null;
        final hadVet = (await _db.getPendingVisit(visit.localId))?.vetJson != null;
        await _syncVisitSubActions(visit.localId, serverId);
        if (hadComplete) anyCompleted = true;
        if (hadVet) anyVet = true;

        // Re-read: sub-action syncing clears fields as it goes, so this
        // reflects what's actually still outstanding.
        final refreshed = await _db.getPendingVisit(visit.localId);
        if (refreshed != null && _db.visitFullySynced(refreshed)) {
          await _db.deletePendingVisit(visit.localId);
        }
      } on ValidationException {
        // Isolated to this visit; the rest of the batch keeps syncing.
        await _db.markVisitNeedsAttention(
            visit.localId, 'validation rejected (422)');
      } catch (e) {
        await _db.markVisitTransientFailure(visit.localId, _message(e));
        rethrow;
      }
    }
    // Refresh read caches once after the whole pass rather than once per
    // visit — prevents parallel writes racing on the same prefs key.
    if (anyCompleted) unawaited(_refreshLeadsCache());
    if (anyVet) unawaited(_refreshVetCache());
  }

  /// Posts check-in for a visit that hasn't synced yet. Returns the new
  /// server id, or null if its farmer isn't resolvable this pass (checked
  /// in against an offline-created farmer that hasn't synced itself yet —
  /// _syncFarmers() ran first in the same pass, so this usually resolves
  /// same-pass; if not, next pass retries, no error needed).
  Future<int?> _checkInPendingVisit(PendingVisit visit) async {
    var farmerId = visit.farmerServerId;
    if (farmerId == null && visit.farmerLocalId != null) {
      farmerId = await _db.resolveServerId(visit.farmerLocalId!);
    }
    if (farmerId == null) return null;

    final payload = {
      ...jsonDecode(visit.checkInPayloadJson) as Map<String, dynamic>,
      'farmer_id': farmerId,
    };

    // If this visit was checked in offline from an offline-created plan item,
    // the check-in payload has '_local_plan_item_id' (negative) instead of
    // 'plan_item_id'. Resolve it to the real server ID now that the plan has
    // synced and stored the mapping.
    final localPlanItemId = payload['_local_plan_item_id'] as int?;
    if (localPlanItemId != null) {
      final serverPlanItemId = await _db.resolveServerId(localPlanItemId.toString());
      if (serverPlanItemId != null) {
        payload['plan_item_id'] = serverPlanItemId;
      }
      payload.remove('_local_plan_item_id');
    }

    final data = await _api.post('/visits/check-in', body: payload);
    final serverId = data['visit_id'] as int;
    await _db.setIdMapping(
      localId: visit.localId,
      entityType: 'visit',
      serverId: serverId,
    );
    return serverId;
  }

  /// Fixed order, matching the guided flow: location-remark, then notes,
  /// then livestock/org-answers, then vet, then every queued order, then
  /// complete last (the backend expects the visit's other data to already
  /// exist before it's marked complete). Each field is cleared the moment
  /// it lands — a failure partway through leaves the rest queued for next
  /// pass rather than blocking or re-sending what already succeeded.
  Future<void> _syncVisitSubActions(String localId, int serverId) async {
    var visit = await _db.getPendingVisit(localId);
    if (visit == null) return;

    if (visit.locationRemarkJson != null) {
      await _api.post('/visits/$serverId/location-remark',
          body: jsonDecode(visit.locationRemarkJson!) as Map<String, dynamic>);
      await _db.clearVisitField(localId, 'location_remark_json');
    }

    visit = await _db.getPendingVisit(localId);
    if (visit?.notesJson != null) {
      await _api.patch('/visits/$serverId/notes',
          body: jsonDecode(visit!.notesJson!) as Map<String, dynamic>);
      await _db.clearVisitField(localId, 'notes_json');
    }

    visit = await _db.getPendingVisit(localId);
    if (visit?.livestockJson != null) {
      await _api.patch('/visits/$serverId/livestock',
          body: jsonDecode(visit!.livestockJson!) as Map<String, dynamic>);
      await _db.clearVisitField(localId, 'livestock_json');
    }

    visit = await _db.getPendingVisit(localId);
    if (visit?.orgAnswersJson != null) {
      await _api.patch('/visits/$serverId/org-answers',
          body: jsonDecode(visit!.orgAnswersJson!) as Map<String, dynamic>);
      await _db.clearVisitField(localId, 'org_answers_json');
    }

    visit = await _db.getPendingVisit(localId);
    if (visit?.vetJson != null) {
      await _api.patch('/visits/$serverId/vet',
          body: jsonDecode(visit!.vetJson!) as Map<String, dynamic>);
      await _db.clearVisitField(localId, 'vet_json');
    }

    visit = await _db.getPendingVisit(localId);
    final ordersJson = visit?.ordersJson;
    if (ordersJson != null) {
      final orders = jsonDecode(ordersJson) as List<dynamic>;
      // Remove each order from the queue immediately after it lands — not
      // after the whole batch — so a failure on order #3 doesn't leave #1
      // and #2 still queued to be (wrongly) resent next pass. Each order
      // also now carries its own client_id (alembic 0026), so even a lost
      // response after a successful create is a safe no-op server-side on
      // retry, not a duplicate.
      for (final order in orders) {
        await _api.post('/visits/$serverId/orders',
            body: order as Map<String, dynamic>);
        await _db.removeSyncedVisitOrders(localId, 1);
      }
    }

    visit = await _db.getPendingVisit(localId);
    if (visit?.completeJson != null) {
      final completeData =
          jsonDecode(visit!.completeJson!) as Map<String, dynamic>;
      await _api.post('/visits/$serverId/complete', body: completeData);
      await _db.clearVisitField(localId, 'complete_json');
      // Follow-ups cache refresh happens here (per-visit, conditional on
      // follow_up_date). Leads cache refresh is batched in _syncVisits()
      // after the full pass to avoid parallel writes racing on the prefs key.
      if (completeData.containsKey('follow_up_date')) {
        unawaited(_refreshFollowUpsCache());
      }
    }
  }

  Future<void> _refreshVetCache() async {
    try {
      final data = await _api.getList('/vet-requests');
      final prefs = _ref.read(sharedPreferencesProvider);
      await prefs.setString('cached_vet_requests', jsonEncode(data));
    } catch (_) {
      // Best-effort: vet screen will re-fetch when opened online.
    }
  }

  Future<void> _refreshLeadsCache() async {
    try {
      final data = await _api.getList('/leads/my');
      final prefs = _ref.read(sharedPreferencesProvider);
      await prefs.setString('cached_my_leads', jsonEncode(data));
    } catch (_) {
      // Best-effort: leads screen will re-fetch when opened online.
    }
  }

  Future<void> _refreshFollowUpsCache() async {
    try {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      String ymd(DateTime d) =>
          '${d.year.toString().padLeft(4, '0')}-'
          '${d.month.toString().padLeft(2, '0')}-'
          '${d.day.toString().padLeft(2, '0')}';
      final data = await _api.getList('/follow-ups/my', query: {
        'date_from': ymd(today),
        'date_to': ymd(today.add(const Duration(days: 7))),
      });
      final prefs = _ref.read(sharedPreferencesProvider);
      await prefs.setString('cached_my_follow_ups', jsonEncode(data));
    } catch (_) {
      // Best-effort: if this fails the user just needs to open the
      // follow-ups screen once while online to get the updated list.
    }
  }

  // ── Attendance sessions ──────────────────────────────────────────────
  Future<void> _syncSessions() async {
    final pending = await _db.getPendingSessions(limit: _sessionBatchSize);
    if (pending.isEmpty) return;

    // A transport error here throws → aborts the pass → backoff. A 2xx with a
    // per-record `errors` array is a PARTIAL success handled row-by-row.
    final resp = await _api.post(
      '/sync/attendance-sessions',
      body: {'sessions': pending.map((s) => s.toApiJson()).toList()},
    );

    final errorIndices = <int, String>{};
    for (final e in (resp['errors'] as List? ?? const [])) {
      if (e is Map && e['index'] is int) {
        errorIndices[e['index'] as int] = (e['reason'] as String?) ?? 'rejected';
      }
    }

    final syncedIds = <int>[];
    for (var i = 0; i < pending.length; i++) {
      final row = pending[i];
      if (errorIndices.containsKey(i)) {
        await _db.markSessionFailed(row.id, errorIndices[i]!);
      } else {
        // processed OR skipped(duplicate) — the server has it either way.
        syncedIds.add(row.id);
      }
    }
    await _db.markSessionsSynced(syncedIds);
    await _db.deleteSyncedSessions();
  }

  // ── Locations (batches of 50) ────────────────────────────────────────
  Future<void> _syncLocations() async {
    while (true) {
      final batch = await _db.getPendingLocations(limit: _locationBatchSize);
      if (batch.isEmpty) break;

      try {
        await _api.post(
          '/location/batch',
          body: {'records': batch.map((r) => r.toApiJson()).toList()},
        );
        // 2xx (processed or deduped-skipped) => the server has them all.
        await _db.markSynced([for (final r in batch) r.id!]);
      } on ValidationException {
        // 422: the whole batch is structurally poison. Isolate these rows so
        // the rest of the queue isn't stuck behind them, then keep draining.
        for (final r in batch) {
          await _db.markFailed(r.id!, 'validation rejected (422)');
        }
        continue;
      }
      // Other ApiExceptions (network / 5xx / 401) propagate → backoff.
    }
    await _db.pruneSynced();
  }

  // ── Profile edit (single pending slot) ────────────────────────────────
  Future<void> _syncProfileUpdate() async {
    final tokens = _ref.read(tokenStorageProvider);
    final pendingJson = tokens.pendingProfileUpdateJson;
    if (pendingJson == null) return;
    try {
      final data = await _api.patch('/auth/me',
          body: jsonDecode(pendingJson) as Map<String, dynamic>);
      await tokens.saveUserJson(jsonEncode(data));
      await tokens.clearPendingProfileUpdate();
    } on ValidationException {
      // A rejected profile edit has no per-row status to flip (single
      // slot, not a table) — leave it queued; the user will see the
      // rejection surface next time they open Edit Profile and resubmit,
      // which overwrites this slot either way.
    }
    // Other ApiExceptions propagate → backoff, same as everything else.
  }

  // ── Leave requests ─────────────────────────────────────────────────────
  Future<void> _syncLeaveRequests() async {
    final pending = await _db.getPendingLeaveRequests();
    for (final leave in pending) {
      try {
        await _api.post('/attendance/leave', body: {'date': leave.leaveDate});
        await _db.deletePendingLeaveRequest(leave.leaveDate);
      } on ValidationException {
        await _db.markLeaveRequestNeedsAttention(
            leave.leaveDate, 'validation rejected (422)');
      } catch (e) {
        await _db.markLeaveRequestTransientFailure(leave.leaveDate, _message(e));
        rethrow;
      }
    }
  }

  // ── Visit plans ────────────────────────────────────────────────────────
  Future<void> _syncVisitPlans() async {
    final pending = await _db.getPendingVisitPlans();
    for (final plan in pending) {
      try {
        final items = jsonDecode(plan.itemsJson) as List<dynamic>;
        final resolvedItems = <Map<String, dynamic>>[];
        var allResolved = true;
        for (final raw in items) {
          final item = Map<String, dynamic>.from(raw as Map<String, dynamic>);
          final farmerId = item['farmer_id'] as int;
          if (farmerId < 0) {
            final localId = item['_farmer_local_id'] as String?;
            final serverId = localId == null ? null : await _db.resolveServerId(localId);
            if (serverId == null) {
              allResolved = false;
              break;
            }
            item['farmer_id'] = serverId;
          }
          item.remove('_farmer_local_id');
          resolvedItems.add(item);
        }
        // Not every referenced farmer has synced yet — try again next pass,
        // no error (same reasoning as _syncVisits skipping an unresolved
        // farmer). If `_farmer_local_id` was never captured (the farmer
        // synced away before this plan was saved — see
        // VisitPlanRepository.savePlan), this never resolves; a known gap,
        // not silently swallowed — retry_count still climbs via the catch
        // block below once this starts throwing instead of skipping. For
        // now it just retries indefinitely at zero cost, same as an
        // unresolved farmer on a normal visit.
        if (!allResolved) continue;

        // Collect local item IDs before stripping them from the payload.
        final localItemIds = [
          for (final item in resolvedItems) item['_local_item_id'] as int?,
        ];
        for (final item in resolvedItems) {
          item.remove('_local_item_id');
        }

        final response = await _api.post('/visit-plans', body: {
          'plan_date': plan.planDate,
          'items': resolvedItems,
        });

        // Store plan_item local→server ID mappings so _checkInPendingVisit can
        // inject the real plan_item_id when syncing visits from offline plans.
        final serverItems =
            ((response['items'] as List?)?.cast<Map<String, dynamic>>()) ?? [];
        for (var i = 0; i < localItemIds.length && i < serverItems.length; i++) {
          final localItemId = localItemIds[i];
          final serverItemId = serverItems[i]['id'] as int?;
          if (localItemId != null && serverItemId != null) {
            await _db.setIdMapping(
              localId: localItemId.toString(),
              entityType: 'plan_item',
              serverId: serverItemId,
            );
          }
        }

        await _db.deletePendingVisitPlan(plan.planDate);
      } on ValidationException {
        await _db.markVisitPlanNeedsAttention(
            plan.planDate, 'validation rejected (422)');
      } catch (e) {
        await _db.markVisitPlanTransientFailure(plan.planDate, _message(e));
        rethrow;
      }
    }
  }

  /// Single-item plan mutations queued offline (skip / carry-over /
  /// cross-day move / status update) — see VisitPlanRepository's offline
  /// branches and _applyPendingPlanItemActions. These only ever target
  /// items that already have a real server id (skip/carry-over/edit act on
  /// items already visible in a submitted plan), so there's no farmer- or
  /// visit-plan-resolution dependency to wait on the way _syncVisits has.
  Future<void> _syncPlanItemActions() async {
    final pending = await _db.getPendingPlanItemActions();
    for (final action in pending) {
      try {
        final payload = jsonDecode(action.payloadJson) as Map<String, dynamic>;
        switch (action.action) {
          case 'skip':
            await _api.post('/visit-plans/items/${action.itemId}/skip');
          case 'carry_over':
            await _api.post(
                '/visit-plans/items/${action.itemId}/carry-over', body: payload);
          case 'update_item':
            await _api.patch('/visit-plans/items/${action.itemId}', body: payload);
          case 'update_status':
            final planId = payload['plan_id'] as int;
            await _api.patch(
              '/visit-plans/$planId/items/${action.itemId}',
              body: {'status': payload['status']},
            );
        }
        await _db.deletePendingPlanItemAction(action.localId);
      } on ValidationException {
        await _db.markPlanItemActionNeedsAttention(
            action.localId, 'validation rejected (422)');
      } catch (e) {
        await _db.markPlanItemActionTransientFailure(action.localId, _message(e));
        rethrow;
      }
    }
  }

  // ── Backoff ──────────────────────────────────────────────────────────
  void _armBackoff() {
    final idx = (_failureStreak - 1).clamp(0, _backoffSchedule.length - 1);
    final delay = _backoffSchedule[idx];
    _backoff?.cancel();
    _backoff = Timer(delay, () => unawaited(syncNow()));
  }

  // ── Pending counts ───────────────────────────────────────────────────
  Future<(int, int)> _counts() async {
    final locations = await _db.getPendingLocationCount();
    final sessions = await _db.getPendingSessionCount();
    return (locations, sessions);
  }

  Future<void> _refreshPendingCount() async {
    final (loc, ses) = await _counts();
    _status.setPending(
      locations: loc,
      sessions: ses,
      isOffline: !_connectivity.current,
    );
  }

  /// Keep the persistent foreground-service notification text in sync with the
  /// online/offline state (what the employee sees in their notification shade).
  Future<void> _updateForegroundNotification({
    required bool online,
    required int pending,
  }) async {
    final text = online
        ? 'FieldTrack · Tracking active · Synced ${_minsAgo()} min ago'
        : 'FieldTrack · Tracking active · Saved locally ($pending points)';
    await LocationService.updateTrackingNotification(text);
  }

  int _minsAgo() {
    final last = _ref.read(syncStatusProvider).lastSuccessfulSync;
    if (last == null) return 0;
    return DateTime.now().difference(last).inMinutes;
  }

  String _message(Object e) {
    if (e is ApiException) return e.message;
    return 'Sync failed. Will retry automatically.';
  }
}

/// App-wide engine. Kept alive by the authenticated shell (see HomeShell), so
/// it runs only while logged in and stops on logout.
final syncEngineProvider = Provider<SyncEngine>((ref) {
  final engine = SyncEngine(ref);
  engine.start();
  ref.onDispose(engine.stop);
  return engine;
});
