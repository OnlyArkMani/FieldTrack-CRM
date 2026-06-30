import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../../core/network/api_exceptions.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_button.dart';
import '../../../../core/widgets/app_card.dart';
import '../data/dsr_repository.dart';
import '../models/dsr.dart';

/// Shown once after the employee hits END attendance.
/// Displays the auto-generated DSR for review, collects an optional
/// end-of-day note, and submits.
///
/// [reportDate] is today's date. The screen loads the DSR by date (giving the
/// background generation task a moment to finish) and derives the report ID
/// from the loaded record.
class DsrReviewScreen extends ConsumerStatefulWidget {
  const DsrReviewScreen({
    super.key,
    required this.reportDate,
  });

  final DateTime reportDate;

  @override
  ConsumerState<DsrReviewScreen> createState() => _DsrReviewScreenState();
}

class _DsrReviewScreenState extends ConsumerState<DsrReviewScreen>
    with SingleTickerProviderStateMixin {
  DsrDetail? _detail;
  bool _loading = true;
  String? _error;
  bool _submitting = false;
  bool _submitted = false;

  final _noteController = TextEditingController();
  late final AnimationController _checkAnim;
  late final Animation<double> _checkScale;

  @override
  void initState() {
    super.initState();
    _checkAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _checkScale = CurvedAnimation(parent: _checkAnim, curve: Curves.elasticOut);
    _loadDsr();
  }

  @override
  void dispose() {
    _noteController.dispose();
    _checkAnim.dispose();
    super.dispose();
  }

  Future<void> _loadDsr() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repo = ref.read(dsrRepositoryProvider);
      final detail = await repo.myForDate(widget.reportDate);
      if (mounted) setState(() => _detail = detail);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _submit() async {
    final note = _noteController.text.trim();
    if (note.length > 300) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Note must be 300 characters or less.')),
      );
      return;
    }
    final reportId = _detail?.id;
    if (reportId == null) return;
    setState(() => _submitting = true);
    try {
      await ref.read(dsrRepositoryProvider).submit(
            reportId,
            endOfDayNote: note.isEmpty ? null : note,
          );
      if (!mounted) return;
      setState(() {
        _submitted = true;
        _submitting = false;
      });
      await _checkAnim.forward();
      await Future<void>.delayed(const Duration(seconds: 1));
      if (mounted) context.go('/home/dashboard');
    } on ApiException catch (e) {
      if (mounted) {
        setState(() => _submitting = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _submitting = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.appColors;
    final dateLabel =
        DateFormat('d MMMM yyyy').format(widget.reportDate.toLocal());

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Text(
          "Today's Summary",
          style: AppTextStyles.titleMedium(context),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (!_submitted)
            TextButton(
              onPressed: _submitting ? null : () => context.go('/home/dashboard'),
              child: Text(
                'Skip for now',
                style: TextStyle(
                  color: theme.colorScheme.onSurface.withOpacity(0.55),
                  fontSize: 13,
                ),
              ),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: _submitted ? _buildSuccess(context) : _buildBody(context, dateLabel),
      ),
    );
  }

  Widget _buildSuccess(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          ScaleTransition(
            scale: _checkScale,
            child: Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.check, color: Colors.white, size: 44),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            'Report submitted to manager',
            style: AppTextStyles.titleMedium(context),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context, String dateLabel) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(_error!, style: const TextStyle(color: Colors.red)),
            const SizedBox(height: 12),
            TextButton(onPressed: _loadDsr, child: const Text('Retry')),
          ],
        ),
      );
    }
    final d = _detail;
    if (d == null) return const SizedBox.shrink();

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Date sub-header
        Text(
          dateLabel,
          style: AppTextStyles.labelSmall(context).copyWith(
            color: context.appColors.textSecondary,
          ),
        ),
        const SizedBox(height: 12),

        // ── Stat cards row ────────────────────────────────────────────
        _StatCardsRow(detail: d),
        const SizedBox(height: 20),

        // ── Completed visits ──────────────────────────────────────────
        if (d.visits.isNotEmpty) ...[
          _SectionHeader(label: 'Visits (${d.visits.length})'),
          ...d.visits.map((v) => _VisitCard(visit: v)),
          const SizedBox(height: 8),
        ],

        // ── Orders ────────────────────────────────────────────────────
        if (d.orders.isNotEmpty) ...[
          _SectionHeader(label: 'Orders (${d.orders.length})'),
          ...d.orders.map((o) => _OrderCard(order: o)),
          const SizedBox(height: 8),
        ],

        // ── Follow-ups ────────────────────────────────────────────────
        if (d.followUps.isNotEmpty) ...[
          _SectionHeader(label: 'Follow-ups Scheduled (${d.followUps.length})'),
          ...d.followUps.map((f) => _FollowUpCard(followUp: f)),
          const SizedBox(height: 8),
        ],

        // ── End-of-day note ───────────────────────────────────────────
        const SizedBox(height: 4),
        _SectionHeader(label: 'End-of-Day Note'),
        AppCard(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Column(
            children: [
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: _noteController,
                builder: (context, value, _) {
                  return TextField(
                    controller: _noteController,
                    maxLength: 300,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      hintText: 'Add your summary note...',
                      border: InputBorder.none,
                      counterText: '',
                    ),
                    style: AppTextStyles.bodyMedium(context),
                  );
                },
              ),
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: _noteController,
                builder: (context, value, _) {
                  final count = value.text.length;
                  return Align(
                    alignment: Alignment.centerRight,
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        '$count / 300',
                        style: AppTextStyles.labelSmall(context).copyWith(
                          color: count > 280
                              ? Theme.of(context).colorScheme.error
                              : context.appColors.textSecondary,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),

        // ── Submit button ─────────────────────────────────────────────
        AppButton(
          label: 'Submit Daily Report',
          isLoading: _submitting,
          onPressed: _submitting ? null : _submit,
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}

// ── Stat cards ────────────────────────────────────────────────────────────────

class _StatCardsRow extends StatelessWidget {
  const _StatCardsRow({required this.detail});
  final DsrDetail detail;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 72,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          _StatCard(
            label: 'Visits',
            value: detail.visitsCompleted.toString(),
            icon: Icons.storefront_outlined,
          ),
          _StatCard(
            label: 'Orders',
            value: detail.ordersCaptures.toString(),
            icon: Icons.shopping_bag_outlined,
          ),
          _StatCard(
            label: 'Hot',
            value: detail.hotLeads.toString(),
            color: const Color(0xFFE8645A),
          ),
          _StatCard(
            label: 'Warm',
            value: detail.warmLeads.toString(),
            color: const Color(0xFFF5A623),
          ),
          _StatCard(
            label: 'Cold',
            value: detail.coldLeads.toString(),
            color: const Color(0xFF8B7FD4),
          ),
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.label,
    required this.value,
    this.icon,
    this.color,
  });

  final String label;
  final String value;
  final IconData? icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final accent = color ?? Theme.of(context).colorScheme.primary;
    return Container(
      width: 72,
      margin: const EdgeInsets.only(right: 8),
      decoration: BoxDecoration(
        color: accent.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accent.withOpacity(0.25)),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (icon != null)
            Icon(icon, size: 16, color: accent)
          else
            const SizedBox(height: 2),
          Text(
            value,
            style: AppTextStyles.titleMedium(context)
                .copyWith(color: accent, fontWeight: FontWeight.w700),
          ),
          Text(
            label,
            style: AppTextStyles.labelSmall(context)
                .copyWith(color: accent, fontSize: 10),
          ),
        ],
      ),
    );
  }
}

// ── Section header ─────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        label,
        style: AppTextStyles.labelMedium(context).copyWith(
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

// ── Visit card ─────────────────────────────────────────────────────────────────

class _VisitCard extends StatelessWidget {
  const _VisitCard({required this.visit});
  final DsrVisit visit;

  Color _leadColor(BuildContext context, String? status) =>
      switch (status?.toUpperCase()) {
        'HOT' => const Color(0xFFE8645A),
        'WARM' => const Color(0xFFF5A623),
        'COLD' => const Color(0xFF8B7FD4),
        _ => Theme.of(context).colorScheme.outline,
      };

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  visit.farmerName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.bodyMedium(context)
                      .copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  '${visit.purposeLabel}  ·  ${visit.timeLabel}',
                  style: AppTextStyles.labelSmall(context)
                      .copyWith(color: colors.textSecondary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (visit.leadStatus != null)
            _LeadChip(status: visit.leadStatus!),
        ],
      ),
    );
  }
}

class _LeadChip extends StatelessWidget {
  const _LeadChip({required this.status});
  final String status;

  Color _bg(BuildContext context) => switch (status.toUpperCase()) {
        'HOT' => const Color(0xFFE8645A),
        'WARM' => const Color(0xFFF5A623),
        'COLD' => const Color(0xFF8B7FD4),
        _ => Theme.of(context).colorScheme.outline,
      };

  @override
  Widget build(BuildContext context) {
    final bg = _bg(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg.withOpacity(0.15),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: bg.withOpacity(0.4)),
      ),
      child: Text(
        status,
        style: TextStyle(
            color: bg, fontSize: 11, fontWeight: FontWeight.w600),
      ),
    );
  }
}

// ── Order card ─────────────────────────────────────────────────────────────────

class _OrderCard extends StatelessWidget {
  const _OrderCard({required this.order});
  final DsrOrder order;

  @override
  Widget build(BuildContext context) {
    final dateLabel =
        DateFormat('d MMM yyyy').format(order.deliveryDate.toLocal());
    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  order.farmerName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.bodyMedium(context)
                      .copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  'Delivery: $dateLabel'
                  '${order.paymentMode != null ? '  ·  ${order.paymentMode}' : ''}',
                  style: AppTextStyles.labelSmall(context).copyWith(
                    color: context.appColors.textSecondary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '${order.bagsCount} bags',
            style: AppTextStyles.bodyMedium(context).copyWith(
              color: const Color(0xFF4CAF7D),
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Follow-up card ─────────────────────────────────────────────────────────────

class _FollowUpCard extends StatelessWidget {
  const _FollowUpCard({required this.followUp});
  final DsrFollowUp followUp;

  @override
  Widget build(BuildContext context) {
    final dateLabel =
        DateFormat('d MMM yyyy').format(followUp.scheduledDate.toLocal());
    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          const Icon(Icons.event_note_outlined, size: 18, color: Color(0xFF8B7FD4)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  followUp.farmerName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.bodyMedium(context)
                      .copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  '$dateLabel'
                  '${followUp.scheduledTime != null ? '  ·  ${followUp.scheduledTime}' : ''}'
                  '${followUp.purpose != null ? '  ·  ${followUp.purpose}' : ''}',
                  style: AppTextStyles.labelSmall(context).copyWith(
                    color: context.appColors.textSecondary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
