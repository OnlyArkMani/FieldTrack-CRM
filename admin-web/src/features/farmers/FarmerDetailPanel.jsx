import { useNavigate } from 'react-router-dom';
import dayjs from 'dayjs';
import { X, Phone, MapPin, Users, FileBarChart } from 'lucide-react';

import {
  useFarmer,
  useFarmerVisits,
  useFarmerLivestock,
  useFarmerLeadHistory,
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

function fmtDate(d) {
  return d ? dayjs(d).format('MMM D, YYYY') : '—';
}

/** Right-side slide-in farmer detail panel (400px). */
export default function FarmerDetailPanel({ farmerId, open, onClose }) {
  const navigate = useNavigate();
  const { data: farmer, isLoading } = useFarmer(open ? farmerId : null);
  const { data: visits } = useFarmerVisits(open ? farmerId : null);
  const { data: livestock } = useFarmerLivestock(open ? farmerId : null);
  const { data: leads } = useFarmerLeadHistory(open ? farmerId : null);

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
            {farmer?.name || 'Farmer'}
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
                  <LeadBadge status={farmer.current_lead?.status} />
                  {!farmer.is_active && (
                    <Badge color="var(--ft-status-offline)">Inactive</Badge>
                  )}
                </div>
                {farmer.village && (
                  <Row icon={MapPin} text={[farmer.village, farmer.district].filter(Boolean).join(', ')} />
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
                    <KV k="Price/bag" v={money(farmer.latest_livestock.current_price_per_bag)} />
                  </div>
                ) : (
                  <Empty>No livestock recorded.</Empty>
                )}
              </Section>

              {/* Visit history */}
              <Section title={`Visit history (${visits?.total ?? 0})`}>
                {visits?.items?.length ? (
                  <MiniTable
                    head={['Date', 'Purpose', 'Status']}
                    rows={visits.items.map((v) => [
                      fmtDate(v.check_in_at || v.created_at),
                      pretty(v.purpose) || 'Visit',
                      pretty(v.status),
                    ])}
                  />
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
