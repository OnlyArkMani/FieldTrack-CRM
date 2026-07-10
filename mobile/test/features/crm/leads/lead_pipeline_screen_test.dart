// Validates the offline-vs-real-error split on the Lead pipeline screen:
// a NoConnectionException/TimeoutException with nothing cached must render
// a calm empty state, never the "Something went wrong" error page (the bug
// from the reported screenshot).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fieldtrack_mobile/core/network/api_exceptions.dart';
import 'package:fieldtrack_mobile/core/theme/app_theme.dart';
import 'package:fieldtrack_mobile/features/crm/leads/data/lead_repository.dart';
import 'package:fieldtrack_mobile/features/crm/leads/models/lead.dart';
import 'package:fieldtrack_mobile/features/crm/leads/screens/lead_pipeline_screen.dart';

// Extends the real notifier (rather than AutoDisposeAsyncNotifier directly)
// so build() can be overridden without touching authProvider/leadRepositoryProvider
// at all — the override must match MyLeadsNotifier's type to satisfy
// myLeadsProvider.overrideWith.
class _ThrowingLeadsNotifier extends MyLeadsNotifier {
  _ThrowingLeadsNotifier(this._error);
  final Object _error;

  @override
  Future<List<LeadItem>> build() async => throw _error;
}

Future<void> _pump(WidgetTester tester, Object error) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        myLeadsProvider.overrideWith(() => _ThrowingLeadsNotifier(error)),
      ],
      child: MaterialApp(theme: AppTheme.light, home: const LeadPipelineScreen()),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets(
      'shows a friendly offline empty state, not an error page, on NoConnectionException',
      (tester) async {
    await _pump(tester, const NoConnectionException());

    expect(find.text('No leads saved offline yet'), findsOneWidget);
    expect(find.text('Something went wrong'), findsNothing);
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets('shows a friendly offline empty state on TimeoutException',
      (tester) async {
    await _pump(tester, const TimeoutException());

    expect(find.text('No leads saved offline yet'), findsOneWidget);
    expect(find.text('Something went wrong'), findsNothing);
  });

  testWidgets('still shows the real error page + Retry for a genuine error',
      (tester) async {
    await _pump(tester, const ServerException());

    expect(find.text('Something went wrong'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('No leads saved offline yet'), findsNothing);
  });
}
