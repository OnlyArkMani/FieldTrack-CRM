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
    return AppBottomSheet.show(
      context,
      title: 'Edit farmer',
      initialSize: 0.8,
      maxSize: 0.95,
      child: _FarmerEditForm(farmer: farmer),
    );
  }
}

class _FarmerEditForm extends ConsumerStatefulWidget {
  const _FarmerEditForm({required this.farmer});
  final FarmerDetail farmer;

  @override
  ConsumerState<_FarmerEditForm> createState() => _FarmerEditFormState();
}

class _FarmerEditFormState extends ConsumerState<_FarmerEditForm> {
  late final _name = TextEditingController(text: widget.farmer.name);
  late final _phone = TextEditingController(text: widget.farmer.phone ?? '');
  late final _village = TextEditingController(text: widget.farmer.village ?? '');
  late final _district =
      TextEditingController(text: widget.farmer.district ?? '');
  late final _address = TextEditingController(text: widget.farmer.address ?? '');
  late final _cattle =
      TextEditingController(text: widget.farmer.totalCattle.toString());
  late final _notes = TextEditingController(text: widget.farmer.notes ?? '');

  bool _saving = false;
  String? _nameError;
  String? _formError;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _village.dispose();
    _district.dispose();
    _address.dispose();
    _cattle.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    setState(() {
      _nameError = name.isEmpty ? 'Name is required' : null;
      _formError = null;
    });
    if (name.isEmpty) return;

    setState(() => _saving = true);
    try {
      await ref.read(farmerRepositoryProvider).update(widget.farmer.id, {
        'name': name,
        'phone': _phone.text.trim(),
        'village': _village.text.trim(),
        'district': _district.text.trim(),
        'address': _address.text.trim(),
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
      setState(() {
        _saving = false;
        _formError = e.message;
      });
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
            label: 'Phone',
            controller: _phone,
            keyboardType: TextInputType.phone),
        const SizedBox(height: AppDimens.grid * 2),
        AppTextField(label: 'Village', controller: _village),
        const SizedBox(height: AppDimens.grid * 2),
        AppTextField(label: 'District', controller: _district),
        const SizedBox(height: AppDimens.grid * 2),
        AppTextField(label: 'Address', controller: _address),
        const SizedBox(height: AppDimens.grid * 2),
        AppTextField(
            label: 'Total cattle',
            controller: _cattle,
            keyboardType: TextInputType.number),
        const SizedBox(height: AppDimens.grid * 2),
        AppTextField(label: 'Notes', controller: _notes),
        if (_formError != null) ...[
          const SizedBox(height: AppDimens.grid),
          Text(_formError!,
              style: AppTextStyles.caption
                  .copyWith(color: Theme.of(context).colorScheme.error)),
        ],
        const SizedBox(height: AppDimens.grid * 2.5),
        AppButton(
          label: 'Save changes',
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
