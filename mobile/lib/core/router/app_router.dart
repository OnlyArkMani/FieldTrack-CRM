import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/attendance/screens/attendance_screen.dart';
import '../../features/auth/models/user.dart';
import '../../features/auth/providers/auth_provider.dart';
import '../../features/auth/screens/login_screen.dart';
import '../../features/crm/farmers/screens/add_farmer_screen.dart';
import '../../features/crm/farmers/screens/farmer_detail_screen.dart';
import '../../features/crm/farmers/screens/farmer_list_screen.dart';
import '../../features/crm/farmers/screens/farmer_visits_screen.dart';
import '../../features/crm/farmers/screens/livestock_history_screen.dart';
import '../../features/crm/planning/screens/plan_map_screen.dart';
import '../../features/crm/planning/screens/visit_plan_screen.dart';
import '../../features/crm/dsr/screens/dsr_history_screen.dart';
import '../../features/crm/dsr/screens/dsr_review_screen.dart';
import '../../features/crm/followups/screens/followups_screen.dart';
import '../../features/crm/leads/screens/lead_pipeline_screen.dart';
import '../../features/crm/visits/screens/visit_flow_screen.dart';
import '../../features/crm/visits/screens/visit_summary_screen.dart';
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
          // Farmers (CRM) — visible to every field user (employees + supervisors).
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/home/farmers',
              pageBuilder: (context, state) =>
                  WaterPage(key: state.pageKey, child: const FarmerListScreen()),
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

      // Farmer detail / create / sub-screens (pushed over the shell).
      GoRoute(
        path: '/farmer/add',
        pageBuilder: (context, state) =>
            WaterPage(key: state.pageKey, child: const AddFarmerScreen()),
      ),
      GoRoute(
        path: '/farmer/:id',
        pageBuilder: (context, state) => WaterPage(
          key: state.pageKey,
          child: FarmerDetailScreen(
            farmerId: int.tryParse(state.pathParameters['id'] ?? '') ?? 0,
          ),
        ),
      ),
      GoRoute(
        path: '/farmer/:id/livestock',
        pageBuilder: (context, state) => WaterPage(
          key: state.pageKey,
          child: LivestockHistoryScreen(
            farmerId: int.tryParse(state.pathParameters['id'] ?? '') ?? 0,
          ),
        ),
      ),
      GoRoute(
        path: '/farmer/:id/visits',
        pageBuilder: (context, state) => WaterPage(
          key: state.pageKey,
          child: FarmerVisitsScreen(
            farmerId: int.tryParse(state.pathParameters['id'] ?? '') ?? 0,
          ),
        ),
      ),

      // Visit planning (pre-day) + its map view.
      GoRoute(
        path: '/planning',
        pageBuilder: (context, state) =>
            WaterPage(key: state.pageKey, child: const VisitPlanScreen()),
      ),
      GoRoute(
        path: '/planning/map',
        pageBuilder: (context, state) =>
            WaterPage(key: state.pageKey, child: const PlanMapScreen()),
      ),

      // Field visit execution (guided flow) + read-only summary.
      GoRoute(
        path: '/visit/start/:farmerId',
        pageBuilder: (context, state) => WaterPage(
          key: state.pageKey,
          child: VisitFlowScreen(
            farmerId:
                int.tryParse(state.pathParameters['farmerId'] ?? '') ?? 0,
            planItemId:
                int.tryParse(state.uri.queryParameters['plan_item'] ?? ''),
          ),
        ),
      ),
      GoRoute(
        path: '/visit/:id/summary',
        pageBuilder: (context, state) => WaterPage(
          key: state.pageKey,
          child: VisitSummaryScreen(
            visitId: int.tryParse(state.pathParameters['id'] ?? '') ?? 0,
          ),
        ),
      ),

      // Lead pipeline + follow-ups (CRM Module 4).
      GoRoute(
        path: '/leads',
        pageBuilder: (context, state) =>
            WaterPage(key: state.pageKey, child: const LeadPipelineScreen()),
      ),
      GoRoute(
        path: '/followups',
        pageBuilder: (context, state) =>
            WaterPage(key: state.pageKey, child: const FollowUpsScreen()),
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

      // DSR: review screen (pushed after attendance END)
      GoRoute(
        path: '/dsr/review',
        pageBuilder: (context, state) {
          final extra = state.extra as Map<String, dynamic>? ?? {};
          return WaterPage(
            key: state.pageKey,
            child: DsrReviewScreen(
              reportDate: extra['report_date'] as DateTime? ?? DateTime.now(),
            ),
          );
        },
      ),

      // DSR history (accessible from profile tab)
      GoRoute(
        path: '/dsr/history',
        pageBuilder: (context, state) =>
            WaterPage(key: state.pageKey, child: const DsrHistoryScreen()),
      ),
    ],
  );
});
