import Card, { CardHeader } from '@/components/ui/Card';
import Table from '@/components/ui/Table';
import Badge from '@/components/ui/Badge';
import Spinner from '@/components/ui/Spinner';

export default function ReportPreviewTable({ data, loading, error, onRetry }) {
  if (loading && !data?.rows?.length) {
    return (
      <Card>
        <div className="flex items-center justify-center py-12 text-text-secondary">
          <Spinner label="Loading preview data..." />
        </div>
      </Card>
    );
  }

  if (error) {
    return (
      <Card>
        <div className="py-8 text-center text-sm text-danger">
          <p className="font-medium">{error}</p>
          {onRetry && (
            <button
              type="button"
              onClick={onRetry}
              className="mt-3 text-xs font-semibold text-primary hover:underline"
            >
              Retry loading preview
            </button>
          )}
        </div>
      </Card>
    );
  }

  const title = data?.title || 'Report Data Preview';
  const subtitle = data?.subtitle || '';
  const rows = data?.rows || [];

  // Enhance columns with badge rendering for status columns if present.
  const columns = (data?.columns || []).map((col) => {
    if (col.key === 'status') {
      return {
        ...col,
        render: (row) => (
          <Badge variant={row.statusVariant || 'neutral'}>
            {row.status}
          </Badge>
        ),
      };
    }
    return col;
  });

  return (
    <Card>
      <CardHeader
        title={
          <div className="flex items-center justify-between gap-3">
            <div>
              <h3 className="text-base font-semibold text-text-primary">{title}</h3>
              {subtitle && (
                <p className="mt-0.5 text-xs text-text-secondary">{subtitle}</p>
              )}
            </div>
            <span className="rounded-full border border-border bg-surface px-2.5 py-0.5 text-xs font-medium text-text-secondary">
              {rows.length} rows
            </span>
          </div>
        }
      />

      <div className="mt-4">
        <Table
          columns={columns}
          rows={rows}
          loading={loading}
          empty="No records found for the selected filter criteria."
        />
      </div>
    </Card>
  );
}
