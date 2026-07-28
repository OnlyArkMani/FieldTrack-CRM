import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_exceptions.dart';
import '../data/report_repository.dart';
import '../models/report_preview_models.dart';
import 'report_provider.dart';

class ReportPreviewState {
  const ReportPreviewState({
    this.isLoading = false,
    this.error,
    this.data,
  });

  final bool isLoading;
  final String? error;
  final ReportTableData? data;

  ReportPreviewState copyWith({
    bool? isLoading,
    String? error,
    bool clearError = false,
    ReportTableData? data,
  }) {
    return ReportPreviewState(
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
      data: data ?? this.data,
    );
  }
}

class ReportPreviewNotifier extends Notifier<ReportPreviewState> {
  int _requestId = 0;

  @override
  ReportPreviewState build() {
    // Watch reportProvider to auto-trigger preview load when filters change.
    final reportState = ref.watch(reportProvider);
    
    // Schedule asynchronous load after build frame
    Future.microtask(() => loadPreview(reportState));
    
    return const ReportPreviewState(isLoading: true);
  }

  Future<void> loadPreview(ReportUiState reportState) async {
    final requestId = ++_requestId;
    state = state.copyWith(isLoading: true, clearError: true);

    try {
      final repo = ref.read(reportRepositoryProvider);
      final data = await repo.fetchPreviewData(
        type: reportState.type,
        range: reportState.range,
        month: reportState.month,
        teamId: reportState.teamId,
      );

      if (_requestId != requestId) return;
      state = state.copyWith(
        isLoading: false,
        data: data,
        clearError: true,
      );
    } on ApiException catch (e) {
      if (_requestId != requestId) return;
      state = state.copyWith(
        isLoading: false,
        error: e.message,
      );
    } catch (e) {
      if (_requestId != requestId) return;
      state = state.copyWith(
        isLoading: false,
        error: e.toString(),
      );
    }
  }
}

final reportPreviewProvider =
    NotifierProvider<ReportPreviewNotifier, ReportPreviewState>(
        ReportPreviewNotifier.new);
