import {
  PieChart,
  Pie,
  Cell,
  ResponsiveContainer,
  Legend,
  Tooltip,
} from 'recharts';
import {
  Users,
  UserCheck,
  UserX,
  Activity,
  Route,
  MapPin,
  TrendingUp,
  ClipboardList,
  BellRing,
  ChevronRight,
} from 'lucide-react';
import { useNavigate } from 'react-router-dom';
import clsx from 'clsx';

import { useDashboard, useTeamOrdersSummary } from '@/hooks/useDashboard';
import { useCrmDashboard } from '@/hooks/useCrm';
import Card, { CardHeader } from '@/components/ui/Card';
import Badge from '@/components/ui/Badge';
import Table from '@/components/ui/Table';
import Avatar from '@/components/ui/Avatar';
import PageHeader from '@/components/ui/PageHeader';
import LeadPipelineCard from '@/features/leads/LeadPipelineCard';

function StatCard({ icon: Icon, label, value, hint, tone = 'primary', onClick }) {
  const toneBg =
    {
      primary: 'bg-primary/15 text-primary',
      active: 'bg-status-active/15 text-status-active',
      danger: 'bg-danger/15 text-danger',
      secondary: 'bg-secondary/15 text-secondary',
      amber: 'bg-amber-500/15 text-amber-500',
    }[tone] || 'bg-primary/15 text-primary';

  return (
    <Card
      className={clsx(
        'group flex items-center justify-between gap-4 transition-all duration-200',
        onClick &&
          'cursor-pointer hover:border-primary/40 hover:shadow-md hover:-translate-y-0.5 active:translate-y-0',
      )}
      onClick={onClick}
    >
      <div className="flex items-center gap-4 min-w-0">
        <div
          className={`grid h-12 w-12 shrink-0 place-items-center rounded-btn ${toneBg} transition-transform group-hover:scale-105`}
        >
          <Icon className="h-6 w-6" />
        </div>
        <div className="min-w-0">
          <div className="truncate text-2xl font-bold text-text-primary">{value}</div>
          <div className="truncate text-sm text-text-secondary">{label}</div>
          {hint && <div className="truncate text-xs text-text-secondary/80">{hint}</div>}
        </div>
      </div>
      {onClick && (
        <ChevronRight className="h-4 w-4 shrink-0 text-text-secondary/40 transition-colors group-hover:text-primary group-hover:translate-x-0.5 transform duration-150" />
      )}
    </Card>
  );
}

export default function DashboardPage() {
  const { data, isLoading } = useDashboard();
  const { data: crm } = useCrmDashboard();
  const { data: teamOrders, isLoading: teamOrdersLoading } = useTeamOrdersSummary();
  const navigate = useNavigate();
  const d = data || {};
  const c = crm || {};

  const teamOrdersColumns = [
    { key: 'team_name', header: 'Team' },
    {
      key: 'target_order_bags',
      header: 'Target Bags (Today)',
      align: 'right',
      render: (t) => (t.target_order_bags ?? 0).toLocaleString(),
    },
    {
      key: 'completed_order_bags',
      header: 'Completed Bags (Today)',
      align: 'right',
      render: (t) => (t.completed_order_bags ?? 0).toLocaleString(),
    },
    {
      key: 'progress',
      header: 'Progress',
      align: 'right',
      render: (t) =>
        t.target_order_bags > 0
          ? `${Math.round((t.completed_order_bags / t.target_order_bags) * 100)}%`
          : '—',
    },
  ];

  const columns = [
    {
      key: 'name',
      header: 'Employee',
      render: (e) => (
        <div className="flex items-center gap-2">
          <Avatar name={e.name} src={e.profile_photo_url} size={30} />
          <div className="min-w-0">
            <div className="truncate font-medium text-text-primary group-hover:text-primary transition-colors">
              {e.name}
            </div>
            <div className="truncate text-xs text-text-secondary">{e.role}</div>
          </div>
        </div>
      ),
    },
    {
      key: 'status',
      header: 'Status',
      render: (e) => <Badge status={e.live?.live_status || 'OFFLINE'} />,
    },
    {
      key: 'loc',
      header: 'Location',
      render: (e) => {
        const isLive = e.live?.last_seen && e.live?.live_status !== 'OFFLINE';
        return isLive ? (
          <button
            type="button"
            onClick={(evt) => {
              evt.stopPropagation();
              navigate('/map');
            }}
            className="inline-flex items-center gap-1 text-primary hover:underline font-medium text-xs bg-primary/10 hover:bg-primary/20 px-2 py-0.5 rounded-full transition-colors"
          >
            <MapPin className="h-3 w-3" />
            Live
          </button>
        ) : (
          <span className="text-text-secondary">—</span>
        );
      },
    },
    {
      key: 'attendance',
      header: 'Attendance',
      render: (e) => {
        const s = e.live?.current_state || 'NULL';
        const ATTENDANCE_LABELS = {
          STARTED: 'Working',
          RESUMED: 'Working',
          ON_BREAK: 'On break',
          ENDED: 'Ended',
        };
        const label = ATTENDANCE_LABELS[s] || 'Not started';
        return <span className="text-text-primary">{label}</span>;
      },
    },
  ];

  return (
    <div className="space-y-6">
      <PageHeader title="Dashboard" subtitle="Live overview of your workforce" />

      {/* Workforce stats */}
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-4">
        <StatCard
          icon={Users}
          label="Total Employees"
          value={d.totalEmployees ?? '—'}
          onClick={() => navigate('/employees')}
        />
        <StatCard
          icon={UserCheck}
          tone="active"
          label="Present Today"
          value={d.presentToday ?? '—'}
          onClick={() => navigate('/attendance')}
        />
        <StatCard
          icon={UserX}
          tone="danger"
          label="Absent"
          value={d.absentToday ?? '—'}
          onClick={() => navigate('/attendance')}
        />
        <StatCard
          icon={Activity}
          tone="secondary"
          label="Active Field Staff"
          value={d.activeFieldStaff ?? '—'}
          onClick={() => navigate('/map')}
        />
      </div>

      {/* CRM snapshot */}
      <div>
        <h2 className="mb-3 text-sm font-semibold uppercase tracking-widest text-text-secondary/70">
          CRM Today
        </h2>
        <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-4">
          <StatCard
            icon={MapPin}
            tone="active"
            label="Visits Today"
            value={c.todayVisits ?? '—'}
            onClick={() => navigate('/planning')}
          />
          <StatCard
            icon={TrendingUp}
            tone="primary"
            label="Active Leads"
            value={c.activeLeadsTotal ?? '—'}
            hint={
              c.activeLeadsTotal != null
                ? `${c.activeLeadsHot ?? 0}H · ${c.activeLeadsWarm ?? 0}W · ${c.activeLeadsCold ?? 0}C`
                : undefined
            }
            onClick={() => navigate('/leads')}
          />
          <StatCard
            icon={ClipboardList}
            tone="secondary"
            label="DSRs Submitted"
            value={
              c.dsrsTotalToday != null
                ? `${c.dsrsSubmittedToday ?? 0}/${c.dsrsTotalToday}`
                : '—'
            }
            onClick={() => navigate('/daily-reports')}
          />
          <StatCard
            icon={BellRing}
            tone="amber"
            label="Follow-ups Today"
            value={c.followUpsToday ?? '—'}
            onClick={() => navigate('/follow-ups')}
          />
        </div>
      </div>

      {/* Middle row: Status Breakdown & Live Activity */}
      <div className="grid grid-cols-1 gap-6 lg:grid-cols-3">
        <Card className="lg:col-span-1 flex flex-col justify-between h-full">
          <CardHeader
            title="Status breakdown"
            subtitle="Active / Idle / Offline"
            action={
              <button
                type="button"
                onClick={() => navigate('/map')}
                className="inline-flex items-center gap-0.5 text-xs font-medium text-primary hover:underline"
              >
                Live Map <ChevronRight className="h-3 w-3" />
              </button>
            }
          />
          <button
            type="button"
            className="flex-1 min-h-[220px] w-full flex items-center justify-center text-left cursor-pointer focus:outline-none py-2"
            onClick={() => navigate('/map')}
            aria-label="View status breakdown on live map"
          >
            <ResponsiveContainer width="100%" height="100%">
              <PieChart>
                <Pie
                  data={d.statusBreakdown || []}
                  dataKey="value"
                  nameKey="name"
                  innerRadius={55}
                  outerRadius={80}
                  paddingAngle={2}
                  stroke="none"
                >
                  {(d.statusBreakdown || []).map((s) => (
                    <Cell key={s.name} fill={s.color} />
                  ))}
                </Pie>
                <Tooltip
                  contentStyle={{
                    background: 'var(--ft-card)',
                    border: '1px solid var(--ft-border)',
                    borderRadius: 12,
                    color: 'var(--ft-text)',
                  }}
                />
                <Legend />
              </PieChart>
            </ResponsiveContainer>
          </button>
          <button
            type="button"
            onClick={() => navigate('/map')}
            className="mt-auto flex items-center justify-center gap-2 rounded-lg p-2.5 text-sm text-text-secondary transition-colors hover:bg-surface/60 hover:text-primary border border-border/40 hover:border-border/80"
          >
            <Route className="h-4 w-4" />
            <span>
              {(d.distanceTodayKm ?? 0).toFixed(1)} km covered today (team total)
            </span>
            <ChevronRight className="h-3.5 w-3.5" />
          </button>
        </Card>

        <Card className="lg:col-span-2 overflow-hidden" padded={false}>
          <div className="p-5 pb-3">
            <CardHeader
              title="Live activity"
              subtitle="Refreshes every 30 seconds"
              action={
                <button
                  type="button"
                  onClick={() => navigate('/employees')}
                  className="inline-flex items-center gap-0.5 text-xs font-medium text-primary hover:underline"
                >
                  View Employees <ChevronRight className="h-3 w-3" />
                </button>
              }
            />
          </div>
          <Table
            columns={columns}
            rows={d.liveEmployees || []}
            loading={isLoading}
            empty="No employees yet"
            onRowClick={(emp) =>
              navigate(emp.id ? `/employees/${emp.id}` : '/employees')
            }
            containerClassName="max-h-[380px] overflow-y-auto"
          />
        </Card>
      </div>

      {/* Team Orders Today */}
      <Card padded={false} className="overflow-hidden">
        <div className="p-5 pb-3">
          <CardHeader
            title="Team Orders Today"
            subtitle="Target bags (from visit plans) vs bags actually captured, per team"
            action={
              <button
                type="button"
                onClick={() => navigate('/orders')}
                className="inline-flex items-center gap-0.5 text-xs font-medium text-primary hover:underline"
              >
                View Orders <ChevronRight className="h-3 w-3" />
              </button>
            }
          />
        </div>
        <Table
          columns={teamOrdersColumns}
          rows={teamOrders || []}
          rowKey={(t) => t.team_id || t.team_name}
          loading={teamOrdersLoading}
          empty="No teams yet"
          onRowClick={() => navigate('/teams')}
          containerClassName="max-h-[300px] overflow-y-auto"
        />
      </Card>

      {/* Lead Pipeline */}
      <LeadPipelineCard />
    </div>
  );
}
