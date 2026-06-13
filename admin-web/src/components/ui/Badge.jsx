import clsx from 'clsx';

// Maps a live/attendance status to a color token + label.
const STATUS = {
  ACTIVE: { color: 'var(--ft-status-active)', label: 'Active' },
  IDLE: { color: 'var(--ft-status-idle)', label: 'Idle' },
  OFFLINE: { color: 'var(--ft-status-offline)', label: 'Offline' },
  PRESENT: { color: 'var(--ft-status-active)', label: 'Present' },
  ABSENT: { color: 'var(--ft-status-danger)', label: 'Absent' },
  HALF_DAY: { color: 'var(--ft-status-battery)', label: 'Half day' },
};

/** Colored pill. Pass `status` for a known status, or `color`+`children`. */
export default function Badge({ status, color, children, dot = true, className }) {
  const preset = status ? STATUS[status] : null;
  const c = color || preset?.color || 'var(--ft-status-offline)';
  const label = children || preset?.label || status || '';
  return (
    <span
      className={clsx(
        'inline-flex items-center gap-1.5 rounded-full px-2.5 py-0.5 text-xs font-medium',
        className,
      )}
      style={{ backgroundColor: `${c}24`, color: c }}
    >
      {dot && (
        <span
          className="h-1.5 w-1.5 rounded-full"
          style={{ backgroundColor: c }}
        />
      )}
      <span className="truncate">{label}</span>
    </span>
  );
}
