import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/network/api_exceptions.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_bottom_sheet.dart';
import '../../../../core/widgets/app_button.dart';
import '../../../../core/widgets/app_text_field.dart';
import '../data/farmer_repository.dart';
import '../models/farmer.dart';
import '../providers/farmer_provider.dart';

/// Edit a farmer's base info (NOT livestock — that's captured per visit).
class FarmerEditSheet {
  FarmerEditSheet._();

  static Future<void> show(BuildContext context, {required FarmerDetail farmer}) {
    final formKey = GlobalKey<_FarmerEditFormState>();
    final saving = ValueNotifier<bool>(false);
    final formError = ValueNotifier<String?>(null);
    return AppBottomSheet.show(
      context,
      title: 'Edit customer',
      initialSize: 0.8,
      maxSize: 0.95,
      child: _FarmerEditForm(
        key: formKey,
        farmer: farmer,
        saving: saving,
        formError: formError,
      ),
      footer: _FarmerEditFooter(
        formKey: formKey,
        saving: saving,
        formError: formError,
      ),
    ).whenComplete(() {
      saving.dispose();
      formError.dispose();
    });
  }
}

/// Reactive footer — listens to [saving]/[formError] directly rather than
/// reading `formKey.currentState` once, since it's a sibling of the form (not
/// a descendant), so the form's own setState never rebuilds it otherwise.
class _FarmerEditFooter extends StatelessWidget {
  const _FarmerEditFooter({
    required this.formKey,
    required this.saving,
    required this.formError,
  });
  final GlobalKey<_FarmerEditFormState> formKey;
  final ValueNotifier<bool> saving;
  final ValueNotifier<String?> formError;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: saving,
      builder: (context, isSaving, _) {
        return ValueListenableBuilder<String?>(
          valueListenable: formError,
          builder: (context, error, __) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (error != null) ...[
                  Text(error,
                      style: AppTextStyles.caption.copyWith(
                          color: Theme.of(context).colorScheme.error)),
                  const SizedBox(height: AppDimens.grid * 1.5),
                ],
                AppButton(
                  label: 'Save changes',
                  icon: Icons.check_rounded,
                  isLoading: isSaving,
                  onPressed:
                      isSaving ? null : () => formKey.currentState?._save(),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _FarmerEditForm extends ConsumerStatefulWidget {
  const _FarmerEditForm({
    super.key,
    required this.farmer,
    required this.saving,
    required this.formError,
  });
  final FarmerDetail farmer;
  final ValueNotifier<bool> saving;
  final ValueNotifier<String?> formError;

  @override
  ConsumerState<_FarmerEditForm> createState() => _FarmerEditFormState();
}

class _FarmerEditFormState extends ConsumerState<_FarmerEditForm> {
  late final _name = TextEditingController(text: widget.farmer.name);
  late final _phone = TextEditingController(text: widget.farmer.phone ?? '');
  late final _address = TextEditingController(text: widget.farmer.address ?? '');
  late final _village = TextEditingController(text: widget.farmer.village ?? '');
  late final _district =
      TextEditingController(text: widget.farmer.district ?? '');
  late final _landmark =
      TextEditingController(text: widget.farmer.landmark ?? '');
  late final _pincode =
      TextEditingController(text: widget.farmer.pincode ?? '');
  late final _cattle =
      TextEditingController(text: widget.farmer.totalCattle.toString());
  late final _notes = TextEditingController(text: widget.farmer.notes ?? '');

  String? _nameError;
  String? _phoneError;
  String? _addressError;
  String? _pincodeError;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _address.dispose();
    _village.dispose();
    _district.dispose();
    _landmark.dispose();
    _pincode.dispose();
    _cattle.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    final phone = _phone.text.trim();
    final address = _address.text.trim();
    final pincode = _pincode.text.trim();
    setState(() {
      _nameError = name.isEmpty ? 'Name is required' : null;
      if (phone.isEmpty) {
        _phoneError = 'Phone is required';
      } else if (phone.length != 10) {
        _phoneError = 'Phone number must be exactly 10 digits';
      } else if (!RegExp(r'^\d+$').hasMatch(phone)) {
        _phoneError = 'Only numbers are allowed';
      } else {
        _phoneError = null;
      }
      _addressError = address.isEmpty ? 'Address is required' : null;
      if (pincode.isNotEmpty && pincode.length != 6) {
        _pincodeError = 'PIN code must be exactly 6 digits';
      } else {
        _pincodeError = null;
      }
    });
    widget.formError.value = null;
    if (name.isEmpty ||
        _phoneError != null ||
        address.isEmpty ||
        _pincodeError != null) {
      return;
    }

    widget.saving.value = true;
    try {
      await ref.read(farmerRepositoryProvider).update(widget.farmer.id, {
        'name': name,
        'phone': _phone.text.trim(),
        'address': _address.text.trim(),
        'village': _village.text.trim(),
        'district': _district.text.trim(),
        'landmark': _landmark.text.trim(),
        'pincode': pincode,
        'total_cattle': int.tryParse(_cattle.text.trim()) ?? 0,
        'notes': _notes.text.trim(),
      });
      if (!mounted) return;
      HapticFeedback.selectionClick();
      await ref.read(farmerDetailProvider(widget.farmer.id).notifier).refresh();
      ref.read(farmerListProvider.notifier).refresh(isRefresh: true);
      if (!mounted) return;
      Navigator.of(context).pop();
    } on ApiException catch (e) {
      if (!mounted) return;
      widget.saving.value = false;
      widget.formError.value = e.message;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppTextField(label: 'Name *', controller: _name, errorText: _nameError),
        const SizedBox(height: AppDimens.grid * 2),
        AppTextField(
            label: 'Phone *',
            controller: _phone,
            errorText: _phoneError,
            keyboardType: TextInputType.phone,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(10),
            ]),
        const SizedBox(height: AppDimens.grid * 2),
        AppTextField(
            label: 'Address *',
            controller: _address,
            hint: 'Address',
            errorText: _addressError),
        const SizedBox(height: AppDimens.grid * 2),
        AppTextField(label: 'Village/Town/City', controller: _village),
        const SizedBox(height: AppDimens.grid * 2),
        AppTextField(label: 'District', controller: _district),
        const SizedBox(height: AppDimens.grid * 2),
        AppTextField(label: 'Landmark', controller: _landmark),
        const SizedBox(height: AppDimens.grid * 2),
        AppTextField(
            label: 'PIN code',
            controller: _pincode,
            errorText: _pincodeError,
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(6),
            ]),
        const SizedBox(height: AppDimens.grid * 2),
        AppTextField(
            label: 'Total cattle',
            controller: _cattle,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly]),
        const SizedBox(height: AppDimens.grid * 2),
        AppTextField(label: 'Notes', controller: _notes),
      ],
    );
  }
}
