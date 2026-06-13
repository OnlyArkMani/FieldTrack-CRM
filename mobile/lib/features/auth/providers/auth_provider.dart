import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_exceptions.dart';
import '../data/auth_repository.dart';
import '../models/user.dart';

enum AuthStatus { unknown, authenticated, unauthenticated }

class AuthState {
  const AuthState({
    this.status = AuthStatus.unknown,
    this.user,
    this.isLoading = false,
    this.error,
  });

  final AuthStatus status;
  final User? user;
  final bool isLoading;
  final String? error;

  AuthState copyWith({
    AuthStatus? status,
    User? user,
    bool? isLoading,
    String? error,
    bool clearError = false,
    bool clearUser = false,
  }) =>
      AuthState(
        status: status ?? this.status,
        user: clearUser ? null : (user ?? this.user),
        isLoading: isLoading ?? this.isLoading,
        error: clearError ? null : (error ?? this.error),
      );
}

class AuthNotifier extends Notifier<AuthState> {
  @override
  AuthState build() {
    // Session revoked by the network layer (refresh failed / second 401):
    // flip to unauthenticated — router redirects to /login automatically.
    ref.listen(sessionRevokedProvider, (prev, next) {
      if (prev != null && next != prev) {
        state = const AuthState(status: AuthStatus.unauthenticated);
      }
    });

    Future.microtask(restoreSession);
    return const AuthState(status: AuthStatus.unknown);
  }

  AuthRepository get _repo => ref.read(authRepositoryProvider);

  /// Called once at startup (splash). Stored refresh token => try /auth/me.
  Future<void> restoreSession() async {
    if (!_repo.hasStoredSession) {
      state = const AuthState(status: AuthStatus.unauthenticated);
      return;
    }
    try {
      final user = await _repo.me();
      state = AuthState(status: AuthStatus.authenticated, user: user);
    } on ApiException {
      // Interceptor already attempted refresh; if we land here, session dead.
      state = const AuthState(status: AuthStatus.unauthenticated);
    }
  }

  Future<void> login(String email, String password) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final user = await _repo.login(email, password);
      state = AuthState(status: AuthStatus.authenticated, user: user);
    } on ApiException catch (e) {
      state = state.copyWith(isLoading: false, error: e.message);
    }
  }

  Future<void> logout() async {
    await _repo.logout();
    state = const AuthState(status: AuthStatus.unauthenticated);
  }

  void clearError() => state = state.copyWith(clearError: true);
}

final authProvider = NotifierProvider<AuthNotifier, AuthState>(AuthNotifier.new);
