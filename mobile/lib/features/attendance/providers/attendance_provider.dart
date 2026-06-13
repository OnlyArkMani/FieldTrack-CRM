import 'dart:async';

import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/network/api_exceptions.dart';
import '../../../services/location/location_service.dart';
import '../../../services/map/tile_cache_service.dart';
import '../../auth/providers/auth_provider.dart';
import '../data/attendance_repository.dart';
import '../models/attendance.dart';

/// UI state for the attendance screen. `errorNonce` increments on each error
/// so the screen can fire its shake animation even on repeat errors.
class AttendanceUiState {
  const AttendanceUiState({
    this.today = TodayAttendance.empty,
    this.isLoading = true,
    this.isSubmitting = false,
    this.pendingAction,
    this.error,
    this.errorNonce = 0,
  });

  final TodayAttendance today;
  final bool isLoading;
  final bool isSubmitting;

  /// Which transition is in flight (drives the per-button spinner).
  final SessionType? pendingAction;
  final String? error;
  final int errorNonce;

  MachineState get state => today.currentState;
  Attendance? get attendance => today.attendance;

  AttendanceUiState copyWith({
    TodayAttendance? today,
    bool? isLoading,
    bool? isSubmitting,
    SessionType? pendingAction,
    bool clearPending = false,
    String? error,
    bool clearError = false,
    int? errorNonce,
  }) =>
      AttendanceUiState(
        today: today ?? this.today,
        isLoading: isLoading ?? this.isLoading,
        isSubmitting: isSubmitting ?? this.isSubmitting,
        pendingAction: clearPending ? null : (pendingAction ?? this.pendingAction),
        error: clearError ? null : (error ?? this.error),
        errorNonce: errorNonce ?? this.errorNonce,
      );
}

/// Bridges app lifecycle → a callback, so the notifier can rehydrate on resume
/// without the notifier itself being a WidgetsBindingObserver.
class _Resumed with WidgetsBindingObserver {
  _Resumed(this.onResume);
  final VoidCallback onResume;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) onResume();
  }
}

class AttendanceNotifier extends Notifier<AttendanceUiState> {
  late final _Resumed _observer;

  @override
  AttendanceUiState build() {
    _observer = _Resumed(_onResume);
    WidgetsBinding.instance.addObserver(_observer);
    ref.onDispose(() => WidgetsBinding.instance.removeObserver(_observer));
    Future.microtask(load);
    return const AttendanceUiState();
  }

  AttendanceRepository get _repo => ref.read(attendanceRepositoryProvider);

  void _onResume() {
    // Don't stomp an in-flight transition; otherwise refresh silently.
    if (!state.isSubmitting) load(silent: true);
  }

  Future<void> load({bool silent = false}) async {
    if (!silent) state = state.copyWith(isLoading: true, clearError: true);
    try {
      final today = await _repo.today();
      state = state.copyWith(today: today, isLoading: false, clearError: true);
      await _syncTracking(today);
    } on ApiException catch (e) {
      state = state.copyWith(isLoading: false, error: e.message);
    }
  }

  /// Converge background GPS to the authoritative server state. Runs on every
  /// load/rehydrate, so a force-killed app or a reboot self-heals: if the
  /// server says STARTED but the service is dead, it restarts (and vice versa).
  Future<void> _syncTracking(TodayAttendance today) async {
    final userId =
        today.attendance?.userId ?? ref.read(authProvider).user?.id;
    if (userId == null) return;
    try {
      await LocationService.instance.syncWithAttendance(
        userId: userId,
        state: today.currentState,
        attendanceId: today.attendance?.id,
      );
    } catch (_) {
      // Tracking failures must never break the attendance UI; the next
      // load()/resume retries convergence.
    }
  }

  // ── Transitions (optimistic) ─────────────────────────────────────────
  Future<void> start() => _run(
        SessionType.start,
        optimistic: _optimisticStart,
        call: (lat, lng) => _repo.start(lat, lng),
      );

  Future<void> takeBreak() => _run(
        SessionType.breakk,
        optimistic: () => _optimisticAppend(SessionType.breakk, MachineState.onBreak),
        call: (lat, lng) => _repo.breakk(lat, lng),
      );

  Future<void> resume() => _run(
        SessionType.resume,
        optimistic: () => _optimisticAppend(SessionType.resume, MachineState.resumed),
        call: (lat, lng) => _repo.resume(lat, lng),
      );

  Future<void> end(String workSummary) => _run(
        SessionType.end,
        optimistic: () => _optimisticAppend(SessionType.end, MachineState.ended),
        call: (lat, lng) => _repo.end(lat, lng, workSummary: workSummary),
      );

  /// Shared transition runner: snapshot → optimistic paint → GPS → API →
  /// reconcile or roll back.
  Future<void> _run(
    SessionType action, {
    required TodayAttendance? Function() optimistic,
    required Future<Attendance> Function(double lat, double lng) call,
  }) async {
    if (state.isSubmitting) return;
    final snapshot = state.today;

    final predicted = optimistic();
    state = state.copyWith(
      today: predicted ?? snapshot,
      isSubmitting: true,
      pendingAction: action,
      clearError: true,
    );

    try {
      final (lat, lng) = await _currentPosition();
      final updated = await call(lat, lng);
      final newToday = TodayAttendance(
        hasAttendance: true,
        currentState: updated.currentState,
        attendance: updated,
      );
      state = state.copyWith(
        today: newToday,
        isSubmitting: false,
        clearPending: true,
      );
      await _syncTracking(newToday);
      // Confirm the state transition landed — a light tap per START/BREAK/
      // RESUME/END, mirroring the haptic on physical attendance terminals.
      unawaited(HapticFeedback.lightImpact());
      // On START, warm the offline tile cache around the clock-in location so
      // the map works without signal in the field (best-effort, fire-and-forget).
      if (action == SessionType.start) {
        unawaited(TileCacheService.instance
            .preCacheRegion(LatLng(lat, lng), 5));
      }
    } on _LocationException catch (e) {
      _rollback(snapshot, e.message);
    } on ApiException catch (e) {
      _rollback(snapshot, e.message);
    }
  }

  void _rollback(TodayAttendance snapshot, String message) {
    unawaited(HapticFeedback.lightImpact());
    state = state.copyWith(
      today: snapshot,
      isSubmitting: false,
      clearPending: true,
      error: message,
      errorNonce: state.errorNonce + 1,
    );
  }

  // ── Optimistic state builders ────────────────────────────────────────
  TodayAttendance? _optimisticStart() {
    final now = DateTime.now();
    final synthetic = Attendance(
      id: -1,
      userId: 0,
      date: now,
      status: AttendanceStatusValue.present,
      totalDurationMinutes: 0,
      totalDistanceMeters: 0,
      currentState: MachineState.started,
      sessions: [
        AttendanceSession(id: -1, type: SessionType.start, timestamp: now),
      ],
    );
    return TodayAttendance(
      hasAttendance: true,
      currentState: MachineState.started,
      attendance: synthetic,
    );
  }

  TodayAttendance? _optimisticAppend(SessionType type, MachineState next) {
    final current = state.attendance;
    if (current == null) return null;
    final now = DateTime.now();
    final sessions = [
      ...current.sessions,
      AttendanceSession(id: -1, type: type, timestamp: now),
    ];
    final updated = Attendance(
      id: current.id,
      userId: current.userId,
      date: current.date,
      status: current.status,
      totalDurationMinutes: current.totalDurationMinutes,
      totalDistanceMeters: current.totalDistanceMeters,
      currentState: next,
      sessions: sessions,
      workSummary: current.workSummary,
    );
    return TodayAttendance(
      hasAttendance: true,
      currentState: next,
      attendance: updated,
    );
  }

  void clearError() => state = state.copyWith(clearError: true);

  // ── GPS acquisition (mandatory per transition) ───────────────────────
  Future<(double, double)> _currentPosition() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw const _LocationException(
          'Location services are off. Enable GPS to mark attendance.');
    }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      throw const _LocationException(
          'Location permission is required to mark attendance.');
    }
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 12),
        ),
      );
      return (pos.latitude, pos.longitude);
    } catch (_) {
      throw const _LocationException(
          'Could not get your location. Move to open sky and retry.');
    }
  }
}

class _LocationException implements Exception {
  const _LocationException(this.message);
  final String message;
}

final attendanceProvider =
    NotifierProvider<AttendanceNotifier, AttendanceUiState>(
        AttendanceNotifier.new);
