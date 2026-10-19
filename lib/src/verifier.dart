import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// One analyzer diagnostic from `dart analyze --format=json`.
class Diagnostic {
  Diagnostic({
    required this.code,
    required this.severity,
    required this.file,
    required this.line,
    required this.offset,
    required this.message,
  });

  final String code;
  final String severity;
  final String file;
  final int line;
  final int offset;
  final String message;

  /// Identity that survives line shifts, used to diff before/after runs.
  String get key => '$file|$code|$message';

  @override
  String toString() =>
      '${severity.toLowerCase()} - $file:$line - $message ($code)';
}

/// Runs pub / analyzer / formatter / test commands for one package.
class Verifier {
  Verifier(this.packageDir)
      : isFlutter = _dependsOnFlutter(File(p.join(packageDir, 'pubspec.yaml')));

  final String packageDir;
  final bool isFlutter;

  String get _pubTool => isFlutter ? 'flutter' : 'dart';

  Future<void> pubGet() async {
    final result = await _run(_pubTool, ['pub', 'get']);
    if (result.exitCode != 0) {
      throw VerifyException('$_pubTool pub get failed:\n${result.stderr}');
    }
  }

  Future<List<Diagnostic>> analyze() async {
    final result = await _run('dart', ['analyze', '--format=json', '.']);
    final out = result.stdout as String;
    final start = out.indexOf('{');
    if (start < 0) {
      if (result.exitCode == 0) return [];
      throw VerifyException('dart analyze failed:\n$out\n${result.stderr}');
    }
    final json = jsonDecode(out.substring(start)) as Map<String, dynamic>;
    return [
      for (final d in json['diagnostics'] as List)
        Diagnostic(
          code: d['code'] as String,
          severity: d['severity'] as String,
          file: p.relative(d['location']['file'] as String, from: packageDir),
          line: d['location']['range']['start']['line'] as int,
          offset: d['location']['range']['start']['offset'] as int,
          message: d['problemMessage'] as String,
        ),
    ];
  }

  Future<void> format(Iterable<String> files) async {
    if (files.isEmpty) return;
    final result = await _run('dart', ['format', ...files]);
    if (result.exitCode != 0) {
      throw VerifyException('dart format failed:\n${result.stderr}');
    }
  }

  Future<bool> test() async {
    if (!Directory(p.join(packageDir, 'test')).existsSync()) return true;
    final result = await _run(_pubTool, ['test']);
    stdout.write(result.stdout);
    stderr.write(result.stderr);
    return result.exitCode == 0;
  }

  Future<ProcessResult> _run(String exe, List<String> args) =>
      Process.run(exe, args, workingDirectory: packageDir);

  static bool _dependsOnFlutter(File pubspec) {
    final doc = loadYaml(pubspec.readAsStringSync());
    if (doc is! YamlMap) return false;
    final deps = doc['dependencies'];
    return deps is YamlMap && deps.containsKey('flutter');
  }
}

/// Diagnostics present in [after] but not in [before] (multiset difference).
List<Diagnostic> newDiagnostics(
    List<Diagnostic> before, List<Diagnostic> after) {
  final counts = <String, int>{};
  for (final d in before) {
    counts[d.key] = (counts[d.key] ?? 0) + 1;
  }
  final added = <Diagnostic>[];
  for (final d in after) {
    final remaining = counts[d.key] ?? 0;
    if (remaining > 0) {
      counts[d.key] = remaining - 1;
    } else {
      added.add(d);
    }
  }
  return added;
}

class VerifyException implements Exception {
  VerifyException(this.message);
  final String message;
  @override
  String toString() => message;
}
