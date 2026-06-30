import {
  useMutation,
  useQuery,
  useQueryClient,
  keepPreviousData,
} from '@tanstack/react-query';
import { api } from '@/services/api/client';

const KEY = 'farmers';

/** Paginated farmer list (admin view). Each row carries the CURRENT lead
 *  status + last-visit timestamp joined by the backend. */
export function useFarmers({ teamId, leadStatus, search } = {}) {
  return useQuery({
    queryKey: [KEY, { teamId, leadStatus, search }],
    queryFn: async () => {
      const params = { limit: 100 };
      if (teamId) params.team_id = teamId;
      if (leadStatus) params.lead_status = leadStatus;
      if (search?.trim()) params.search = search.trim();
      const { data } = await api.get('/farmers', { params });
      return data; // { items, total, has_more, next_cursor }
    },
    placeholderData: keepPreviousData,
  });
}

/** Full farmer profile (base + current lead + recent visits + livestock +
 *  follow-ups + totals). */
export function useFarmer(id) {
  return useQuery({
    queryKey: [KEY, 'detail', id],
    queryFn: async () => (await api.get(`/farmers/${id}`)).data,
    enabled: !!id,
  });
}

export function useFarmerVisits(id) {
  return useQuery({
    queryKey: [KEY, 'visits', id],
    queryFn: async () =>
      (await api.get(`/farmers/${id}/visits`, { params: { limit: 100 } })).data,
    enabled: !!id,
  });
}

export function useFarmerLivestock(id) {
  return useQuery({
    queryKey: [KEY, 'livestock', id],
    queryFn: async () => (await api.get(`/farmers/${id}/livestock-history`)).data,
    enabled: !!id,
  });
}

export function useFarmerLeadHistory(id) {
  return useQuery({
    queryKey: [KEY, 'leads', id],
    queryFn: async () => (await api.get(`/farmers/${id}/lead-history`)).data,
    enabled: !!id,
  });
}

export function useCreateFarmer() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (body) => (await api.post('/farmers', body)).data,
    onSuccess: () => qc.invalidateQueries({ queryKey: [KEY] }),
  });
}

export function useUpdateFarmer(id) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (body) => (await api.put(`/farmers/${id}`, body)).data,
    onSuccess: () => qc.invalidateQueries({ queryKey: [KEY] }),
  });
}
