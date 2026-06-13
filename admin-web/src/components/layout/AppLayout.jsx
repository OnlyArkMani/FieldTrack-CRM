import { Outlet } from 'react-router-dom';
import Sidebar from '@/components/ui/Sidebar';
import Topbar from './Topbar';
import { SearchProvider, useGlobalSearch } from '@/hooks/useGlobalSearch';

function SearchTopbar() {
  const { setQuery } = useGlobalSearch();
  return <Topbar onSearch={setQuery} />;
}

export default function AppLayout() {
  return (
    <SearchProvider>
      <div className="flex h-screen overflow-hidden bg-bg">
        <Sidebar />
        <div className="flex min-w-0 flex-1 flex-col">
          <SearchTopbar />
          <main className="flex-1 overflow-y-auto p-4 md:p-6">
            <div className="mx-auto max-w-7xl">
              <Outlet />
            </div>
          </main>
        </div>
      </div>
    </SearchProvider>
  );
}
