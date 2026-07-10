import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_bottom_sheet.dart';
import '../../../../core/widgets/app_button.dart';
import '../../../../core/widgets/app_text_field.dart';

/// One Farmer Meet attendee collected by the sheet below.
typedef AttendeeInput = ({String name, String phone, String village});

/// Bottom sheet to add one Farmer Meet attendee. Pops with the entered
/// (name, phone, village) triple, or null if dismissed without saving.
/// Venue fields (address/district/PIN/...) live on the parent form and are
/// shared by every attendee — village is entered per attendee since
/// attendees at one meet often come from different villages.
class AddAttendeeSheet {
  AddAttendeeSheet._();

  static Future<AttendeeInput?> show(BuildContext context) {
    return AppBottomSheet.show<AttendeeInput>(
      context,
      title: 'Add a farmer',
      initialSize: 0.42,
      maxSize: 0.7,
      child: const _AddAttendeeForm(),
    );
  }
}

class _AddAttendeeForm extends StatefulWidget {
  const _AddAttendeeForm();

  @override
  State<_AddAttendeeForm> createState() => _AddAttendeeFormState();
}

class _AddAttendeeFormState extends State<_AddAttendeeForm> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _village = TextEditingController();
  String? _nameError;
  String? _phoneError;
  String? _villageError;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _village.dispose();
    super.dispose();
  }

  void _confirm() {
    final name = _name.text.trim();
    final phone = _phone.text.trim();
    final village = _village.text.trim();
    setState(() {
      _nameError = name.isEmpty ? 'Name is required' : null;
      _villageError = village.isEmpty ? 'Village is required' : null;
      if (phone.isEmpty) {
        _phoneError = 'Phone is required';
      } else if (phone.length != 10) {
        _phoneError = 'Phone number must be exactly 10 digits';
      } else if (!RegExp(r'^\d+$').hasMatch(phone)) {
        _phoneError = 'Only numbers are allowed';
      } else {
        _phoneError = null;
      }
    });
    if (name.isEmpty || village.isEmpty || _phoneError != null) return;
    Navigator.of(context).pop((name: name, phone: phone, village: village));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Shares the venue address already entered on the form.',
          style: AppTextStyles.caption
              .copyWith(color: context.appColors.textSecondary),
        ),
        const SizedBox(height: AppDimens.grid * 2),
        AppTextField(
          label: 'Name *',
          controller: _name,
          hint: "Farmer's full name",
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
        const SizedBox(height: AppDimens.grid * 2),
        AppTextField(
          label: 'Village *',
          controller: _village,
          hint: "Farmer's village/town/city",
          errorText: _villageError,
          textInputAction: TextInputAction.done,
          prefixIcon: Icons.home_work_rounded,
          onSubmitted: (_) => _confirm(),
        ),
        const SizedBox(height: AppDimens.grid * 2.5),
        AppButton(
          label: 'Add farmer',
          icon: Icons.check_rounded,
          onPressed: _confirm,
        ),
        SizedBox(
            height: AppDimens.grid + MediaQuery.of(context).viewInsets.bottom),
      ],
    );
  }
}
