import 'package:flutter/material.dart';

/// Data model for a single cell in the report table preview.
class ReportTableCell {
  const ReportTableCell(
    this.text, {
    this.badgeColor,
    this.badgeTextColor,
    this.isBold = false,
    this.alignment = Alignment.centerLeft,
  });

  final String text;
  final Color? badgeColor;
  final Color? badgeTextColor;
  final bool isBold;
  final Alignment alignment;

  bool get hasBadge => badgeColor != null;
}

/// Data model for a table row in the report preview.
class ReportTableRow {
  const ReportTableRow({
    required this.id,
    required this.cells,
  });

  final String id;
  final List<ReportTableCell> cells;
}

/// Data model for a column header in the report preview.
class ReportTableColumn {
  const ReportTableColumn({
    required this.label,
    this.width = 120.0,
    this.alignment = Alignment.centerLeft,
    this.isSessionHistory = false,
  });

  final String label;
  final double width;
  final Alignment alignment;
  final bool isSessionHistory;
}

/// Complete dataset returned for the tabular report preview.
class ReportTableData {
  const ReportTableData({
    required this.columns,
    required this.rows,
    this.totalRecords = 0,
    this.summarySubtitle,
  });

  final List<ReportTableColumn> columns;
  final List<ReportTableRow> rows;
  final int totalRecords;
  final String? summarySubtitle;

  bool get isEmpty => rows.isEmpty;
}
