import 'package:logger/logger.dart';

var logger = Logger(
  printer: PrettyPrinter(stackTraceBeginIndex: 1),
);

void log(String message) {
  logger.i(message);
}
