import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/network/api_client.dart';
import '../../farmers/models/farmer.dart' show LivestockProfile, LeadStatus;
import '../models/visit.dart';

final visitRepositoryProvider = Provider<VisitRepository>((ref) {
  return VisitRepository(ref.watch(apiClientProvider));
});

/// Thin wrapper over the /visits API.
class VisitRepository {
  VisitRepository(this._api);
  final ApiClient _api;

  static String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  Future<CheckInResult> checkIn({
    required int farmerId,
    required double lat,
    required double lng,
    int? planItemId,
  }) async {
    final data = await _api.post('/visits/check-in', body: {
      'farmer_id': farmerId,
      'lat': lat,
      'lng': lng,
      if (planItemId != null) 'plan_item_id': planItemId,
    });
    return CheckInResult.fromJson(data);
  }

  Future<VisitDetail> locationRemark(int visitId, String remark) async {
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
    await _api.patch('/visits/$visitId/notes', body: {
      'meeting_highlights': meetingHighlights,
      'farmer_concerns': farmerConcerns,
      'product_interest': productInterest,
      'step_completed': stepCompleted,
    });
  }

  Future<LivestockProfile> saveLivestock(
    int visitId,
    Map<String, dynamic> fields,
  ) async {
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
  }) async {
    final data = await _api.post('/visits/$visitId/orders', body: {
      'bags_count': bagsCount,
      'delivery_date': _ymd(deliveryDate),
      if (deliveryAddress != null && deliveryAddress.isNotEmpty)
        'delivery_address': deliveryAddress,
      if (paymentMode != null) 'payment_mode': paymentMode,
      if (specialNotes != null && specialNotes.isNotEmpty)
        'special_notes': specialNotes,
    });
    return VisitOrder.fromJson(data);
  }

  Future<VisitDetail> complete(
    int visitId, {
    required LeadStatus leadStatus,
    DateTime? followUpDate,
    String? followUpTime, // "HH:MM:SS"
    String? followUpPurpose,
  }) async {
    final data = await _api.post('/visits/$visitId/complete', body: {
      'lead_status': leadStatus.wire,
      if (followUpDate != null) 'follow_up_date': _ymd(followUpDate),
      if (followUpTime != null) 'follow_up_time': followUpTime,
      if (followUpPurpose != null && followUpPurpose.isNotEmpty)
        'follow_up_purpose': followUpPurpose,
    });
    return VisitDetail.fromJson(data);
  }

  Future<VisitDetail> detail(int visitId) async {
    final data = await _api.get('/visits/$visitId');
    return VisitDetail.fromJson(data);
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

  /// The employee's open visit, or null if none.
  Future<VisitDetail?> active() async {
    final data = await _api.get('/visits/active');
    if (data.isEmpty) return null;
    return VisitDetail.fromJson(data);
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
