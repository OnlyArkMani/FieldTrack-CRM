// Validates the offline-vs-real-error split on the Vet requests dashboard: a
// NoConnectionException/TimeoutException with nothing cached must render a
// calm empty state, never the "Something went wrong" error page (the bug
// from the reported screenshot).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fieldtrack_mobile/core/network/api_exceptions.dart';
import 'package:fieldtrack_mobile/core/theme/app_theme.dart';
import 'package:fieldtrack_mobile/features/crm/vet/data/vet_repository.dart';
import 'package:fieldtrack_mobile/features/crm/vet/screens/vet_dashboard_screen.dart';

Future<void> _pump(WidgetTester tester, Object error) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        vetRequestsProvider.overrideWith(
          (ref, filter) async => throw error,
        ),
      ],
      child: MaterialApp(theme: AppTheme.light, home: const VetDashboardScreen()),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets(
      'shows a friendly offline empty state, not an error page, on NoConnectionException',
      (tester) async {
    await _pump(tester, const NoConnectionException());

    expect(find.text('No vet requests saved offline yet'), findsOneWidget);
    expect(find.text('Something went wrong'), findsNothing);
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets('shows a friendly offline empty state on TimeoutException',
      (tester) async {
    await _pump(tester, const TimeoutException());

    expect(find.text('No vet requests saved offline yet'), findsOneWidget);
    expect(find.text('Something went wrong'), findsNothing);
  });

  testWidgets('still shows the real error page + Retry for a genuine error',
      (tester) async {
    await _pump(tester, const ServerException());

    expect(find.text('Something went wrong'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('No vet requests saved offline yet'), findsNothing);
  });
}
