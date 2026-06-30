import { useQuery, keepPreviousData } from '@tanstack/react-query';
import { api } from '@/services/api/client';

const KEY = 'visit-plans';

/** All in-scope employees' plans for a date (admin sees everyone). */
export function useTeamPlans(date) {
  return useQuery({
    queryKey: [KEY, 'team', date],
    queryFn: async () => (await api.get(`/visit-plans/team/${date}`)).data,
    enabled: !!date,
    placeholderData: keepPreviousData,
  });
}

/** Employees with no submitted plan for tomorrow (alert source). */
export function usePendingSubmissions() {
  return useQuery({
    queryKey: [KEY, 'pending'],
    queryFn: async () => (await api.get('/visit-plans/pending-submissions')).data,
  });
}
