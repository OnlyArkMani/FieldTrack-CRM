/// Visit-execution models — mirror app/schemas/crm.py (check-in, visit detail,
/// notes, livestock, orders, lead). Reuses the farmers feature's LeadStatus and
/// LivestockProfile so there's one source of truth for those shapes.
library;

import '../../farmers/models/farmer.dart' show LeadStatus, LivestockProfile;

DateTime? _dt(dynamic v) =>
    v == null ? null : DateTime.tryParse(v as String)?.toLocal();

double? _d(dynamic v) => (v as num?)?.toDouble();

/// Result of POST /visits/check-in.
class CheckInResult {
  const CheckInResult({
    required this.visitId,
    required this.locationWarning,
    this.distanceMeters,
    required this.farmerName,
    required this.warningRequired,
  });

  final int visitId;
  final bool locationWarning;
  final double? distanceMeters;
  final String farmerName;
  final bool warningRequired;

  factory CheckInResult.fromJson(Map<String, dynamic> json) => CheckInResult(
        visitId: json['visit_id'] as int,
        locationWarning: (json['location_warning'] as bool?) ?? false,
        distanceMeters: _d(json['distance_meters']),
        farmerName: (json['farmer_name'] as String?) ?? '',
        warningRequired: (json['warning_required'] as bool?) ?? false,
      );
}

class VisitNoteData {
  const VisitNoteData({
    this.meetingHighlights,
    this.farmerConcerns,
    this.productInterest,
    this.stepCompleted = 0,
  });

  final String? meetingHighlights;
  final String? farmerConcerns;
  final String? productInterest;
  final int stepCompleted;

  factory VisitNoteData.fromJson(Map<String, dynamic> json) => VisitNoteData(
        meetingHighlights: json['meeting_highlights'] as String?,
        farmerConcerns: json['farmer_concerns'] as String?,
        productInterest: json['product_interest'] as String?,
        stepCompleted: (json['step_completed'] as int?) ?? 0,
      );
}

class VisitOrder {
  const VisitOrder({
    required this.id,
    required this.bagsCount,
    this.deliveryDate,
    this.deliveryAddress,
    this.paymentMode,
    this.specialNotes,
    this.status = 'SUBMITTED',
  });

  final int id;
  final int bagsCount;
  final DateTime? deliveryDate;
  final String? deliveryAddress;
  final String? paymentMode;
  final String? specialNotes;
  final String status;

  factory VisitOrder.fromJson(Map<String, dynamic> json) => VisitOrder(
        id: json['id'] as int,
        bagsCount: (json['bags_count'] as int?) ?? 0,
        deliveryDate: _dt(json['delivery_date']),
        deliveryAddress: json['delivery_address'] as String?,
        paymentMode: json['payment_mode'] as String?,
        specialNotes: json['special_notes'] as String?,
        status: (json['status'] as String?) ?? 'SUBMITTED',
      );
}

/// One photo attached to a visit (checklist #24). The image bytes are fetched
/// from [downloadUrl] (relative to the API base) with the bearer token.
class VisitPhoto {
  const VisitPhoto({
    required this.id,
    this.visitId,
    this.caption,
    this.contentType,
    this.sizeBytes,
    this.downloadUrl,
    this.createdAt,
  });

  final int id;
  final int? visitId;
  final String? caption;
  final String? contentType;
  final int? sizeBytes;
  final String? downloadUrl;
  final DateTime? createdAt;

  factory VisitPhoto.fromJson(Map<String, dynamic> json) => VisitPhoto(
        id: json['id'] as int,
        visitId: json['visit_id'] as int?,
        caption: json['caption'] as String?,
        contentType: json['content_type'] as String?,
        sizeBytes: json['size_bytes'] as int?,
        downloadUrl: json['download_url'] as String?,
        createdAt: _dt(json['created_at']),
      );
}

/// Full visit detail (GET /visits/{id}, /visits/active, and the result of
/// check-out).
class VisitDetail {
  const VisitDetail({
    required this.id,
    this.employeeId,
    this.farmerId,
    this.farmerName,
    this.planItemId,
    this.checkInAt,
    this.checkOutAt,
    this.distanceAtCheckinMeters,
    this.locationWarning = false,
    this.locationWarningRemark,
    this.purpose,
    required this.status,
    this.notes,
    this.livestock,
    this.orders = const [],
    this.lead,
    this.photos = const [],
  });

  final int id;
  final int? employeeId;
  final int? farmerId;
  final String? farmerName;
  final int? planItemId;
  final DateTime? checkInAt;
  final DateTime? checkOutAt;
  final double? distanceAtCheckinMeters;
  final bool locationWarning;
  final String? locationWarningRemark;
  final String? purpose;
  final String status;
  final VisitNoteData? notes;
  final LivestockProfile? livestock;
  final List<VisitOrder> orders;
  final LeadStatus? lead;
  final List<VisitPhoto> photos;

  factory VisitDetail.fromJson(Map<String, dynamic> json) => VisitDetail(
        id: json['id'] as int,
        employeeId: json['employee_id'] as int?,
        farmerId: json['farmer_id'] as int?,
        farmerName: json['farmer_name'] as String?,
        planItemId: json['plan_item_id'] as int?,
        checkInAt: _dt(json['check_in_at']),
        checkOutAt: _dt(json['check_out_at']),
        distanceAtCheckinMeters: _d(json['distance_at_checkin_meters']),
        locationWarning: (json['location_warning'] as bool?) ?? false,
        locationWarningRemark: json['location_warning_remark'] as String?,
        purpose: json['purpose'] as String?,
        status: (json['status'] as String?) ?? 'CHECKED_IN',
        notes: json['notes'] != null
            ? VisitNoteData.fromJson(json['notes'] as Map<String, dynamic>)
            : null,
        livestock: json['livestock'] != null
            ? LivestockProfile.fromJson(
                json['livestock'] as Map<String, dynamic>)
            : null,
        orders: ((json['orders'] as List<dynamic>?) ?? [])
            .map((e) => VisitOrder.fromJson(e as Map<String, dynamic>))
            .toList(),
        lead: json['lead'] != null
            ? LeadStatus.fromWire(
                (json['lead'] as Map<String, dynamic>)['status'] as String?)
            : null,
        photos: ((json['photos'] as List<dynamic>?) ?? [])
            .map((e) => VisitPhoto.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}
