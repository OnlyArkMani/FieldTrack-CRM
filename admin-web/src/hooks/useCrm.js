import { useQuery } from '@tanstack/react-query';
import { api } from '@/services/api/client';

function todayISO() {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

function nDaysAgoISO(n) {
  const d = new Date();
  d.setDate(d.getDate() - n);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

/**
 * CRM dashboard summary — derived from parallel lightweight fetches.
 * Returns:
 *   todayVisits, activeLeadsHot, activeLeadsWarm, activeLeadsCold,
 *   dsrsSubmittedToday, dsrsTotalToday, followUpsToday
 */
export function useCrmDashboard() {
  return useQuery({
    queryKey: ['crm', 'dashboard'],
    refetchInterval: 60_000,
    queryFn: async () => {
      const today = todayISO();
      const [visitsRes, leadsRes, dsrRes, fuRes] = await Promise.allSettled([
        api.get('/visits/team', { params: { date_from: today, date_to: today, limit: 1 } }),
        api.get('/leads/pipeline'),
        api.get('/daily-reports/team', { params: { report_date: today } }),
        api.get('/follow-ups/team', { params: { date_from: today, date_to: today } }),
      ]);

      // Today visits total
      let todayVisits = 0;
      if (visitsRes.status === 'fulfilled') {
        const d = visitsRes.value.data;
        todayVisits = d?.total ?? (Array.isArray(d) ? d.length : 0);
      }

      // Active leads breakdown
      let activeLeadsHot = 0, activeLeadsWarm = 0, activeLeadsCold = 0;
      if (leadsRes.status === 'fulfilled') {
        const d = leadsRes.value.data;
        activeLeadsHot = d?.hot ?? 0;
        activeLeadsWarm = d?.warm ?? 0;
        activeLeadsCold = d?.cold ?? 0;
      }

      // DSR counts for today
      let dsrsSubmittedToday = 0, dsrsTotalToday = 0;
      if (dsrRes.status === 'fulfilled') {
        const items = dsrRes.value.data || [];
        dsrsTotalToday = items.length;
        dsrsSubmittedToday = items.filter((r) => r.status === 'SUBMITTED').length;
      }

      // Follow-ups today
      let followUpsToday = 0;
      if (fuRes.status === 'fulfilled') {
        const d = fuRes.value.data;
        followUpsToday = Array.isArray(d) ? d.length : (d?.total ?? 0);
      }

      return {
        todayVisits,
        activeLeadsHot,
        activeLeadsWarm,
        activeLeadsCold,
        activeLeadsTotal: activeLeadsHot + activeLeadsWarm + activeLeadsCold,
        dsrsSubmittedToday,
        dsrsTotalToday,
        followUpsToday,
      };
    },
  });
}

/**
 * CRM performance scorecard for a single employee.
 * start/end default to last 30 days on the backend when omitted.
 */
export function useCrmPerformance(employeeId, { startDate, endDate } = {}) {
  return useQuery({
    queryKey: ['crm', 'performance', employeeId, startDate, endDate],
    enabled: !!employeeId,
    queryFn: async () => {
      const params = {};
      if (startDate) params.start_date = startDate;
      if (endDate) params.end_date = endDate;
      return (await api.get(`/employees/${employeeId}/crm-performance`, { params })).data;
    },
  });
}
