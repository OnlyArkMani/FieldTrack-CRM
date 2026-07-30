import { useState } from 'react';
import dayjs from 'dayjs';
import { AlertTriangle } from 'lucide-react';
import clsx from 'clsx';

import { useAttendanceForDate } from '@/hooks/useAttendance';
import PageHeader from '@/components/ui/PageHeader';
import Card from '@/components/ui/Card';
import Table from '@/components/ui/Table';
import Badge from '@/components/ui/Badge';
import Avatar from '@/components/ui/Avatar';
import { Input } from '@/components/ui/Input';
import OverrideModal from './OverrideModal';

const fmtTime = (sessions, type) => {
  const list = (sessions || []).filter((s) => s.type === type);
  if (!list.length) return '—';
  const ts = type === 'END' ? list[list.length - 1].timestamp : list[0].timestamp;
  return dayjs(ts).format('HH:mm');
};

const fmtDuration = (mins) => {
  if (!mins) return '—';
  const h = Math.floor(mins / 60);
  const m = mins % 60;
  return h ? `${h}h ${m}m` : `${m}m`;
};

export default function AttendancePage() {
  const [date, setDate] = useState(dayjs().format('YYYY-MM-DD'));
  const { data, isLoading } = useAttendanceForDate(date);
  const [override, setOverride] = useState(null);
  const [tab, setTab] = useState('ALL');

  const allRows = data?.items || [];
  const rows = allRows.filter((r) => {
    if (tab === 'PRESENT') return r.status === 'PRESENT' || r.status === 'HALF_DAY';
    if (tab === 'ABSENT') return r.status === 'ABSENT';
    return true;
  });

  const columns = [
    {
      key: 'employee',
      header: 'Employee',
      render: (r) => (
        <div className="flex items-center gap-2">
          <Avatar name={r.employee?.name} src={r.employee?.profile_photo_url} size={30} />
          <div className="min-w-0">
            <div className="flex items-center gap-1.5">
              <span className="font-medium text-text-primary">
                {r.employee?.name || `#${r.user_id}`}
              </span>
              {r.has_mock_gps && (
                <AlertTriangle className="h-4 w-4 text-danger shrink-0" title="Mock GPS detected" />
              )}
            </div>
            {r.employee?.role && (
              <div className="truncate text-xs text-text-secondary">{r.employee.role}</div>
            )}
          </div>
        </div>
      ),
    },
    { key: 'start', header: 'Start', render: (r) => fmtTime(r.sessions, 'START') },
    { key: 'end', header: 'End', render: (r) => fmtTime(r.sessions, 'END') },
    { key: 'duration', header: 'Duration', render: (r) => fmtDuration(r.total_duration_minutes) },
    {
      key: 'summary',
      header: 'Work summary',
      render: (r) => (
        <span className="line-clamp-1 max-w-xs text-text-secondary">
          {r.work_summary || '—'}
        </span>
      ),
    },
    { key: 'status', header: 'Status', render: (r) => <Badge status={r.status} /> },
  ];

  return (
    <div className="space-y-6">
      <PageHeader
        title="Attendance"
        subtitle="Live roster overview & daily attendance logs"
        actions={
          <div className="w-44">
            <Input type="date" value={date} onChange={(e) => setDate(e.target.value)} />
          </div>
        }
      />

      <div className="flex items-center gap-2">
        <button
          type="button"
          onClick={() => setTab('ALL')}
          className={clsx(
            'px-3 py-1.5 text-xs font-medium rounded-lg transition-colors',
            tab === 'ALL'
              ? 'bg-primary text-white font-semibold'
              : 'bg-surface/60 text-text-secondary hover:text-text-primary',
          )}
        >
          All ({data?.total ?? 0})
        </button>
        <button
          type="button"
          onClick={() => setTab('PRESENT')}
          className={clsx(
            'px-3 py-1.5 text-xs font-medium rounded-lg transition-colors',
            tab === 'PRESENT'
              ? 'bg-status-active text-white font-semibold'
              : 'bg-surface/60 text-text-secondary hover:text-text-primary',
          )}
        >
          Present ({data?.presentCount ?? 0})
        </button>
        <button
          type="button"
          onClick={() => setTab('ABSENT')}
          className={clsx(
            'px-3 py-1.5 text-xs font-medium rounded-lg transition-colors',
            tab === 'ABSENT'
              ? 'bg-danger text-white font-semibold'
              : 'bg-surface/60 text-text-secondary hover:text-text-primary',
          )}
        >
          Absent ({data?.absentCount ?? 0})
        </button>
      </div>

      <Card padded={false}>
        <Table
          columns={columns}
          rows={rows}
          loading={isLoading}
          onRowClick={(r) => r.id && !r.isAbsent && setOverride(r)}
          empty={`No attendance recorded for ${dayjs(date).format('MMM D, YYYY')}`}
        />
      </Card>

      <OverrideModal open={!!override} row={override} onClose={() => setOverride(null)} />
    </div>
  );
}
