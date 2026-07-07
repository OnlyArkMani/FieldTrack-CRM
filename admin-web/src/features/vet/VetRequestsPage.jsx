import { useState } from 'react';
import dayjs from 'dayjs';

import { useVetRequests, useUpdateVetStatus } from '@/hooks/useVet';
import { useTeams } from '@/hooks/useTeams';
import { useEmployees } from '@/hooks/useEmployees';
import PageHeader from '@/components/ui/PageHeader';
import Card from '@/components/ui/Card';
import Table from '@/components/ui/Table';
import Badge from '@/components/ui/Badge';
import Button from '@/components/ui/Button';
import { Select } from '@/components/ui/Input';

const STATUS_COLORS = {
  REQUESTED: 'var(--ft-danger)',
  SCHEDULED: 'var(--ft-primary)',
  DONE: 'var(--ft-status-active)',
};

const NEXT = { REQUESTED: 'SCHEDULED', SCHEDULED: 'DONE' };

function pretty(s) {
  if (!s) return '—';
  return s.charAt(0) + s.slice(1).toLowerCase();
}

/** Vet dashboard — customers who requested a veterinary visit in the field. */
export default function VetRequestsPage() {
  const [status, setStatus] = useState('');
  const [teamId, setTeamId] = useState('');
  const [employeeId, setEmployeeId] = useState('');

  const { data: teams = [] } = useTeams();
  const { data: employeesData } = useEmployees({ teamId: teamId || undefined });
  const employees = employeesData?.items || [];
  const { data: rows = [], isLoading } = useVetRequests({ status, teamId, employeeId });
  const update = useUpdateVetStatus();

  const columns = [
    { key: 'customer', header: 'Customer', render: (r) => r.farmer_name },
    {
      key: 'type',
      header: 'Type',
      render: (r) => <Badge color="var(--ft-secondary)">{r.customer_type}</Badge>,
    },
    { key: 'village', header: 'Village', render: (r) => r.village || '—' },
    {
      key: 'employee',
      header: 'Executive',
      render: (r) => r.employee_name ?? '—',
    },
    {
      key: 'date',
      header: 'Requested',
      render: (r) => (r.visit_date ? dayjs(r.visit_date).format('MMM D, YYYY') : '—'),
    },
    { key: 'cattle', header: 'Cattle', render: (r) => r.vet_cattle_count ?? '—' },
    {
      key: 'notes',
      header: 'Notes',
      render: (r) => (
        <span className="block max-w-xs truncate text-text-secondary" title={r.vet_notes || ''}>
          {r.vet_notes || '—'}
        </span>
      ),
    },
    {
      key: 'status',
      header: 'Status',
      render: (r) => (
        <Badge color={STATUS_COLORS[r.vet_status] || 'var(--ft-text-secondary)'}>
          {pretty(r.vet_status)}
        </Badge>
      ),
    },
    {
      key: 'actions',
      header: '',
      align: 'right',
      render: (r) =>
        NEXT[r.vet_status] ? (
          <Button
            size="sm"
            variant="secondary"
            loading={update.isPending}
            onClick={() =>
              update.mutate({ visitId: r.visit_id, vetStatus: NEXT[r.vet_status] })
            }
          >
            Mark {pretty(NEXT[r.vet_status])}
          </Button>
        ) : null,
    },
  ];

  return (
    <div className="space-y-6">
      <PageHeader
        title="Vet Requests"
        subtitle="Customers who asked for a veterinary visit in the field"
      />

      <Card className="flex flex-wrap items-end gap-3">
        <div className="w-48">
          <Select label="Status" value={status} onChange={(e) => setStatus(e.target.value)}>
            <option value="">All</option>
            <option value="REQUESTED">Requested</option>
            <option value="SCHEDULED">Scheduled</option>
            <option value="DONE">Done</option>
          </Select>
        </div>
        <div className="w-56">
          <Select
            label="Team"
            value={teamId}
            onChange={(e) => {
              setTeamId(e.target.value);
              setEmployeeId(''); // narrow the employee list; drop a now-stale pick
            }}
          >
            <option value="">All teams</option>
            {teams.map((t) => (
              <option key={t.id} value={t.id}>
                {t.name}
              </option>
            ))}
          </Select>
        </div>
        <div className="w-56">
          <Select
            label="Employee"
            value={employeeId}
            onChange={(e) => setEmployeeId(e.target.value)}
          >
            <option value="">All employees</option>
            {employees.map((e) => (
              <option key={e.id} value={e.id}>
                {e.name}
              </option>
            ))}
          </Select>
        </div>
        {rows.length > 0 && <Badge color="var(--ft-primary)">{rows.length} total</Badge>}
      </Card>

      <Card padded={false}>
        <Table
          columns={columns}
          rows={rows}
          rowKey={(r) => r.visit_id}
          loading={isLoading}
          empty="No vet requests."
        />
      </Card>
    </div>
  );
}
