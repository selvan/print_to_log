/// Migrates `debugPrint` and `print` calls in a Flutter package to `package:logging`.
library;

export 'src/file_migrator.dart'
    show
        FileMigration,
        findTopLevelLoggerIn,
        migrateSource,
        prepareLibrary,
        removeUnusedImports;
export 'src/pubspec_updater.dart' show addLoggingDependency, loggingConstraint;
export 'src/verifier.dart'
    show Diagnostic, Verifier, VerifyException, newDiagnostics;
