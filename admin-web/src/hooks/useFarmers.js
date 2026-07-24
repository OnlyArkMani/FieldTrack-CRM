import {
  useMutation,
  useQuery,
  useInfiniteQuery,
  useQueryClient,
  keepPreviousData,
} from '@tanstack/react-query';
import { api } from '@/services/api/client';

const KEY = 'farmers';

/** Paginated farmer list (admin view). Each row carries the CURRENT lead
 *  status + last-visit timestamp joined by the backend. */
export function useFarmers({ teamId, leadStatus, search, customerType } = {}) {
  return useQuery({
    queryKey: [KEY, { teamId, leadStatus, search, customerType }],
    queryFn: async () => {
      const params = { limit: 100 };
      if (teamId) params.team_id = teamId;
      if (leadStatus) params.lead_status = leadStatus;
      if (customerType) params.customer_type = customerType;
      if (search?.trim()) params.search = search.trim();
      const { data } = await api.get('/farmers', { params });
      return data; // { items, total, has_more, next_cursor }
    },
    placeholderData: keepPreviousData,
  });
}

/** Bulk import customers (admin). Sends a CSV/XLSX file; dry_run=true previews.
 *  Resolves to CustomerImportResult { total_rows, created, skipped, by_type,
 *  errors, dry_run }. */
export function useImportCustomers() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async ({ file, dryRun = true }) => {
      const form = new FormData();
      form.append('file', file);
      const { data } = await api.post('/farmers/import', form, {
        params: { dry_run: dryRun },
        headers: { 'Content-Type': 'multipart/form-data' },
      });
      return data;
    },
    onSuccess: (res) => {
      if (res && res.dry_run === false) {
        qc.invalidateQueries({ queryKey: [KEY] });
      }
    },
  });
}

/** Download the blank import template (CSV) as a browser file save. */
export async function downloadImportTemplate() {
  const { data } = await api.get('/farmers/import/template', {
    responseType: 'blob',
  });
  triggerBlobDownload(data, 'customers_import_template.csv');
}

function triggerBlobDownload(blob, filename) {
  const url = window.URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  a.remove();
  window.URL.revokeObjectURL(url);
}

/** Full farmer profile (base + current lead + recent visits + livestock +
 *  follow-ups + totals). */
export function useFarmer(id) {
  return useQuery({
    queryKey: [KEY, 'detail', id],
    queryFn: async () => (await api.get(`/farmers/${id}`)).data,
    enabled: !!id,
  });
}

/** Cursor-paginated visit history — fetches one page (default 30) at a time
 *  via `fetchNextPage`, for farmers whose visit count can run into the
 *  hundreds/thousands. Pair with a virtualized list on the render side so the
 *  DOM only ever holds the visible rows. */
export function useFarmerVisitsInfinite(id, pageSize = 30) {
  return useInfiniteQuery({
    queryKey: [KEY, 'visits-infinite', id],
    queryFn: async ({ pageParam }) =>
      (
        await api.get(`/farmers/${id}/visits`, {
          params: { limit: pageSize, cursor: pageParam ?? undefined },
        })
      ).data,
    initialPageParam: null,
    getNextPageParam: (lastPage) => (lastPage.has_more ? lastPage.next_cursor : undefined),
    enabled: !!id,
  });
}

export function useFarmerLivestock(id) {
  return useQuery({
    queryKey: [KEY, 'livestock', id],
    queryFn: async () => (await api.get(`/farmers/${id}/livestock-history`)).data,
    enabled: !!id,
  });
}

export function useFarmerLeadHistory(id) {
  return useQuery({
    queryKey: [KEY, 'leads', id],
    queryFn: async () => (await api.get(`/farmers/${id}/lead-history`)).data,
    enabled: !!id,
  });
}

/** Full order history for one farmer (checklist #35). */
export function useFarmerOrders(id) {
  return useQuery({
    queryKey: [KEY, 'orders', id],
    queryFn: async () => (await api.get(`/orders/farmer/${id}`)).data,
    enabled: !!id,
  });
}

export function useCreateFarmer() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (body) => (await api.post('/farmers', body)).data,
    onSuccess: () => qc.invalidateQueries({ queryKey: [KEY] }),
  });
}

export function useUpdateFarmer(id) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (body) => (await api.put(`/farmers/${id}`, body)).data,
    onSuccess: () => qc.invalidateQueries({ queryKey: [KEY] }),
  });
}
