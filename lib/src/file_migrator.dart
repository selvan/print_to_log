import 'dart:math';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/ast/visitor.dart';

const loggingImportUri = 'package:logging/logging.dart';
const _loggingImport = "import '$loggingImportUri';";
const _topLevelLogger = '_log';

/// Outcome of migrating a single Dart source file.
class FileMigration {
  FileMigration({
    required this.source,
    required this.replaced,
    required this.loggersAdded,
    required this.importAdded,
    required this.partOfUri,
    required this.needsLibraryLogger,
    required this.warnings,
  });

  /// The new file content (identical to the input when nothing changed).
  final String source;

  /// Number of `debugPrint(...)` calls rewritten.
  final int replaced;

  /// Logger names declared by this migration.
  final List<String> loggersAdded;

  /// Whether `package:logging` was imported into this file.
  final bool importAdded;

  /// For a `part of` file that needs the logging import or a top-level
  /// logger, the URI of its library: both belong in the library file, since
  /// parts cannot import and share the library's top-level namespace.
  final String? partOfUri;

  /// Whether the library of this part file needs a top-level `_log`.
  final bool needsLibraryLogger;

  /// Calls or situations the tool could not migrate automatically.
  final List<String> warnings;

  bool get changed => replaced > 0;
}

/// Rewrites every `debugPrint(...)` call (and `print(...)` call, when
/// [convertPrint] is set) in [source] to `log.fine(() => ...)`, declaring
/// loggers and importing `package:logging` where needed.
///
/// [fileName] is the file's name without extension; it names the logger used
/// by code that is not inside a class, mixin, enum or extension.
///
/// Existing loggers are reused: the enclosing class's own logger first, then
/// the file's top-level logger. For a `part` file, [libraryLogger] names the
/// top-level logger already declared in its library file, if any.
FileMigration migrateSource(String source,
    {required String fileName,
    bool convertPrint = true,
    String? libraryLogger}) {
  final names = {'debugPrint', if (convertPrint) 'print'};
  if (!names.any(source.contains)) return _unchanged(source);

  final unit = parseString(content: source, throwIfDiagnostics: false).unit;
  final collector = _PrintCollector(names, _importPrefixes(unit));
  unit.accept(collector);
  if (collector.calls.isEmpty) {
    return _unchanged(source, warnings: collector.warnings);
  }

  final edits = <_Edit>[];
  final warnings = [...collector.warnings];
  final loggersAdded = <String>[];
  final createdClassLoggers = <CompilationUnitMember>{};
  var createdTopLevelLogger = false;
  final partOf = unit.directives.whereType<PartOfDirective>().firstOrNull;
  final printShadowedInFile = _declaresPrintOutsideClassMembers(unit);
  final fileLogger =
      _findTopLevelLogger(unit) ?? (partOf != null ? libraryLogger : null);
  var needsLibraryLogger = false;
  var replaced = 0;

  for (final call in collector.calls) {
    final owner = _ownerOf(call);
    final name = call.methodName.name;
    final message = _messageArgument(call);
    if (message == null) {
      warnings.add('${_location(unit, call)}: $name without a message, '
          'left unchanged');
      continue;
    }
    if (name == 'print' &&
        call.target == null &&
        (printShadowedInFile ||
            (owner != null && _hasMember(owner, 'print')))) {
      warnings.add('${_location(unit, call)}: print(...) may call a '
          'user-defined `print`, left unchanged');
      continue;
    }
    final String loggerName;
    if (owner != null) {
      // 1. A logger the class already has (any name). An instance logger
      //    cannot be used from static code, so it is skipped there.
      // 2. The file's top-level logger.
      // 3. A new class-scoped `static final log = Logger('ClassName');`.
      final existing =
          _classLogger(owner, staticContext: _inStaticContext(call, owner));
      if (existing != null) {
        loggerName = existing;
      } else if (fileLogger != null && !_hasMember(owner, fileLogger)) {
        loggerName = fileLogger;
      } else if (createdClassLoggers.contains(owner)) {
        loggerName = 'log';
      } else if (_hasMember(owner, 'log')) {
        warnings.add('${_location(unit, call)}: ${_ownerName(owner, fileName)} '
            'already has a member named `log` that is not usable as a static '
            'Logger here, left unchanged');
        continue;
      } else if (_callsLogFunction(owner)) {
        warnings.add('${_location(unit, call)}: ${_ownerName(owner, fileName)} '
            'calls a function named `log` (e.g. dart:math), which a `log` '
            'logger would shadow; left unchanged');
        continue;
      } else {
        final name = _ownerName(owner, fileName);
        edits.add(_classLoggerEdit(source, owner, name));
        loggersAdded.add(name);
        createdClassLoggers.add(owner);
        loggerName = 'log';
      }
    } else if (fileLogger != null) {
      loggerName = fileLogger;
    } else if (_declaresTopLevel(unit, _topLevelLogger)) {
      warnings.add('${_location(unit, call)}: the file already declares a '
          '`$_topLevelLogger` that is not a Logger, left unchanged');
      continue;
    } else {
      // Private, so it is not exported and cannot clash with other files'
      // loggers or with dart:math's `log`. Parts share the library's
      // namespace, so their logger is declared in the library file.
      if (partOf != null) {
        needsLibraryLogger = true;
      } else if (!createdTopLevelLogger) {
        edits.add(_topLevelLoggerEdit(unit, fileName));
        loggersAdded.add('$_topLevelLogger ($fileName)');
      }
      createdTopLevelLogger = true;
      loggerName = _topLevelLogger;
    }

    edits.add(_replacement(source, call, message, loggerName));
    replaced++;
  }

  if (replaced == 0) return _unchanged(source, warnings: warnings);

  var importAdded = false;
  String? partOfUri;
  if (partOf != null) {
    partOfUri = partOf.uri?.stringValue;
    if (partOfUri == null) {
      warnings.add('part of ${partOf.libraryName}: add `$_loggingImport`'
          '${needsLibraryLogger ? ' and a top-level `$_topLevelLogger` Logger' : ''} to '
          'the library file manually');
    }
  } else if (!_importsLogging(unit)) {
    edits.add(_importEdit(unit));
    importAdded = true;
  }

  return FileMigration(
    source: _applyEdits(source, edits),
    replaced: replaced,
    loggersAdded: loggersAdded,
    importAdded: importAdded,
    partOfUri: partOfUri,
    needsLibraryLogger: needsLibraryLogger,
    warnings: warnings,
  );
}

/// Prepares the library file of migrated parts: adds the logging import and,
/// when [logger] is set, a top-level `final _log = Logger('<fileName>');`,
/// each only if missing. Returns null when nothing changed.
String? prepareLibrary(String source,
    {required bool logger, required String fileName}) {
  final unit = parseString(content: source, throwIfDiagnostics: false).unit;
  final edits = [
    if (!_importsLogging(unit)) _importEdit(unit),
    if (logger && !_declaresTopLevel(unit, _topLevelLogger))
      _topLevelLoggerEdit(unit, fileName),
  ];
  return edits.isEmpty ? null : _applyEdits(source, edits);
}

FileMigration _unchanged(String source, {List<String> warnings = const []}) =>
    FileMigration(
      source: source,
      replaced: 0,
      loggersAdded: const [],
      importAdded: false,
      partOfUri: null,
      needsLibraryLogger: false,
      warnings: warnings,
    );

/// Collects calls to the functions in [names] (`debugPrint`, `print`),
/// unprefixed or through an import prefix (e.g. `foundation.debugPrint(...)`).
/// Method calls on objects, like `buffer.print(...)`, are not collected.
class _PrintCollector extends RecursiveAstVisitor<void> {
  _PrintCollector(this.names, this.importPrefixes);

  final Set<String> names;
  final Set<String> importPrefixes;
  final calls = <MethodInvocation>[];
  final warnings = <String>[];

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (names.contains(node.methodName.name)) {
      final target = node.target;
      if (target == null || _isImportPrefix(target)) {
        calls.add(node);
        // Nested print calls inside the message are left as-is.
        return;
      }
    }
    super.visitMethodInvocation(node);
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (names.contains(node.name) && _isValueUse(node)) {
      final unit = node.root as CompilationUnit;
      warnings.add('${_location(unit, node)}: ${node.name} used as a value '
          '(tear-off or assignment), left unchanged');
    }
  }

  bool _isImportPrefix(Expression target) =>
      target is SimpleIdentifier && importPrefixes.contains(target.name);

  /// A reference to the function itself, e.g. `.forEach(print)`; not a call,
  /// a `show`/`hide` name, or a member of some object (`x.print`).
  bool _isValueUse(SimpleIdentifier node) => switch (node.parent) {
        MethodInvocation(:final methodName) => methodName != node,
        Combinator() => false,
        PropertyAccess(:final propertyName) => propertyName != node,
        PrefixedIdentifier(:final prefix, :final identifier) =>
          identifier != node || _isImportPrefix(prefix),
        _ => true,
      };
}

Set<String> _importPrefixes(CompilationUnit unit) => {
      for (final d in unit.directives.whereType<ImportDirective>())
        if (d.prefix != null) d.prefix!.name,
    };

/// The nearest enclosing class-like declaration, or null for top-level code.
CompilationUnitMember? _ownerOf(AstNode node) {
  for (AstNode? n = node.parent; n != null; n = n.parent) {
    if (n is ClassDeclaration && n.body is BlockClassBody) return n;
    if (n is MixinDeclaration && n.body is BlockClassBody) return n;
    if (n is ExtensionDeclaration && n.body is BlockClassBody) return n;
    if (n is ExtensionTypeDeclaration && n.body is BlockClassBody) return n;
    if (n is EnumDeclaration && n.body is BlockEnumBody) return n;
  }
  return null;
}

String _ownerName(CompilationUnitMember? owner, String fileName) =>
    switch (owner) {
      ClassDeclaration(:final namePart) => namePart.typeName.lexeme,
      MixinDeclaration(:final name) => name.lexeme,
      ExtensionDeclaration(:final name) => name?.lexeme ?? fileName,
      ExtensionTypeDeclaration(:final namePart) => namePart.typeName.lexeme,
      EnumDeclaration(:final namePart) => namePart.typeName.lexeme,
      _ => fileName,
    };

List<ClassMember> _members(CompilationUnitMember owner) => switch (owner) {
      ClassDeclaration(:final body) => body.members,
      MixinDeclaration(:final body) => body.members,
      ExtensionDeclaration(:final body) => body.members,
      ExtensionTypeDeclaration(:final body) => body.members,
      EnumDeclaration(:final body) => body.members,
      _ => const [],
    };

/// Whether [scope] has an unqualified call like `log(x)`, which would
/// resolve to the new logger instead of e.g. `dart:math`'s `log`.
bool _callsLogFunction(AstNode scope) {
  final finder = _LogCallFinder();
  scope.accept(finder);
  return finder.found;
}

class _LogCallFinder extends RecursiveAstVisitor<void> {
  var found = false;

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (node.target == null && node.methodName.name == 'log') found = true;
    super.visitMethodInvocation(node);
  }
}

bool _hasMember(CompilationUnitMember owner, String name) =>
    _members(owner).any((m) =>
        (m is MethodDeclaration && m.name.lexeme == name) ||
        (m is FieldDeclaration &&
            m.fields.variables.any((v) => v.name.lexeme == name)));

/// Whether the file declares something named `print` (top-level or local
/// function, variable or parameter), which unqualified `print(...)` calls
/// could refer to instead of `dart:core`'s. Class members are checked
/// per class by [_hasMember].
bool _declaresPrintOutsideClassMembers(CompilationUnit unit) {
  final finder = _PrintDeclarationFinder();
  unit.accept(finder);
  return finder.found;
}

class _PrintDeclarationFinder extends GeneralizingAstVisitor<void> {
  var found = false;

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    if (node.name.lexeme == 'print') found = true;
    super.visitFunctionDeclaration(node);
  }

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    if (node.name.lexeme == 'print' &&
        node.parent?.parent is! FieldDeclaration) {
      found = true;
    }
    super.visitVariableDeclaration(node);
  }

  @override
  void visitFormalParameter(FormalParameter node) {
    if (node.name?.lexeme == 'print') found = true;
    super.visitFormalParameter(node);
  }
}

/// The name of the first top-level Logger variable or getter in [unit].
String? _findTopLevelLogger(CompilationUnit unit) {
  for (final d in unit.declarations) {
    if (d is TopLevelVariableDeclaration) {
      for (final v in d.variables.variables) {
        if (_isLogger(d.variables.type, v.initializer)) return v.name.lexeme;
      }
    } else if (d is FunctionDeclaration &&
        d.isGetter &&
        _isLoggerType(d.returnType)) {
      return d.name.lexeme;
    }
  }
  return null;
}

/// The name of the first top-level Logger variable or getter declared in
/// [source] (used to find the logger of a part file's library).
String? findTopLevelLoggerIn(String source) => _findTopLevelLogger(
    parseString(content: source, throwIfDiagnostics: false).unit);

/// The name of a Logger field or getter of [owner], usable from static code
/// when [staticContext] is set.
String? _classLogger(CompilationUnitMember owner,
    {required bool staticContext}) {
  for (final m in _members(owner)) {
    if (m is FieldDeclaration && (m.isStatic || !staticContext)) {
      for (final v in m.fields.variables) {
        if (_isLogger(m.fields.type, v.initializer)) return v.name.lexeme;
      }
    } else if (m is MethodDeclaration &&
        m.isGetter &&
        (m.isStatic || !staticContext) &&
        _isLoggerType(m.returnType)) {
      return m.name.lexeme;
    }
  }
  return null;
}

/// Declared as `Logger`, or initialized with `Logger(...)`,
/// `Logger.detached(...)` or `new Logger(...)`.
bool _isLogger(TypeAnnotation? type, Expression? initializer) =>
    _isLoggerType(type) ||
    switch (initializer) {
      MethodInvocation(target: null, :final methodName) =>
        methodName.name == 'Logger',
      MethodInvocation(target: SimpleIdentifier(name: 'Logger')) => true,
      InstanceCreationExpression(:final constructorName) =>
        constructorName.type.name.lexeme == 'Logger',
      _ => false,
    };

bool _isLoggerType(TypeAnnotation? type) =>
    type is NamedType && type.name.lexeme == 'Logger';

/// Whether [call] runs without access to `this` inside [owner]: in a static
/// member, a factory constructor, a constructor initializer list, or a
/// non-late field initializer.
bool _inStaticContext(AstNode call, CompilationUnitMember owner) {
  for (AstNode? n = call.parent; n != null && n != owner; n = n.parent) {
    switch (n) {
      case MethodDeclaration(:final isStatic):
        return isStatic;
      case ConstructorDeclaration(:final factoryKeyword):
        return factoryKeyword != null;
      case ConstructorInitializer():
        return true;
      case FieldDeclaration(:final isStatic, :final fields):
        return isStatic || !fields.isLate;
    }
  }
  return false;
}

bool _declaresTopLevel(CompilationUnit unit, String name) =>
    unit.declarations.any((d) =>
        d is TopLevelVariableDeclaration &&
        d.variables.variables.any((v) => v.name.lexeme == name));

bool _importsLogging(CompilationUnit unit) => unit.directives
    .whereType<ImportDirective>()
    .any((d) => d.uri.stringValue == loggingImportUri && d.prefix == null);

Expression? _messageArgument(MethodInvocation call) =>
    call.argumentList.arguments
        .where((a) => a is! NamedArgument)
        .firstOrNull
        ?.argumentExpression;

/// Replaces [call] with the `log.fine` form. A call that is the unbraced
/// body of an `if`/loop gets braces, since the result spans several lines
/// (`curly_braces_in_flow_control_structures`).
_Edit _replacement(String source, MethodInvocation call, Expression message,
    String loggerName) {
  final indent = _lineIndent(source, call.offset);
  final statement = call.parent;
  if (statement is ExpressionStatement &&
      statement.expression == call &&
      _isUnbracedBody(statement)) {
    final inner = '$indent  ';
    return _Edit(
      statement.offset,
      statement.end,
      '{\n$inner${_logFine(source, message, inner, loggerName)};\n$indent}',
    );
  }
  return _Edit(
      call.offset, call.end, _logFine(source, message, indent, loggerName));
}

bool _isUnbracedBody(Statement statement) => switch (statement.parent) {
      IfStatement(:final thenStatement, :final elseStatement) =>
        thenStatement == statement || elseStatement == statement,
      ForStatement(:final body) ||
      WhileStatement(:final body) ||
      DoStatement(:final body) =>
        body == statement,
      _ => false,
    };

String _logFine(
    String source, Expression message, String indent, String loggerName) {
  final messageIndent = '$indent      ';
  return '$loggerName.fine(\n'
      '$indent  () =>\n'
      '$messageIndent${_reindent(source, message, messageIndent)},\n'
      '$indent)';
}

/// The source of [message], with its continuation lines shifted to line up
/// with its new position. Messages containing multi-line string literals are
/// kept verbatim, since re-indenting would change the string.
String _reindent(String source, Expression message, String newIndent) {
  final text = source.substring(message.offset, message.end);
  if (!text.contains('\n') || _hasMultilineString(message)) return text;
  final lineStart = source.lastIndexOf('\n', message.offset - 1) + 1;
  final shift = newIndent.length - (message.offset - lineStart);
  final lines = text.split('\n');
  return [
    lines.first,
    for (final line in lines.skip(1))
      if (shift >= 0)
        '${' ' * shift}$line'
      else
        line.substring(min(-shift, line.length - line.trimLeft().length)),
  ].join('\n');
}

bool _hasMultilineString(Expression message) {
  final finder = _MultilineStringFinder();
  message.accept(finder);
  return finder.found;
}

class _MultilineStringFinder extends RecursiveAstVisitor<void> {
  var found = false;

  @override
  void visitSimpleStringLiteral(SimpleStringLiteral node) {
    if (node.isMultiline) found = true;
  }

  @override
  void visitStringInterpolation(StringInterpolation node) {
    if (node.isMultiline) found = true;
    super.visitStringInterpolation(node);
  }
}

_Edit _classLoggerEdit(
    String source, CompilationUnitMember owner, String name) {
  final Token anchor = switch (owner) {
    EnumDeclaration(:final body) =>
      (body as BlockEnumBody).semicolon ?? body.leftBracket,
    ClassDeclaration(:final body) ||
    MixinDeclaration(:final body) ||
    ExtensionDeclaration(:final body) ||
    ExtensionTypeDeclaration(:final body) =>
      (body as BlockClassBody).leftBracket,
    _ => throw StateError('Unsupported owner ${owner.runtimeType}'),
  };
  final indent = '${_lineIndent(source, owner.offset)}  ';
  final declaration = "static final log = Logger('$name');";
  // After a class `{` keep a blank line before the existing members; after
  // an enum's `;` the existing blank line already separates them.
  final trailing = owner is EnumDeclaration ? '' : '\n';
  return _Edit(anchor.end, anchor.end, '\n$indent$declaration$trailing',
      order: 1);
}

_Edit _topLevelLoggerEdit(CompilationUnit unit, String fileName) {
  final declaration = "final $_topLevelLogger = Logger('$fileName');";
  if (unit.directives.isNotEmpty) {
    final end = unit.directives.last.end;
    return _Edit(end, end, '\n\n$declaration', order: 2);
  }
  final at = _firstDeclarationOffset(unit);
  return _Edit(at, at, '$declaration\n\n', order: 2);
}

/// Inserts the logging import, keeping package imports alphabetical.
_Edit _importEdit(CompilationUnit unit) {
  final imports = unit.directives.whereType<ImportDirective>().toList();
  String uriOf(ImportDirective d) => d.uri.stringValue ?? '';

  final packageImports =
      imports.where((d) => uriOf(d).startsWith('package:')).toList();
  final after = packageImports
      .where((d) => uriOf(d).compareTo(loggingImportUri) > 0)
      .firstOrNull;
  if (after != null) {
    return _Edit(after.offset, after.offset, '$_loggingImport\n', order: 0);
  }
  if (packageImports.isNotEmpty) {
    final end = packageImports.last.end;
    return _Edit(end, end, '\n$_loggingImport', order: 0);
  }
  final dartImports =
      imports.where((d) => uriOf(d).startsWith('dart:')).toList();
  if (dartImports.isNotEmpty) {
    final end = dartImports.last.end;
    return _Edit(end, end, '\n\n$_loggingImport', order: 0);
  }
  if (imports.isNotEmpty) {
    final at = imports.first.offset;
    return _Edit(at, at, '$_loggingImport\n\n', order: 0);
  }
  final library = unit.directives.whereType<LibraryDirective>().firstOrNull;
  if (library != null) {
    return _Edit(library.end, library.end, '\n\n$_loggingImport', order: 0);
  }
  final at = unit.directives.isNotEmpty
      ? unit.directives.first.offset
      : _firstDeclarationOffset(unit);
  return _Edit(at, at, '$_loggingImport\n\n', order: 0);
}

int _firstDeclarationOffset(CompilationUnit unit) =>
    unit.declarations.isEmpty ? 0 : unit.declarations.first.offset;

String _lineIndent(String source, int offset) {
  final lineStart = source.lastIndexOf('\n', offset > 0 ? offset - 1 : 0) + 1;
  var i = lineStart;
  while (i < source.length && (source[i] == ' ' || source[i] == '\t')) {
    i++;
  }
  return source.substring(lineStart, i);
}

String _location(CompilationUnit unit, AstNode node) {
  final loc = unit.lineInfo.getLocation(node.offset);
  return 'line ${loc.lineNumber}';
}

class _Edit {
  _Edit(this.start, this.end, this.text, {this.order = 3});

  final int start;
  final int end;
  final String text;

  /// Tie-breaker for insertions at the same offset: lower comes first.
  final int order;
}

String _applyEdits(String source, List<_Edit> edits) {
  final sorted = [...edits]..sort((a, b) {
      final byStart = b.start.compareTo(a.start);
      return byStart != 0 ? byStart : b.order.compareTo(a.order);
    });
  var result = source;
  for (final e in sorted) {
    result = result.replaceRange(e.start, e.end, e.text);
  }
  return result;
}

/// Removes imports (or `show` names) reported unused by the analyzer.
///
/// [diagnostics] are `(code, offset)` pairs of `unused_import`,
/// `unnecessary_import` and `unused_shown_name` diagnostics in this file.
/// Returns null when nothing was removed.
String? removeUnusedImports(
    String source, List<({String code, int offset})> diagnostics) {
  final unit = parseString(content: source, throwIfDiagnostics: false).unit;
  final edits = <_Edit>[];
  final removedDirectives = <ImportDirective>{};

  ImportDirective? directiveAt(int offset) => unit.directives
      .whereType<ImportDirective>()
      .where((d) => d.offset <= offset && offset < d.end)
      .firstOrNull;

  for (final d in diagnostics) {
    final directive = directiveAt(d.offset);
    if (directive == null || removedDirectives.contains(directive)) continue;

    if (d.code == 'unused_shown_name') {
      final shown = directive.combinators
          .whereType<ShowCombinator>()
          .expand((c) => c.shownNames.map((n) => (c, n)))
          .where((e) => e.$2.offset == d.offset)
          .firstOrNull;
      if (shown == null) continue;
      final (combinator, name) = shown;
      final remaining = combinator.shownNames
          .where((n) =>
              n != name &&
              !diagnostics.any(
                  (x) => x.code == 'unused_shown_name' && x.offset == n.offset))
          .toList();
      if (remaining.isEmpty) {
        removedDirectives.add(directive);
      } else {
        final names = combinator.shownNames;
        final i = names.indexOf(name);
        // Remove the name together with one adjacent comma.
        final start = i == 0 ? name.offset : names[i - 1].end;
        final end = i == 0 ? names[1].offset : name.end;
        edits.add(_Edit(start, end, ''));
      }
    } else {
      removedDirectives.add(directive);
    }
  }

  for (final directive in removedDirectives) {
    edits.removeWhere(
        (e) => e.start >= directive.offset && e.end <= directive.end);
    var end = directive.end;
    if (end < source.length && source[end] == '\n') end++;
    edits.add(_Edit(directive.offset, end, ''));
  }
  if (edits.isEmpty) return null;
  return _applyEdits(source, edits);
}
