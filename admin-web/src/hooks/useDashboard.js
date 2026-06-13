import { useQuery } from '@tanstack/react-query';
import { api } from '@/services/api/client';

function todayISO() {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(
    d.getDate(),
  ).padStart(2, '0')}`;
}

/**
 * Dashboard overview, refreshed every 30s. Derived from two endpoints:
 *   /employees      → live status counts (Active/Idle/Offline) + total
 *   /attendance/all → present-today + distance-today aggregates
 */
export function useDashboard() {
  return useQuery({
    queryKey: ['dashboard'],
    refetchInterval: 30_000,
    queryFn: async () => {
      const [emps, att] = await Promise.all([
        api.get('/employees', { params: { limit: 100 } }),
        api.get('/attendance/all', { params: { date: todayISO(), limit: 100 } }),
      ]);

      const employees = emps.data.items || [];
      const totalEmployees = emps.data.total ?? employees.length;

      let active = 0;
      let idle = 0;
      let offline = 0;
      for (const e of employees) {
        const s = e.live?.live_status || 'OFFLINE';
        if (s === 'ACTIVE') active += 1;
        else if (s === 'IDLE') idle += 1;
        else offline += 1;
      }

      const rows = att.data.items || [];
      let present = 0;
      let half = 0;
      let absent = 0;
      let distance = 0;
      for (const r of rows) {
        if (r.status === 'PRESENT') present += 1;
        else if (r.status === 'HALF_DAY') half += 1;
        else if (r.status === 'ABSENT') absent += 1;
        distance += r.total_distance_meters || 0;
      }
      // Absent = roster minus those with a present/half record today.
      const accountedPresent = present + half;
      const derivedAbsent = Math.max(0, totalEmployees - accountedPresent) || absent;

      return {
        totalEmployees,
        presentToday: accountedPresent,
        absentToday: derivedAbsent,
        activeFieldStaff: active,
        distanceTodayKm: distance / 1000,
        statusBreakdown: [
          { name: 'Active', value: active, color: 'var(--ft-status-active)' },
          { name: 'Idle', value: idle, color: 'var(--ft-status-idle)' },
          { name: 'Offline', value: offline, color: 'var(--ft-status-offline)' },
        ],
        liveEmployees: employees,
      };
    },
  });
}
