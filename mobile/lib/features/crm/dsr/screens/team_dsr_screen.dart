import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/state_views.dart';
import '../data/dsr_repository.dart';
import '../models/dsr.dart';

/// Selected date for the Team DSR screen. Held in a provider rather than
/// local State — some ancestor rebuild (shell/router related) can dispose
/// and recreate this screen's State right as the date picker resolves; a
/// plain `DateTime` field would silently reset to `DateTime.now()` when that
/// happens, making date changes look like they never took effect.
final _teamDsrDateProvider = StateProvider<DateTime>((ref) => DateTime.now());

/// Manager-only: their team's DSR status for a chosen date. Scope is
/// auto-filtered to the caller's team on the backend. Tap a member with a DSR
/// to see a read-only detail.
class TeamDsrScreen extends ConsumerStatefulWidget {
  const TeamDsrScreen({super.key});

  @override
  ConsumerState<TeamDsrScreen> createState() => _TeamDsrScreenState();
}

class _TeamDsrScreenState extends ConsumerState<TeamDsrScreen> {
  late Future<List<TeamDsrItem>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<TeamDsrItem>> _load() =>
      ref.read(dsrRepositoryProvider).teamDsrs(ref.read(_teamDsrDateProvider));

  void _reload() => setState(() => _future = _load());

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: ref.read(_teamDsrDateProvider),
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now(),
    );
    if (picked != null) {
      ref.read(_teamDsrDateProvider.notifier).state = picked;
      _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final date = ref.watch(_teamDsrDateProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Team DSR',
            maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Date selector
            Padding(
              padding: const EdgeInsets.all(AppDimens.grid * 2),
              child: InkWell(
                onTap: _pickDate,
                borderRadius: BorderRadius.circular(AppDimens.buttonRadius),
                child: Container(
                  padding: const EdgeInsets.all(AppDimens.grid * 1.5),
                  decoration: BoxDecoration(
                    border: Border.all(
                        color: colors.textSecondary.withValues(alpha: 0.25)),
                    borderRadius: BorderRadius.circular(AppDimens.buttonRadius),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.event_rounded,
                          size: 18, color: colors.textSecondary),
                      const SizedBox(width: AppDimens.grid),
                      Text(DateFormat('EEEE, d MMM yyyy').format(date),
                          style: AppTextStyles.bodyMedium.copyWith(
                              color: Theme.of(context).colorScheme.onSurface)),
                      const Spacer(),
                      Text('Change',
                          style: AppTextStyles.caption.copyWith(
                              color: Theme.of(context).colorScheme.primary)),
                    ],
                  ),
                ),
              ),
            ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: () async => _reload(),
                child: FutureBuilder<List<TeamDsrItem>>(
                  future: _future,
                  builder: (context, snap) {
                    if (snap.connectionState == ConnectionState.waiting) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (snap.hasError) {
                      return ErrorStateView(
                        message: 'Could not load team DSRs.',
                        onRetry: _reload,
                      );
                    }
                    final items = snap.data ?? const <TeamDsrItem>[];
                    if (items.isEmpty) {
                      return ListView(children: const [
                        SizedBox(height: 80),
                        Center(child: Text('No team members found.')),
                      ]);
                    }
                    return ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.symmetric(
                          horizontal: AppDimens.grid * 2),
                      itemCount: items.length,
                      itemBuilder: (_, i) => _MemberTile(
                        item: items[i],
                        date: date,
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MemberTile extends ConsumerWidget {
  const _MemberTile({required this.item, required this.date});
  final TeamDsrItem item;
  final DateTime date;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.appColors;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppDimens.grid * 1.5),
      child: AppCard(
        child: InkWell(
          onTap: () => _open(context, ref),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(item.employeeName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.bodyMedium.copyWith(
                            color: Theme.of(context).colorScheme.onSurface)),
                    const SizedBox(height: 2),
                    Text(
                      '${item.visitsCompleted} visits · ${item.ordersCaptured} orders',
                      style: AppTextStyles.caption
                          .copyWith(color: colors.textSecondary),
                    ),
                  ],
                ),
              ),
              _StatusChip(status: item.status),
              if (item.isLate) ...[
                const SizedBox(width: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Theme.of(context)
                        .colorScheme
                        .error
                        .withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text('LATE',
                      style: AppTextStyles.caption.copyWith(
                          color: Theme.of(context).colorScheme.error,
                          fontWeight: FontWeight.w700)),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _open(BuildContext context, WidgetRef ref) async {
    if (item.reportId == null || item.status == 'MISSING') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No DSR submitted yet.')),
      );
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.appColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _MemberDsrSheet(
        employeeId: item.employeeId,
        employeeName: item.employeeName,
        date: date,
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});
  final String status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colors = context.appColors;
    final (Color c, String label) = switch (status) {
      'SUBMITTED' => (colors.statusActive, 'Submitted'),
      'DRAFT' => (scheme.primary, 'Draft'),
      _ => (scheme.error, 'Missing'),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(label,
          style: AppTextStyles.caption
              .copyWith(color: c, fontWeight: FontWeight.w700)),
    );
  }
}

class _MemberDsrSheet extends ConsumerWidget {
  const _MemberDsrSheet({
    required this.employeeId,
    required this.employeeName,
    required this.date,
  });
  final int employeeId;
  final String employeeName;
  final DateTime date;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.appColors;
    final scheme = Theme.of(context).colorScheme;
    final future =
        ref.read(dsrRepositoryProvider).teamMemberDsr(employeeId, date);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      builder: (context, controller) => FutureBuilder<DsrDetail>(
        future: future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const SizedBox(
                height: 250, child: Center(child: CircularProgressIndicator()));
          }
          if (snap.hasError || snap.data == null) {
            return SizedBox(
                height: 250,
                child: Center(
                    child: Text('No DSR found for this date.',
                        style: AppTextStyles.body
                            .copyWith(color: colors.textSecondary))));
          }
          final d = snap.data!;
          final initial =
              employeeName.isNotEmpty ? employeeName[0].toUpperCase() : 'E';

          return ListView(
            controller: controller,
            padding: const EdgeInsets.all(AppDimens.grid * 2),
            children: [
              // Header Card with Avatar
              Row(
                children: [
                  CircleAvatar(
                    radius: 22,
                    backgroundColor: scheme.primary.withValues(alpha: 0.15),
                    child: Text(
                      initial,
                      style: AppTextStyles.heading
                          .copyWith(color: scheme.primary),
                    ),
                  ),
                  const SizedBox(width: AppDimens.grid * 1.5),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          employeeName,
                          style: AppTextStyles.heading.copyWith(
                              color: scheme.onSurface,
                              fontWeight: FontWeight.bold),
                        ),
                        Text(
                          DateFormat('EEEE, d MMMM yyyy').format(date),
                          style: AppTextStyles.caption
                              .copyWith(color: colors.textSecondary),
                        ),
                      ],
                    ),
                  ),
                  if (d.isSubmitted)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.green.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        d.isLate ? 'Late Submission' : 'Submitted',
                        style: AppTextStyles.caption.copyWith(
                            color: d.isLate ? Colors.orange.shade800 : Colors.green.shade700,
                            fontWeight: FontWeight.w600),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: AppDimens.grid * 2),

              // Metrics Card Row
              Container(
                padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                      color: scheme.outline.withValues(alpha: 0.2)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _statItem(context, 'Visits', d.visitsCompleted.toString(),
                        scheme.primary),
                    _divider(context),
                    _statItem(context, 'Orders', d.ordersCaptures.toString(),
                        Colors.green.shade700),
                    _divider(context),
                    _statItem(
                        context, 'Hot', d.hotLeads.toString(), Colors.red.shade700),
                    _divider(context),
                    _statItem(
                        context, 'Warm', d.warmLeads.toString(), Colors.orange.shade800),
                    _divider(context),
                    _statItem(
                        context, 'Cold', d.coldLeads.toString(), Colors.blue.shade700),
                  ],
                ),
              ),

              // Employee Note Callout Card
              if (d.endOfDayNote != null && d.endOfDayNote!.isNotEmpty) ...[
                const SizedBox(height: AppDimens.grid * 2),
                _calloutCard(
                  context,
                  title: "Employee's note",
                  content: d.endOfDayNote!,
                  icon: Icons.chat_bubble_outline_rounded,
                  color: scheme.primary,
                ),
              ],

              // Late Checkout Reason Callout Card
              if (d.lateCheckoutReason != null &&
                  d.lateCheckoutReason!.isNotEmpty) ...[
                const SizedBox(height: AppDimens.grid * 1.5),
                _calloutCard(
                  context,
                  title: "Late checkout reason",
                  content: d.lateCheckoutReason!,
                  icon: Icons.warning_amber_rounded,
                  color: Colors.amber.shade900,
                ),
              ],

              // Manager Comment Callout Card
              if (d.managerComment != null &&
                  d.managerComment!.isNotEmpty) ...[
                const SizedBox(height: AppDimens.grid * 1.5),
                _calloutCard(
                  context,
                  title: "Manager comment",
                  content: d.managerComment!,
                  icon: Icons.rate_review_rounded,
                  color: Colors.green.shade700,
                ),
              ],

              // Visits Section
              if (d.visits.isNotEmpty) ...[
                const SizedBox(height: AppDimens.grid * 2.5),
                _sectionHeader(context, 'Visits', d.visits.length),
                const SizedBox(height: AppDimens.grid),
                ...d.visits.map((v) => _TeamVisitTile(visit: v)),
              ],

              // Orders Section
              if (d.orders.isNotEmpty) ...[
                const SizedBox(height: AppDimens.grid * 2.5),
                _sectionHeader(context, 'Orders Captured', d.orders.length),
                const SizedBox(height: AppDimens.grid),
                ...d.orders.map((o) => _orderTile(context, o)),
              ],

              // Follow-ups Section
              if (d.followUps.isNotEmpty) ...[
                const SizedBox(height: AppDimens.grid * 2.5),
                _sectionHeader(context, 'Scheduled Follow-ups', d.followUps.length),
                const SizedBox(height: AppDimens.grid),
                ...d.followUps.map((f) => _followUpTile(context, f)),
              ],

              const SizedBox(height: AppDimens.grid * 3),
            ],
          );
        },
      ),
    );
  }

  Widget _statItem(
      BuildContext context, String label, String value, Color color) {
    final colors = context.appColors;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(value,
            style: AppTextStyles.heading
                .copyWith(color: color, fontWeight: FontWeight.bold)),
        const SizedBox(height: 2),
        Text(label,
            style: AppTextStyles.caption
                .copyWith(color: colors.textSecondary, fontSize: 11)),
      ],
    );
  }

  Widget _divider(BuildContext context) {
    return Container(
      height: 24,
      width: 1,
      color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.2),
    );
  }

  Widget _calloutCard(
    BuildContext context, {
    required String title,
    required String content,
    required IconData icon,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 6),
              Text(
                title,
                style: AppTextStyles.caption.copyWith(
                    color: color, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            content,
            style: AppTextStyles.body.copyWith(
                color: Theme.of(context).colorScheme.onSurface,
                height: 1.35),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(BuildContext context, String title, int count) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Text(title,
            style: AppTextStyles.bodyMedium.copyWith(
                color: scheme.onSurface, fontWeight: FontWeight.bold)),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: scheme.primary.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            '$count',
            style: AppTextStyles.caption.copyWith(
                color: scheme.primary, fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }

  Widget _orderTile(BuildContext context, DsrOrder o) {
    final colors = context.appColors;
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outline.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          Icon(Icons.shopping_bag_outlined, size: 18, color: Colors.green.shade700),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              o.farmerName,
              style: AppTextStyles.body.copyWith(color: scheme.onSurface),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            '${o.bagsCount} bags · ${DateFormat('d MMM').format(o.deliveryDate)}',
            style: AppTextStyles.caption.copyWith(color: colors.textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _followUpTile(BuildContext context, DsrFollowUp f) {
    final colors = context.appColors;
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outline.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          Icon(Icons.event_repeat_rounded, size: 18, color: scheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              f.farmerName,
              style: AppTextStyles.body.copyWith(color: scheme.onSurface),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            DateFormat('d MMM yyyy').format(f.scheduledDate),
            style: AppTextStyles.caption.copyWith(color: colors.textSecondary),
          ),
        ],
      ),
    );
  }
}

/// Expandable, tappable visit row in the team-member DSR drill-down. Tap the
/// name to open the customer's full history; expand to see meeting detail.
class _TeamVisitTile extends StatefulWidget {
  const _TeamVisitTile({required this.visit});
  final DsrVisit visit;

  @override
  State<_TeamVisitTile> createState() => _TeamVisitTileState();
}

class _TeamVisitTileState extends State<_TeamVisitTile> {
  bool _expanded = false;

  String _money(double? v) => v == null
      ? '—'
      : '₹${v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2)}';

  @override
  Widget build(BuildContext context) {
    final v = widget.visit;
    final colors = context.appColors;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: v.farmerId == null
                      ? null
                      : () => context.push('/farmer/${v.farmerId}'),
                  child: Text(v.farmerName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.body.copyWith(
                          color: v.farmerId == null
                              ? scheme.onSurface
                              : scheme.primary,
                          fontWeight: FontWeight.w600)),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${v.purposeLabel}${v.leadStatus != null ? ' · ${v.leadStatus}' : ''}',
                style:
                    AppTextStyles.caption.copyWith(color: colors.textSecondary),
              ),
              if (v.hasDetail)
                GestureDetector(
                  onTap: () => setState(() => _expanded = !_expanded),
                  child: Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Icon(
                        _expanded
                            ? Icons.expand_less_rounded
                            : Icons.expand_more_rounded,
                        size: 18,
                        color: colors.textSecondary),
                  ),
                ),
            ],
          ),
          if (_expanded && v.hasDetail)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 4, bottom: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (v.timeLabel.isNotEmpty)
                    _detail(context, 'Time', v.timeLabel),
                  if (v.meetingHighlights != null &&
                      v.meetingHighlights!.isNotEmpty)
                    _detail(context, 'Highlights', v.meetingHighlights!),
                  if (v.farmerConcerns != null && v.farmerConcerns!.isNotEmpty)
                    _detail(context, 'Concerns', v.farmerConcerns!),
                  if (v.productInterest != null &&
                      v.productInterest!.isNotEmpty)
                    _detail(context, 'Product interest', v.productInterest!),
                  if (v.orderBags != null && v.orderBags! > 0)
                    _detail(context, 'Order',
                        '${v.orderBags} bags · ${_money(v.orderValue)}'),
                  if (v.vetRequired)
                    _detail(context, 'Vet needed',
                        '${v.vetCattleCount ?? '—'} cattle'),
                  if (v.breed != null ||
                      v.currentBrand != null ||
                      v.livestockCattle != null)
                    _detail(
                        context,
                        'Livestock',
                        [
                          if (v.livestockCattle != null)
                            '${v.livestockCattle} cattle',
                          if (v.breed != null) v.breed,
                          if (v.currentBrand != null) v.currentBrand,
                          if (v.pricePerBag != null) _money(v.pricePerBag),
                        ].whereType<String>().join(' · ')),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _detail(BuildContext context, String k, String val) {
    final colors = context.appColors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: RichText(
        text: TextSpan(
          style: AppTextStyles.caption.copyWith(color: colors.textSecondary),
          children: [
            TextSpan(
                text: '$k: ',
                style: const TextStyle(fontWeight: FontWeight.w700)),
            TextSpan(text: val),
          ],
        ),
      ),
    );
  }
}
