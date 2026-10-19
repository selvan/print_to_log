import 'package:yaml/yaml.dart';
import 'package:yaml_edit/yaml_edit.dart';

const loggingConstraint = '^1.3.0';

/// Adds `logging: ^1.3.0` under `dependencies` in [pubspec].
///
/// Returns the updated pubspec, or null when `logging` is already a regular
/// dependency. A `logging` entry in `dev_dependencies` is moved to
/// `dependencies`, since the migrated code lives in the library.
String? addLoggingDependency(String pubspec) {
  final doc = loadYaml(pubspec);
  final deps = doc is YamlMap ? doc['dependencies'] : null;
  if (deps is YamlMap && deps.containsKey('logging')) return null;

  final editor = YamlEditor(pubspec);
  final devDeps = doc is YamlMap ? doc['dev_dependencies'] : null;
  if (devDeps is YamlMap && devDeps.containsKey('logging')) {
    editor.remove(['dev_dependencies', 'logging']);
  }
  if (deps is YamlMap) {
    editor.update(['dependencies', 'logging'], loggingConstraint);
  } else {
    editor.update(['dependencies'], {'logging': loggingConstraint});
  }
  return editor.toString();
}
