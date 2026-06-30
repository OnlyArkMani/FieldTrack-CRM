import { useState } from 'react';
import { ChevronDown, ChevronRight, MapPin } from 'lucide-react';
import dayjs from 'dayjs';

import { useTeamPlans } from '@/hooks/useVisitPlans';
import Card, { CardHeader } from '@/components/ui/Card';
import PageHeader from '@/components/ui/PageHeader';
import Spinner from '@/components/ui/Spinner';

function todayISO() {
  return dayjs().format('YYYY-MM-DD');
}

const STATUS_CFG = {
  SUBMITTED: { bg: 'bg-status-active/15', text: 'text-status-active', label: 'Submitted' },
  DRAFT:     { bg: 'bg-primary/15',        text: 'text-primary',        label: 'Draft' },
  PENDING:   { bg: 'bg-border/40',         text: 'text-text-secondary', label: 'Pending' },
};

function StatusChip({ status }) {
  const cfg = STATUS_CFG[status?.toUpperCase()] || STATUS_CFG.PENDING;
  return (
    <span className={`inline-flex items-center rounded-full px-2 py-0.5 text-xs font-semibold ${cfg.bg} ${cfg.text}`}>
      {cfg.label}
    </span>
  );
}

const VISIT_STATUS_CFG = {
  COMPLETED:   { color: 'var(--ft-status-active)',  label: 'Done' },
  CHECKED_IN:  { color: 'var(--ft-primary)',        label: 'In Progress' },
  PLANNED:     { color: 'var(--ft-text-secondary)', label: 'Planned' },
  SKIPPED:     { color: 'var(--ft-status-danger)',  label: 'Skipped' },
};

function CoverageBar({ done, total }) {
  const pct = total > 0 ? Math.round((done / total) * 100) : 0;
  return (
    <div className="flex items-center gap-2">
      <div className="h-1.5 w-16 overflow-hidden rounded-full bg-border">
        <div
          className="h-full rounded-full bg-primary"
          style={{ width: `${pct}%` }}
        />
      </div>
      <span className="text-xs text-text-secondary">{pct}%</span>
    </div>
  );
}

function PlanRow({ plan }) {
  const [open, setOpen] = useState(false);
  const items = plan.items || [];
  const completed = items.filter((i) => i.status === 'COMPLETED').length;

  return (
    <>
      <tr
        className="cursor-pointer border-t border-border/60 hover:bg-surface/40"
        onClick={() => setOpen((v) => !v)}
      >
        <td className="px-4 py-3">
          <div className="flex items-center gap-2">
            {open ? <ChevronDown className="h-4 w-4 text-text-secondary" /> : <ChevronRight className="h-4 w-4 text-text-secondary" />}
            <span className="font-medium text-text-primary">{plan.employee_name ?? '—'}</span>
          </div>
        </td>
        <td className="px-4 py-3">
          <StatusChip status={plan.status} />
        </td>
        <td className="px-4 py-3 text-text-secondary">{items.length}</td>
        <td className="px-4 py-3">
          <CoverageBar done={completed} total={items.length} />
        </td>
        <td className="px-4 py-3 text-xs text-text-secondary">
          {plan.submitted_at ? dayjs(plan.submitted_at).format('HH:mm') : '—'}
        </td>
      </tr>
      {open && items.length > 0 && (
        <tr className="bg-surface/30">
          <td colSpan={5} className="px-6 py-3">
            <ul className="space-y-2">
              {items.map((item) => {
                const vcfg = VISIT_STATUS_CFG[item.status] || VISIT_STATUS_CFG.PLANNED;
                return (
                  <li key={item.id} className="flex items-center gap-3">
                    <MapPin className="h-3.5 w-3.5 shrink-0" style={{ color: vcfg.color }} />
                    <span className="flex-1 truncate text-sm text-text-primary">
                      {item.farmer_name ?? `Farmer #${item.farmer_id}`}
                    </span>
                    <span className="text-xs" style={{ color: vcfg.color }}>{vcfg.label}</span>
                    {item.notes && (
                      <span className="max-w-[200px] truncate text-xs text-text-secondary">
                        {item.notes}
                      </span>
                    )}
                  </li>
                );
              })}
            </ul>
          </td>
        </tr>
      )}
      {open && items.length === 0 && (
        <tr className="bg-surface/30">
          <td colSpan={5} className="px-6 py-3 text-sm text-text-secondary">
            No visits planned.
          </td>
        </tr>
      )}
    </>
  );
}

export default function VisitPlansPage() {
  const [date, setDate] = useState(todayISO());
  const { data, isLoading } = useTeamPlans(date);
  const plans = Array.isArray(data) ? data : (data?.items || []);

  const submitted = plans.filter((p) => p.status === 'SUBMITTED').length;
  const total = plans.length;

  return (
    <div className="space-y-6">
      <PageHeader
        title="Visit Plans"
        subtitle="Daily field visit plans by employee"
      />

      {/* Date picker + summary */}
      <div className="flex flex-wrap items-center gap-4">
        <input
          type="date"
          value={date}
          onChange={(e) => setDate(e.target.value)}
          className="h-9 rounded-btn border border-border bg-surface px-3 text-sm text-text-primary focus:border-primary focus:outline-none"
        />
        {!isLoading && total > 0 && (
          <span className="text-sm text-text-secondary">
            {submitted}/{total} submitted
          </span>
        )}
      </div>

      <Card padded={false}>
        {isLoading ? (
          <Spinner label="Loading plans…" className="py-16" />
        ) : plans.length === 0 ? (
          <div className="py-16 text-center text-sm text-text-secondary">
            No plans found for {dayjs(date).format('D MMMM YYYY')}.
          </div>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-left text-sm">
              <thead className="border-b border-border bg-surface/60 text-text-secondary">
                <tr>
                  <th className="px-4 py-3 font-semibold">Employee</th>
                  <th className="px-4 py-3 font-semibold">Status</th>
                  <th className="px-4 py-3 font-semibold">Visits</th>
                  <th className="px-4 py-3 font-semibold">Coverage</th>
                  <th className="px-4 py-3 font-semibold">Submitted</th>
                </tr>
              </thead>
              <tbody>
                {plans.map((plan) => (
                  <PlanRow key={plan.id ?? plan.employee_id} plan={plan} />
                ))}
              </tbody>
            </table>
          </div>
        )}
      </Card>
    </div>
  );
}
