import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/network/api_exceptions.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_button.dart';
import '../../../../core/widgets/app_text_field.dart';
import '../../../../services/village/models/village.dart';
import '../../../../services/village/widgets/village_search_field.dart';
import '../data/farmer_repository.dart';
import '../models/farmer.dart';
import '../providers/farmer_provider.dart';
import '../widgets/add_attendee_sheet.dart';

/// Create-a-farmer form. Farmer Meet collects a list of attendees (added one
/// at a time via a bottom sheet, all sharing this form's venue fields) and
/// saves them in a single backend transaction; every other customer type
/// keeps the single Name/Phone contact fields inline.
/// Submit has a loading state; success navigates to the new farmer's detail
/// screen (or back to the list when several attendees were created at once).
class AddFarmerScreen extends ConsumerStatefulWidget {
  const AddFarmerScreen({super.key});

  @override
  ConsumerState<AddFarmerScreen> createState() => _AddFarmerScreenState();
}

class _AddFarmerScreenState extends ConsumerState<AddFarmerScreen> {
  // Org contact (FPO/VLCC/Retailer/Distributor) — one entity, one contact.
  final _name = TextEditingController();
  final _phone = TextEditingController();

  // Farmer Meet attendees — collected via AddAttendeeSheet, one per farmer.
  final List<AttendeeInput> _attendees = [];

  final _address = TextEditingController();
  final _village = TextEditingController();
  final _district = TextEditingController();
  final _landmark = TextEditingController();
  final _pincode = TextEditingController();
  final _notes = TextEditingController();

  CustomerType _type = CustomerType.farmer;
  bool _submitting = false;
  String? _nameError;
  String? _phoneError;
  String? _addressError;
  String? _pincodeError;
  String? _formError;

  bool get _isFarmerMeet => _type == CustomerType.farmer;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _address.dispose();
    _village.dispose();
    _district.dispose();
    _landmark.dispose();
    _pincode.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _addAttendee() async {
    final result = await AddAttendeeSheet.show(context);
    if (result == null) return;
    setState(() {
      _attendees.add(result);
      _formError = null;
    });
  }

  void _removeAttendee(int index) => setState(() => _attendees.removeAt(index));

  void _onVillageSelected(Village v) => setState(() {
        _village.text = v.villageName;
        _district.text = v.districtName ?? '';
        _address.text = v.formattedAddress;
        _addressError = null;
      });

  Future<void> _submit() async {
    final address = _address.text.trim();
    final pincode = _pincode.text.trim();
    final name = _name.text.trim();
    final phone = _phone.text.trim();

    setState(() {
      _addressError = !_isFarmerMeet && address.isEmpty ? 'Address is required' : null;
      if (pincode.isNotEmpty && pincode.length != 6) {
        _pincodeError = 'PIN code must be exactly 6 digits';
      } else {
        _pincodeError = null;
      }
      if (!_isFarmerMeet) {
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
      }
      _formError = _isFarmerMeet && _attendees.isEmpty
          ? 'Add at least one farmer'
          : null;
    });

    if ((!_isFarmerMeet && address.isEmpty) ||
        _pincodeError != null ||
        (_isFarmerMeet && _attendees.isEmpty) ||
        (!_isFarmerMeet &&
            (name.isEmpty ||
                phone.isEmpty ||
                phone.length != 10 ||
                !RegExp(r'^\d+$').hasMatch(phone)))) {
      return;
    }

    setState(() => _submitting = true);
    try {
      if (_isFarmerMeet) {
        final created = await ref.read(farmerRepositoryProvider).createBatch(
              attendees: _attendees,
              address: address,
              notes: _notes.text.trim(),
            );
        if (!mounted) return;
        HapticFeedback.mediumImpact();
        ref.read(farmerListProvider.notifier).refresh(isRefresh: true);
        if (created.length == 1) {
          context.pushReplacement('/farmer/${created.first.id}');
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Added ${created.length} farmers')),
          );
          context.pop();
        }
      } else {
        final farmer = await ref.read(farmerRepositoryProvider).create(
              name: name,
              customerType: _type,
              phone: phone,
              address: address,
              village: _village.text.trim(),
              district: _district.text.trim(),
              landmark: _landmark.text.trim(),
              pincode: pincode,
              notes: _notes.text.trim(),
            );
        if (!mounted) return;
        HapticFeedback.mediumImpact();
        ref.read(farmerListProvider.notifier).refresh(isRefresh: true);
        context.pushReplacement('/farmer/${farmer.id}');
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _formError = e.message;
      });
    }
  }

  String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    final letters = parts.take(2).map((p) => p.isEmpty ? '' : p[0]).join();
    return letters.toUpperCase();
  }

  Widget _attendeeTile(BuildContext context, int index) {
    final colors = context.appColors;
    final attendee = _attendees[index];
    return Container(
      margin: const EdgeInsets.only(bottom: AppDimens.grid),
      padding: const EdgeInsets.symmetric(
          horizontal: AppDimens.grid * 1.25, vertical: AppDimens.grid),
      decoration: BoxDecoration(
        color: colors.card,
        borderRadius: BorderRadius.circular(AppDimens.cardRadius),
        border: Border.all(color: colors.textSecondary.withValues(alpha: 0.15)),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 15,
            backgroundColor: AppPalette.amber.withValues(alpha: 0.2),
            child: Text(
              _initials(attendee.name),
              style: AppTextStyles.caption.copyWith(
                color: AppPalette.amber,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: AppDimens.grid * 1.25),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(attendee.name,
                    style: AppTextStyles.bodyMedium.copyWith(
                        color: Theme.of(context).colorScheme.onSurface),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                Text('${attendee.phone} · ${attendee.village}',
                    style:
                        AppTextStyles.caption.copyWith(color: colors.textSecondary)),
              ],
            ),
          ),
          IconButton(
            icon: Icon(Icons.close_rounded, size: 18, color: colors.textSecondary),
            visualDensity: VisualDensity.compact,
            tooltip: 'Remove ${attendee.name}',
            onPressed: () => _removeAttendee(index),
          ),
        ],
      ),
    );
  }

  Widget _attendeesSection(BuildContext context) {
    final colors = context.appColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Attendees',
                style: AppTextStyles.bodyMedium.copyWith(
                    color: Theme.of(context).colorScheme.onSurface,
                    fontWeight: FontWeight.w600)),
            if (_attendees.isNotEmpty)
              Text('${_attendees.length} added',
                  style: AppTextStyles.caption
                      .copyWith(color: colors.textSecondary)),
          ],
        ),
        const SizedBox(height: AppDimens.grid),
        if (_attendees.isEmpty)
          Container(
            padding: const EdgeInsets.all(AppDimens.grid * 1.75),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppDimens.cardRadius),
              border: Border.all(
                color: colors.textSecondary.withValues(alpha: 0.25),
                style: BorderStyle.solid,
              ),
            ),
            child: Center(
              child: Text('No farmers added yet',
                  style: AppTextStyles.caption
                      .copyWith(color: colors.textSecondary)),
            ),
          )
        else
          for (var i = 0; i < _attendees.length; i++) _attendeeTile(context, i),
        const SizedBox(height: AppDimens.grid),
        OutlinedButton.icon(
          onPressed: _addAttendee,
          icon: const Icon(Icons.add_rounded, size: 18),
          label: const Text('Add another farmer'),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(44),
            foregroundColor: AppPalette.amber,
            side: BorderSide(color: AppPalette.amber.withValues(alpha: 0.55)),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppDimens.buttonRadius),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Add customer',
            maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppDimens.grid * 2),
          children: [
            Text('Customer type',
                style: AppTextStyles.caption
                    .copyWith(color: colors.textSecondary)),
            const SizedBox(height: AppDimens.grid),
            Stack(
              children: [
                InputDecorator(
                  decoration: InputDecoration(
                    border: OutlineInputBorder(
                      borderRadius:
                          BorderRadius.circular(AppDimens.buttonRadius),
                    ),
                    // Horizontal inset lives on DropdownButton's own `padding`
                    // instead of here — any horizontal contentPadding on this
                    // InputDecorator makes DropdownButton's actual render box
                    // (what Flutter anchors the popup menu to) narrower than
                    // the visible border, so the menu would sit inset from
                    // the field's edges instead of matching it exactly.
                    contentPadding: const EdgeInsets.symmetric(
                      vertical: AppDimens.grid * 0.75,
                    ),
                  ),
                  child: ButtonTheme(
                    alignedDropdown: true,
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<CustomerType>(
                        value: _type,
                        isDense: true,
                        isExpanded: true,
                        padding: const EdgeInsetsDirectional.only(end: 8),
                        style: AppTextStyles.bodyMedium.copyWith(
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                        selectedItemBuilder: (context) {
                          return CustomerType.values.map((t) {
                            return Padding(
                              padding: const EdgeInsets.only(left: 32),
                              child: Text(t.label,
                                  maxLines: 1, overflow: TextOverflow.ellipsis),
                            );
                          }).toList();
                        },
                        items: CustomerType.values
                            .map((t) => DropdownMenuItem(
                                  value: t,
                                  child: Text(t.label,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis),
                                ))
                            .toList(),
                        onChanged: (v) => setState(() {
                          _type = v ?? CustomerType.farmer;
                          _formError = null;
                        }),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 16,
                  top: 0,
                  bottom: 0,
                  child: IgnorePointer(
                    child: Icon(
                      Icons.category_rounded,
                      size: 20,
                      color: colors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppDimens.grid * 2),
            if (_isFarmerMeet)
              _attendeesSection(context)
            else ...[
              AppTextField(
                label: 'Name *',
                controller: _name,
                hint: 'Name',
                errorText: _nameError,
                textInputAction: TextInputAction.next,
                prefixIcon: Icons.person_rounded,
              ),
              const SizedBox(height: AppDimens.grid * 2),
              AppTextField(
                label: 'Phone *',
                controller: _phone,
                hint: 'Mobile number',
                errorText: _phoneError,
                keyboardType: TextInputType.phone,
                textInputAction: TextInputAction.next,
                prefixIcon: Icons.phone_rounded,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(10),
                ],
              ),
            ],
            if (!_isFarmerMeet) ...[
              const SizedBox(height: AppDimens.grid * 2),
              VillageSearchField(
                label: 'Address *',
                controller: _address,
                hint: 'Address',
                errorText: _addressError,
                textInputAction: TextInputAction.next,
                prefixIcon: Icons.location_on_rounded,
                onSelected: _onVillageSelected,
              ),
              const SizedBox(height: AppDimens.grid * 2),
              AppTextField(
                label: 'Village/Town/City',
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
                label: 'Landmark',
                controller: _landmark,
                hint: 'Nearby landmark',
                textInputAction: TextInputAction.next,
                prefixIcon: Icons.push_pin_rounded,
              ),
              const SizedBox(height: AppDimens.grid * 2),
              AppTextField(
                label: 'PIN code',
                controller: _pincode,
                hint: '6-digit postal code',
                errorText: _pincodeError,
                keyboardType: TextInputType.number,
                textInputAction: TextInputAction.next,
                prefixIcon: Icons.markunread_mailbox_rounded,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(6),
                ],
              ),
            ],
            const SizedBox(height: AppDimens.grid * 2),
            AppTextField(
              label: 'Notes',
              controller: _notes,
              hint: 'Anything worth remembering',
              textInputAction: TextInputAction.done,
              prefixIcon: Icons.notes_rounded,
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
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppDimens.grid * 3),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_formError != null) ...[
                Text(
                  _formError!,
                  style: AppTextStyles.caption
                      .copyWith(color: Theme.of(context).colorScheme.error),
                ),
                const SizedBox(height: AppDimens.grid * 1.5),
              ],
              AppButton(
                label:
                    _attendees.length > 1 ? 'Save farmers' : 'Save customer',
                icon: Icons.check_rounded,
                isLoading: _submitting,
                onPressed: _submitting ? null : _submit,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
