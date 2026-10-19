import 'dart:math';

import 'package:flutter/foundation.dart';

mixin Talker {
  void talk() {
    debugPrint('talking');
  }
}

class Nested {
  void outer() {
    void inner() {
      debugPrint('from inner function');
    }

    inner();
  }
}

class MathHelper {
  // Uses dart:math's log(); a `log` logger here would break this call, so the
  // tool must leave this class alone and report it.
  double ln(num x) {
    debugPrint('ln of $x');
    return log(x);
  }
}
