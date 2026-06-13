import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { api } from '@/services/api/client';

const KEY = 'geofences';

export function useGeofences() {
  return useQuery({
    queryKey: [KEY],
    queryFn: async () => (await api.get('/geofences')).data, // [{id,name,coordinates,...}]
  });
}

export function useGeofence(id) {
  return useQuery({
    queryKey: [KEY, id],
    queryFn: async () => (await api.get(`/geofences/${id}`)).data,
    enabled: !!id,
  });
}

export function useCreateGeofence() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (body) => (await api.post('/geofences', body)).data,
    onSuccess: () => qc.invalidateQueries({ queryKey: [KEY] }),
  });
}

export function useUpdateGeofence() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async ({ id, ...body }) => (await api.put(`/geofences/${id}`, body)).data,
    onSuccess: () => qc.invalidateQueries({ queryKey: [KEY] }),
  });
}

export function useDeleteGeofence() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (id) => api.delete(`/geofences/${id}`),
    onSuccess: () => qc.invalidateQueries({ queryKey: [KEY] }),
  });
}
