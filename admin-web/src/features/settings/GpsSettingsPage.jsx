import { useState, useEffect } from 'react';
import { Save, RotateCcw, Radio } from 'lucide-react';

import { useTeams } from '@/hooks/useTeams';
import { useTeamGpsConfig, useSaveGpsConfig, GPS_DEFAULTS } from '@/hooks/useGpsConfig';
import Card, { CardHeader } from '@/components/ui/Card';
import PageHeader from '@/components/ui/PageHeader';
import { Select } from '@/components/ui/Input';

// ── Slider ──────────────────────────────────────────────────────────────────

function ConfigSlider({ label, hint, value, min, max, step = 1, format, onChange }) {
  const pct = ((value - min) / (max - min)) * 100;
  return (
    <div className="space-y-2">
      <div className="flex items-center justify-between">
        <div>
          <div className="text-sm font-medium text-text-primary">{label}</div>
          {hint && <div className="text-xs text-text-secondary">{hint}</div>}
        </div>
        <span className="min-w-[80px] text-right text-sm font-semibold text-primary">
          {format(value)}
        </span>
      </div>
      <div className="relative flex items-center">
        <input
          type="range"
          min={min}
          max={max}
          step={step}
          value={value}
          onChange={(e) => onChange(Number(e.target.value))}
          className="h-2 w-full cursor-pointer appearance-none rounded-full"
          style={{
            background: `linear-gradient(to right, var(--ft-primary) ${pct}%, var(--ft-border) ${pct}%)`,
          }}
        />
      </div>
      <div className="flex justify-between text-[10px] text-text-secondary/70">
        <span>{format(min)}</span>
        <span>{format(max)}</span>
      </div>
    </div>
  );
}

function fmtSecs(s) {
  if (s < 60) return `${s}s`;
  const m = Math.round(s / 60);
  return m === 1 ? '1 minute' : `${m} minutes`;
}

// ── Main page ────────────────────────────────────────────────────────────────

export default function GpsSettingsPage() {
  const { data: teamsData } = useTeams();
  const teams = Array.isArray(teamsData) ? teamsData : (teamsData?.items || []);

  const [teamId, setTeamId] = useState('');
  const [toast, setToast] = useState(null); // { type: 'success'|'error', msg }

  // Local slider state — initialised from fetched config
  const [cfg, setCfg] = useState({ ...GPS_DEFAULTS });
  const { data: remote, isLoading } = useTeamGpsConfig(teamId);
  const save = useSaveGpsConfig(teamId);

  // Sync sliders when remote data arrives or team changes
  useEffect(() => {
    if (remote) setCfg({ ...GPS_DEFAULTS, ...remote });
  }, [remote]);

  // Auto-select first team once loaded
  useEffect(() => {
    if (!teamId && teams.length > 0) setTeamId(String(teams[0].id));
  }, [teams, teamId]);

  const selectedTeamName = teams.find((t) => String(t.id) === teamId)?.name ?? '';

  function update(key, val) {
    setCfg((c) => ({ ...c, [key]: val }));
  }

  function handleReset() {
    setCfg({ ...GPS_DEFAULTS });
  }

  async function handleSave() {
    if (!teamId) return;
    try {
      await save.mutateAsync({
        moving_interval_seconds: cfg.moving_interval_seconds,
        stationary_interval_seconds: cfg.stationary_interval_seconds,
        low_battery_interval_seconds: cfg.low_battery_interval_seconds,
        low_battery_threshold: cfg.low_battery_threshold,
      });
      setToast({
        type: 'success',
        msg: `Configuration saved for ${selectedTeamName}. Changes apply on employees' next attendance start.`,
      });
    } catch {
      setToast({ type: 'error', msg: 'Failed to save. Please try again.' });
    }
    setTimeout(() => setToast(null), 5000);
  }

  return (
    <div className="space-y-6">
      <PageHeader
        title="GPS Tracking"
        subtitle="Configure location update intervals per team"
        icon={<Radio className="h-6 w-6 text-primary" />}
      />

      {/* Toast */}
      {toast && (
        <div
          className={`rounded-card border px-4 py-3 text-sm font-medium ${
            toast.type === 'success'
              ? 'border-amber-300 bg-amber-50 text-amber-800'
              : 'border-danger/30 bg-danger/10 text-danger'
          }`}
        >
          {toast.msg}
        </div>
      )}

      {/* Team selector */}
      <div className="flex items-center gap-3">
        <label className="text-sm font-medium text-text-secondary">Team</label>
        <div className="w-56">
          <Select
            value={teamId}
            onChange={(e) => setTeamId(e.target.value)}
            disabled={teams.length === 0}
          >
            {teams.length === 0 && <option value="">No teams yet</option>}
            {teams.map((t) => (
              <option key={t.id} value={t.id}>{t.name}</option>
            ))}
          </Select>
        </div>
      </div>

      {/* Config card */}
      <Card>
        <CardHeader
          title="GPS Tracking Configuration"
          subtitle={selectedTeamName ? `Team: ${selectedTeamName}` : 'Select a team above'}
        />

        {isLoading ? (
          <div className="py-10 text-center text-sm text-text-secondary">Loading…</div>
        ) : (
          <div className="space-y-8 py-2">
            <ConfigSlider
              label="Moving Interval"
              hint="How often to record location when the employee is moving (speed > 0.5 m/s)"
              value={cfg.moving_interval_seconds}
              min={60}
              max={600}
              step={30}
              format={fmtSecs}
              onChange={(v) => update('moving_interval_seconds', v)}
            />

            <ConfigSlider
              label="Stationary Interval"
              hint="How often to record location when the employee is not moving"
              value={cfg.stationary_interval_seconds}
              min={300}
              max={1800}
              step={60}
              format={fmtSecs}
              onChange={(v) => update('stationary_interval_seconds', v)}
            />

            <ConfigSlider
              label="Low Battery Interval"
              hint="Wider interval to conserve battery when level is below threshold"
              value={cfg.low_battery_interval_seconds}
              min={600}
              max={3600}
              step={60}
              format={fmtSecs}
              onChange={(v) => update('low_battery_interval_seconds', v)}
            />

            <ConfigSlider
              label="Low Battery Threshold"
              hint="Battery percentage that triggers low-battery mode"
              value={cfg.low_battery_threshold}
              min={10}
              max={30}
              step={1}
              format={(v) => `${v}%`}
              onChange={(v) => update('low_battery_threshold', v)}
            />

            <div className="flex items-center justify-between border-t border-border pt-4">
              <button
                type="button"
                onClick={handleReset}
                className="flex items-center gap-2 rounded-btn px-4 py-2 text-sm text-text-secondary hover:bg-surface hover:text-text-primary"
              >
                <RotateCcw className="h-4 w-4" />
                Reset to defaults
              </button>

              <button
                type="button"
                onClick={handleSave}
                disabled={save.isPending || !teamId}
                className="flex items-center gap-2 rounded-btn bg-primary px-5 py-2.5 text-sm font-semibold text-white transition-opacity hover:opacity-90 disabled:opacity-50"
              >
                {save.isPending ? (
                  <>
                    <span className="h-4 w-4 animate-spin rounded-full border-2 border-white border-t-transparent" />
                    Saving…
                  </>
                ) : (
                  <>
                    <Save className="h-4 w-4" />
                    Save Configuration
                  </>
                )}
              </button>
            </div>
          </div>
        )}
      </Card>

      {/* Informational note */}
      <p className="text-xs text-text-secondary">
        Changes take effect the next time an employee starts their attendance.
        Active sessions continue using the previous configuration.
      </p>
    </div>
  );
}
