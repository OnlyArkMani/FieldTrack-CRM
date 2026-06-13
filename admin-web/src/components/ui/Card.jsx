import clsx from 'clsx';

/** Standard card: 12px radius, soft shadow, theme card background. */
export default function Card({ children, className, padded = true, ...props }) {
  return (
    <div
      className={clsx(
        'rounded-card bg-card shadow-soft border border-border/60',
        padded && 'p-5',
        className,
      )}
      {...props}
    >
      {children}
    </div>
  );
}

export function CardHeader({ title, subtitle, action }) {
  return (
    <div className="mb-4 flex items-start justify-between gap-3">
      <div className="min-w-0">
        <h3 className="truncate text-base font-semibold text-text-primary">
          {title}
        </h3>
        {subtitle && (
          <p className="truncate text-sm text-text-secondary">{subtitle}</p>
        )}
      </div>
      {action}
    </div>
  );
}
