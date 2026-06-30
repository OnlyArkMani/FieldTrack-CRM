/// Follow-up models — mirror app/schemas/crm.py (FollowUpListItem).
library;

class FollowUpItem {
  const FollowUpItem({
    required this.id,
    this.farmerId,
    this.farmerName,
    this.employeeId,
    this.employeeName,
    required this.scheduledDate,
    this.scheduledTime,
    this.purpose,
    required this.status,
    this.reminderSent24h = false,
    this.reminderSent1h = false,
  });

  final int id;
  final int? farmerId;
  final String? farmerName;
  final int? employeeId;
  final String? employeeName;
  final DateTime scheduledDate;
  final String? scheduledTime; // "HH:MM:SS"
  final String? purpose;
  final String status; // PENDING / ACKNOWLEDGED / COMPLETED / ESCALATED
  final bool reminderSent24h;
  final bool reminderSent1h;

  String? get timeLabel => (scheduledTime != null && scheduledTime!.length >= 5)
      ? scheduledTime!.substring(0, 5)
      : null;

  /// Pending and past its scheduled moment.
  bool get isOverdue {
    if (status == 'COMPLETED') return false;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    if (scheduledDate.isBefore(today)) return status != 'ACKNOWLEDGED';
    if (scheduledDate.isAtSameMomentAs(today) && timeLabel != null) {
      final parts = timeLabel!.split(':');
      final due = DateTime(today.year, today.month, today.day,
          int.tryParse(parts[0]) ?? 0, int.tryParse(parts[1]) ?? 0);
      return now.isAfter(due) && status == 'PENDING';
    }
    return false;
  }

  factory FollowUpItem.fromJson(Map<String, dynamic> json) => FollowUpItem(
        id: json['id'] as int,
        farmerId: json['farmer_id'] as int?,
        farmerName: json['farmer_name'] as String?,
        employeeId: json['employee_id'] as int?,
        employeeName: json['employee_name'] as String?,
        scheduledDate: DateTime.parse(json['scheduled_date'] as String),
        scheduledTime: json['scheduled_time'] as String?,
        purpose: json['purpose'] as String?,
        status: (json['status'] as String?) ?? 'PENDING',
        reminderSent24h: (json['reminder_sent_24h'] as bool?) ?? false,
        reminderSent1h: (json['reminder_sent_1h'] as bool?) ?? false,
      );
}
