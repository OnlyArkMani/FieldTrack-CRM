/// CRM farmer models — mirror the backend app/schemas/crm.py wire shapes.
///
/// Lead status is its own enum (Hot/Warm/Cold) with a UI color resolved at the
/// widget layer (see widgets/lead_status_badge.dart) so the model stays
/// presentation-free.
library;

enum LeadStatus {
  hot('HOT'),
  warm('WARM'),
  cold('COLD');

  const LeadStatus(this.wire);
  final String wire;

  static LeadStatus? fromWire(String? v) {
    if (v == null) return null;
    for (final s in LeadStatus.values) {
      if (s.wire == v) return s;
    }
    return null;
  }

  String get label => switch (this) {
        LeadStatus.hot => 'Hot',
        LeadStatus.warm => 'Warm',
        LeadStatus.cold => 'Cold',
      };
}

/// Customer discriminator (mirrors backend CustomerType). Farmers use the
/// guided livestock flow; FPO, VLCC and Retailer share the 5-question org
/// form (Retailer reuses the FPO/VLCC form as-is — no dedicated fields).
enum CustomerType {
  farmer('FARMER_MEET'),
  fpo('FPO'),
  vlcc('VLCC'),
  retailer('RETAILER'),
  distributor('DISTRIBUTOR');

  const CustomerType(this.wire);
  final String wire;

  static CustomerType fromWire(String? v) {
    for (final t in CustomerType.values) {
      if (t.wire == v) return t;
    }
    return CustomerType.farmer;
  }

  String get label => switch (this) {
        CustomerType.farmer => 'Farmer Meet',
        CustomerType.fpo => 'FPO',
        CustomerType.vlcc => 'VLCC',
        CustomerType.retailer => 'Retailer',
        CustomerType.distributor => 'Distributor',
      };

  /// FPO, VLCC, Retailer and Distributor answer the shared organisation form
  /// instead of livestock.
  bool get isOrg => this != CustomerType.farmer;
}

DateTime? _dt(dynamic v) =>
    v == null ? null : DateTime.tryParse(v as String)?.toLocal();

double? _d(dynamic v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v);
  return null;
}

/// A farmer created offline has no real server id yet. This derives a
/// stable-for-this-run placeholder int from the client UUID so screens that
/// key on `int id` (routes, providers) keep working unmodified — the actual
/// identity while pending is [FarmerDetail.localId] / [FarmerListItem.localId],
/// never this placeholder. Negative so it can never collide with a real
/// (always-positive) server id.
int placeholderIdFromLocalId(String localId) => -(localId.hashCode.abs()) - 1;

/// One row in the farmer list (GET /farmers).
class FarmerListItem {
  const FarmerListItem({
    required this.id,
    required this.name,
    this.customerType = CustomerType.farmer,
    this.phone,
    this.village,
    this.district,
    this.totalCattle = 0,
    this.isActive = true,
    this.teamId,
    this.teamName,
    this.leadStatus,
    this.lastVisitAt,
    this.createdAt,
    this.localId,
    this.syncStatus,
  });

  final int id;
  final String name;
  final CustomerType customerType;
  final String? phone;
  final String? village;
  final String? district;
  final int totalCattle;
  final bool isActive;
  final int? teamId;
  final String? teamName;
  final LeadStatus? leadStatus;
  final DateTime? lastVisitAt;
  final DateTime? createdAt;
  /// Non-null only for a farmer that was created offline. While non-null,
  /// [id] is a placeholder, not a real server id — see
  /// [placeholderIdFromLocalId].
  final String? localId;
  /// Mirrors DatabaseHelper.farmerStatus* when [localId] is set — lets the
  /// list UI show "pending sync" vs "needs attention" badges.
  final int? syncStatus;

  bool get isPending => localId != null;

  /// Only `lastVisitAt`/`leadStatus` are ever overridden — to merge in an
  /// offline visit's effect on this row (see
  /// FarmerRepository._applyPendingVisitInfo).
  FarmerListItem copyWith({DateTime? lastVisitAt, LeadStatus? leadStatus}) =>
      FarmerListItem(
        id: id,
        name: name,
        customerType: customerType,
        phone: phone,
        village: village,
        district: district,
        totalCattle: totalCattle,
        isActive: isActive,
        teamId: teamId,
        teamName: teamName,
        leadStatus: leadStatus ?? this.leadStatus,
        lastVisitAt: lastVisitAt ?? this.lastVisitAt,
        createdAt: createdAt,
        localId: localId,
        syncStatus: syncStatus,
      );

  factory FarmerListItem.pending({
    required String localId,
    required Map<String, dynamic> payload,
    required int syncStatus,
  }) =>
      FarmerListItem(
        id: placeholderIdFromLocalId(localId),
        name: payload['name'] as String? ?? '',
        customerType: CustomerType.fromWire(payload['customer_type'] as String?),
        phone: payload['phone'] as String?,
        village: payload['village'] as String?,
        district: payload['district'] as String?,
        totalCattle: (payload['total_cattle'] as int?) ?? 0,
        localId: localId,
        syncStatus: syncStatus,
      );

  factory FarmerListItem.fromJson(Map<String, dynamic> json) => FarmerListItem(
        id: json['id'] as int,
        name: json['name'] as String,
        customerType: CustomerType.fromWire(json['customer_type'] as String?),
        phone: json['phone'] as String?,
        village: json['village'] as String?,
        district: json['district'] as String?,
        totalCattle: (json['total_cattle'] as int?) ?? 0,
        isActive: (json['is_active'] as bool?) ?? true,
        teamId: json['team_id'] as int?,
        teamName: json['team_name'] as String?,
        leadStatus: LeadStatus.fromWire(json['lead_status'] as String?),
        lastVisitAt: _dt(json['last_visit_at']),
        createdAt: _dt(json['created_at']),
      );
}

/// Cursor page envelope (mirrors backend CursorPage).
class FarmerPage {
  const FarmerPage({
    required this.items,
    required this.total,
    required this.hasMore,
    this.nextCursor,
  });

  final List<FarmerListItem> items;
  final int total;
  final bool hasMore;
  final String? nextCursor;

  factory FarmerPage.fromJson(Map<String, dynamic> json) => FarmerPage(
        items: ((json['items'] as List<dynamic>?) ?? [])
            .map((e) => FarmerListItem.fromJson(e as Map<String, dynamic>))
            .toList(),
        total: (json['total'] as int?) ?? 0,
        hasMore: (json['has_more'] as bool?) ?? false,
        nextCursor: json['next_cursor'] as String?,
      );
}

class VisitSummary {
  const VisitSummary({
    required this.id,
    this.employeeId,
    this.checkInAt,
    this.checkOutAt,
    this.purpose,
    required this.status,
    this.createdAt,
    this.syncStatus,
  });

  final int id;
  final int? employeeId;
  final DateTime? checkInAt;
  final DateTime? checkOutAt;
  final String? purpose;
  final String status;
  final DateTime? createdAt;
  /// Mirrors `DatabaseHelper.visitStatus*` — non-null only for a synthetic
  /// entry built from a `pending_visits` row (see
  /// FarmerRepository._pendingVisitSummaries); null for a real server row.
  final int? syncStatus;

  /// A negative id is always a placeholder for an unsynced visit — see
  /// placeholderIdFromLocalId. Real server ids are always positive.
  bool get isPending => id < 0;

  factory VisitSummary.fromJson(Map<String, dynamic> json) => VisitSummary(
        id: json['id'] as int,
        employeeId: json['employee_id'] as int?,
        checkInAt: _dt(json['check_in_at']),
        checkOutAt: _dt(json['check_out_at']),
        purpose: json['purpose'] as String?,
        status: (json['status'] as String?) ?? 'CHECKED_IN',
        createdAt: _dt(json['created_at']),
      );
}

class LivestockProfile {
  const LivestockProfile({
    required this.id,
    this.farmerId,
    this.visitId,
    this.totalCattle,
    this.breed,
    this.ageGroup,
    this.currentBrand,
    this.bagsPerMonth,
    this.kgPerAnimalPerDay,
    this.currentPricePerBag,
    this.willingToPayMin,
    this.willingToPayMax,
    this.healthStatus,
    this.healthNotes,
    this.usesCattleFeed,
    this.interestedInNewFeed,
    this.recordedAt,
  });

  final int id;
  final int? farmerId;
  final int? visitId;
  final int? totalCattle;
  final String? breed;
  final String? ageGroup;
  final String? currentBrand;
  final int? bagsPerMonth;
  final double? kgPerAnimalPerDay;
  final double? currentPricePerBag;
  final double? willingToPayMin;
  final double? willingToPayMax;
  final String? healthStatus;
  final String? healthNotes;
  final bool? usesCattleFeed;
  final bool? interestedInNewFeed;
  final DateTime? recordedAt;

  factory LivestockProfile.fromJson(Map<String, dynamic> json) =>
      LivestockProfile(
        id: json['id'] as int,
        farmerId: json['farmer_id'] as int?,
        visitId: json['visit_id'] as int?,
        totalCattle: json['total_cattle'] as int?,
        breed: json['breed'] as String?,
        ageGroup: json['age_group'] as String?,
        currentBrand: json['current_brand'] as String?,
        bagsPerMonth: json['bags_per_month'] as int?,
        kgPerAnimalPerDay: _d(json['kg_per_animal_per_day']),
        currentPricePerBag: _d(json['current_price_per_bag']),
        willingToPayMin: _d(json['willing_to_pay_min']),
        willingToPayMax: _d(json['willing_to_pay_max']),
        healthStatus: json['health_status'] as String?,
        healthNotes: json['health_notes'] as String?,
        usesCattleFeed: json['uses_cattle_feed'] as bool?,
        interestedInNewFeed: json['interested_in_new_feed'] as bool?,
        recordedAt: _dt(json['recorded_at']),
      );
}

class LeadHistoryItem {
  const LeadHistoryItem({
    required this.id,
    required this.status,
    this.reasonNote,
    this.employeeId,
    this.visitId,
    this.createdAt,
  });

  final int id;
  final LeadStatus status;
  final String? reasonNote;
  final int? employeeId;
  final int? visitId;
  final DateTime? createdAt;

  factory LeadHistoryItem.fromJson(Map<String, dynamic> json) => LeadHistoryItem(
        id: json['id'] as int,
        status:
            LeadStatus.fromWire(json['status'] as String?) ?? LeadStatus.cold,
        reasonNote: json['reason_note'] as String?,
        employeeId: json['employee_id'] as int?,
        visitId: json['visit_id'] as int?,
        createdAt: _dt(json['created_at']),
      );
}

class CurrentLead {
  const CurrentLead({required this.status, this.reasonNote, this.changedAt});

  final LeadStatus status;
  final String? reasonNote;
  final DateTime? changedAt;

  factory CurrentLead.fromJson(Map<String, dynamic> json) => CurrentLead(
        status:
            LeadStatus.fromWire(json['status'] as String?) ?? LeadStatus.cold,
        reasonNote: json['reason_note'] as String?,
        changedAt: _dt(json['changed_at']),
      );
}

class FollowUp {
  const FollowUp({
    required this.id,
    this.farmerId,
    this.scheduledDate,
    this.scheduledTime,
    this.purpose,
    required this.status,
  });

  final int id;
  final int? farmerId;
  final DateTime? scheduledDate;
  final String? scheduledTime; // HH:MM:SS wire string
  final String? purpose;
  final String status;

  factory FollowUp.fromJson(Map<String, dynamic> json) => FollowUp(
        id: json['id'] as int,
        farmerId: json['farmer_id'] as int?,
        scheduledDate: _dt(json['scheduled_date']),
        scheduledTime: json['scheduled_time'] as String?,
        purpose: json['purpose'] as String?,
        status: (json['status'] as String?) ?? 'PENDING',
      );
}

/// Full farmer profile (GET /farmers/{id}).
class FarmerDetail {
  const FarmerDetail({
    required this.id,
    this.customerType = CustomerType.farmer,
    this.teamId,
    this.teamName,
    this.createdBy,
    required this.name,
    this.phone,
    this.village,
    this.district,
    this.address,
    this.pincode,
    this.landmark,
    this.lat,
    this.lng,
    this.totalCattle = 0,
    this.currentFeedBrand,
    this.currentFeedPricePerBag,
    this.notes,
    this.isActive = true,
    this.createdAt,
    this.updatedAt,
    this.currentLead,
    this.recentVisits = const [],
    this.latestLivestock,
    this.pendingFollowUps = const [],
    this.totalVisits = 0,
    this.totalOrders = 0,
    this.localId,
    this.syncStatus,
  });

  final int id;
  final CustomerType customerType;
  final int? teamId;
  final String? teamName;
  final int? createdBy;
  final String name;
  final String? phone;
  final String? village;
  final String? district;
  final String? address;
  final String? pincode;
  final String? landmark;
  final double? lat;
  final double? lng;
  final int totalCattle;
  final String? currentFeedBrand;
  final double? currentFeedPricePerBag;
  final String? notes;
  final bool isActive;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final CurrentLead? currentLead;
  final List<VisitSummary> recentVisits;
  final LivestockProfile? latestLivestock;
  final List<FollowUp> pendingFollowUps;
  final int totalVisits;
  final int totalOrders;
  /// Non-null only for a farmer created offline and not yet synced. While
  /// non-null, [id] is a placeholder — see [placeholderIdFromLocalId].
  final String? localId;
  /// Mirrors DatabaseHelper.farmerStatus* when [localId] is set.
  final int? syncStatus;

  bool get isPending => localId != null;

  /// Optimistic object returned the instant an offline create is queued —
  /// built straight from the same payload that's sitting in
  /// `pending_farmers`, before the server has ever seen it.
  factory FarmerDetail.pending({
    required String localId,
    required Map<String, dynamic> payload,
    int syncStatus = 0,
  }) =>
      FarmerDetail(
        id: placeholderIdFromLocalId(localId),
        customerType: CustomerType.fromWire(payload['customer_type'] as String?),
        name: payload['name'] as String? ?? '',
        phone: payload['phone'] as String?,
        village: payload['village'] as String?,
        district: payload['district'] as String?,
        address: payload['address'] as String?,
        pincode: payload['pincode'] as String?,
        landmark: payload['landmark'] as String?,
        totalCattle: (payload['total_cattle'] as int?) ?? 0,
        currentFeedBrand: payload['current_feed_brand'] as String?,
        notes: payload['notes'] as String?,
        isActive: true,
        localId: localId,
        syncStatus: syncStatus,
      );

  /// Wire format for POST /farmers — used both for the online create call
  /// and to build `payload_json` when queuing an offline create.
  Map<String, dynamic> toCreateJson({String? clientId}) => {
        'name': name,
        'customer_type': customerType.wire,
        if (phone != null && phone!.isNotEmpty) 'phone': phone,
        if (village != null && village!.isNotEmpty) 'village': village,
        if (district != null && district!.isNotEmpty) 'district': district,
        if (address != null && address!.isNotEmpty) 'address': address,
        if (pincode != null && pincode!.isNotEmpty) 'pincode': pincode,
        if (landmark != null && landmark!.isNotEmpty) 'landmark': landmark,
        if (notes != null && notes!.isNotEmpty) 'notes': notes,
        if (teamId != null) 'team_id': teamId,
        if (clientId != null) 'client_id': clientId,
      };

  factory FarmerDetail.fromJson(Map<String, dynamic> json) => FarmerDetail(
        id: json['id'] as int,
        customerType: CustomerType.fromWire(json['customer_type'] as String?),
        teamId: json['team_id'] as int?,
        teamName: json['team_name'] as String?,
        createdBy: json['created_by'] as int?,
        name: json['name'] as String,
        phone: json['phone'] as String?,
        village: json['village'] as String?,
        district: json['district'] as String?,
        address: json['address'] as String?,
        pincode: json['pincode'] as String?,
        landmark: json['landmark'] as String?,
        lat: _d(json['lat']),
        lng: _d(json['lng']),
        totalCattle: (json['total_cattle'] as int?) ?? 0,
        currentFeedBrand: json['current_feed_brand'] as String?,
        currentFeedPricePerBag: _d(json['current_feed_price_per_bag']),
        notes: json['notes'] as String?,
        isActive: (json['is_active'] as bool?) ?? true,
        createdAt: _dt(json['created_at']),
        updatedAt: _dt(json['updated_at']),
        currentLead: json['current_lead'] != null
            ? CurrentLead.fromJson(json['current_lead'] as Map<String, dynamic>)
            : null,
        recentVisits: ((json['recent_visits'] as List<dynamic>?) ?? [])
            .map((e) => VisitSummary.fromJson(e as Map<String, dynamic>))
            .toList(),
        latestLivestock: json['latest_livestock'] != null
            ? LivestockProfile.fromJson(
                json['latest_livestock'] as Map<String, dynamic>)
            : null,
        pendingFollowUps: ((json['pending_follow_ups'] as List<dynamic>?) ?? [])
            .map((e) => FollowUp.fromJson(e as Map<String, dynamic>))
            .toList(),
        totalVisits: (json['total_visits'] as int?) ?? 0,
        totalOrders: (json['total_orders'] as int?) ?? 0,
      );
}
