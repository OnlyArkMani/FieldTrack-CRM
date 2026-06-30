import { useState } from 'react';
import dayjs from 'dayjs';

import { useFarmers } from '@/hooks/useFarmers';
import { useTeams } from '@/hooks/useTeams';
import { useGlobalSearch } from '@/hooks/useGlobalSearch';

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

  const { data, isLoading } = useFarmers({
    teamId: teamId || undefined,
    leadStatus: leadStatus || undefined,
    search: query || undefined,
  });

  const rows = data?.items || [];

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
      <PageHeader title="Farmers" subtitle={`${data?.total ?? 0} total`} />

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
        empty="No farmers match these filters"
      />

      <FarmerDetailPanel
        farmerId={selectedId}
        open={selectedId != null}
        onClose={() => setSelectedId(null)}
      />
    </div>
  );
}
