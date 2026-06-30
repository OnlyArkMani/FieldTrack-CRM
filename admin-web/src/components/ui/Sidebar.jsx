import { NavLink } from 'react-router-dom';
import clsx from 'clsx';
import {
  LayoutDashboard,
  Users,
  Sprout,
  CalendarCheck,
  BellRing,
  Boxes,
  Fingerprint,
  Map,
  Hexagon,
  FileBarChart,
  ClipboardList,
  TrendingUp,
  Settings,
  Radio,
  ChevronLeft,
  X,
} from 'lucide-react';

import { useUiStore } from '@/store/uiStore';

// NAV uses either a route object or a section divider { section: label }
const NAV = [
  { to: '/', label: 'Dashboard', icon: LayoutDashboard, end: true },
  { to: '/employees', label: 'Employees', icon: Users },
  { to: '/teams', label: 'Teams', icon: Boxes },
  { to: '/attendance', label: 'Attendance', icon: Fingerprint },
  { to: '/map', label: 'Live Map', icon: Map },
  { to: '/geofences', label: 'Geofences', icon: Hexagon },
  { to: '/reports', label: 'Reports', icon: FileBarChart },
  { section: 'CRM' },
  { to: '/farmers', label: 'Farmers', icon: Sprout },
  { to: '/planning', label: 'Visit Plans', icon: CalendarCheck },
  { to: '/leads', label: 'Lead Pipeline', icon: TrendingUp },
  { to: '/follow-ups', label: 'Follow-ups', icon: BellRing },
  { to: '/daily-reports', label: 'Daily Reports', icon: ClipboardList },
  { to: '/settings', label: 'Settings', icon: Settings },
  { to: '/settings/gps', label: 'GPS Tracking', icon: Radio },
];

function NavItems({ collapsed, onNavigate }) {
  return (
    <nav className="flex flex-1 flex-col gap-1 px-3 overflow-y-auto">
      {NAV.map((item, idx) => {
        if (item.section) {
          if (collapsed) {
            return (
              <div key={`section-${idx}`} className="my-1 mx-auto h-px w-6 bg-border" />
            );
          }
          return (
            <div
              key={`section-${idx}`}
              className="mt-3 mb-1 px-3 text-[10px] font-semibold uppercase tracking-widest text-text-secondary/60"
            >
              {item.section}
            </div>
          );
        }
        const { to, label, icon: Icon, end } = item;
        return (
          <NavLink
            key={to}
            to={to}
            end={end}
            onClick={onNavigate}
            className={({ isActive }) =>
              clsx(
                'flex items-center gap-3 rounded-btn px-3 py-2.5 text-sm font-medium transition-colors',
                isActive
                  ? 'bg-primary/16 text-primary'
                  : 'text-text-secondary hover:bg-border/40 hover:text-text-primary',
                collapsed && 'justify-center px-2',
              )
            }
            title={collapsed ? label : undefined}
          >
            <Icon className="h-5 w-5 shrink-0" />
            {!collapsed && <span className="truncate">{label}</span>}
          </NavLink>
        );
      })}
    </nav>
  );
}

function Brand({ collapsed }) {
  return (
    <div className={clsx('flex items-center gap-2 px-5 py-5', collapsed && 'justify-center px-2')}>
      <div className="grid h-9 w-9 shrink-0 place-items-center rounded-btn bg-primary text-primary-fg font-bold">
        F
      </div>
      {!collapsed && (
        <span className="text-lg font-bold text-text-primary">FieldTrack</span>
      )}
    </div>
  );
}

export default function Sidebar() {
  const collapsed = useUiStore((s) => s.sidebarCollapsed);
  const toggle = useUiStore((s) => s.toggleSidebar);
  const mobileOpen = useUiStore((s) => s.sidebarMobileOpen);
  const setMobileOpen = useUiStore((s) => s.setSidebarMobileOpen);

  return (
    <>
      {/* Desktop sidebar */}
      <aside
        className={clsx(
          'hidden md:flex flex-col border-r border-border bg-card transition-all duration-200',
          collapsed ? 'w-[72px]' : 'w-60',
        )}
      >
        <Brand collapsed={collapsed} />
        <NavItems collapsed={collapsed} />
        <button
          onClick={toggle}
          className="m-3 flex items-center justify-center gap-2 rounded-btn px-3 py-2 text-sm text-text-secondary hover:bg-border/40"
        >
          <ChevronLeft
            className={clsx('h-4 w-4 transition-transform', collapsed && 'rotate-180')}
          />
          {!collapsed && <span>Collapse</span>}
        </button>
      </aside>

      {/* Mobile drawer */}
      {mobileOpen && (
        <div className="fixed inset-0 z-40 md:hidden">
          <div
            className="absolute inset-0 bg-black/40"
            onClick={() => setMobileOpen(false)}
          />
          <aside className="absolute left-0 top-0 flex h-full w-64 flex-col bg-card shadow-card">
            <div className="flex items-center justify-between pr-3">
              <Brand collapsed={false} />
              <button
                onClick={() => setMobileOpen(false)}
                className="rounded-btn p-1 text-text-secondary hover:bg-border/50"
              >
                <X className="h-5 w-5" />
              </button>
            </div>
            <NavItems collapsed={false} onNavigate={() => setMobileOpen(false)} />
          </aside>
        </div>
      )}
    </>
  );
}
