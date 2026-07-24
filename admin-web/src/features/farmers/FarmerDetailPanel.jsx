import { useEffect, useRef } from 'react';
import { useNavigate } from 'react-router-dom';
import { useVirtualizer } from '@tanstack/react-virtual';
import dayjs from 'dayjs';
import { X, Phone, MapPin, Users, FileBarChart } from 'lucide-react';

import {
  useFarmer,
  useFarmerVisitsInfinite,
  useFarmerLivestock,
  useFarmerLeadHistory,
  useFarmerOrders,
} from '@/hooks/useFarmers';
import Badge from '@/components/ui/Badge';
import Button from '@/components/ui/Button';
import Spinner from '@/components/ui/Spinner';

export const LEAD_META = {
  HOT: { color: 'var(--ft-danger)', label: 'Hot' },
  WARM: { color: 'var(--ft-primary)', label: 'Warm' },
  COLD: { color: 'var(--ft-secondary)', label: 'Cold' },
};

export function LeadBadge({ status }) {
  if (!status) return <Badge color="var(--ft-status-offline)">No lead</Badge>;
  const m = LEAD_META[status] || LEAD_META.COLD;
  return <Badge color={m.color}>{m.label}</Badge>;
}

const ORDER_STATUS_META = {
  SUBMITTED: { color: 'var(--ft-primary)', label: 'Pending' },
  APPROVED: { color: 'var(--ft-status-active)', label: 'Approved' },
  REJECTED: { color: 'var(--ft-danger)', label: 'Rejected' },
};

function OrderStatusBadge({ status }) {
  const m = ORDER_STATUS_META[status] || ORDER_STATUS_META.SUBMITTED;
  return <Badge color={m.color}>{m.label}</Badge>;
}

// Customer type discriminator (FARMER_MEET / FPO / VLCC / RETAILER / DISTRIBUTOR).
export const CUSTOMER_TYPE_META = {
  FARMER_MEET: { color: 'var(--ft-secondary)', label: 'Farmer Meet' },
  FPO: { color: 'var(--ft-primary)', label: 'FPO' },
  VLCC: { color: 'var(--ft-status-active, #2E9E6B)', label: 'VLCC' },
  RETAILER: { color: 'var(--ft-status-battery, #D4A72C)', label: 'Retailer' },
  DISTRIBUTOR: { color: 'var(--ft-status-inactive, #7C6FD4)', label: 'Distributor' },
};

export function CustomerTypeBadge({ type }) {
  const m = CUSTOMER_TYPE_META[type] || CUSTOMER_TYPE_META.FARMER_MEET;
  return <Badge color={m.color}>{m.label}</Badge>;
}

function fmtDate(d) {
  return d ? dayjs(d).format('MMM D, YYYY') : '—';
}

function fmtDateTime(d) {
  return d ? dayjs(d).format('MMM D, YYYY · h:mm A') : '—';
}

/** Right-side slide-in farmer detail panel (400px). */
export default function FarmerDetailPanel({ farmerId, open, onClose }) {
  const navigate = useNavigate();
  const { data: farmer, isLoading } = useFarmer(open ? farmerId : null);
  const {
    data: visitPages,
    fetchNextPage,
    hasNextPage,
    isFetchingNextPage,
    isLoading: visitsLoading,
  } = useFarmerVisitsInfinite(open ? farmerId : null);
  const { data: livestock } = useFarmerLivestock(open ? farmerId : null);
  const { data: leads } = useFarmerLeadHistory(open ? farmerId : null);
  const { data: orders } = useFarmerOrders(open ? farmerId : null);

  // Visit history can run into the hundreds/thousands per farmer — fetch it a
  // page at a time (useFarmerVisitsInfinite) and only mount the rows actually
  // scrolled into view (useVirtualizer), instead of paying for a huge fetch
  // and a huge DOM up front.
  const visitRows = visitPages?.pages.flatMap((p) => p.items) ?? [];
  const visitTotal = visitPages?.pages[0]?.total ?? 0;
  const visitScrollRef = useRef(null);
  const rowVirtualizer = useVirtualizer({
    count: hasNextPage ? visitRows.length + 1 : visitRows.length,
    getScrollElement: () => visitScrollRef.current,
    estimateSize: () => 52,
    overscan: 6,
  });
  const virtualItems = rowVirtualizer.getVirtualItems();
  const lastVirtualIndex = virtualItems.length ? virtualItems[virtualItems.length - 1].index : -1;

  useEffect(() => {
    if (lastVirtualIndex >= visitRows.length - 1 && hasNextPage && !isFetchingNextPage) {
      fetchNextPage();
    }
  }, [lastVirtualIndex, visitRows.length, hasNextPage, isFetchingNextPage, fetchNextPage]);

  return (
    <>
      {/* Scrim */}
      <div
        onClick={onClose}
        className={`fixed inset-0 z-40 bg-black/40 transition-opacity duration-200 ${
          open ? 'opacity-100' : 'pointer-events-none opacity-0'
        }`}
      />
      {/* Panel */}
      <aside
        className={`fixed right-0 top-0 z-50 flex h-full w-full max-w-[400px] flex-col border-l border-border bg-card shadow-card transition-transform duration-300 ${
          open ? 'translate-x-0' : 'translate-x-full'
        }`}
      >
        <div className="flex items-center justify-between border-b border-border px-5 py-4">
          <h2 className="truncate text-lg font-semibold text-text-primary">
            {farmer?.name || 'Customer'}
          </h2>
          <button
            onClick={onClose}
            className="rounded-btn p-1 text-text-secondary hover:bg-border/50"
          >
            <X className="h-5 w-5" />
          </button>
        </div>

        <div className="flex-1 overflow-y-auto px-5 py-4">
          {isLoading || !farmer ? (
            <Spinner label="Loading farmer…" className="py-16" />
          ) : (
            <div className="space-y-6">
              {/* Header info */}
              <div className="space-y-2">
                <div className="flex items-center gap-2">
                  <CustomerTypeBadge type={farmer.customer_type} />
                  <LeadBadge status={farmer.current_lead?.status} />
                  {!farmer.is_active && (
                    <Badge color="var(--ft-status-offline)">Inactive</Badge>
                  )}
                </div>
                {farmer.village && (
                  <Row icon={MapPin} text={[farmer.village, farmer.district].filter(Boolean).join(', ')} />
                )}
                {(farmer.address || farmer.landmark) && (
                  <Row icon={MapPin} text={[farmer.address, farmer.landmark].filter(Boolean).join(', ')} />
                )}
                {farmer.pincode && (
                  <Row icon={MapPin} text={`PIN ${farmer.pincode}`} />
                )}
                {farmer.phone && (
                  <Row icon={Phone} text={<a className="text-primary hover:underline" href={`tel:${farmer.phone}`}>{farmer.phone}</a>} />
                )}
                {farmer.team_name && <Row icon={Users} text={farmer.team_name} />}
              </div>

              {/* Quick stats */}
              <div className="grid grid-cols-3 gap-3">
                <Mini label="Visits" value={farmer.total_visits ?? 0} />
                <Mini label="Orders" value={farmer.total_orders ?? 0} />
                <Mini label="Cattle" value={farmer.total_cattle ?? 0} />
              </div>

              {/* Latest livestock */}
              <Section title="Latest livestock">
                {farmer.latest_livestock ? (
                  <div className="grid grid-cols-2 gap-2 text-sm">
                    <KV k="Breed" v={farmer.latest_livestock.breed} />
                    <KV k="Brand" v={farmer.latest_livestock.current_brand} />
                    <KV k="Bags/mo" v={farmer.latest_livestock.bags_per_month} />
                    <KV k="Kg/animal/day" v={farmer.latest_livestock.kg_per_animal_per_day} />
                    <KV k="Price/bag" v={money(farmer.latest_livestock.current_price_per_bag)} />
                  </div>
                ) : (
                  <Empty>No livestock recorded.</Empty>
                )}
              </Section>

              {/* Visit history — virtualized + infinite-scrolled since a
                  farmer's visit count can grow into the hundreds. */}
              <Section title={`Visit history (${visitTotal})`}>
                {visitRows.length ? (
                  <div
                    ref={visitScrollRef}
                    className="max-h-72 overflow-y-auto rounded-btn border border-border"
                  >
                    <div
                      style={{ height: rowVirtualizer.getTotalSize(), position: 'relative' }}
                    >
                      {virtualItems.map((vRow) => {
                        const v = visitRows[vRow.index];
                        return (
                          <div
                            key={vRow.key}
                            style={{
                              position: 'absolute',
                              top: 0,
                              left: 0,
                              width: '100%',
                              height: vRow.size,
                              transform: `translateY(${vRow.start}px)`,
                            }}
                            className="flex items-center justify-between gap-3 border-b border-border/60 px-3 text-sm"
                          >
                            {v ? (
                              <>
                                <div className="min-w-0">
                                  <div className="truncate font-medium text-text-primary">
                                    {v.employee_name || 'Unassigned'}
                                  </div>
                                  <div className="truncate text-xs text-text-secondary">
                                    {pretty(v.purpose) || 'Visit'}
                                  </div>
                                </div>
                                <div className="shrink-0 text-right">
                                  <div className="text-xs text-text-secondary">
                                    {fmtDateTime(v.check_in_at || v.created_at)}
                                  </div>
                                  <div className="text-xs text-text-secondary">{pretty(v.status)}</div>
                                </div>
                              </>
                            ) : (
                              <span className="w-full text-center text-xs text-text-secondary">
                                Loading more…
                              </span>
                            )}
                          </div>
                        );
                      })}
                    </div>
                  </div>
                ) : visitsLoading ? (
                  <Spinner className="py-6" />
                ) : (
                  <Empty>No visits yet.</Empty>
                )}
              </Section>

              {/* Livestock history */}
              <Section title="Livestock history">
                {livestock?.length ? (
                  <MiniTable
                    head={['Date', 'Cattle', 'Brand', 'Price']}
                    rows={livestock.map((l) => [
                      fmtDate(l.recorded_at),
                      l.total_cattle ?? '—',
                      l.current_brand || '—',
                      money(l.current_price_per_bag),
                    ])}
                  />
                ) : (
                  <Empty>No livestock history.</Empty>
                )}
              </Section>

              {/* Order history (checklist #35) */}
              <Section title={`Order history (${farmer.total_orders ?? 0})`}>
                {orders?.length ? (
                  <MiniTable
                    head={['Date', 'Bags', 'Value', 'Status']}
                    rows={orders.map((o) => [
                      fmtDate(o.created_at),
                      o.bags_count,
                      money(o.total_value),
                      <OrderStatusBadge key={o.id} status={o.status} />,
                    ])}
                  />
                ) : (
                  <Empty>No orders yet.</Empty>
                )}
              </Section>

              {/* Lead history timeline */}
              <Section title="Lead history">
                {leads?.length ? (
                  <ol className="space-y-3">
                    {leads.map((l) => (
                      <li key={l.id} className="flex gap-3">
                        <span
                          className="mt-1 h-2.5 w-2.5 shrink-0 rounded-full"
                          style={{ background: (LEAD_META[l.status] || LEAD_META.COLD).color }}
                        />
                        <div className="min-w-0">
                          <div className="flex items-center gap-2">
                            <LeadBadge status={l.status} />
                            <span className="text-xs text-text-secondary">
                              {dayjs(l.created_at).format('MMM D, YYYY · HH:mm')}
                            </span>
                          </div>
                          {l.reason_note && (
                            <p className="mt-1 text-sm text-text-primary">{l.reason_note}</p>
                          )}
                          {l.employee_name && (
                            <p className="mt-0.5 text-xs text-text-secondary">by {l.employee_name}</p>
                          )}
                        </div>
                      </li>
                    ))}
                  </ol>
                ) : (
                  <Empty>No lead changes yet.</Empty>
                )}
              </Section>
            </div>
          )}
        </div>

        {/* Footer action */}
        <div className="border-t border-border px-5 py-4">
          <Button
            icon={FileBarChart}
            variant="secondary"
            className="w-full"
            onClick={() => navigate('/reports')}
          >
            Generate Report
          </Button>
        </div>
      </aside>
    </>
  );
}

function Row({ icon: Icon, text }) {
  return (
    <div className="flex items-center gap-2 text-sm text-text-secondary">
      <Icon className="h-4 w-4 shrink-0" />
      <span className="truncate">{text}</span>
    </div>
  );
}

function Mini({ label, value }) {
  return (
    <div className="rounded-btn border border-border p-3 text-center">
      <div className="text-xl font-bold text-text-primary">{value}</div>
      <div className="text-xs text-text-secondary">{label}</div>
    </div>
  );
}

function Section({ title, children }) {
  return (
    <div>
      <h3 className="mb-2 text-sm font-semibold text-text-primary">{title}</h3>
      {children}
    </div>
  );
}

function KV({ k, v }) {
  return (
    <div>
      <div className="text-xs text-text-secondary">{k}</div>
      <div className="text-text-primary">{v ?? '—'}</div>
    </div>
  );
}

function MiniTable({ head, rows }) {
  return (
    <div className="overflow-hidden rounded-btn border border-border">
      <table className="w-full text-left text-xs">
        <thead className="bg-surface/60 text-text-secondary">
          <tr>
            {head.map((h) => (
              <th key={h} className="px-2 py-1.5 font-semibold">{h}</th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.map((r, i) => (
            <tr key={i} className="border-t border-border/60">
              {r.map((c, j) => (
                <td key={j} className="px-2 py-1.5 text-text-primary">{c}</td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function Empty({ children }) {
  return (
    <p className="rounded-btn border border-dashed border-border p-3 text-center text-xs text-text-secondary">
      {children}
    </p>
  );
}

function pretty(s) {
  if (!s) return '';
  return s
    .toLowerCase()
    .split('_')
    .map((w) => (w ? w[0].toUpperCase() + w.slice(1) : w))
    .join(' ');
}

function money(v) {
  if (v == null) return '—';
  const n = Number(v);
  return `₹${Number.isInteger(n) ? n : n.toFixed(2)}`;
}
