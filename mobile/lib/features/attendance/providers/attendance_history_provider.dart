import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_exceptions.dart';
import '../../auth/providers/auth_provider.dart';
import '../data/attendance_repository.dart';
import '../models/attendance.dart';

enum HistoryFilterType {
  week('1 Week'),
  month('1 Month'),
  sixMonths('6 Months'),
  custom('Custom');

  const HistoryFilterType(this.label);
  final String label;
}

class AttendanceHistoryState {
  const AttendanceHistoryState({
    this.filterType = HistoryFilterType.week,
    this.startDate,
    this.endDate,
    this.entries = const [],
    this.isLoading = false,
    this.error,
  });

  final HistoryFilterType filterType;
  final DateTime? startDate;
  final DateTime? endDate;
  final List<Attendance> entries;
  final bool isLoading;
  final String? error;

  AttendanceHistoryState copyWith({
    HistoryFilterType? filterType,
    DateTime? startDate,
    DateTime? endDate,
    List<Attendance>? entries,
    bool? isLoading,
    String? error,
    bool clearError = false,
  }) =>
      AttendanceHistoryState(
        filterType: filterType ?? this.filterType,
        startDate: startDate ?? this.startDate,
        endDate: endDate ?? this.endDate,
        entries: entries ?? this.entries,
        isLoading: isLoading ?? this.isLoading,
        error: clearError ? null : (error ?? this.error),
      );
}

class AttendanceHistoryNotifier extends Notifier<AttendanceHistoryState> {
  @override
  AttendanceHistoryState build() {
    final auth = ref.watch(authProvider);
    if (auth.status != AuthStatus.authenticated) {
      return const AttendanceHistoryState();
    }

    final today = DateTime.now();
    final start = today.subtract(const Duration(days: 7));

    Future.microtask(load);

    return AttendanceHistoryState(
      filterType: HistoryFilterType.week,
      startDate: start,
      endDate: today,
    );
  }

  AttendanceRepository get _repo => ref.read(attendanceRepositoryProvider);

  Future<void> load({bool silent = false}) async {
    final current = state;
    DateTime? start = current.startDate;
    DateTime? end = current.endDate;

    final today = DateTime.now();

    // Recalculate date range if not custom filter
    if (current.filterType != HistoryFilterType.custom) {
      end = today;
      switch (current.filterType) {
        case HistoryFilterType.week:
          start = today.subtract(const Duration(days: 7));
          break;
        case HistoryFilterType.month:
          start = today.subtract(const Duration(days: 30));
          break;
        case HistoryFilterType.sixMonths:
          start = today.subtract(const Duration(days: 180));
          break;
        case HistoryFilterType.custom:
          break;
      }
    }

    if (start == null || end == null) return;

    if (!silent) {
      state = current.copyWith(
        isLoading: true,
        startDate: start,
        endDate: end,
        clearError: true,
      );
    }

    try {
      final fetched = await _repo.getHistory(startDate: start, endDate: end);
      
      // Filter out current day (today) history logs as they are shown in the main UI
      final filtered = fetched.where((e) {
        return !(e.date.year == today.year &&
            e.date.month == today.month &&
            e.date.day == today.day);
      }).toList();

      state = state.copyWith(
        entries: filtered,
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

  void setFilter(HistoryFilterType type) {
    if (type == HistoryFilterType.custom) {
      // Don't fetch automatically; wait for custom date range picker
      state = state.copyWith(filterType: type);
      return;
    }
    state = state.copyWith(filterType: type);
    load();
  }

  void setCustomRange(DateTime start, DateTime end) {
    state = state.copyWith(
      filterType: HistoryFilterType.custom,
      startDate: start,
      endDate: end,
    );
    load();
  }

  void clearError() => state = state.copyWith(clearError: true);
}

final attendanceHistoryProvider =
    NotifierProvider<AttendanceHistoryNotifier, AttendanceHistoryState>(
        AttendanceHistoryNotifier.new);
