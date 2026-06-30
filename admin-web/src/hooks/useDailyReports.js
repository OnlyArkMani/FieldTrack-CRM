import {
  useMutation,
  useQuery,
  useQueryClient,
  keepPreviousData,
} from '@tanstack/react-query';
import { api } from '@/services/api/client';

const KEY = 'daily-reports';

/** Team DSRs for a given date (supervisor/admin). */
export function useTeamDsrs(date) {
  return useQuery({
    queryKey: [KEY, 'team', date],
    queryFn: async () => {
      const { data } = await api.get('/daily-reports/team', {
        params: { report_date: date },
      });
      return data; // array of TeamDsrItem
    },
    placeholderData: keepPreviousData,
    enabled: !!date,
  });
}

/** Full DSR detail for one employee on one date. */
export function useDsrDetail(employeeId, date) {
  return useQuery({
    queryKey: [KEY, 'detail', employeeId, date],
    queryFn: async () => {
      const { data } = await api.get(
        `/daily-reports/team/${employeeId}/${date}`
      );
      return data;
    },
    enabled: !!employeeId && !!date,
  });
}

/** Paginated admin archive. */
export function useDsrArchive(filters) {
  return useQuery({
    queryKey: [KEY, 'archive', filters],
    queryFn: async () => {
      const { data } = await api.get('/daily-reports/archive', {
        params: {
          ...filters,
          limit: 30,
        },
      });
      return data;
    },
    placeholderData: keepPreviousData,
  });
}

/** POST manager comment. */
export function useAddManagerComment() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async ({ reportId, comment }) =>
      (await api.post(`/daily-reports/${reportId}/manager-comment`, { comment }))
        .data,
    onSuccess: () => qc.invalidateQueries({ queryKey: [KEY] }),
  });
}
