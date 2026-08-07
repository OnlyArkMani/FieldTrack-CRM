import 'package:intl/intl.dart';

/// Lightweight summary used for history list.
class DsrSummary {
  const DsrSummary({
    required this.id,
    required this.reportDate,
    required this.status,
    required this.visitsCompleted,
    required this.ordersCaptures,
    required this.hotLeads,
    required this.warmLeads,
    required this.coldLeads,
    required this.isLate,
    this.submittedAt,
    this.endOfDayNote,
    this.lateCheckoutReason,
    this.managerComment,
  });

  final int id;
  final DateTime reportDate;
  final String status; // DRAFT / SUBMITTED
  final int visitsCompleted;
  final int ordersCaptures;
  final int hotLeads;
  final int warmLeads;
  final int coldLeads;
  final bool isLate;
  final DateTime? submittedAt;
  final String? endOfDayNote;
  final String? lateCheckoutReason;
  final String? managerComment;

  bool get isSubmitted => status == 'SUBMITTED';

  static DateTime _parseDate(String s) => DateTime.parse(s);

  factory DsrSummary.fromJson(Map<String, dynamic> j) => DsrSummary(
        id: j['id'] as int,
        reportDate: _parseDate(j['report_date'] as String),
        status: j['status'] as String,
        visitsCompleted: j['visits_completed'] as int,
        ordersCaptures: j['orders_captured'] as int,
        hotLeads: j['hot_leads'] as int,
        warmLeads: j['warm_leads'] as int,
        coldLeads: j['cold_leads'] as int,
        isLate: j['is_late'] as bool? ?? false,
        submittedAt: j['submitted_at'] != null
            ? DateTime.parse(j['submitted_at'] as String)
            : null,
        endOfDayNote: j['end_of_day_note'] as String?,
        lateCheckoutReason: j['late_checkout_reason'] as String?,
        managerComment: j['manager_comment'] as String?,
      );
}

/// One team member's DSR status for a date (manager team view).
class TeamDsrItem {
  const TeamDsrItem({
    required this.employeeId,
    required this.employeeName,
    required this.status,
    required this.visitsCompleted,
    required this.ordersCaptured,
    required this.hotLeads,
    required this.warmLeads,
    required this.coldLeads,
    required this.isLate,
    this.reportId,
  });

  final int employeeId;
  final String employeeName;
  final String status; // SUBMITTED / DRAFT / MISSING
  final int visitsCompleted;
  final int ordersCaptured;
  final int hotLeads;
  final int warmLeads;
  final int coldLeads;
  final bool isLate;
  final int? reportId;

  factory TeamDsrItem.fromJson(Map<String, dynamic> j) => TeamDsrItem(
        employeeId: j['employee_id'] as int,
        employeeName: j['employee_name'] as String? ?? 'Employee',
        status: j['status'] as String? ?? 'MISSING',
        visitsCompleted: j['visits_completed'] as int? ?? 0,
        ordersCaptured: j['orders_captured'] as int? ?? 0,
        hotLeads: j['hot_leads'] as int? ?? 0,
        warmLeads: j['warm_leads'] as int? ?? 0,
        coldLeads: j['cold_leads'] as int? ?? 0,
        isLate: j['is_late'] as bool? ?? false,
        reportId: j['report_id'] as int?,
      );
}

/// Full DSR including per-visit, order, and follow-up lists.
class DsrDetail extends DsrSummary {
  const DsrDetail({
    required super.id,
    required super.reportDate,
    required super.status,
    required super.visitsCompleted,
    required super.ordersCaptures,
    required super.hotLeads,
    required super.warmLeads,
    required super.coldLeads,
    required super.isLate,
    super.submittedAt,
    super.endOfDayNote,
    super.lateCheckoutReason,
    super.managerComment,
    required this.visits,
    required this.orders,
    required this.followUps,
    required this.visitsPlanCount,
  });

  final List<DsrVisit> visits;
  final List<DsrOrder> orders;
  final List<DsrFollowUp> followUps;
  final int visitsPlanCount;

  factory DsrDetail.fromJson(Map<String, dynamic> j) => DsrDetail(
        id: j['id'] as int,
        reportDate: DateTime.parse(j['report_date'] as String),
        status: j['status'] as String,
        visitsCompleted: j['visits_completed'] as int,
        ordersCaptures: j['orders_captured'] as int,
        hotLeads: j['hot_leads'] as int,
        warmLeads: j['warm_leads'] as int,
        coldLeads: j['cold_leads'] as int,
        isLate: j['is_late'] as bool? ?? false,
        submittedAt: j['submitted_at'] != null
            ? DateTime.parse(j['submitted_at'] as String)
            : null,
        endOfDayNote: j['end_of_day_note'] as String?,
        lateCheckoutReason: j['late_checkout_reason'] as String?,
        managerComment: j['manager_comment'] as String?,
        visitsPlanCount: j['visits_planned'] as int? ?? 0,
        visits: (j['visits'] as List<dynamic>? ?? [])
            .map((e) => DsrVisit.fromJson(e as Map<String, dynamic>))
            .toList(),
        orders: (j['orders'] as List<dynamic>? ?? [])
            .map((e) => DsrOrder.fromJson(e as Map<String, dynamic>))
            .toList(),
        followUps: (j['follow_ups'] as List<dynamic>? ?? [])
            .map((e) => DsrFollowUp.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class DsrVisit {
  const DsrVisit({
    required this.id,
    this.farmerId,
    required this.farmerName,
    this.village,
    this.customerType,
    this.purpose,
    this.checkInAt,
    this.checkOutAt,
    this.leadStatus,
    this.meetingHighlights,
    this.farmerConcerns,
    this.productInterest,
    this.vetRequired = false,
    this.vetCattleCount,
    this.orderBags,
    this.orderValue,
    this.breed,
    this.currentBrand,
    this.livestockCattle,
    this.pricePerBag,
  });

  final int id;
  final int? farmerId;
  final String farmerName;
  final String? village;
  final String? customerType;
  final String? purpose;
  final DateTime? checkInAt;
  final DateTime? checkOutAt;
  final String? leadStatus;
  final String? meetingHighlights;
  final String? farmerConcerns;
  final String? productInterest;
  final bool vetRequired;
  final int? vetCattleCount;
  final int? orderBags;
  final double? orderValue;
  final String? breed;
  final String? currentBrand;
  final int? livestockCattle;
  final double? pricePerBag;

  static double? _d(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  /// True when there is expandable detail worth showing.
  bool get hasDetail =>
      (meetingHighlights != null && meetingHighlights!.isNotEmpty) ||
      (farmerConcerns != null && farmerConcerns!.isNotEmpty) ||
      (productInterest != null && productInterest!.isNotEmpty) ||
      vetRequired ||
      (orderBags != null && orderBags! > 0) ||
      breed != null ||
      currentBrand != null ||
      livestockCattle != null;

  factory DsrVisit.fromJson(Map<String, dynamic> j) => DsrVisit(
        id: j['id'] as int,
        farmerId: j['farmer_id'] as int?,
        farmerName: j['farmer_name'] as String? ?? 'Unknown Farmer',
        village: j['village'] as String?,
        customerType: j['customer_type'] as String?,
        purpose: j['purpose'] as String?,
        checkInAt: j['check_in_at'] != null
            ? DateTime.parse(j['check_in_at'] as String)
            : null,
        checkOutAt: j['check_out_at'] != null
            ? DateTime.parse(j['check_out_at'] as String)
            : null,
        leadStatus: j['lead_status'] as String?,
        meetingHighlights: j['meeting_highlights'] as String?,
        farmerConcerns: j['farmer_concerns'] as String?,
        productInterest: j['product_interest'] as String?,
        vetRequired: j['vet_required'] as bool? ?? false,
        vetCattleCount: j['vet_cattle_count'] as int?,
        orderBags: j['order_bags'] as int?,
        orderValue: _d(j['order_value']),
        breed: j['breed'] as String?,
        currentBrand: j['current_brand'] as String?,
        livestockCattle: j['livestock_cattle'] as int?,
        pricePerBag: _d(j['price_per_bag']),
      );

  String get purposeLabel {
    if (purpose == null || purpose!.isEmpty) return 'Visit';
    return purpose!
        .toLowerCase()
        .split('_')
        .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
        .join(' ');
  }

  String get timeLabel {
    if (checkInAt == null) return '';
    final fmt = DateFormat('h:mm a');
    if (checkOutAt != null) {
      return '${fmt.format(checkInAt!.toLocal())} – ${fmt.format(checkOutAt!.toLocal())}';
    }
    return fmt.format(checkInAt!.toLocal());
  }
}

class DsrOrder {
  const DsrOrder({
    required this.id,
    required this.farmerName,
    required this.bagsCount,
    required this.deliveryDate,
    this.paymentMode,
  });

  final int id;
  final String farmerName;
  final int bagsCount;
  final DateTime deliveryDate;
  final String? paymentMode;

  factory DsrOrder.fromJson(Map<String, dynamic> j) => DsrOrder(
        id: j['id'] as int,
        farmerName: j['farmer_name'] as String? ?? 'Unknown Farmer',
        bagsCount: j['bags_count'] as int,
        deliveryDate: DateTime.parse(j['delivery_date'] as String),
        paymentMode: j['payment_mode'] as String?,
      );
}

class DsrFollowUp {
  const DsrFollowUp({
    required this.id,
    required this.farmerName,
    required this.scheduledDate,
    this.scheduledTime,
    this.purpose,
  });

  final int id;
  final String farmerName;
  final DateTime scheduledDate;
  final String? scheduledTime;
  final String? purpose;

  factory DsrFollowUp.fromJson(Map<String, dynamic> j) => DsrFollowUp(
        id: j['id'] as int,
        farmerName: j['farmer_name'] as String? ?? 'Unknown Farmer',
        scheduledDate: DateTime.parse(j['scheduled_date'] as String),
        scheduledTime: j['scheduled_time'] as String?,
        purpose: j['purpose'] as String?,
      );
}
