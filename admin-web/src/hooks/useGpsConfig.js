import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { api } from '@/services/api/client';

const KEY = 'gps-config';

export const GPS_DEFAULTS = {
  moving_interval_seconds: 180,
  stationary_interval_seconds: 720,
  low_battery_interval_seconds: 1200,
  low_battery_threshold: 20,
};

export function useTeamGpsConfig(teamId) {
  return useQuery({
    queryKey: [KEY, 'team', teamId],
    queryFn: async () => (await api.get(`/gps-config/team/${teamId}`)).data,
    enabled: !!teamId,
    placeholderData: { ...GPS_DEFAULTS, team_id: teamId ? Number(teamId) : null },
  });
}

export function useSaveGpsConfig(teamId) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (body) =>
      (await api.put(`/gps-config/team/${teamId}`, body)).data,
    onSuccess: (data) => {
      qc.setQueryData([KEY, 'team', teamId], data);
    },
  });
}
