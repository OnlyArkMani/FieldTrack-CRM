import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../../core/network/api_exceptions.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/state_views.dart';
import '../data/dsr_repository.dart';
import '../models/dsr.dart';

/// Accessible from the Profile tab.
/// Shows the employee's DSR history by month with status chips and late badges.
/// Tapping a row opens the full detail view.
class DsrHistoryScreen extends ConsumerStatefulWidget {
  const DsrHistoryScreen({super.key});

  @override
  ConsumerState<DsrHistoryScreen> createState() => _DsrHistoryScreenState();
}

class _DsrHistoryScreenState extends ConsumerState<DsrHistoryScreen> {
  final _now = DateTime.now();
  late int _selectedYear;
  late int _selectedMonth;

  List<DsrSummary>? _items;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _selectedYear = _now.year;
    _selectedMonth = _now.month;
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repo = ref.read(dsrRepositoryProvider);
      final items = await repo.myHistory(
        month: _selectedMonth,
        year: _selectedYear,
      );
      if (mounted) setState(() => _items = items);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _prevMonth() {
    setState(() {
      if (_selectedMonth == 1) {
        _selectedMonth = 12;
        _selectedYear--;
      } else {
        _selectedMonth--;
      }
    });
    _load();
  }

  void _nextMonth() {
    final isCurrentMonth =
        _selectedMonth == _now.month && _selectedYear == _now.year;
    if (isCurrentMonth) return;
    setState(() {
      if (_selectedMonth == 12) {
        _selectedMonth = 1;
        _selectedYear++;
      } else {
        _selectedMonth++;
      }
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final monthLabel = DateFormat('MMMM yyyy')
        .format(DateTime(_selectedYear, _selectedMonth));
    final isCurrentMonth =
        _selectedMonth == _now.month && _selectedYear == _now.year;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Daily Reports',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Month picker
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(
                    icon: const Icon(Icons.chevron_left),
                    onPressed: _prevMonth,
                  ),
                  Text(
                    monthLabel,
                    style: AppTextStyles.heading,
                  ),
                  IconButton(
                    icon: const Icon(Icons.chevron_right),
                    onPressed: isCurrentMonth ? null : _nextMonth,
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _buildBody(context),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return ErrorStateView(message: _error!, onRetry: _load);
    }
    final items = _items ?? [];
    if (items.isEmpty) {
      return Center(
        child: Text(
          'No reports for this month',
          style: AppTextStyles.bodyMedium.copyWith(
            color: context.appColors.textSecondary,
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      itemCount: items.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, i) => _DsrListItem(
        summary: items[i],
        onTap: () => _openDetail(context, items[i]),
      ),
    );
  }

  void _openDetail(BuildContext context, DsrSummary summary) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _DsrDetailView(summary: summary),
      ),
    );
  }
}

// ── List item ─────────────────────────────────────────────────────────────────

class _DsrListItem extends StatelessWidget {
  const _DsrListItem({required this.summary, required this.onTap});
  final DsrSummary summary;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final dateLabel =
        DateFormat('EEE, d MMM').format(summary.reportDate.toLocal());
    final colors = context.appColors;

    return AppCard(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      dateLabel,
                      style: AppTextStyles.bodyMedium
                          .copyWith(fontWeight: FontWeight.w600),
                    ),
                    if (summary.isLate) ...[
                      const SizedBox(width: 6),
                      _LateBadge(),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '${summary.visitsCompleted} visits  ·  '
                  '${summary.ordersCaptures} orders  ·  '
                  '${summary.hotLeads + summary.warmLeads + summary.coldLeads} leads',
                  style: AppTextStyles.caption
                      .copyWith(color: colors.textSecondary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _StatusChip(status: summary.status),
          const SizedBox(width: 4),
          const Icon(Icons.chevron_right, size: 18),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});
  final String status;

  @override
  Widget build(BuildContext context) {
    final isSubmitted = status == 'SUBMITTED';
    final color = isSubmitted
        ? const Color(0xFF4CAF7D)
        : Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withOpacity(0.35)),
      ),
      child: Text(
        isSubmitted ? 'Submitted' : 'Draft',
        style:
            TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _LateBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    const coral = Color(0xFFE8645A);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: coral.withOpacity(0.12),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: coral.withOpacity(0.4)),
      ),
      child: const Text(
        'LATE',
        style: TextStyle(
            color: coral, fontSize: 10, fontWeight: FontWeight.w700),
      ),
    );
  }
}

// ── Detail view (push-over, read-only) ────────────────────────────────────────

class _DsrDetailView extends ConsumerStatefulWidget {
  const _DsrDetailView({required this.summary});
  final DsrSummary summary;

  @override
  ConsumerState<_DsrDetailView> createState() => _DsrDetailViewState();
}

class _DsrDetailViewState extends ConsumerState<_DsrDetailView> {
  DsrDetail? _detail;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repo = ref.read(dsrRepositoryProvider);
      final detail = await repo.myForDate(widget.summary.reportDate);
      if (mounted) setState(() => _detail = detail);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = DateFormat('d MMMM yyyy')
        .format(widget.summary.reportDate.toLocal());
    return Scaffold(
      appBar: AppBar(
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? ErrorStateView(message: _error!, onRetry: _load)
                : _buildContent(context),
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    final d = _detail;
    if (d == null) return const SizedBox.shrink();
    final colors = context.appColors;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Status row
        Row(
          children: [
            _StatusChip(status: d.status),
            if (d.isLate) ...[const SizedBox(width: 6), _LateBadge()],
          ],
        ),
        const SizedBox(height: 16),

        // Stats
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _InfoChip(label: 'Visits', value: d.visitsCompleted.toString()),
            _InfoChip(label: 'Orders', value: d.ordersCaptures.toString()),
            _InfoChip(
                label: 'Hot Leads',
                value: d.hotLeads.toString(),
                color: const Color(0xFFE8645A)),
            _InfoChip(
                label: 'Warm Leads',
                value: d.warmLeads.toString(),
                color: const Color(0xFFF5A623)),
            _InfoChip(
                label: 'Cold Leads',
                value: d.coldLeads.toString(),
                color: const Color(0xFF8B7FD4)),
            _InfoChip(
                label: 'Follow-ups',
                value: d.followUps.length.toString()),
          ],
        ),
        const SizedBox(height: 16),

        // Visits
        if (d.visits.isNotEmpty) ...[
          _SectionLabel('Visits'),
          ...d.visits.map(
            (v) => AppCard(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          v.farmerName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTextStyles.bodyMedium
                              .copyWith(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${v.purposeLabel}  ·  ${v.timeLabel}',
                          style: AppTextStyles.caption
                              .copyWith(color: colors.textSecondary),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  if (v.leadStatus != null)
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: _LeadBadge(status: v.leadStatus!),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],

        // Orders
        if (d.orders.isNotEmpty) ...[
          _SectionLabel('Orders'),
          ...d.orders.map(
            (o) => AppCard(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      o.farmerName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.bodyMedium,
                    ),
                  ),
                  Text(
                    '${o.bagsCount} bags',
                    style: AppTextStyles.bodyMedium.copyWith(
                      color: const Color(0xFF4CAF7D),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],

        // End-of-day note
        if (d.endOfDayNote != null && d.endOfDayNote!.isNotEmpty) ...[
          _SectionLabel('End-of-Day Note'),
          AppCard(
            child: Text(
              d.endOfDayNote!,
              style: AppTextStyles.bodyMedium,
            ),
          ),
          const SizedBox(height: 12),
        ],

        // Manager comment (amber card)
        if (d.managerComment != null && d.managerComment!.isNotEmpty) ...[
          _SectionLabel('Manager Comment'),
          AppCard(
            color: const Color(0xFFF5A623).withOpacity(0.1),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.comment_outlined,
                    size: 16, color: Color(0xFFF5A623)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    d.managerComment!,
                    style: AppTextStyles.bodyMedium,
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 24),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label);
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8, top: 4),
        child: Text(
          label,
          style: AppTextStyles.caption
              .copyWith(fontWeight: FontWeight.w600),
        ),
      );
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.label, required this.value, this.color});
  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: c.withOpacity(0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.withOpacity(0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(value,
              style: TextStyle(
                  color: c,
                  fontWeight: FontWeight.w700,
                  fontSize: 14)),
          const SizedBox(width: 4),
          Text(label,
              style: TextStyle(
                  color: c.withOpacity(0.8),
                  fontSize: 12)),
        ],
      ),
    );
  }
}

class _LeadBadge extends StatelessWidget {
  const _LeadBadge({required this.status});
  final String status;

  Color _color() => switch (status.toUpperCase()) {
        'HOT' => const Color(0xFFE8645A),
        'WARM' => const Color(0xFFF5A623),
        'COLD' => const Color(0xFF8B7FD4),
        _ => Colors.grey,
      };

  @override
  Widget build(BuildContext context) {
    final c = _color();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: c.withOpacity(0.12),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: c.withOpacity(0.4)),
      ),
      child: Text(
        status,
        style:
            TextStyle(color: c, fontSize: 11, fontWeight: FontWeight.w600),
      ),
    );
  }
}
