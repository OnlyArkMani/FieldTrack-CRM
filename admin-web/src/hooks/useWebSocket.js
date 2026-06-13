import { useEffect, useRef, useState } from 'react';
import { useAuthStore } from '@/store/authStore';

function wsUrl() {
  const fromEnv = import.meta.env.VITE_WS_URL;
  if (fromEnv) return fromEnv;
  const prefix = import.meta.env.VITE_API_PREFIX || '/api/v1';
  const proto = window.location.protocol === 'https:' ? 'wss' : 'ws';
  return `${proto}://${window.location.host}${prefix}/ws/admin-live`;
}

/**
 * Subscribe to the admin live feed (WS /ws/admin-live). Returns the latest
 * {employees, serverTime} plus a connection status. Auto-reconnects with
 * backoff; the access token is passed as a query param (browsers can't set WS
 * headers).
 */
export function useAdminLiveSocket({ enabled = true } = {}) {
  const token = useAuthStore((s) => s.accessToken);
  const [employees, setEmployees] = useState([]);
  const [status, setStatus] = useState('connecting'); // connecting|open|closed
  const [serverTime, setServerTime] = useState(null);
  const socketRef = useRef(null);
  const retryRef = useRef(0);
  const closedByUs = useRef(false);

  useEffect(() => {
    if (!enabled || !token) return undefined;
    closedByUs.current = false;
    let reconnectTimer;

    const connect = () => {
      setStatus('connecting');
      const ws = new WebSocket(`${wsUrl()}?token=${encodeURIComponent(token)}`);
      socketRef.current = ws;

      ws.onopen = () => {
        retryRef.current = 0;
        setStatus('open');
      };
      ws.onmessage = (evt) => {
        try {
          const msg = JSON.parse(evt.data);
          if (msg.type === 'LOCATION_UPDATE') {
            setEmployees(msg.employees || []);
            setServerTime(msg.server_time || null);
          }
        } catch {
          /* ignore malformed frame */
        }
      };
      ws.onclose = () => {
        setStatus('closed');
        if (closedByUs.current) return;
        // Exponential backoff capped at 30s.
        const delay = Math.min(30000, 1000 * 2 ** retryRef.current);
        retryRef.current += 1;
        reconnectTimer = setTimeout(connect, delay);
      };
      ws.onerror = () => ws.close();
    };

    connect();

    return () => {
      closedByUs.current = true;
      clearTimeout(reconnectTimer);
      socketRef.current?.close();
    };
  }, [enabled, token]);

  return { employees, status, serverTime };
}
