import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

export 'src/service.dart';

part 'src/part_file.dart';

final appLogger = Logger('partially_migrated_pkg');

void start() {
  debugPrint('start');
}
