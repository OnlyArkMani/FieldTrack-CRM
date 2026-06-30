import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/network/api_exceptions.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_button.dart';
import '../../../../core/widgets/app_text_field.dart';
import '../data/farmer_repository.dart';
import '../providers/farmer_provider.dart';

/// Create-a-farmer form. Name is required; everything else optional.
/// Submit has a loading state; success navigates to the new farmer's detail
/// screen with haptic feedback.
class AddFarmerScreen extends ConsumerStatefulWidget {
  const AddFarmerScreen({super.key});

  @override
  ConsumerState<AddFarmerScreen> createState() => _AddFarmerScreenState();
}

class _AddFarmerScreenState extends ConsumerState<AddFarmerScreen> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _village = TextEditingController();
  final _district = TextEditingController();
  final _address = TextEditingController();
  final _cattle = TextEditingController(text: '0');
  final _notes = TextEditingController();

  bool _submitting = false;
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

  Future<void> _submit() async {
    final name = _name.text.trim();
    setState(() {
      _nameError = name.isEmpty ? 'Name is required' : null;
      _formError = null;
    });
    if (name.isEmpty) return;

    setState(() => _submitting = true);
    try {
      final farmer = await ref.read(farmerRepositoryProvider).create(
            name: name,
            phone: _phone.text.trim(),
            village: _village.text.trim(),
            district: _district.text.trim(),
            address: _address.text.trim(),
            totalCattle: int.tryParse(_cattle.text.trim()) ?? 0,
            notes: _notes.text.trim(),
          );
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      // Refresh the list so the new farmer shows on return.
      ref.read(farmerListProvider.notifier).refresh(isRefresh: true);
      // Replace this form with the new farmer's detail screen.
      context.pushReplacement('/farmer/${farmer.id}');
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _formError = e.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Add Farmer',
            maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppDimens.grid * 2),
          children: [
            AppTextField(
              label: 'Name *',
              controller: _name,
              hint: 'Farmer or vendor name',
              errorText: _nameError,
              textInputAction: TextInputAction.next,
              prefixIcon: Icons.person_rounded,
            ),
            const SizedBox(height: AppDimens.grid * 2),
            AppTextField(
              label: 'Phone',
              controller: _phone,
              hint: 'Mobile number',
              keyboardType: TextInputType.phone,
              textInputAction: TextInputAction.next,
              prefixIcon: Icons.phone_rounded,
            ),
            const SizedBox(height: AppDimens.grid * 2),
            AppTextField(
              label: 'Village',
              controller: _village,
              textInputAction: TextInputAction.next,
              prefixIcon: Icons.home_work_rounded,
            ),
            const SizedBox(height: AppDimens.grid * 2),
            AppTextField(
              label: 'District',
              controller: _district,
              textInputAction: TextInputAction.next,
              prefixIcon: Icons.map_rounded,
            ),
            const SizedBox(height: AppDimens.grid * 2),
            AppTextField(
              label: 'Address',
              controller: _address,
              textInputAction: TextInputAction.next,
              prefixIcon: Icons.location_on_rounded,
            ),
            const SizedBox(height: AppDimens.grid * 2),
            AppTextField(
              label: 'Total cattle',
              controller: _cattle,
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.next,
              prefixIcon: Icons.pets_rounded,
            ),
            const SizedBox(height: AppDimens.grid * 2),
            AppTextField(
              label: 'Notes',
              controller: _notes,
              hint: 'Anything worth remembering',
              textInputAction: TextInputAction.done,
              prefixIcon: Icons.notes_rounded,
            ),
            if (_formError != null) ...[
              const SizedBox(height: AppDimens.grid * 2),
              Text(
                _formError!,
                style: AppTextStyles.caption
                    .copyWith(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: AppDimens.grid * 3),
            AppButton(
              label: 'Save Farmer',
              icon: Icons.check_rounded,
              isLoading: _submitting,
              onPressed: _submitting ? null : _submit,
            ),
            const SizedBox(height: AppDimens.grid),
            Text(
              '* Required',
              style:
                  AppTextStyles.caption.copyWith(color: colors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}
