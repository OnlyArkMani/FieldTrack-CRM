import { useState } from 'react';
import { Search, Bell, Menu, LogOut } from 'lucide-react';

import { useUiStore } from '@/store/uiStore';
import { useAuthStore } from '@/store/authStore';
import { api } from '@/services/api/client';
import ThemeToggle from '@/components/ui/ThemeToggle';
import Avatar from '@/components/ui/Avatar';

export default function Topbar({ onSearch }) {
  const setMobileOpen = useUiStore((s) => s.setSidebarMobileOpen);
  const user = useAuthStore((s) => s.user);
  const clear = useAuthStore((s) => s.clear);
  const [menuOpen, setMenuOpen] = useState(false);

  const logout = async () => {
    try {
      await api.post('/auth/logout', {});
    } catch {
      /* logout is best-effort; clear locally regardless */
    }
    clear();
  };

  return (
    <header className="sticky top-0 z-30 flex h-16 items-center gap-3 border-b border-border bg-card/80 px-4 backdrop-blur">
      <button
        onClick={() => setMobileOpen(true)}
        className="grid h-9 w-9 place-items-center rounded-btn text-text-secondary hover:bg-border/50 md:hidden"
      >
        <Menu className="h-5 w-5" />
      </button>

      <div className="relative max-w-md flex-1">
        <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-text-secondary" />
        <input
          onChange={(e) => onSearch?.(e.target.value)}
          placeholder="Search employees, teams…"
          className="h-10 w-full rounded-btn border border-border bg-surface pl-9 pr-3 text-sm text-text-primary placeholder:text-text-secondary focus:border-primary focus:outline-none focus:ring-2 focus:ring-primary/30"
        />
      </div>

      <div className="ml-auto flex items-center gap-1">
        <button className="relative grid h-9 w-9 place-items-center rounded-btn text-text-secondary hover:bg-border/50">
          <Bell className="h-5 w-5" />
          <span className="absolute right-2 top-2 h-2 w-2 rounded-full bg-danger" />
        </button>
        <ThemeToggle />
        <div className="relative">
          <button
            onClick={() => setMenuOpen((o) => !o)}
            className="flex items-center gap-2 rounded-btn px-1.5 py-1 hover:bg-border/40"
          >
            <Avatar name={user?.name} src={user?.profile_photo_url} size={32} />
            <span className="hidden text-sm font-medium text-text-primary sm:block">
              {user?.name || 'Admin'}
            </span>
          </button>
          {menuOpen && (
            <>
              <div className="fixed inset-0 z-10" onClick={() => setMenuOpen(false)} />
              <div className="absolute right-0 z-20 mt-2 w-44 rounded-card border border-border bg-card p-1 shadow-card">
                <div className="px-3 py-2 text-xs text-text-secondary">
                  {user?.email}
                </div>
                <button
                  onClick={logout}
                  className="flex w-full items-center gap-2 rounded-btn px-3 py-2 text-sm text-danger hover:bg-danger/10"
                >
                  <LogOut className="h-4 w-4" /> Sign out
                </button>
              </div>
            </>
          )}
        </div>
      </div>
    </header>
  );
}
