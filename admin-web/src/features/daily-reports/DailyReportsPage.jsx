import { useState } from 'react';
import dayjs from 'dayjs';
import { X, MessageSquare, Download } from 'lucide-react';

import {
  useTeamDsrs,
  useDsrDetail,
  useAddManagerComment,
  useDsrArchive,
  downloadTeamDsr,
  downloadVisitsExport,
} from '@/hooks/useDailyReports';
import { useTeams } from '@/hooks/useTeams';
import { useAuthStore } from '@/store/authStore';
import PageHeader from '@/components/ui/PageHeader';
import Card from '@/components/ui/Card';
import Table from '@/components/ui/Table';
import Badge from '@/components/ui/Badge';
import Spinner from '@/components/ui/Spinner';
import { Input, Select } from '@/components/ui/Input';
import Button from '@/components/ui/Button';

const MAX_RANGE_DAYS = 731;

// ── Status helpers ────────────────────────────────────────────────────────────

const STATUS_VARIANT = {
  SUBMITTED: 'success',
  DRAFT: 'warning',
  MISSING: 'danger',
};

function StatusBadge({ status }) {
  return (
    <Badge variant={STATUS_VARIANT[status] || 'default'}>
      {status[0] + status.slice(1).toLowerCase()}
    </Badge>
  );
}

function LateBadge() {
  return (
    <span className="ml-1.5 rounded px-1.5 py-0.5 text-[10px] font-bold bg-danger/10 text-danger border border-danger/30">
      LATE
    </span>
  );
}

function money(v) {
  if (v == null) return '—';
  const n = Number(v);
  return `₹${Number.isInteger(n) ? n : n.toFixed(2)}`;
}

function LeadPills({ h, w, c }) {
  if (h + w + c === 0) return <span className="text-text-secondary">—</span>;
  return (
    <span className="flex gap-1">
      {h > 0 && <span className="rounded px-1.5 py-0.5 text-xs font-semibold bg-danger/10 text-danger">{h}H</span>}
      {w > 0 && <span className="rounded px-1.5 py-0.5 text-xs font-semibold bg-primary/10 text-primary">{w}W</span>}
      {c > 0 && <span className="rounded px-1.5 py-0.5 text-xs font-semibold bg-secondary/10 text-secondary">{c}C</span>}
    </span>
  );
}

function fmtTime(v) {
  return v ? dayjs(v).format('HH:mm') : '—';
}

// ── Summary cards ─────────────────────────────────────────────────────────────

function SummaryCards({ rows }) {
  const submitted = rows.filter((r) => r.status === 'SUBMITTED').length;
  const draft = rows.filter((r) => r.status === 'DRAFT').length;
  const missing = rows.filter((r) => r.status === 'MISSING').length;
  const late = rows.filter((r) => r.is_late).length;
  const cards = [
    { label: 'Submitted', value: submitted, cls: 'text-status-active' },
    { label: 'Draft', value: draft, cls: 'text-primary' },
    { label: 'Missing', value: missing, cls: 'text-danger' },
    { label: 'Late', value: late, cls: 'text-danger' },
  ];
  return (
    <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
      {cards.map((c) => (
        <Card key={c.label} className="py-3">
          <div className={`text-2xl font-bold ${c.cls}`}>{c.value}</div>
          <div className="text-xs text-text-secondary">{c.label}</div>
        </Card>
      ))}
    </div>
  );
}

// ── Main page ─────────────────────────────────────────────────────────────────

export default function DailyReportsPage() {
  const user = useAuthStore((s) => s.user);
  const isAdmin = user?.role === 'ADMIN';
  const { data: teams = [] } = useTeams();

  const [view, setView] = useState('daily'); // 'daily' | 'range'

  return (
    <div className="flex h-full flex-col gap-4">
      <PageHeader
        title="Daily Sales Reports (DSR)"
        subtitle="Team CRM activity and visit summaries"
      />

      {/* View toggle */}
      <div className="flex gap-2">
        {[
          { k: 'daily', label: 'Daily View' },
          { k: 'range', label: 'Date Range' },
        ].map((t) => (
          <button
            key={t.k}
            onClick={() => setView(t.k)}
            className={`rounded-btn px-3 py-1.5 text-sm font-medium transition-colors ${
              view === t.k
                ? 'bg-primary text-white'
                : 'bg-surface text-text-secondary hover:text-text-primary'
            }`}
          >
            {t.label}
          </button>
        ))}
      </div>

      {view === 'daily' ? (
        <DailyView isAdmin={isAdmin} teams={teams} />
      ) : (
        <RangeView isAdmin={isAdmin} teams={teams} />
      )}
    </div>
  );
}

// ── Daily view (per-employee status for one date) ──────────────────────────────

function DailyView({ isAdmin, teams }) {
  const [date, setDate] = useState(dayjs().format('YYYY-MM-DD'));
  const [teamId, setTeamId] = useState('');
  const [selectedRow, setSelectedRow] = useState(null);

  const { data: rows = [], isLoading } = useTeamDsrs(date, isAdmin ? teamId : undefined);

  const columns = [
    { key: 'employee', header: 'Employee', render: (r) => (
      <span className="font-medium text-text-primary">{r.employee_name}</span>
    )},
    { key: 'in', header: 'Check In', render: (r) => fmtTime(r.check_in_time) },
    { key: 'out', header: 'Check Out', render: (r) => fmtTime(r.check_out_time) },
    { key: 'visits', header: 'Visits (Done/Planned)', render: (r) => `${r.visits_completed}/${r.visits_planned}` },
    { key: 'orders', header: 'Orders', render: (r) => r.orders_captured },
    { key: 'leads', header: 'Leads (H/W/C)', render: (r) => (
      <LeadPills h={r.hot_leads} w={r.warm_leads} c={r.cold_leads} />
    )},
    { key: 'status', header: 'DSR Status', render: (r) => (
      <span className="flex items-center">
        <StatusBadge status={r.status} />
        {r.is_late && <LateBadge />}
      </span>
    )},
    {
      key: 'actions',
      header: 'Action',
      align: 'right',
      render: (r) =>
        r.status !== 'MISSING' ? (
          <Button
            size="sm"
            variant="ghost"
            icon={Download}
            onClick={(ev) => {
              ev.stopPropagation();
              downloadTeamDsr(r.employee_id, date, r.employee_name);
            }}
            title="Download DSR (CSV)"
          />
        ) : null,
    },
  ];

  return (
    <div className="flex gap-4" style={{ maxHeight: 'calc(100vh - 140px)' }}>
      <div className={`flex flex-col gap-4 transition-all duration-300 ${selectedRow ? 'w-1/2' : 'w-full'}`}>
        <Card>
          <div className="mb-4 flex flex-wrap items-center gap-3">
            <label className="text-sm font-medium text-text-secondary">Date</label>
            <Input
              type="date"
              value={date}
              max={dayjs().format('YYYY-MM-DD')}
              onChange={(e) => { setDate(e.target.value); setSelectedRow(null); }}
              className="w-44"
            />
            {isAdmin && (
              <div className="w-52">
                <Select value={teamId} onChange={(e) => { setTeamId(e.target.value); setSelectedRow(null); }}>
                  <option value="">All teams</option>
                  {teams.map((t) => (
                    <option key={t.id} value={t.id}>{t.name}</option>
                  ))}
                </Select>
              </div>
            )}
          </div>

          {!isLoading && rows.length > 0 && (
            <div className="mb-4"><SummaryCards rows={rows} /></div>
          )}

          {isLoading ? (
            <div className="flex justify-center py-12"><Spinner /></div>
          ) : rows.length === 0 ? (
            <p className="py-8 text-center text-sm text-text-secondary">
              No employees found for this date.
            </p>
          ) : (
            <Table
              columns={columns}
              rows={rows}
              rowKey={(r) => r.employee_id}
              onRowClick={(r) =>
                setSelectedRow(
                  selectedRow?.employee_id === r.employee_id
                    ? null
                    : { employee_id: r.employee_id, employee_name: r.employee_name, report_id: r.report_id }
                )
              }
              activeRowKey={selectedRow?.employee_id}
            />
          )}
        </Card>
      </div>

      {selectedRow && (
        <DsrDetailPanel
          employeeId={selectedRow.employee_id}
          employeeName={selectedRow.employee_name}
          reportId={selectedRow.report_id}
          date={date}
          onClose={() => setSelectedRow(null)}
        />
      )}
    </div>
  );
}

// ── Range view (up to 31 days, one row per employee-day) ───────────────────────

function RangeView({ isAdmin, teams }) {
  const [start, setStart] = useState(dayjs().subtract(6, 'day').format('YYYY-MM-DD'));
  const [end, setEnd] = useState(dayjs().format('YYYY-MM-DD'));
  const [teamId, setTeamId] = useState('');
  const [search, setSearch] = useState('');
  const [executiveName, setExecutiveName] = useState('');

  const rangeTooLong = dayjs(end).diff(dayjs(start), 'day') > MAX_RANGE_DAYS;

  const { data, isLoading } = useDsrArchive({
    enabled: !rangeTooLong,
    date_from: start,
    date_to: end,
    ...(isAdmin && teamId ? { team_id: teamId } : {}),
    ...(search.trim() ? { search: search.trim() } : {}),
    ...(executiveName.trim() ? { executive_name: executiveName.trim() } : {}),
  });
  const items = data?.items ?? [];

  const columns = [
    { key: 'employee', header: 'Employee', render: (r) => (
      <span className="font-medium text-text-primary">{r.employee_name}</span>
    )},
    { key: 'date', header: 'Date', render: (r) => dayjs(r.report_date).format('DD MMM') },
    { key: 'status', header: 'Status', render: (r) => (
      <span className="flex items-center"><StatusBadge status={r.status} />{r.is_late && <LateBadge />}</span>
    )},
    { key: 'visits', header: 'Visits', render: (r) => r.visits_completed },
    { key: 'orders', header: 'Orders', render: (r) => r.orders_captured },
    { key: 'leads', header: 'Leads (H/W/C)', render: (r) => (
      <LeadPills h={r.hot_leads} w={r.warm_leads} c={r.cold_leads} />
    )},
    {
      key: 'actions',
      header: 'Action',
      align: 'right',
      render: (r) =>
        r.status !== 'MISSING' ? (
          <Button
            size="sm"
            variant="ghost"
            icon={Download}
            onClick={(ev) => {
              ev.stopPropagation();
              downloadTeamDsr(r.employee_id, r.report_date, r.employee_name);
            }}
            title="Download DSR (CSV)"
          />
        ) : null,
    },
  ];

  return (
    <Card>
      <div className="mb-4 flex flex-wrap items-end gap-3">
        <div className="w-44">
          <Input label="Start" type="date" value={start} max={end}
            onChange={(e) => setStart(e.target.value)} />
        </div>
        <div className="w-44">
          <Input label="End" type="date" value={end} min={start} max={dayjs().format('YYYY-MM-DD')}
            onChange={(e) => setEnd(e.target.value)} />
        </div>
        {isAdmin && (
          <div className="w-52">
            <Select label="Team" value={teamId} onChange={(e) => setTeamId(e.target.value)}>
              <option value="">All teams</option>
              {teams.map((t) => (<option key={t.id} value={t.id}>{t.name}</option>))}
            </Select>
          </div>
        )}
        <div className="w-56">
          <Input
            label="Farmer / customer"
            placeholder="Search by name…"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
          />
        </div>
        <div className="w-56">
          <Input
            label="Executive"
            placeholder="Search by name…"
            value={executiveName}
            onChange={(e) => setExecutiveName(e.target.value)}
          />
        </div>
        <Button
          variant="secondary"
          icon={Download}
          onClick={() =>
            downloadVisitsExport({
              dateFrom: start,
              dateTo: end,
              teamId: isAdmin ? teamId : undefined,
            })
          }
        >
          Visits Excel
        </Button>
      </div>
      <p className="mb-3 text-xs italic text-text-secondary">
        Max 24 months per range. “Visits Excel” downloads one row per visit with
        full meeting, order, vet &amp; livestock detail.
      </p>

      {rangeTooLong ? (
        <p className="py-8 text-center text-sm text-danger">Please select a range of 24 months or less.</p>
      ) : isLoading ? (
        <div className="flex justify-center py-12"><Spinner /></div>
      ) : items.length === 0 ? (
        <p className="py-8 text-center text-sm text-text-secondary">No DSRs in this range.</p>
      ) : (
        <Table columns={columns} rows={items} rowKey={(r) => `${r.employee_id}-${r.report_date}`} />
      )}
    </Card>
  );
}

// ── Detail panel ──────────────────────────────────────────────────────────────

function DsrDetailPanel({ employeeId, employeeName, reportId, date, onClose }) {
  const { data: dsr, isLoading } = useDsrDetail(employeeId, date);
  const addComment = useAddManagerComment();
  const [comment, setComment] = useState('');
  const [saving, setSaving] = useState(false);

  const existingComment = dsr?.manager_comment || '';

  async function handleAddComment() {
    if (!comment.trim() || !reportId) return;
    setSaving(true);
    try {
      await addComment.mutateAsync({ reportId, comment: comment.trim() });
      setComment('');
    } finally {
      setSaving(false);
    }
  }

  return (
    <div className="flex h-full w-1/2 flex-col rounded-card border border-border bg-card shadow-md overflow-hidden">
      <div className="flex items-center justify-between border-b border-border px-4 py-3">
        <div>
          <h3 className="font-semibold text-text-primary">{employeeName}</h3>
          <p className="text-xs text-text-secondary">{dayjs(date).format('D MMMM YYYY')}</p>
        </div>
        <div className="flex items-center gap-1">
          <button
            onClick={() => downloadTeamDsr(employeeId, date, employeeName)}
            title="Download this day's DSR (CSV)"
            className="flex items-center gap-1 rounded-btn px-2 py-1 text-xs font-medium text-primary hover:bg-primary/10"
          >
            <Download className="h-4 w-4" /> CSV
          </button>
          <button onClick={onClose} className="rounded p-1 text-text-secondary hover:bg-border/40 hover:text-text-primary">
            <X className="h-4 w-4" />
          </button>
        </div>
      </div>

      <div className="flex-1 overflow-y-auto p-4 space-y-4">
        {isLoading ? (
          <div className="flex justify-center py-8"><Spinner /></div>
        ) : !dsr ? (
          <p className="text-center text-sm text-text-secondary py-8">
            No DSR submitted yet for this employee.
          </p>
        ) : (
          <>
            <div className="flex items-center gap-2">
              <StatusBadge status={dsr.status} />
              {dsr.is_late && <LateBadge />}
              {dsr.submitted_at && (
                <span className="text-xs text-text-secondary">Submitted {dayjs(dsr.submitted_at).format('HH:mm')}</span>
              )}
            </div>

            {(dsr.check_in_at || dsr.check_out_at) && (
              <div className="flex flex-wrap items-center gap-x-3 gap-y-1 rounded-card bg-bg px-3 py-2 text-xs text-text-secondary">
                {dsr.check_in_at && (
                  <span>
                    <span className="text-text-primary font-medium">In:</span>{' '}
                    {dayjs(dsr.check_in_at).format('HH:mm')}
                    {dsr.check_in_lat != null && dsr.check_in_lng != null && (
                      <span className="text-text-secondary">
                        {' '}({dsr.check_in_lat.toFixed(4)}, {dsr.check_in_lng.toFixed(4)})
                      </span>
                    )}
                  </span>
                )}
                {dsr.check_out_at && (
                  <span>
                    <span className="text-text-primary font-medium">Out:</span>{' '}
                    {dayjs(dsr.check_out_at).format('HH:mm')}
                    {dsr.check_out_lat != null && dsr.check_out_lng != null && (
                      <span className="text-text-secondary">
                        {' '}({dsr.check_out_lat.toFixed(4)}, {dsr.check_out_lng.toFixed(4)})
                      </span>
                    )}
                  </span>
                )}
              </div>
            )}

            <div className="grid grid-cols-3 gap-2">
              {[
                { label: 'Visits', val: dsr.visits_completed },
                { label: 'Orders', val: dsr.orders_captured },
                { label: 'Order Value', val: dsr.orders_value != null ? money(dsr.orders_value) : '—' },
                { label: 'Follow-ups', val: dsr.follow_ups_scheduled },
                { label: 'Hot Leads', val: dsr.hot_leads, color: 'text-danger' },
                { label: 'Warm Leads', val: dsr.warm_leads, color: 'text-primary' },
                { label: 'Cold Leads', val: dsr.cold_leads, color: 'text-secondary' },
              ].map(({ label, val, color }) => (
                <div key={label} className="rounded-card bg-bg p-2 text-center">
                  <div className={`text-xl font-bold ${color || 'text-text-primary'}`}>{val}</div>
                  <div className="text-xs text-text-secondary">{label}</div>
                </div>
              ))}
            </div>

            {dsr.visits?.length > 0 && (
              <Section title={`Visits (${dsr.visits.length})`}>
                {dsr.visits.map((v) => (
                  <div key={v.id} className="rounded-btn bg-bg px-3 py-2 space-y-1">
                    <div className="flex items-center justify-between gap-2">
                      <span className="flex min-w-0 items-center gap-1.5">
                        <span className="font-medium text-text-primary truncate">{v.farmer_name}</span>
                        <TypeTag type={v.customer_type} />
                      </span>
                      <span className="text-xs text-text-secondary shrink-0">
                        {v.purpose?.replace(/_/g, ' ') || 'Visit'}
                        {v.lead_status && (
                          <span className={`ml-2 font-semibold ${
                            v.lead_status === 'HOT' ? 'text-danger' :
                            v.lead_status === 'WARM' ? 'text-primary' : 'text-secondary'
                          }`}>{v.lead_status}</span>
                        )}
                      </span>
                    </div>
                    {(v.village || v.district) && (
                      <div className="text-[11px] text-text-secondary">
                        {[v.village, v.district].filter(Boolean).join(', ')}
                      </div>
                    )}
                    {v.check_in_lat != null && v.check_in_lng != null && (
                      <a
                        href={`https://www.google.com/maps?q=${v.check_in_lat},${v.check_in_lng}`}
                        target="_blank"
                        rel="noreferrer"
                        className="text-[11px] text-primary underline"
                      >
                        Location
                      </a>
                    )}
                    {v.meeting_highlights && (
                      <p className="text-xs italic text-text-primary">{v.meeting_highlights}</p>
                    )}
                    {v.farmer_concerns && (
                      <p className="text-xs italic text-danger">{v.farmer_concerns}</p>
                    )}
                  </div>
                ))}
              </Section>
            )}

            {dsr.orders?.length > 0 && (
              <Section title={`Orders (${dsr.orders.length})`}>
                {dsr.orders.map((o) => (
                  <div key={o.id} className="rounded-btn bg-bg px-3 py-2 space-y-1">
                    <div className="flex items-center justify-between gap-2">
                      <span className="flex min-w-0 items-center gap-1.5">
                        <span className="font-medium text-text-primary truncate">{o.farmer_name}</span>
                        <TypeTag type={o.customer_type} />
                      </span>
                      <span className="text-xs font-bold text-success shrink-0">
                        {o.bags_count} bags · {dayjs(o.delivery_date).format('DD MMM')}
                      </span>
                    </div>
                    {o.price_per_bag != null && (
                      <div className="text-[11px] text-text-secondary">
                        {money(o.price_per_bag)}/bag · Total {money(o.total_value)}
                      </div>
                    )}
                  </div>
                ))}
              </Section>
            )}

            {dsr.follow_ups?.length > 0 && (
              <Section title={`Follow-ups (${dsr.follow_ups.length})`}>
                {dsr.follow_ups.map((f) => (
                  <RowItem key={f.id}>
                    <span className="font-medium text-text-primary truncate">{f.farmer_name}</span>
                    <span className="text-xs text-text-secondary shrink-0">
                      {dayjs(f.scheduled_date).format('DD MMM')}
                      {f.scheduled_time ? ` · ${String(f.scheduled_time).slice(0, 5)}` : ''}
                    </span>
                  </RowItem>
                ))}
              </Section>
            )}

            {dsr.end_of_day_note && (
              <Section title="Employee's Note">
                <p className="text-sm italic text-text-primary whitespace-pre-wrap rounded-card bg-bg p-3">
                  {dsr.end_of_day_note}
                </p>
              </Section>
            )}

            {dsr.late_checkout_reason && (
              <Section title="Reason for Late Checkout">
                <div className="rounded-card bg-status-danger/10 border border-status-danger/20 p-3 text-sm font-medium text-status-danger">
                  {dsr.late_checkout_reason}
                </div>
              </Section>
            )}

            {existingComment && (
              <Section title="Your Previous Comment">
                <p className="text-sm text-text-primary whitespace-pre-wrap">{existingComment}</p>
              </Section>
            )}
          </>
        )}

            {reportId && (
              <Section title="Manager Comment">
                <textarea
                  rows={3}
                  value={comment}
                  onChange={(e) => setComment(e.target.value)}
                  placeholder="Leave a comment for the employee…"
                  maxLength={1000}
                  className="w-full rounded-btn border border-border bg-bg p-2 text-sm text-text-primary placeholder:text-text-secondary focus:outline-none focus:ring-1 focus:ring-primary resize-none"
                />
                <div className="mt-2 flex justify-end">
                  <Button size="sm" icon={MessageSquare} disabled={!comment.trim() || saving} loading={saving} onClick={handleAddComment}>
                    Save Comment
                  </Button>
                </div>
              </Section>
            )}
      </div>
    </div>
  );
}

function Section({ title, children }) {
  return (
    <div>
      <h4 className="mb-2 text-xs font-semibold uppercase tracking-wide text-text-secondary">{title}</h4>
      <div className="space-y-1">{children}</div>
    </div>
  );
}

function RowItem({ children }) {
  return (
    <div className="flex items-center justify-between gap-2 rounded-btn bg-bg px-3 py-2">
      {children}
    </div>
  );
}

// Small inline customer-type chip (only shown for FPO/VLCC to avoid noise).
function TypeTag({ type }) {
  if (!type || type === 'FARMER_MEET') return null;
  return (
    <span className="shrink-0 rounded bg-primary/10 px-1.5 py-0.5 text-[10px] font-bold text-primary">
      {type}
    </span>
  );
}
