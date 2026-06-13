import { useEffect, useMemo, useState } from 'react';
import { MapContainer, TileLayer, Marker, useMap } from 'react-leaflet';
import L from 'leaflet';
import { Wifi, WifiOff, X } from 'lucide-react';

import { useAdminLiveSocket } from '@/hooks/useWebSocket';
import { useEmployees } from '@/hooks/useEmployees';
import { useTeams } from '@/hooks/useTeams';
import PageHeader from '@/components/ui/PageHeader';
import Card from '@/components/ui/Card';
import Badge from '@/components/ui/Badge';
import Avatar from '@/components/ui/Avatar';
import { Select } from '@/components/ui/Input';

const STATUS_COLOR = {
  ACTIVE: '#4CAF7D',
  IDLE: '#F5A623',
  OFFLINE: '#9E9EAE',
};

function initials(name = '') {
  const p = name.trim().split(/\s+/).filter(Boolean);
  return p.length ? p.slice(0, 2).map((x) => x[0].toUpperCase()).join('') : '?';
}

function avatarIcon(member) {
  const color = STATUS_COLOR[member.status] || STATUS_COLOR.OFFLINE;
  const inner = member.photo_url
    ? `<img src="${member.photo_url}" style="width:100%;height:100%;object-fit:cover;border-radius:9999px"/>`
    : `<span style="font-weight:700;color:#8B7FD4;font-size:13px">${initials(member.name)}</span>`;
  return L.divIcon({
    className: 'ft-marker',
    html: `<div style="width:40px;height:40px;border-radius:9999px;background:${color};padding:2.5px;box-shadow:0 2px 6px rgba(0,0,0,.3)">
             <div style="width:100%;height:100%;border-radius:9999px;background:#fff;display:flex;align-items:center;justify-content:center;overflow:hidden">${inner}</div>
           </div>`,
    iconSize: [40, 40],
    iconAnchor: [20, 20],
  });
}

function FitBounds({ points }) {
  const map = useMap();
  useEffect(() => {
    if (points.length) {
      map.fitBounds(points.map((p) => [p.lat, p.lng]), { padding: [40, 40], maxZoom: 15 });
    }
    // Only re-fit when the number of plotted points changes (not on every tick).
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [points.length]);
  return null;
}

function Legend() {
  return (
    <div className="absolute bottom-4 left-4 z-[400] rounded-card border border-border bg-card/90 px-3 py-2 text-xs shadow-soft backdrop-blur">
      {Object.entries(STATUS_COLOR).map(([k, c]) => (
        <div key={k} className="flex items-center gap-2 text-text-secondary">
          <span className="h-2.5 w-2.5 rounded-full" style={{ background: c }} />
          {k.charAt(0) + k.slice(1).toLowerCase()}
        </div>
      ))}
    </div>
  );
}

export default function MapPage() {
  const { employees, status } = useAdminLiveSocket();
  const { data: emps } = useEmployees({});
  const { data: teams = [] } = useTeams();
  const [teamFilter, setTeamFilter] = useState('');
  const [selected, setSelected] = useState(null);

  // user_id → team_id (the WS payload doesn't carry team membership).
  const teamOf = useMemo(() => {
    const m = {};
    for (const e of emps?.items || []) m[e.id] = e.team_id;
    return m;
  }, [emps]);

  const located = employees.filter((e) => e.lat != null && e.lng != null);
  const filtered = teamFilter
    ? located.filter((e) => String(teamOf[e.user_id]) === String(teamFilter))
    : located;

  const center = filtered[0]
    ? [filtered[0].lat, filtered[0].lng]
    : [20.5937, 78.9629];

  return (
    <div className="space-y-4">
      <PageHeader
        title="Live Map"
        subtitle={`${filtered.length} on map`}
        actions={
          <div className="flex items-center gap-3">
            <span className="flex items-center gap-1.5 text-sm text-text-secondary">
              {status === 'open' ? (
                <Wifi className="h-4 w-4 text-status-active" />
              ) : (
                <WifiOff className="h-4 w-4 text-status-offline" />
              )}
              {status === 'open' ? 'Live' : 'Reconnecting…'}
            </span>
            <div className="w-44">
              <Select value={teamFilter} onChange={(e) => setTeamFilter(e.target.value)}>
                <option value="">All teams</option>
                {teams.map((t) => (
                  <option key={t.id} value={t.id}>{t.name}</option>
                ))}
              </Select>
            </div>
          </div>
        }
      />

      <div className="flex gap-4">
        <Card padded={false} className="relative h-[70vh] flex-1 overflow-hidden">
          <MapContainer
            center={center}
            zoom={13}
            style={{ height: '100%', width: '100%' }}
            scrollWheelZoom
          >
            <TileLayer
              url="https://tile.openstreetmap.org/{z}/{x}/{y}.png"
              attribution="&copy; OpenStreetMap contributors"
            />
            <FitBounds points={filtered} />
            {filtered.map((m) => (
              <Marker
                key={m.user_id}
                position={[m.lat, m.lng]}
                icon={avatarIcon(m)}
                eventHandlers={{ click: () => setSelected(m) }}
              />
            ))}
          </MapContainer>
          <Legend />
        </Card>

        {selected && (
          <Card className="hidden w-72 shrink-0 lg:block">
            <div className="flex items-start justify-between">
              <div className="flex items-center gap-2">
                <Avatar name={selected.name} src={selected.photo_url} size={44} />
                <div className="min-w-0">
                  <div className="truncate font-semibold text-text-primary">{selected.name}</div>
                  <Badge status={selected.status} />
                </div>
              </div>
              <button onClick={() => setSelected(null)} className="text-text-secondary hover:text-text-primary">
                <X className="h-4 w-4" />
              </button>
            </div>
            <dl className="mt-4 space-y-2 text-sm">
              <Row label="Attendance" value={stateLabel(selected.attendance_state)} />
              <Row
                label="Last seen"
                value={selected.last_seen ? relTime(selected.last_seen) : '—'}
              />
              <Row label="Battery" value={selected.battery_level != null ? `${selected.battery_level}%` : '—'} />
              <Row label="Team" value={teams.find((t) => t.id === teamOf[selected.user_id])?.name || '—'} />
            </dl>
          </Card>
        )}
      </div>
    </div>
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

function stateLabel(s) {
  if (s === 'STARTED' || s === 'RESUMED') return 'Working';
  if (s === 'ON_BREAK') return 'On break';
  if (s === 'ENDED') return 'Shift ended';
  return 'Not started';
}

// Lightweight relative-time without a dayjs plugin dependency.
function relTime(iso) {
  const diff = Date.now() - new Date(iso).getTime();
  const m = Math.floor(diff / 60000);
  if (m < 1) return 'just now';
  if (m < 60) return `${m}m ago`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h}h ago`;
  return `${Math.floor(h / 24)}d ago`;
}
