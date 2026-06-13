import { useQuery } from '@tanstack/react-query';
import { api } from '@/services/api/client';

/**
 * Trail-replay route for an employee on a given day. Returns the enriched
 * payload: { points:[{lat,lng,timestamp,speed,accuracy,is_mock_gps,
 * attendance_state}], sessions:[{type,lat,lng,timestamp}],
 * total_distance_meters, total_duration_minutes }.
 */
export function useEmployeeRoute(userId, date, enabled = true) {
  return useQuery({
    queryKey: ['route', userId, date],
    enabled: enabled && !!userId && !!date,
    queryFn: async () =>
      (await api.get(`/location/route/${userId}`, { params: { date } })).data,
  });
}
