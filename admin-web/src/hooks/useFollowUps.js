import { useQuery, keepPreviousData } from '@tanstack/react-query';
import { api } from '@/services/api/client';

const KEY = 'follow-ups';

/** Team follow-ups (supervisor: their teams; admin: all) in a date window. */
export function useTeamFollowUps({ dateFrom, dateTo, employeeId } = {}) {
  return useQuery({
    queryKey: [KEY, 'team', { dateFrom, dateTo, employeeId }],
    queryFn: async () => {
      const params = {};
      if (dateFrom) params.date_from = dateFrom;
      if (dateTo) params.date_to = dateTo;
      if (employeeId) params.employee_id = employeeId;
      return (await api.get('/follow-ups/team', { params })).data;
    },
    enabled: !!dateFrom && !!dateTo,
    placeholderData: keepPreviousData,
  });
}
