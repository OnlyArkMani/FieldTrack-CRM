import { useState } from 'react';
import dayjs from 'dayjs';
import { Check, X } from 'lucide-react';

import { usePendingOrders, useReviewOrder } from '@/hooks/useOrders';
import { useTeams } from '@/hooks/useTeams';
import PageHeader from '@/components/ui/PageHeader';
import Card from '@/components/ui/Card';
import Table from '@/components/ui/Table';
import Badge from '@/components/ui/Badge';
import Button from '@/components/ui/Button';
import Modal from '@/components/ui/Modal';
import { Select, Textarea } from '@/components/ui/Input';

function money(v) {
  if (v == null) return '—';
  const n = Number(v);
  return `₹${Number.isInteger(n) ? n : n.toFixed(2)}`;
}

/** Manager approval workflow for orders captured in the field (checklist #34). */
export default function OrdersPage() {
  const [teamId, setTeamId] = useState('');
  const [rejectTarget, setRejectTarget] = useState(null); // order being rejected
  const [reason, setReason] = useState('');

  const { data: teams = [] } = useTeams();
  const { data: orders = [], isLoading } = usePendingOrders(teamId);
  const review = useReviewOrder();

  const approve = (order) => {
    review.mutate({ orderId: order.id, action: 'APPROVE' });
  };

  const openReject = (order) => {
    setRejectTarget(order);
    setReason('');
  };

  const confirmReject = () => {
    if (reason.trim().length < 10 || !rejectTarget) return;
    review.mutate(
      { orderId: rejectTarget.id, action: 'REJECT', rejectionReason: reason.trim() },
      { onSuccess: () => setRejectTarget(null) },
    );
  };

  const columns = [
     {
      key: 'Employee',
      header: 'Employee',
      render: (o) => o.employee_name ?? `Employee #${o.employee_id}`,
    },
    {
      key: 'Customer',
      header: 'Customer',
      render: (o) => o.farmer_name ?? `Farmer #${o.farmer_id}`,
    },
    {
      key: 'Customer Type',
      header: 'Customer Type',
      render: (o) => o.customer_type ?? '—',
    },
    {
      key: 'target_bags',
      header: 'Target Bags',
      render: (o) => o.target_order_bags ?? '—',
    },
    { key: 'bags', header: 'Actual Bags', render: (o) => o.bags_count },
    { key: 'value', header: 'Value', render: (o) => money(o.total_value) },
    {
      key: 'delivery',
      header: 'Delivery date',
      render: (o) => dayjs(o.delivery_date).format('MMM D, YYYY'),
    },
    { key: 'payment', header: 'Payment', render: (o) => o.payment_mode || '—' },
    {
      key: 'actions',
      header: '',
      align: 'right',
      render: (o) => (
        <div className="flex justify-end gap-2">
          <Button
            size="sm"
            variant="secondary"
            icon={Check}
            loading={review.isPending}
            onClick={() => approve(o)}
          >
            Approve
          </Button>
          <Button
            size="sm"
            variant="danger"
            icon={X}
            disabled={review.isPending}
            onClick={() => openReject(o)}
          >
            Reject
          </Button>
        </div>
      ),
    },
  ];

  return (
    <div className="space-y-6">
      <PageHeader
        title="Orders"
        subtitle="Orders awaiting manager approval"
      />

      <Card className="flex flex-wrap items-end gap-3">
        <div className="w-56">
          <Select label="Team" value={teamId} onChange={(e) => setTeamId(e.target.value)}>
            <option value="">All teams</option>
            {teams.map((t) => (
              <option key={t.id} value={t.id}>
                {t.name}
              </option>
            ))}
          </Select>
        </div>
        {orders.length > 0 && (
          <Badge color="var(--ft-primary)">{orders.length} pending</Badge>
        )}
      </Card>

      <Card padded={false}>
        <Table
          columns={columns}
          rows={orders}
          rowKey={(o) => o.id}
          loading={isLoading}
          empty="No orders awaiting approval."
        />
      </Card>

      <Modal
        open={!!rejectTarget}
        onClose={() => setRejectTarget(null)}
        title="Reject order"
        footer={
          <>
            <Button variant="outline" onClick={() => setRejectTarget(null)}>
              Cancel
            </Button>
            <Button
              variant="danger"
              disabled={reason.trim().length < 10}
              loading={review.isPending}
              onClick={confirmReject}
            >
              Reject order
            </Button>
          </>
        }
      >
        <Textarea
          label="Reason (min 10 characters)"
          value={reason}
          onChange={(e) => setReason(e.target.value)}
          rows={3}
          placeholder="Why is this order being rejected?"
        />
      </Modal>
    </div>
  );
}
