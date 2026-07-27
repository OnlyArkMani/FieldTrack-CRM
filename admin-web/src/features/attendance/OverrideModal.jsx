import { useEffect, useState } from 'react';
import dayjs from 'dayjs';
import Modal from '@/components/ui/Modal';
import Button from '@/components/ui/Button';
import { Input, Select, Textarea } from '@/components/ui/Input';
import { apiErrorMessage } from '@/services/api/client';
import { useOverrideStatus, useAddManualSession } from '@/hooks/useAttendance';

/** Adjust a day's classification, and/or insert a manual session. */
export default function OverrideModal({ open, onClose, row }) {
  const override = useOverrideStatus();
  const addSession = useAddManualSession();
  const [status, setStatus] = useState('PRESENT');
  const [reason, setReason] = useState('');
  const [error, setError] = useState(null);

  // Manual session sub-form
  const [showManual, setShowManual] = useState(false);
  const [sType, setSType] = useState('END');
  const [sTime, setSTime] = useState('');
  const [sReason, setSReason] = useState('');

  useEffect(() => {
    if (open && row) {
      setStatus(row.status || 'PRESENT');
      setReason('');
      setError(null);
      setShowManual(false);
      setSType('END');
      setSTime(dayjs().format('YYYY-MM-DDTHH:mm'));
      setSReason('');
    }
  }, [open, row]);

  if (!row) return null;

  const saveStatus = async () => {
    setError(null);
    try {
      await override.mutateAsync({ attendanceId: row.id, status, reason: reason || null });
      onClose();
    } catch (err) {
      setError(apiErrorMessage(err));
    }
  };

  const saveSession = async () => {
    setError(null);
    try {
      await addSession.mutateAsync({
        attendanceId: row.id,
        type: sType,
        timestamp: dayjs(sTime).toISOString(),
        reason: sReason,
      });
      onClose();
    } catch (err) {
      setError(apiErrorMessage(err));
    }
  };

  return (
    <Modal
      open={open}
      onClose={onClose}
      title={`Adjust — ${row.employee?.name || 'Employee'}`}
      footer={
        <>
          <Button variant="outline" onClick={onClose}>Close</Button>
          {showManual ? (
            <Button onClick={saveSession} loading={addSession.isPending} disabled={sReason.trim().length < 3}>
              Add session
            </Button>
          ) : (
            <Button onClick={saveStatus} loading={override.isPending}>
              Save status
            </Button>
          )}
        </>
      }
    >
      <div className="space-y-4">
        {row.sessions && row.sessions.length > 0 && (
          <div className="bg-surface/50 border border-white/10 rounded-xl p-3.5 space-y-2.5">
            <div className="text-xs font-semibold text-text-secondary uppercase tracking-wider">
              Daily Session Timeline ({row.sessions.length} checkpoints)
            </div>
            <div className="space-y-2 max-h-48 overflow-y-auto pr-1">
              {row.sessions.map((s, idx) => {
                const isCheckIn = s.type === 'START' || s.type === 'RESUME' || s.type === 'RE_CHECKIN';
                const label = s.type === 'START' ? 'Check-In' : s.type === 'END' ? 'Check-Out' : s.type === 'RE_CHECKIN' ? 'Re-Check In' : s.type;
                const badgeColor = s.type === 'START' ? 'bg-emerald-500/20 text-emerald-400 border-emerald-500/30' : s.type === 'END' ? 'bg-red-500/20 text-red-400 border-red-500/30' : 'bg-purple-500/20 text-purple-400 border-purple-500/30';
                return (
                  <div key={idx} className="flex items-start justify-between text-xs py-1 border-b border-white/5 last:border-0 gap-2">
                    <div className="flex items-center gap-2 min-w-0">
                      <span className={clsx("px-2 py-0.5 rounded text-[11px] font-medium border shrink-0", badgeColor)}>
                        {label}
                      </span>
                      {s.notes && (
                        <span className="text-text-secondary italic truncate">
                          "{s.notes}"
                        </span>
                      )}
                    </div>
                    <span className="font-mono text-text-primary shrink-0">
                      {dayjs(s.timestamp).format('HH:mm')}
                    </span>
                  </div>
                );
              })}
            </div>
          </div>
        )}

        {!showManual ? (
          <>
            <Select label="Day status" value={status} onChange={(e) => setStatus(e.target.value)}>
              <option value="PRESENT">Present</option>
              <option value="HALF_DAY">Half day</option>
              <option value="ABSENT">Absent</option>
            </Select>
            <Textarea
              label="Reason (audit log)"
              value={reason}
              onChange={(e) => setReason(e.target.value)}
              placeholder="Why is this being overridden?"
            />
            <button
              className="text-sm text-secondary hover:underline"
              onClick={() => setShowManual(true)}
            >
              + Add a manual session instead
            </button>
          </>
        ) : (
          <>
            <div className="grid grid-cols-2 gap-4">
              <Select label="Session type" value={sType} onChange={(e) => setSType(e.target.value)}>
                <option value="START">Start</option>
                <option value="BREAK">Break</option>
                <option value="RESUME">Resume</option>
                <option value="END">End</option>
                <option value="RE_CHECKIN">Re-Check In</option>
              </Select>
              <Input
                label="Timestamp"
                type="datetime-local"
                value={sTime}
                onChange={(e) => setSTime(e.target.value)}
              />
            </div>
            <Textarea
              label="Reason (required)"
              value={sReason}
              onChange={(e) => setSReason(e.target.value)}
              placeholder="Min 3 characters"
            />
            <button
              className="text-sm text-secondary hover:underline"
              onClick={() => setShowManual(false)}
            >
              ← Back to status override
            </button>
          </>
        )}
        {error && <p className="text-sm text-danger">{error}</p>}
      </div>
    </Modal>
  );
}
