import 'package:logger/logger.dart';

var logger = Logger(
  printer: PrettyPrinter(stackTraceBeginIndex: 1),
);

void log(dynamic message) {
  logger.i(message);
}
