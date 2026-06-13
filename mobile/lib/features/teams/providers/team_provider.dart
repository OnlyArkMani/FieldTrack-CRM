import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_exceptions.dart';
import '../data/team_repository.dart';
import '../models/team.dart';

class TeamListState {
  const TeamListState({
    this.teams = const [],
    this.isLoading = false,
    this.isRefreshing = false,
    this.error,
  });

  final List<Team> teams;
  final bool isLoading;
  final bool isRefreshing;
  final String? error;

  bool get isEmpty => teams.isEmpty && !isLoading && error == null;

  TeamListState copyWith({
    List<Team>? teams,
    bool? isLoading,
    bool? isRefreshing,
    String? error,
    bool clearError = false,
  }) =>
      TeamListState(
        teams: teams ?? this.teams,
        isLoading: isLoading ?? this.isLoading,
        isRefreshing: isRefreshing ?? this.isRefreshing,
        error: clearError ? null : (error ?? this.error),
      );
}

class TeamNotifier extends Notifier<TeamListState> {
  @override
  TeamListState build() {
    Future.microtask(load);
    return const TeamListState(isLoading: true);
  }

  TeamRepository get _repo => ref.read(teamRepositoryProvider);

  Future<void> load({bool isRefresh = false}) async {
    state = state.copyWith(
      isLoading: !isRefresh && state.teams.isEmpty,
      isRefreshing: isRefresh,
      clearError: true,
    );
    try {
      final teams = await _repo.list();
      state = state.copyWith(
        teams: teams,
        isLoading: false,
        isRefreshing: false,
      );
    } on ApiException catch (e) {
      state = state.copyWith(
        isLoading: false,
        isRefreshing: false,
        error: e.message,
      );
    }
  }

  /// Create a team and prepend it. Returns null on success, or the error
  /// message for the caller to show inline (keeps the bottom sheet open).
  Future<String?> create({
    required String name,
    String? description,
    int? supervisorId,
  }) async {
    try {
      final team = await _repo.create(
        name: name,
        description: description,
        supervisorId: supervisorId,
      );
      state = state.copyWith(teams: [team, ...state.teams]);
      return null;
    } on ApiException catch (e) {
      return e.message;
    }
  }

  Future<String?> delete(int id) async {
    try {
      await _repo.delete(id);
      state = state.copyWith(
        teams: state.teams.where((t) => t.id != id).toList(),
      );
      return null;
    } on ApiException catch (e) {
      return e.message;
    }
  }
}

final teamListProvider =
    NotifierProvider<TeamNotifier, TeamListState>(TeamNotifier.new);

final teamDetailProvider = FutureProvider.family<Team, int>((ref, id) async {
  return ref.watch(teamRepositoryProvider).detail(id);
});
