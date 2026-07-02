import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/state_views.dart';
import '../data/dsr_repository.dart';
import '../models/dsr.dart';

/// Supervisor-only: their team's DSR status for a chosen date. Scope is
/// auto-filtered to the caller's team on the backend. Tap a member with a DSR
/// to see a read-only detail.
class TeamDsrScreen extends ConsumerStatefulWidget {
  const TeamDsrScreen({super.key});

  @override
  ConsumerState<TeamDsrScreen> createState() => _TeamDsrScreenState();
}

class _TeamDsrScreenState extends ConsumerState<TeamDsrScreen> {
  DateTime _date = DateTime.now();
  late Future<List<TeamDsrItem>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<TeamDsrItem>> _load() =>
      ref.read(dsrRepositoryProvider).teamDsrs(_date);

  void _reload() => setState(() => _future = _load());

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now(),
    );
    if (picked != null) {
      _date = picked;
      _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
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
                    borderRadius:
                        BorderRadius.circular(AppDimens.buttonRadius),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.event_rounded,
                          size: 18, color: colors.textSecondary),
                      const SizedBox(width: AppDimens.grid),
                      Text(DateFormat('EEEE, d MMM yyyy').format(_date),
                          style: AppTextStyles.bodyMedium.copyWith(
                              color: Theme.of(context).colorScheme.onSurface)),
                      const Spacer(),
                      Text('Change',
                          style: AppTextStyles.caption
                              .copyWith(color: Theme.of(context).colorScheme.primary)),
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
                        date: _date,
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
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.error.withValues(alpha: 0.12),
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
    final future = ref.read(dsrRepositoryProvider).teamMemberDsr(employeeId, date);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.92,
      builder: (context, controller) => FutureBuilder<DsrDetail>(
        future: future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const SizedBox(
                height: 200, child: Center(child: CircularProgressIndicator()));
          }
          if (snap.hasError || snap.data == null) {
            return const SizedBox(
                height: 200,
                child: Center(child: Text('No DSR found for this date.')));
          }
          final d = snap.data!;
          return ListView(
            controller: controller,
            padding: const EdgeInsets.all(AppDimens.grid * 2),
            children: [
              Text(employeeName,
                  style: AppTextStyles.heading
                      .copyWith(color: Theme.of(context).colorScheme.onSurface)),
              Text(DateFormat('d MMMM yyyy').format(date),
                  style:
                      AppTextStyles.caption.copyWith(color: colors.textSecondary)),
              const SizedBox(height: AppDimens.grid * 1.5),
              Wrap(spacing: 12, runSpacing: 8, children: [
                _stat(context, 'Visits', d.visitsCompleted.toString()),
                _stat(context, 'Orders', d.ordersCaptures.toString()),
                _stat(context, 'Hot', d.hotLeads.toString()),
                _stat(context, 'Warm', d.warmLeads.toString()),
                _stat(context, 'Cold', d.coldLeads.toString()),
              ]),
              if (d.visits.isNotEmpty) ...[
                const SizedBox(height: AppDimens.grid * 2),
                _sectionTitle(context, 'Visits'),
                ...d.visits.map((v) => _row(context, v.farmerName,
                    '${v.purposeLabel}${v.leadStatus != null ? ' · ${v.leadStatus}' : ''}')),
              ],
              if (d.orders.isNotEmpty) ...[
                const SizedBox(height: AppDimens.grid * 2),
                _sectionTitle(context, 'Orders'),
                ...d.orders.map((o) => _row(context, o.farmerName,
                    '${o.bagsCount} bags · ${DateFormat('d MMM').format(o.deliveryDate)}')),
              ],
              if (d.followUps.isNotEmpty) ...[
                const SizedBox(height: AppDimens.grid * 2),
                _sectionTitle(context, 'Follow-ups'),
                ...d.followUps.map((f) => _row(context, f.farmerName,
                    DateFormat('d MMM').format(f.scheduledDate))),
              ],
              if (d.endOfDayNote != null && d.endOfDayNote!.isNotEmpty) ...[
                const SizedBox(height: AppDimens.grid * 2),
                _sectionTitle(context, "Employee's note"),
                Text(d.endOfDayNote!,
                    style: AppTextStyles.body.copyWith(
                        fontStyle: FontStyle.italic, color: colors.textSecondary)),
              ],
              const SizedBox(height: AppDimens.grid * 2),
            ],
          );
        },
      ),
    );
  }

  Widget _stat(BuildContext context, String label, String value) {
    final colors = context.appColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(value,
            style: AppTextStyles.heading
                .copyWith(color: Theme.of(context).colorScheme.onSurface)),
        Text(label,
            style: AppTextStyles.caption.copyWith(color: colors.textSecondary)),
      ],
    );
  }

  Widget _sectionTitle(BuildContext context, String t) => Padding(
        padding: const EdgeInsets.only(bottom: AppDimens.grid),
        child: Text(t,
            style: AppTextStyles.bodyMedium
                .copyWith(color: Theme.of(context).colorScheme.onSurface)),
      );

  Widget _row(BuildContext context, String left, String right) {
    final colors = context.appColors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(left,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.body
                    .copyWith(color: Theme.of(context).colorScheme.onSurface)),
          ),
          const SizedBox(width: 8),
          Text(right,
              style:
                  AppTextStyles.caption.copyWith(color: colors.textSecondary)),
        ],
      ),
    );
  }
}
