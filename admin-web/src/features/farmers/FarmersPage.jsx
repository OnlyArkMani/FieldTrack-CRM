import { useState, useEffect } from 'react';
import { useLocation, useNavigate } from 'react-router-dom';
import dayjs from 'dayjs';
import { Upload, Download, CheckCircle2, AlertTriangle } from 'lucide-react';

import {
  useFarmers,
  useImportCustomers,
  downloadImportTemplate,
} from '@/hooks/useFarmers';
import { useTeams } from '@/hooks/useTeams';
import { useGlobalSearch } from '@/hooks/useGlobalSearch';
import { useAuthStore } from '@/store/authStore';
import { api, apiErrorMessage } from '@/services/api/client';

import PageHeader from '@/components/ui/PageHeader';
import Card from '@/components/ui/Card';
import Table from '@/components/ui/Table';
import Modal from '@/components/ui/Modal';
import Button from '@/components/ui/Button';
import { Select } from '@/components/ui/Input';
import FarmerDetailPanel, { LeadBadge, CustomerTypeBadge } from './FarmerDetailPanel';

// [All] [Farmers] [FPOs] [VLCCs] [Retailers] — value '' means no customer_type filter.
const TYPE_TABS = [
  { value: '', label: 'All' },
  { value: 'FARMER', label: 'Farmers' },
  { value: 'FPO', label: 'FPOs' },
  { value: 'VLCC', label: 'VLCCs' },
  { value: 'RETAILER', label: 'Retailers' },
];

export default function FarmersPage() {
  const { query } = useGlobalSearch();
  const { data: teams = [] } = useTeams();
  const isAdmin = useAuthStore((s) => s.user?.role === 'ADMIN');

  const [customerType, setCustomerType] = useState('');
  const [teamId, setTeamId] = useState('');
  const [leadStatus, setLeadStatus] = useState('');
  const [selectedId, setSelectedId] = useState(null);
  const [exporting, setExporting] = useState(false);
  const [importOpen, setImportOpen] = useState(false);

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
    customerType: customerType || undefined,
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
      key: 'type',
      header: 'Type',
      render: (f) => <CustomerTypeBadge type={f.customer_type} />,
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
      <PageHeader
        title="Customers"
        subtitle={`${data?.total ?? 0} total`}
        actions={
          isAdmin ? (
            <Button icon={Upload} onClick={() => setImportOpen(true)}>
              Import
            </Button>
          ) : null
        }
      />

      {/* Type tabs */}
      <div className="flex flex-wrap gap-2">
        {TYPE_TABS.map((t) => (
          <button
            key={t.value || 'all'}
            onClick={() => {
              setCustomerType(t.value);
              setSelectedId(null);
            }}
            className={`rounded-btn px-3.5 py-1.5 text-sm font-medium transition-colors ${
              customerType === t.value
                ? 'bg-primary text-primary-fg'
                : 'bg-surface text-text-secondary hover:text-text-primary'
            }`}
          >
            {t.label}
          </button>
        ))}
      </div>

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
        empty="No customers match these filters"
      />

      <FarmerDetailPanel
        farmerId={selectedId}
        open={selectedId != null}
        onClose={() => setSelectedId(null)}
      />

      {importOpen && <ImportModal onClose={() => setImportOpen(false)} />}
    </div>
  );
}

// ── Import modal (admin preload) ─────────────────────────────────────────
function ImportModal({ onClose }) {
  const importMut = useImportCustomers();
  const [file, setFile] = useState(null);
  const [preview, setPreview] = useState(null); // dry-run result
  const [committed, setCommitted] = useState(null);
  const [error, setError] = useState('');

  async function run(dryRun) {
    if (!file) return;
    setError('');
    try {
      const res = await importMut.mutateAsync({ file, dryRun });
      if (dryRun) setPreview(res);
      else setCommitted(res);
    } catch (e) {
      setError(apiErrorMessage(e, 'Import failed'));
    }
  }

  const canCommit = preview && preview.created > 0 && !committed;

  return (
    <Modal open title="Import customers" onClose={onClose} size="lg">
      <div className="space-y-4">
        {!committed && (
          <>
            <p className="text-sm text-text-secondary">
              Upload a CSV or Excel file with a <code>customer_type</code> column
              (FARMER / FPO / VLCC). We validate first, then you confirm the insert.
            </p>

            <button
              type="button"
              onClick={() => downloadImportTemplate()}
              className="inline-flex items-center gap-1.5 text-sm font-medium text-primary hover:underline"
            >
              <Download className="h-4 w-4" /> Download template
            </button>

            <div>
              <input
                type="file"
                accept=".csv,.xlsx,.xlsm"
                onChange={(e) => {
                  setFile(e.target.files?.[0] || null);
                  setPreview(null);
                }}
                className="block w-full text-sm text-text-primary file:mr-3 file:rounded-btn file:border-0 file:bg-primary/10 file:px-3 file:py-2 file:text-sm file:font-medium file:text-primary"
              />
            </div>

            {preview && (
              <ResultSummary result={preview} title="Validation preview" />
            )}

            {error && (
              <p className="rounded-btn border border-danger/30 bg-danger/10 p-2 text-sm text-danger">
                {error}
              </p>
            )}
          </>
        )}

        {committed && <ResultSummary result={committed} title="Import complete" done />}
      </div>

      <div className="mt-5 flex justify-end gap-2">
        <Button variant="outline" onClick={onClose}>
          {committed ? 'Done' : 'Cancel'}
        </Button>
        {!committed && (
          <>
            <Button
              variant="secondary"
              icon={CheckCircle2}
              disabled={!file}
              loading={importMut.isPending && !preview}
              onClick={() => run(true)}
            >
              Validate
            </Button>
            <Button
              icon={Upload}
              disabled={!canCommit}
              loading={importMut.isPending && !!preview}
              onClick={() => run(false)}
            >
              Import {preview ? `${preview.created}` : ''}
            </Button>
          </>
        )}
      </div>
    </Modal>
  );
}

function ResultSummary({ result, title, done }) {
  const byType = result.by_type || {};
  return (
    <div className="rounded-card border border-border p-3">
      <div className="mb-2 flex items-center gap-2">
        {done ? (
          <CheckCircle2 className="h-4 w-4 text-status-active" />
        ) : (
          <AlertTriangle className="h-4 w-4 text-primary" />
        )}
        <span className="text-sm font-semibold text-text-primary">{title}</span>
      </div>
      <div className="grid grid-cols-3 gap-2 text-center">
        <Stat label="Rows" value={result.total_rows} />
        <Stat label={done ? 'Created' : 'Will create'} value={result.created || (result.total_rows - result.skipped)} />
        <Stat label="Skipped" value={result.skipped} cls="text-danger" />
      </div>
      {Object.keys(byType).length > 0 && (
        <div className="mt-2 flex flex-wrap gap-2 text-xs text-text-secondary">
          {Object.entries(byType).map(([k, v]) => (
            <span key={k} className="rounded bg-surface px-2 py-0.5">
              {k}: {v}
            </span>
          ))}
        </div>
      )}
      {result.errors?.length > 0 && (
        <div className="mt-3">
          <div className="mb-1 text-xs font-semibold text-danger">
            {result.errors.length} row error{result.errors.length > 1 ? 's' : ''}
          </div>
          <ul className="max-h-40 space-y-1 overflow-y-auto text-xs text-text-secondary">
            {result.errors.slice(0, 50).map((er, i) => (
              <li key={i}>
                Row {er.row}
                {er.field ? ` · ${er.field}` : ''}: {er.message}
              </li>
            ))}
          </ul>
        </div>
      )}
    </div>
  );
}

function Stat({ label, value, cls }) {
  return (
    <div className="rounded-btn bg-surface p-2">
      <div className={`text-lg font-bold ${cls || 'text-text-primary'}`}>{value ?? 0}</div>
      <div className="text-xs text-text-secondary">{label}</div>
    </div>
  );
}
