import {
  useMutation,
  useQuery,
  useQueryClient,
  keepPreviousData,
} from '@tanstack/react-query';
import { api } from '@/services/api/client';

const KEY = 'employees';

/** Paginated employee list (admin view). Filters map to backend query params. */
export function useEmployees({ teamId, status, search } = {}) {
  return useQuery({
    queryKey: [KEY, { teamId, status, search }],
    queryFn: async () => {
      const params = { limit: 100 };
      if (teamId) params.team_id = teamId;
      if (status) params.status = status;
      if (search?.trim()) params.search = search.trim();
      const { data } = await api.get('/employees', { params });
      return data; // { items, total, has_more, next_cursor }
    },
    placeholderData: keepPreviousData,
  });
}

export function useEmployee(id) {
  return useQuery({
    queryKey: [KEY, 'detail', id],
    queryFn: async () => (await api.get(`/employees/${id}`)).data,
    enabled: !!id,
  });
}

export function useAttendanceSummary(id, year, month) {
  return useQuery({
    queryKey: [KEY, 'summary', id, year, month],
    queryFn: async () =>
      (await api.get(`/employees/${id}/attendance-summary`, { params: { year, month } })).data,
    enabled: !!id,
  });
}

export function useCreateEmployee() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (body) => (await api.post('/employees', body)).data,
    onSuccess: () => qc.invalidateQueries({ queryKey: [KEY] }),
  });
}

export function useUpdateEmployee(id) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (body) => (await api.put(`/employees/${id}`, body)).data,
    onSuccess: () => qc.invalidateQueries({ queryKey: [KEY] }),
  });
}

export function useSetEmployeeStatus() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async ({ id, isActive }) =>
      (await api.patch(`/employees/${id}/status`, { is_active: isActive })).data,
    onSuccess: () => qc.invalidateQueries({ queryKey: [KEY] }),
  });
}

/** Mock-GPS integrity for one employee (7-day window). Admin/supervisor only;
 *  this anti-gaming data is never shown to the employee. Refetched on an
 *  interval so the detail page stays current without a manual reload. */
export function useGpsIntegrity(id) {
  return useQuery({
    queryKey: [KEY, 'gps-integrity', id],
    queryFn: async () => (await api.get(`/employees/${id}/gps-integrity`)).data,
    enabled: !!id,
    refetchInterval: 60_000,
  });
}
