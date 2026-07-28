import { api } from './client';

/**
 * Helper to fetch tabular preview data for the web admin reports page,
 * using the backend report generation calculation engine (POST /reports/preview).
 */
export async function fetchReportPreviewData({
  type,
  startDate,
  endDate,
  teamId,
  userId,
}) {
  const filters = {};
  if (startDate) filters.start_date = startDate;
  if (endDate) filters.end_date = endDate;
  if (teamId) filters.team_id = Number(teamId);
  if (userId) filters.user_id = Number(userId);

  try {
    const { data } = await api.post('/reports/preview', {
      type,
      filters,
    });

    const primaryTable = data.tables?.[0] || { columns: [], rows: [] };
    const rawColumns = primaryTable.columns || [];
    const rawRows = primaryTable.rows || [];

    const columns = rawColumns.map((colHeader, cIdx) => ({
      key: `col_${cIdx}`,
      header: colHeader,
      render: (row) => row[`col_${cIdx}`],
    }));

    const rows = rawRows.map((rowArray, rIdx) => {
      const rowObj = { id: `r_${rIdx}` };
      (rowArray || []).forEach((val, cIdx) => {
        rowObj[`col_${cIdx}`] = val ?? '—';
      });
      return rowObj;
    });

    return {
      title: `${data.title} Data`,
      subtitle: data.subtitle,
      summary: data.summary,
      columns,
      rows,
    };
  } catch (err) {
    return { title: 'Report Data', columns: [], rows: [], subtitle: '' };
  }
}
