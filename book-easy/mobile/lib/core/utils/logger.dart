import 'package:logging/logging.dart';

/// App-wide logger built on package:logging.
///
/// Call [initLogging] once from `main()`. In debug builds every record is
/// printed; in release builds only warnings and above are surfaced so we
/// never spam (or leak) information from production devices.
final Logger appLogger = Logger('BookEasy');

void initLogging() {
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((record) {
    if (!kReleaseLogging || record.level >= Level.WARNING) {
      // ignore: avoid_print — intentional debug console output
      print('${record.level.name} [${record.loggerName}] ${record.message}'
          '${record.error != null ? ' | error: ${record.error}' : ''}');
    }
  });
}

/// Only log info/debug records in debug builds.
const bool kReleaseLogging = bool.fromEnvironment('dart.vm.product');
