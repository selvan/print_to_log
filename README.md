# print_to_log

Migrates `debugPrint(...)` and `print(...)` calls in any Flutter/Dart package to
[`package:logging`](https://pub.dev/packages/logging).

For each Dart file that calls `debugPrint` or `print`, the tool:

- adds `logging: ^1.3.0` to `pubspec.yaml` under `dependencies` (if missing)
- adds `import 'package:logging/logging.dart';` (if missing)
- reuses a logger that already exists, under any name. A logger is a variable or
  getter typed `Logger` or initialized with `Logger(...)` / `Logger.detached(...)`.
  For each call it picks, in order:
  1. the enclosing class's own logger (an instance logger only from instance
     code, not from static methods, factory constructors or initializers)
  2. the file's top-level logger (for a `part` file, its library's)
  3. a new logger:
     - inside a class, mixin, enum or extension: `static final log = Logger('ClassName');`
       (class-scoped, so static methods and factory constructors can use it too)
     - for top-level code: `final _log = Logger('<file name without extension>');`.
       It is private so it is not exported and cannot clash with other files'
       loggers or with `dart:math`'s `log`. For a `part` file it goes in the
       library file, since parts share one namespace.
- replaces each call:

  ```dart
  debugPrint('Counter incremented to $value');
  ```
  becomes
  ```dart
  log.fine(
    () =>
        'Counter incremented to $value',
  );
  ```

Then it runs `pub get` and `dart analyze`, removes imports that became unused
(usually `package:flutter/foundation.dart`), and fails if the migration
introduced any new analyzer error, warning or lint compared to the baseline.

## Usage

The tool can be used in two ways: as a dev dependency of the package you
want to migrate, or as an independent, globally installed command. Both run
the same tool and accept the same options.

### As a dev dependency

Add it to the package you want to migrate:

```yaml
dev_dependencies:
  print_to_log: ^1.0.0
```

Then run it from that package's root (it migrates the current directory):

```bash
flutter pub get                  # or: dart pub get
dart run print_to_log --dry-run  # preview
dart run print_to_log
```

Once migrated, you can remove `print_to_log` from `dev_dependencies` again.

### As an independent tool

Install it once and run it on any package, without changing that package's
`pubspec.yaml`:

```bash
dart pub global activate print_to_log
print_to_log /path/to/flutter_package
```

From inside the package, `print_to_log` alone migrates the current directory.
To install from a local checkout instead of pub.dev:

```bash
dart pub global activate --source path /path/to/print_to_log
```

The global install resolves its own dependencies, so use it if adding the dev
dependency makes `pub get` report a version conflict on `analyzer` (for
example with an older `build_runner`).

### Options

| Option | Effect |
| --- | --- |
| `-n`, `--dry-run` | Report what would change; write nothing. |
| `--no-verify` | Skip pub get / analyzer checks and unused import cleanup. |
| `--no-print` | Convert only `debugPrint`, leaving `print` alone (e.g. for command-line tools whose output is `print`). |
| `--format` | Run `dart format` on changed files. The newer "tall" style may collapse `log.fine(...)` onto one line. |
| `--test` | Run `flutter test` / `dart test` afterwards. |

Exit code is non-zero when the analyzer reports new issues or tests fail.
Commit or stash your work first so the changes are easy to review. Note that
recent Flutter versions' `flutter pub get` (run by the verify step) may add an
`analyzer: exclude: build/**` entry to `analysis_options.yaml`.

## Left unchanged (reported under "Not migrated automatically")

- Classes that call a function named `log`, such as `log(x)` from `dart:math`:
  a class-level `log` logger would shadow it. Top-level code is unaffected,
  since it uses `_log`.
- Classes that need a new logger but already have a non-Logger member named `log`,
  and files that need one but already have a non-Logger top-level `_log`.
- `print(...)` where `print` could be user-defined: a class with its own `print`
  member, or a file that declares a `print` function, variable or parameter.
  A `print` method inherited from a superclass can't be detected, so review
  `print` changes in such classes.
- `debugPrint` or `print` used as a value, e.g. `.forEach(print)`.
- Calls on objects, e.g. `buffer.print(...)`, are never touched.
- Nested packages such as `example/`: run the tool on them separately.
- Generated files (`*.g.dart`, `*.freezed.dart`, `*.mocks.dart`, `*.gr.dart`).

## Seeing the logs

`log.fine` is below `Logger.root`'s default level (`INFO`), so enable it in
your app, for example:

```dart
Logger.root.level = Level.ALL;
Logger.root.onRecord.listen((r) => debugPrint('${r.loggerName}: ${r.message}'));
```

## Development

```bash
dart test        # unit tests
dart analyze
dart run print_to_log fixtures/sample_pkg --dry-run
```

`fixtures/sample_pkg` (no logging yet) and `fixtures/partially_migrated_pkg`
(existing loggers to reuse) are sample Flutter packages covering the cases above.
Run the tool on a copy of them, not on the fixtures themselves.
