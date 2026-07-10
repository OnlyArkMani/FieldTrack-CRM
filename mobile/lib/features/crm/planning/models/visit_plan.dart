/// Visit-planning models — mirror app/schemas/crm.py (MyPlanResponse /
/// PlanItemView). Reuses the farmers feature's LeadStatus for the lead pill.
library;

import '../../farmers/models/farmer.dart' show CustomerType, LeadStatus;

DateTime? _dt(dynamic v) =>
    v == null ? null : DateTime.tryParse(v as String)?.toLocal();

/// One stop in a day's plan. Mutable-by-copy: the screen edits a working list
/// of these (add / remove / reorder) before saving.
class PlanItem {
  const PlanItem({
    required this.id,
    required this.farmerId,
    required this.farmerName,
    this.customerType = CustomerType.farmer,
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
    this.targetOrderBags,
    this.status = 'PLANNED',
    this.isFollowUp = false,
    this.followUpId,
    this.isCarryOver = false,
    this.originalDate,
  });

  final int id;
  final int farmerId;
  final String farmerName;
  final CustomerType customerType;
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

  /// Bags the executive is targeting to sell/collect an order for at this stop.
  final int? targetOrderBags;
  final String status; // PLANNED / COMPLETED / SKIPPED / PENDING (follow-up)
  final bool isFollowUp;
  final int? followUpId;

  /// A missed PLANNED stop carried over from an earlier day's plan.
  final bool isCarryOver;
  final DateTime? originalDate;

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
    int? targetOrderBags,
    String? status,
  }) =>
      PlanItem(
        id: id,
        farmerId: farmerId,
        farmerName: farmerName,
        customerType: customerType,
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
        targetOrderBags: targetOrderBags ?? this.targetOrderBags,
        status: status ?? this.status,
        isFollowUp: isFollowUp,
        followUpId: followUpId,
        isCarryOver: isCarryOver,
        originalDate: originalDate,
      );

  factory PlanItem.fromJson(Map<String, dynamic> json) => PlanItem(
        id: json['id'] as int,
        farmerId: json['farmer_id'] as int,
        farmerName: (json['farmer_name'] as String?) ?? 'Unknown',
        customerType: CustomerType.fromWire(json['customer_type'] as String?),
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
        targetOrderBags: json['target_order_bags'] as int?,
        status: (json['status'] as String?) ?? 'PLANNED',
        isFollowUp: (json['is_follow_up'] as bool?) ?? false,
        followUpId: json['follow_up_id'] as int?,
        isCarryOver: (json['is_carry_over'] as bool?) ?? false,
        originalDate: _dt(json['original_date']),
      );

  /// Body shape for POST /visit-plans items.
  Map<String, dynamic> toInput(int sequence) => {
        'farmer_id': farmerId,
        'sequence_order': sequence,
        if (timeSlot != null) 'time_slot': timeSlot,
        if (purpose != null) 'purpose': purpose,
        if (notes != null && notes!.isNotEmpty) 'notes': notes,
        if (targetOrderBags != null) 'target_order_bags': targetOrderBags,
      };
}

/// One employee's plan summary in the manager's team view — mirrors
/// TeamPlanEmployeeView.
class TeamPlanEmployee {
  const TeamPlanEmployee({
    required this.employeeId,
    required this.employeeName,
    this.teamName,
    this.planId,
    this.status = 'NOT_SUBMITTED',
    this.visitsPlanned = 0,
    this.submittedAt,
    this.items = const [],
  });

  final int employeeId;
  final String employeeName;
  final String? teamName;
  final int? planId;
  final String status; // NOT_SUBMITTED / DRAFT / SUBMITTED / IN_PROGRESS / COMPLETED
  final int visitsPlanned;
  final DateTime? submittedAt;
  final List<PlanItem> items;

  factory TeamPlanEmployee.fromJson(Map<String, dynamic> json) =>
      TeamPlanEmployee(
        employeeId: json['employee_id'] as int,
        employeeName: (json['employee_name'] as String?) ?? 'Unknown',
        teamName: json['team_name'] as String?,
        planId: json['plan_id'] as int?,
        status: (json['status'] as String?) ?? 'NOT_SUBMITTED',
        visitsPlanned: (json['visits_planned'] as int?) ?? 0,
        submittedAt: _dt(json['submitted_at']),
        items: ((json['items'] as List<dynamic>?) ?? [])
            .map((e) => PlanItem.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// GET /visit-plans/team/{date} — manager/admin only.
class TeamPlans {
  const TeamPlans({required this.planDate, this.employees = const []});

  final DateTime planDate;
  final List<TeamPlanEmployee> employees;

  factory TeamPlans.fromJson(Map<String, dynamic> json) => TeamPlans(
        planDate: DateTime.parse(json['plan_date'] as String),
        employees: ((json['employees'] as List<dynamic>?) ?? [])
            .map((e) => TeamPlanEmployee.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class MyPlan {
  const MyPlan({
    this.id,
    required this.planDate,
    this.status = 'DRAFT',
    this.submittedAt,
    this.items = const [],
    this.isOnLeave = false,
  });

  final int? id;
  final DateTime planDate;
  final String status; // DRAFT / SUBMITTED / IN_PROGRESS / COMPLETED
  final DateTime? submittedAt;
  final List<PlanItem> items;

  /// True when the employee is marked on leave for [planDate] — visits can't
  /// be planned for this day (mirrors the server-side guard).
  final bool isOnLeave;

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
        isOnLeave: (json['is_on_leave'] as bool?) ?? false,
      );
}
