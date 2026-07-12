/// A `pending_*` row that has permanently stopped auto-retrying
/// (`sync_status = 3`, one of `DatabaseHelper`'s `*StatusNeedsAttention`
/// constants) — the server rejected it (422) and it needs a human decision:
/// retry as-is, or discard the change entirely.
enum NeedsAttentionKind { farmer, visit, visitPlan, leaveRequest, planItemAction }

class NeedsAttentionItem {
  const NeedsAttentionItem({
    required this.kind,
    required this.key,
    required this.title,
    this.subtitle,
    required this.error,
    required this.createdAt,
  });

  final NeedsAttentionKind kind;

  /// The row's primary key in its own `pending_*` table — `local_id` for
  /// farmers/visits, `plan_date` for visit plans, `leave_date` for leave
  /// requests. Opaque to the UI; only used to call back into
  /// [NeedsAttentionRepository.retry]/[NeedsAttentionRepository.discard].
  final String key;

  final String title;
  final String? subtitle;
  final String error;
  final DateTime createdAt;
}
