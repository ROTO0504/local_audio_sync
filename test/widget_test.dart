import 'package:flutter_test/flutter_test.dart';

void main() {
  // Widget tests require Opus initialization which involves async FFI loading.
  // App-level smoke tests are covered in integration_test/.
  test('placeholder', () => expect(true, isTrue));
}
