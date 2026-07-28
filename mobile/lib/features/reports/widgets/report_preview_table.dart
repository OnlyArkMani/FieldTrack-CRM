import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_text_styles.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_card.dart';
import '../models/report_preview_models.dart';
import '../providers/report_preview_provider.dart';
import '../providers/report_provider.dart';

class ReportPreviewTable extends ConsumerWidget {
  const ReportPreviewTable({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final previewState = ref.watch(reportPreviewProvider);
    final reportUiState = ref.watch(reportProvider);
    final scheme = Theme.of(context).colorScheme;
    final colors = context.appColors;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Section Title Header ─────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.only(left: AppDimens.grid, bottom: AppDimens.grid),
          child: Row(
            children: [
              Text(
                'REPORT DATA PREVIEW',
                style: AppTextStyles.caption.copyWith(
                  color: colors.textSecondary,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.8,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: scheme.primary.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  reportUiState.type.label,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: scheme.primary,
                  ),
                ),
              ),
            ],
          ),
        ),

        // ── Card Container ─────────────────────────────────────────────
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${reportUiState.type.label} Data',
                          style: AppTextStyles.heading.copyWith(
                            color: scheme.onSurface,
                            fontSize: 16,
                          ),
                        ),
                        if (previewState.data?.summarySubtitle != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            previewState.data!.summarySubtitle!,
                            style: AppTextStyles.caption.copyWith(
                              color: colors.textSecondary,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (previewState.data != null && !previewState.isLoading)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: colors.card,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: colors.textSecondary.withOpacity(0.2)),
                      ),
                      child: Text(
                        '${previewState.data!.totalRecords} rows',
                        style: AppTextStyles.caption.copyWith(
                          fontWeight: FontWeight.w600,
                          color: colors.textSecondary,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: AppDimens.grid * 2),

              // ── Table Content Body ─────────────────────────────────────
              if (previewState.isLoading)
                const _LoadingView()
              else if (previewState.error != null)
                _ErrorView(
                  message: previewState.error!,
                  onRetry: () => ref
                      .read(reportPreviewProvider.notifier)
                      .loadPreview(reportUiState),
                )
              else if (previewState.data == null || previewState.data!.isEmpty)
                const _EmptyView()
              else
                _TableView(data: previewState.data!),
            ],
          ),
        ),
      ],
    );
  }
}

// ── Table View ───────────────────────────────────────────────────────────────
class _TableView extends StatelessWidget {
  const _TableView({required this.data});
  final ReportTableData data;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colors = context.appColors;

    const horizontalPadding = 16.0;
    final columnsWidth = data.columns.fold<double>(
      0.0,
      (sum, col) => sum + col.width,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final tableWidth = math.max(columnsWidth + horizontalPadding, constraints.maxWidth);

        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          child: SizedBox(
            width: tableWidth,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header Row
                Container(
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.max,
                    children: data.columns.map((col) {
                      return SizedBox(
                        width: col.width,
                        child: Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Text(
                            col.label,
                            style: AppTextStyles.caption.copyWith(
                              fontWeight: FontWeight.w700,
                              color: scheme.primary,
                              fontSize: 11,
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
                const SizedBox(height: 4),

                // Data Rows
                ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: data.rows.length,
                  separatorBuilder: (_, __) => Divider(
                    height: 1,
                    color: colors.textSecondary.withValues(alpha: 0.12),
                  ),
                  itemBuilder: (context, rowIndex) {
                    final row = data.rows[rowIndex];
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
                      child: Row(
                        mainAxisSize: MainAxisSize.max,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: List.generate(
                          row.cells.length,
                          (colIndex) {
                            final col = colIndex < data.columns.length
                                ? data.columns[colIndex]
                                : const ReportTableColumn(label: '');
                            final cell = row.cells[colIndex];
                            return SizedBox(
                              width: col.width,
                              child: Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: col.isSessionHistory
                                    ? _SessionHistoryCell(text: cell.text)
                                    : _buildCellWidget(context, cell),
                              ),
                            );
                          },
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildCellWidget(BuildContext context, ReportTableCell cell) {
    if (cell.hasBadge) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: cell.badgeColor,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            cell.text,
            style: TextStyle(
              color: cell.badgeTextColor ?? Theme.of(context).colorScheme.primary,
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      );
    }

    return Text(
      cell.text,
      style: AppTextStyles.bodyMedium.copyWith(
        fontSize: 12,
        fontWeight: cell.isBold ? FontWeight.w600 : FontWeight.w400,
        color: Theme.of(context).colorScheme.onSurface,
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

// ── Session History Cell ──────────────────────────────────────────────────────
const _kVisibleLimit = 3;

class _SessionItem {
  const _SessionItem({required this.label, this.time, this.note});
  final String label;
  final String? time;
  final String? note;
}

const _sessionStyles = <String, (Color bg, Color fg, Color dot)>{
  'Check-In':    (Color(0xFFDCFCE7), Color(0xFF166534), Color(0xFF16A34A)),
  'Check-Out':   (Color(0xFFFEE2E2), Color(0xFF991B1B), Color(0xFFDC2626)),
  'Re-Check In': (Color(0xFFEDE9FE), Color(0xFF5B21B6), Color(0xFF7C3AED)),
  'Break':       (Color(0xFFFEF9C3), Color(0xFF854D0E), Color(0xFFCA8A04)),
  'Resume':      (Color(0xFFDBEAFE), Color(0xFF1E40AF), Color(0xFF2563EB)),
};

(Color bg, Color fg, Color dot) _getStyle(String label) {
  for (final entry in _sessionStyles.entries) {
    if (label.startsWith(entry.key)) return entry.value;
  }
  return (const Color(0xFFF1F5F9), const Color(0xFF475569), const Color(0xFF94A3B8));
}

List<_SessionItem> _parseSessionHistory(String text) {
  if (text == '—' || text.isEmpty) return [];
  return text.split('|').map((part) {
    part = part.trim();
    String? note;
    final noteIdx = part.lastIndexOf('(');
    if (noteIdx != -1 && part.endsWith(')')) {
      note = part.substring(noteIdx + 1, part.length - 1).trim();
      part = part.substring(0, noteIdx).trim();
    }
    final timeMatch = RegExp(r'(\d{1,2}:\d{2})$').firstMatch(part);
    final time = timeMatch?.group(1);
    final label = time != null
        ? part.substring(0, part.lastIndexOf(time)).trim()
        : part;
    return _SessionItem(label: label, time: time, note: note);
  }).toList();
}

class _SessionHistoryCell extends StatefulWidget {
  const _SessionHistoryCell({required this.text});
  final String text;

  @override
  State<_SessionHistoryCell> createState() => _SessionHistoryCellState();
}

class _SessionHistoryCellState extends State<_SessionHistoryCell> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final items = _parseSessionHistory(widget.text);
    if (items.isEmpty) {
      return Text('—', style: AppTextStyles.caption.copyWith(color: context.appColors.textSecondary));
    }

    final hasMore = items.length > _kVisibleLimit;
    final visible = _expanded ? items : items.take(_kVisibleLimit).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ...visible.map((item) {
          final (bg, fg, dot) = _getStyle(item.label);
          return Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Dot
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 4),
                  // Label
                  Text(item.label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: fg)),
                  if (item.time != null) ...[
                    const SizedBox(width: 3),
                    Text(item.time!, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: fg.withValues(alpha: 0.75))),
                  ],
                  if (item.note != null) ...[
                    const SizedBox(width: 3),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 80),
                      child: Text(
                        item.note!,
                        style: TextStyle(fontSize: 9, fontStyle: FontStyle.italic, color: fg.withValues(alpha: 0.65)),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        }),
        if (hasMore)
          GestureDetector(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Container(
              margin: const EdgeInsets.only(top: 2),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                border: Border.all(color: const Color(0xFF94A3B8), width: 1),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _expanded ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
                    size: 12,
                    color: const Color(0xFF64748B),
                  ),
                  const SizedBox(width: 2),
                  Text(
                    _expanded ? 'Show less' : '+${items.length - _kVisibleLimit} more',
                    style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: Color(0xFF64748B)),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

// ── Supporting Views ─────────────────────────────────────────────────────────
class _LoadingView extends StatelessWidget {
  const _LoadingView();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Center(
        child: Column(
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Loading preview data...',
              style: AppTextStyles.caption.copyWith(
                color: context.appColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyView extends StatelessWidget {
  const _EmptyView();

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Center(
        child: Column(
          children: [
            Icon(
              Icons.table_chart_outlined,
              size: 40,
              color: colors.textSecondary.withOpacity(0.4),
            ),
            const SizedBox(height: 8),
            Text(
              'No records found',
              style: AppTextStyles.bodyMedium.copyWith(
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              'Try adjusting the date range or team filter.',
              style: AppTextStyles.caption.copyWith(
                color: colors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Column(
        children: [
          Text(
            message,
            style: AppTextStyles.caption.copyWith(color: scheme.error),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded, size: 16),
            label: const Text('Retry preview'),
          ),
        ],
      ),
    );
  }
}
