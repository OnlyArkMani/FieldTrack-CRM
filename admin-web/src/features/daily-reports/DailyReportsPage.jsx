import { useState, useRef } from 'react';
import dayjs from 'dayjs';
import { X, MessageSquare } from 'lucide-react';

import { useTeamDsrs, useDsrDetail, useAddManagerComment } from '@/hooks/useDailyReports';
import PageHeader from '@/components/ui/PageHeader';
import Card from '@/components/ui/Card';
import Table from '@/components/ui/Table';
import Badge from '@/components/ui/Badge';
import Spinner from '@/components/ui/Spinner';
import { Input } from '@/components/ui/Input';
import Button from '@/components/ui/Button';

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

// ── Main page ─────────────────────────────────────────────────────────────────

export default function DailyReportsPage() {
  const [date, setDate] = useState(dayjs().format('YYYY-MM-DD'));
  const [selectedRow, setSelectedRow] = useState(null); // { employee_id, employee_name, report_id }

  const { data: rows = [], isLoading } = useTeamDsrs(date);

  const columns = [
    {
      key: 'employee',
      header: 'Employee',
      render: (r) => (
        <span className="font-medium text-text-primary">
          {r.employee_name}
        </span>
      ),
    },
    {
      key: 'visits',
      header: 'Visits',
      render: (r) => r.visits_completed,
    },
    {
      key: 'orders',
      header: 'Orders',
      render: (r) => r.orders_captured,
    },
    {
      key: 'leads',
      header: 'Leads',
      render: (r) => (
        <span className="flex gap-1">
          {r.hot_leads > 0 && (
            <span className="rounded px-1.5 py-0.5 text-xs font-semibold bg-danger/10 text-danger">
              {r.hot_leads}H
            </span>
          )}
          {r.warm_leads > 0 && (
            <span className="rounded px-1.5 py-0.5 text-xs font-semibold bg-primary/10 text-primary">
              {r.warm_leads}W
            </span>
          )}
          {r.cold_leads > 0 && (
            <span className="rounded px-1.5 py-0.5 text-xs font-semibold bg-secondary/10 text-secondary">
              {r.cold_leads}C
            </span>
          )}
          {r.hot_leads + r.warm_leads + r.cold_leads === 0 && (
            <span className="text-text-secondary">—</span>
          )}
        </span>
      ),
    },
    {
      key: 'status',
      header: 'Status',
      render: (r) => (
        <span className="flex items-center">
          <StatusBadge status={r.status} />
          {r.is_late && <LateBadge />}
        </span>
      ),
    },
  ];

  return (
    <div className="flex h-full gap-4">
      {/* ── Main table ─────────────────────────────────────────────── */}
      <div className={`flex flex-col gap-4 transition-all duration-300 ${selectedRow ? 'w-1/2' : 'w-full'}`}>
        <PageHeader
          title="Daily Reports"
          subtitle="Team DSR submissions by date"
        />

        <Card>
          <div className="mb-4 flex items-center gap-3">
            <label className="text-sm font-medium text-text-secondary">Date</label>
            <Input
              type="date"
              value={date}
              onChange={(e) => {
                setDate(e.target.value);
                setSelectedRow(null);
              }}
              className="w-44"
            />
          </div>

          {isLoading ? (
            <div className="flex justify-center py-12">
              <Spinner />
            </div>
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

      {/* ── Slide-in detail panel ──────────────────────────────────── */}
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

// ── Detail panel ──────────────────────────────────────────────────────────────

function DsrDetailPanel({ employeeId, employeeName, reportId, date, onClose }) {
  const { data: dsr, isLoading } = useDsrDetail(employeeId, date);
  const addComment = useAddManagerComment();
  const [comment, setComment] = useState('');
  const [saving, setSaving] = useState(false);

  // Prefill if manager already left a comment
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
    <div className="flex w-1/2 flex-col rounded-card border border-border bg-card shadow-md overflow-hidden">
      {/* Header */}
      <div className="flex items-center justify-between border-b border-border px-4 py-3">
        <div>
          <h3 className="font-semibold text-text-primary">{employeeName}</h3>
          <p className="text-xs text-text-secondary">{dayjs(date).format('D MMMM YYYY')}</p>
        </div>
        <button
          onClick={onClose}
          className="rounded p-1 text-text-secondary hover:bg-border/40 hover:text-text-primary"
        >
          <X className="h-4 w-4" />
        </button>
      </div>

      {/* Body */}
      <div className="flex-1 overflow-y-auto p-4 space-y-4">
        {isLoading ? (
          <div className="flex justify-center py-8"><Spinner /></div>
        ) : !dsr ? (
          <p className="text-center text-sm text-text-secondary py-8">
            No DSR found.
          </p>
        ) : (
          <>
            {/* Status + late */}
            <div className="flex items-center gap-2">
              <StatusBadge status={dsr.status} />
              {dsr.is_late && <LateBadge />}
              {dsr.submitted_at && (
                <span className="text-xs text-text-secondary">
                  Submitted {dayjs(dsr.submitted_at).format('HH:mm')}
                </span>
              )}
            </div>

            {/* Stat row */}
            <div className="grid grid-cols-3 gap-2">
              {[
                { label: 'Visits', val: dsr.visits_completed },
                { label: 'Orders', val: dsr.orders_captured },
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

            {/* Visits list */}
            {dsr.visits?.length > 0 && (
              <Section title={`Visits (${dsr.visits.length})`}>
                {dsr.visits.map((v) => (
                  <RowItem key={v.id}>
                    <span className="font-medium text-text-primary truncate">{v.farmer_name}</span>
                    <span className="text-xs text-text-secondary shrink-0">
                      {v.purpose?.replace(/_/g, ' ') || 'Visit'}
                      {v.lead_status && (
                        <span className={`ml-2 font-semibold ${
                          v.lead_status === 'HOT' ? 'text-danger' :
                          v.lead_status === 'WARM' ? 'text-primary' : 'text-secondary'
                        }`}>
                          {v.lead_status}
                        </span>
                      )}
                    </span>
                  </RowItem>
                ))}
              </Section>
            )}

            {/* Orders list */}
            {dsr.orders?.length > 0 && (
              <Section title={`Orders (${dsr.orders.length})`}>
                {dsr.orders.map((o) => (
                  <RowItem key={o.id}>
                    <span className="font-medium text-text-primary truncate">{o.farmer_name}</span>
                    <span className="text-xs font-bold text-success shrink-0">
                      {o.bags_count} bags
                    </span>
                  </RowItem>
                ))}
              </Section>
            )}

            {/* End-of-day note */}
            {dsr.end_of_day_note && (
              <Section title="End-of-Day Note">
                <p className="text-sm text-text-primary whitespace-pre-wrap">
                  {dsr.end_of_day_note}
                </p>
              </Section>
            )}

            {/* Existing manager comment */}
            {existingComment && (
              <Section title="Your Previous Comment">
                <p className="text-sm text-text-primary whitespace-pre-wrap">
                  {existingComment}
                </p>
              </Section>
            )}

            {/* Add / update manager comment */}
            {reportId && (
              <Section title="Add Comment">
                <textarea
                  rows={3}
                  value={comment}
                  onChange={(e) => setComment(e.target.value)}
                  placeholder="Leave a comment for the employee…"
                  maxLength={1000}
                  className="w-full rounded-btn border border-border bg-bg p-2 text-sm text-text-primary placeholder:text-text-secondary focus:outline-none focus:ring-1 focus:ring-primary resize-none"
                />
                <div className="mt-2 flex justify-end">
                  <Button
                    size="sm"
                    disabled={!comment.trim() || saving}
                    isLoading={saving}
                    onClick={handleAddComment}
                  >
                    <MessageSquare className="mr-1.5 h-3.5 w-3.5" />
                    Add comment
                  </Button>
                </div>
              </Section>
            )}
          </>
        )}
      </div>
    </div>
  );
}

function Section({ title, children }) {
  return (
    <div>
      <h4 className="mb-2 text-xs font-semibold uppercase tracking-wide text-text-secondary">
        {title}
      </h4>
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
