import { useEffect, useMemo, useState } from 'react';
import { Plus, Trash2, Pencil, Users, ShieldCheck } from 'lucide-react';

import {
  useTeams,
  useCreateTeam,
  useUpdateTeam,
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

/** Create when `team` is omitted, edit an existing team otherwise. A manager
 * has no uniqueness constraint on the backend (Team.manager_id has no unique
 * index) — this form lets you pick a manager who already owns other teams,
 * and surfaces that fact so the assignment is a deliberate choice. */
function TeamFormModal({ open, onClose, team, teams }) {
  const isEdit = !!team;
  const create = useCreateTeam();
  const update = useUpdateTeam(team?.id);
  const { data: emps } = useEmployees({});
  const managers = (emps?.items || []).filter(
    (e) => e.role === 'MANAGER' || e.role === 'ADMIN',
  );
  const [name, setName] = useState('');
  const [description, setDescription] = useState('');
  const [managerId, setManagerId] = useState('');
  const [error, setError] = useState(null);

  useEffect(() => {
    if (open) {
      setError(null);
      setName(team?.name || '');
      setDescription(team?.description || '');
      setManagerId(team?.manager_id ? String(team.manager_id) : '');
    }
  }, [open, team]);

  const otherTeamsForManager = managerId
    ? teams.filter((t) => String(t.manager_id) === managerId && t.id !== team?.id)
    : [];

  const submit = async () => {
    setError(null);
    try {
      const payload = {
        name: name.trim(),
        description: description.trim() || null,
        manager_id: managerId === '' ? null : Number(managerId),
      };
      if (isEdit) {
        await update.mutateAsync(payload);
      } else {
        await create.mutateAsync(payload);
      }
      onClose();
    } catch (err) {
      setError(apiErrorMessage(err));
    }
  };

  return (
    <Modal
      open={open}
      onClose={onClose}
      title={isEdit ? `Edit ${team.name}` : 'New team'}
      footer={
        <>
          <Button variant="outline" onClick={onClose}>Cancel</Button>
          <Button onClick={submit} loading={create.isPending || update.isPending} disabled={name.trim().length < 2}>
            {isEdit ? 'Save changes' : 'Create team'}
          </Button>
        </>
      }
    >
      <div className="space-y-4">
        <Input label="Team name" value={name} onChange={(e) => setName(e.target.value)} />
        <Textarea label="Description" value={description} onChange={(e) => setDescription(e.target.value)} placeholder="Optional" />
        <Select label="Manager" value={managerId} onChange={(e) => setManagerId(e.target.value)}>
          <option value="">No manager</option>
          {managers.map((s) => (
            <option key={s.id} value={s.id}>{s.name} ({titleCase(s.role)})</option>
          ))}
        </Select>
        {otherTeamsForManager.length > 0 && (
          <p className="text-xs text-text-secondary">
            Already manages <b className="text-text-primary">{otherTeamsForManager.map((t) => t.name).join(', ')}</b>.
            Assigning them here adds this team alongside it — records the two teams create stay visible only to
            each other's own members and this manager, never to other managers.
          </p>
        )}
        {error && <p className="text-sm text-danger">{error}</p>}
      </div>
    </Modal>
  );
}

export default function TeamsPage() {
  const { data: teams, isLoading } = useTeams();
  const del = useDeleteTeam();
  const [creating, setCreating] = useState(false);
  const [editingTeam, setEditingTeam] = useState(null);
  const [managerFilter, setManagerFilter] = useState('');

  const managerOptions = useMemo(() => {
    const seen = new Map();
    for (const t of teams || []) {
      if (t.manager_id) seen.set(String(t.manager_id), t.manager_name);
    }
    return [...seen.entries()];
  }, [teams]);

  const visibleTeams = useMemo(() => {
    if (!managerFilter) return teams || [];
    return (teams || []).filter((t) => String(t.manager_id) === managerFilter);
  }, [teams, managerFilter]);

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

      {managerOptions.length > 0 && (
        <div className="max-w-xs">
          <Select
            label="Check teams for a manager"
            value={managerFilter}
            onChange={(e) => setManagerFilter(e.target.value)}
          >
            <option value="">All managers</option>
            {managerOptions.map(([id, name]) => (
              <option key={id} value={id}>{name}</option>
            ))}
          </Select>
        </div>
      )}

      {isLoading ? (
        <Spinner label="Loading teams…" className="py-20" />
      ) : visibleTeams.length === 0 ? (
        <Card className="text-center text-text-secondary">
          {managerFilter ? 'This manager owns no teams.' : 'No teams yet.'}
        </Card>
      ) : (
        <div className="grid grid-cols-1 gap-4 md:grid-cols-2 xl:grid-cols-3">
          {visibleTeams.map((t) => (
            <Card key={t.id}>
              <div className="flex items-start justify-between gap-3">
                <div className="min-w-0">
                  <h3 className="truncate text-base font-semibold text-text-primary">{t.name}</h3>
                  {t.manager_name && (
                    <div className="mt-0.5 flex items-center gap-1 text-xs text-text-secondary">
                      <ShieldCheck className="h-3.5 w-3.5" /> {t.manager_name}
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
                <span className="flex items-center gap-1">
                  <Button size="sm" variant="ghost" icon={Pencil} onClick={() => setEditingTeam(t)} title="Edit" />
                  <Button size="sm" variant="ghost" icon={Trash2} onClick={() => remove(t)} title="Delete" />
                </span>
              </div>
            </Card>
          ))}
        </div>
      )}

      <TeamFormModal
        open={creating}
        onClose={() => setCreating(false)}
        team={null}
        teams={teams || []}
      />
      <TeamFormModal
        open={!!editingTeam}
        onClose={() => setEditingTeam(null)}
        team={editingTeam}
        teams={teams || []}
      />
    </div>
  );
}

function titleCase(s = '') {
  return s.charAt(0) + s.slice(1).toLowerCase();
}
