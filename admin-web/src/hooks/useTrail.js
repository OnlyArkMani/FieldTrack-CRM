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

/**
 * 31-day distance report for an employee. Returns
 * { user_id, start_date, end_date, total_distance_meters,
 *   days:[{date, distance_meters, point_count, has_trail}] }.
 * Cheap (one grouped query, derived from the existing 31-day location_logs —
 * no extra storage), so safe to fetch whenever the modal opens.
 */
export function useTrailSummary(userId, days = 31, enabled = true) {
  return useQuery({
    queryKey: ['trail-summary', userId, days],
    enabled: enabled && !!userId,
    queryFn: async () =>
      (await api.get(`/location/trail-summary/${userId}`, { params: { days } })).data,
  });
}
