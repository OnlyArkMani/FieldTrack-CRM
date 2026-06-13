import { useState } from 'react';
import dayjs from 'dayjs';
import { AlertTriangle } from 'lucide-react';

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

  const rows = data?.items || [];

  const columns = [
    {
      key: 'employee',
      header: 'Employee',
      render: (r) => (
        <div className="flex items-center gap-2">
          <Avatar name={r.employee?.name} src={r.employee?.profile_photo_url} size={30} />
          <div className="flex items-center gap-1.5">
            <span className="font-medium text-text-primary">
              {r.employee?.name || `#${r.user_id}`}
            </span>
            {r.has_mock_gps && (
              <AlertTriangle className="h-4 w-4 text-danger" title="Mock GPS detected" />
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
        subtitle="Click any row to override status or add a manual session"
        actions={
          <div className="w-44">
            <Input type="date" value={date} onChange={(e) => setDate(e.target.value)} />
          </div>
        }
      />

      <Card padded={false}>
        <Table
          columns={columns}
          rows={rows}
          loading={isLoading}
          onRowClick={(r) => r.id && setOverride(r)}
          empty={`No attendance recorded for ${dayjs(date).format('MMM D, YYYY')}`}
        />
      </Card>

      <OverrideModal open={!!override} row={override} onClose={() => setOverride(null)} />
    </div>
  );
}
