import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { fileURLToPath, URL } from 'node:url';

// Dev proxy so the SPA and API share an origin in development (httpOnly refresh
// cookie is scoped to /api/v1/auth, so cross-origin would drop it).
export default defineConfig({
  plugins: [react()],
  resolve: {
    alias: {
      '@': fileURLToPath(new URL('./src', import.meta.url)),
    },
  },
  server: {
    port: 5173,
    proxy: {
      '/api': {
        target: process.env.VITE_PROXY_TARGET || 'http://localhost:8000',
        changeOrigin: true,
        ws: true, // proxy the /ws/admin-live WebSocket too
      },
    },
  },
});
