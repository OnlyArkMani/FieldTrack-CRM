import { useState } from 'react';
import dayjs from 'dayjs';
import { ChevronRight, ChevronDown, AlertTriangle, Clock } from 'lucide-react';

import { useTeamPlans, usePendingSubmissions } from '@/hooks/useVisitPlans';
import PageHeader from '@/components/ui/PageHeader';
import Card from '@/components/ui/Card';
import Badge from '@/components/ui/Badge';
import Spinner from '@/components/ui/Spinner';
import { LeadBadge } from '@/features/farmers/FarmerDetailPanel';

const STATUS_META = {
  SUBMITTED: { color: 'var(--ft-status-active)', label: 'Submitted' },
  IN_PROGRESS: { color: 'var(--ft-status-battery)', label: 'In progress' },
  COMPLETED: { color: 'var(--ft-status-active)', label: 'Completed' },
  DRAFT: { color: 'var(--ft-status-battery)', label: 'Draft' },
  NOT_SUBMITTED: { color: 'var(--ft-status-danger)', label: 'Not submitted' },
};

function StatusBadge({ status }) {
  const m = STATUS_META[status] || STATUS_META.NOT_SUBMITTED;
  return <Badge color={m.color}>{m.label}</Badge>;
}

function pretty(s) {
  if (!s) return '';
  return s
    .toLowerCase()
    .split('_')
    .map((w) => (w ? w[0].toUpperCase() + w.slice(1) : w))
    .join(' ');
}

export default function PlanningPage() {
  const [date, setDate] = useState(dayjs().add(1, 'day').format('YYYY-MM-DD'));
  const [expanded, setExpanded] = useState(null);

  const { data, isLoading } = useTeamPlans(date);
  const { data: pending } = usePendingSubmissions();

  const employees = data?.employees || [];
  const submittedCount = employees.filter((e) => e.status === 'SUBMITTED' || e.status === 'IN_PROGRESS' || e.status === 'COMPLETED').length;

  return (
    <div className="space-y-6">
      <PageHeader
        title="Visit Planning"
        subtitle={`${submittedCount}/${employees.length} submitted for ${dayjs(date).format('MMM D, YYYY')}`}
      />

      {/* Pending-for-tomorrow alert */}
      {pending?.length > 0 && (
        <div
          className="flex items-start gap-3 rounded-card border p-4"
          style={{
            background: 'var(--ft-status-battery)18',
            borderColor: 'var(--ft-status-battery)',
          }}
        >
          <AlertTriangle className="mt-0.5 h-5 w-5 shrink-0" style={{ color: 'var(--ft-status-battery)' }} />
          <div>
            <p className="text-sm font-semibold text-text-primary">
              {pending.length} employee{pending.length === 1 ? '' : 's'} haven&apos;t submitted tomorrow&apos;s plan
            </p>
            <p className="text-sm text-text-secondary">
              {pending.map((p) => p.employee_name).join(', ')}
            </p>
          </div>
        </div>
      )}

      <Card className="flex flex-wrap items-end gap-3">
        <div>
          <label className="mb-1 block text-sm font-medium text-text-primary">Date</label>
          <input
            type="date"
            value={date}
            onChange={(e) => { setDate(e.target.value); setExpanded(null); }}
            className="h-10 rounded-btn border border-border bg-surface px-3 text-sm text-text-primary focus:border-primary focus:outline-none"
          />
        </div>
        <p className="ml-auto self-center text-sm text-text-secondary">
          Click a row to see the planned visits.
        </p>
      </Card>

      <div className="overflow-x-auto rounded-card border border-border/60">
        <table className="w-full border-collapse text-sm">
          <thead>
            <tr className="bg-surface/60 text-left text-text-secondary">
              <th className="px-4 py-3 font-semibold" />
              <th className="px-4 py-3 font-semibold">Employee</th>
              <th className="px-4 py-3 font-semibold">Team</th>
              <th className="px-4 py-3 font-semibold">Plan status</th>
              <th className="px-4 py-3 font-semibold">Visits planned</th>
              <th className="px-4 py-3 font-semibold">Submitted at</th>
            </tr>
          </thead>
          <tbody>
            {isLoading ? (
              <tr>
                <td colSpan={6} className="px-4 py-10">
                  <Spinner label="Loading plans…" />
                </td>
              </tr>
            ) : employees.length === 0 ? (
              <tr>
                <td colSpan={6} className="px-4 py-10 text-center text-text-secondary">
                  No employees in scope.
                </td>
              </tr>
            ) : (
              employees.map((e) => {
                const isOpen = expanded === e.employee_id;
                const notSubmitted = e.status === 'NOT_SUBMITTED';
                return (
                  <FragmentRow
                    key={e.employee_id}
                    employee={e}
                    isOpen={isOpen}
                    notSubmitted={notSubmitted}
                    onToggle={() => setExpanded(isOpen ? null : e.employee_id)}
                  />
                );
              })
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}

function FragmentRow({ employee: e, isOpen, notSubmitted, onToggle }) {
  return (
    <>
      <tr
        onClick={onToggle}
        className="cursor-pointer border-t border-border/60 transition-colors hover:bg-surface/60"
        style={notSubmitted ? { background: 'var(--ft-status-battery)14' } : undefined}
      >
        <td className="px-4 py-3 text-text-secondary">
          {isOpen ? <ChevronDown className="h-4 w-4" /> : <ChevronRight className="h-4 w-4" />}
        </td>
        <td className="px-4 py-3 font-medium text-text-primary">{e.employee_name}</td>
        <td className="px-4 py-3 text-text-secondary">{e.team_name || '—'}</td>
        <td className="px-4 py-3"><StatusBadge status={e.status} /></td>
        <td className="px-4 py-3 text-text-primary">{e.visits_planned}</td>
        <td className="px-4 py-3 text-text-secondary">
          {e.submitted_at ? dayjs(e.submitted_at).format('MMM D, HH:mm') : '—'}
        </td>
      </tr>
      {isOpen && (
        <tr className="border-t border-border/60 bg-surface/30">
          <td colSpan={6} className="px-4 py-3">
            {e.items?.length ? (
              <ol className="space-y-2">
                {e.items.map((it, idx) => (
                  <li key={it.id} className="flex items-center gap-3 rounded-btn border border-border bg-card p-2.5">
                    <span className="grid h-6 w-6 shrink-0 place-items-center rounded-full bg-primary/16 text-xs font-bold text-primary">
                      {idx + 1}
                    </span>
                    {it.time_slot && (
                      <span className="flex items-center gap-1 text-xs text-text-secondary">
                        <Clock className="h-3.5 w-3.5" />
                        {it.time_slot.slice(0, 5)}
                      </span>
                    )}
                    <span className="min-w-0 flex-1 truncate font-medium text-text-primary">
                      {it.farmer_name}
                      {it.village ? <span className="text-text-secondary"> · {it.village}</span> : null}
                    </span>
                    <span className="text-xs text-text-secondary">{pretty(it.purpose) || 'Visit'}</span>
                    <LeadBadge status={it.lead_status} />
                  </li>
                ))}
              </ol>
            ) : (
              <p className="py-2 text-center text-sm text-text-secondary">
                {notSubmitted ? 'No plan submitted for this date.' : 'No visits in this plan.'}
              </p>
            )}
          </td>
        </tr>
      )}
    </>
  );
}
