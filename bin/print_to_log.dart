import 'dart:io';

import 'package:args/args.dart';
import 'package:print_to_log/print_to_log.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

const _importCleanupCodes = {
  'unused_import',
  'unnecessary_import',
  'unused_shown_name',
};

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addFlag('dry-run',
        abbr: 'n',
        negatable: false,
        help: 'Report what would change without writing files.')
    ..addFlag('verify',
        defaultsTo: true,
        help: 'Run pub get and the analyzer before and after, remove imports '
            'left unused, and fail if new diagnostics appear.')
    ..addFlag('format',
        negatable: false,
        help: 'Run dart format on changed files (note: the tall style may '
            'collapse the multi-line log.fine layout).')
    ..addFlag('print',
        defaultsTo: true,
        help: 'Also convert print(...) calls. Use --no-print for command-line '
            'packages where print is the program output.')
    ..addFlag('test',
        negatable: false, help: 'Run the package tests after migrating.')
    ..addFlag('help', abbr: 'h', negatable: false);

  final ArgResults args;
  try {
    args = parser.parse(arguments);
  } on FormatException catch (e) {
    _usage(parser, e.message);
  }
  if (args.flag('help')) _usage(parser);
  if (args.rest.length > 1) {
    _usage(parser, 'Expected at most one package directory.');
  }

  // Defaults to the current directory, so a package that has print_to_log as
  // a dev dependency can run `dart run print_to_log` from its root.
  final packageDir = p.normalize(
      p.absolute(args.rest.isEmpty ? Directory.current.path : args.rest.single));
  final pubspecFile = File(p.join(packageDir, 'pubspec.yaml'));
  if (!pubspecFile.existsSync()) {
    _fail('No pubspec.yaml in $packageDir');
  }
  final dryRun = args.flag('dry-run');
  final verify = args.flag('verify') && !dryRun;
  final convertPrint = args.flag('print');
  final callNames = convertPrint ? 'debugPrint/print' : 'debugPrint';
  final verifier = Verifier(packageDir);

  try {
    List<Diagnostic> baseline = const [];
    if (verify) {
      stdout.writeln('Resolving dependencies and analyzing (baseline)...');
      await verifier.pubGet();
      baseline = await verifier.analyze();
      final errors = baseline.where((d) => d.severity == 'ERROR').length;
      if (errors > 0) {
        stdout.writeln('  note: package already has $errors analyzer '
            'error(s) before migration; only new ones will be reported.');
      }
    }

    // Migrate every Dart file.
    final packageName =
        (loadYaml(pubspecFile.readAsStringSync()) as Map)['name'];
    final changed = <String, String>{}; // path -> new content
    // Library files of migrated parts -> whether they need a top-level log.
    final libraries = <String, bool>{};
    var totalCalls = 0;
    var totalLoggers = 0;
    final warnings = <String>[];

    for (final file in _dartFiles(packageDir)) {
      final source = file.readAsStringSync();
      final fileName = p.basenameWithoutExtension(file.path);
      var result =
          migrateSource(source, fileName: fileName, convertPrint: convertPrint);
      // A part file can reuse the logger its library already declares.
      final partUri = result.partOfUri;
      if (result.needsLibraryLogger && partUri != null) {
        final library =
            _resolveUri(partUri, file.path, packageDir, packageName);
        final libraryLogger = library == null
            ? null
            : findTopLevelLoggerIn(
                changed[library] ?? File(library).readAsStringSync());
        if (libraryLogger != null) {
          result = migrateSource(source,
              fileName: fileName,
              convertPrint: convertPrint,
              libraryLogger: libraryLogger);
        }
      }
      final rel = p.relative(file.path, from: packageDir);
      warnings.addAll(result.warnings.map((w) => '$rel: $w'));
      if (!result.changed) continue;

      changed[file.path] = result.source;
      totalCalls += result.replaced;
      totalLoggers += result.loggersAdded.length;
      stdout.writeln('  $rel: ${result.replaced} call(s)'
          '${result.loggersAdded.isEmpty ? '' : ', logger ${result.loggersAdded.join(', ')}'}'
          '${result.importAdded ? ', import added' : ''}');

      final partOf = result.partOfUri;
      if (partOf != null) {
        final library = _resolveUri(partOf, file.path, packageDir, packageName);
        if (library == null) {
          warnings.add('$rel: cannot locate library "$partOf"; add the '
              'logging import${result.needsLibraryLogger ? ' and a top-level '
                  '`_log` Logger' : ''} there manually');
        } else {
          libraries[library] =
              (libraries[library] ?? false) || result.needsLibraryLogger;
        }
      }
    }

    for (final MapEntry(key: library, value: logger) in libraries.entries) {
      final current = changed[library] ?? File(library).readAsStringSync();
      final updated = prepareLibrary(current,
          logger: logger, fileName: p.basenameWithoutExtension(library));
      if (updated != null) {
        changed[library] = updated;
        stdout.writeln('  ${p.relative(library, from: packageDir)}: '
            'logging import/logger ensured for its parts');
      }
    }

    if (changed.isEmpty) {
      stdout.writeln('No $callNames calls found.');
      _printWarnings(warnings);
      return;
    }

    final newPubspec = addLoggingDependency(pubspecFile.readAsStringSync());
    stdout.writeln('${dryRun ? 'Would replace' : 'Replaced'} $totalCalls '
        '$callNames call(s) in ${changed.length} file(s), '
        '$totalLoggers logger(s) declared'
        '${newPubspec != null ? ', logging $loggingConstraint added to pubspec.yaml' : ''}.');

    if (dryRun) {
      _printWarnings(warnings);
      return;
    }

    changed.forEach((path, content) => File(path).writeAsStringSync(content));
    if (newPubspec != null) pubspecFile.writeAsStringSync(newPubspec);

    if (verify) {
      stdout.writeln('Resolving dependencies and analyzing (after)...');
      await verifier.pubGet();
      var after = await verifier.analyze();
      if (await _removeNewlyUnusedImports(
          packageDir, newDiagnostics(baseline, after), changed.keys.toSet())) {
        after = await verifier.analyze();
      }
      if (args.flag('format')) await verifier.format(changed.keys);
      if (args.flag('format')) after = await verifier.analyze();

      final introduced = newDiagnostics(baseline, after);
      _printWarnings(warnings);
      if (introduced.isNotEmpty) {
        stderr.writeln('Migration introduced ${introduced.length} new '
            'analyzer issue(s):');
        for (final d in introduced) {
          stderr.writeln('  $d');
        }
        exit(1);
      }
      stdout.writeln('Analyzer: no new issues.');
    } else {
      if (args.flag('format')) await verifier.format(changed.keys);
      _printWarnings(warnings);
    }

    if (args.flag('test')) {
      stdout.writeln('Running tests...');
      if (!await verifier.test()) _fail('Tests failed.');
    }
  } on VerifyException catch (e) {
    _fail(e.message);
  }
}

/// Removes imports that became unused (typically flutter/foundation.dart that
/// was only needed for debugPrint). Returns whether any file changed.
Future<bool> _removeNewlyUnusedImports(
    String packageDir, List<Diagnostic> introduced, Set<String> files) async {
  final byFile = <String, List<({String code, int offset})>>{};
  for (final d in introduced) {
    final path = p.join(packageDir, d.file);
    if (!_importCleanupCodes.contains(d.code) || !files.contains(path)) {
      continue;
    }
    (byFile[path] ??= []).add((code: d.code, offset: d.offset));
  }
  var any = false;
  for (final MapEntry(key: path, value: diagnostics) in byFile.entries) {
    final file = File(path);
    final updated = removeUnusedImports(file.readAsStringSync(), diagnostics);
    if (updated != null) {
      file.writeAsStringSync(updated);
      stdout.writeln('  ${p.relative(path, from: packageDir)}: removed '
          'unused import(s)');
      any = true;
    }
  }
  return any;
}

/// Dart files of this package, skipping tool output, hidden directories,
/// nested packages (e.g. `example/`) and generated code.
Iterable<File> _dartFiles(String root) sync* {
  final pending = [Directory(root)];
  while (pending.isNotEmpty) {
    final dir = pending.removeLast();
    for (final entity in dir.listSync(followLinks: false)) {
      final name = p.basename(entity.path);
      if (entity is Directory) {
        if (name.startsWith('.') || name == 'build') continue;
        if (File(p.join(entity.path, 'pubspec.yaml')).existsSync()) {
          stdout.writeln('  skipping nested package '
              '${p.relative(entity.path, from: root)} (run the tool on it '
              'separately)');
          continue;
        }
        pending.add(entity);
      } else if (entity is File &&
          name.endsWith('.dart') &&
          !_isGenerated(name)) {
        yield entity;
      }
    }
  }
}

bool _isGenerated(String name) =>
    name.endsWith('.g.dart') ||
    name.endsWith('.freezed.dart') ||
    name.endsWith('.mocks.dart') ||
    name.endsWith('.gr.dart');

String? _resolveUri(
    String uri, String fromFile, String packageDir, Object? packageName) {
  final String path;
  if (uri.startsWith('package:$packageName/')) {
    path = p.join(
        packageDir, 'lib', uri.substring('package:$packageName/'.length));
  } else if (!uri.contains(':')) {
    path = p.normalize(p.join(p.dirname(fromFile), uri));
  } else {
    return null;
  }
  return File(path).existsSync() ? path : null;
}

void _printWarnings(List<String> warnings) {
  if (warnings.isEmpty) return;
  stdout.writeln('Not migrated automatically:');
  for (final w in warnings) {
    stdout.writeln('  $w');
  }
}

Never _usage(ArgParser parser, [String? error]) {
  if (error != null) stderr.writeln(error);
  (error == null ? stdout : stderr)
    ..writeln('Usage: print_to_log [package_dir] [options]')
    ..writeln('package_dir defaults to the current directory.')
    ..writeln(parser.usage);
  exit(error == null ? 0 : 64);
}

Never _fail(String message) {
  stderr.writeln(message);
  exit(1);
}
