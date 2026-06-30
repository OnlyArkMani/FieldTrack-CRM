import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/network/api_exceptions.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_bottom_sheet.dart';
import '../../../../core/widgets/app_button.dart';
import '../../leads/data/lead_repository.dart';
import '../models/farmer.dart';
import '../providers/farmer_provider.dart';
import '../utils.dart';
import 'lead_status_badge.dart';

/// Bottom sheet to change a farmer's lead status WITHOUT a visit. Hot/Warm/Cold
/// selector, a required reason (min 10 chars), and — for Warm/Cold — an optional
/// follow-up date/time to schedule at the same time. Posts to /leads/update-status.
class UpdateLeadSheet {
  UpdateLeadSheet._();

  static Future<void> show(
    BuildContext context, {
    required int farmerId,
    LeadStatus? current,
  }) {
    return AppBottomSheet.show(
      context,
      title: 'Update lead status',
      initialSize: 0.72,
      maxSize: 0.95,
      child: _UpdateLeadForm(farmerId: farmerId, current: current),
    );
  }
}

class _UpdateLeadForm extends ConsumerStatefulWidget {
  const _UpdateLeadForm({required this.farmerId, this.current});

  final int farmerId;
  final LeadStatus? current;

  @override
  ConsumerState<_UpdateLeadForm> createState() => _UpdateLeadFormState();
}

class _UpdateLeadFormState extends ConsumerState<_UpdateLeadForm> {
  late LeadStatus _selected = widget.current ?? LeadStatus.warm;
  final _reason = TextEditingController();
  final _purpose = TextEditingController();
  DateTime? _followUpDate;
  TimeOfDay? _followUpTime;

  bool _saving = false;
  String? _reasonError;
  String? _formError;

  bool get _needsFollowUp =>
      _selected == LeadStatus.warm || _selected == LeadStatus.cold;

  @override
  void dispose() {
    _reason.dispose();
    _purpose.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final reason = _reason.text.trim();
    setState(() {
      _reasonError =
          reason.length < 10 ? 'Please give a reason (at least 10 characters)' : null;
      _formError = null;
    });
    if (reason.length < 10) return;

    setState(() => _saving = true);
    try {
      final time = _followUpTime == null
          ? null
          : '${_followUpTime!.hour.toString().padLeft(2, '0')}:'
              '${_followUpTime!.minute.toString().padLeft(2, '0')}:00';
      await ref.read(leadRepositoryProvider).updateStatus(
            farmerId: widget.farmerId,
            status: _selected,
            reason: reason,
            followUpDate: _needsFollowUp ? _followUpDate : null,
            followUpTime: _needsFollowUp ? time : null,
            followUpPurpose: _needsFollowUp ? _purpose.text.trim() : null,
          );
      if (!mounted) return;
      HapticFeedback.selectionClick();
      // Refresh the views that show lead state.
      ref.invalidate(farmerDetailProvider(widget.farmerId));
      ref.invalidate(leadHistoryProvider(widget.farmerId));
      ref.read(farmerListProvider.notifier).refresh(isRefresh: true);
      ref.invalidate(myLeadsProvider);
      if (!mounted) return;
      Navigator.of(context).pop();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _formError = e.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Status',
            style: AppTextStyles.bodyMedium.copyWith(color: scheme.onSurface)),
        const SizedBox(height: AppDimens.grid),
        Row(
          children: [
            for (final s in LeadStatus.values) ...[
              Expanded(child: _option(context, s)),
              if (s != LeadStatus.values.last)
                const SizedBox(width: AppDimens.grid),
            ],
          ],
        ),
        const SizedBox(height: AppDimens.grid * 2.5),
        Text('Why are you changing this status? *',
            style: AppTextStyles.bodyMedium.copyWith(color: scheme.onSurface)),
        const SizedBox(height: AppDimens.grid),
        TextField(
          controller: _reason,
          minLines: 2,
          maxLines: 4,
          textCapitalization: TextCapitalization.sentences,
          style: AppTextStyles.body.copyWith(color: scheme.onSurface),
          decoration: InputDecoration(
            hintText: 'At least 10 characters',
            errorText: _reasonError,
          ),
        ),
        if (_needsFollowUp) ...[
          const SizedBox(height: AppDimens.grid * 2),
          Text('Schedule a follow-up',
              style:
                  AppTextStyles.bodyMedium.copyWith(color: scheme.onSurface)),
          const SizedBox(height: AppDimens.grid),
          Row(
            children: [
              Expanded(
                child: _pickerTile(
                  icon: Icons.event_rounded,
                  label: _followUpDate == null
                      ? 'Date'
                      : shortDate(_followUpDate),
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: _followUpDate ??
                          DateTime.now().add(const Duration(days: 1)),
                      firstDate: DateTime.now(),
                      lastDate: DateTime.now().add(const Duration(days: 365)),
                    );
                    if (picked != null) setState(() => _followUpDate = picked);
                  },
                ),
              ),
              const SizedBox(width: AppDimens.grid),
              Expanded(
                child: _pickerTile(
                  icon: Icons.schedule_rounded,
                  label: _followUpTime == null
                      ? 'Time'
                      : _followUpTime!.format(context),
                  onTap: () async {
                    final picked = await showTimePicker(
                        context: context,
                        initialTime: const TimeOfDay(hour: 10, minute: 0));
                    if (picked != null) setState(() => _followUpTime = picked);
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: AppDimens.grid),
          TextField(
            controller: _purpose,
            style: AppTextStyles.body.copyWith(color: scheme.onSurface),
            decoration: const InputDecoration(labelText: 'Purpose (optional)'),
          ),
        ],
        if (_formError != null) ...[
          const SizedBox(height: AppDimens.grid),
          Text(_formError!,
              style: AppTextStyles.caption.copyWith(color: scheme.error)),
        ],
        const SizedBox(height: AppDimens.grid * 2.5),
        AppButton(
          label: 'Save',
          icon: Icons.flag_rounded,
          isLoading: _saving,
          onPressed: _saving ? null : _save,
        ),
        SizedBox(
            height: AppDimens.grid + MediaQuery.of(context).viewInsets.bottom),
      ],
    );
  }

  Widget _option(BuildContext context, LeadStatus status) {
    final color = leadStatusColor(context, status);
    final selected = _selected == status;
    return GestureDetector(
      onTap: () => setState(() => _selected = status),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOutCubic,
        padding: const EdgeInsets.symmetric(vertical: AppDimens.grid * 1.5),
        decoration: BoxDecoration(
          color:
              selected ? color.withValues(alpha: 0.16) : context.appColors.card,
          borderRadius: BorderRadius.circular(AppDimens.cardRadius),
          border: Border.all(
            color: selected
                ? color
                : context.appColors.textSecondary.withValues(alpha: 0.2),
            width: selected ? 1.6 : 1,
          ),
        ),
        child: Column(
          children: [
            Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(height: AppDimens.grid * 0.75),
            Text(status.label,
                style: AppTextStyles.caption.copyWith(
                  color: selected ? color : context.appColors.textSecondary,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                )),
          ],
        ),
      ),
    );
  }

  Widget _pickerTile(
      {required IconData icon,
      required String label,
      required VoidCallback onTap}) {
    final colors = context.appColors;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppDimens.buttonRadius),
      child: Container(
        padding: const EdgeInsets.all(AppDimens.grid * 1.5),
        decoration: BoxDecoration(
          border:
              Border.all(color: colors.textSecondary.withValues(alpha: 0.25)),
          borderRadius: BorderRadius.circular(AppDimens.buttonRadius),
        ),
        child: Row(
          children: [
            Icon(icon, size: 16, color: colors.textSecondary),
            const SizedBox(width: AppDimens.grid * 0.75),
            Flexible(
              child: Text(label,
                  style: AppTextStyles.body
                      .copyWith(color: colors.textSecondary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
      ),
    );
  }
}
