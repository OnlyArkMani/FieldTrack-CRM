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
import '../models/farmer.dart';

final farmerRepositoryProvider = Provider<FarmerRepository>((ref) {
  return FarmerRepository(
    ref.watch(apiClientProvider),
    ref.watch(connectivityServiceProvider),
    ref.watch(sharedPreferencesProvider),
  );
});

/// Wrapper over the /farmers API. Returns typed models; throws
/// ApiException (mapped by api_client) for the providers to surface.
///
/// Offline support (see docs/OFFLINE_SYNC_PLAN.md): `create()` queues to
/// SQLite instead of calling the API when there's no connectivity; `list()`
/// merges in unsynced local farmers and a read-through cache of the last
/// successful server response so offline browsing/check-in still works.
class FarmerRepository {
  FarmerRepository(this._api, this._connectivity, this._prefs);
  final ApiClient _api;
  final ConnectivityService _connectivity;
  final SharedPreferences _prefs;
  final _db = DatabaseHelper.instance;
  static const _uuid = Uuid();

  Future<FarmerPage> list({
    String? cursor,
    int limit = 20,
    String? search,
    LeadStatus? leadStatus,
    CustomerType? customerType,
    int? teamId,
  }) async {
    if (!_connectivity.current) {
      return _offlineList(search: search);
    }
    final query = <String, dynamic>{'limit': limit};
    if (cursor != null) query['cursor'] = cursor;
    if (search != null && search.trim().isNotEmpty) {
      query['search'] = search.trim();
    }
    if (leadStatus != null) query['lead_status'] = leadStatus.wire;
    if (customerType != null) query['customer_type'] = customerType.wire;
    if (teamId != null) query['team_id'] = teamId;
    final data = await _api.get('/farmers', query: query);
    final page = FarmerPage.fromJson(data);
    // Write-through: first page (no cursor, no filters) is the closest thing
    // to "the employee's farmer list" — cache it so offline check-in can
    // target any of these later, not just farmers created this session.
    // NOTE: the screen's default state passes search: '' (empty string, not
    // null) — `search == null` here was never true on a normal list load,
    // so this cache silently never populated. Treat blank the same as null.
    final hasSearch = search != null && search.trim().isNotEmpty;
    if (cursor == null && !hasSearch && leadStatus == null) {
      unawaited(_cacheListPage(data));
    }
    // A farmer's last-visit-date/lead badge here comes straight from the
    // cached/fetched server row — the server genuinely doesn't know about a
    // visit completed offline against it yet. Without this merge, an
    // already-synced farmer visited offline keeps showing "Never visited"
    // and its old lead status on this list until the visit itself syncs,
    // even though the farmer's own detail screen (_applyPendingVisits)
    // already reflects it.
    final pendingInfo = await _pendingVisitInfo();
    final mergedServerItems =
        page.items.map((f) => _applyPendingVisitInfo(f, pendingInfo.byServerId)).toList();
    final unsynced = await _db.getAllUnsyncedFarmers();
    if (unsynced.isEmpty) {
      return FarmerPage(
        items: mergedServerItems,
        total: page.total,
        hasMore: page.hasMore,
        nextCursor: page.nextCursor,
      );
    }
    return FarmerPage(
      items: [
        for (final f in unsynced) _pendingFarmerListItem(f, pendingInfo.byLocalId),
        ...mergedServerItems,
      ],
      total: page.total + unsynced.length,
      hasMore: page.hasMore,
      nextCursor: page.nextCursor,
    );
  }

  /// Latest offline visit per farmer, split by how the farmer itself is
  /// known: `byServerId` for an already-synced farmer visited offline
  /// (merged onto the server/cached row), `byLocalId` for a farmer that was
  /// *also* created offline in the same session — its own `.pending()` row
  /// has no last-visit/lead concept at all otherwise, so without this a
  /// farmer created-and-visited entirely offline would keep showing "Never
  /// visited"/"No lead" even though `_applyPendingVisitInfo` already
  /// handles the already-synced case correctly.
  Future<
      ({
        Map<int, ({DateTime lastVisitAt, LeadStatus? leadStatus})> byServerId,
        Map<String, ({DateTime lastVisitAt, LeadStatus? leadStatus})> byLocalId,
      })> _pendingVisitInfo() async {
    final visits = await _db.getAllUnsyncedVisits();
    final byServerId = <int, ({DateTime lastVisitAt, LeadStatus? leadStatus})>{};
    final byLocalId = <String, ({DateTime lastVisitAt, LeadStatus? leadStatus})>{};
    for (final v in visits) {
      LeadStatus? status;
      if (v.completeJson != null) {
        final complete = jsonDecode(v.completeJson!) as Map<String, dynamic>;
        status = LeadStatus.fromWire(complete['lead_status'] as String?);
      }
      if (v.farmerServerId != null) {
        final farmerId = v.farmerServerId!;
        final existing = byServerId[farmerId];
        byServerId[farmerId] = existing == null
            ? (lastVisitAt: v.createdAt, leadStatus: status)
            : (
                lastVisitAt: v.createdAt.isAfter(existing.lastVisitAt)
                    ? v.createdAt
                    : existing.lastVisitAt,
                leadStatus: status ?? existing.leadStatus,
              );
      } else if (v.farmerLocalId != null) {
        final localId = v.farmerLocalId!;
        final existing = byLocalId[localId];
        byLocalId[localId] = existing == null
            ? (lastVisitAt: v.createdAt, leadStatus: status)
            : (
                lastVisitAt: v.createdAt.isAfter(existing.lastVisitAt)
                    ? v.createdAt
                    : existing.lastVisitAt,
                leadStatus: status ?? existing.leadStatus,
              );
      }
    }
    return (byServerId: byServerId, byLocalId: byLocalId);
  }

  FarmerListItem _applyPendingVisitInfo(
    FarmerListItem item,
    Map<int, ({DateTime lastVisitAt, LeadStatus? leadStatus})> pendingInfo,
  ) {
    final info = pendingInfo[item.id];
    if (info == null) return item;
    final current = item.lastVisitAt;
    return item.copyWith(
      lastVisitAt: current == null || info.lastVisitAt.isAfter(current)
          ? info.lastVisitAt
          : current,
      leadStatus: info.leadStatus ?? item.leadStatus,
    );
  }

  FarmerListItem _pendingFarmerListItem(
    PendingFarmer f,
    Map<String, ({DateTime lastVisitAt, LeadStatus? leadStatus})> pendingInfoByLocalId,
  ) {
    final item = FarmerListItem.pending(
      localId: f.localId,
      payload: jsonDecode(f.payloadJson) as Map<String, dynamic>,
      syncStatus: f.syncStatus,
    );
    final info = pendingInfoByLocalId[f.localId];
    if (info == null) return item;
    return item.copyWith(lastVisitAt: info.lastVisitAt, leadStatus: info.leadStatus);
  }

  Future<void> _cacheListPage(Map<String, dynamic> data) async {
    final items = (data['items'] as List<dynamic>? ?? []);
    final byId = <int, String>{
      for (final e in items)
        (e as Map<String, dynamic>)['id'] as int: jsonEncode(e),
    };
    await _db.upsertCachedFarmers(byId);
  }

  Future<FarmerPage> _offlineList({String? search}) async {
    final unsynced = await _db.getAllUnsyncedFarmers();
    final cachedJson = await _db.getAllCachedFarmerJson();
    final pendingInfo = await _pendingVisitInfo();
    final q = search?.trim().toLowerCase();
    final items = <FarmerListItem>[
      for (final f in unsynced) _pendingFarmerListItem(f, pendingInfo.byLocalId),
      for (final json in cachedJson)
        _applyPendingVisitInfo(
          FarmerListItem.fromJson(jsonDecode(json) as Map<String, dynamic>),
          pendingInfo.byServerId,
        ),
    ].where((f) => q == null || q.isEmpty || f.name.toLowerCase().contains(q)).toList();
    return FarmerPage(items: items, total: items.length, hasMore: false);
  }

  Future<FarmerDetail> detail(int id) async {
    // A negative id is always a placeholder for a farmer that hasn't
    // synced yet (real server ids are always positive) — see
    // placeholderIdFromLocalId. Never worth an API call.
    if (id < 0) return _pendingDetailByPlaceholderId(id);

    FarmerDetail base;
    if (_connectivity.current) {
      final data = await _api.get('/farmers/$id');
      unawaited(_db.upsertCachedFarmer(id, jsonEncode(data)));
      base = FarmerDetail.fromJson(data);
    } else {
      final cached = await _db.getCachedFarmerJson(id);
      if (cached != null) {
        base = FarmerDetail.fromJson(jsonDecode(cached) as Map<String, dynamic>);
      } else {
        // Not cached and offline — surfaces as a normal ApiException-shaped
        // failure to the caller (no network call to actually make).
        final data = await _api.get('/farmers/$id');
        base = FarmerDetail.fromJson(data);
      }
    }
    // Applies even when freshly fetched online: if a visit for this farmer
    // was completed offline, the server genuinely doesn't know about it
    // yet either, cached response or not.
    return _applyPendingVisits(base, farmerId: id);
  }

  /// Neither a fresh server response nor a cached one can know about a
  /// check-in/complete that only exists locally in `pending_visits` and
  /// hasn't synced yet. Prepends synthetic `VisitSummary` entries built
  /// straight from that local data — same reasoning as
  /// VisitPlanRepository._applyPendingVisitProgress.
  Future<FarmerDetail> _applyPendingVisits(
    FarmerDetail base, {
    int? farmerId,
    String? farmerLocalId,
  }) async {
    final pending = await _pendingVisitSummaries(
      farmerId: farmerId,
      farmerLocalId: farmerLocalId,
    );
    if (pending.isEmpty) return base;
    return FarmerDetail(
      id: base.id,
      customerType: base.customerType,
      teamId: base.teamId,
      teamName: base.teamName,
      createdBy: base.createdBy,
      name: base.name,
      phone: base.phone,
      village: base.village,
      district: base.district,
      address: base.address,
      pincode: base.pincode,
      landmark: base.landmark,
      lat: base.lat,
      lng: base.lng,
      totalCattle: base.totalCattle,
      currentFeedBrand: base.currentFeedBrand,
      currentFeedPricePerBag: base.currentFeedPricePerBag,
      notes: base.notes,
      isActive: base.isActive,
      createdAt: base.createdAt,
      updatedAt: base.updatedAt,
      currentLead: base.currentLead,
      // Newest first, matching the server's own ordering — an unsynced
      // visit is always the most recent thing that's happened here.
      recentVisits: [...pending, ...base.recentVisits],
      latestLivestock: base.latestLivestock,
      pendingFollowUps: base.pendingFollowUps,
      totalVisits: base.totalVisits + pending.length,
      totalOrders: base.totalOrders,
      localId: base.localId,
      syncStatus: base.syncStatus,
    );
  }

  Future<List<VisitSummary>> _pendingVisitSummaries({
    int? farmerId,
    String? farmerLocalId,
  }) async {
    final visits = await _db.getAllUnsyncedVisits();
    final result = <VisitSummary>[];
    for (final v in visits) {
      final matches = farmerId != null
          ? v.farmerServerId == farmerId
          : v.farmerLocalId == farmerLocalId;
      if (!matches) continue;
      final checkIn = v.checkInPayloadJson.isEmpty || v.checkInPayloadJson == '{}'
          ? const <String, dynamic>{}
          : jsonDecode(v.checkInPayloadJson) as Map<String, dynamic>;
      result.add(VisitSummary(
        id: v.visitServerId ?? placeholderIdFromLocalId(v.localId),
        checkInAt: v.createdAt, // check-in payload carries no timestamp of its own
        purpose: checkIn['purpose'] as String?,
        status: v.completeJson != null ? 'COMPLETED' : 'CHECKED_IN',
        createdAt: v.createdAt,
        syncStatus: v.syncStatus,
      ));
    }
    return result;
  }

  /// [placeholderIdFromLocalId] is a one-way hash, so recovering which
  /// queued farmer a placeholder id refers to means scanning the (always
  /// small) unsynced set rather than a direct lookup — cheap in practice
  /// since a phone rarely has more than a handful of unsynced farmers at
  /// once.
  Future<FarmerDetail> _pendingDetailByPlaceholderId(int placeholderId) async {
    final unsynced = await _db.getAllUnsyncedFarmers();
    for (final f in unsynced) {
      if (placeholderIdFromLocalId(f.localId) == placeholderId) {
        final pending = FarmerDetail.pending(
          localId: f.localId,
          payload: jsonDecode(f.payloadJson) as Map<String, dynamic>,
          syncStatus: f.syncStatus,
        );
        return _applyPendingVisits(pending, farmerLocalId: f.localId);
      }
    }
    // Rare race: it finished syncing (and was removed from the queue)
    // between the screen navigating here and this read. The placeholder id
    // has no meaning to the server, so there's nothing left to fetch by —
    // send the user back to the list rather than a raw network error.
    throw const UnknownApiException(
      'This farmer just finished syncing — go back and open it from the list.',
      'PENDING_RESOLVED',
    );
  }

  /// The pending-local counterpart of [detail] — reads a farmer that only
  /// exists in `pending_farmers` (never synced), keyed by its client UUID.
  Future<FarmerDetail?> pendingDetail(String localId) async {
    final row = await _db.getPendingFarmer(localId);
    if (row == null) return null;
    return FarmerDetail.pending(
      localId: localId,
      payload: jsonDecode(row.payloadJson) as Map<String, dynamic>,
      syncStatus: row.syncStatus,
    );
  }

  Future<FarmerDetail> create({
    required String name,
    CustomerType customerType = CustomerType.farmer,
    String? phone,
    String? village,
    String? district,
    String? address,
    String? pincode,
    String? landmark,
    String? notes,
    int? teamId,
  }) async {
    final draft = FarmerDetail(
      id: 0, // unused — toCreateJson() doesn't read it
      customerType: customerType,
      name: name,
      phone: phone,
      village: village,
      district: district,
      address: address,
      pincode: pincode,
      landmark: landmark,
      notes: notes,
      teamId: teamId,
    );

    if (!_connectivity.current) {
      final localId = _uuid.v4();
      await _db.insertPendingFarmer(
        localId: localId,
        payloadJson: jsonEncode(draft.toCreateJson(clientId: localId)),
      );
      // See DatabaseHelper.insertIdMappingPlaceholder — closes the Visit
      // Plan farmer-race gap by recording this local_id now, not only once
      // it syncs.
      await _db.insertIdMappingPlaceholder(localId: localId, entityType: 'farmer');
      return FarmerDetail.pending(localId: localId, payload: draft.toCreateJson());
    }

    // Total cattle is intentionally NOT collected at add time — it's captured
    // during the first meeting/visit (livestock form). Backend defaults it to 0.
    final data = await _api.post('/farmers', body: draft.toCreateJson());
    // POST returns the base FarmerResponse; re-fetch the full profile so the
    // detail screen has visits/leads/etc. populated.
    return detail(data['id'] as int);
  }

  /// Create every attendee of one Farmer Meet in a single backend
  /// transaction. All attendees share the venue's address/district/etc.;
  /// name/phone/village vary per row.
  Future<List<FarmerDetail>> createBatch({
    required List<({String name, String phone, String village})> attendees,
    String? village,
    String? district,
    String? address,
    String? pincode,
    String? landmark,
    String? notes,
    int? teamId,
  }) async {
    if (!_connectivity.current) {
      // Each attendee still gets its own pending_farmers row (so
      // updatePending/needs_attention handling applies per-attendee), but
      // all of them share a batch_group_id so _syncFarmers() can send them
      // as one POST /farmers/batch later — same all-or-nothing transaction
      // the online path gets. The shared venue fields are duplicated onto
      // every row (under `_venue_*` keys, distinct from the attendee's own
      // `village`) so each row stays self-sufficient and the sync engine
      // can rebuild the batch body from any row in the group.
      final batchGroupId = _uuid.v4();
      final results = <FarmerDetail>[];
      for (final a in attendees) {
        final localId = _uuid.v4();
        final payload = {
          'name': a.name,
          'customer_type': CustomerType.farmer.wire,
          if (a.phone.isNotEmpty) 'phone': a.phone,
          'village': a.village,
          if (village != null && village.isNotEmpty) '_venue_village': village,
          if (district != null && district.isNotEmpty) 'district': district,
          if (address != null && address.isNotEmpty) 'address': address,
          if (pincode != null && pincode.isNotEmpty) 'pincode': pincode,
          if (landmark != null && landmark.isNotEmpty) 'landmark': landmark,
          if (notes != null && notes.isNotEmpty) 'notes': notes,
          if (teamId != null) 'team_id': teamId,
          'client_id': localId,
        };
        await _db.insertPendingFarmer(
          localId: localId,
          payloadJson: jsonEncode(payload),
          batchGroupId: batchGroupId,
        );
        // See DatabaseHelper.insertIdMappingPlaceholder — closes the Visit
        // Plan farmer-race gap for Farmer Meet attendees too.
        await _db.insertIdMappingPlaceholder(localId: localId, entityType: 'farmer');
        results.add(FarmerDetail.pending(localId: localId, payload: payload));
      }
      return results;
    }
    final data = await _api.post('/farmers/batch', body: {
      'attendees': attendees
          .map((a) => {'name': a.name, 'phone': a.phone, 'village': a.village})
          .toList(),
      if (village != null && village.isNotEmpty) 'village': village,
      if (district != null && district.isNotEmpty) 'district': district,
      if (address != null && address.isNotEmpty) 'address': address,
      if (pincode != null && pincode.isNotEmpty) 'pincode': pincode,
      if (landmark != null && landmark.isNotEmpty) 'landmark': landmark,
      if (notes != null && notes.isNotEmpty) 'notes': notes,
      if (teamId != null) 'team_id': teamId,
    });
    return ((data['created'] as List<dynamic>?) ?? [])
        .map((e) => FarmerDetail.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> update(int id, Map<String, dynamic> changes) async {
    await _api.put('/farmers/$id', body: changes);
  }

  /// Editing a farmer that hasn't synced yet: there's no server id to PUT
  /// against, so the edit is merged straight into the still-queued
  /// `payload_json` instead of making an API call. When it eventually syncs,
  /// POST /farmers goes out already carrying this edit — the server never
  /// sees a "before" version.
  Future<FarmerDetail?> updatePending(
    String localId,
    Map<String, dynamic> changes,
  ) async {
    final row = await _db.getPendingFarmer(localId);
    if (row == null) return null;
    final merged = {
      ...jsonDecode(row.payloadJson) as Map<String, dynamic>,
      ...changes,
    };
    await _db.updatePendingFarmerPayload(localId, jsonEncode(merged));
    return FarmerDetail.pending(localId: localId, payload: merged);
  }

  /// One page of full visit history (newest first). Returns the parsed items
  /// plus the next cursor for infinite scroll. The first page (no cursor)
  /// is prefixed with any unsynced visit for this farmer, same reasoning as
  /// [detail]'s `recentVisits` merge; later (paged) requests need
  /// connectivity same as before.
  Future<({List<VisitSummary> items, String? nextCursor, bool hasMore})>
      visitList(int id, {String? cursor, int limit = 20}) async {
    final pending = cursor == null ? await _pendingVisitSummaries(farmerId: id) : const <VisitSummary>[];
    try {
      final query = <String, dynamic>{'limit': limit};
      if (cursor != null) query['cursor'] = cursor;
      final data = await _api.get('/farmers/$id/visits', query: query);
      final items = ((data['items'] as List<dynamic>?) ?? [])
          .map((e) => VisitSummary.fromJson(e as Map<String, dynamic>))
          .toList();
      return (
        items: [...pending, ...items],
        nextCursor: data['next_cursor'] as String?,
        hasMore: (data['has_more'] as bool?) ?? false,
      );
    } on NoConnectionException {
      if (pending.isNotEmpty) return (items: pending, nextCursor: null, hasMore: false);
      rethrow;
    } on TimeoutException {
      if (pending.isNotEmpty) return (items: pending, nextCursor: null, hasMore: false);
      rethrow;
    }
  }

  static String _livestockHistoryCacheKey(int id) =>
      'cached_livestock_history_$id';
  static String _leadHistoryCacheKey(int id) => 'cached_lead_history_$id';

  /// Falls back to the last successful response when offline, same pattern
  /// as leads/follow-ups/vet — previously this had no offline handling at
  /// all and threw a raw NoConnectionException, inconsistent with the rest
  /// of the (offline-capable) farmer detail page it's drilled into from.
  Future<List<LivestockProfile>> livestockHistory(int id) async {
    List<dynamic>? data;
    ApiException? networkError;
    try {
      data = await _api.getList('/farmers/$id/livestock-history');
      unawaited(_prefs.setString(_livestockHistoryCacheKey(id), jsonEncode(data)));
    } on NoConnectionException catch (e) {
      data = _cachedList(_livestockHistoryCacheKey(id));
      networkError = e;
    } on TimeoutException catch (e) {
      data = _cachedList(_livestockHistoryCacheKey(id));
      networkError = e;
    }
    if (data == null) throw networkError!;
    return data
        .map((e) => LivestockProfile.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<LeadHistoryItem>> leadHistory(int id) async {
    List<dynamic>? data;
    ApiException? networkError;
    try {
      data = await _api.getList('/farmers/$id/lead-history');
      unawaited(_prefs.setString(_leadHistoryCacheKey(id), jsonEncode(data)));
    } on NoConnectionException catch (e) {
      data = _cachedList(_leadHistoryCacheKey(id));
      networkError = e;
    } on TimeoutException catch (e) {
      data = _cachedList(_leadHistoryCacheKey(id));
      networkError = e;
    }
    if (data == null) throw networkError!;
    return data
        .map((e) => LeadHistoryItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  List<dynamic>? _cachedList(String key) {
    final json = _prefs.getString(key);
    if (json == null) return null;
    try {
      return jsonDecode(json) as List<dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<void> updateLeadStatus(
    int id, {
    required LeadStatus status,
    required String reason,
    int? visitId,
  }) async {
    await _api.post('/farmers/$id/lead-status', body: {
      'status': status.wire,
      'reason_note': reason,
      if (visitId != null) 'visit_id': visitId,
    });
  }
}
