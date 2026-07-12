import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/needs_attention_repository.dart';
import '../models/needs_attention_item.dart';

/// Every locally-queued row that stopped auto-retrying and needs a human
/// decision. `autoDispose` so the Profile tile's count badge and the full
/// screen both see a fresh read each time they're opened, without needing
/// an explicit refresh button for the common case.
final needsAttentionProvider =
    FutureProvider.autoDispose<List<NeedsAttentionItem>>((ref) {
  return ref.watch(needsAttentionRepositoryProvider).list();
});
