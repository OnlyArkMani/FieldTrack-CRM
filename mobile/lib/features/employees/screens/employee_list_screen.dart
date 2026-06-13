import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_text_styles.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/shimmer_card.dart';
import '../../../core/widgets/state_views.dart';
import '../models/employee.dart';
import '../providers/employee_provider.dart';
import '../widgets/employee_avatar.dart';
import '../widgets/pulsing_status_dot.dart';

/// Team directory with live status. Supervisor/admin facing.
/// - debounced search (300ms, in the notifier)
/// - pull-to-refresh, infinite scroll (cursor paging)
/// - shimmer first-load, empty + error states
/// - 30s lifecycle-aware live-status polling while this screen is on top
class EmployeeListScreen extends ConsumerStatefulWidget {
  const EmployeeListScreen({super.key});

  @override
  ConsumerState<EmployeeListScreen> createState() => _EmployeeListScreenState();
}

class _EmployeeListScreenState extends ConsumerState<EmployeeListScreen> {
  final _scroll = ScrollController();
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    // Start lifecycle-aware live polling for as long as this screen is alive.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(liveStatusPollerProvider).attach();
    });
  }

  @override
  void dispose() {
    ref.read(liveStatusPollerProvider).detach();
    _scroll.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scroll.position.pixels >=
        _scroll.position.maxScrollExtent - 400) {
      ref.read(employeeListProvider.notifier).loadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(employeeListProvider);
    final notifier = ref.read(employeeListProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Team', maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: SafeArea(
        child: Column(
          children: [
            _SearchBar(
              controller: _searchController,
              onChanged: notifier.setSearch,
              onClear: () {
                _searchController.clear();
                notifier.setSearch('');
              },
              total: state.total,
            ),
            Expanded(child: _body(context, state, notifier)),
          ],
        ),
      ),
    );
  }

  Widget _body(
    BuildContext context,
    EmployeeListState state,
    EmployeeNotifier notifier,
  ) {
    if (state.isLoading) return const ShimmerList(count: 6);

    if (state.error != null && state.items.isEmpty) {
      return ErrorStateView(
        message: state.error!,
        onRetry: () => notifier.refresh(),
      );
    }

    if (state.isEmpty) {
      final searching = state.search.trim().isNotEmpty;
      return RefreshIndicator(
        onRefresh: () => notifier.refresh(isRefresh: true),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(height: MediaQuery.of(context).size.height * 0.12),
            EmptyStateView(
              icon: searching
                  ? Icons.search_off_rounded
                  : Icons.groups_2_rounded,
              title: searching ? 'No matches' : 'No employees yet',
              message: searching
                  ? 'No one matches "${state.search.trim()}". Try a different name or email.'
                  : 'Employees added by an admin will appear here.',
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () => notifier.refresh(isRefresh: true),
      child: ListView.separated(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(AppDimens.grid * 2),
        itemCount: state.items.length + (state.hasMore ? 1 : 0),
        separatorBuilder: (_, __) =>
            const SizedBox(height: AppDimens.grid * 1.5),
        itemBuilder: (context, index) {
          if (index >= state.items.length) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: AppDimens.grid * 2),
              child: Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2.2),
                ),
              ),
            );
          }
          final employee = state.items[index];
          return StaggeredEntrance(
            index: index,
            child: _EmployeeTile(
              employee: employee,
              onTap: () => context.push('/employee/${employee.id}'),
            ),
          );
        },
      ),
    );
  }
}

class _SearchBar extends StatelessWidget {
  const _SearchBar({
    required this.controller,
    required this.onChanged,
    required this.onClear,
    required this.total,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;
  final int total;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppDimens.grid * 2,
        AppDimens.grid,
        AppDimens.grid * 2,
        AppDimens.grid,
      ),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        textInputAction: TextInputAction.search,
        style: AppTextStyles.body
            .copyWith(color: Theme.of(context).colorScheme.onSurface),
        decoration: InputDecoration(
          hintText: total > 0 ? 'Search $total employees' : 'Search employees',
          prefixIcon:
              Icon(Icons.search_rounded, size: 20, color: colors.textSecondary),
          suffixIcon: ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (context, value, _) => value.text.isEmpty
                ? const SizedBox.shrink()
                : IconButton(
                    icon: Icon(Icons.close_rounded,
                        size: 18, color: colors.textSecondary),
                    onPressed: onClear,
                  ),
          ),
        ),
      ),
    );
  }
}

class _EmployeeTile extends StatelessWidget {
  const _EmployeeTile({required this.employee, required this.onTap});

  final Employee employee;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final scheme = Theme.of(context).colorScheme;
    final dimmed = !employee.isActive;

    return AppCard(
      onTap: onTap,
      child: Opacity(
        opacity: dimmed ? 0.55 : 1,
        child: Row(
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                EmployeeAvatar(
                  initials: employee.initials,
                  photoUrl: employee.profilePhotoUrl,
                  heroTag: 'emp-avatar-${employee.id}',
                ),
                Positioned(
                  right: -2,
                  bottom: -2,
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      color: colors.card,
                      shape: BoxShape.circle,
                    ),
                    child: PulsingStatusDot(status: employee.status),
                  ),
                ),
              ],
            ),
            const SizedBox(width: AppDimens.grid * 2),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          employee.name,
                          style: AppTextStyles.bodyMedium
                              .copyWith(color: scheme.onSurface),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: AppDimens.grid),
                      RoleBadge(label: employee.role.label),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    employee.email,
                    style: AppTextStyles.caption
                        .copyWith(color: colors.textSecondary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppDimens.grid),
            Icon(Icons.chevron_right_rounded,
                size: 20, color: colors.textSecondary),
          ],
        ),
      ),
    );
  }
}
