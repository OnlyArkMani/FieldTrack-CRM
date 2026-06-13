import 'package:flutter/material.dart';

/// One tap in the state machine.
enum SessionType {
  start('START'),
  breakk('BREAK'), // 'break' is a Dart keyword
  resume('RESUME'),
  end('END');

  const SessionType(this.wire);
  final String wire;

  static SessionType fromWire(String v) =>
      SessionType.values.firstWhere((t) => t.wire == v,
          orElse: () => SessionType.start);

  IconData get icon => switch (this) {
        SessionType.start => Icons.play_circle_fill_rounded,
        SessionType.breakk => Icons.pause_circle_filled_rounded,
        SessionType.resume => Icons.refresh_rounded,
        SessionType.end => Icons.stop_circle_rounded,
      };

  String get label => switch (this) {
        SessionType.start => 'Started',
        SessionType.breakk => 'Break',
        SessionType.resume => 'Resumed',
        SessionType.end => 'Ended',
      };
}

/// Live machine position (mirrors backend current_state).
enum MachineState {
  none('NULL'),
  started('STARTED'),
  onBreak('ON_BREAK'),
  resumed('RESUMED'),
  ended('ENDED');

  const MachineState(this.wire);
  final String wire;

  static MachineState fromWire(String? v) => MachineState.values.firstWhere(
        (s) => s.wire == v,
        orElse: () => MachineState.none,
      );

  bool get isWorking => this == MachineState.started || this == MachineState.resumed;
  bool get isOnBreak => this == MachineState.onBreak;
  bool get isEnded => this == MachineState.ended;
  bool get notStarted => this == MachineState.none;
}

class AttendanceStatusValue {
  // Day classification (present/absent/half_day).
  static const present = 'PRESENT';
  static const absent = 'ABSENT';
  static const halfDay = 'HALF_DAY';
}

class AttendanceSession {
  const AttendanceSession({
    required this.id,
    required this.type,
    required this.timestamp,
    this.lat,
    this.lng,
    this.notes,
  });

  final int id;
  final SessionType type;
  final DateTime timestamp;
  final double? lat;
  final double? lng;
  final String? notes;

  factory AttendanceSession.fromJson(Map<String, dynamic> json) =>
      AttendanceSession(
        id: json['id'] as int,
        type: SessionType.fromWire(json['type'] as String),
        timestamp: DateTime.parse(json['timestamp'] as String),
        lat: (json['lat'] as num?)?.toDouble(),
        lng: (json['lng'] as num?)?.toDouble(),
        notes: json['notes'] as String?,
      );
}

class AttendanceEmployeeRef {
  const AttendanceEmployeeRef({
    required this.id,
    required this.name,
    this.profilePhotoUrl,
    this.role,
  });

  final int id;
  final String name;
  final String? profilePhotoUrl;
  final String? role;

  factory AttendanceEmployeeRef.fromJson(Map<String, dynamic> json) =>
      AttendanceEmployeeRef(
        id: json['id'] as int,
        name: json['name'] as String,
        profilePhotoUrl: json['profile_photo_url'] as String?,
        role: json['role'] as String?,
      );
}

class Attendance {
  const Attendance({
    required this.id,
    required this.userId,
    required this.date,
    required this.status,
    required this.totalDurationMinutes,
    required this.totalDistanceMeters,
    required this.currentState,
    required this.sessions,
    this.workSummary,
    this.employee,
  });

  final int id;
  final int userId;
  final DateTime date;
  final String status;
  final int totalDurationMinutes;
  final double totalDistanceMeters;
  final MachineState currentState;
  final List<AttendanceSession> sessions;
  final String? workSummary;
  final AttendanceEmployeeRef? employee;

  /// Timestamp of the first START today — the timer's origin.
  DateTime? get startedAt {
    for (final s in sessions) {
      if (s.type == SessionType.start) return s.timestamp;
    }
    return null;
  }

  /// Timestamp the current break began (for the on-break duration display).
  DateTime? get breakStartedAt {
    if (currentState != MachineState.onBreak) return null;
    for (final s in sessions.reversed) {
      if (s.type == SessionType.breakk) return s.timestamp;
    }
    return null;
  }

  factory Attendance.fromJson(Map<String, dynamic> json) => Attendance(
        id: json['id'] as int,
        userId: json['user_id'] as int,
        date: DateTime.parse(json['date'] as String),
        status: json['status'] as String,
        totalDurationMinutes: (json['total_duration_minutes'] as int?) ?? 0,
        totalDistanceMeters:
            ((json['total_distance_meters'] as num?) ?? 0).toDouble(),
        currentState: MachineState.fromWire(json['current_state'] as String?),
        workSummary: json['work_summary'] as String?,
        sessions: ((json['sessions'] as List<dynamic>?) ?? [])
            .map((e) => AttendanceSession.fromJson(e as Map<String, dynamic>))
            .toList(),
        employee: json['employee'] != null
            ? AttendanceEmployeeRef.fromJson(
                json['employee'] as Map<String, dynamic>)
            : null,
      );
}

/// GET /attendance/today envelope.
class TodayAttendance {
  const TodayAttendance({
    required this.hasAttendance,
    required this.currentState,
    this.attendance,
  });

  final bool hasAttendance;
  final MachineState currentState;
  final Attendance? attendance;

  factory TodayAttendance.fromJson(Map<String, dynamic> json) => TodayAttendance(
        hasAttendance: (json['has_attendance'] as bool?) ?? false,
        currentState: MachineState.fromWire(json['current_state'] as String?),
        attendance: json['attendance'] != null
            ? Attendance.fromJson(json['attendance'] as Map<String, dynamic>)
            : null,
      );

  static const empty =
      TodayAttendance(hasAttendance: false, currentState: MachineState.none);
}
