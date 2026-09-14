import 'dart:io';

/// A private test CA, trusted only by this test's SecurityContext. macOS limits
/// leaf certificate lifetimes, so generate a fresh short-lived leaf in /tmp.
/// All keys under test/fixtures/http_probe are public test material.
Future<Directory> createProbeCertificates() async {
  final directory = await Directory.systemTemp.createTemp('keqdis_probe_cert_');
  var openssl = 'openssl';
  if (Platform.isWindows) {
    for (final path in [
      '${Platform.environment['ProgramFiles'] ?? 'C:/Program Files'}/Git/mingw64/bin/openssl.exe',
      '${Platform.environment['ProgramFiles'] ?? 'C:/Program Files'}/Git/usr/bin/openssl.exe',
    ]) {
      if (await File(path).exists()) {
        openssl = path;
        break;
      }
    }
  }
  Future<void> run(List<String> arguments) async {
    final result = await Process.run(openssl, arguments);
    if (result.exitCode != 0) {
      throw StateError('Could not create local TLS fixture: ${result.stderr}');
    }
  }

  try {
    await run([
      'req',
      '-batch',
      '-new',
      '-key',
      'test/fixtures/http_probe/localhost-key.pem',
      '-out',
      '${directory.path}/localhost.csr',
      '-subj',
      '/CN=localhost',
    ]);
    await run([
      'x509',
      '-req',
      '-in',
      '${directory.path}/localhost.csr',
      '-CA',
      'test/fixtures/http_probe/ca-cert.pem',
      '-CAkey',
      'test/fixtures/http_probe/ca-key.pem',
      '-set_serial',
      '2',
      '-out',
      '${directory.path}/localhost-cert.pem',
      '-days',
      '30',
      '-extfile',
      'test/fixtures/http_probe/localhost.ext',
    ]);
    return directory;
  } catch (_) {
    await directory.delete(recursive: true);
    rethrow;
  }
}
