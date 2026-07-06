import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../../core/network/api_exceptions.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_button.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/state_views.dart';
import '../data/order_repository.dart';
import '../models/pending_order.dart';

/// Supervisor/admin approval queue for orders captured in the field. Approve
/// inline; Reject asks for a reason (min 10 chars, enforced server-side too).
class OrderApprovalsScreen extends ConsumerStatefulWidget {
  const OrderApprovalsScreen({super.key});

  @override
  ConsumerState<OrderApprovalsScreen> createState() =>
      _OrderApprovalsScreenState();
}

class _OrderApprovalsScreenState extends ConsumerState<OrderApprovalsScreen> {
  int? _busyId;

  String _money(double? v) => v == null
      ? '—'
      : '₹${v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2)}';

  Future<void> _approve(PendingOrder o) async {
    setState(() => _busyId = o.id);
    try {
      await ref.read(orderRepositoryProvider).review(o.id, action: 'APPROVE');
      HapticFeedback.mediumImpact();
      ref.invalidate(pendingOrdersProvider);
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<void> _reject(PendingOrder o) async {
    final reason = await _askReason();
    if (reason == null) return;
    setState(() => _busyId = o.id);
    try {
      await ref.read(orderRepositoryProvider).review(
            o.id,
            action: 'REJECT',
            rejectionReason: reason,
          );
      HapticFeedback.mediumImpact();
      ref.invalidate(pendingOrdersProvider);
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<String?> _askReason() async {
    final ctrl = TextEditingController();
    String? err;
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Reject order'),
          content: TextField(
            controller: ctrl,
            maxLines: 3,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              hintText: 'Reason (min 10 characters)',
              errorText: err,
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel')),
            TextButton(
              onPressed: () {
                final v = ctrl.text.trim();
                if (v.length < 10) {
                  setLocal(() => err = 'At least 10 characters.');
                  return;
                }
                Navigator.pop(ctx, v);
              },
              child: const Text('Reject'),
            ),
          ],
        ),
      ),
    );
    ctrl.dispose();
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(pendingOrdersProvider);
    final colors = context.appColors;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Order approvals',
            maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: SafeArea(
        child: async.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ErrorStateView(
            message: e.toString(),
            onRetry: () => ref.invalidate(pendingOrdersProvider),
          ),
          data: (orders) {
            if (orders.isEmpty) {
              return Center(
                child: Text('No orders awaiting approval.',
                    style: AppTextStyles.body
                        .copyWith(color: colors.textSecondary)),
              );
            }
            return RefreshIndicator(
              onRefresh: () async => ref.invalidate(pendingOrdersProvider),
              child: ListView.builder(
                padding: const EdgeInsets.all(AppDimens.grid * 2),
                itemCount: orders.length,
                itemBuilder: (context, i) => _card(orders[i]),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _card(PendingOrder o) {
    final colors = context.appColors;
    final scheme = Theme.of(context).colorScheme;
    final busy = _busyId == o.id;
    final delivery = o.deliveryDate != null
        ? DateFormat('d MMM yyyy').format(o.deliveryDate!)
        : '—';
    return Padding(
      padding: const EdgeInsets.only(bottom: AppDimens.grid * 1.5),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(o.farmerName ?? 'Customer #${o.farmerId}',
                      style: AppTextStyles.bodyMedium
                          .copyWith(color: scheme.onSurface),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ),
                Text('${o.bagsCount} bags',
                    style: AppTextStyles.bodyMedium.copyWith(
                        color: scheme.primary, fontWeight: FontWeight.w700)),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              [
                if (o.employeeName != null) 'By ${o.employeeName}',
                'Delivery $delivery',
                if (o.paymentMode != null) o.paymentMode!,
                'Value ${_money(o.totalValue)}',
              ].join('  ·  '),
              style: AppTextStyles.caption.copyWith(color: colors.textSecondary),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            if (o.specialNotes != null && o.specialNotes!.isNotEmpty) ...[
              const SizedBox(height: AppDimens.grid * 0.5),
              Text(o.specialNotes!,
                  style: AppTextStyles.caption.copyWith(color: scheme.onSurface),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis),
            ],
            const SizedBox(height: AppDimens.grid),
            Row(
              children: [
                Expanded(
                  child: AppButton(
                    label: 'Approve',
                    icon: Icons.check_rounded,
                    isLoading: busy,
                    onPressed: busy ? null : () => _approve(o),
                  ),
                ),
                const SizedBox(width: AppDimens.grid * 1.5),
                Expanded(
                  child: AppButton(
                    label: 'Reject',
                    icon: Icons.close_rounded,
                    variant: AppButtonVariant.secondary,
                    onPressed: busy ? null : () => _reject(o),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
