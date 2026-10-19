import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

final _fileLogger = Logger('service');

class Service {
  static final _logger = Logger('Service');

  void run() {
    debugPrint('running');
  }
}

class Repository {
  final Logger logger = Logger('Repository');

  void load() => print('loading');

  static Repository create() {
    debugPrint('creating');
    return Repository();
  }
}

class Plain {
  void go() => debugPrint('plain uses the file logger');
}

void helper() => debugPrint('helper');
