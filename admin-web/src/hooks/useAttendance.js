import {
  useMutation,
  useQuery,
  useQueryClient,
  keepPreviousData,
} from '@tanstack/react-query';
import { api } from '@/services/api/client';

const KEY = 'attendance';

/** All employees' attendance for a given day (admin). */
export function useAttendanceForDate(date) {
  return useQuery({
    queryKey: [KEY, 'all', date],
    queryFn: async () => {
      const { data } = await api.get('/attendance/all', {
        params: { date, limit: 100 },
      });
      return data; // { items, total, has_more, next_cursor }
    },
    placeholderData: keepPreviousData,
  });
}

export function useOverrideStatus() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async ({ attendanceId, status, reason }) =>
      (await api.patch(`/attendance/${attendanceId}/status`, { status, reason })).data,
    onSuccess: () => qc.invalidateQueries({ queryKey: [KEY] }),
  });
}

export function useAddManualSession() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async ({ attendanceId, type, timestamp, lat, lng, reason }) =>
      (
        await api.post(`/attendance/${attendanceId}/sessions`, {
          type,
          timestamp,
          lat,
          lng,
          reason,
        })
      ).data,
    onSuccess: () => qc.invalidateQueries({ queryKey: [KEY] }),
  });
}
