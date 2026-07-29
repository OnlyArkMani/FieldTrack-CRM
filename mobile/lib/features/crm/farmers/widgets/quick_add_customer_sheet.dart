import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/network/api_exceptions.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_bottom_sheet.dart';
import '../../../../core/widgets/app_button.dart';
import '../../../../core/widgets/app_text_field.dart';
import '../../../../services/village/widgets/village_search_field.dart';
import '../data/farmer_repository.dart';
import '../models/farmer.dart';
import '../providers/farmer_provider.dart';

/// Minimal customer-creation sheet used from inline flows (e.g. Add Visit's
/// farmer search) — customer type + name + phone + address, all required.
/// Saves through the exact same `FarmerRepository.create()` used by the full
/// Add Customer screen, so there's one save path, not a second
/// implementation of "create a customer".
class QuickAddCustomerSheet {
  QuickAddCustomerSheet._();

  static Future<FarmerListItem?> show(BuildContext context) {
    final formKey = GlobalKey<_QuickAddCustomerFormState>();
    final saving = ValueNotifier<bool>(false);
    final formError = ValueNotifier<String?>(null);
    return AppBottomSheet.show<FarmerListItem>(
      context,
      title: 'Add customer',
      initialSize: 0.65,
      maxSize: 0.9,
      child: _QuickAddCustomerForm(
        key: formKey,
        saving: saving,
        formError: formError,
      ),
      footer: _QuickAddCustomerFooter(
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
/// reading `formKey.currentState` once, since it's a sibling of the form
/// (not a descendant), so the form's own setState never rebuilds it
/// otherwise.
class _QuickAddCustomerFooter extends StatelessWidget {
  const _QuickAddCustomerFooter({
    required this.formKey,
    required this.saving,
    required this.formError,
  });
  final GlobalKey<_QuickAddCustomerFormState> formKey;
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
                  label: 'Save customer',
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

class _QuickAddCustomerForm extends ConsumerStatefulWidget {
  const _QuickAddCustomerForm({
    super.key,
    required this.saving,
    required this.formError,
  });
  final ValueNotifier<bool> saving;
  final ValueNotifier<String?> formError;

  @override
  ConsumerState<_QuickAddCustomerForm> createState() =>
      _QuickAddCustomerFormState();
}

class _QuickAddCustomerFormState extends ConsumerState<_QuickAddCustomerForm> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _address = TextEditingController();

  CustomerType _type = CustomerType.farmer;
  String? _nameError;
  String? _phoneError;
  String? _addressError;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _address.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    final phone = _phone.text.trim();
    final address = _address.text.trim();
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
    });
    widget.formError.value = null;
    if (name.isEmpty || _phoneError != null || address.isEmpty) return;

    widget.saving.value = true;
    try {
      final farmer = await ref.read(farmerRepositoryProvider).create(
            name: name,
            customerType: _type,
            phone: phone,
            address: address,
          );
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      ref.read(farmerListProvider.notifier).refresh(isRefresh: true);
      Navigator.of(context).pop(
        FarmerListItem(
          id: farmer.id,
          name: farmer.name,
          customerType: farmer.customerType,
          phone: farmer.phone,
          village: farmer.village,
          district: farmer.district,
          totalCattle: farmer.totalCattle,
          isActive: farmer.isActive,
          teamId: farmer.teamId,
          teamName: farmer.teamName,
          leadStatus: farmer.currentLead?.status,
          lastVisitAt: farmer.recentVisits.isNotEmpty
              ? farmer.recentVisits.first.checkInAt
              : null,
          createdAt: farmer.createdAt,
          localId: farmer.localId,
          syncStatus: farmer.syncStatus,
        ),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      widget.saving.value = false;
      widget.formError.value = e.message;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Customer type',
            style:
                AppTextStyles.caption.copyWith(color: colors.textSecondary)),
        const SizedBox(height: AppDimens.grid),
        InputDecorator(
          // No overrides — inherits the app's InputDecorationTheme (fill,
          // padding, border) so this matches the AppTextFields below exactly.
          decoration: const InputDecoration(),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<CustomerType>(
              value: _type,
              isExpanded: true,
              isDense: true,
              style: AppTextStyles.body
                  .copyWith(color: Theme.of(context).colorScheme.onSurface),
              items: CustomerType.values
                  .map((t) => DropdownMenuItem(
                        value: t,
                        child: Text(t.label,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                      ))
                  .toList(),
              onChanged: (v) =>
                  setState(() => _type = v ?? CustomerType.farmer),
            ),
          ),
        ),
        const SizedBox(height: AppDimens.grid * 2),
        AppTextField(
          label: 'Name *',
          controller: _name,
          errorText: _nameError,
          textInputAction: TextInputAction.next,
          prefixIcon: Icons.person_rounded,
        ),
        const SizedBox(height: AppDimens.grid * 2),
        AppTextField(
          label: 'Phone *',
          controller: _phone,
          errorText: _phoneError,
          keyboardType: TextInputType.phone,
          textInputAction: TextInputAction.next,
          prefixIcon: Icons.phone_rounded,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(10),
          ],
        ),
        const SizedBox(height: AppDimens.grid * 2),
        VillageSearchField(
          label: 'Address *',
          controller: _address,
          hint: 'Address',
          errorText: _addressError,
          textInputAction: TextInputAction.done,
          prefixIcon: Icons.location_on_rounded,
          onSelected: (v) => setState(() {
            _address.text = v.formattedAddress;
            _addressError = null;
          }),
        ),
      ],
    );
  }
}
