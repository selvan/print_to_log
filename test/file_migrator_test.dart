import 'package:print_to_log/print_to_log.dart';
import 'package:test/test.dart';

FileMigration migrate(String source, [String fileName = 'my_file']) =>
    migrateSource(source, fileName: fileName);

void main() {
  test('rewrites a call inside a class and declares a class logger', () {
    final result = migrate('''
import 'package:flutter/foundation.dart';

class Foo {
  void bar(int x) {
    debugPrint('x is \$x');
  }
}
''');
    expect(result.source, '''
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

class Foo {
  static final log = Logger('Foo');

  void bar(int x) {
    log.fine(
      () =>
          'x is \$x',
    );
  }
}
''');
    expect(result.replaced, 1);
    expect(result.loggersAdded, ['Foo']);
    expect(result.importAdded, isTrue);
  });

  test('uses the file name for top-level code', () {
    final result = migrate('''
import 'package:flutter/foundation.dart';

void main() {
  debugPrint("hello");
}
''', 'app_main');
    expect(result.source, '''
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

final _log = Logger('app_main');

void main() {
  _log.fine(
    () =>
        "hello",
  );
}
''');
  });

  test('declares one logger per class and leaves comments and strings', () {
    final result = migrate('''
class A {
  static void s() => debugPrint('static');
  void i() => debugPrint('instance');
  // debugPrint('comment');
  final t = "debugPrint('string')";
}
''');
    expect(RegExp(r"Logger\('A'\)").allMatches(result.source), hasLength(1));
    expect(result.replaced, 2);
    expect(result.source, contains("// debugPrint('comment');"));
    expect(result.source, contains("\"debugPrint('string')\""));
  });

  test('supports mixins, enums and extensions', () {
    final result = migrate('''
mixin M {
  void a() => debugPrint('m');
}

enum E {
  one;

  void a() => debugPrint('e');
}

extension X on int {
  void a() => debugPrint('x');
}
''');
    expect(result.loggersAdded, ['M', 'E', 'X']);
    expect(result.source, contains("one;\n  static final log = Logger('E');"));
  });

  test('drops wrapWidth and keeps multi-line messages', () {
    final result = migrate('''
class A {
  void a() {
    debugPrint(
      'one '
      'two',
      wrapWidth: 80,
    );
  }
}
''');
    expect(result.source, isNot(contains('wrapWidth')));
    expect(result.source, contains("          'one '\n          'two',"));
  });

  test('keeps multi-line string literals verbatim', () {
    final result = migrate("""
void a() {
  debugPrint('''
first
  second''');
}
""");
    expect(result.source, contains("'''\nfirst\n  second''',"));
  });

  test('adds braces around an unbraced if body', () {
    final result = migrate('''
void a(bool b) {
  if (b) debugPrint('yes');
}
''', 'a');
    expect(result.source, contains('''
  if (b) {
    _log.fine(
      () =>
          'yes',
    );
  }
'''));
  });

  test('reuses existing logger and import', () {
    const source = '''
import 'package:logging/logging.dart';

class A {
  static final log = Logger('A');

  void a() => debugPrint('a');
}
''';
    final result = migrate(source);
    expect(result.loggersAdded, isEmpty);
    expect(result.importAdded, isFalse);
    expect(RegExp('Logger').allMatches(result.source), hasLength(1));
  });

  test('top-level _log does not clash with dart:math log', () {
    final result = migrate('''
import 'dart:math';

double f(num x) {
  debugPrint('f');
  return log(x);
}
''');
    expect(result.replaced, 1);
    expect(result.source, contains('_log.fine('));
    expect(result.source, contains('return log(x);'));
  });

  test('reuses an existing public top-level log', () {
    final result = migrate('''
final log = Logger('x');

void f() => debugPrint('f');
''');
    expect(result.loggersAdded, isEmpty);
    expect(result.source, contains('=> log.fine('));
  });

  test('skips classes that call a log() function', () {
    final result = migrate('''
import 'dart:math';

class A {
  double f(num x) {
    debugPrint('f');
    return log(x);
  }
}
''');
    expect(result.changed, isFalse);
    expect(result.warnings.single, contains('calls a function named `log`'));
  });

  test('handles prefixed calls and reports tear-offs', () {
    final result = migrate('''
import 'package:flutter/foundation.dart' as f;

void a() {
  f.debugPrint('prefixed');
  [1].map((e) => '\$e').forEach(f.debugPrint);
}
''');
    expect(result.replaced, 1);
    expect(result.warnings.single, contains('used as a value'));
  });

  test('sorts the import among package imports', () {
    final result = migrate('''
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';

import 'local.dart';

void a() => debugPrint('a');
''');
    expect(
        result.source,
        contains("import 'package:flutter/foundation.dart';\n"
            "import 'package:logging/logging.dart';\n"
            "import 'package:provider/provider.dart';"));
  });

  test('part files report their library instead of importing', () {
    final result = migrate('''
part of '../lib.dart';

void a() => debugPrint('a');
''');
    expect(result.importAdded, isFalse);
    expect(result.partOfUri, '../lib.dart');
    expect(result.needsLibraryLogger, isTrue);
    expect(result.source, isNot(contains('import')));
    expect(result.source, isNot(contains('Logger(')));
  });

  test('prepareLibrary adds import and top-level logger once', () {
    const source = "part 'src/a.dart';\n\nvoid main() {}\n";
    final updated = prepareLibrary(source, logger: true, fileName: 'lib')!;
    expect(
        updated,
        "import 'package:logging/logging.dart';\n\n"
        "part 'src/a.dart';\n\n"
        "final _log = Logger('lib');\n\n"
        'void main() {}\n');
    expect(prepareLibrary(updated, logger: true, fileName: 'lib'), isNull);
  });

  test('is idempotent', () {
    final once = migrate('class A { void a() => debugPrint("a"); }').source;
    expect(migrate(once).changed, isFalse);
  });

  group('reuses existing loggers', () {
    test('a class logger with any name', () {
      final result = migrate('''
class A {
  static final _logger = Logger('A');

  void a() => debugPrint('a');
}
''');
      expect(result.loggersAdded, isEmpty);
      expect(result.source, contains('=> _logger.fine('));
    });

    test('a typed or getter class logger', () {
      final typed = migrate('''
class A {
  static late final Logger logger;
  void a() => print('a');
}
''');
      expect(typed.source, contains('=> logger.fine('));

      final getter = migrate('''
class A {
  Logger get logger => Logger('A');
  void a() => print('a');
}
''');
      expect(getter.source, contains('=> logger.fine('));
    });

    test('the file logger for classes without one', () {
      final result = migrate('''
final _logger = Logger('file');

class A {
  void a() => debugPrint('a');
}

class B {
  static final log = Logger('B');
  void b() => debugPrint('b');
}

void f() => debugPrint('f');
''');
      expect(result.loggersAdded, isEmpty);
      expect(result.source, contains("void a() => _logger.fine("));
      expect(result.source, contains("void b() => log.fine("));
      expect(result.source, contains("void f() => _logger.fine("));
    });

    test('an instance logger only from instance code', () {
      final result = migrate('''
class A {
  final logger = Logger('A');

  void a() => debugPrint('instance');
  static void s() => debugPrint('static');
  factory A.make() {
    debugPrint('factory');
    return A();
  }
  A();
}
''');
      expect(result.source, contains("void a() => logger.fine("));
      expect(result.source, contains("static void s() => log.fine("));
      expect(result.source, contains("static final log = Logger('A');"));
      expect(RegExp(r'Logger\(').allMatches(result.source), hasLength(2));
      expect(result.source,
          contains("    log.fine(\n      () =>\n          'factory',"));
    });

    test('an instance logger falls back to the file logger in static code', () {
      final result = migrate('''
final _log = Logger('file');

class A {
  final logger = Logger('A');
  static void s() => debugPrint('static');
}
''');
      expect(result.loggersAdded, isEmpty);
      expect(result.source, contains("static void s() => _log.fine("));
    });

    test('the library logger of a part file', () {
      final result = migrateSource('''
part of 'lib.dart';

void f() => debugPrint('f');
''', fileName: 'part', libraryLogger: '_logger');
      expect(result.needsLibraryLogger, isFalse);
      expect(result.source, contains("void f() => _logger.fine("));
    });

    test('does not treat a non-Logger `_log` as a logger', () {
      final result = migrate('''
final _log = <String>[];

void f() => debugPrint('f');
''');
      expect(result.changed, isFalse);
      expect(result.warnings.single, contains('not a Logger'));
    });

    test('findTopLevelLoggerIn finds any name', () {
      expect(findTopLevelLoggerIn("final appLog = Logger.detached('x');"),
          'appLog');
      expect(findTopLevelLoggerIn('final x = 1;'), isNull);
    });
  });

  group('print', () {
    test('converts print alongside debugPrint, sharing one logger', () {
      final result = migrate('''
class A {
  void a(Object o) {
    print(o);
    debugPrint('d');
  }
}
''');
      expect(result.replaced, 2);
      expect(result.loggersAdded, ['A']);
      expect(result.source, contains('() =>\n          o,'));
      expect(result.source, isNot(contains('print(')));
    });

    test('is skipped with convertPrint: false', () {
      final result = migrateSource("void a() { print('x'); }",
          fileName: 'a', convertPrint: false);
      expect(result.changed, isFalse);
    });

    test('leaves method calls on objects alone', () {
      const source = "void a(dynamic p) { p.print('x'); p?.print; }";
      expect(migrate(source).changed, isFalse);
      expect(migrate(source).warnings, isEmpty);
    });

    test('skips classes with their own print method', () {
      final result = migrate('''
class Printer {
  void print(String s) {}
  void a() => print('mine');
}
''');
      expect(result.changed, isFalse);
      expect(result.warnings.single, contains('user-defined `print`'));
    });

    test('skips files that declare print elsewhere', () {
      final result = migrate('''
void run(void Function(String) print) {
  print('callback');
}
''');
      expect(result.changed, isFalse);
    });

    test('reports print tear-offs', () {
      final result = migrate("void a() { [1].forEach(print); }");
      expect(result.warnings.single, contains('print used as a value'));
    });
  });

  group('removeUnusedImports', () {
    test('removes a whole import', () {
      const source = "import 'a.dart';\nimport 'b.dart';\n";
      expect(removeUnusedImports(source, [(code: 'unused_import', offset: 7)]),
          "import 'b.dart';\n");
    });

    test('removes a single shown name', () {
      const source = "import 'f.dart' show debugPrint, kDebugMode;\n";
      final offset = source.indexOf('debugPrint');
      expect(
          removeUnusedImports(
              source, [(code: 'unused_shown_name', offset: offset)]),
          "import 'f.dart' show kDebugMode;\n");
    });
  });

  group('addLoggingDependency', () {
    test('adds under dependencies preserving content', () {
      const pubspec = 'name: x\n'
          'dependencies:\n'
          '  flutter:\n'
          '    sdk: flutter # keep\n';
      final updated = addLoggingDependency(pubspec)!;
      expect(updated, contains('# keep'));
      expect(updated, contains('logging: ^1.3.0'));
    });

    test('returns null when already present', () {
      expect(
          addLoggingDependency('name: x\ndependencies:\n  logging: ^1.2.0\n'),
          isNull);
    });

    test('creates dependencies section when missing', () {
      expect(addLoggingDependency('name: x\n'), contains('logging: ^1.3.0'));
    });
  });
}
