import '../../../core/widgets/status_badge.dart';
import '../../auth/models/user.dart' show UserRole;

/// Live status block — Redis-derived on the server, present on both list rows
/// and the detail view. Maps to the StatusBadge's EmployeeStatus for the UI.
enum LiveStatusValue {
  active('ACTIVE'),
  idle('IDLE'),
  offline('OFFLINE');

  const LiveStatusValue(this.wire);
  final String wire;

  static LiveStatusValue fromWire(String? v) => LiveStatusValue.values.firstWhere(
        (s) => s.wire == v,
        orElse: () => LiveStatusValue.offline,
      );
}

enum AttendancePhase {
  started('STARTED'),
  onBreak('ON_BREAK'),
  ended('ENDED'),
  none('NULL');

  const AttendancePhase(this.wire);
  final String wire;

  static AttendancePhase fromWire(String? v) => AttendancePhase.values.firstWhere(
        (s) => s.wire == v,
        orElse: () => AttendancePhase.none,
      );

  String get label => switch (this) {
        AttendancePhase.started => 'Working',
        AttendancePhase.onBreak => 'On break',
        AttendancePhase.ended => 'Shift ended',
        AttendancePhase.none => 'Not started',
      };
}

class LiveStatus {
  const LiveStatus({
    required this.value,
    required this.currentState,
    this.lastSeen,
    this.batteryLevel,
    this.isMockGps = false,
  });

  final LiveStatusValue value;
  final AttendancePhase currentState;
  final DateTime? lastSeen;
  final int? batteryLevel;
  final bool isMockGps;

  factory LiveStatus.fromJson(Map<String, dynamic> json) => LiveStatus(
        value: LiveStatusValue.fromWire(json['live_status'] as String?),
        currentState: AttendancePhase.fromWire(json['current_state'] as String?),
        lastSeen: json['last_seen'] != null
            ? DateTime.tryParse(json['last_seen'] as String)
            : null,
        batteryLevel: json['battery_level'] as int?,
        isMockGps: (json['is_mock_gps'] as bool?) ?? false,
      );

  /// Display status for the dot/badge. Layers GPS + battery signals on top of
  /// the coarse live value (richer than the 3-value server enum):
  ///   mock GPS  -> GPS Disabled (red)   [highest priority alert]
  ///   low batt  -> Low Battery (amber-orange) when not offline
  ///   else      -> active / idle / offline
  EmployeeStatus get displayStatus {
    if (value == LiveStatusValue.offline) return EmployeeStatus.offline;
    if (isMockGps) return EmployeeStatus.gpsDisabled;
    if (batteryLevel != null && batteryLevel! <= 15) {
      return EmployeeStatus.lowBattery;
    }
    return value == LiveStatusValue.active
        ? EmployeeStatus.active
        : EmployeeStatus.idle;
  }
}

class TeamRef {
  const TeamRef({required this.id, required this.name});
  final int id;
  final String name;

  factory TeamRef.fromJson(Map<String, dynamic> json) =>
      TeamRef(id: json['id'] as int, name: json['name'] as String);
}

/// List-row + detail employee. `team` and a non-null `live` are only populated
/// on the detail endpoint; on list rows `live` may be present but `team` null.
class Employee {
  const Employee({
    required this.id,
    required this.name,
    required this.email,
    required this.role,
    required this.isActive,
    this.phone,
    this.teamId,
    this.profilePhotoUrl,
    this.createdAt,
    this.team,
    this.live,
  });

  final int id;
  final String name;
  final String email;
  final UserRole role;
  final bool isActive;
  final String? phone;
  final int? teamId;
  final String? profilePhotoUrl;
  final DateTime? createdAt;
  final TeamRef? team;
  final LiveStatus? live;

  EmployeeStatus get status =>
      live?.displayStatus ?? EmployeeStatus.offline;

  /// Initials fallback for the avatar (no photo): first letters of up to two
  /// name parts.
  String get initials {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty);
    if (parts.isEmpty) return '?';
    final letters = parts.take(2).map((p) => p[0].toUpperCase()).join();
    return letters.isEmpty ? '?' : letters;
  }

  factory Employee.fromJson(Map<String, dynamic> json) => Employee(
        id: json['id'] as int,
        name: json['name'] as String,
        email: json['email'] as String,
        role: UserRole.fromWire(json['role'] as String),
        isActive: (json['is_active'] as bool?) ?? true,
        phone: json['phone'] as String?,
        teamId: json['team_id'] as int?,
        profilePhotoUrl: json['profile_photo_url'] as String?,
        createdAt: json['created_at'] != null
            ? DateTime.tryParse(json['created_at'] as String)
            : null,
        team: json['team'] != null
            ? TeamRef.fromJson(json['team'] as Map<String, dynamic>)
            : null,
        live: json['live'] != null
            ? LiveStatus.fromJson(json['live'] as Map<String, dynamic>)
            : null,
      );
}

/// One paginated page of employees (mirrors the backend CursorPage envelope).
class EmployeePage {
  const EmployeePage({
    required this.items,
    required this.total,
    required this.hasMore,
    this.nextCursor,
  });

  final List<Employee> items;
  final int total;
  final bool hasMore;
  final String? nextCursor;

  factory EmployeePage.fromJson(Map<String, dynamic> json) => EmployeePage(
        items: (json['items'] as List<dynamic>)
            .map((e) => Employee.fromJson(e as Map<String, dynamic>))
            .toList(),
        total: (json['total'] as int?) ?? 0,
        hasMore: (json['has_more'] as bool?) ?? false,
        nextCursor: json['next_cursor'] as String?,
      );
}

// ── Attendance summary ──────────────────────────────────────────────────
class AttendanceDay {
  const AttendanceDay({
    required this.date,
    required this.status,
    required this.durationMinutes,
    required this.distanceMeters,
  });

  final DateTime date;
  final String status;
  final int durationMinutes;
  final double distanceMeters;

  factory AttendanceDay.fromJson(Map<String, dynamic> json) => AttendanceDay(
        date: DateTime.parse(json['date'] as String),
        status: json['status'] as String,
        durationMinutes: (json['total_duration_minutes'] as int?) ?? 0,
        distanceMeters: ((json['total_distance_meters'] as num?) ?? 0).toDouble(),
      );
}

class AttendanceSummary {
  const AttendanceSummary({
    required this.year,
    required this.month,
    required this.daysPresent,
    required this.daysHalf,
    required this.daysAbsent,
    required this.totalWorkMinutes,
    required this.avgWorkMinutes,
    required this.totalDistanceMeters,
    required this.days,
  });

  final int year;
  final int month;
  final int daysPresent;
  final int daysHalf;
  final int daysAbsent;
  final int totalWorkMinutes;
  final int avgWorkMinutes;
  final double totalDistanceMeters;
  final List<AttendanceDay> days;

  factory AttendanceSummary.fromJson(Map<String, dynamic> json) =>
      AttendanceSummary(
        year: json['year'] as int,
        month: json['month'] as int,
        daysPresent: (json['days_present'] as int?) ?? 0,
        daysHalf: (json['days_half'] as int?) ?? 0,
        daysAbsent: (json['days_absent'] as int?) ?? 0,
        totalWorkMinutes: (json['total_work_minutes'] as int?) ?? 0,
        avgWorkMinutes: (json['avg_work_minutes'] as int?) ?? 0,
        totalDistanceMeters:
            ((json['total_distance_meters'] as num?) ?? 0).toDouble(),
        days: ((json['days'] as List<dynamic>?) ?? [])
            .map((e) => AttendanceDay.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

// ── Location history ────────────────────────────────────────────────────
class LocationPoint {
  const LocationPoint({
    required this.lat,
    required this.lng,
    required this.timestamp,
    this.accuracy,
    this.speed,
    this.batteryLevel,
    this.isMockGps = false,
  });

  final double lat;
  final double lng;
  final DateTime timestamp;
  final double? accuracy;
  final double? speed;
  final int? batteryLevel;
  final bool isMockGps;

  factory LocationPoint.fromJson(Map<String, dynamic> json) => LocationPoint(
        lat: (json['lat'] as num).toDouble(),
        lng: (json['lng'] as num).toDouble(),
        timestamp: DateTime.parse(json['timestamp'] as String),
        accuracy: (json['accuracy'] as num?)?.toDouble(),
        speed: (json['speed'] as num?)?.toDouble(),
        batteryLevel: json['battery_level'] as int?,
        isMockGps: (json['is_mock_gps'] as bool?) ?? false,
      );
}
