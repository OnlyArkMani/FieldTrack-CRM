import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/network/api_exceptions.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/state_views.dart';
import '../data/vet_repository.dart';
import '../models/vet_request.dart';

const _statuses = ['REQUESTED', 'SCHEDULED', 'DONE'];

/// Dashboard listing customers who requested a vet during a visit. Scope is
/// enforced server-side (employee=own, manager=team, admin=all). Filterable
/// by status; each card can be advanced REQUESTED → SCHEDULED → DONE.
class VetDashboardScreen extends ConsumerStatefulWidget {
  const VetDashboardScreen({super.key});

  @override
  ConsumerState<VetDashboardScreen> createState() => _VetDashboardScreenState();
}

class _VetDashboardScreenState extends ConsumerState<VetDashboardScreen> {
  String? _filter; // null = all

  Color _statusColor(BuildContext context, String status) {
    final scheme = Theme.of(context).colorScheme;
    return switch (status.toUpperCase()) {
      'REQUESTED' => scheme.error,
      'SCHEDULED' => scheme.primary,
      'DONE' => context.appColors.statusActive,
      _ => scheme.outline,
    };
  }

  Future<void> _setStatus(VetRequest r, String status) async {
    try {
      await ref.read(vetRepositoryProvider).updateStatus(r.visitId, status);
      HapticFeedback.selectionClick();
      ref.invalidate(vetRequestsProvider(_filter));
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(vetRequestsProvider(_filter));
    final colors = context.appColors;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Vet requests',
            maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Filter chips
            Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: AppDimens.grid * 2, vertical: AppDimens.grid),
              child: Row(
                children: [
                  _chip('All', _filter == null,
                      () => setState(() => _filter = null)),
                  for (final s in _statuses) ...[
                    const SizedBox(width: AppDimens.grid),
                    _chip(_pretty(s), _filter == s,
                        () => setState(() => _filter = s)),
                  ],
                ],
              ),
            ),
            Expanded(
              child: async.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => ErrorStateView(
                  message: e.toString(),
                  onRetry: () => ref.invalidate(vetRequestsProvider(_filter)),
                ),
                data: (items) {
                  if (items.isEmpty) {
                    return Center(
                      child: Text('No vet requests.',
                          style: AppTextStyles.body
                              .copyWith(color: colors.textSecondary)),
                    );
                  }
                  return RefreshIndicator(
                    onRefresh: () async =>
                        ref.invalidate(vetRequestsProvider(_filter)),
                    child: ListView.builder(
                      padding: const EdgeInsets.all(AppDimens.grid * 2),
                      itemCount: items.length,
                      itemBuilder: (context, i) => _card(items[i]),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(String label, bool selected, VoidCallback onTap) {
    final colors = context.appColors;
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: AppDimens.grid * 1.25, vertical: AppDimens.grid * 0.6),
        decoration: BoxDecoration(
          color:
              selected ? scheme.primary.withValues(alpha: 0.16) : colors.card,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected
                ? scheme.primary
                : colors.textSecondary.withValues(alpha: 0.25),
          ),
        ),
        child: Text(label,
            style: AppTextStyles.caption.copyWith(
              color: selected ? scheme.primary : colors.textSecondary,
              fontWeight: FontWeight.w600,
            )),
      ),
    );
  }

  Future<void> _call(BuildContext context, String phone) async {
    final uri = Uri(scheme: 'tel', path: phone);
    try {
      if (!await launchUrl(uri)) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not start a call to $phone')),
          );
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not start a call to $phone')),
        );
      }
    }
  }

  Widget _card(VetRequest r) {
    final colors = context.appColors;
    final scheme = Theme.of(context).colorScheme;
    final statusColor = _statusColor(context, r.vetStatus);
    final dateLabel = r.visitDate != null
        ? DateFormat('d MMM yyyy').format(r.visitDate!)
        : '—';
    return Padding(
      padding: const EdgeInsets.only(bottom: AppDimens.grid * 1.5),
      child: AppCard(
        onTap: r.farmerId != null
            ? () => context.push('/farmer/${r.farmerId}')
            : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(r.farmerName,
                      style: AppTextStyles.bodyMedium.copyWith(
                        color: scheme.onSurface,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: AppDimens.grid, vertical: 2),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(6),
                    border:
                        Border.all(color: statusColor.withValues(alpha: 0.4)),
                  ),
                  child: Text(_pretty(r.vetStatus),
                      style: TextStyle(
                          color: statusColor,
                          fontSize: 11,
                          fontWeight: FontWeight.w700)),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              [
                r.customerType.label,
                if (r.village != null && r.village!.isNotEmpty) r.village,
                dateLabel,
              ].join('  ·  '),
              style:
                  AppTextStyles.caption.copyWith(color: colors.textSecondary),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: AppDimens.grid),
            Row(
              children: [
                Icon(Icons.pets_rounded, size: 15, color: colors.textSecondary),
                const SizedBox(width: 4),
                Text('${r.vetCattleCount ?? '—'} cattle',
                    style: AppTextStyles.caption.copyWith(
                      color: scheme.onSurface,
                      fontWeight: FontWeight.w500,
                    )),
                if (r.employeeName != null) ...[
                  const SizedBox(width: AppDimens.grid * 1.5),
                  Icon(Icons.person_rounded,
                      size: 15, color: colors.textSecondary),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(r.employeeName!,
                        style: AppTextStyles.caption
                            .copyWith(color: colors.textSecondary),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                  ),
                ],
              ],
            ),
            if (r.vetNotes != null && r.vetNotes!.isNotEmpty) ...[
              const SizedBox(height: AppDimens.grid),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(AppDimens.grid * 1.5),
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: scheme.primary.withValues(alpha: 0.15),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.medical_information_rounded,
                            size: 14, color: scheme.primary),
                        const SizedBox(width: 6),
                        Text(
                          'Symptoms / Notes',
                          style: AppTextStyles.caption.copyWith(
                            color: scheme.primary,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      r.vetNotes!,
                      style: AppTextStyles.bodyMedium.copyWith(
                        color: scheme.onSurface,
                        fontStyle: FontStyle.italic,
                      ),
                      maxLines: 5,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: AppDimens.grid),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                if (r.phone != null && r.phone!.isNotEmpty)
                  InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => _call(context, r.phone!),
                    child: Padding(
                      padding: const EdgeInsets.only(
                          left: 0, right: 8, top: 4, bottom: 4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.phone_in_talk_rounded,
                              size: 16, color: colors.statusActive),
                          const SizedBox(width: 4),
                          Text(
                            'Call ${r.customerType.label}',
                            style: AppTextStyles.caption.copyWith(
                              color: colors.statusActive,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                else
                  const SizedBox.shrink(),
                PopupMenuButton<String>(
                  onSelected: (s) => _setStatus(r, s),
                  itemBuilder: (context) => [
                    for (final s in _statuses)
                      if (s != r.vetStatus)
                        PopupMenuItem(
                            value: s, child: Text('Mark ${_pretty(s)}')),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.only(
                        left: 8, right: 0, top: 4, bottom: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.edit_rounded,
                            size: 15, color: scheme.primary),
                        const SizedBox(width: 4),
                        Text('Update status',
                            style: AppTextStyles.caption.copyWith(
                                color: scheme.primary,
                                fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _pretty(String s) => s[0].toUpperCase() + s.substring(1).toLowerCase();
}
