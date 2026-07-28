import { useState } from 'react';
import Card, { CardHeader } from '@/components/ui/Card';
import Table from '@/components/ui/Table';
import Badge from '@/components/ui/Badge';
import Spinner from '@/components/ui/Spinner';

// ── Session Chip ─────────────────────────────────────────────────────────────
// Maps each session event type to a color/icon combo.
const SESSION_STYLES = {
  'Check-In':     { bg: '#dcfce7', color: '#166534', dot: '#16a34a', icon: '↗' },
  'Check-Out':    { bg: '#fee2e2', color: '#991b1b', dot: '#dc2626', icon: '↙' },
  'Re-Check In':  { bg: '#ede9fe', color: '#5b21b6', dot: '#7c3aed', icon: '↺' },
  'Break':        { bg: '#fef9c3', color: '#854d0e', dot: '#ca8a04', icon: '⏸' },
  'Resume':       { bg: '#dbeafe', color: '#1e40af', dot: '#2563eb', icon: '▶' },
};

function getSessionStyle(label) {
  // Normalise: remove trailing note like "Re-Check In 10:00 (bye mistake)"
  const key = Object.keys(SESSION_STYLES).find((k) => label.startsWith(k));
  return SESSION_STYLES[key] || { bg: '#f1f5f9', color: '#475569', dot: '#94a3b8', icon: '●' };
}

// Parses "Check-In 09:56 | Check-Out 09:56 | Re-Check In 10:00 (bye mistake) | Check-Out 10:01"
function parseSessionHistory(text) {
  if (!text || text === '—') return [];
  return text
    .split('|')
    .map((part) => part.trim())
    .filter(Boolean)
    .map((part) => {
      // Extract optional note in parentheses
      const noteMatch = part.match(/\(([^)]+)\)$/);
      const note = noteMatch ? noteMatch[1] : null;
      const withoutNote = noteMatch ? part.slice(0, noteMatch.index).trim() : part;
      // Extract time (last token that looks like HH:MM)
      const timeMatch = withoutNote.match(/\b(\d{1,2}:\d{2})\s*$/);
      const time = timeMatch ? timeMatch[1] : null;
      const label = timeMatch
        ? withoutNote.slice(0, timeMatch.index).trim()
        : withoutNote;
      return { label, time, note };
    });
}

const VISIBLE_LIMIT = 3;

function SessionHistoryCell({ value }) {
  const [expanded, setExpanded] = useState(false);
  const items = parseSessionHistory(value);
  if (!items.length) return <span className="text-text-secondary">—</span>;

  const hasMore = items.length > VISIBLE_LIMIT;
  const visible = expanded ? items : items.slice(0, VISIBLE_LIMIT);

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: '4px', minWidth: 220 }}>
      {visible.map((item, idx) => {
        const style = getSessionStyle(item.label);
        return (
          <div
            key={idx}
            style={{
              display: 'inline-flex',
              alignItems: 'center',
              gap: '5px',
              backgroundColor: style.bg,
              borderRadius: '999px',
              padding: '2px 9px 2px 6px',
              width: 'fit-content',
            }}
          >
            {/* Coloured dot */}
            <span
              style={{
                width: 7,
                height: 7,
                borderRadius: '50%',
                backgroundColor: style.dot,
                flexShrink: 0,
              }}
            />
            {/* Label */}
            <span
              style={{
                fontSize: '11px',
                fontWeight: 600,
                color: style.color,
                whiteSpace: 'nowrap',
              }}
            >
              {item.label}
            </span>
            {/* Time */}
            {item.time && (
              <span
                style={{
                  fontSize: '11px',
                  fontWeight: 700,
                  color: style.color,
                  opacity: 0.8,
                  whiteSpace: 'nowrap',
                }}
              >
                {item.time}
              </span>
            )}
            {/* Note */}
            {item.note && (
              <span
                style={{
                  fontSize: '10px',
                  fontStyle: 'italic',
                  color: style.color,
                  opacity: 0.7,
                  maxWidth: 130,
                  overflow: 'hidden',
                  textOverflow: 'ellipsis',
                  whiteSpace: 'nowrap',
                }}
                title={item.note}
              >
                {item.note}
              </span>
            )}
          </div>
        );
      })}

      {/* Show more / less toggle */}
      {hasMore && (
        <button
          type="button"
          onClick={() => setExpanded((e) => !e)}
          style={{
            display: 'inline-flex',
            alignItems: 'center',
            gap: '4px',
            marginTop: '2px',
            padding: '2px 8px',
            width: 'fit-content',
            border: '1px dashed #94a3b8',
            borderRadius: '999px',
            background: 'transparent',
            cursor: 'pointer',
            fontSize: '11px',
            fontWeight: 600,
            color: '#64748b',
            transition: 'all 0.15s ease',
          }}
          onMouseEnter={(e) => {
            e.currentTarget.style.background = '#f1f5f9';
            e.currentTarget.style.borderColor = '#64748b';
            e.currentTarget.style.color = '#334155';
          }}
          onMouseLeave={(e) => {
            e.currentTarget.style.background = 'transparent';
            e.currentTarget.style.borderColor = '#94a3b8';
            e.currentTarget.style.color = '#64748b';
          }}
        >
          {expanded ? (
            <><span>▲</span> Show less</>
          ) : (
            <><span>▼</span> +{items.length - VISIBLE_LIMIT} more</>
          )}
        </button>
      )}
    </div>
  );
}

// ── Main Component ────────────────────────────────────────────────────────────
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
    // Detect Session History column by header (case-insensitive)
    if (col.header?.toLowerCase().includes('session history')) {
      return {
        ...col,
        render: (row) => <SessionHistoryCell value={row[col.key]} />,
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
