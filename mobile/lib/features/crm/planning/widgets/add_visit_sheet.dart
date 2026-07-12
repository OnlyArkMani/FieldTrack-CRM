import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/network/api_exceptions.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../services/sync/connectivity_service.dart';
import '../../../attendance/providers/upcoming_leaves_provider.dart'
    show isLeaveDateCached;
import '../../../../core/widgets/app_bottom_sheet.dart';
import '../../../../core/widgets/app_button.dart';
import '../../../../core/widgets/app_card.dart';
import '../../farmers/data/farmer_repository.dart';
import '../../farmers/models/farmer.dart';
import '../../farmers/utils.dart';
import '../../farmers/widgets/customer_type_chip.dart';
import '../../farmers/widgets/lead_status_badge.dart';
import '../../farmers/widgets/quick_add_customer_sheet.dart';
import '../models/visit_plan.dart';
import '../providers/visit_plan_provider.dart';
import 'plan_item_card.dart' show purposeLabel;

const visitPurposes = [
  'FIRST_VISIT',
  'FOLLOW_UP',
  'ORDER_COLLECTION',
  'RELATIONSHIP_VISIT',
];

/// Field staff work roughly 4am (early-morning milk collection rounds) to
/// 8pm — kept in sync with `_TIME_SLOT_MIN`/`_TIME_SLOT_MAX` in
/// app/schemas/crm.py.
const timeSlotErrorMessage = 'Please select a time between 4:00 AM and 8:00 PM.';

bool isValidTimeSlot(TimeOfDay t) {
  final minutes = t.hour * 60 + t.minute;
  return minutes >= 4 * 60 && minutes <= 20 * 60;
}

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
  final _targetBagsController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _search(''); // initial page
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    _targetBagsController.dispose();
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

  Future<void> _addCustomer() async {
    final created = await QuickAddCustomerSheet.show(context);
    if (created == null || !mounted) return;
    setState(() => _selected = created);
  }

  void _add() {
    if (_time == null) {
      setState(() => _error = 'Please select a time slot.');
      return;
    }

    final offline = !ref.read(connectivityServiceProvider).current;
    if (offline) {
      final planDate = ref.read(visitPlanProvider).date;
      final prefs = ref.read(sharedPreferencesProvider);
      if (isLeaveDateCached(prefs, planDate)) {
        setState(() => _error = "You're on leave on that day — pick a different date.");
        return;
      }
    }

    final farmer = _selected!;
    final id = -DateTime.now().microsecondsSinceEpoch;
    final slot = _time == null
        ? null
        : '${_time!.hour.toString().padLeft(2, '0')}:'
            '${_time!.minute.toString().padLeft(2, '0')}:00';
    final targetBags = int.tryParse(_targetBagsController.text.trim());
    ref.read(visitPlanProvider.notifier).addItem(
          PlanItem(
            id: id,
            farmerId: farmer.id,
            farmerName: farmer.name,
            village: farmer.village,
            customerType: farmer.customerType,
            leadStatus: farmer.leadStatus,
            lastVisitAt: farmer.lastVisitAt,
            sequenceOrder: 9999,
            timeSlot: slot,
            purpose: _purpose,
            targetOrderBags: targetBags,
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
        OutlinedButton.icon(
          onPressed: _addCustomer,
          icon: const Icon(Icons.person_add_alt_1_rounded, size: 18),
          label: const Text('Add customer'),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(44),
            foregroundColor: AppPalette.amber,
            side: BorderSide(color: AppPalette.amber.withValues(alpha: 0.55)),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppDimens.buttonRadius),
            ),
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
        Text('Time slot *',
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
            if (picked == null) return;
            if (!isValidTimeSlot(picked)) {
              setState(() => _error = timeSlotErrorMessage);
              return;
            }
            setState(() {
              _time = picked;
              _error = null;
            });
          },
          child: Container(
            padding: const EdgeInsets.all(AppDimens.grid * 1.5),
            decoration: BoxDecoration(
              border: Border.all(
                color: _time == null
                    ? scheme.error.withValues(alpha: 0.5)
                    : colors.textSecondary.withValues(alpha: 0.25),
              ),
              borderRadius: BorderRadius.circular(AppDimens.buttonRadius),
            ),
            child: Row(
              children: [
                Icon(Icons.schedule_rounded,
                    size: 18, color: colors.textSecondary),
                const SizedBox(width: AppDimens.grid),
                Text(
                  _time == null ? 'Select a time' : _time!.format(context),
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
            for (final p in visitPurposes)
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
        const SizedBox(height: AppDimens.grid * 2),
        Text('Target order (bags)',
            style:
                AppTextStyles.bodyMedium.copyWith(color: scheme.onSurface)),
        const SizedBox(height: AppDimens.grid),
        TextField(
          controller: _targetBagsController,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          style: AppTextStyles.body.copyWith(color: scheme.onSurface),
          decoration: const InputDecoration(
            hintText: 'e.g. 10 (optional)',
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: AppDimens.grid * 1.5),
          Text(_error!,
              style: AppTextStyles.caption
                  .copyWith(color: Theme.of(context).colorScheme.error)),
        ],
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
              const SizedBox(width: AppDimens.grid),
              CustomerTypeChip(type: farmer.customerType),
              const SizedBox(width: AppDimens.grid),
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
