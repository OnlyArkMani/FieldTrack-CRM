import axios from 'axios';
import { useAuthStore } from '@/store/authStore';

// Base URL: the Vite dev proxy maps /api → the FastAPI server, so the refresh
// cookie (scoped to /api/v1/auth) stays same-origin. In production, serve the
// SPA behind the same Nginx as the API.
const API_PREFIX = import.meta.env.VITE_API_PREFIX || '/api/v1';

export const api = axios.create({
  baseURL: API_PREFIX,
  withCredentials: true, // send the httpOnly refresh cookie on /auth/*
  headers: { Accept: 'application/json' },
  timeout: 20000,
});

// Attach the in-memory access token to every request.
api.interceptors.request.use((config) => {
  const token = useAuthStore.getState().accessToken;
  if (token && !config.headers.Authorization) {
    config.headers.Authorization = `Bearer ${token}`;
  }
  return config;
});

// ── Single-flight refresh on 401 ──────────────────────────────────────────
let refreshing = null;

async function doRefresh() {
  // Bare axios (no interceptors) to avoid recursion. The refresh token rides
  // the httpOnly cookie; the new access token comes back in the body.
  const resp = await axios.post(
    `${API_PREFIX}/auth/refresh`,
    {},
    { withCredentials: true },
  );
  const token = resp.data.access_token;
  useAuthStore.getState().setAccessToken(token);
  if (resp.data.user) useAuthStore.getState().setUser(resp.data.user);
  return token;
}

api.interceptors.response.use(
  (r) => r,
  async (error) => {
    const original = error.config;
    const status = error.response?.status;
    const isAuthCall =
      original?.url?.includes('/auth/login') ||
      original?.url?.includes('/auth/refresh');

    if (status !== 401 || isAuthCall || original?._retried) {
      return Promise.reject(error);
    }

    try {
      refreshing = refreshing || doRefresh();
      const token = await refreshing;
      refreshing = null;
      original._retried = true;
      original.headers.Authorization = `Bearer ${token}`;
      return api(original);
    } catch (e) {
      refreshing = null;
      useAuthStore.getState().clear(); // session dead → bounce to /login
      return Promise.reject(error);
    }
  },
);

/** Normalize the backend's {detail, code} error envelope to a string. */
export function apiErrorMessage(error, fallback = 'Something went wrong') {
  return error?.response?.data?.detail || error?.message || fallback;
}
