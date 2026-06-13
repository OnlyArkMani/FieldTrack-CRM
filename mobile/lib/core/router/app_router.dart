import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/attendance/screens/attendance_screen.dart';
import '../../features/auth/models/user.dart';
import '../../features/auth/providers/auth_provider.dart';
import '../../features/auth/screens/login_screen.dart';
import '../../features/dashboard/screens/dashboard_screen.dart';
import '../../features/employees/screens/employee_detail_screen.dart';
import '../../features/employees/screens/employee_list_screen.dart';
import '../../features/home/screens/home_shell.dart';
import '../../features/map/screens/map_screen.dart';
import '../../features/notifications/screens/notifications_screen.dart';
import '../../features/profile/screens/profile_screen.dart';
import '../../features/reports/screens/reports_screen.dart';
import '../../features/splash/splash_screen.dart';
import '../../features/teams/screens/team_list_screen.dart';
import 'transitions.dart';

/// Bridges Riverpod -> go_router's refreshListenable: any auth change makes
/// the router re-run its redirect logic.
class _AuthRefresh extends ChangeNotifier {
  _AuthRefresh(Ref ref) {
    ref.listen(authProvider, (_, __) => notifyListeners());
  }
}

final routerProvider = Provider<GoRouter>((ref) {
  final refresh = _AuthRefresh(ref);
  ref.onDispose(refresh.dispose);

  return GoRouter(
    initialLocation: '/splash',
    refreshListenable: refresh,
    redirect: (context, state) {
      final auth = ref.read(authProvider);
      final loc = state.matchedLocation;

      // Still restoring the session: stay on splash.
      if (auth.status == AuthStatus.unknown) {
        return loc == '/splash' ? null : '/splash';
      }

      final loggedIn = auth.status == AuthStatus.authenticated;

      if (!loggedIn) {
        return loc == '/login' ? null : '/login';
      }

      // Logged in: never show splash/login again.
      if (loc == '/splash' || loc == '/login') return '/home/dashboard';

      // Role guard: the team-management surfaces (employee directory, an
      // employee's detail, and teams) are supervisor-only on mobile (admins
      // are web-only per the role matrix). '/employees' (list) is distinct
      // from '/employee/' (detail) — both are covered here.
      final isTeamMgmt = loc == '/employees' ||
          loc == '/teams' ||
          loc.startsWith('/employee/');
      if (isTeamMgmt && auth.user?.role != UserRole.supervisor) {
        return '/home/dashboard';
      }

      return null;
    },
    routes: [
      GoRoute(
        path: '/splash',
        pageBuilder: (context, state) =>
            WaterPage(key: state.pageKey, child: const SplashScreen()),
      ),
      GoRoute(
        path: '/login',
        pageBuilder: (context, state) =>
            WaterPage(key: state.pageKey, child: const LoginScreen()),
      ),

      // Bottom-nav shell. IndexedStack keeps tab state (map stays loaded,
      // scroll positions survive tab switches).
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            HomeShell(navigationShell: navigationShell),
        branches: [
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/home/dashboard',
              pageBuilder: (context, state) => WaterPage(
                  key: state.pageKey,
                  // Role-aware INSIDE the screen: supervisor gets the team
                  // view, employee the personal view — one route, no fork.
                  child: const DashboardScreen()),
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/home/attendance',
              pageBuilder: (context, state) => WaterPage(
                  key: state.pageKey, child: const AttendanceScreen()),
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/home/map',
              pageBuilder: (context, state) =>
                  WaterPage(key: state.pageKey, child: const MapScreen()),
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/home/profile',
              pageBuilder: (context, state) =>
                  WaterPage(key: state.pageKey, child: const ProfileScreen()),
            ),
          ]),
        ],
      ),

      GoRoute(
        path: '/employees',
        pageBuilder: (context, state) =>
            WaterPage(key: state.pageKey, child: const EmployeeListScreen()),
      ),
      GoRoute(
        path: '/teams',
        pageBuilder: (context, state) =>
            WaterPage(key: state.pageKey, child: const TeamListScreen()),
      ),
      GoRoute(
        path: '/employee/:id',
        pageBuilder: (context, state) => WaterPage(
          key: state.pageKey,
          child: EmployeeDetailScreen(
            employeeId: int.tryParse(state.pathParameters['id'] ?? '') ?? 0,
          ),
        ),
      ),
      GoRoute(
        path: '/notifications',
        pageBuilder: (context, state) =>
            WaterPage(key: state.pageKey, child: const NotificationsScreen()),
      ),
      GoRoute(
        path: '/reports',
        pageBuilder: (context, state) =>
            WaterPage(key: state.pageKey, child: const ReportsScreen()),
      ),
    ],
  );
});
