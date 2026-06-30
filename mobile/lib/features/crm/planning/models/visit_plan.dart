/// Visit-planning models — mirror app/schemas/crm.py (MyPlanResponse /
/// PlanItemView). Reuses the farmers feature's LeadStatus for the lead pill.
library;

import '../../farmers/models/farmer.dart' show LeadStatus;

DateTime? _dt(dynamic v) =>
    v == null ? null : DateTime.tryParse(v as String)?.toLocal();

/// One stop in a day's plan. Mutable-by-copy: the screen edits a working list
/// of these (add / remove / reorder) before saving.
class PlanItem {
  const PlanItem({
    required this.id,
    required this.farmerId,
    required this.farmerName,
    this.village,
    this.lat,
    this.lng,
    this.leadStatus,
    this.lastVisitAt,
    this.lastVisitNote,
    this.sequenceOrder = 0,
    this.timeSlot,
    this.purpose,
    this.notes,
    this.status = 'PLANNED',
    this.isFollowUp = false,
    this.followUpId,
  });

  final int id;
  final int farmerId;
  final String farmerName;
  final String? village;
  final double? lat;
  final double? lng;
  final LeadStatus? leadStatus;
  final DateTime? lastVisitAt;
  final String? lastVisitNote;
  final int sequenceOrder;

  /// Wire shape "HH:MM:SS" (or "HH:MM"); null if unscheduled.
  final String? timeSlot;
  final String? purpose;
  final String? notes;
  final String status; // PLANNED / COMPLETED / SKIPPED / PENDING (follow-up)
  final bool isFollowUp;
  final int? followUpId;

  /// Stable key for list widgets (plan items and follow-ups share an id space).
  String get key => isFollowUp ? 'fu-$id' : 'pi-$id';

  /// "HH:MM" for display, or null.
  String? get timeLabel {
    if (timeSlot == null || timeSlot!.length < 5) return null;
    return timeSlot!.substring(0, 5);
  }

  PlanItem copyWith({
    int? sequenceOrder,
    String? timeSlot,
    String? purpose,
    String? notes,
    String? status,
  }) =>
      PlanItem(
        id: id,
        farmerId: farmerId,
        farmerName: farmerName,
        village: village,
        lat: lat,
        lng: lng,
        leadStatus: leadStatus,
        lastVisitAt: lastVisitAt,
        lastVisitNote: lastVisitNote,
        sequenceOrder: sequenceOrder ?? this.sequenceOrder,
        timeSlot: timeSlot ?? this.timeSlot,
        purpose: purpose ?? this.purpose,
        notes: notes ?? this.notes,
        status: status ?? this.status,
        isFollowUp: isFollowUp,
        followUpId: followUpId,
      );

  factory PlanItem.fromJson(Map<String, dynamic> json) => PlanItem(
        id: json['id'] as int,
        farmerId: json['farmer_id'] as int,
        farmerName: (json['farmer_name'] as String?) ?? 'Unknown',
        village: json['village'] as String?,
        lat: (json['lat'] as num?)?.toDouble(),
        lng: (json['lng'] as num?)?.toDouble(),
        leadStatus: LeadStatus.fromWire(json['lead_status'] as String?),
        lastVisitAt: _dt(json['last_visit_at']),
        lastVisitNote: json['last_visit_note'] as String?,
        sequenceOrder: (json['sequence_order'] as int?) ?? 0,
        timeSlot: json['time_slot'] as String?,
        purpose: json['purpose'] as String?,
        notes: json['notes'] as String?,
        status: (json['status'] as String?) ?? 'PLANNED',
        isFollowUp: (json['is_follow_up'] as bool?) ?? false,
        followUpId: json['follow_up_id'] as int?,
      );

  /// Body shape for POST /visit-plans items.
  Map<String, dynamic> toInput(int sequence) => {
        'farmer_id': farmerId,
        'sequence_order': sequence,
        if (timeSlot != null) 'time_slot': timeSlot,
        if (purpose != null) 'purpose': purpose,
        if (notes != null && notes!.isNotEmpty) 'notes': notes,
      };
}

class MyPlan {
  const MyPlan({
    this.id,
    required this.planDate,
    this.status = 'DRAFT',
    this.submittedAt,
    this.items = const [],
  });

  final int? id;
  final DateTime planDate;
  final String status; // DRAFT / SUBMITTED / IN_PROGRESS / COMPLETED
  final DateTime? submittedAt;
  final List<PlanItem> items;

  bool get isSubmitted =>
      status == 'SUBMITTED' || status == 'IN_PROGRESS' || status == 'COMPLETED';

  factory MyPlan.fromJson(Map<String, dynamic> json) => MyPlan(
        id: json['id'] as int?,
        planDate: DateTime.parse(json['plan_date'] as String),
        status: (json['status'] as String?) ?? 'DRAFT',
        submittedAt: _dt(json['submitted_at']),
        items: ((json['items'] as List<dynamic>?) ?? [])
            .map((e) => PlanItem.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}
