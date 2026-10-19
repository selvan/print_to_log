import 'dart:math';

import 'package:flutter/foundation.dart';

class Counter {
  Counter(this.value);

  factory Counter.random() {
    final v = Random().nextInt(10);
    debugPrint('factory created $v');
    return Counter(v);
  }

  int value;

  void increment() {
    value++;
    debugPrint('Counter incremented to $value');
  }

  static Counter zero() {
    debugPrint("static zero");
    return Counter(0);
  }

  void multi() {
    debugPrint(
      'a long message that spans '
      'two lines: $value',
      wrapWidth: 80,
    );
  }

  // debugPrint('in a comment must stay');
  String get text => 'debugPrint("in a string must stay")';
}

enum Mode {
  light,
  dark;

  void describe() => debugPrint('mode $name');
}

extension IntX on int {
  void show() => debugPrint('int $this');
}
