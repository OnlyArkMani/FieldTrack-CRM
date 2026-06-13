import { Moon, Sun, User, ShieldCheck } from 'lucide-react';

import { useUiStore } from '@/store/uiStore';
import { useAuthStore } from '@/store/authStore';
import PageHeader from '@/components/ui/PageHeader';
import Card, { CardHeader } from '@/components/ui/Card';
import Avatar from '@/components/ui/Avatar';
import Button from '@/components/ui/Button';

export default function SettingsPage() {
  const theme = useUiStore((s) => s.theme);
  const toggleTheme = useUiStore((s) => s.toggleTheme);
  const user = useAuthStore((s) => s.user);
  const isDark = theme === 'dark';

  return (
    <div className="space-y-6">
      <PageHeader title="Settings" subtitle="Preferences and account" />

      <div className="grid grid-cols-1 gap-6 lg:grid-cols-2">
        <Card>
          <CardHeader title="Appearance" subtitle="Match your environment" />
          <div className="flex items-center justify-between rounded-btn border border-border p-4">
            <div className="flex items-center gap-3">
              {isDark ? (
                <Moon className="h-5 w-5 text-secondary" />
              ) : (
                <Sun className="h-5 w-5 text-primary" />
              )}
              <div>
                <div className="font-medium text-text-primary">
                  {isDark ? 'Dark' : 'Light'} theme
                </div>
                <div className="text-xs text-text-secondary">
                  Toggle between the cream and midnight palettes.
                </div>
              </div>
            </div>
            <Button variant="outline" onClick={toggleTheme}>
              Switch to {isDark ? 'light' : 'dark'}
            </Button>
          </div>
        </Card>

        <Card>
          <CardHeader title="Account" />
          <div className="flex items-center gap-3">
            <Avatar name={user?.name} src={user?.profile_photo_url} size={52} />
            <div className="min-w-0">
              <div className="truncate text-base font-semibold text-text-primary">
                {user?.name}
              </div>
              <div className="truncate text-sm text-text-secondary">{user?.email}</div>
            </div>
          </div>
          <dl className="mt-4 space-y-2 text-sm">
            <div className="flex items-center justify-between">
              <dt className="flex items-center gap-2 text-text-secondary">
                <ShieldCheck className="h-4 w-4" /> Role
              </dt>
              <dd className="font-medium text-text-primary">{user?.role}</dd>
            </div>
            <div className="flex items-center justify-between">
              <dt className="flex items-center gap-2 text-text-secondary">
                <User className="h-4 w-4" /> User ID
              </dt>
              <dd className="font-medium text-text-primary">{user?.id}</dd>
            </div>
          </dl>
        </Card>
      </div>

      <Card className="text-sm text-text-secondary">
        FieldTrack Admin · web dashboard · v0.1.0
      </Card>
    </div>
  );
}
