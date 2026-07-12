import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/network/api_client.dart';
import '../../../../core/network/api_exceptions.dart';
import '../../../../core/theme/app_theme.dart' show sharedPreferencesProvider;
import '../../../../local_db/database_helper.dart';
import '../../../../services/sync/connectivity_service.dart';
import '../../../auth/providers/auth_provider.dart';
import '../../farmers/models/farmer.dart'
    show CustomerType, LivestockProfile, LeadStatus, placeholderIdFromLocalId;
import '../models/visit.dart';

final visitRepositoryProvider = Provider<VisitRepository>((ref) {
  return VisitRepository(
    ref.watch(apiClientProvider),
    ref.watch(connectivityServiceProvider),
    ref.watch(sharedPreferencesProvider),
    () => ref.read(authProvider).user?.id,
  );
});

/// Wrapper over the /visits API.
///
/// Offline support (see docs/OFFLINE_SYNC_PLAN.md): check-in AND every
/// sub-action (location-remark, notes, livestock, org-answers, vet, orders,
/// complete) queue to SQLite when there's no connectivity — whether the
/// visit itself was checked in offline (placeholder id) or online (real id,
/// network dropped partway through the guided flow). Most sub-action
/// endpoints have no server-side idempotency (client_id), unlike farmers,
/// check-in, and (as of alembic 0026) orders — a retry after a lost
/// response could in principle double-send one of these. Acceptable for
/// notes/livestock/vet (upserts, so a duplicate PATCH is harmless); orders
/// was the one real risk and now carries its own client_id (see
/// createOrder below).
class VisitRepository {
  VisitRepository(this._api, this._connectivity, this._prefs, this._getUserId);
  final ApiClient _api;
  final ConnectivityService _connectivity;
  final SharedPreferences _prefs;
  final int? Function() _getUserId;
  final _db = DatabaseHelper.instance;
  static const _activeCacheKey = 'cached_active_visit';
  static String _detailCacheKey(int id) => 'cached_visit_detail_$id';
  /// Remembers a real check-in's plan_item_id/purpose/target_order_bags —
  /// the server never hands this back on its own, so without it, a later
  /// sub-action (e.g. complete) going offline creates its pending_visits
  /// placeholder row via getOrCreatePendingVisitForServerId with an EMPTY
  /// check-in payload. That breaks VisitPlanRepository._applyPendingVisitProgress,
  /// which reads plan_item_id from exactly that payload to patch the plan
  /// item's status — the item silently stays PLANNED forever even though
  /// the visit genuinely completed. See _resolvePendingVisitLocalId.
  static String _checkInContextKey(int visitId) => 'checkin_context_$visitId';
  static const _uuid = Uuid();

  static String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  Future<CheckInResult> checkIn({
    required int farmerId,
    required double lat,
    required double lng,
    int? planItemId,
    int? targetOrderBags,
    String? purpose,
    String? farmerName,
  }) async {
    // A negative farmerId is a local placeholder for a farmer created offline
    // that hasn't synced yet — the server has never seen it, so an online call
    // would always return 404 "Farmer not found" even if connectivity just
    // came back. Always use the offline path until the farmer syncs.
    if (!_connectivity.current || farmerId < 0) {
      return _checkInOffline(
        farmerId: farmerId,
        lat: lat,
        lng: lng,
        planItemId: planItemId,
        targetOrderBags: targetOrderBags,
        purpose: purpose,
        farmerName: farmerName ?? '',
      );
    }
    // Only send plan_item_id if it's a real server ID (positive). A negative
    // ID means the plan was created offline and hasn't synced yet — the server
    // can't find it, so send target_order_bags instead so it creates an ad-hoc
    // plan item and the target shows in admin.
    final hasRealPlanItem = planItemId != null && planItemId > 0;
    final data = await _api.post('/visits/check-in', body: {
      'farmer_id': farmerId,
      'lat': lat,
      'lng': lng,
      if (hasRealPlanItem) 'plan_item_id': planItemId,
      if (!hasRealPlanItem && targetOrderBags != null) 'target_order_bags': targetOrderBags,
      if (!hasRealPlanItem && purpose != null) 'purpose': purpose,
    });
    // Always persist farmer_id so offline sub-actions (complete, notes, etc.)
    // can store it on the pending row — without it, _pendingVisitInfo can't
    // associate the row with this farmer and lead/visit status never reflects.
    unawaited(_prefs.setString(
      _checkInContextKey(data['visit_id'] as int),
      jsonEncode({
        'farmer_id': farmerId,
        if (planItemId != null) 'plan_item_id': planItemId,
        if (planItemId == null && targetOrderBags != null)
          'target_order_bags': targetOrderBags,
        if (planItemId == null && purpose != null) 'purpose': purpose,
      }),
    ));
    return CheckInResult.fromJson(data);
  }

  Future<CheckInResult> _checkInOffline({
    required int farmerId,
    required double lat,
    required double lng,
    int? planItemId,
    int? targetOrderBags,
    String? purpose,
    required String farmerName,
  }) async {
    // A15 parity (visit_service.check_in): attendance must be active. The
    // server enforces this online; offline there's no server to ask, so we
    // mirror it against local_attendance_state, which the attendance
    // provider already keeps current on every START/BREAK/RESUME/END.
    final userId = _getUserId();
    if (userId != null) {
      final state = await _db.getLocalAttendanceState(userId);
      if (state == null || !state.shouldTrack) {
        throw const UnknownApiException(
          'Start attendance before visiting farmers.',
          'ATTENDANCE_REQUIRED',
        );
      }
    }

    String? farmerLocalId;
    int? farmerServerId;
    if (farmerId < 0) {
      farmerLocalId = await _resolveFarmerLocalId(farmerId);
      if (farmerLocalId == null) {
        throw const UnknownApiException(
          "This farmer just finished syncing — go back and reopen it, then check in again.",
          'FARMER_NOT_RESOLVED',
        );
      }
    } else {
      farmerServerId = farmerId;
    }

    final localId = _uuid.v4();
    // Same rule as the online path: only include plan_item_id if it's a real
    // server ID. Negative means the plan was offline-created and not yet
    // synced — send target_order_bags so the server can create an ad-hoc
    // plan item when this check-in eventually syncs.
    final hasRealPlanItem = planItemId != null && planItemId > 0;
    final payload = <String, dynamic>{
      'lat': lat,
      'lng': lng,
      'client_id': localId,
      if (hasRealPlanItem) 'plan_item_id': planItemId,
      // Stash the negative local ID so sync_engine can resolve it to the real
      // server plan_item_id once the plan syncs, and so _applyPendingVisitProgress
      // can immediately mark this item COMPLETED/IN_PROGRESS on the plan screen.
      if (!hasRealPlanItem && planItemId != null) '_local_plan_item_id': planItemId,
      if (!hasRealPlanItem && targetOrderBags != null) 'target_order_bags': targetOrderBags,
      if (!hasRealPlanItem && purpose != null) 'purpose': purpose,
    };

    await _db.insertPendingVisit(
      localId: localId,
      farmerLocalId: farmerLocalId,
      farmerServerId: farmerServerId,
      checkInPayloadJson: jsonEncode(payload),
    );

    return CheckInResult.pending(localId: localId, farmerName: farmerName);
  }

  /// Mirrors FarmerRepository's placeholder-id resolution — the id is a
  /// one-way hash, so recovering the farmer it refers to means scanning the
  /// (always small) unsynced set.
  Future<String?> _resolveFarmerLocalId(int placeholderId) async {
    final unsynced = await _db.getAllUnsyncedFarmers();
    for (final f in unsynced) {
      if (placeholderIdFromLocalId(f.localId) == placeholderId) return f.localId;
    }
    // Same fallback as VisitPlanRepository.savePlan — the farmer may have
    // synced away (and left pending_farmers) in the gap between being
    // created and this check-in being attempted. id_mappings keeps every
    // farmer local_id permanently (see
    // DatabaseHelper.insertIdMappingPlaceholder), so this still resolves.
    final allFarmerLocalIds = await _db.getFarmerIdMappingLocalIds();
    for (final localId in allFarmerLocalIds) {
      if (placeholderIdFromLocalId(localId) == placeholderId) return localId;
    }
    return null;
  }

  /// The pending_visits row a sub-action should write into — whichever of
  /// the two ways a visit can already be "known" locally applies: checked
  /// in offline (placeholder id, row already exists from check-in) or
  /// checked in online (real id; row created on first offline sub-action).
  Future<String> _resolvePendingVisitLocalId(int visitId) async {
    if (visitId >= 0) {
      final contextStr = _prefs.getString(_checkInContextKey(visitId));
      final ctx = contextStr != null
          ? jsonDecode(contextStr) as Map<String, dynamic>
          : null;
      return _db.getOrCreatePendingVisitForServerId(
        visitId,
        checkInPayloadJson: contextStr,
        farmerServerId: ctx?['farmer_id'] as int?,
      );
    }
    final unsynced = await _db.getAllUnsyncedVisits();
    for (final v in unsynced) {
      if (placeholderIdFromLocalId(v.localId) == visitId) return v.localId;
    }
    throw const UnknownApiException(
      "This visit's check-in just finished syncing — go back and reopen it.",
      'VISIT_NOT_RESOLVED',
    );
  }

  Future<VisitDetail> locationRemark(int visitId, String remark) async {
    if (!_connectivity.current) {
      final localId = await _resolvePendingVisitLocalId(visitId);
      await _db.setPendingVisitLocationRemark(
          localId, jsonEncode({'remark': remark}));
      return VisitDetail(id: visitId, status: 'CHECKED_IN', locationWarningRemark: remark);
    }
    final data = await _api.post('/visits/$visitId/location-remark',
        body: {'remark': remark});
    return VisitDetail.fromJson(data);
  }

  Future<void> saveNotes(
    int visitId, {
    String? meetingHighlights,
    String? farmerConcerns,
    String? productInterest,
    required int stepCompleted,
  }) async {
    final body = {
      'meeting_highlights': meetingHighlights,
      'farmer_concerns': farmerConcerns,
      'product_interest': productInterest,
      'step_completed': stepCompleted,
    };
    if (!_connectivity.current) {
      final localId = await _resolvePendingVisitLocalId(visitId);
      await _db.setPendingVisitNotes(localId, jsonEncode(body));
      return;
    }
    await _api.patch('/visits/$visitId/notes', body: body);
  }

  Future<LivestockProfile> saveLivestock(
    int visitId,
    Map<String, dynamic> fields,
  ) async {
    if (!_connectivity.current) {
      final localId = await _resolvePendingVisitLocalId(visitId);
      await _db.setPendingVisitLivestock(localId, jsonEncode(fields));
      return LivestockProfile.fromJson({...fields, 'id': visitId});
    }
    final data = await _api.patch('/visits/$visitId/livestock', body: fields);
    return LivestockProfile.fromJson(data);
  }

  Future<VisitOrder> createOrder(
    int visitId, {
    required int bagsCount,
    required DateTime deliveryDate,
    String? deliveryAddress,
    String? paymentMode,
    String? specialNotes,
    double? pricePerBag,
  }) async {
    final body = {
      'bags_count': bagsCount,
      'delivery_date': _ymd(deliveryDate),
      if (deliveryAddress != null && deliveryAddress.isNotEmpty)
        'delivery_address': deliveryAddress,
      if (paymentMode != null) 'payment_mode': paymentMode,
      if (specialNotes != null && specialNotes.isNotEmpty)
        'special_notes': specialNotes,
      if (pricePerBag != null) 'price_per_bag': pricePerBag,
    };
    if (!_connectivity.current) {
      // client_id closes the one remaining duplicate-creation risk in the
      // sub-actions queue (see class doc comment / alembic 0026): if the
      // sync engine's POST lands server-side but the response is lost (app
      // killed mid-sync, dropped connection), the retry next pass is a
      // no-op on the server instead of a second order.
      final localId = await _resolvePendingVisitLocalId(visitId);
      final queued = {...body, 'client_id': _uuid.v4()};
      await _db.appendPendingVisitOrder(localId, jsonEncode(queued));
      return VisitOrder.fromJson({...body, 'id': visitId, 'status': 'SUBMITTED'});
    }
    final data = await _api.post('/visits/$visitId/orders', body: body);
    return VisitOrder.fromJson(data);
  }

  /// Upsert the shared FPO/VLCC 5-question form. When [interestedInSupply] is
  /// true with [interestedBags] > 0 the backend also creates a real order.
  Future<OrgAnswers> saveOrgAnswers(
    int visitId, {
    int? memberCount,
    int? totalCattle,
    String? currentBrand,
    int? monthlyBags,
    bool interestedInSupply = false,
    int? interestedBags,
    double? currentPricePerBag,
    double? priceMin,
    double? priceMax,
    String? notes,
    String? paymentMode,
  }) async {
    final body = {
      'member_count': memberCount,
      'total_cattle': totalCattle,
      'current_brand': currentBrand,
      'monthly_bags': monthlyBags,
      'interested_in_supply': interestedInSupply,
      'interested_bags': interestedBags,
      if (currentPricePerBag != null) 'current_price_per_bag': currentPricePerBag,
      if (priceMin != null) 'price_min': priceMin,
      if (priceMax != null) 'price_max': priceMax,
      if (notes != null && notes.isNotEmpty) 'notes': notes,
      if (paymentMode != null) 'payment_mode': paymentMode,
    };
    if (!_connectivity.current) {
      final localId = await _resolvePendingVisitLocalId(visitId);
      await _db.setPendingVisitOrgAnswers(localId, jsonEncode(body));
      return OrgAnswers.fromJson(body);
    }
    final data = await _api.patch('/visits/$visitId/org-answers', body: body);
    return OrgAnswers.fromJson(data);
  }

  /// Record (or clear) the veterinary requirement for this visit. Powers the
  /// Vet dashboard. Passing [vetRequired] false clears the count/notes.
  Future<VisitDetail> setVet(
    int visitId, {
    required bool vetRequired,
    int? vetCattleCount,
    String? vetNotes,
  }) async {
    final body = {
      'vet_required': vetRequired,
      if (vetRequired && vetCattleCount != null)
        'vet_cattle_count': vetCattleCount,
      if (vetRequired && vetNotes != null && vetNotes.isNotEmpty)
        'vet_notes': vetNotes,
    };
    if (!_connectivity.current) {
      final localId = await _resolvePendingVisitLocalId(visitId);
      await _db.setPendingVisitVet(localId, jsonEncode(body));
      return VisitDetail(
        id: visitId,
        status: 'CHECKED_IN',
        vetRequired: vetRequired,
        vetCattleCount: vetCattleCount,
        vetNotes: vetNotes,
      );
    }
    final data = await _api.patch('/visits/$visitId/vet', body: body);
    return VisitDetail.fromJson(data);
  }

  Future<VisitDetail> complete(
    int visitId, {
    required LeadStatus leadStatus,
    DateTime? followUpDate,
    String? followUpTime, // "HH:MM:SS"
    String? followUpPurpose,
  }) async {
    final body = {
      'lead_status': leadStatus.wire,
      if (followUpDate != null) 'follow_up_date': _ymd(followUpDate),
      if (followUpTime != null) 'follow_up_time': followUpTime,
      if (followUpPurpose != null && followUpPurpose.isNotEmpty)
        'follow_up_purpose': followUpPurpose,
    };
    if (!_connectivity.current) {
      final localId = await _resolvePendingVisitLocalId(visitId);
      await _db.setPendingVisitComplete(localId, jsonEncode(body));
      return VisitDetail(id: visitId, status: 'COMPLETED', lead: leadStatus);
    }
    final data = await _api.post('/visits/$visitId/complete', body: body);
    return VisitDetail.fromJson(data);
  }

  Future<VisitDetail> detail(int visitId) async {
    if (visitId < 0) {
      final pending = await _findPendingVisitByPlaceholderId(visitId);
      if (pending != null) return _pendingVisitDetail(pending);
      throw const UnknownApiException(
        'This visit just finished syncing — go back and reopen it.',
        'VISIT_NOT_RESOLVED',
      );
    }
    if (_connectivity.current) {
      final data = await _api.get('/visits/$visitId');
      unawaited(_prefs.setString(_detailCacheKey(visitId), jsonEncode(data)));
      return VisitDetail.fromJson(data);
    }
    // Offline, real id: a pending row (unsynced sub-actions still queued)
    // is more current than any cached server response.
    final pendingByServer = await _db.getPendingVisitByServerId(visitId);
    if (pendingByServer != null) return _pendingVisitDetail(pendingByServer);
    final cached = _prefs.getString(_detailCacheKey(visitId));
    if (cached != null) {
      try {
        return VisitDetail.fromJson(jsonDecode(cached) as Map<String, dynamic>);
      } catch (_) {
        // fall through to the network call, which will throw a proper
        // NoConnectionException below rather than a JSON-parsing error.
      }
    }
    final data = await _api.get('/visits/$visitId');
    return VisitDetail.fromJson(data);
  }

  Future<PendingVisit?> _findPendingVisitByPlaceholderId(int placeholderId) async {
    final unsynced = await _db.getAllUnsyncedVisits();
    for (final v in unsynced) {
      if (placeholderIdFromLocalId(v.localId) == placeholderId) return v;
    }
    return null;
  }

  /// Builds a `VisitDetail` straight from a `pending_visits` row — the
  /// same data the sync engine itself will eventually send, just read back
  /// for display instead of POSTed.
  Future<VisitDetail> _pendingVisitDetail(PendingVisit v) async {
    final checkIn = v.checkInPayloadJson.isEmpty || v.checkInPayloadJson == '{}'
        ? <String, dynamic>{}
        : jsonDecode(v.checkInPayloadJson) as Map<String, dynamic>;
    final farmer = await _resolveFarmerDisplay(v.farmerServerId, v.farmerLocalId);
    final notes = v.notesJson != null
        ? VisitNoteData.fromJson(jsonDecode(v.notesJson!) as Map<String, dynamic>)
        : null;
    final livestock = v.livestockJson != null
        ? LivestockProfile.fromJson({
            ...jsonDecode(v.livestockJson!) as Map<String, dynamic>,
            'id': v.visitServerId ?? placeholderIdFromLocalId(v.localId),
          })
        : null;
    final orgAnswers = v.orgAnswersJson != null
        ? OrgAnswers.fromJson(jsonDecode(v.orgAnswersJson!) as Map<String, dynamic>)
        : null;
    final vet = v.vetJson != null ? jsonDecode(v.vetJson!) as Map<String, dynamic> : null;
    final orders = v.ordersJson != null
        ? (jsonDecode(v.ordersJson!) as List<dynamic>)
            .map((o) => VisitOrder.fromJson({
                  ...o as Map<String, dynamic>,
                  'id': 0,
                  'status': 'SUBMITTED',
                }))
            .toList()
        : const <VisitOrder>[];
    final complete =
        v.completeJson != null ? jsonDecode(v.completeJson!) as Map<String, dynamic> : null;

    return VisitDetail(
      id: v.visitServerId ?? placeholderIdFromLocalId(v.localId),
      farmerId: farmer?.id,
      farmerName: farmer?.name,
      customerType: farmer?.customerType ?? CustomerType.farmer,
      planItemId: checkIn['plan_item_id'] as int?,
      purpose: checkIn['purpose'] as String?,
      status: complete != null ? 'COMPLETED' : 'CHECKED_IN',
      vetRequired: (vet?['vet_required'] as bool?) ?? false,
      vetCattleCount: vet?['vet_cattle_count'] as int?,
      vetNotes: vet?['vet_notes'] as String?,
      notes: notes,
      livestock: livestock,
      orgAnswers: orgAnswers,
      orders: orders,
      lead: complete != null ? LeadStatus.fromWire(complete['lead_status'] as String?) : null,
    );
  }

  Future<
      ({
        int? id,
        String name,
        String? village,
        CustomerType customerType
      })?> _resolveFarmerDisplay(int? farmerServerId, String? farmerLocalId) async {
    if (farmerServerId != null) {
      final json = await _db.getCachedFarmerJson(farmerServerId);
      if (json == null) {
        return (id: farmerServerId, name: 'Unknown', village: null, customerType: CustomerType.farmer);
      }
      final f = jsonDecode(json) as Map<String, dynamic>;
      return (
        id: farmerServerId,
        name: (f['name'] as String?) ?? 'Unknown',
        village: f['village'] as String?,
        customerType: CustomerType.fromWire(f['customer_type'] as String?),
      );
    }
    if (farmerLocalId != null) {
      final row = await _db.getPendingFarmer(farmerLocalId);
      if (row != null) {
        final f = jsonDecode(row.payloadJson) as Map<String, dynamic>;
        return (
          id: null,
          name: (f['name'] as String?) ?? 'Unknown',
          village: f['village'] as String?,
          customerType: CustomerType.fromWire(f['customer_type'] as String?),
        );
      }
      // Farmer synced away (deleted from pending_farmers) — look it up in
      // id_mappings so the visit detail is not missing farmer info.
      final serverId = await _db.resolveServerId(farmerLocalId);
      if (serverId != null) {
        final json = await _db.getCachedFarmerJson(serverId);
        if (json != null) {
          final f = jsonDecode(json) as Map<String, dynamic>;
          return (
            id: serverId,
            name: (f['name'] as String?) ?? 'Unknown',
            village: f['village'] as String?,
            customerType: CustomerType.fromWire(f['customer_type'] as String?),
          );
        }
        return (id: serverId, name: 'Unknown', village: null, customerType: CustomerType.farmer);
      }
    }
    return null;
  }

  // ── Photos (checklist #24) ──────────────────────────────────────────────

  /// Upload one photo to a visit. Uses the raw Dio (multipart) — the auth +
  /// refresh interceptors still apply. Throws ApiException on failure (e.g. the
  /// 6th photo / oversize file surface as a 400).
  Future<VisitPhoto> uploadPhoto(
    int visitId, {
    required String filePath,
    String? caption,
  }) async {
    final form = FormData.fromMap({
      'file': await MultipartFile.fromFile(filePath),
      if (caption != null && caption.isNotEmpty) 'caption': caption,
    });
    try {
      final res = await _api.dio.post('/visits/$visitId/photos', data: form);
      return VisitPhoto.fromJson(res.data as Map<String, dynamic>);
    } on DioException catch (e) {
      throw ApiClient.mapError(e);
    }
  }

  Future<List<VisitPhoto>> listPhotos(int visitId) async {
    final data = await _api.getList('/visits/$visitId/photos');
    return data
        .map((e) => VisitPhoto.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> deletePhoto(int photoId) async {
    await _api.delete('/visits/photos/$photoId');
  }

  /// The employee's open visit, or null if none. Offline, a not-yet-complete
  /// pending visit (checked in offline, or online but with unsynced
  /// sub-actions) is treated as the active one — it's more current than any
  /// cached server response. If nothing is queued locally, falls back to
  /// the last-known server response rather than erroring (this is a
  /// "usually null" read; failing it loudly for every offline app-open
  /// would be worse than occasionally showing slightly-stale info).
  Future<VisitDetail?> active() async {
    if (_connectivity.current) {
      final data = await _api.get('/visits/active');
      if (data.isEmpty) {
        await _prefs.remove(_activeCacheKey);
        return null;
      }
      unawaited(_prefs.setString(_activeCacheKey, jsonEncode(data)));
      return VisitDetail.fromJson(data);
    }
    final visits = await _db.getAllUnsyncedVisits();
    for (final v in visits) {
      if (v.completeJson == null) return _pendingVisitDetail(v);
    }
    final cached = _prefs.getString(_activeCacheKey);
    if (cached == null) return null;
    try {
      return VisitDetail.fromJson(jsonDecode(cached) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }
}

/// Open (CHECKED_IN) visit, if any — used to offer "resume visit".
final activeVisitProvider = FutureProvider<VisitDetail?>((ref) async {
  return ref.watch(visitRepositoryProvider).active();
});

/// Read-only visit detail by id (visit summary screen).
final visitDetailProvider =
    FutureProvider.family<VisitDetail, int>((ref, id) async {
  return ref.watch(visitRepositoryProvider).detail(id);
});
