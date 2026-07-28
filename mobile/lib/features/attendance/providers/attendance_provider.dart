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
    this.isMarkingLeave = false,
    this.isNavigatingToDsr = false,
    this.error,
    this.errorNonce = 0,
  });

  final TodayAttendance today;
  final bool isLoading;
  final bool isSubmitting;

  /// Which transition is in flight (drives the per-button spinner).
  final SessionType? pendingAction;

  /// True while the leave request is in flight (drives the On Leave button
  /// spinner — leave has no SessionType, so it isn't covered by pendingAction).
  final bool isMarkingLeave;

  /// True after checkout while navigating to/showing the DSR screen.
  final bool isNavigatingToDsr;
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
    bool? isMarkingLeave,
    bool? isNavigatingToDsr,
    String? error,
    bool clearError = false,
    int? errorNonce,
  }) =>
      AttendanceUiState(
        today: today ?? this.today,
        isLoading: isLoading ?? this.isLoading,
        isSubmitting: isSubmitting ?? this.isSubmitting,
        pendingAction: clearPending ? null : (pendingAction ?? this.pendingAction),
        isMarkingLeave: isMarkingLeave ?? this.isMarkingLeave,
        isNavigatingToDsr: isNavigatingToDsr ?? this.isNavigatingToDsr,
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
  // NOT late final — build() is called again when authProvider changes (e.g.
  // logout → re-login). Riverpod runs the previous onDispose (which removes
  // the old observer) before the new build(), so a plain `late` is safe.
  late _Resumed _observer;

  @override
  AttendanceUiState build() {
    final auth = ref.watch(authProvider);
    _observer = _Resumed(_onResume);
    WidgetsBinding.instance.addObserver(_observer);
    ref.onDispose(() => WidgetsBinding.instance.removeObserver(_observer));
    if (auth.status != AuthStatus.authenticated) {
      return const AttendanceUiState(isLoading: false);
    }
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

  Future<void> reCheckIn(String remark) => _run(
        SessionType.reCheckIn,
        optimistic: () =>
            _optimisticAppend(SessionType.reCheckIn, MachineState.reCheckedIn),
        call: (lat, lng) => _repo.reCheckIn(lat, lng, remark: remark),
      );

  Future<void> end(String workSummary) => _run(
        SessionType.end,
        optimistic: () => _optimisticAppend(SessionType.end, MachineState.ended),
        call: (lat, lng) => _repo.end(lat, lng, workSummary: workSummary),
      );

  /// Mark a day as leave — today by default, or a future `date`. No GPS
  /// involved (unlike the session transitions), so this bypasses `_run` and
  /// drives its own submitting flag. The optimistic "today" state update only
  /// applies when the leave date IS today; a future-dated leave doesn't
  /// change what the app shows for today.
  Future<void> markLeave({DateTime? date}) async {
    if (state.isSubmitting || state.isMarkingLeave) return;
    final now = DateTime.now();
    final isToday = date == null ||
        (date.year == now.year && date.month == now.month && date.day == now.day);
    final snapshot = state.today;

    if (isToday) {
      final synthetic = Attendance(
        id: -1,
        userId: 0,
        date: now,
        status: AttendanceStatusValue.onLeave,
        totalDurationMinutes: 0,
        totalDistanceMeters: 0,
        currentState: MachineState.onLeave,
        sessions: const [],
      );
      state = state.copyWith(
        today: TodayAttendance(
          hasAttendance: true,
          currentState: MachineState.onLeave,
          attendance: synthetic,
        ),
        isMarkingLeave: true,
        clearError: true,
      );
    } else {
      state = state.copyWith(isMarkingLeave: true, clearError: true);
    }

    try {
      final updated = await _repo.markLeave(date: date);
      if (isToday) {
        final newToday = TodayAttendance(
          hasAttendance: true,
          currentState: updated.currentState,
          attendance: updated,
        );
        state = state.copyWith(
          today: newToday,
          isMarkingLeave: false,
          clearError: true,
        );
      } else {
        state = state.copyWith(isMarkingLeave: false, clearError: true);
      }
      unawaited(HapticFeedback.lightImpact());
    } on ApiException catch (e) {
      unawaited(HapticFeedback.lightImpact());
      state = state.copyWith(
        today: snapshot,
        isMarkingLeave: false,
        error: e.message,
        errorNonce: state.errorNonce + 1,
      );
    }
  }

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
    } on ConflictException {
      // Server rejected because state already exists (e.g. the sync engine
      // uploaded an offline session before the user tapped Start). Re-fetch
      // the real server state and show it — never treat this as a user error.
      state = state.copyWith(isSubmitting: false, clearPending: true, clearError: true);
      await load(silent: true);
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

  void setNavigatingToDsr(bool value) =>
      state = state.copyWith(isNavigatingToDsr: value);

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
    } catch (e) {
      // Was a bare `catch (_)` — swallowed the real cause (e.g. OEM battery/
      // Doze throttling killing the fix a few seconds in) behind one generic
      // message, making field reports impossible to root-cause. Logged, not
      // surfaced to the user — the message below stays the same.
      debugPrint('Attendance GPS fetch failed (${e.runtimeType}): $e');
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
