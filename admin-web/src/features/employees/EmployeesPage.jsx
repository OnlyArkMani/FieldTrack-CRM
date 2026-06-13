import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { Plus, Power, Pencil, ShieldAlert } from 'lucide-react';

import { useEmployees, useSetEmployeeStatus } from '@/hooks/useEmployees';
import { useTeams } from '@/hooks/useTeams';
import { useGlobalSearch } from '@/hooks/useGlobalSearch';
import { apiErrorMessage } from '@/services/api/client';

import PageHeader from '@/components/ui/PageHeader';
import Card from '@/components/ui/Card';
import Table from '@/components/ui/Table';
import Badge from '@/components/ui/Badge';
import Button from '@/components/ui/Button';
import Avatar from '@/components/ui/Avatar';
import { Select } from '@/components/ui/Input';
import EmployeeFormModal from './EmployeeFormModal';

export default function EmployeesPage() {
  const navigate = useNavigate();
  const { query } = useGlobalSearch();
  const { data: teams = [] } = useTeams();
  const [teamId, setTeamId] = useState('');
  const [status, setStatus] = useState('');
  const [modal, setModal] = useState({ open: false, employee: null });

  const { data, isLoading } = useEmployees({
    teamId: teamId || undefined,
    status: status || undefined,
    search: query || undefined,
  });
  const setActive = useSetEmployeeStatus();

  const rows = data?.items || [];

  const toggleActive = async (e, ev) => {
    ev.stopPropagation();
    try {
      await setActive.mutateAsync({ id: e.id, isActive: !e.is_active });
    } catch (err) {
      alert(apiErrorMessage(err));
    }
  };

  const columns = [
    {
      key: 'name',
      header: 'Employee',
      render: (e) => (
        <div className="flex items-center gap-2">
          <Avatar name={e.name} src={e.profile_photo_url} size={32} />
          <div className="min-w-0">
            <div className="flex items-center gap-1.5">
              <span className="truncate font-medium text-text-primary">{e.name}</span>
              {e.mock_gps_today && (
                <ShieldAlert
                  className="h-4 w-4 shrink-0"
                  style={{ color: 'var(--ft-status-danger)' }}
                  aria-label="Mock GPS detected today"
                />
              )}
            </div>
            <div className="truncate text-xs text-text-secondary">{e.email}</div>
          </div>
        </div>
      ),
    },
    { key: 'role', header: 'Role', render: (e) => <span className="text-text-primary">{titleCase(e.role)}</span> },
    {
      key: 'team',
      header: 'Team',
      render: (e) => (
        <span className="text-text-secondary">
          {teams.find((t) => t.id === e.team_id)?.name || '—'}
        </span>
      ),
    },
    {
      key: 'live',
      header: 'Live',
      render: (e) => <Badge status={e.live?.live_status || 'OFFLINE'} />,
    },
    {
      key: 'active',
      header: 'Account',
      render: (e) =>
        e.is_active ? (
          <Badge color="var(--ft-status-active)">Active</Badge>
        ) : (
          <Badge color="var(--ft-status-offline)">Inactive</Badge>
        ),
    },
    {
      key: 'actions',
      header: '',
      align: 'right',
      render: (e) => (
        <div className="flex items-center justify-end gap-1">
          <Button
            size="sm"
            variant="ghost"
            icon={Power}
            onClick={(ev) => toggleActive(e, ev)}
            title={e.is_active ? 'Deactivate' : 'Activate'}
          />
          <Button
            size="sm"
            variant="ghost"
            icon={Pencil}
            onClick={(ev) => {
              ev.stopPropagation();
              setModal({ open: true, employee: e });
            }}
            title="Edit"
          />
        </div>
      ),
    },
  ];

  return (
    <div className="space-y-6">
      <PageHeader
        title="Employees"
        subtitle={`${data?.total ?? 0} total`}
        actions={
          <Button icon={Plus} onClick={() => setModal({ open: true, employee: null })}>
            New employee
          </Button>
        }
      />

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
          <Select label="Status" value={status} onChange={(e) => setStatus(e.target.value)}>
            <option value="">All</option>
            <option value="active">Active</option>
            <option value="inactive">Inactive</option>
          </Select>
        </div>
        <p className="ml-auto self-center text-sm text-text-secondary">
          Use the top search to filter by name or email.
        </p>
      </Card>

      <Table
        columns={columns}
        rows={rows}
        loading={isLoading}
        onRowClick={(e) => navigate(`/employees/${e.id}`)}
        empty="No employees match these filters"
      />

      <EmployeeFormModal
        open={modal.open}
        employee={modal.employee}
        onClose={() => setModal({ open: false, employee: null })}
      />
    </div>
  );
}

function titleCase(s = '') {
  return s.charAt(0) + s.slice(1).toLowerCase();
}
