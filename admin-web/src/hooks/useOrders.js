import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { api } from '@/services/api/client';

const KEY = 'orders';

/** SUBMITTED orders awaiting approval (checklist #34). */
export function usePendingOrders(teamId) {
  return useQuery({
    queryKey: [KEY, 'pending', teamId],
    queryFn: async () => {
      const { data } = await api.get('/orders/pending', {
        params: { team_id: teamId || undefined },
      });
      return data;
    },
  });
}

/** Approve or reject a pending order. */
export function useReviewOrder() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async ({ orderId, action, rejectionReason }) =>
      (
        await api.post(`/orders/${orderId}/review`, {
          action,
          rejection_reason: rejectionReason || undefined,
        })
      ).data,
    onSuccess: () => qc.invalidateQueries({ queryKey: [KEY] }),
  });
}
