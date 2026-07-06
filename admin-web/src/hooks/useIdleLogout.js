import { useEffect, useRef } from 'react';
import { useNavigate } from 'react-router-dom';

import { api } from '@/services/api/client';
import { useAuthStore } from '@/store/authStore';

// checklist #70 — 30-minute inactivity timeout. Mounted once for the
// authenticated app shell (see App.jsx's <Protected> wrapper), not the
// login page itself.
const IDLE_TIMEOUT_MS = 30 * 60 * 1000;
const ACTIVITY_EVENTS = ['mousemove', 'mousedown', 'keydown', 'scroll', 'touchstart'];

export function useIdleLogout() {
  const clear = useAuthStore((s) => s.clear);
  const navigate = useNavigate();
  const timerRef = useRef(null);

  useEffect(() => {
    async function logoutForInactivity() {
      try {
        await api.post('/auth/logout', {});
      } catch {
        /* best-effort, same as the manual logout button */
      }
      clear();
      navigate('/login', { replace: true, state: { reason: 'idle' } });
    }

    function resetTimer() {
      if (timerRef.current) clearTimeout(timerRef.current);
      timerRef.current = setTimeout(logoutForInactivity, IDLE_TIMEOUT_MS);
    }

    resetTimer();
    ACTIVITY_EVENTS.forEach((evt) => window.addEventListener(evt, resetTimer, { passive: true }));

    return () => {
      if (timerRef.current) clearTimeout(timerRef.current);
      ACTIVITY_EVENTS.forEach((evt) => window.removeEventListener(evt, resetTimer));
    };
  }, [clear, navigate]);
}
