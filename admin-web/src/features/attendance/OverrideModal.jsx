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
