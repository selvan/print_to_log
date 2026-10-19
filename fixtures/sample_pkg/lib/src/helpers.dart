import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;

void helper() {
  if (kDebugMode) debugPrint('helper called');
  [1, 2].forEach((i) => debugPrint('item $i'));
}
