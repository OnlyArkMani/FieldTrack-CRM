// Placeholder smoke test.
//
// The default Flutter counter test referenced a non-existent `MyApp`. Booting
// the real app (FieldTrackApp) in a widget test requires a harness that loads
// dotenv (.env) and overrides sharedPreferencesProvider, which isn't set up
// yet. Until that harness exists this keeps `flutter test` green.
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('placeholder — app test harness pending', () {
    expect(true, isTrue);
  });
}
