import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/shimmer_card.dart';
import '../../../../core/widgets/state_views.dart';
import '../models/farmer.dart';
import '../providers/farmer_provider.dart';
import '../utils.dart';
import '../widgets/lead_status_badge.dart';

/// Farmer directory. Field-facing (employees + supervisors).
/// - debounced search (name/village) + lead-status filter chips
/// - pull-to-refresh, infinite scroll (cursor paging)
/// - shimmer first-load, empty + error states
/// - staggered entrance per card (50ms steps)
class FarmerListScreen extends ConsumerStatefulWidget {
  const FarmerListScreen({super.key});

  @override
  ConsumerState<FarmerListScreen> createState() => _FarmerListScreenState();
}

class _FarmerListScreenState extends ConsumerState<FarmerListScreen> {
  final _scroll = ScrollController();
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 400) {
      ref.read(farmerListProvider.notifier).loadMore();
    }
  }

  void _openAdd() => context.push('/farmer/add');

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(farmerListProvider);
    final notifier = ref.read(farmerListProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        title:
            const Text('Farmers', maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openAdd,
        icon: const Icon(Icons.add_rounded),
        label: const Text('Add Farmer'),
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
            _FilterChips(
              selected: state.leadFilter,
              onSelect: notifier.setLeadFilter,
            ),
            Expanded(child: _body(context, state, notifier)),
          ],
        ),
      ),
    );
  }

  Widget _body(
    BuildContext context,
    FarmerListState state,
    FarmerListNotifier notifier,
  ) {
    if (state.isLoading) return const ShimmerList(count: 6);

    if (state.error != null && state.items.isEmpty) {
      return ErrorStateView(
        message: state.error!,
        onRetry: notifier.refresh,
      );
    }

    if (state.isEmpty) {
      final searching =
          state.search.trim().isNotEmpty || state.leadFilter != null;
      return RefreshIndicator(
        onRefresh: () => notifier.refresh(isRefresh: true),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(height: MediaQuery.of(context).size.height * 0.1),
            EmptyStateView(
              icon: searching
                  ? Icons.search_off_rounded
                  : Icons.agriculture_rounded,
              title: searching ? 'No matches' : 'No farmers yet',
              message: searching
                  ? 'Try a different name, village, or lead filter.'
                  : 'Add your first farmer.',
              actionLabel: searching ? null : 'Add Farmer',
              onAction: searching ? null : _openAdd,
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
        padding: const EdgeInsets.fromLTRB(
          AppDimens.grid * 2,
          AppDimens.grid * 2,
          AppDimens.grid * 2,
          AppDimens.grid * 12, // clear the FAB
        ),
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
          final farmer = state.items[index];
          return StaggeredEntrance(
            index: index,
            child: _FarmerTile(
              farmer: farmer,
              onTap: () => context.push('/farmer/${farmer.id}'),
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
        AppDimens.grid * 0.5,
      ),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        textInputAction: TextInputAction.search,
        style: AppTextStyles.body
            .copyWith(color: Theme.of(context).colorScheme.onSurface),
        decoration: InputDecoration(
          hintText: total > 0 ? 'Search $total farmers' : 'Search farmers',
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

class _FilterChips extends StatelessWidget {
  const _FilterChips({required this.selected, required this.onSelect});

  final LeadStatus? selected;
  final ValueChanged<LeadStatus?> onSelect;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppDimens.grid * 2),
        children: [
          _chip(context, label: 'All', value: null),
          _chip(context, label: 'Hot', value: LeadStatus.hot),
          _chip(context, label: 'Warm', value: LeadStatus.warm),
          _chip(context, label: 'Cold', value: LeadStatus.cold),
        ],
      ),
    );
  }

  Widget _chip(BuildContext context,
      {required String label, required LeadStatus? value}) {
    final colors = context.appColors;
    final isSelected = selected == value;
    final color = value == null
        ? Theme.of(context).colorScheme.onSurface
        : leadStatusColor(context, value);
    return Padding(
      padding: const EdgeInsets.only(right: AppDimens.grid),
      child: GestureDetector(
        onTap: () => onSelect(value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOutCubic,
          padding: const EdgeInsets.symmetric(
            horizontal: AppDimens.grid * 1.75,
            vertical: AppDimens.grid * 0.75,
          ),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: isSelected
                ? color.withValues(alpha: 0.16)
                : colors.card,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: isSelected
                  ? color
                  : colors.textSecondary.withValues(alpha: 0.2),
              width: isSelected ? 1.4 : 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (value != null) ...[
                Container(
                  width: 8,
                  height: 8,
                  decoration:
                      BoxDecoration(color: color, shape: BoxShape.circle),
                ),
                const SizedBox(width: AppDimens.grid * 0.75),
              ],
              Text(
                label,
                style: AppTextStyles.caption.copyWith(
                  color: isSelected ? color : colors.textSecondary,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FarmerTile extends StatelessWidget {
  const _FarmerTile({required this.farmer, required this.onTap});

  final FarmerListItem farmer;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final scheme = Theme.of(context).colorScheme;
    final dimmed = !farmer.isActive;

    return AppCard(
      onTap: onTap,
      child: Opacity(
        opacity: dimmed ? 0.55 : 1,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Hero(
                    tag: 'farmer-name-${farmer.id}',
                    child: Material(
                      type: MaterialType.transparency,
                      child: Text(
                        farmer.name,
                        style: AppTextStyles.bodyMedium
                            .copyWith(color: scheme.onSurface),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: AppDimens.grid),
                LeadStatusBadge(status: farmer.leadStatus),
              ],
            ),
            if (farmer.village != null && farmer.village!.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(
                farmer.village!,
                style:
                    AppTextStyles.caption.copyWith(color: colors.textSecondary),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            const SizedBox(height: AppDimens.grid),
            Row(
              children: [
                Icon(Icons.schedule_rounded,
                    size: 14, color: colors.textSecondary),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    lastVisitedLabel(farmer.lastVisitAt),
                    style: AppTextStyles.caption
                        .copyWith(color: colors.textSecondary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: AppDimens.grid),
                Icon(Icons.pets_rounded, size: 14, color: colors.textSecondary),
                const SizedBox(width: 4),
                Text(
                  '${farmer.totalCattle}',
                  style: AppTextStyles.caption
                      .copyWith(color: colors.textSecondary),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
