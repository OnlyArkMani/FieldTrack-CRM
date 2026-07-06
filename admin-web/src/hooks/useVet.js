import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { api } from '@/services/api/client';

const KEY = 'vet-requests';

/** Vet requests visible to the caller (admin sees all; team filter optional). */
export function useVetRequests({ status, teamId } = {}) {
  return useQuery({
    queryKey: [KEY, status, teamId],
    queryFn: async () => {
      const { data } = await api.get('/vet-requests', {
        params: { status: status || undefined, team_id: teamId || undefined },
      });
      return data;
    },
  });
}

/** Advance a vet request: REQUESTED -> SCHEDULED -> DONE. */
export function useUpdateVetStatus() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async ({ visitId, vetStatus }) =>
      (
        await api.patch(`/vet-requests/${visitId}/status`, {
          vet_status: vetStatus,
        })
      ).data,
    onSuccess: () => qc.invalidateQueries({ queryKey: [KEY] }),
  });
}
