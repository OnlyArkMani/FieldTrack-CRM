import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_text_styles.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_bottom_sheet.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_text_field.dart';
import '../../../core/network/api_exceptions.dart';
import '../../auth/models/user.dart';
import '../../auth/providers/auth_provider.dart';
import '../../teams/providers/team_provider.dart';
import '../data/employee_repository.dart';
import '../models/employee.dart';
import '../providers/employee_provider.dart';

/// Edit an employee's profile. Role reassignment is admin-only (the control is
/// hidden for supervisors). On success, invalidates the detail + list so both
/// reflect the change.
Future<bool> showEmployeeEditSheet(BuildContext context, Employee employee) async {
  final result = await AppBottomSheet.show<bool>(
    context,
    title: 'Edit ${employee.name}',
    initialSize: 0.78,
    maxSize: 0.95,
    child: _EmployeeEditForm(employee: employee),
  );
  return result ?? false;
}

class _EmployeeEditForm extends ConsumerStatefulWidget {
  const _EmployeeEditForm({required this.employee});
  final Employee employee;

  @override
  ConsumerState<_EmployeeEditForm> createState() => _EmployeeEditFormState();
}

class _EmployeeEditFormState extends ConsumerState<_EmployeeEditForm> {
  late final TextEditingController _name =
      TextEditingController(text: widget.employee.name);
  late final TextEditingController _phone =
      TextEditingController(text: widget.employee.phone ?? '');
  late UserRole _role = widget.employee.role;
  late int? _teamId = widget.employee.teamId;

  bool _saving = false;
  String? _error;
  String? _nameError;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  bool get _isAdmin =>
      ref.read(authProvider).user?.role == UserRole.admin;

  Future<void> _save() async {
    final name = _name.text.trim();
    setState(() {
      _nameError = name.length < 2 ? 'Name must be at least 2 characters' : null;
      _error = null;
    });
    if (_nameError != null) return;

    setState(() => _saving = true);
    final changes = <String, dynamic>{
      'name': name,
      'phone': _phone.text.trim().isEmpty ? null : _phone.text.trim(),
      'team_id': _teamId,
      if (_isAdmin) 'role': _role.wire,
    };
    try {
      await ref.read(employeeRepositoryProvider).update(widget.employee.id, changes);
      ref.invalidate(employeeDetailProvider(widget.employee.id));
      ref.read(employeeListProvider.notifier).refresh();
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final teamsState = ref.watch(teamListProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppTextField(
          label: 'Full name',
          controller: _name,
          errorText: _nameError,
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: AppDimens.grid * 2),
        AppTextField(
          label: 'Phone',
          controller: _phone,
          hint: 'Optional',
          keyboardType: TextInputType.phone,
        ),
        const SizedBox(height: AppDimens.grid * 2),

        // Team assignment
        Text('Team',
            style: AppTextStyles.bodyMedium
                .copyWith(color: Theme.of(context).colorScheme.onSurface)),
        const SizedBox(height: AppDimens.grid),
        DropdownButtonFormField<int?>(
          value: _teamId,
          isExpanded: true,
          decoration: const InputDecoration(),
          items: [
            const DropdownMenuItem<int?>(value: null, child: Text('No team')),
            ...teamsState.teams.map(
              (t) => DropdownMenuItem<int?>(
                value: t.id,
                child: Text(t.name,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            ),
          ],
          onChanged: _saving ? null : (v) => setState(() => _teamId = v),
        ),

        if (_isAdmin) ...[
          const SizedBox(height: AppDimens.grid * 2),
          Text('Role',
              style: AppTextStyles.bodyMedium
                  .copyWith(color: Theme.of(context).colorScheme.onSurface)),
          const SizedBox(height: AppDimens.grid),
          DropdownButtonFormField<UserRole>(
            value: _role,
            isExpanded: true,
            decoration: const InputDecoration(),
            items: UserRole.values
                .map((r) => DropdownMenuItem(value: r, child: Text(r.label)))
                .toList(),
            onChanged: _saving ? null : (v) => setState(() => _role = v ?? _role),
          ),
        ],

        if (_error != null) ...[
          const SizedBox(height: AppDimens.grid * 2),
          Text(
            _error!,
            style: AppTextStyles.caption
                .copyWith(color: Theme.of(context).colorScheme.error),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        ],

        const SizedBox(height: AppDimens.grid * 3),
        AppButton(
          label: 'Save changes',
          isLoading: _saving,
          onPressed: _saving ? null : _save,
        ),
        const SizedBox(height: AppDimens.grid),
        AppButton(
          label: 'Cancel',
          variant: AppButtonVariant.secondary,
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
        ),
        SizedBox(height: MediaQuery.of(context).viewInsets.bottom),
      ],
    );
  }
}
