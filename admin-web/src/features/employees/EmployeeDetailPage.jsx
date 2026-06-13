import { useState } from 'react';
import { useParams, useNavigate } from 'react-router-dom';
import dayjs from 'dayjs';
import {
  ArrowLeft,
  ChevronLeft,
  ChevronRight,
  Power,
  Pencil,
  ShieldAlert,
  ShieldCheck,
  MapPin,
} from 'lucide-react';

import {
  useEmployee,
  useAttendanceSummary,
  useSetEmployeeStatus,
  useGpsIntegrity,
} from '@/hooks/useEmployees';
import { useTeams } from '@/hooks/useTeams';
import { apiErrorMessage } from '@/services/api/client';

import Card, { CardHeader } from '@/components/ui/Card';
import Button from '@/components/ui/Button';
import Badge from '@/components/ui/Badge';
import Avatar from '@/components/ui/Avatar';
import Spinner from '@/components/ui/Spinner';
import EmployeeFormModal from './EmployeeFormModal';
import TrailReplayModal from '@/features/map/TrailReplayModal';

const STATUS_COLOR = {
  PRESENT: 'var(--ft-status-active)',
  ABSENT: 'var(--ft-status-danger)',
  HALF_DAY: 'var(--ft-status-battery)',
};

function AttendanceCalendar({ summary, cursor }) {
  const byDate = {};
  for (const d of summary?.days || []) byDate[d.date] = d.status;

  const start = cursor.startOf('month');
  const daysInMonth = cursor.daysInMonth();
  const leadingBlanks = start.day(); // 0=Sun

  const cells = [];
  for (let i = 0; i < leadingBlanks; i += 1) cells.push(null);
  for (let day = 1; day <= daysInMonth; day += 1) {
    const date = start.date(day).format('YYYY-MM-DD');
    cells.push({ day, status: byDate[date] });
  }

  return (
    <div>
      <div className="mb-2 grid grid-cols-7 gap-1 text-center text-xs text-text-secondary">
        {['S', 'M', 'T', 'W', 'T', 'F', 'S'].map((d, i) => (
          <div key={i}>{d}</div>
        ))}
      </div>
      <div className="grid grid-cols-7 gap-1">
        {cells.map((c, i) =>
          c === null ? (
            <div key={i} />
          ) : (
            <div
              key={i}
              className="flex aspect-square items-center justify-center rounded-btn text-sm"
              style={{
                background: c.status ? `${STATUS_COLOR[c.status]}26` : 'var(--ft-surface)',
                color: c.status ? STATUS_COLOR[c.status] : 'var(--ft-text-secondary)',
                border: '1px solid var(--ft-border)',
              }}
              title={c.status || 'No record'}
            >
              {c.day}
            </div>
          ),
        )}
      </div>
      <div className="mt-4 flex flex-wrap gap-4 text-xs">
        {[
          ['Present', STATUS_COLOR.PRESENT],
          ['Half day', STATUS_COLOR.HALF_DAY],
          ['Absent', STATUS_COLOR.ABSENT],
        ].map(([label, color]) => (
          <span key={label} className="flex items-center gap-1.5 text-text-secondary">
            <span className="h-3 w-3 rounded" style={{ background: color }} />
            {label}
          </span>
        ))}
      </div>
    </div>
  );
}

export default function EmployeeDetailPage() {
  const { id } = useParams();
  const navigate = useNavigate();
  const { data: employee, isLoading } = useEmployee(id);
  const { data: teams = [] } = useTeams();
  const setActive = useSetEmployeeStatus();
  const [cursor, setCursor] = useState(dayjs());
  const [editing, setEditing] = useState(false);
  const [trailOpen, setTrailOpen] = useState(false);

  const summaryQ = useAttendanceSummary(id, cursor.year(), cursor.month() + 1);

  if (isLoading || !employee) {
    return <Spinner label="Loading employee…" className="py-20" />;
  }

  const toggle = async () => {
    try {
      await setActive.mutateAsync({ id: employee.id, isActive: !employee.is_active });
    } catch (err) {
      alert(apiErrorMessage(err));
    }
  };

  const teamName = teams.find((t) => t.id === employee.team_id)?.name;

  return (
    <div className="space-y-6">
      <button
        onClick={() => navigate('/employees')}
        className="flex items-center gap-1 text-sm text-text-secondary hover:text-text-primary"
      >
        <ArrowLeft className="h-4 w-4" /> Back to employees
      </button>

      <div className="grid grid-cols-1 gap-6 lg:grid-cols-3">
        <Card className="lg:col-span-1">
          <div className="flex items-center gap-3">
            <Avatar name={employee.name} src={employee.profile_photo_url} size={56} />
            <div className="min-w-0">
              <h2 className="truncate text-lg font-semibold text-text-primary">
                {employee.name}
              </h2>
              <div className="mt-1 flex items-center gap-2">
                <Badge status={employee.live?.live_status || 'OFFLINE'} />
                <span className="text-xs text-text-secondary">
                  {employee.role?.toLowerCase()}
                </span>
              </div>
            </div>
          </div>

          <dl className="mt-5 space-y-3 text-sm">
            <Row label="Email" value={employee.email} />
            <Row label="Phone" value={employee.phone || '—'} />
            <Row label="Team" value={teamName || '—'} />
            <Row
              label="Account"
              value={employee.is_active ? 'Active' : 'Inactive'}
            />
          </dl>

          <div className="mt-5 flex gap-2">
            <Button variant="outline" icon={Pencil} onClick={() => setEditing(true)} className="flex-1">
              Edit
            </Button>
            <Button
              variant={employee.is_active ? 'danger' : 'primary'}
              icon={Power}
              loading={setActive.isPending}
              onClick={toggle}
              className="flex-1"
            >
              {employee.is_active ? 'Deactivate' : 'Activate'}
            </Button>
          </div>

          <Button
            variant="secondary"
            icon={MapPin}
            onClick={() => setTrailOpen(true)}
            className="mt-2 w-full"
          >
            View Trail
          </Button>
        </Card>

        <Card className="lg:col-span-2">
          <CardHeader
            title="Attendance history"
            action={
              <div className="flex items-center gap-2">
                <Button size="sm" variant="ghost" icon={ChevronLeft}
                  onClick={() => setCursor((c) => c.subtract(1, 'month'))} />
                <span className="text-sm font-medium text-text-primary">
                  {cursor.format('MMMM YYYY')}
                </span>
                <Button size="sm" variant="ghost" icon={ChevronRight}
                  onClick={() => setCursor((c) => c.add(1, 'month'))} />
              </div>
            }
          />
          {summaryQ.isLoading ? (
            <Spinner label="Loading…" className="py-10" />
          ) : (
            <>
              <div className="mb-4 grid grid-cols-3 gap-3">
                <Mini label="Present" value={summaryQ.data?.days_present ?? 0} color={STATUS_COLOR.PRESENT} />
                <Mini label="Half day" value={summaryQ.data?.days_half ?? 0} color={STATUS_COLOR.HALF_DAY} />
                <Mini label="Absent" value={summaryQ.data?.days_absent ?? 0} color={STATUS_COLOR.ABSENT} />
              </div>
              <AttendanceCalendar summary={summaryQ.data} cursor={cursor} />
            </>
          )}
        </Card>
      </div>

      <GpsIntegrityCard employeeId={employee.id} />

      <EmployeeFormModal open={editing} employee={employee} onClose={() => setEditing(false)} />
      <TrailReplayModal
        open={trailOpen}
        onClose={() => setTrailOpen(false)}
        employee={employee}
      />
    </div>
  );
}

function GpsIntegrityCard({ employeeId }) {
  const { data, isLoading } = useGpsIntegrity(employeeId);
  const flaggedToday = data?.flagged_today;
  const detections = data?.detections ?? 0;
  const points = data?.points || [];

  return (
    <Card>
      <CardHeader
        title="GPS integrity"
        subtitle={`Mock-location detections · last ${data?.window_days ?? 7} days`}
        action={
          isLoading ? null : flaggedToday ? (
            <Badge color="var(--ft-status-danger)">
              <span className="flex items-center gap-1">
                <ShieldAlert className="h-3.5 w-3.5" /> Flagged today
              </span>
            </Badge>
          ) : detections > 0 ? (
            <Badge color="var(--ft-status-battery)">Past detections</Badge>
          ) : (
            <Badge color="var(--ft-status-active)">
              <span className="flex items-center gap-1">
                <ShieldCheck className="h-3.5 w-3.5" /> Clean
              </span>
            </Badge>
          )
        }
      />

      {isLoading ? (
        <Spinner label="Loading…" className="py-8" />
      ) : (
        <>
          <div className="mb-4 grid grid-cols-2 gap-3">
            <Mini
              label="Detections (7d)"
              value={detections}
              color={detections > 0 ? 'var(--ft-status-danger)' : 'var(--ft-status-active)'}
            />
            <Mini
              label="Today"
              value={flaggedToday ? 'Yes' : 'No'}
              color={flaggedToday ? 'var(--ft-status-danger)' : 'var(--ft-status-active)'}
            />
          </div>

          {points.length === 0 ? (
            <div className="rounded-btn border border-border p-6 text-center text-sm text-text-secondary">
              No mock-GPS activity detected. Location data looks authentic.
            </div>
          ) : (
            <ol className="space-y-2">
              {points.map((p, i) => (
                <li
                  key={i}
                  className="flex items-center gap-3 rounded-btn border border-border p-3"
                >
                  <span
                    className="flex h-8 w-8 shrink-0 items-center justify-center rounded-full border"
                    style={{ borderColor: 'var(--ft-status-danger)' }}
                  >
                    <MapPin className="h-4 w-4" style={{ color: 'var(--ft-status-danger)' }} />
                  </span>
                  <div className="min-w-0 flex-1">
                    <div className="truncate text-sm font-medium text-text-primary">
                      {dayjs(p.timestamp).format('MMM D, YYYY · HH:mm')}
                    </div>
                    <div className="truncate text-xs text-text-secondary">
                      {p.lat.toFixed(5)}, {p.lng.toFixed(5)}
                      {p.accuracy != null ? ` · ±${Math.round(p.accuracy)}m` : ''}
                      {p.battery_level != null ? ` · ${p.battery_level}% battery` : ''}
                    </div>
                  </div>
                </li>
              ))}
            </ol>
          )}
        </>
      )}
    </Card>
  );
}

function Row({ label, value }) {
  return (
    <div className="flex items-center justify-between gap-3">
      <dt className="text-text-secondary">{label}</dt>
      <dd className="truncate text-right font-medium text-text-primary">{value}</dd>
    </div>
  );
}

function Mini({ label, value, color }) {
  return (
    <div className="rounded-btn border border-border p-3 text-center">
      <div className="text-xl font-bold" style={{ color }}>
        {value}
      </div>
      <div className="text-xs text-text-secondary">{label}</div>
    </div>
  );
}
