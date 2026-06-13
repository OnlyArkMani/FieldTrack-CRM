import { useState } from 'react';
import dayjs from 'dayjs';
import { Download, FileSpreadsheet } from 'lucide-react';

import { api, apiErrorMessage } from '@/services/api/client';
import PageHeader from '@/components/ui/PageHeader';
import Card, { CardHeader } from '@/components/ui/Card';
import Button from '@/components/ui/Button';
import { Input, Select } from '@/components/ui/Input';
import Table from '@/components/ui/Table';
import Badge from '@/components/ui/Badge';

const MAX_RANGE_DAYS = 31;

function toCsv(rows, columns) {
  const esc = (v) => {
    const s = v == null ? '' : String(v);
    return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
  };
  const header = columns.map((c) => esc(c.header)).join(',');
  const body = rows.map((r) => columns.map((c) => esc(c.value(r))).join(',')).join('\n');
  return `${header}\n${body}`;
}

function download(filename, content, type = 'text/csv;charset=utf-8') {
  const blob = new Blob([content], { type });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  a.click();
  URL.revokeObjectURL(url);
}

const fmtTime = (sessions, type) => {
  const list = (sessions || []).filter((s) => s.type === type);
  if (!list.length) return '';
  const ts = type === 'END' ? list[list.length - 1].timestamp : list[0].timestamp;
  return dayjs(ts).format('HH:mm');
};

export default function ReportsPage() {
  const today = dayjs().format('YYYY-MM-DD');
  const [type, setType] = useState('attendance');
  const [startDate, setStartDate] = useState(today);
  const [endDate, setEndDate] = useState(today);
  const [rows, setRows] = useState([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState(null);

  // Max end date = start + 31 days, but never in the future.
  const capDate = (start) => {
    const plus31 = dayjs(start).add(MAX_RANGE_DAYS, 'day');
    return plus31.isAfter(dayjs(today)) ? dayjs(today) : plus31;
  };
  const maxEnd = capDate(startDate).format('YYYY-MM-DD');

  const onStartChange = (value) => {
    setStartDate(value);
    // Clamp the end date into [start, start+31] (and not in the future).
    const start = dayjs(value);
    const cap = capDate(value);
    if (dayjs(endDate).isAfter(cap) || dayjs(endDate).isBefore(start)) {
      setEndDate(cap.format('YYYY-MM-DD'));
    }
  };

  const rangeTooLong = dayjs(endDate).diff(dayjs(startDate), 'day') > MAX_RANGE_DAYS;

  const ATTENDANCE_COLS = [
    { header: 'Employee', value: (r) => r.employee?.name || r.user_id },
    { header: 'Date', value: (r) => r.date },
    { header: 'Start', value: (r) => fmtTime(r.sessions, 'START') },
    { header: 'End', value: (r) => fmtTime(r.sessions, 'END') },
    { header: 'Duration (min)', value: (r) => r.total_duration_minutes ?? 0 },
    { header: 'Distance (m)', value: (r) => Math.round(r.total_distance_meters ?? 0) },
    { header: 'Status', value: (r) => r.status },
    { header: 'Work summary', value: (r) => r.work_summary || '' },
  ];
  const EMPLOYEE_COLS = [
    { header: 'Name', value: (r) => r.name },
    { header: 'Email', value: (r) => r.email },
    { header: 'Phone', value: (r) => r.phone || '' },
    { header: 'Role', value: (r) => r.role },
    { header: 'Active', value: (r) => (r.is_active ? 'Yes' : 'No') },
  ];
  const cols = type === 'attendance' ? ATTENDANCE_COLS : EMPLOYEE_COLS;

  const generate = async () => {
    if (rangeTooLong) return;
    setLoading(true);
    setError(null);
    try {
      if (type === 'attendance') {
        const days = [];
        let d = dayjs(startDate);
        const end = dayjs(endDate);
        while (!d.isAfter(end) && days.length <= MAX_RANGE_DAYS) {
          days.push(d.format('YYYY-MM-DD'));
          d = d.add(1, 'day');
        }
        const all = [];
        for (const day of days) {
          // eslint-disable-next-line no-await-in-loop
          const { data } = await api.get('/attendance/all', { params: { date: day, limit: 100 } });
          all.push(...(data.items || []));
        }
        setRows(all);
      } else {
        const { data } = await api.get('/employees', { params: { limit: 100 } });
        setRows(data.items || []);
      }
    } catch (err) {
      setError(apiErrorMessage(err));
      setRows([]);
    } finally {
      setLoading(false);
    }
  };

  const exportCsv = () => {
    const name =
      type === 'attendance'
        ? `attendance_${startDate}_to_${endDate}.csv`
        : `employees_${today}.csv`;
    download(name, toCsv(rows, cols));
  };

  const previewColumns = cols.slice(0, 5).map((c, i) => ({
    key: String(i),
    header: c.header,
    render: (r) => (c.header === 'Status' ? <Badge status={c.value(r)} /> : String(c.value(r) ?? '')),
  }));

  return (
    <div className="space-y-6">
      <PageHeader title="Reports" subtitle="Generate and download CSV exports" />

      <Card>
        <CardHeader title="Build a report" />
        <div className="flex flex-wrap items-end gap-3">
          <div className="w-52">
            <Select label="Report type" value={type} onChange={(e) => setType(e.target.value)}>
              <option value="attendance">Attendance</option>
              <option value="employees">Employee roster</option>
            </Select>
          </div>
          {type === 'attendance' && (
            <>
              <div className="w-44">
                <Input
                  label="Start date"
                  type="date"
                  max={today}
                  value={startDate}
                  onChange={(e) => onStartChange(e.target.value)}
                />
              </div>
              <div className="w-44">
                <Input
                  label="End date"
                  type="date"
                  min={startDate}
                  max={maxEnd}
                  value={endDate}
                  onChange={(e) => setEndDate(e.target.value)}
                />
              </div>
            </>
          )}
          <Button icon={FileSpreadsheet} onClick={generate} loading={loading} disabled={rangeTooLong}>
            Generate
          </Button>
          <Button variant="outline" icon={Download} onClick={exportCsv} disabled={!rows.length}>
            Download CSV
          </Button>
        </div>

        {type === 'attendance' && (
          <p className="mt-2 text-xs italic text-text-secondary">Max 31 days per report</p>
        )}
        {rangeTooLong && (
          <p className="mt-2 text-sm text-danger">
            Please select a date range of 31 days or less.
          </p>
        )}
        {error && <p className="mt-3 text-sm text-danger">{error}</p>}
      </Card>

      {rows.length > 0 && (
        <Card padded={false}>
          <div className="p-5 pb-3">
            <CardHeader title={`Preview — ${rows.length} rows`} subtitle="First 5 columns shown" />
          </div>
          <Table columns={previewColumns} rows={rows} rowKey={(r) => r.id ?? `${r.user_id}-${r.email}`} />
        </Card>
      )}
    </div>
  );
}
