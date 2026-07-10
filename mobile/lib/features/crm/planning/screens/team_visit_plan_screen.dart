import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/state_views.dart';
import '../data/visit_plan_repository.dart';
import '../models/visit_plan.dart';
import '../widgets/plan_item_card.dart';

/// Selected date for the Team Visit Plans screen. Held in a provider rather
/// than local State — some ancestor rebuild (shell/router related) can
/// dispose and recreate this screen's State right as the date picker
/// resolves; a plain `DateTime` field would silently reset to
/// `DateTime.now()` when that happens, making date changes look like they
/// never took effect.
final _teamVisitPlanDateProvider =
    StateProvider<DateTime>((ref) => DateTime.now());

/// Manager-only: their team's visit plans for a chosen date. Scope is
/// auto-filtered to the caller's team on the backend (VisitPlanService.
/// get_team_plans) — the route itself is also gated to managers, see
/// app_router.dart.
class TeamVisitPlanScreen extends ConsumerStatefulWidget {
  const TeamVisitPlanScreen({super.key});

  @override
  ConsumerState<TeamVisitPlanScreen> createState() =>
      _TeamVisitPlanScreenState();
}

class _TeamVisitPlanScreenState extends ConsumerState<TeamVisitPlanScreen> {
  late Future<TeamPlans> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<TeamPlans> _load() => ref
      .read(visitPlanRepositoryProvider)
      .teamPlans(ref.read(_teamVisitPlanDateProvider));

  void _reload() => setState(() => _future = _load());

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: ref.read(_teamVisitPlanDateProvider),
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now().add(const Duration(days: 30)),
    );
    if (picked != null) {
      ref.read(_teamVisitPlanDateProvider.notifier).state = picked;
      _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final date = ref.watch(_teamVisitPlanDateProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Team Visit Plans',
            maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(AppDimens.grid * 2),
              child: InkWell(
                onTap: _pickDate,
                borderRadius: BorderRadius.circular(AppDimens.buttonRadius),
                child: Container(
                  padding: const EdgeInsets.all(AppDimens.grid * 1.5),
                  decoration: BoxDecoration(
                    border: Border.all(
                        color: colors.textSecondary.withValues(alpha: 0.25)),
                    borderRadius: BorderRadius.circular(AppDimens.buttonRadius),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.event_rounded,
                          size: 18, color: colors.textSecondary),
                      const SizedBox(width: AppDimens.grid),
                      Text(DateFormat('EEEE, d MMM yyyy').format(date),
                          style: AppTextStyles.bodyMedium.copyWith(
                              color: Theme.of(context).colorScheme.onSurface)),
                      const Spacer(),
                      Text('Change',
                          style: AppTextStyles.caption.copyWith(
                              color: Theme.of(context).colorScheme.primary)),
                    ],
                  ),
                ),
              ),
            ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: () async => _reload(),
                child: FutureBuilder<TeamPlans>(
                  future: _future,
                  builder: (context, snap) {
                    if (snap.connectionState == ConnectionState.waiting) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (snap.hasError) {
                      return ErrorStateView(
                        message: 'Could not load team visit plans.',
                        onRetry: _reload,
                      );
                    }
                    final employees =
                        snap.data?.employees ?? const <TeamPlanEmployee>[];
                    if (employees.isEmpty) {
                      return ListView(children: const [
                        SizedBox(height: 80),
                        Center(child: Text('No team members found.')),
                      ]);
                    }
                    return ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.symmetric(
                          horizontal: AppDimens.grid * 2),
                      itemCount: employees.length,
                      itemBuilder: (_, i) =>
                          _EmployeePlanTile(employee: employees[i]),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmployeePlanTile extends StatelessWidget {
  const _EmployeePlanTile({required this.employee});
  final TeamPlanEmployee employee;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppDimens.grid * 1.5),
      child: AppCard(
        child: InkWell(
          onTap: () => _open(context),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(employee.employeeName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.bodyMedium.copyWith(
                            color: Theme.of(context).colorScheme.onSurface)),
                    const SizedBox(height: 2),
                    Text(
                      employee.teamName != null
                          ? '${employee.teamName} · ${employee.visitsPlanned} visits planned'
                          : '${employee.visitsPlanned} visits planned',
                      style: AppTextStyles.caption
                          .copyWith(color: colors.textSecondary),
                    ),
                  ],
                ),
              ),
              _StatusChip(status: employee.status),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _open(BuildContext context) async {
    if (employee.items.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No plan submitted yet.')),
      );
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.appColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _EmployeePlanSheet(employee: employee),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});
  final String status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colors = context.appColors;
    final (Color c, String label) = switch (status) {
      'SUBMITTED' => (colors.statusActive, 'Submitted'),
      'IN_PROGRESS' => (scheme.primary, 'In progress'),
      'COMPLETED' => (colors.statusActive, 'Completed'),
      'DRAFT' => (scheme.primary, 'Draft'),
      _ => (scheme.error, 'Not submitted'),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(label,
          style: AppTextStyles.caption
              .copyWith(color: c, fontWeight: FontWeight.w700)),
    );
  }
}

class _EmployeePlanSheet extends StatelessWidget {
  const _EmployeePlanSheet({required this.employee});
  final TeamPlanEmployee employee;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.92,
      builder: (context, controller) => ListView(
        controller: controller,
        padding: const EdgeInsets.all(AppDimens.grid * 2),
        children: [
          Text(employee.employeeName,
              style: AppTextStyles.heading
                  .copyWith(color: Theme.of(context).colorScheme.onSurface)),
          if (employee.teamName != null)
            Text(employee.teamName!,
                style: AppTextStyles.caption
                    .copyWith(color: colors.textSecondary)),
          const SizedBox(height: AppDimens.grid * 2),
          for (var i = 0; i < employee.items.length; i++)
            PlanItemCard(item: employee.items[i], index: i),
          const SizedBox(height: AppDimens.grid * 2),
        ],
      ),
    );
  }
}
