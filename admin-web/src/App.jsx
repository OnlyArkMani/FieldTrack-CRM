import { useEffect } from 'react';
import { Routes, Route, Navigate, useLocation } from 'react-router-dom';

import { api } from './services/api/client';
import { useAuthStore, selectIsAdmin } from './store/authStore';

import AppLayout from './components/layout/AppLayout';
import Spinner from './components/ui/Spinner';

import LoginPage from './features/auth/LoginPage';
import DashboardPage from './features/dashboard/DashboardPage';
import EmployeesPage from './features/employees/EmployeesPage';
import EmployeeDetailPage from './features/employees/EmployeeDetailPage';
import TeamsPage from './features/teams/TeamsPage';
import AttendancePage from './features/attendance/AttendancePage';
import MapPage from './features/map/MapPage';
import GeofencesPage from './features/geofences/GeofencesPage';
import ReportsPage from './features/reports/ReportsPage';
import SettingsPage from './features/settings/SettingsPage';

/** Restore the session on load via the httpOnly refresh cookie. */
function useSessionBootstrap() {
  const status = useAuthStore((s) => s.status);
  const setSession = useAuthStore((s) => s.setSession);
  const setUnauthenticated = useAuthStore((s) => s.setUnauthenticated);

  useEffect(() => {
    let active = true;
    (async () => {
      try {
        const { data } = await api.post('/auth/refresh', {});
        if (!active) return;
        setSession({ accessToken: data.access_token, user: data.user });
      } catch {
        if (active) setUnauthenticated();
      }
    })();
    return () => {
      active = false;
    };
  }, [setSession, setUnauthenticated]);

  return status;
}

function Protected({ children }) {
  const status = useAuthStore((s) => s.status);
  const isAdmin = useAuthStore(selectIsAdmin);
  const location = useLocation();

  if (status !== 'authenticated') {
    return <Navigate to="/login" replace state={{ from: location }} />;
  }
  if (!isAdmin) {
    // The web dashboard is admin-only by design.
    return (
      <div className="grid h-screen place-items-center p-8 text-center">
        <div>
          <h1 className="text-xl font-semibold text-text-primary">
            Admin access only
          </h1>
          <p className="mt-2 text-text-secondary">
            The FieldTrack web dashboard is for administrators. Supervisors and
            employees use the mobile app.
          </p>
        </div>
      </div>
    );
  }
  return children;
}

export default function App() {
  const status = useSessionBootstrap();

  if (status === 'unknown') {
    return (
      <div className="grid h-screen place-items-center bg-bg">
        <Spinner label="Restoring session…" />
      </div>
    );
  }

  return (
    <Routes>
      <Route path="/login" element={<LoginPage />} />
      <Route
        element={
          <Protected>
            <AppLayout />
          </Protected>
        }
      >
        <Route path="/" element={<DashboardPage />} />
        <Route path="/employees" element={<EmployeesPage />} />
        <Route path="/employees/:id" element={<EmployeeDetailPage />} />
        <Route path="/teams" element={<TeamsPage />} />
        <Route path="/attendance" element={<AttendancePage />} />
        <Route path="/map" element={<MapPage />} />
        <Route path="/geofences" element={<GeofencesPage />} />
        <Route path="/reports" element={<ReportsPage />} />
        <Route path="/settings" element={<SettingsPage />} />
      </Route>
      <Route path="*" element={<Navigate to="/" replace />} />
    </Routes>
  );
}
