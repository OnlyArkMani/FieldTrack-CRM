import { useEffect, useMemo, useRef, useState } from "react";
import {
  MapContainer,
  TileLayer,
  Polyline,
  CircleMarker,
  Popup,
  Tooltip,
  useMap,
} from "react-leaflet";
import dayjs from "dayjs";
import { Play, Pause, RotateCcw } from "lucide-react";

import { useEmployeeRoute, useTrailSummary } from "@/hooks/useTrail";
import Modal from "@/components/ui/Modal";
import Spinner from "@/components/ui/Spinner";
import { Input } from "@/components/ui/Input";

const AMBER = "#F5A623";
const GREY = "#9E9EAE";
const ROUTE_BLUE = "#2563EB";
const VISIT_COLOR = "#8B5CF6";
const SESSION_STYLE = {
  START: { color: "#4CAF7D", label: "Start" },
  BREAK: { color: "#F5A623", label: "Break" },
  RESUME: { color: "#3B82F6", label: "Resume" },
  END: { color: "#E8645A", label: "End" },
  RE_CHECKIN: { color: "#8B5CF6", label: "Re-Check In" },
};
const TICK_MS = { 1: 100, 2: 50, 5: 20 };

async function fetchRoadRoute(coords) {
  if (!coords || coords.length < 2) return coords;
  let sampled = coords;
  if (coords.length > 60) {
    const step = Math.ceil(coords.length / 60);
    sampled = coords.filter((_, i) => i === 0 || i === coords.length - 1 || i % step === 0);
  }
  const waypointsStr = sampled.map(([lat, lng]) => `${lng},${lat}`).join(';');
  const url = `https://router.project-osrm.org/route/v1/driving/${waypointsStr}?overview=full&geometries=geojson`;
  try {
    const res = await fetch(url);
    if (!res.ok) return coords;
    const json = await res.json();
    if (json.routes && json.routes[0] && json.routes[0].geometry?.coordinates) {
      return json.routes[0].geometry.coordinates.map(([lng, lat]) => [lat, lng]);
    }
  } catch {
    // Fallback to direct coords if OSRM is unreachable
  }
  return coords;
}

const fmtDuration = (min) => {
  if (!min) return "0m";
  const h = Math.floor(min / 60);
  const m = min % 60;
  return h ? `${h}h ${m}m` : `${m}m`;
};

function Follow({ target }) {
  const map = useMap();
  useEffect(() => {
    if (target) map.panTo(target, { animate: true, duration: 0.25 });
  }, [target, map]);
  return null;
}

export default function TrailReplayModal({ open, onClose, employee }) {
  const [date, setDate] = useState(dayjs().format("YYYY-MM-DD"));
  const [idx, setIdx] = useState(0);
  const [playing, setPlaying] = useState(false);
  const [speed, setSpeed] = useState(1);
  const timer = useRef(null);

  const { data, isLoading } = useEmployeeRoute(employee?.id, date, open);
  const { data: summary } = useTrailSummary(employee?.id, 31, open);
  const points = useMemo(() => data?.points || [], [data]);
  const sessions = data?.sessions || [];
  const visits = data?.visits || [];
  const maxDayMeters = useMemo(
    () => Math.max(1, ...(summary?.days || []).map((d) => d.distance_meters)),
    [summary],
  );

  // Reset playback whenever the route changes (new date / fresh fetch).
  useEffect(() => {
    setIdx(0);
    setPlaying(false);
  }, [date, data]);

  // Playback timer.
  useEffect(() => {
    clearInterval(timer.current);
    if (!playing || points.length === 0) return undefined;
    timer.current = setInterval(() => {
      setIdx((i) => {
        if (i >= points.length - 1) {
          clearInterval(timer.current);
          setPlaying(false);
          return i;
        }
        return i + 1;
      });
    }, TICK_MS[speed]);
    return () => clearInterval(timer.current);
  }, [playing, speed, points.length]);

  const latlngs = useMemo(() => points.map((p) => [p.lat, p.lng]), [points]);
  const [roadPath, setRoadPath] = useState([]);

  useEffect(() => {
    let canceled = false;
    if (latlngs.length >= 2) {
      fetchRoadRoute(latlngs).then((res) => {
        if (!canceled) setRoadPath(res);
      });
    } else {
      setRoadPath(latlngs);
    }
    return () => {
      canceled = true;
    };
  }, [latlngs]);

  const displayPath = roadPath.length > 0 ? roadPath : latlngs;

  const playedLatLngs = useMemo(() => {
    if (!displayPath || displayPath.length === 0) return [];
    if (points.length <= 1) return displayPath;
    const progress = idx / Math.max(1, points.length - 1);
    const roadIdx = Math.min(
      displayPath.length - 1,
      Math.floor(progress * (displayPath.length - 1))
    );
    return displayPath.slice(0, roadIdx + 1);
  }, [displayPath, points.length, idx]);

  const currentPos = useMemo(() => {
    if (!displayPath || displayPath.length === 0) {
      const p = points[idx];
      return p ? [p.lat, p.lng] : null;
    }
    if (points.length <= 1) return displayPath[0];
    const progress = idx / Math.max(1, points.length - 1);
    const roadIdx = Math.min(
      displayPath.length - 1,
      Math.floor(progress * (displayPath.length - 1))
    );
    return displayPath[roadIdx];
  }, [displayPath, points, idx]);

  const current = points[idx];
  const mapCenter = latlngs[0] || [20.5937, 78.9629];

  return (
    <Modal
      open={open}
      onClose={onClose}
      title={`Trail · ${employee?.name || ""}`}
      size="lg"
    >
      <div className="space-y-3">
        {/* Date + stats */}
        <div className="flex flex-wrap items-end gap-3">
          <div className="w-44">
            <Input
              label="Date"
              type="date"
              max={dayjs().format("YYYY-MM-DD")}
              value={date}
              onChange={(e) => setDate(e.target.value)}
            />
          </div>
          <div className="flex flex-1 gap-4 text-sm">
            <Stat
              label="Distance"
              value={`${((data?.total_distance_meters || 0) / 1000).toFixed(2)} km`}
            />
            <Stat
              label="Active time"
              value={fmtDuration(data?.total_duration_minutes || 0)}
            />
            <Stat label="GPS Ping Points" value={points.length} />
            <Stat label="Visits" value={visits.length} />
          </div>
        </div>

        {/* 30-day distance report */}
        {summary?.days?.length > 0 && (
          <div>
            <div className="mb-1 flex items-baseline justify-between text-xs text-text-secondary">
              <span>Last 31 days</span>
              <span>
                Total {((summary.total_distance_meters || 0) / 1000).toFixed(1)}{" "}
                km
              </span>
            </div>
            <div className="flex gap-1 overflow-x-auto pb-1">
              {summary.days.map((d) => {
                const isSelected = d.date === date;
                const heightPct = Math.max(
                  6,
                  (d.distance_meters / maxDayMeters) * 100,
                );
                return (
                  <button
                    key={d.date}
                    type="button"
                    disabled={!d.has_trail}
                    onClick={() => setDate(d.date)}
                    title={`${dayjs(d.date).format("DD MMM")} · ${(d.distance_meters / 1000).toFixed(2)} km`}
                    className={`flex h-16 w-6 shrink-0 flex-col items-center justify-end gap-1 rounded-btn px-0.5 pb-1 text-[10px] ${
                      isSelected
                        ? "bg-primary/16"
                        : d.has_trail
                          ? "hover:bg-border/50"
                          : "opacity-30"
                    }`}
                  >
                    <div
                      className="w-full rounded-sm"
                      style={{
                        height: `${heightPct}%`,
                        background: isSelected
                          ? AMBER
                          : d.has_trail
                            ? "#9E9EAE"
                            : "transparent",
                      }}
                    />
                    <span className="text-text-secondary">
                      {dayjs(d.date).format("D")}
                    </span>
                  </button>
                );
              })}
            </div>
          </div>
        )}

        {/* Map */}
        <div className="h-[460px] overflow-hidden rounded-card border border-border">
          {isLoading ? (
            <div className="grid h-full place-items-center">
              <Spinner label="Loading trail…" />
            </div>
          ) : points.length === 0 ? (
            <div className="grid h-full place-items-center text-center text-sm text-text-secondary">
              No location data for this date
            </div>
          ) : (
            <MapContainer
              center={mapCenter}
              zoom={15}
              style={{ height: "100%", width: "100%" }}
            >
              <TileLayer
                url="https://tile.openstreetmap.org/{z}/{x}/{y}.png"
                attribution="&copy; OpenStreetMap contributors"
              />
              {/* full route (blue, road-following via OSRM) */}
              <Polyline
                positions={displayPath}
                pathOptions={{ color: ROUTE_BLUE, weight: 4, opacity: 0.95 }}
              />
              {/* played portion (amber, thicker) */}
              <Polyline
                positions={playedLatLngs}
                pathOptions={{ color: AMBER, weight: 4 }}
              />
              {/* mock-GPS warnings */}
              {points
                .filter((p) => p.is_mock_gps)
                .map((p, i) => (
                  <CircleMarker
                    key={`mock-${i}`}
                    center={[p.lat, p.lng]}
                    radius={4}
                    pathOptions={{
                      color: "#E8645A",
                      fillColor: "#E8645A",
                      fillOpacity: 1,
                    }}
                  />
                ))}
              {/* session markers */}
              {sessions
                .filter((s) => s.lat != null && s.lng != null)
                .map((s, i) => {
                  const st = SESSION_STYLE[s.type] || SESSION_STYLE.START;
                  return (
                    <CircleMarker
                      key={`s-${i}`}
                      center={[s.lat, s.lng]}
                      radius={7}
                      pathOptions={{
                        color: "#fff",
                        fillColor: st.color,
                        fillOpacity: 1,
                        weight: 2,
                      }}
                    >
                      <Tooltip permanent direction="top" offset={[0, -8]} opacity={0.75} interactive>
                        <div className="text-xs p-0.5 text-center min-w-[90px]">
                          <div className="font-bold text-gray-900 text-sm">
                            {st.label === "Start" ? "Check-in" : st.label === "End" ? "Check-out" : `${st.label} Session`}
                          </div>
                          <div className="text-gray-600 font-medium my-0.5">
                            {dayjs(s.timestamp).format("HH:mm")}
                          </div>
                          <div className="text-[10px] text-gray-500 font-mono">
                            {s.lat.toFixed(4)}, {s.lng.toFixed(4)}
                          </div>
                        </div>
                      </Tooltip>
                    </CircleMarker>
                  );
                })}
              {/* completed farmer visits */}
              {visits.map((v) => (
                <CircleMarker
                  key={`visit-${v.visit_id}`}
                  center={[v.lat, v.lng]}
                  radius={8}
                  pathOptions={{
                    color: "#fff",
                    fillColor: VISIT_COLOR,
                    fillOpacity: 1,
                    weight: 2,
                  }}
                >
                  <Tooltip
                    permanent
                    direction="top"
                    offset={[0, -8]}
                    opacity={0.75}
                    interactive
                  >
                    <div className="text-xs p-0.5 text-center min-w-[100px]">
                      <div className="font-bold text-gray-900 text-sm">
                        {v.farmer_name || "Farmer visit"}
                      </div>
                      <div className="text-gray-600 font-medium my-0.5">
                        {dayjs(v.timestamp).format("HH:mm")} · {v.status}
                      </div>
                      <div className="text-[10px] text-gray-500 font-mono">
                        {v.lat != null ? v.lat.toFixed(4) : "—"}, {v.lng != null ? v.lng.toFixed(4) : "—"}
                      </div>
                      {v.location_warning && (
                        <div className="text-red-600 font-semibold text-[10px] mt-0.5">
                          ⚠️ Check-in far from location
                        </div>
                      )}
                    </div>
                  </Tooltip>
                </CircleMarker>
              ))}
              {/* current position */}
              {currentPos && (
                <CircleMarker
                  center={currentPos}
                  radius={8}
                  pathOptions={{
                    color: "#fff",
                    fillColor: AMBER,
                    fillOpacity: 1,
                    weight: 3,
                  }}
                />
              )}
              <Follow target={currentPos} />
            </MapContainer>
          )}
        </div>

        {/* Controls */}
        {points.length > 0 && (
          <>
            <div className="flex items-center gap-2">
              <button
                onClick={() => {
                  setIdx(0);
                  setPlaying(false);
                }}
                className="grid h-9 w-9 place-items-center rounded-btn text-text-secondary hover:bg-border/50"
                title="Restart"
              >
                <RotateCcw className="h-4 w-4" />
              </button>
              <button
                onClick={() => setPlaying((p) => !p)}
                className="grid h-9 w-9 place-items-center rounded-btn bg-primary text-primary-fg"
                title={playing ? "Pause" : "Play"}
              >
                {playing ? (
                  <Pause className="h-4 w-4" />
                ) : (
                  <Play className="h-4 w-4" />
                )}
              </button>
              <div className="ml-2 flex gap-1">
                {[1, 2, 5].map((s) => (
                  <button
                    key={s}
                    onClick={() => setSpeed(s)}
                    className={`rounded-btn px-2.5 py-1 text-xs font-medium ${
                      speed === s
                        ? "bg-primary/16 text-primary"
                        : "text-text-secondary hover:bg-border/50"
                    }`}
                  >
                    {s}x
                  </button>
                ))}
              </div>
              {current && (
                <div className="ml-auto flex items-center gap-2 text-xs text-text-secondary">
                  <span>{dayjs(current.timestamp).format("HH:mm:ss")}</span>
                  <span>
                    ·{" "}
                    {current.speed != null
                      ? `${(current.speed * 3.6).toFixed(1)} km/h`
                      : "—"}
                  </span>
                  {current.attendance_state && (
                    <span
                      className="rounded-full px-2 py-0.5"
                      style={{ background: `${AMBER}24`, color: AMBER }}
                    >
                      {current.attendance_state}
                    </span>
                  )}
                </div>
              )}
            </div>

            <input
              type="range"
              min={0}
              max={Math.max(0, points.length - 1)}
              value={idx}
              onChange={(e) => {
                setPlaying(false);
                setIdx(Number(e.target.value));
              }}
              className="w-full accent-[var(--ft-primary)]"
            />
          </>
        )}
      </div>
    </Modal>
  );
}

function Stat({ label, value }) {
  return (
    <div>
      <div className="font-semibold text-text-primary">{value}</div>
      <div className="text-xs text-text-secondary">{label}</div>
    </div>
  );
}
