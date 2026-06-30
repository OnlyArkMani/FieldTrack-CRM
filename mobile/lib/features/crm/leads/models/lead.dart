/// Lead-management models — mirror app/schemas/crm.py (LeadListItem). Reuses the
/// farmers feature's LeadStatus.
library;

import '../../farmers/models/farmer.dart' show LeadStatus;

DateTime? _dt(dynamic v) =>
    v == null ? null : DateTime.tryParse(v as String)?.toLocal();

class LeadItem {
  const LeadItem({
    required this.farmerId,
    required this.farmerName,
    this.village,
    required this.status,
    this.lastVisitAt,
    this.followUpDate,
    this.followUpTime,
    this.reasonNote,
    this.employeeId,
    this.employeeName,
  });

  final int farmerId;
  final String farmerName;
  final String? village;
  final LeadStatus status;
  final DateTime? lastVisitAt;
  final DateTime? followUpDate;
  final String? followUpTime; // "HH:MM:SS"
  final String? reasonNote;
  final int? employeeId;
  final String? employeeName;

  String? get followUpTimeLabel =>
      (followUpTime != null && followUpTime!.length >= 5)
          ? followUpTime!.substring(0, 5)
          : null;

  /// Follow-up is due within the next 3 days (inclusive of today).
  bool get followUpSoon {
    if (followUpDate == null) return false;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final diff = followUpDate!.difference(today).inDays;
    return diff >= 0 && diff <= 3;
  }

  factory LeadItem.fromJson(Map<String, dynamic> json) => LeadItem(
        farmerId: json['farmer_id'] as int,
        farmerName: (json['farmer_name'] as String?) ?? 'Unknown',
        village: json['village'] as String?,
        status:
            LeadStatus.fromWire(json['lead_status'] as String?) ?? LeadStatus.cold,
        lastVisitAt: _dt(json['last_visit_at']),
        followUpDate: _dt(json['follow_up_date']),
        followUpTime: json['follow_up_time'] as String?,
        reasonNote: json['reason_note'] as String?,
        employeeId: json['employee_id'] as int?,
        employeeName: json['employee_name'] as String?,
      );
}
