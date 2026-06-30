import { useQuery, keepPreviousData } from '@tanstack/react-query';
import { api } from '@/services/api/client';

const KEY = 'leads';

/** Admin pipeline summary: totals + by_team + by_employee. */
export function usePipeline() {
  return useQuery({
    queryKey: [KEY, 'pipeline'],
    queryFn: async () => (await api.get('/leads/pipeline')).data,
    placeholderData: keepPreviousData,
  });
}

/** Team leads (supervisor/admin): grouped counts + filterable list. */
export function useTeamLeads({ status, employeeId } = {}) {
  return useQuery({
    queryKey: [KEY, 'team', { status, employeeId }],
    queryFn: async () => {
      const params = {};
      if (status) params.status = status;
      if (employeeId) params.employee_id = employeeId;
      return (await api.get('/leads/team', { params })).data;
    },
    placeholderData: keepPreviousData,
  });
}
