import { useState } from 'react';
import { Navigate, useNavigate } from 'react-router-dom';
import { LogIn } from 'lucide-react';

import { api, apiErrorMessage } from '@/services/api/client';
import { useAuthStore, selectIsAdmin } from '@/store/authStore';
import Button from '@/components/ui/Button';
import { Input } from '@/components/ui/Input';
import Card from '@/components/ui/Card';

export default function LoginPage() {
  const status = useAuthStore((s) => s.status);
  const isAdmin = useAuthStore(selectIsAdmin);
  const setSession = useAuthStore((s) => s.setSession);
  const navigate = useNavigate();

  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState(null);
  const [loading, setLoading] = useState(false);

  if (status === 'authenticated' && isAdmin) return <Navigate to="/" replace />;

  const submit = async (e) => {
    e.preventDefault();
    setError(null);
    setLoading(true);
    try {
      const { data } = await api.post('/auth/login', {
        email: email.trim().toLowerCase(),
        password,
        client: 'web', // refresh token returned as httpOnly cookie
      });
      if (data.user?.role !== 'ADMIN') {
        setError('This dashboard is for administrators only.');
        setLoading(false);
        return;
      }
      setSession({ accessToken: data.access_token, user: data.user });
      navigate('/', { replace: true });
    } catch (err) {
      setError(apiErrorMessage(err, 'Login failed'));
      setLoading(false);
    }
  };

  return (
    <div className="grid min-h-screen place-items-center bg-bg p-4">
      <div className="w-full max-w-sm">
        <div className="mb-6 flex items-center justify-center gap-2">
          <div className="grid h-11 w-11 place-items-center rounded-card bg-primary text-primary-fg text-xl font-bold">
            F
          </div>
          <span className="text-2xl font-bold text-text-primary">FieldTrack</span>
        </div>
        <Card>
          <h1 className="text-lg font-semibold text-text-primary">Admin sign in</h1>
          <p className="mt-1 text-sm text-text-secondary">
            Manage employees, teams, attendance and live tracking.
          </p>
          <form onSubmit={submit} className="mt-5 space-y-4">
            <Input
              label="Email"
              type="email"
              autoComplete="username"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              required
            />
            <Input
              label="Password"
              type="password"
              autoComplete="current-password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              required
            />
            {error && <p className="text-sm text-danger">{error}</p>}
            <Button type="submit" loading={loading} icon={LogIn} className="w-full">
              Sign in
            </Button>
          </form>
        </Card>
      </div>
    </div>
  );
}
