import { useState, useEffect } from 'react';
import { useLocation, useNavigate } from 'react-router-dom';
import dayjs from 'dayjs';
import { Download } from 'lucide-react';

import { useFarmers } from '@/hooks/useFarmers';
import { useTeams } from '@/hooks/useTeams';
import { useGlobalSearch } from '@/hooks/useGlobalSearch';
import { api } from '@/services/api/client';

import PageHeader from '@/components/ui/PageHeader';
import Card from '@/components/ui/Card';
import Table from '@/components/ui/Table';
import { Select } from '@/components/ui/Input';
import FarmerDetailPanel, { LeadBadge } from './FarmerDetailPanel';

export default function FarmersPage() {
  const { query } = useGlobalSearch();
  const { data: teams = [] } = useTeams();
  const [teamId, setTeamId] = useState('');
  const [leadStatus, setLeadStatus] = useState('');
  const [selectedId, setSelectedId] = useState(null);
  const [exporting, setExporting] = useState(false);

  // Cross-page click-through (e.g. from the Follow-up Calendar) — open a
  // specific farmer's detail panel on arrival, then clear the nav state so
  // a later in-page navigation doesn't keep reopening it.
  const location = useLocation();
  const navigate = useNavigate();
  useEffect(() => {
    const openFarmerId = location.state?.openFarmerId;
    if (openFarmerId != null) {
      setSelectedId(openFarmerId);
      navigate(location.pathname, { replace: true, state: null });
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [location.state]);

  const { data, isLoading } = useFarmers({
    teamId: teamId || undefined,
    leadStatus: leadStatus || undefined,
    search: query || undefined,
  });

  const rows = data?.items || [];

  async function handleExport() {
    setExporting(true);
    try {
      const filters = {};
      if (teamId) filters.team_id = Number(teamId);
      const { data: job } = await api.post('/reports/generate', {
        type: 'FARMER_EXPORT',
        format: 'EXCEL',
        filters,
      });

      const reportId = job.report_id;
      let ready = false;
      for (let tick = 0; tick < 20 && !ready; tick += 1) {
        await new Promise((resolve) => setTimeout(resolve, 1500));
        const { data: status } = await api.get(`/reports/${reportId}/status`);
        if (status.status === 'READY') {
          ready = true;
        } else if (status.status === 'FAILED' || status.status === 'EXPIRED') {
          throw new Error(status.error || 'Report generation failed');
        }
      }
      if (!ready) throw new Error('Report is taking too long — please retry.');

      const res = await api.get(`/reports/${reportId}/download`, { responseType: 'blob' });
      const url = URL.createObjectURL(res.data);
      const a = document.createElement('a');
      a.href = url;
      a.download = `farmer_export_${dayjs().format('YYYY-MM-DD')}.xlsx`;
      a.click();
      URL.revokeObjectURL(url);
    } catch {
      // ignore — user sees no download
    } finally {
      setExporting(false);
    }
  }

  const columns = [
    {
      key: 'name',
      header: 'Name',
      render: (f) => (
        <div className="min-w-0">
          <div className="truncate font-medium text-text-primary">{f.name}</div>
          {f.phone && (
            <div className="truncate text-xs text-text-secondary">{f.phone}</div>
          )}
        </div>
      ),
    },
    {
      key: 'village',
      header: 'Village',
      render: (f) => (
        <span className="text-text-secondary">{f.village || '—'}</span>
      ),
    },
    {
      key: 'team',
      header: 'Team',
      render: (f) => (
        <span className="text-text-secondary">
          {f.team_name || teams.find((t) => t.id === f.team_id)?.name || '—'}
        </span>
      ),
    },
    {
      key: 'lead',
      header: 'Lead',
      render: (f) => <LeadBadge status={f.lead_status} />,
    },
    {
      key: 'last_visit',
      header: 'Last visit',
      render: (f) => (
        <span className="text-text-secondary">
          {f.last_visit_at ? dayjs(f.last_visit_at).format('MMM D, YYYY') : 'Never'}
        </span>
      ),
    },
    {
      key: 'cattle',
      header: 'Cattle',
      align: 'right',
      render: (f) => <span className="text-text-primary">{f.total_cattle ?? 0}</span>,
    },
  ];

  return (
    <div className="space-y-6">
      <PageHeader title="FPO" subtitle={`${data?.total ?? 0} total`} />

      <Card className="flex flex-wrap items-end gap-3">
        <div className="w-48">
          <Select label="Team" value={teamId} onChange={(e) => setTeamId(e.target.value)}>
            <option value="">All teams</option>
            {teams.map((t) => (
              <option key={t.id} value={t.id}>
                {t.name}
              </option>
            ))}
          </Select>
        </div>
        <div className="w-48">
          <Select
            label="Lead status"
            value={leadStatus}
            onChange={(e) => setLeadStatus(e.target.value)}
          >
            <option value="">All leads</option>
            <option value="HOT">Hot</option>
            <option value="WARM">Warm</option>
            <option value="COLD">Cold</option>
          </Select>
        </div>
        <p className="ml-auto self-center text-sm text-text-secondary">
          Use the top search to filter by name or village.
        </p>
      </Card>

      <Table
        columns={columns}
        rows={rows}
        loading={isLoading}
        onRowClick={(f) => setSelectedId(f.id)}
        empty="No FPOs match these filters"
      />

      <FarmerDetailPanel
        farmerId={selectedId}
        open={selectedId != null}
        onClose={() => setSelectedId(null)}
      />
    </div>
  );
}
