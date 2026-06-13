import { createContext, useContext, useMemo, useState } from 'react';

// Debounced global search shared between the topbar and whichever list page is
// open. Pages read `query` and filter; the topbar writes it.
const SearchContext = createContext(null);

export function SearchProvider({ children }) {
  const [query, setQuery] = useState('');
  const value = useMemo(() => ({ query, setQuery }), [query]);
  return <SearchContext.Provider value={value}>{children}</SearchContext.Provider>;
}

export function useGlobalSearch() {
  const ctx = useContext(SearchContext);
  if (!ctx) return { query: '', setQuery: () => {} };
  return ctx;
}
