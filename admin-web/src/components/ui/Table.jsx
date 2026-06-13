import clsx from 'clsx';
import Spinner from './Spinner';

/**
 * Lightweight data table.
 * columns: [{ key, header, render?(row), className?, align? }]
 */
export default function Table({
  columns,
  rows,
  rowKey = (r) => r.id,
  onRowClick,
  loading = false,
  empty = 'Nothing to show',
}) {
  return (
    <div className="overflow-x-auto rounded-card border border-border/60">
      <table className="w-full border-collapse text-sm">
        <thead>
          <tr className="bg-surface/60">
            {columns.map((col) => (
              <th
                key={col.key}
                className={clsx(
                  'whitespace-nowrap px-4 py-3 text-left font-semibold text-text-secondary',
                  col.align === 'right' && 'text-right',
                  col.align === 'center' && 'text-center',
                  col.className,
                )}
              >
                {col.header}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {loading ? (
            <tr>
              <td colSpan={columns.length} className="px-4 py-10">
                <Spinner label="Loading…" />
              </td>
            </tr>
          ) : rows.length === 0 ? (
            <tr>
              <td
                colSpan={columns.length}
                className="px-4 py-10 text-center text-text-secondary"
              >
                {empty}
              </td>
            </tr>
          ) : (
            rows.map((row) => (
              <tr
                key={rowKey(row)}
                onClick={onRowClick ? () => onRowClick(row) : undefined}
                className={clsx(
                  'border-t border-border/60 transition-colors',
                  onRowClick && 'cursor-pointer hover:bg-surface/60',
                )}
              >
                {columns.map((col) => (
                  <td
                    key={col.key}
                    className={clsx(
                      'px-4 py-3 text-text-primary',
                      col.align === 'right' && 'text-right',
                      col.align === 'center' && 'text-center',
                      col.cellClassName,
                    )}
                  >
                    {col.render ? col.render(row) : row[col.key]}
                  </td>
                ))}
              </tr>
            ))
          )}
        </tbody>
      </table>
    </div>
  );
}
