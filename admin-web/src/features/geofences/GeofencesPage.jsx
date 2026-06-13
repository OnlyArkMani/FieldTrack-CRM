import { useEffect, useMemo, useState } from 'react';
import {
  MapContainer,
  TileLayer,
  Circle,
  Polygon,
  Tooltip,
  useMap,
} from 'react-leaflet';
import { Plus, Trash2, Circle as CircleIcon, Hexagon } from 'lucide-react';

import { useGeofences, useDeleteGeofence } from '@/hooks/useGeofences';
import { apiErrorMessage } from '@/services/api/client';
import PageHeader from '@/components/ui/PageHeader';
import Card from '@/components/ui/Card';
import Button from '@/components/ui/Button';
import Spinner from '@/components/ui/Spinner';
import GeofenceCreateModal from './GeofenceCreateModal';

const AMBER = '#F5A623';
const fill = { color: AMBER, fillColor: AMBER, fillOpacity: 0.15, weight: 2 };

// Backend ring is [[lng,lat],...] (closed). Leaflet wants [[lat,lng],...].
const toLatLng = (coords) =>
  (coords || [])
    .map(([lng, lat]) => [lat, lng])
    .filter((_, i, a) => !(i === a.length - 1 && i > 0));

const fmtArea = (sqm) =>
  !sqm
    ? ''
    : sqm >= 1_000_000
      ? `${(sqm / 1_000_000).toFixed(2)} km²`
      : `${Math.round(sqm).toLocaleString()} m²`;

function FlyController({ target }) {
  const map = useMap();
  useEffect(() => {
    if (target) map.flyTo(target, 15, { duration: 1.5 });
  }, [target, map]);
  return null;
}

function ZoneTooltip({ g }) {
  const area =
    g.shape_type === 'CIRCLE'
      ? Math.PI * (g.radius_meters || 0) ** 2
      : g.area_sq_meters;
  return (
    <Tooltip sticky>
      <div className="text-xs">
        <div className="font-semibold">{g.name}</div>
        <div>
          {g.shape_type === 'CIRCLE' ? 'Circle' : 'Polygon'} · {fmtArea(area)}
        </div>
      </div>
    </Tooltip>
  );
}

export default function GeofencesPage() {
  const { data: geofences = [], isLoading } = useGeofences();
  const del = useDeleteGeofence();
  const [creating, setCreating] = useState(false);
  const [flyTarget, setFlyTarget] = useState(null);

  const center = useMemo(() => {
    const g = geofences[0];
    if (!g) return [20.5937, 78.9629];
    if (g.shape_type === 'CIRCLE' && g.center_lat != null) {
      return [g.center_lat, g.center_lng];
    }
    const ring = toLatLng(g.coordinates);
    return ring[0] || [20.5937, 78.9629];
  }, [geofences]);

  const remove = async (g) => {
    if (!window.confirm(`Delete "${g.name}"?`)) return;
    try {
      await del.mutateAsync(g.id);
    } catch (err) {
      alert(apiErrorMessage(err));
    }
  };

  return (
    <div className="space-y-4">
      <PageHeader
        title="Geofences"
        subtitle={`${geofences.length} zone${geofences.length === 1 ? '' : 's'}`}
        actions={
          <Button icon={Plus} onClick={() => setCreating(true)}>
            New geofence
          </Button>
        }
      />

      <div className="flex flex-col gap-4 lg:flex-row">
        <Card padded={false} className="h-[68vh] flex-1 overflow-hidden">
          <MapContainer center={center} zoom={12} style={{ height: '100%', width: '100%' }}>
            <TileLayer
              url="https://tile.openstreetmap.org/{z}/{x}/{y}.png"
              attribution="&copy; OpenStreetMap contributors"
            />
            <FlyController target={flyTarget} />
            {geofences.map((g) =>
              g.shape_type === 'CIRCLE' && g.center_lat != null ? (
                <Circle
                  key={g.id}
                  center={[g.center_lat, g.center_lng]}
                  radius={g.radius_meters}
                  pathOptions={fill}
                >
                  <ZoneTooltip g={g} />
                </Circle>
              ) : (
                <Polygon key={g.id} positions={toLatLng(g.coordinates)} pathOptions={fill}>
                  <ZoneTooltip g={g} />
                </Polygon>
              ),
            )}
          </MapContainer>
        </Card>

        <div className="w-full lg:w-80">
          <Card padded={false}>
            <div className="border-b border-border px-4 py-3 text-sm font-semibold text-text-primary">
              {geofences.length} zone{geofences.length === 1 ? '' : 's'}
            </div>
            {isLoading ? (
              <Spinner label="Loading…" className="py-8" />
            ) : geofences.length === 0 ? (
              <p className="px-4 py-8 text-center text-sm text-text-secondary">
                No geofences yet. Click “New geofence” to draw one.
              </p>
            ) : (
              <ul className="divide-y divide-border">
                {geofences.map((g) => (
                  <li
                    key={g.id}
                    className="flex cursor-pointer items-center gap-2 px-4 py-3 hover:bg-surface"
                    onClick={() =>
                      g.shape_type === 'CIRCLE' && g.center_lat != null
                        ? setFlyTarget([g.center_lat, g.center_lng])
                        : setFlyTarget(toLatLng(g.coordinates)[0])
                    }
                  >
                    {g.shape_type === 'CIRCLE' ? (
                      <CircleIcon className="h-4 w-4 shrink-0 text-primary" />
                    ) : (
                      <Hexagon className="h-4 w-4 shrink-0 text-primary" />
                    )}
                    <div className="min-w-0 flex-1">
                      <div className="truncate font-medium text-text-primary">{g.name}</div>
                      <div className="truncate text-xs text-text-secondary">
                        {g.shape_type === 'CIRCLE'
                          ? `Circle · ${Math.round(g.radius_meters)} m radius`
                          : `Polygon · ${g.coordinates.length - 1} vertices`}
                      </div>
                    </div>
                    <Button
                      size="sm"
                      variant="ghost"
                      icon={Trash2}
                      onClick={(ev) => {
                        ev.stopPropagation();
                        remove(g);
                      }}
                      title="Delete"
                    />
                  </li>
                ))}
              </ul>
            )}
          </Card>
        </div>
      </div>

      <GeofenceCreateModal
        open={creating}
        onClose={() => setCreating(false)}
        onCreated={(target) => setFlyTarget(target)}
      />
    </div>
  );
}
