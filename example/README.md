# Using print_to_log

`print_to_log` can run as a dev dependency of the package you want to migrate,
or as an independent, globally installed tool. Both give the same result.

## As a dev dependency

Add it to the Flutter or Dart package you want to migrate:

```yaml
dev_dependencies:
  print_to_log: ^1.0.0
```

Then, from that package's root:

```bash
flutter pub get                  # or: dart pub get
dart run print_to_log --dry-run  # preview the changes
dart run print_to_log            # migrate, then verify with the analyzer
```

Once the migration is done you can remove `print_to_log` from
`dev_dependencies`.

## As an independent tool

Install it once, then run it on any package without changing its
`pubspec.yaml`:

```bash
dart pub global activate print_to_log
print_to_log --dry-run /path/to/flutter_package
print_to_log /path/to/flutter_package
```

Run from inside the package, `print_to_log` alone migrates the current
directory.

## What changes

A file like

```dart
import 'package:flutter/foundation.dart';

class Counter {
  int value = 0;

  void increment() {
    value++;
    debugPrint('Counter incremented to $value');
  }
}
```

becomes

```dart
import 'package:logging/logging.dart';

class Counter {
  static final log = Logger('Counter');

  int value = 0;

  void increment() {
    value++;
    log.fine(
      () =>
          'Counter incremented to $value',
    );
  }
}
```

and `logging` is added to your `dependencies`.
