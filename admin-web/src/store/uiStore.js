import { create } from 'zustand';

const THEME_KEY = 'ft_theme';

function initialTheme() {
  const stored = localStorage.getItem(THEME_KEY);
  if (stored === 'dark' || stored === 'light') return stored;
  return window.matchMedia?.('(prefers-color-scheme: dark)').matches
    ? 'dark'
    : 'light';
}

function applyTheme(theme) {
  const root = document.documentElement;
  if (theme === 'dark') root.classList.add('dark');
  else root.classList.remove('dark');
}

// Global UI: theme (persisted) + sidebar collapse state.
export const useUiStore = create((set, get) => {
  const theme = initialTheme();
  applyTheme(theme);
  return {
    theme,
    sidebarCollapsed: false,
    sidebarMobileOpen: false,

    toggleTheme: () => {
      const next = get().theme === 'dark' ? 'light' : 'dark';
      localStorage.setItem(THEME_KEY, next);
      applyTheme(next);
      set({ theme: next });
    },

    toggleSidebar: () =>
      set((s) => ({ sidebarCollapsed: !s.sidebarCollapsed })),
    setSidebarMobileOpen: (open) => set({ sidebarMobileOpen: open }),
  };
});
