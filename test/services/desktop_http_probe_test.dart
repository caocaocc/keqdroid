import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/services/desktop_http_probe.dart';
import '../helpers/probe_certificates.dart';

late String _cert;
const _key = 'test/fixtures/http_probe/localhost-key.pem';

typedef _Reply = Future<void> Function(Socket socket, int request);

/// Real TCP CONNECT proxy and separately bound TLS endpoint, all on loopback.
/// The proxy ignores requested destinations and can only reach this fixture.
class _Fixture {
  final ServerSocket proxy;
  final SecureServerSocket endpoint;
  final _Reply reply;
  final Duration connectDelay;
  final bool stallConnect;
  final bool stallTls;
  final Set<Socket> sockets = {};
  final List<String> requests = [];
  int connects = 0;
  int handshakes = 0;
  int openClients = 0;
  bool closed = false;

  _Fixture(
    this.proxy,
    this.endpoint,
    this.reply,
    this.connectDelay,
    this.stallConnect,
    this.stallTls,
  ) {
    proxy.listen(_proxyClient);
    endpoint.listen(_tlsClient, onError: (Object _) {});
  }

  static Future<_Fixture> start({
    _Reply? reply,
    Duration connectDelay = Duration.zero,
    bool stallConnect = false,
    bool stallTls = false,
  }) async {
    final context = SecurityContext()
      ..useCertificateChain(_cert)
      ..usePrivateKey(_key);
    return _Fixture(
      await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
      await SecureServerSocket.bind(InternetAddress.loopbackIPv4, 0, context),
      reply ??
          (socket, _) async {
            socket.write('HTTP/1.1 204 No Content\r\n\r\n');
            await socket.flush();
          },
      connectDelay,
      stallConnect,
      stallTls,
    );
  }

  SecurityContext get trust =>
      SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificates('test/fixtures/http_probe/ca-cert.pem');
  String get url => 'https://localhost:${endpoint.port}/probe?a=1%202&b=two';

  void _proxyClient(Socket client) {
    sockets.add(client);
    openClients++;
    var pending = <int>[];
    Socket? upstream;
    var accepted = false;
    client.listen(
      (data) async {
        if (upstream != null) {
          upstream!.add(data);
          return;
        }
        if (accepted) return;
        pending.addAll(data);
        if (!ascii.decode(pending, allowInvalid: true).contains('\r\n\r\n')) {
          return;
        }
        accepted = true;
        connects++;
        if (stallConnect) return;
        await Future<void>.delayed(connectDelay);
        if (closed) return;
        try {
          if (!stallTls) {
            final remote = await Socket.connect(
              InternetAddress.loopbackIPv4,
              endpoint.port,
            );
            if (closed) {
              remote.destroy();
              return;
            }
            upstream = remote;
            sockets.add(remote);
            remote.listen(
              client.add,
              onError: (Object _) => client.destroy(),
              onDone: () => client.destroy(),
            );
          }
          // Split the CONNECT header to exercise incremental parsing.
          client.write('HTTP/1.1 200 Connection');
          await client.flush();
          client.write(' established\r\n\r\n');
          await client.flush();
        } catch (_) {
          client.destroy();
        }
      },
      onError: (Object _) {},
      onDone: () {
        openClients--;
        upstream?.destroy();
      },
    );
  }

  void _tlsClient(SecureSocket client) {
    handshakes++;
    sockets.add(client);
    var buffer = '';
    var count = 0;
    client.listen((data) {
      buffer += ascii.decode(data, allowInvalid: true);
      var end = -1;
      while ((end = buffer.indexOf('\r\n\r\n')) >= 0) {
        requests.add(buffer.substring(0, end));
        buffer = buffer.substring(end + 4);
        count++;
        unawaited(reply(client, count).catchError((Object _) {}));
      }
    }, onError: (Object _) {});
  }

  Future<void> close() async {
    closed = true;
    for (final socket in sockets) {
      socket.destroy();
    }
    await proxy.close();
    await endpoint.close();
  }
}

void main() {
  late Directory certificateDirectory;
  setUpAll(() async {
    certificateDirectory = await createProbeCertificates();
    _cert = '${certificateDirectory.path}/localhost-cert.pem';
  });
  tearDownAll(() => certificateDirectory.delete(recursive: true));
  Future<_Fixture> fixture({
    _Reply? reply,
    Duration connectDelay = Duration.zero,
    bool stallConnect = false,
    bool stallTls = false,
  }) async {
    final value = await _Fixture.start(
      reply: reply,
      connectDelay: connectDelay,
      stallConnect: stallConnect,
      stallTls: stallTls,
    );
    addTearDown(value.close);
    return value;
  }

  test(
    'CONNECT upgrades to verified TLS; two GETs reuse one connection',
    () async {
      final f = await fixture();
      final result = await DesktopHttpProbe.run(
        testUrl: f.url,
        proxyPort: f.proxy.port,
        timeout: const Duration(seconds: 3),
        securityContext: f.trust,
      );
      expect(result.success, isTrue, reason: result.error);
      expect(result.diagnostics?.timingKind, 'warm');
      final diagnostics = result.diagnostics!;
      expect(diagnostics.stageDurationsMs.keys, [
        'localConnect',
        'proxyConnect',
        'tls',
        'firstGet',
        'warmGet',
      ]);
      expect(diagnostics.stageDurationsMs.values, everyElement(isNonNegative));
      expect(
        diagnostics.stageDurationsMs.values.fold(0, (sum, ms) => sum + ms),
        diagnostics.elapsedMs,
      );
      expect(f.connects, 1);
      expect(f.handshakes, 1);
      expect(f.requests, hasLength(2));
      expect(f.requests.first, startsWith('GET /probe?a=1%202&b=two HTTP/1.1'));
      expect(
        f.requests.first,
        contains('Host: localhost:${f.endpoint.port}\r\n'),
      );
    },
  );

  test('cold latency includes CONNECT and TLS instead of only GET', () async {
    final f = await fixture(connectDelay: const Duration(milliseconds: 120));
    final result = await DesktopHttpProbe.run(
      testUrl: f.url,
      proxyPort: f.proxy.port,
      timeout: const Duration(seconds: 3),
      securityContext: f.trust,
      keepAlive: false,
    );
    expect(result.success, isTrue, reason: result.error);
    expect(result.latencyMs, greaterThanOrEqualTo(110));
    expect(result.diagnostics?.timingKind, 'cold');
    expect(
      result.diagnostics!.stageDurationsMs['proxyConnect'],
      greaterThanOrEqualTo(110),
    );
    expect(f.requests, hasLength(1));
  });

  test(
    'second request timeout preserves first success and marks cold fallback',
    () async {
      final f = await fixture(
        reply: (socket, request) async {
          if (request == 1) {
            socket.write('HTTP/1.1 204 No Content\r\n\r\n');
            await socket.flush();
          }
        },
      );
      final result = await DesktopHttpProbe.run(
        testUrl: f.url,
        proxyPort: f.proxy.port,
        timeout: const Duration(milliseconds: 450),
        securityContext: f.trust,
      );
      expect(result.success, isTrue, reason: result.error);
      expect(result.diagnostics?.timingKind, 'coldFallback');
      expect(result.diagnostics?.completedRequests, 1);
      expect(result.diagnostics?.warning, contains('warmGet'));
    },
  );

  for (final framing in ['length', 'chunked', 'eof', 'http10']) {
    test(
      'drains $framing response and only reuses a persistent connection',
      () async {
        final f = await fixture(
          reply: (socket, request) async {
            final text = switch (framing) {
              'length' => 'HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nbody',
              'chunked' =>
                'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nbo\r\n2\r\ndy\r\n0\r\nX-Test: yes\r\n\r\n',
              'http10' => 'HTTP/1.0 200 OK\r\nContent-Length: 4\r\n\r\nbody',
              _ => 'HTTP/1.1 200 OK\r\n\r\nbody',
            };
            for (var offset = 0; offset < text.length; offset += 7) {
              socket.write(
                text.substring(offset, (offset + 7).clamp(0, text.length)),
              );
              await socket.flush();
            }
            if (framing == 'eof' || framing == 'http10') await socket.close();
          },
        );
        final result = await DesktopHttpProbe.run(
          testUrl: f.url,
          proxyPort: f.proxy.port,
          timeout: const Duration(seconds: 3),
          securityContext: f.trust,
        );
        expect(result.success, isTrue, reason: result.error);
        expect(
          f.requests,
          hasLength(framing == 'eof' || framing == 'http10' ? 1 : 2),
        );
      },
    );
  }

  for (final body in ['nothex\r\n\r\n', '1\r\naX\r\n0\r\n\r\n']) {
    test('rejects malformed chunk framing $body', () async {
      final f = await fixture(
        reply: (socket, _) async {
          socket.write(
            'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n$body',
          );
          await socket.flush();
        },
      );
      final result = await DesktopHttpProbe.run(
        testUrl: f.url,
        proxyPort: f.proxy.port,
        timeout: const Duration(seconds: 2),
        securityContext: f.trust,
      );
      expect(result.success, isFalse);
      expect(result.error, contains('firstGet'));
      expect(result.error, contains('chunk'));
    });
  }

  for (final stage in ['proxyConnect', 'tls', 'firstGet']) {
    test(
      '$stage stall observes one deadline and closes the underlying client',
      () async {
        final f = await fixture(
          stallConnect: stage == 'proxyConnect',
          stallTls: stage == 'tls',
          reply: stage == 'firstGet' ? (socket, _) async {} : null,
        );
        final sw = Stopwatch()..start();
        final result = await DesktopHttpProbe.run(
          testUrl: f.url,
          proxyPort: f.proxy.port,
          timeout: const Duration(milliseconds: 300),
          securityContext: f.trust,
        );
        expect(result.success, isFalse);
        expect(result.diagnostics?.stage, stage);
        expect(
          result.diagnostics!.stageDurationsMs[stage],
          greaterThanOrEqualTo(200),
        );
        expect(result.error, contains('timed out'));
        expect(sw.elapsedMilliseconds, lessThan(1200));
        await Future<void>.delayed(const Duration(milliseconds: 60));
        expect(f.openClients, 0);
      },
    );
  }

  for (final malformed in {
    'header name': 'Bad Name: value\r\nContent-Length: 0\r\n\r\n',
    'header value': 'X-Test: value\u0001\r\nContent-Length: 0\r\n\r\n',
    'trailer name':
        'Transfer-Encoding: chunked\r\n\r\n0\r\nBad Name: value\r\n\r\n',
  }.entries) {
    test('rejects an invalid HTTP ${malformed.key}', () async {
      final f = await fixture(
        reply: (socket, _) async {
          socket.write('HTTP/1.1 200 OK\r\n${malformed.value}');
          await socket.flush();
        },
      );
      final result = await DesktopHttpProbe.run(
        testUrl: f.url,
        proxyPort: f.proxy.port,
        timeout: const Duration(seconds: 2),
        securityContext: f.trust,
        keepAlive: false,
      );
      expect(result.success, isFalse);
      expect(result.diagnostics?.stage, 'firstGet');
      expect(result.error, contains('Invalid HTTP header'));
    });
  }

  test('cancellation during TLS closes the owned raw socket', () async {
    final f = await fixture(stallTls: true);
    final cancellation = ProbeCancellation();
    final future = DesktopHttpProbe.run(
      testUrl: f.url,
      proxyPort: f.proxy.port,
      timeout: const Duration(seconds: 3),
      securityContext: f.trust,
      cancellation: cancellation,
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    cancellation.cancel();
    final result = await future;
    expect(result.error, contains('cancelled'));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(f.openClients, 0);
  });

  test('untrusted certificate is rejected without accepting a GET', () async {
    final f = await fixture();
    final result = await DesktopHttpProbe.run(
      testUrl: f.url,
      proxyPort: f.proxy.port,
      timeout: const Duration(seconds: 2),
      securityContext: SecurityContext(withTrustedRoots: false),
    );
    expect(result.success, isFalse);
    expect(result.diagnostics?.stage, 'tls');
    expect(f.requests, isEmpty);
  });

  test('trusted CA does not bypass hostname verification', () async {
    final f = await fixture();
    final result = await DesktopHttpProbe.run(
      testUrl: f.url.replaceFirst('localhost', 'wrong.invalid'),
      proxyPort: f.proxy.port,
      timeout: const Duration(seconds: 2),
      securityContext: f.trust,
    );
    expect(result.success, isFalse);
    expect(result.diagnostics?.stage, 'tls');
    expect(f.requests, isEmpty);
  });

  test('the total deadline is not renewed after CONNECT', () async {
    final f = await fixture(
      connectDelay: const Duration(milliseconds: 180),
      reply: (socket, _) async {
        await Future<void>.delayed(const Duration(milliseconds: 220));
        socket.write('HTTP/1.1 204 No Content\r\n\r\n');
        await socket.flush();
      },
    );
    final result = await DesktopHttpProbe.run(
      testUrl: f.url,
      proxyPort: f.proxy.port,
      timeout: const Duration(milliseconds: 320),
      securityContext: f.trust,
    );
    expect(result.success, isFalse);
    expect(result.diagnostics?.stage, 'firstGet');
    expect(result.diagnostics!.elapsedMs, lessThan(550));
  });

  test('truncated content length cannot become a successful GET', () async {
    final f = await fixture(
      reply: (socket, _) async {
        socket.write('HTTP/1.1 200 OK\r\nContent-Length: 12\r\n\r\nshort');
        await socket.flush();
        await socket.close();
      },
    );
    final result = await DesktopHttpProbe.run(
      testUrl: f.url,
      proxyPort: f.proxy.port,
      timeout: const Duration(seconds: 2),
      securityContext: f.trust,
    );
    expect(result.success, isFalse);
    expect(result.error, contains('Truncated'));
  });
}
