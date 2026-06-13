import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_text_styles.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_bottom_sheet.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_text_field.dart';
import '../../auth/models/user.dart';
import '../../employees/data/employee_repository.dart';
import '../providers/team_provider.dart';

/// Candidate supervisors for the assign-supervisor picker: active employees
/// whose role is SUPERVISOR or ADMIN. First page (≤100) covers this product's
/// scale without pagination.
final _supervisorCandidatesProvider = FutureProvider.autoDispose((ref) async {
  final page = await ref.watch(employeeRepositoryProvider).list(limit: 100);
  return page.items
      .where((e) =>
          e.isActive &&
          (e.role == UserRole.supervisor || e.role == UserRole.admin))
      .toList();
});

Future<bool> showCreateTeamSheet(BuildContext context) async {
  final result = await AppBottomSheet.show<bool>(
    context,
    title: 'New team',
    initialSize: 0.72,
    maxSize: 0.95,
    child: const _CreateTeamForm(),
  );
  return result ?? false;
}

class _CreateTeamForm extends ConsumerStatefulWidget {
  const _CreateTeamForm();

  @override
  ConsumerState<_CreateTeamForm> createState() => _CreateTeamFormState();
}

class _CreateTeamFormState extends ConsumerState<_CreateTeamForm> {
  final _name = TextEditingController();
  final _description = TextEditingController();
  int? _supervisorId;

  bool _saving = false;
  String? _error;
  String? _nameError;

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    setState(() {
      _nameError = name.length < 2 ? 'Name must be at least 2 characters' : null;
      _error = null;
    });
    if (_nameError != null) return;

    setState(() => _saving = true);
    final err = await ref.read(teamListProvider.notifier).create(
          name: name,
          description: _description.text.trim(),
          supervisorId: _supervisorId,
        );
    if (!mounted) return;
    if (err == null) {
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _error = err;
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final candidates = ref.watch(_supervisorCandidatesProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppTextField(
          label: 'Team name',
          controller: _name,
          hint: 'e.g. North Field Crew',
          errorText: _nameError,
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: AppDimens.grid * 2),
        AppTextField(
          label: 'Description',
          controller: _description,
          hint: 'Optional',
          textInputAction: TextInputAction.done,
        ),
        const SizedBox(height: AppDimens.grid * 2),
        Text('Supervisor',
            style: AppTextStyles.bodyMedium
                .copyWith(color: Theme.of(context).colorScheme.onSurface)),
        const SizedBox(height: AppDimens.grid),
        candidates.when(
          loading: () => const Padding(
            padding: EdgeInsets.symmetric(vertical: AppDimens.grid),
            child: LinearProgressIndicator(minHeight: 2),
          ),
          error: (_, __) => Text(
            'Could not load supervisors',
            style: AppTextStyles.caption
                .copyWith(color: context.appColors.textSecondary),
          ),
          data: (list) => DropdownButtonFormField<int?>(
            value: _supervisorId,
            isExpanded: true,
            decoration: const InputDecoration(),
            items: [
              const DropdownMenuItem<int?>(
                  value: null, child: Text('No supervisor')),
              ...list.map(
                (e) => DropdownMenuItem<int?>(
                  value: e.id,
                  child: Text('${e.name} (${e.role.label})',
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              ),
            ],
            onChanged:
                _saving ? null : (v) => setState(() => _supervisorId = v),
          ),
        ),
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
          label: 'Create team',
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
