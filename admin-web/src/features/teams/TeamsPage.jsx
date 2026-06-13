import { useState } from 'react';
import { Plus, Trash2, Users, ShieldCheck } from 'lucide-react';

import {
  useTeams,
  useCreateTeam,
  useDeleteTeam,
} from '@/hooks/useTeams';
import { useEmployees } from '@/hooks/useEmployees';
import { apiErrorMessage } from '@/services/api/client';

import PageHeader from '@/components/ui/PageHeader';
import Card from '@/components/ui/Card';
import Button from '@/components/ui/Button';
import Spinner from '@/components/ui/Spinner';
import Modal from '@/components/ui/Modal';
import { Input, Select, Textarea } from '@/components/ui/Input';

function PerformanceRing({ pct }) {
  const color =
    pct >= 75 ? 'var(--ft-status-active)' : pct >= 40 ? 'var(--ft-status-idle)' : 'var(--ft-status-danger)';
  const deg = Math.min(100, Math.max(0, pct)) * 3.6;
  return (
    <div
      className="grid h-14 w-14 place-items-center rounded-full"
      style={{ background: `conic-gradient(${color} ${deg}deg, var(--ft-border) 0deg)` }}
    >
      <div className="grid h-11 w-11 place-items-center rounded-full bg-card text-xs font-semibold" style={{ color }}>
        {Math.round(pct)}%
      </div>
    </div>
  );
}

function CreateTeamModal({ open, onClose }) {
  const create = useCreateTeam();
  const { data: emps } = useEmployees({});
  const supervisors = (emps?.items || []).filter(
    (e) => e.role === 'SUPERVISOR' || e.role === 'ADMIN',
  );
  const [name, setName] = useState('');
  const [description, setDescription] = useState('');
  const [supervisorId, setSupervisorId] = useState('');
  const [error, setError] = useState(null);

  const submit = async () => {
    setError(null);
    try {
      await create.mutateAsync({
        name: name.trim(),
        description: description.trim() || null,
        supervisor_id: supervisorId === '' ? null : Number(supervisorId),
      });
      setName('');
      setDescription('');
      setSupervisorId('');
      onClose();
    } catch (err) {
      setError(apiErrorMessage(err));
    }
  };

  return (
    <Modal
      open={open}
      onClose={onClose}
      title="New team"
      footer={
        <>
          <Button variant="outline" onClick={onClose}>Cancel</Button>
          <Button onClick={submit} loading={create.isPending} disabled={name.trim().length < 2}>
            Create team
          </Button>
        </>
      }
    >
      <div className="space-y-4">
        <Input label="Team name" value={name} onChange={(e) => setName(e.target.value)} />
        <Textarea label="Description" value={description} onChange={(e) => setDescription(e.target.value)} placeholder="Optional" />
        <Select label="Supervisor" value={supervisorId} onChange={(e) => setSupervisorId(e.target.value)}>
          <option value="">No supervisor</option>
          {supervisors.map((s) => (
            <option key={s.id} value={s.id}>{s.name} ({titleCase(s.role)})</option>
          ))}
        </Select>
        {error && <p className="text-sm text-danger">{error}</p>}
      </div>
    </Modal>
  );
}

export default function TeamsPage() {
  const { data: teams, isLoading } = useTeams();
  const del = useDeleteTeam();
  const [creating, setCreating] = useState(false);

  const remove = async (team) => {
    if (!window.confirm(`Delete "${team.name}"? Members will be unassigned.`)) return;
    try {
      await del.mutateAsync(team.id);
    } catch (err) {
      alert(apiErrorMessage(err));
    }
  };

  return (
    <div className="space-y-6">
      <PageHeader
        title="Teams"
        subtitle={`${teams?.length ?? 0} active`}
        actions={<Button icon={Plus} onClick={() => setCreating(true)}>New team</Button>}
      />

      {isLoading ? (
        <Spinner label="Loading teams…" className="py-20" />
      ) : (teams || []).length === 0 ? (
        <Card className="text-center text-text-secondary">No teams yet.</Card>
      ) : (
        <div className="grid grid-cols-1 gap-4 md:grid-cols-2 xl:grid-cols-3">
          {teams.map((t) => (
            <Card key={t.id}>
              <div className="flex items-start justify-between gap-3">
                <div className="min-w-0">
                  <h3 className="truncate text-base font-semibold text-text-primary">{t.name}</h3>
                  {t.supervisor_name && (
                    <div className="mt-0.5 flex items-center gap-1 text-xs text-text-secondary">
                      <ShieldCheck className="h-3.5 w-3.5" /> {t.supervisor_name}
                    </div>
                  )}
                </div>
                <PerformanceRing pct={t.performance_pct ?? 0} />
              </div>
              {t.description && (
                <p className="mt-2 line-clamp-2 text-sm text-text-secondary">{t.description}</p>
              )}
              <div className="mt-4 flex items-center justify-between border-t border-border pt-3 text-sm">
                <span className="flex items-center gap-1.5 text-text-secondary">
                  <Users className="h-4 w-4" /> {t.member_count} member{t.member_count === 1 ? '' : 's'}
                </span>
                <span className="text-text-secondary">{t.present_today} present today</span>
                <Button size="sm" variant="ghost" icon={Trash2} onClick={() => remove(t)} title="Delete" />
              </div>
            </Card>
          ))}
        </div>
      )}

      <CreateTeamModal open={creating} onClose={() => setCreating(false)} />
    </div>
  );
}

function titleCase(s = '') {
  return s.charAt(0) + s.slice(1).toLowerCase();
}
