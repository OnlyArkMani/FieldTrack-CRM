import { create } from 'zustand';

// Auth state. The access token is kept IN MEMORY only (never localStorage) —
// XSS can't read it, and a page reload re-bootstraps it from the httpOnly
// refresh cookie via /auth/refresh. The user object is convenience-cached.
export const useAuthStore = create((set) => ({
  accessToken: null,
  user: null,
  status: 'unknown', // 'unknown' | 'authenticated' | 'unauthenticated'

  setAccessToken: (accessToken) => set({ accessToken }),
  setUser: (user) => set({ user }),

  setSession: ({ accessToken, user }) =>
    set({ accessToken, user, status: 'authenticated' }),

  clear: () =>
    set({ accessToken: null, user: null, status: 'unauthenticated' }),

  setUnauthenticated: () => set({ status: 'unauthenticated' }),
}));

export const selectIsAdmin = (s) => s.user?.role === 'ADMIN';
