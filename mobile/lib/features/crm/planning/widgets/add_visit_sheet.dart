import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/network/api_exceptions.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_bottom_sheet.dart';
import '../../../../core/widgets/app_button.dart';
import '../../../../core/widgets/app_card.dart';
import '../../farmers/data/farmer_repository.dart';
import '../../farmers/models/farmer.dart';
import '../../farmers/utils.dart';
import '../../farmers/widgets/lead_status_badge.dart';
import '../models/visit_plan.dart';
import '../providers/visit_plan_provider.dart';
import 'plan_item_card.dart' show purposeLabel;

const _purposes = [
  'FIRST_VISIT',
  'FOLLOW_UP',
  'ORDER_COLLECTION',
  'RELATIONSHIP_VISIT',
];

/// Add-a-visit flow: search farmers → pick one → set time + purpose → add.
class AddVisitSheet {
  AddVisitSheet._();

  static Future<void> show(BuildContext context) {
    return AppBottomSheet.show(
      context,
      title: 'Add visit to plan',
      initialSize: 0.75,
      maxSize: 0.95,
      child: const _AddVisitFlow(),
    );
  }
}

class _AddVisitFlow extends ConsumerStatefulWidget {
  const _AddVisitFlow();

  @override
  ConsumerState<_AddVisitFlow> createState() => _AddVisitFlowState();
}

class _AddVisitFlowState extends ConsumerState<_AddVisitFlow> {
  final _searchController = TextEditingController();
  Timer? _debounce;

  bool _loading = false;
  String? _error;
  List<FarmerListItem> _results = const [];

  FarmerListItem? _selected;
  TimeOfDay? _time;
  String _purpose = 'FIRST_VISIT';

  @override
  void initState() {
    super.initState();
    _search(''); // initial page
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => _search(v));
  }

  Future<void> _search(String q) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page =
          await ref.read(farmerRepositoryProvider).list(search: q, limit: 20);
      if (!mounted) return;
      setState(() {
        _results = page.items;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  void _add() {
    final farmer = _selected!;
    final id = -DateTime.now().microsecondsSinceEpoch;
    final slot = _time == null
        ? null
        : '${_time!.hour.toString().padLeft(2, '0')}:'
            '${_time!.minute.toString().padLeft(2, '0')}:00';
    ref.read(visitPlanProvider.notifier).addItem(
          PlanItem(
            id: id,
            farmerId: farmer.id,
            farmerName: farmer.name,
            village: farmer.village,
            leadStatus: farmer.leadStatus,
            lastVisitAt: farmer.lastVisitAt,
            sequenceOrder: 9999,
            timeSlot: slot,
            purpose: _purpose,
            status: 'PLANNED',
          ),
        );
    HapticFeedback.selectionClick();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return _selected == null ? _searchStep(context) : _configureStep(context);
  }

  // ── Step 1: search + pick ──────────────────────────────────────────────
  Widget _searchStep(BuildContext context) {
    final colors = context.appColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _searchController,
          autofocus: true,
          onChanged: _onSearchChanged,
          textInputAction: TextInputAction.search,
          style: AppTextStyles.body
              .copyWith(color: Theme.of(context).colorScheme.onSurface),
          decoration: InputDecoration(
            hintText: 'Search farmers by name or village',
            prefixIcon: Icon(Icons.search_rounded,
                size: 20, color: colors.textSecondary),
          ),
        ),
        const SizedBox(height: AppDimens.grid * 1.5),
        if (_loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: AppDimens.grid * 3),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppDimens.grid * 2),
            child: Text(_error!,
                style: AppTextStyles.body
                    .copyWith(color: Theme.of(context).colorScheme.error)),
          )
        else if (_results.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppDimens.grid * 3),
            child: Center(
              child: Text('No farmers found',
                  style: AppTextStyles.body
                      .copyWith(color: colors.textSecondary)),
            ),
          )
        else
          ..._results.map((f) => Padding(
                padding: const EdgeInsets.only(bottom: AppDimens.grid),
                child: _FarmerResultCard(
                  farmer: f,
                  onTap: () => setState(() => _selected = f),
                ),
              )),
      ],
    );
  }

  // ── Step 2: time + purpose ──────────────────────────────────────────────
  Widget _configureStep(BuildContext context) {
    final colors = context.appColors;
    final scheme = Theme.of(context).colorScheme;
    final farmer = _selected!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Selected farmer header + change.
        Row(
          children: [
            Expanded(
              child: Text(farmer.name,
                  style: AppTextStyles.bodyMedium
                      .copyWith(color: scheme.onSurface),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ),
            TextButton(
              onPressed: () => setState(() => _selected = null),
              child: const Text('Change'),
            ),
          ],
        ),
        const SizedBox(height: AppDimens.grid),
        Text('Time slot',
            style:
                AppTextStyles.bodyMedium.copyWith(color: scheme.onSurface)),
        const SizedBox(height: AppDimens.grid),
        InkWell(
          borderRadius: BorderRadius.circular(AppDimens.buttonRadius),
          onTap: () async {
            final picked = await showTimePicker(
              context: context,
              initialTime: _time ?? const TimeOfDay(hour: 9, minute: 0),
            );
            if (picked != null) setState(() => _time = picked);
          },
          child: Container(
            padding: const EdgeInsets.all(AppDimens.grid * 1.5),
            decoration: BoxDecoration(
              border: Border.all(
                  color: colors.textSecondary.withValues(alpha: 0.25)),
              borderRadius: BorderRadius.circular(AppDimens.buttonRadius),
            ),
            child: Row(
              children: [
                Icon(Icons.schedule_rounded,
                    size: 18, color: colors.textSecondary),
                const SizedBox(width: AppDimens.grid),
                Text(
                  _time == null ? 'Any time (optional)' : _time!.format(context),
                  style: AppTextStyles.body.copyWith(
                    color: _time == null
                        ? colors.textSecondary
                        : scheme.onSurface,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: AppDimens.grid * 2),
        Text('Purpose',
            style:
                AppTextStyles.bodyMedium.copyWith(color: scheme.onSurface)),
        const SizedBox(height: AppDimens.grid),
        Wrap(
          spacing: AppDimens.grid,
          runSpacing: AppDimens.grid,
          children: [
            for (final p in _purposes)
              GestureDetector(
                onTap: () => setState(() => _purpose = p),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: AppDimens.grid * 1.5,
                      vertical: AppDimens.grid * 0.75),
                  decoration: BoxDecoration(
                    color: _purpose == p
                        ? scheme.secondary.withValues(alpha: 0.16)
                        : colors.card,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: _purpose == p
                          ? scheme.secondary
                          : colors.textSecondary.withValues(alpha: 0.2),
                    ),
                  ),
                  child: Text(
                    purposeLabel(p),
                    style: AppTextStyles.caption.copyWith(
                      color: _purpose == p
                          ? scheme.secondary
                          : colors.textSecondary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: AppDimens.grid * 2.5),
        AppButton(
          label: 'Add to Plan',
          icon: Icons.add_rounded,
          onPressed: _add,
        ),
        SizedBox(
            height: AppDimens.grid + MediaQuery.of(context).viewInsets.bottom),
      ],
    );
  }
}

class _FarmerResultCard extends StatelessWidget {
  const _FarmerResultCard({required this.farmer, required this.onTap});

  final FarmerListItem farmer;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final scheme = Theme.of(context).colorScheme;
    return AppCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(farmer.name,
                    style: AppTextStyles.bodyMedium
                        .copyWith(color: scheme.onSurface),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ),
              LeadStatusBadge(status: farmer.leadStatus),
            ],
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              if (farmer.village != null && farmer.village!.isNotEmpty) ...[
                Expanded(
                  child: Text(farmer.village!,
                      style: AppTextStyles.caption
                          .copyWith(color: colors.textSecondary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ),
              ] else
                const Spacer(),
              Text(lastVisitedLabel(farmer.lastVisitAt),
                  style: AppTextStyles.caption
                      .copyWith(color: colors.textSecondary)),
            ],
          ),
        ],
      ),
    );
  }
}
