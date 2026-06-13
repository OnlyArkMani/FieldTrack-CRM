import { QueryClient } from '@tanstack/react-query';

// Sensible defaults for a dashboard: don't refetch on every window focus
// (the live views poll explicitly), but do retry transient failures once.
export const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      refetchOnWindowFocus: false,
      retry: 1,
      staleTime: 10_000,
    },
  },
});
