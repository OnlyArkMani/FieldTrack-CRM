import { Loader2 } from 'lucide-react';

export default function Spinner({ label, className }) {
  return (
    <div className={`flex items-center justify-center gap-2 text-text-secondary ${className || ''}`}>
      <Loader2 className="h-5 w-5 animate-spin text-primary" />
      {label && <span className="text-sm">{label}</span>}
    </div>
  );
}
