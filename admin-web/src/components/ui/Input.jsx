import clsx from 'clsx';
import { forwardRef } from 'react';

const base =
  'w-full rounded-btn border border-border bg-surface px-3 py-2 text-sm text-text-primary ' +
  'placeholder:text-text-secondary focus:border-primary focus:outline-none ' +
  'focus:ring-2 focus:ring-primary/30 transition';

export const Input = forwardRef(function Input(
  { label, error, className, ...props },
  ref,
) {
  return (
    <label className="block">
      {label && (
        <span className="mb-1 block text-sm font-medium text-text-primary">
          {label}
        </span>
      )}
      <input ref={ref} className={clsx(base, error && 'border-danger', className)} {...props} />
      {error && <span className="mt-1 block text-xs text-danger">{error}</span>}
    </label>
  );
});

export function Select({ label, error, children, className, ...props }) {
  return (
    <label className="block">
      {label && (
        <span className="mb-1 block text-sm font-medium text-text-primary">
          {label}
        </span>
      )}
      <select className={clsx(base, 'pr-8', error && 'border-danger', className)} {...props}>
        {children}
      </select>
      {error && <span className="mt-1 block text-xs text-danger">{error}</span>}
    </label>
  );
}

export function Textarea({ label, error, className, ...props }) {
  return (
    <label className="block">
      {label && (
        <span className="mb-1 block text-sm font-medium text-text-primary">
          {label}
        </span>
      )}
      <textarea
        className={clsx(base, 'min-h-[90px] resize-y', error && 'border-danger', className)}
        {...props}
      />
      {error && <span className="mt-1 block text-xs text-danger">{error}</span>}
    </label>
  );
}
