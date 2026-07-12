import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/network/api_exceptions.dart';
import '../../../core/theme/app_theme.dart' show sharedPreferencesProvider;
import '../../auth/providers/auth_provider.dart';
import '../data/attendance_repository.dart';
import '../models/attendance.dart';
import 'attendance_provider.dart';

String _ymd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// Returns true if [date] is cached as a leave day — works fully offline.
bool isLeaveDateCached(SharedPreferences prefs, DateTime date) {
  final json = prefs.getString('cached_leave_dates');
  if (json == null) return false;
  try {
    final list = jsonDecode(json) as List<dynamic>;
    return list.contains(_ymd(date));
  } catch (_) {
    return false;
  }
}

class UpcomingLeavesState {
  const UpcomingLeavesState({
    this.leaves = const [],
    this.isLoading = false,
    this.error,
    this.revokingId,
  });

  final List<Attendance> leaves;
  final bool isLoading;
  final String? error;
  final int? revokingId;

  UpcomingLeavesState copyWith({
    List<Attendance>? leaves,
    bool? isLoading,
    String? error,
    int? revokingId,
    bool clearError = false,
    bool clearRevokingId = false,
  }) =>
      UpcomingLeavesState(
        leaves: leaves ?? this.leaves,
        isLoading: isLoading ?? this.isLoading,
        error: clearError ? null : (error ?? this.error),
        revokingId: clearRevokingId ? null : (revokingId ?? this.revokingId),
      );
}

class UpcomingLeavesNotifier extends Notifier<UpcomingLeavesState> {
  @override
  UpcomingLeavesState build() {
    final auth = ref.watch(authProvider);
    if (auth.status != AuthStatus.authenticated) {
      return const UpcomingLeavesState();
    }

    Future.microtask(load);
    return const UpcomingLeavesState(isLoading: true);
  }

  AttendanceRepository get _repo => ref.read(attendanceRepositoryProvider);

  Future<void> load() async {
    state = state.copyWith(isLoading: true, clearError: true);
    final today = DateTime.now();
    final startDate = DateTime(today.year, today.month, today.day);
    final endDate = startDate.add(const Duration(days: 90));

    try {
      final res = await _repo.getHistory(
        startDate: startDate,
        endDate: endDate,
        limit: 100,
      );

      final leaves = res.items
          .where((e) => e.status == 'ON_LEAVE')
          .toList();

      // Persist leave dates so offline code can check them without a network call.
      final leaveDates = leaves.map((e) => _ymd(e.date)).toList();
      unawaited(
        ref.read(sharedPreferencesProvider).setString(
              'cached_leave_dates',
              jsonEncode(leaveDates),
            ),
      );

      state = state.copyWith(
        leaves: leaves,
        isLoading: false,
        clearError: true,
      );
    } on ApiException catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: e.message,
      );
    }
  }

  Future<void> revokeLeave(int attendanceId) async {
    state = state.copyWith(revokingId: attendanceId, clearError: true);
    try {
      await _repo.revokeLeave(attendanceId);
      
      await load();
      ref.read(attendanceProvider.notifier).load();
      
      state = state.copyWith(clearRevokingId: true, clearError: true);
    } on ApiException catch (e) {
      state = state.copyWith(
        clearRevokingId: true,
        error: e.message,
      );
    }
  }

  void clearError() => state = state.copyWith(clearError: true);
}

final upcomingLeavesProvider =
    NotifierProvider<UpcomingLeavesNotifier, UpcomingLeavesState>(
        UpcomingLeavesNotifier.new);
