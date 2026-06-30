import { useState } from 'react';
import {
  PieChart,
  Pie,
  Cell,
  ResponsiveContainer,
  Legend,
  Tooltip,
} from 'recharts';

import { usePipeline } from '@/hooks/useLeads';
import Card, { CardHeader } from '@/components/ui/Card';
import Spinner from '@/components/ui/Spinner';
import { Select } from '@/components/ui/Input';

const COLORS = {
  Hot: 'var(--ft-danger)',
  Warm: 'var(--ft-primary)',
  Cold: 'var(--ft-secondary)',
};

/** Hot/Warm/Cold donut with a team filter; clicking a slice filters the
 *  employee breakdown table below to employees holding that lead type. */
export default function LeadPipelineCard() {
  const { data, isLoading } = usePipeline();
  const [team, setTeam] = useState('');
  const [active, setActive] = useState(null); // 'Hot' | 'Warm' | 'Cold' | null

  if (isLoading || !data) {
    return (
      <Card>
        <CardHeader title="Lead pipeline" subtitle="Hot / Warm / Cold" />
        <Spinner label="Loading pipeline…" className="py-10" />
      </Card>
    );
  }

  const byTeam = data.by_team || [];
  const totals =
    team && byTeam.length
      ? byTeam.find((t) => t.team_name === team) || { hot: 0, warm: 0, cold: 0 }
      : { hot: data.hot_count, warm: data.warm_count, cold: data.cold_count };

  const chart = [
    { name: 'Hot', value: totals.hot || 0 },
    { name: 'Warm', value: totals.warm || 0 },
    { name: 'Cold', value: totals.cold || 0 },
  ];
  const empty = chart.every((c) => c.value === 0);

  const statusKey = active ? active.toLowerCase() : null;
  const employees = (data.by_employee || [])
    .filter((e) => (statusKey ? e[statusKey] > 0 : true))
    .sort((a, b) =>
      statusKey ? b[statusKey] - a[statusKey] : a.name.localeCompare(b.name),
    );

  return (
    <Card>
      <CardHeader
        title="Lead pipeline"
        subtitle={
          active
            ? `Employees with ${active} leads — click the centre to clear`
            : 'Click a slice to drill into employees'
        }
        action={
          <div className="w-44">
            <Select
              value={team}
              onChange={(e) => setTeam(e.target.value)}
              aria-label="Team filter"
            >
              <option value="">All teams</option>
              {byTeam.map((t) => (
                <option key={t.team_name} value={t.team_name}>
                  {t.team_name}
                </option>
              ))}
            </Select>
          </div>
        }
      />

      <div className="grid grid-cols-1 gap-6 lg:grid-cols-2">
        <div className="h-60">
          {empty ? (
            <div className="grid h-full place-items-center text-sm text-text-secondary">
              No leads yet.
            </div>
          ) : (
            <ResponsiveContainer width="100%" height="100%">
              <PieChart>
                <Pie
                  data={chart}
                  dataKey="value"
                  nameKey="name"
                  innerRadius={55}
                  outerRadius={85}
                  paddingAngle={2}
                  stroke="none"
                  onClick={(d) =>
                    setActive((prev) => (prev === d.name ? null : d.name))
                  }
                >
                  {chart.map((c) => (
                    <Cell
                      key={c.name}
                      fill={COLORS[c.name]}
                      opacity={active && active !== c.name ? 0.35 : 1}
                      cursor="pointer"
                    />
                  ))}
                </Pie>
                <Tooltip
                  contentStyle={{
                    background: 'var(--ft-card)',
                    border: '1px solid var(--ft-border)',
                    borderRadius: 12,
                  }}
                />
                <Legend />
              </PieChart>
            </ResponsiveContainer>
          )}
        </div>

        <div className="overflow-hidden rounded-card border border-border/60">
          <table className="w-full text-left text-sm">
            <thead className="bg-surface/60 text-text-secondary">
              <tr>
                <th className="px-3 py-2 font-semibold">Employee</th>
                <th className="px-3 py-2 text-center font-semibold">Hot</th>
                <th className="px-3 py-2 text-center font-semibold">Warm</th>
                <th className="px-3 py-2 text-center font-semibold">Cold</th>
              </tr>
            </thead>
            <tbody>
              {employees.length === 0 ? (
                <tr>
                  <td colSpan={4} className="px-3 py-6 text-center text-text-secondary">
                    No employees to show
                  </td>
                </tr>
              ) : (
                employees.map((e) => (
                  <tr key={e.name} className="border-t border-border/60">
                    <td className="px-3 py-2 font-medium text-text-primary">{e.name}</td>
                    <Num v={e.hot} color={COLORS.Hot} on={active === 'Hot'} />
                    <Num v={e.warm} color={COLORS.Warm} on={active === 'Warm'} />
                    <Num v={e.cold} color={COLORS.Cold} on={active === 'Cold'} />
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </div>
      </div>
    </Card>
  );
}

function Num({ v, color, on }) {
  return (
    <td className="px-3 py-2 text-center">
      <span
        className="font-semibold"
        style={{ color: v > 0 ? color : 'var(--ft-text-secondary)', opacity: on || v === 0 ? 1 : 0.85 }}
      >
        {v}
      </span>
    </td>
  );
}
