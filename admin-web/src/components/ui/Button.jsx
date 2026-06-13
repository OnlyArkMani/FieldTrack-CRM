import clsx from 'clsx';
import { Loader2 } from 'lucide-react';

const VARIANTS = {
  primary: 'bg-primary text-primary-fg hover:brightness-95',
  secondary: 'bg-secondary text-white hover:brightness-95',
  danger: 'bg-danger text-white hover:brightness-95',
  ghost:
    'bg-transparent text-text-secondary hover:bg-border/50 hover:text-text-primary',
  outline:
    'bg-transparent border border-border text-text-primary hover:bg-border/40',
};

const SIZES = {
  sm: 'h-8 px-3 text-sm',
  md: 'h-10 px-4 text-sm',
  lg: 'h-11 px-5 text-base',
};

/** The only button. Loading + disabled handled by construction. */
export default function Button({
  children,
  variant = 'primary',
  size = 'md',
  loading = false,
  icon: Icon,
  className,
  disabled,
  type = 'button',
  ...props
}) {
  const isDisabled = disabled || loading;
  return (
    <button
      type={type}
      disabled={isDisabled}
      className={clsx(
        'inline-flex items-center justify-center gap-2 rounded-btn font-semibold',
        'transition-all duration-150 active:scale-[0.98] focus:outline-none',
        'focus-visible:ring-2 focus-visible:ring-primary/60',
        VARIANTS[variant],
        SIZES[size],
        isDisabled && 'opacity-50 cursor-not-allowed active:scale-100',
        className,
      )}
      {...props}
    >
      {loading ? (
        <Loader2 className="h-4 w-4 animate-spin" />
      ) : (
        Icon && <Icon className="h-4 w-4" />
      )}
      {children && <span className="truncate">{children}</span>}
    </button>
  );
}
