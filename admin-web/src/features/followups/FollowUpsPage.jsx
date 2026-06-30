import { useState } from 'react';
import dayjs from 'dayjs';
import { ChevronLeft, ChevronRight } from 'lucide-react';

import { useTeamFollowUps } from '@/hooks/useFollowUps';
import PageHeader from '@/components/ui/PageHeader';
import Card, { CardHeader } from '@/components/ui/Card';
import Badge from '@/components/ui/Badge';
import Spinner from '@/components/ui/Spinner';

const STATUS = {
  PENDING: { color: 'var(--ft-status-battery)', label: 'Pending' },
  ACKNOWLEDGED: { color: 'var(--ft-status-offline)', label: 'Acknowledged' },
  COMPLETED: { color: 'var(--ft-status-active)', label: 'Completed' },
  ESCALATED: { color: 'var(--ft-status-danger)', label: 'Escalated' },
};

export default function FollowUpsPage() {
  const [cursor, setCursor] = useState(dayjs().startOf('month'));
  const [selected, setSelected] = useState(dayjs().format('YYYY-MM-DD'));

  const monthStart = cursor.startOf('month');
  const monthEnd = cursor.endOf('month');
  const { data: items = [], isLoading } = useTeamFollowUps({
    dateFrom: monthStart.format('YYYY-MM-DD'),
    dateTo: monthEnd.format('YYYY-MM-DD'),
  });

  // Group by date.
  const byDate = {};
  for (const f of items) {
    (byDate[f.scheduled_date] ||= []).push(f);
  }

  const daysInMonth = cursor.daysInMonth();
  const leading = monthStart.day(); // 0=Sun
  const cells = [];
  for (let i = 0; i < leading; i += 1) cells.push(null);
  for (let day = 1; day <= daysInMonth; day += 1) {
    cells.push(monthStart.date(day).format('YYYY-MM-DD'));
  }

  const dayItems = byDate[selected] || [];

  return (
    <div className="space-y-6">
      <PageHeader title="Follow-ups" subtitle="Scheduled across your teams" />

      <div className="grid grid-cols-1 gap-6 lg:grid-cols-2">
        <Card>
          <CardHeader
            title={cursor.format('MMMM YYYY')}
            action={
              <div className="flex items-center gap-1">
                <button
                  className="rounded-btn p-1.5 text-text-secondary hover:bg-border/40"
                  onClick={() => setCursor((c) => c.subtract(1, 'month'))}
                >
                  <ChevronLeft className="h-4 w-4" />
                </button>
                <button
                  className="rounded-btn p-1.5 text-text-secondary hover:bg-border/40"
                  onClick={() => setCursor((c) => c.add(1, 'month'))}
                >
                  <ChevronRight className="h-4 w-4" />
                </button>
              </div>
            }
          />
          {isLoading ? (
            <Spinner label="Loading…" className="py-10" />
          ) : (
            <>
              <div className="mb-2 grid grid-cols-7 gap-1 text-center text-xs text-text-secondary">
                {['S', 'M', 'T', 'W', 'T', 'F', 'S'].map((d, i) => (
                  <div key={i}>{d}</div>
                ))}
              </div>
              <div className="grid grid-cols-7 gap-1">
                {cells.map((date, i) =>
                  date === null ? (
                    <div key={i} />
                  ) : (
                    <button
                      key={date}
                      onClick={() => setSelected(date)}
                      className="relative flex aspect-square flex-col items-center justify-center rounded-btn border text-sm transition-colors"
                      style={{
                        borderColor:
                          selected === date ? 'var(--ft-primary)' : 'var(--ft-border)',
                        background:
                          selected === date ? 'var(--ft-primary)18' : 'transparent',
                        color: 'var(--ft-text-primary)',
                      }}
                    >
                      {dayjs(date).date()}
                      {byDate[date] && (
                        <span
                          className="absolute bottom-1 h-1.5 w-1.5 rounded-full"
                          style={{ background: 'var(--ft-primary)' }}
                        />
                      )}
                    </button>
                  ),
                )}
              </div>
            </>
          )}
        </Card>

        <Card>
          <CardHeader
            title={dayjs(selected).format('dddd, MMM D')}
            subtitle={`${dayItems.length} follow-up${dayItems.length === 1 ? '' : 's'}`}
          />
          {dayItems.length === 0 ? (
            <div className="rounded-btn border border-dashed border-border p-6 text-center text-sm text-text-secondary">
              No follow-ups scheduled for this day.
            </div>
          ) : (
            <ol className="space-y-2">
              {dayItems
                .slice()
                .sort((a, b) => (a.scheduled_time || '').localeCompare(b.scheduled_time || ''))
                .map((f) => {
                  const meta = STATUS[f.status] || STATUS.PENDING;
                  return (
                    <li
                      key={f.id}
                      className="flex items-center gap-3 rounded-btn border border-border p-3"
                    >
                      <span className="w-12 shrink-0 text-sm font-medium text-text-secondary">
                        {f.scheduled_time ? f.scheduled_time.slice(0, 5) : '—'}
                      </span>
                      <div className="min-w-0 flex-1">
                        <div className="truncate font-medium text-text-primary">
                          {f.farmer_name || 'Farmer'}
                        </div>
                        <div className="truncate text-xs text-text-secondary">
                          {f.employee_name || '—'}
                          {f.purpose ? ` · ${f.purpose}` : ''}
                        </div>
                      </div>
                      <Badge color={meta.color}>{meta.label}</Badge>
                    </li>
                  );
                })}
            </ol>
          )}
        </Card>
      </div>
    </div>
  );
}
