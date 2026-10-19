import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sample_pkg/sample_pkg.dart';

void main() {
  test('increment', () {
    final c = Counter(1)..increment();
    expect(c.value, 2);
    debugPrint('test done');
  });
}
