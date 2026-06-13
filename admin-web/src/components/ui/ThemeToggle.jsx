import { Moon, Sun } from 'lucide-react';
import { useUiStore } from '@/store/uiStore';

export default function ThemeToggle() {
  const theme = useUiStore((s) => s.theme);
  const toggle = useUiStore((s) => s.toggleTheme);
  const isDark = theme === 'dark';
  return (
    <button
      onClick={toggle}
      aria-label="Toggle theme"
      className="grid h-9 w-9 place-items-center rounded-btn text-text-secondary hover:bg-border/50 hover:text-text-primary"
    >
      {isDark ? <Sun className="h-5 w-5" /> : <Moon className="h-5 w-5" />}
    </button>
  );
}
