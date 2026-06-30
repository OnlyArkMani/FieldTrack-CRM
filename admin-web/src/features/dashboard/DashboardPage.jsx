import {
  PieChart,
  Pie,
  Cell,
  ResponsiveContainer,
  Legend,
  Tooltip,
} from 'recharts';
import { Users, UserCheck, UserX, Activity, Route, MapPin, TrendingUp, ClipboardList, BellRing } from 'lucide-react';
import { useNavigate } from 'react-router-dom';

import { useDashboard } from '@/hooks/useDashboard';
import { useCrmDashboard } from '@/hooks/useCrm';
import Card, { CardHeader } from '@/components/ui/Card';
import Badge from '@/components/ui/Badge';
import Table from '@/components/ui/Table';
import Avatar from '@/components/ui/Avatar';
import PageHeader from '@/components/ui/PageHeader';
import LeadPipelineCard from '@/features/leads/LeadPipelineCard';

function StatCard({ icon: Icon, label, value, hint, tone = 'primary', onClick }) {
  const toneBg = {
    primary: 'bg-primary/15 text-primary',
    active: 'bg-status-active/15 text-status-active',
    danger: 'bg-danger/15 text-danger',
    secondary: 'bg-secondary/15 text-secondary',
    amber: 'bg-amber-100 text-amber-600',
  }[tone] || 'bg-primary/15 text-primary';
  return (
    <Card
      className={`flex items-center gap-4 ${onClick ? 'cursor-pointer hover:shadow-md transition-shadow' : ''}`}
      onClick={onClick}
    >
      <div className={`grid h-12 w-12 place-items-center rounded-btn ${toneBg}`}>
        <Icon className="h-6 w-6" />
      </div>
      <div className="min-w-0">
        <div className="truncate text-2xl font-bold text-text-primary">{value}</div>
        <div className="truncate text-sm text-text-secondary">{label}</div>
        {hint && <div className="truncate text-xs text-text-secondary">{hint}</div>}
      </div>
    </Card>
  );
}

const fmtLoc = (e) =>
  e.live?.last_seen && e.live?.live_status !== 'OFFLINE'
    ? 'Live'
    : '—';

export default function DashboardPage() {
  const { data, isLoading } = useDashboard();
  const { data: crm } = useCrmDashboard();
  const navigate = useNavigate();
  const d = data || {};
  const c = crm || {};

  const columns = [
    {
      key: 'name',
      header: 'Employee',
      render: (e) => (
        <div className="flex items-center gap-2">
          <Avatar name={e.name} src={e.profile_photo_url} size={30} />
          <div className="min-w-0">
            <div className="truncate font-medium text-text-primary">{e.name}</div>
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
      render: (e) => <span className="text-text-secondary">{fmtLoc(e)}</span>,
    },
    {
      key: 'attendance',
      header: 'Attendance',
      render: (e) => {
        const s = e.live?.current_state || 'NULL';
        const label =
          s === 'STARTED' || s === 'RESUMED'
            ? 'Working'
            : s === 'ON_BREAK'
              ? 'On break'
              : s === 'ENDED'
                ? 'Ended'
                : 'Not started';
        return <span className="text-text-primary">{label}</span>;
      },
    },
  ];

  return (
    <div className="space-y-6">
      <PageHeader title="Dashboard" subtitle="Live overview of your workforce" />

      {/* Workforce stats */}
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-4">
        <StatCard icon={Users} label="Total Employees" value={d.totalEmployees ?? '—'} />
        <StatCard
          icon={UserCheck}
          tone="active"
          label="Present Today"
          value={d.presentToday ?? '—'}
        />
        <StatCard icon={UserX} tone="danger" label="Absent" value={d.absentToday ?? '—'} />
        <StatCard
          icon={Activity}
          tone="secondary"
          label="Active Field Staff"
          value={d.activeFieldStaff ?? '—'}
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

      <div className="grid grid-cols-1 gap-6 lg:grid-cols-3">
        <Card className="lg:col-span-1">
          <CardHeader title="Status breakdown" subtitle="Active / Idle / Offline" />
          <div className="h-56">
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
          </div>
          <div className="mt-2 flex items-center justify-center gap-2 text-sm text-text-secondary">
            <Route className="h-4 w-4" />
            <span>
              {(d.distanceTodayKm ?? 0).toFixed(1)} km covered today (team total)
            </span>
          </div>
        </Card>

        <Card className="lg:col-span-2" padded={false}>
          <div className="p-5 pb-3">
            <CardHeader
              title="Live activity"
              subtitle="Refreshes every 30 seconds"
            />
          </div>
          <Table
            columns={columns}
            rows={d.liveEmployees || []}
            loading={isLoading}
            empty="No employees yet"
          />
        </Card>
      </div>

      <LeadPipelineCard />
    </div>
  );
}
