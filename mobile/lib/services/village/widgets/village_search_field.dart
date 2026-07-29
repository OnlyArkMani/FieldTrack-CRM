import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_exceptions.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/theme/app_theme.dart';
import '../data/village_repository.dart';
import '../models/village.dart';

/// Debounced village lookup field. Waits [_debounceDelay] after the user
/// stops typing, then queries [villageRepositoryProvider] and lists matches
/// inline below the field.
///
/// This widget never decides what a selection populates beyond its own text —
/// that's caller policy (farmer vs. org customer types populate differently
/// from the same [Village]) — it only reports the pick via [onSelected].
class VillageSearchField extends ConsumerStatefulWidget {
  const VillageSearchField({
    super.key,
    required this.label,
    required this.controller,
    required this.onSelected,
    this.hint,
    this.errorText,
    this.textInputAction,
    this.prefixIcon = Icons.home_work_rounded,
  });

  final String label;
  final TextEditingController controller;
  final ValueChanged<Village> onSelected;
  final String? hint;
  final String? errorText;
  final TextInputAction? textInputAction;
  final IconData prefixIcon;

  @override
  ConsumerState<VillageSearchField> createState() =>
      _VillageSearchFieldState();
}

class _VillageSearchFieldState extends ConsumerState<VillageSearchField> {
  static const _debounceDelay = Duration(milliseconds: 700);
  static const _minQueryLength = 2;

  final _focusNode = FocusNode();
  Timer? _debounce;
  List<Village> _results = const [];
  bool _loading = false;

  // Bumped on every search; a response only applies if it's still the
  // latest — cheaper than Dio CancelToken plumbing and just as effective
  // against out-of-order responses from overlapping requests.
  int _requestSeq = 0;

  // Set right before a selection assigns widget.controller.text — the
  // TextField's own controller listener fires onChanged for that
  // programmatic change too, so this suppresses the resulting spurious
  // re-search of the just-picked value.
  bool _isSelecting = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _focusNode.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    if (_isSelecting) {
      _isSelecting = false;
      return;
    }
    _debounce?.cancel();
    final query = value.trim();
    if (query.length < _minQueryLength) {
      _requestSeq++; // invalidate any in-flight response
      setState(() {
        _results = const [];
        _loading = false;
      });
      return;
    }
    setState(() => _loading = true);
    _debounce = Timer(_debounceDelay, () => _search(query));
  }

  Future<void> _search(String query) async {
    final seq = ++_requestSeq;
    try {
      final results =
          await ref.read(villageRepositoryProvider).search(query);
      if (!mounted || seq != _requestSeq) return; // superseded by a later one
      setState(() {
        _results = results;
        _loading = false;
      });
    } on ApiException catch (_) {
      if (!mounted || seq != _requestSeq) return;
      // A failed lookup shouldn't block manual typing — just drop suggestions.
      setState(() {
        _results = const [];
        _loading = false;
      });
    }
  }

  void _select(Village village) {
    _debounce?.cancel();
    _requestSeq++;
    _isSelecting = true;
    setState(() => _results = const []);
    widget.onSelected(village);
    _focusNode.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final onSurface = Theme.of(context).colorScheme.onSurface;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          widget.label,
          style: AppTextStyles.bodyMedium.copyWith(color: onSurface),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: AppDimens.grid),
        TextField(
          controller: widget.controller,
          focusNode: _focusNode,
          onChanged: _onChanged,
          textInputAction: widget.textInputAction,
          style: AppTextStyles.body.copyWith(color: onSurface),
          decoration: InputDecoration(
            hintText: widget.hint,
            errorText: widget.errorText,
            errorMaxLines: 2,
            prefixIcon:
                Icon(widget.prefixIcon, size: 20, color: colors.textSecondary),
            suffixIcon: _loading
                ? const Padding(
                    padding: EdgeInsets.all(14),
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppPalette.amber,
                      ),
                    ),
                  )
                : null,
          ),
        ),
        if (_results.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(top: AppDimens.grid),
            constraints: const BoxConstraints(maxHeight: 240),
            decoration: BoxDecoration(
              color: colors.card,
              borderRadius: BorderRadius.circular(AppDimens.cardRadius),
              border:
                  Border.all(color: colors.textSecondary.withValues(alpha: 0.2)),
              boxShadow: AppDimens.shadow(Theme.of(context).brightness),
            ),
            child: ListView.separated(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              itemCount: _results.length,
              separatorBuilder: (_, __) => Divider(
                height: 1,
                color: colors.textSecondary.withValues(alpha: 0.12),
              ),
              itemBuilder: (context, index) {
                final v = _results[index];
                final subtitle = [v.subdistrictName, v.districtName, v.stateName]
                    .where((s) => s != null && s.trim().isNotEmpty)
                    .join(', ');
                return GestureDetector(
                  key: ValueKey(v.villageCode),
                  behavior: HitTestBehavior.opaque,
                  // onTapDown (not onTap): TextField's default onTapOutside
                  // unfocuses on the same pointer-down that hits this tile,
                  // which would otherwise remove this list (if visibility
                  // were focus-driven) before onTap's pointer-up ever fires.
                  // Visibility here is driven by _results only, and firing
                  // the pick on tap-down sidesteps the race entirely.
                  onTapDown: (_) => _select(v),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppDimens.grid * 1.5,
                      vertical: AppDimens.grid * 1.25,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          v.villageName,
                          style:
                              AppTextStyles.bodyMedium.copyWith(color: onSurface),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (subtitle.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            subtitle,
                            style: AppTextStyles.caption
                                .copyWith(color: colors.textSecondary),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}
