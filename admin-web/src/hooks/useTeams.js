import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { api } from '@/services/api/client';

const KEY = 'teams';

export function useTeams() {
  return useQuery({
    queryKey: [KEY],
    queryFn: async () => (await api.get('/teams')).data, // bare array
  });
}

export function useTeam(id) {
  return useQuery({
    queryKey: [KEY, id],
    queryFn: async () => (await api.get(`/teams/${id}`)).data,
    enabled: !!id,
  });
}

export function useCreateTeam() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (body) => (await api.post('/teams', body)).data,
    onSuccess: () => qc.invalidateQueries({ queryKey: [KEY] }),
  });
}

export function useUpdateTeam(id) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (body) => (await api.put(`/teams/${id}`, body)).data,
    onSuccess: () => qc.invalidateQueries({ queryKey: [KEY] }),
  });
}

export function useDeleteTeam() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (id) => api.delete(`/teams/${id}`),
    onSuccess: () => qc.invalidateQueries({ queryKey: [KEY] }),
  });
}

export function useAddTeamMember() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async ({ teamId, userId }) =>
      (await api.post(`/teams/${teamId}/members`, { user_id: userId })).data,
    onSuccess: () => qc.invalidateQueries({ queryKey: [KEY] }),
  });
}

export function useRemoveTeamMember() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async ({ teamId, userId }) =>
      (await api.delete(`/teams/${teamId}/members/${userId}`)).data,
    onSuccess: () => qc.invalidateQueries({ queryKey: [KEY] }),
  });
}
