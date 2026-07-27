import {
  useMutation,
  useQuery,
  useQueryClient,
  keepPreviousData,
} from '@tanstack/react-query';
import { api } from '@/services/api/client';

const KEY = 'attendance';

/** All employees' attendance for a given day (admin). Merges roster so absent/not started employees are also listed. */
export function useAttendanceForDate(date) {
  return useQuery({
    queryKey: [KEY, 'all', date],
    queryFn: async () => {
      const [attRes, empsRes] = await Promise.all([
        api.get('/attendance/all', { params: { date, limit: 100 } }),
        api.get('/employees', { params: { limit: 100 } }),
      ]);

      const attItems = attRes.data?.items || [];
      const employees = empsRes.data?.items || [];

      // Map existing attendance items by employee/user ID
      const attMap = new Map();
      for (const item of attItems) {
        const empId = item.employee?.id || item.user_id;
        if (empId) attMap.set(empId, item);
      }

      const merged = [];
      for (const emp of employees) {
        const record = attMap.get(emp.id);
        if (record) {
          merged.push({
            ...record,
            employee: record.employee || emp,
          });
          attMap.delete(emp.id);
        } else {
          // Employee has no attendance entry for this date -> ABSENT / Not started
          merged.push({
            id: null,
            user_id: emp.id,
            employee: emp,
            status: 'ABSENT',
            sessions: [],
            total_duration_minutes: 0,
            work_summary: null,
            isAbsent: true,
          });
        }
      }

      // Add any remaining attendance items not in employees list
      for (const record of attMap.values()) {
        merged.push(record);
      }

      const presentCount = merged.filter(
        (i) => i.status === 'PRESENT' || i.status === 'HALF_DAY',
      ).length;
      const absentCount = merged.length - presentCount;

      return {
        items: merged,
        total: merged.length,
        presentCount,
        absentCount,
      };
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
