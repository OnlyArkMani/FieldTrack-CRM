import {
  useMutation,
  useQuery,
  useQueryClient,
  keepPreviousData,
} from '@tanstack/react-query';
import { api } from '@/services/api/client';

const KEY = 'daily-reports';

/** Team DSRs for a given date (supervisor/admin). Admin may pass a teamId. */
export function useTeamDsrs(date, teamId) {
  return useQuery({
    queryKey: [KEY, 'team', date, teamId ?? null],
    queryFn: async () => {
      const { data } = await api.get('/daily-reports/team', {
        params: { report_date: date, ...(teamId ? { team_id: teamId } : {}) },
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

/** Paginated DSR archive (admin: all/team; supervisor: own team). Pass
 *  { enabled, ...filters } — `enabled` gates the query and is not sent. */
export function useDsrArchive({ enabled = true, ...filters } = {}) {
  return useQuery({
    queryKey: [KEY, 'archive', filters],
    queryFn: async () => {
      const { data } = await api.get('/daily-reports/archive', {
        params: { ...filters, limit: 100 },
      });
      return data;
    },
    placeholderData: keepPreviousData,
    enabled,
  });
}

/** Download one employee's DSR for a date as CSV (the per-day download button). */
export async function downloadTeamDsr(employeeId, date, employeeName = 'employee') {
  const { data } = await api.get(
    `/daily-reports/team/${employeeId}/${date}/download`,
    { responseType: 'blob' },
  );
  const url = window.URL.createObjectURL(data);
  const a = document.createElement('a');
  a.href = url;
  a.download = `DSR_${employeeName.replace(/\s+/g, '_')}_${date}.csv`;
  document.body.appendChild(a);
  a.click();
  a.remove();
  window.URL.revokeObjectURL(url);
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
