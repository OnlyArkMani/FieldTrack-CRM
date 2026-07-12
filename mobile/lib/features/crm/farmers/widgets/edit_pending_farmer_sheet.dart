import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_bottom_sheet.dart';
import '../../../../core/widgets/app_button.dart';
import '../../../../core/widgets/app_text_field.dart';
import '../../../../local_db/database_helper.dart';
import '../data/farmer_repository.dart';

/// Edit-and-resubmit for a `pending_farmers` row stuck in `needs_attention`
/// (a 422 the server won't auto-retry) — the Needs Attention screen's entry
/// point into `FarmerRepository.updatePending()`, which already existed but
/// had no UI pointing at it. Covers the fields the server actually
/// validates (name/phone/village/district/address/pincode); resubmitting
/// flips the row back to pending via `updatePendingFarmerPayload`.
class EditPendingFarmerSheet {
  EditPendingFarmerSheet._();

  static Future<bool> show(BuildContext context, {required String localId}) async {
    final result = await AppBottomSheet.show<bool>(
      context,
      title: 'Edit customer',
      initialSize: 0.75,
      maxSize: 0.95,
      child: _EditPendingFarmerForm(localId: localId),
    );
    return result ?? false;
  }
}

class _EditPendingFarmerForm extends ConsumerStatefulWidget {
  const _EditPendingFarmerForm({required this.localId});
  final String localId;

  @override
  ConsumerState<_EditPendingFarmerForm> createState() => _EditPendingFarmerFormState();
}

class _EditPendingFarmerFormState extends ConsumerState<_EditPendingFarmerForm> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _village = TextEditingController();
  final _district = TextEditingController();
  final _address = TextEditingController();
  final _pincode = TextEditingController();

  bool _loading = true;
  bool _saving = false;
  String? _formError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final row = await DatabaseHelper.instance.getPendingFarmer(widget.localId);
    if (!mounted) return;
    if (row == null) {
      setState(() {
        _loading = false;
        _formError = 'This change no longer exists — it may have synced already.';
      });
      return;
    }
    final payload = jsonDecode(row.payloadJson) as Map<String, dynamic>;
    _name.text = (payload['name'] as String?) ?? '';
    _phone.text = (payload['phone'] as String?) ?? '';
    _village.text = (payload['village'] as String?) ?? '';
    _district.text = (payload['district'] as String?) ?? '';
    _address.text = (payload['address'] as String?) ?? '';
    _pincode.text = (payload['pincode'] as String?) ?? '';
    setState(() => _loading = false);
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _village.dispose();
    _district.dispose();
    _address.dispose();
    _pincode.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _formError = 'Name is required');
      return;
    }
    setState(() {
      _saving = true;
      _formError = null;
    });
    try {
      final updated = await ref.read(farmerRepositoryProvider).updatePending(
        widget.localId,
        {
          'name': name,
          'phone': _phone.text.trim(),
          'village': _village.text.trim(),
          'district': _district.text.trim(),
          'address': _address.text.trim(),
          'pincode': _pincode.text.trim(),
        },
      );
      if (!mounted) return;
      if (updated == null) {
        setState(() {
          _saving = false;
          _formError = 'This change no longer exists — it may have synced already.';
        });
        return;
      }
      HapticFeedback.mediumImpact();
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _formError = 'Could not save — try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    if (_loading) {
      return const SizedBox(
        height: 120,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return SingleChildScrollView(
      physics: const ClampingScrollPhysics(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Fix the field the server rejected, then resubmit.',
            style: AppTextStyles.caption.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: AppDimens.grid * 2),
          AppTextField(label: 'Name *', controller: _name, prefixIcon: Icons.person_rounded),
          const SizedBox(height: AppDimens.grid * 1.5),
          AppTextField(
            label: 'Phone',
            controller: _phone,
            keyboardType: TextInputType.phone,
            prefixIcon: Icons.phone_rounded,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(10),
            ],
          ),
          const SizedBox(height: AppDimens.grid * 1.5),
          AppTextField(
              label: 'Village/Town/City', controller: _village, prefixIcon: Icons.home_work_rounded),
          const SizedBox(height: AppDimens.grid * 1.5),
          AppTextField(label: 'District', controller: _district, prefixIcon: Icons.map_rounded),
          const SizedBox(height: AppDimens.grid * 1.5),
          AppTextField(
              label: 'Address', controller: _address, prefixIcon: Icons.location_on_rounded),
          const SizedBox(height: AppDimens.grid * 1.5),
          AppTextField(
            label: 'PIN code',
            controller: _pincode,
            keyboardType: TextInputType.number,
            prefixIcon: Icons.markunread_mailbox_rounded,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(6),
            ],
          ),
          if (_formError != null) ...[
            const SizedBox(height: AppDimens.grid),
            Text(_formError!,
                style: AppTextStyles.caption
                    .copyWith(color: Theme.of(context).colorScheme.error)),
          ],
          const SizedBox(height: AppDimens.grid * 2.5),
          AppButton(
            label: 'Save and resubmit',
            icon: Icons.check_rounded,
            isLoading: _saving,
            onPressed: _saving ? null : _save,
          ),
          SizedBox(height: AppDimens.grid + MediaQuery.of(context).viewInsets.bottom),
        ],
      ),
    );
  }
}
