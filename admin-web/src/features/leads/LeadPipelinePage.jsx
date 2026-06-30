import { useState } from 'react';
import { Download, TrendingUp } from 'lucide-react';
import dayjs from 'dayjs';

import { usePipeline, useTeamLeads } from '@/hooks/useLeads';
import { useTeams } from '@/hooks/useTeams';
import { useEmployees } from '@/hooks/useEmployees';
import { api } from '@/services/api/client';
import Card, { CardHeader } from '@/components/ui/Card';
import PageHeader from '@/components/ui/PageHeader';
import Spinner from '@/components/ui/Spinner';
import { Select } from '@/components/ui/Input';

const STATUS_COLORS = {
  HOT: { bg: 'bg-danger/15', text: 'text-danger', label: 'Hot' },
  WARM: { bg: 'bg-primary/15', text: 'text-primary', label: 'Warm' },
  COLD: { bg: 'bg-secondary/15', text: 'text-secondary', label: 'Cold' },
};

function LeadBadge({ status }) {
  const cfg = STATUS_COLORS[status?.toUpperCase()] || { bg: 'bg-border/40', text: 'text-text-secondary', label: status };
  return (
    <span className={`inline-flex items-center rounded-full px-2 py-0.5 text-xs font-semibold ${cfg.bg} ${cfg.text}`}>
      {cfg.label}
    </span>
  );
}

function StatMini({ label, value, color }) {
  return (
    <div className="rounded-card border border-border p-4 text-center">
      <div className="text-2xl font-bold" style={{ color }}>{value ?? '—'}</div>
      <div className="mt-0.5 text-xs text-text-secondary">{label}</div>
    </div>
  );
}

export default function LeadPipelinePage() {
  const [teamId, setTeamId] = useState('');
  const [employeeId, setEmployeeId] = useState('');
  const [statusFilter, setStatusFilter] = useState('');
  const [exporting, setExporting] = useState(false);

  const { data: pipeline } = usePipeline();
  const { data: leads, isLoading } = useTeamLeads({
    status: statusFilter || undefined,
    employeeId: employeeId || undefined,
  });
  const { data: teamsData } = useTeams();
  const { data: empsData } = useEmployees({ teamId: teamId || undefined, limit: 100 });

  const teams = Array.isArray(teamsData) ? teamsData : (teamsData?.items || []);
  const employees = empsData?.items || [];
  const leadList = Array.isArray(leads) ? leads : (leads?.items || []);

  // Conversion rate = share of all leads that have reached HOT (closest to a
  // sale). Displayed alongside the Hot/Warm/Cold counts.
  const totalLeads =
    (pipeline?.hot_count ?? 0) + (pipeline?.warm_count ?? 0) + (pipeline?.cold_count ?? 0);
  const conversionRate =
    totalLeads > 0 ? Math.round(((pipeline?.hot_count ?? 0) / totalLeads) * 100) : 0;

  const today = dayjs().format('YYYY-MM-DD');
  const overdueIds = new Set(
    leadList
      .filter((l) => l.follow_up_date && l.follow_up_date < today && l.follow_up_status !== 'DONE')
      .map((l) => l.id),
  );

  async function handleExport() {
    setExporting(true);
    try {
      const params = { format: 'EXCEL', report_type: 'LEAD_PIPELINE' };
      if (employeeId) params.employee_id = employeeId;
      const res = await api.get('/reports/generate', {
        params,
        responseType: 'blob',
      });
      const url = URL.createObjectURL(res.data);
      const a = document.createElement('a');
      a.href = url;
      a.download = `lead_pipeline_${today}.xlsx`;
      a.click();
      URL.revokeObjectURL(url);
    } catch {
      // ignore — user sees no download
    } finally {
      setExporting(false);
    }
  }

  return (
    <div className="space-y-6">
      <PageHeader
        title="Lead Pipeline"
        subtitle="Track Hot, Warm, and Cold leads across your team"
        action={
          <button
            type="button"
            onClick={handleExport}
            disabled={exporting}
            className="flex items-center gap-2 rounded-btn border border-border bg-card px-4 py-2 text-sm font-medium text-text-primary hover:bg-surface disabled:opacity-50"
          >
            <Download className="h-4 w-4" />
            {exporting ? 'Exporting…' : 'Export Excel'}
          </button>
        }
      />

      {/* Summary stats */}
      <div className="grid grid-cols-2 gap-4 md:grid-cols-4">
        <StatMini label="Hot" value={pipeline?.hot_count} color="var(--ft-status-danger)" />
        <StatMini label="Warm" value={pipeline?.warm_count} color="var(--ft-primary)" />
        <StatMini label="Cold" value={pipeline?.cold_count} color="var(--ft-secondary)" />
        <StatMini
          label="Conversion rate"
          value={`${conversionRate}%`}
          color="var(--ft-primary)"
        />
      </div>

      {/* Filters */}
      <Card>
        <div className="flex flex-wrap gap-3">
          <div className="w-44">
            <Select
              value={teamId}
              onChange={(e) => { setTeamId(e.target.value); setEmployeeId(''); }}
              aria-label="Team"
            >
              <option value="">All teams</option>
              {teams.map((t) => (
                <option key={t.id} value={t.id}>{t.name}</option>
              ))}
            </Select>
          </div>
          <div className="w-48">
            <Select
              value={employeeId}
              onChange={(e) => setEmployeeId(e.target.value)}
              aria-label="Employee"
            >
              <option value="">All employees</option>
              {employees.map((e) => (
                <option key={e.id} value={e.id}>{e.name || e.full_name}</option>
              ))}
            </Select>
          </div>
          <div className="w-36">
            <Select
              value={statusFilter}
              onChange={(e) => setStatusFilter(e.target.value)}
              aria-label="Status"
            >
              <option value="">All statuses</option>
              <option value="HOT">Hot</option>
              <option value="WARM">Warm</option>
              <option value="COLD">Cold</option>
            </Select>
          </div>
        </div>
      </Card>

      {/* Table */}
      <Card padded={false}>
        {isLoading ? (
          <Spinner label="Loading leads…" className="py-16" />
        ) : leadList.length === 0 ? (
          <div className="py-16 text-center text-sm text-text-secondary">No leads found.</div>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-left text-sm">
              <thead className="border-b border-border bg-surface/60 text-text-secondary">
                <tr>
                  <th className="px-4 py-3 font-semibold">Farmer</th>
                  <th className="px-4 py-3 font-semibold">Employee</th>
                  <th className="px-4 py-3 font-semibold">Status</th>
                  <th className="px-4 py-3 font-semibold">Last Visit</th>
                  <th className="px-4 py-3 font-semibold">Follow-up</th>
                  <th className="px-4 py-3 font-semibold">Note</th>
                </tr>
              </thead>
              <tbody>
                {leadList.map((lead) => {
                  const overdue = overdueIds.has(lead.id);
                  return (
                    <tr
                      key={lead.id}
                      className={`border-t border-border/60 ${overdue ? 'bg-danger/5' : 'hover:bg-surface/40'}`}
                    >
                      <td className="px-4 py-3 font-medium text-text-primary">
                        <div className="truncate max-w-[160px]">{lead.farmer_name ?? '—'}</div>
                        {overdue && (
                          <div className="text-xs text-danger font-medium mt-0.5">Overdue follow-up</div>
                        )}
                      </td>
                      <td className="px-4 py-3 text-text-secondary">{lead.employee_name ?? '—'}</td>
                      <td className="px-4 py-3">
                        <LeadBadge status={lead.status} />
                      </td>
                      <td className="px-4 py-3 text-text-secondary">
                        {lead.last_visit_date ? dayjs(lead.last_visit_date).format('D MMM') : '—'}
                      </td>
                      <td className="px-4 py-3 text-text-secondary">
                        {lead.follow_up_date
                          ? <span className={overdue ? 'text-danger font-medium' : ''}>{dayjs(lead.follow_up_date).format('D MMM')}</span>
                          : '—'}
                      </td>
                      <td className="px-4 py-3 text-text-secondary">
                        <div className="truncate max-w-[200px]">{lead.reason_note ?? '—'}</div>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
      </Card>
    </div>
  );
}
