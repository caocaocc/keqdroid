import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/services/ephemeral_xray_ping.dart';

void main() {
  test(
    'core startup reports a process exit without waiting for its full deadline',
    () async {
      final process = Platform.isWindows
          ? await Process.start('cmd', ['/c', 'exit', '7'])
          : await Process.start('/bin/sh', ['-c', 'exit 7']);
      addTearDown(() {
        process.kill();
      });
      final result = await EphemeralXrayPing.waitForCorePort(
        process: process,
        port: 0,
      );
      expect(result.ready, isFalse);
      expect(result.exitCode, 7);
    },
  );

  test(
    'signal termination is an exit, not the old negative timeout sentinel',
    () async {
      final process = await Process.start('/bin/sleep', ['10']);
      addTearDown(() {
        process.kill();
      });
      process.kill(ProcessSignal.sigkill);
      final result = await EphemeralXrayPing.waitForCorePort(
        process: process,
        port: 0,
      );
      expect(result.ready, isFalse);
      expect(result.exitCode, -ProcessSignal.sigkill.signalNumber);
    },
    skip: Platform.isWindows,
  );
}
