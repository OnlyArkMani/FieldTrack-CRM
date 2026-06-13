import clsx from 'clsx';

function initials(name = '') {
  const parts = name.trim().split(/\s+/).filter(Boolean);
  if (!parts.length) return '?';
  return parts.slice(0, 2).map((p) => p[0].toUpperCase()).join('');
}

/** Circular avatar with photo or initials fallback, optional status ring. */
export default function Avatar({ name, src, size = 36, ringColor, className }) {
  return (
    <div
      className={clsx('relative shrink-0 rounded-full', className)}
      style={{
        width: size,
        height: size,
        padding: ringColor ? 2 : 0,
        background: ringColor || 'transparent',
      }}
    >
      <div className="grid h-full w-full place-items-center overflow-hidden rounded-full bg-secondary/20">
        {src ? (
          // eslint-disable-next-line jsx-a11y/img-redundant-alt
          <img src={src} alt={name} className="h-full w-full object-cover" />
        ) : (
          <span
            className="font-semibold text-secondary"
            style={{ fontSize: size * 0.36 }}
          >
            {initials(name)}
          </span>
        )}
      </div>
    </div>
  );
}
