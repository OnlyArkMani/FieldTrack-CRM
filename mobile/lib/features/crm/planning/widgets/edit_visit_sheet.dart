import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_bottom_sheet.dart';
import '../../../../core/widgets/app_button.dart';
import '../models/visit_plan.dart';
import '../providers/visit_plan_provider.dart';
import 'add_visit_sheet.dart' show visitPurposes;
import 'plan_item_card.dart' show purposeLabel;

/// Edit a still-planned stop: time, day, purpose, target bags. Only reachable
/// for PLANNED items — once checked in, the pencil doesn't appear.
class EditVisitSheet {
  EditVisitSheet._();

  static Future<void> show(
    BuildContext context,
    PlanItem item,
    DateTime currentDay,
  ) {
    return AppBottomSheet.show(
      context,
      title: 'Edit visit',
      initialSize: 0.65,
      maxSize: 0.9,
      child: _EditVisitFlow(item: item, currentDay: currentDay),
    );
  }
}

class _EditVisitFlow extends ConsumerStatefulWidget {
  const _EditVisitFlow({required this.item, required this.currentDay});
  final PlanItem item;
  final DateTime currentDay;

  @override
  ConsumerState<_EditVisitFlow> createState() => _EditVisitFlowState();
}

class _EditVisitFlowState extends ConsumerState<_EditVisitFlow> {
  late TimeOfDay? _time;
  late String _purpose;
  late DateTime _day;
  late final TextEditingController _targetBagsController;

  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final item = widget.item;
    _time = _parseTimeSlot(item.timeSlot);
    _purpose = visitPurposes.contains(item.purpose)
        ? item.purpose!
        : visitPurposes.first;
    _day = widget.currentDay;
    _targetBagsController =
        TextEditingController(text: item.targetOrderBags?.toString() ?? '');
  }

  @override
  void dispose() {
    _targetBagsController.dispose();
    super.dispose();
  }

  static TimeOfDay? _parseTimeSlot(String? slot) {
    if (slot == null || slot.length < 5) return null;
    final hour = int.tryParse(slot.substring(0, 2));
    final minute = int.tryParse(slot.substring(3, 5));
    if (hour == null || minute == null) return null;
    return TimeOfDay(hour: hour, minute: minute);
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final slot = _time == null
        ? null
        : '${_time!.hour.toString().padLeft(2, '0')}:'
            '${_time!.minute.toString().padLeft(2, '0')}:00';
    final targetBags = int.tryParse(_targetBagsController.text.trim());
    final ok = await ref.read(visitPlanProvider.notifier).editItem(
          widget.item,
          timeSlot: slot,
          purpose: _purpose,
          targetOrderBags: targetBags,
          planDate: _day,
        );
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _saving = false;
        _error = ref.read(visitPlanProvider).error ?? 'Could not save changes';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.item.farmerName,
            style: AppTextStyles.bodyMedium.copyWith(color: scheme.onSurface),
            maxLines: 1,
            overflow: TextOverflow.ellipsis),
        const SizedBox(height: AppDimens.grid * 2),
        Text('Day',
            style: AppTextStyles.bodyMedium.copyWith(color: scheme.onSurface)),
        const SizedBox(height: AppDimens.grid),
        InkWell(
          borderRadius: BorderRadius.circular(AppDimens.buttonRadius),
          onTap: () async {
            final picked = await showDatePicker(
              context: context,
              initialDate: _day,
              firstDate: DateTime.now(),
              lastDate: DateTime.now().add(const Duration(days: 90)),
            );
            if (picked != null) setState(() => _day = picked);
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
                Icon(Icons.event_rounded, size: 18, color: colors.textSecondary),
                const SizedBox(width: AppDimens.grid),
                Text(
                  '${_day.day}/${_day.month}/${_day.year}',
                  style: AppTextStyles.body.copyWith(color: scheme.onSurface),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: AppDimens.grid * 2),
        Text('Time slot',
            style: AppTextStyles.bodyMedium.copyWith(color: scheme.onSurface)),
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
                    color:
                        _time == null ? colors.textSecondary : scheme.onSurface,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: AppDimens.grid * 2),
        Text('Purpose',
            style: AppTextStyles.bodyMedium.copyWith(color: scheme.onSurface)),
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
            style: AppTextStyles.bodyMedium.copyWith(color: scheme.onSurface)),
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
              style: AppTextStyles.caption.copyWith(color: scheme.error)),
        ],
        const SizedBox(height: AppDimens.grid * 2.5),
        AppButton(
          label: 'Save Changes',
          icon: Icons.check_rounded,
          isLoading: _saving,
          onPressed: _saving ? null : _save,
        ),
        SizedBox(
            height: AppDimens.grid + MediaQuery.of(context).viewInsets.bottom),
      ],
    );
  }
}
