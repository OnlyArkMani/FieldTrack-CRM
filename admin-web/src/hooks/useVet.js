import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { api } from '@/services/api/client';

const KEY = 'vet-requests';

/** Vet requests visible to the caller (admin sees all; team/employee filters optional). */
export function useVetRequests({ status, teamId, employeeId } = {}) {
  return useQuery({
    queryKey: [KEY, status, teamId, employeeId],
    queryFn: async () => {
      const { data } = await api.get('/vet-requests', {
        params: {
          status: status || undefined,
          team_id: teamId || undefined,
          employee_id: employeeId || undefined,
        },
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
