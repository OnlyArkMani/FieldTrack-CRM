/// Vet-request models — mirror app/schemas/crm.py VetRequestItem.
library;

import '../../farmers/models/farmer.dart' show CustomerType;

DateTime? _dt(dynamic v) =>
    v == null ? null : DateTime.tryParse(v as String)?.toLocal();

class VetRequest {
  const VetRequest({
    required this.visitId,
    this.farmerId,
    required this.farmerName,
    this.customerType = CustomerType.farmer,
    this.village,
    this.phone,
    this.employeeId,
    this.employeeName,
    this.teamName,
    this.visitDate,
    this.vetCattleCount,
    this.vetNotes,
    this.vetStatus = 'REQUESTED',
  });

  final int visitId;
  final int? farmerId;
  final String farmerName;
  final CustomerType customerType;
  final String? village;
  final String? phone;
  final int? employeeId;
  final String? employeeName;
  final String? teamName;
  final DateTime? visitDate;
  final int? vetCattleCount;
  final String? vetNotes;
  final String vetStatus;

  factory VetRequest.fromJson(Map<String, dynamic> json) => VetRequest(
        visitId: json['visit_id'] as int,
        farmerId: json['farmer_id'] as int?,
        farmerName: (json['farmer_name'] as String?) ?? 'Unknown',
        customerType: CustomerType.fromWire(json['customer_type'] as String?),
        village: json['village'] as String?,
        phone: json['phone'] as String?,
        employeeId: json['employee_id'] as int?,
        employeeName: json['employee_name'] as String?,
        teamName: json['team_name'] as String?,
        visitDate: _dt(json['visit_date']),
        vetCattleCount: json['vet_cattle_count'] as int?,
        vetNotes: json['vet_notes'] as String?,
        vetStatus: (json['vet_status'] as String?) ?? 'REQUESTED',
      );
}
