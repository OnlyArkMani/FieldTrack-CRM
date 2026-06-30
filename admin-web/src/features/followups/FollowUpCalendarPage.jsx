import { useState, useMemo } from 'react';
import { ChevronLeft, ChevronRight, CheckCircle2, Clock, AlertCircle } from 'lucide-react';
import dayjs from 'dayjs';

import { useTeamFollowUps } from '@/hooks/useFollowUps';
import Card, { CardHeader } from '@/components/ui/Card';
import PageHeader from '@/components/ui/PageHeader';
import Spinner from '@/components/ui/Spinner';

const STATUS_CFG = {
  DONE:      { icon: CheckCircle2, color: 'var(--ft-status-active)',  label: 'Done' },
  PENDING:   { icon: Clock,        color: 'var(--ft-primary)',        label: 'Pending' },
  ESCALATED: { icon: AlertCircle,  color: 'var(--ft-status-danger)',  label: 'Escalated' },
};

function FollowUpItem({ fu }) {
  const cfg = STATUS_CFG[fu.status] || STATUS_CFG.PENDING;
  const Icon = cfg.icon;
  return (
    <div className="flex items-start gap-3 rounded-card border border-border p-3">
      <Icon className="mt-0.5 h-4 w-4 shrink-0" style={{ color: cfg.color }} />
      <div className="min-w-0 flex-1">
        <div className="truncate font-medium text-text-primary">
          {fu.farmer_name ?? `Farmer #${fu.farmer_id}`}
        </div>
        <div className="truncate text-xs text-text-secondary">
          {fu.employee_name ?? `Employee #${fu.employee_id}`}
          {fu.scheduled_time ? ` · ${fu.scheduled_time.slice(0, 5)}` : ''}
        </div>
        {fu.purpose && (
          <div className="mt-1 truncate text-xs text-text-secondary">{fu.purpose}</div>
        )}
      </div>
      <span className="shrink-0 text-xs font-medium" style={{ color: cfg.color }}>
        {cfg.label}
      </span>
    </div>
  );
}

export default function FollowUpCalendarPage() {
  const [cursor, setCursor] = useState(dayjs().startOf('month'));
  const [selectedDate, setSelectedDate] = useState(dayjs().format('YYYY-MM-DD'));

  const monthStart = cursor.format('YYYY-MM-DD');
  const monthEnd = cursor.endOf('month').format('YYYY-MM-DD');

  const { data, isLoading } = useTeamFollowUps({ dateFrom: monthStart, dateTo: monthEnd });
  const followUps = Array.isArray(data) ? data : (data?.items || []);

  // Group by date
  const byDate = useMemo(() => {
    const map = {};
    for (const fu of followUps) {
      const d = fu.scheduled_date;
      if (!map[d]) map[d] = [];
      map[d].push(fu);
    }
    return map;
  }, [followUps]);

  const selectedFUs = byDate[selectedDate] || [];

  // Calendar grid
  const daysInMonth = cursor.daysInMonth();
  const leadingBlanks = cursor.startOf('month').day(); // Sun=0
  const cells = [];
  for (let i = 0; i < leadingBlanks; i++) cells.push(null);
  for (let d = 1; d <= daysInMonth; d++) {
    const iso = cursor.date(d).format('YYYY-MM-DD');
    cells.push({ day: d, iso, count: (byDate[iso] || []).length });
  }

  const today = dayjs().format('YYYY-MM-DD');

  return (
    <div className="space-y-6">
      <PageHeader title="Follow-up Calendar" subtitle="Monthly view of scheduled follow-ups" />

      <div className="grid grid-cols-1 gap-6 lg:grid-cols-3">
        {/* Calendar */}
        <Card className="lg:col-span-2">
          {/* Month nav */}
          <div className="mb-4 flex items-center justify-between">
            <button
              type="button"
              onClick={() => setCursor((c) => c.subtract(1, 'month').startOf('month'))}
              className="rounded-btn p-1.5 text-text-secondary hover:bg-border/40"
            >
              <ChevronLeft className="h-5 w-5" />
            </button>
            <span className="font-semibold text-text-primary">
              {cursor.format('MMMM YYYY')}
            </span>
            <button
              type="button"
              onClick={() => setCursor((c) => c.add(1, 'month').startOf('month'))}
              className="rounded-btn p-1.5 text-text-secondary hover:bg-border/40"
            >
              <ChevronRight className="h-5 w-5" />
            </button>
          </div>

          {/* Day-of-week headers */}
          <div className="mb-1 grid grid-cols-7 text-center text-xs font-medium text-text-secondary">
            {['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'].map((d) => (
              <div key={d} className="py-1">{d}</div>
            ))}
          </div>

          {/* Day cells */}
          {isLoading ? (
            <Spinner label="Loading…" className="py-10" />
          ) : (
            <div className="grid grid-cols-7 gap-1">
              {cells.map((cell, idx) =>
                cell === null ? (
                  <div key={`blank-${idx}`} />
                ) : (
                  <button
                    key={cell.iso}
                    type="button"
                    onClick={() => setSelectedDate(cell.iso)}
                    className={[
                      'relative flex aspect-square flex-col items-center justify-center rounded-btn text-sm transition-colors',
                      selectedDate === cell.iso
                        ? 'bg-primary text-white font-semibold'
                        : cell.iso === today
                          ? 'border border-primary text-primary font-semibold hover:bg-primary/10'
                          : 'text-text-primary hover:bg-surface',
                    ].join(' ')}
                  >
                    {cell.day}
                    {cell.count > 0 && (
                      <span
                        className={`absolute bottom-1 left-1/2 h-1.5 w-1.5 -translate-x-1/2 rounded-full ${selectedDate === cell.iso ? 'bg-white/80' : 'bg-amber-400'}`}
                      />
                    )}
                  </button>
                ),
              )}
            </div>
          )}
        </Card>

        {/* Day panel */}
        <Card>
          <CardHeader
            title={dayjs(selectedDate).format('D MMMM')}
            subtitle={`${selectedFUs.length} follow-up${selectedFUs.length !== 1 ? 's' : ''}`}
          />
          {selectedFUs.length === 0 ? (
            <div className="py-8 text-center text-sm text-text-secondary">
              No follow-ups on this day.
            </div>
          ) : (
            <div className="space-y-2 overflow-y-auto" style={{ maxHeight: 420 }}>
              {selectedFUs
                .sort((a, b) => (a.scheduled_time || '').localeCompare(b.scheduled_time || ''))
                .map((fu) => (
                  <FollowUpItem key={fu.id} fu={fu} />
                ))}
            </div>
          )}
        </Card>
      </div>
    </div>
  );
}
