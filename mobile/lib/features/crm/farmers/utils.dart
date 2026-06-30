/// Small presentation helpers shared across the farmer screens.
library;

/// Coarse relative time, e.g. "3 days ago", "just now", "2 weeks ago".
String timeAgo(DateTime? when, {String never = 'Never'}) {
  if (when == null) return never;
  final now = DateTime.now();
  final diff = now.difference(when);
  if (diff.isNegative) return 'just now';
  if (diff.inSeconds < 60) return 'just now';
  if (diff.inMinutes < 60) {
    final m = diff.inMinutes;
    return '$m min${m == 1 ? '' : 's'} ago';
  }
  if (diff.inHours < 24) {
    final h = diff.inHours;
    return '$h hour${h == 1 ? '' : 's'} ago';
  }
  if (diff.inDays < 7) {
    final d = diff.inDays;
    return d == 1 ? 'yesterday' : '$d days ago';
  }
  if (diff.inDays < 30) {
    final w = (diff.inDays / 7).floor();
    return '$w week${w == 1 ? '' : 's'} ago';
  }
  if (diff.inDays < 365) {
    final mo = (diff.inDays / 30).floor();
    return '$mo month${mo == 1 ? '' : 's'} ago';
  }
  final y = (diff.inDays / 365).floor();
  return '$y year${y == 1 ? '' : 's'} ago';
}

/// "Last visited: 3 days ago" / "Never visited".
String lastVisitedLabel(DateTime? when) =>
    when == null ? 'Never visited' : 'Last visited: ${timeAgo(when)}';

/// Short date like "29 Jun 2026".
String shortDate(DateTime? d) {
  if (d == null) return '—';
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return '${d.day} ${months[d.month - 1]} ${d.year}';
}

/// Rupee amount, no decimals when whole. Null -> dash.
String money(num? v) {
  if (v == null) return '—';
  final whole = v == v.truncateToDouble();
  return '₹${whole ? v.toInt().toString() : v.toStringAsFixed(2)}';
}
