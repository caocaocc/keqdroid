import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../tunnel/url_test_diagnostics.dart';

/// One deadline covers local connect, CONNECT, TLS and both HTTP requests.
/// A RawSocket remains owned throughout TLS upgrade, so cancellation can close
/// a handshake immediately instead of merely abandoning its Future.
class DesktopHttpProbe {
  static Future<UrlTestResult> run({
    required String testUrl,
    required int proxyPort,
    required Duration timeout,
    bool keepAlive = true,
    SecurityContext? securityContext,
    ProbeCancellation? cancellation,
  }) async {
    final deadline = _Deadline(timeout, cancellation);
    var stage = 'localConnect';
    var stageStartedMs = 0;
    final stageDurationsMs = <String, int>{};
    void beginStage(String next) {
      final elapsed = deadline.elapsedMs;
      stageDurationsMs[stage] = elapsed - stageStartedMs;
      stage = next;
      stageStartedMs = elapsed;
    }

    var completed = 0;
    int? coldMs;
    int? firstStatus;
    int? lastStatus;
    RawSocket? socket;
    RawSecureSocket? secure;
    _Wire? wire;
    UrlTestDiagnostics details(String kind, {String? warning}) {
      final elapsed = deadline.elapsedMs;
      return UrlTestDiagnostics(
        stage: stage,
        elapsedMs: elapsed,
        budgetMs: timeout.inMilliseconds,
        timingKind: kind,
        completedRequests: completed,
        warning: warning,
        stageDurationsMs: {
          ...stageDurationsMs,
          stage: elapsed - stageStartedMs,
        },
      );
    }

    try {
      final normalized = testUrl.trim().replaceFirst(
        RegExp(r'^http://', caseSensitive: false),
        'https://',
      );
      final uri = Uri.parse(normalized);
      if (uri.scheme != 'https' ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty) {
        throw const FormatException(
          'A HTTPS URL without credentials is required',
        );
      }
      final host = uri.host;
      final authorityHost = host.contains(':') ? '[$host]' : host;
      final authority = '$authorityHost:${uri.port}';
      final hostHeader = uri.port == 443 ? authorityHost : authority;
      final target =
          '${uri.path.isEmpty ? '/' : uri.path}${uri.hasQuery ? '?${uri.query}' : ''}';
      socket = await deadline.wait<RawSocket>(
        RawSocket.connect(
          InternetAddress.loopbackIPv4,
          proxyPort,
          timeout: deadline.remaining,
        ),
        onLate: (value) => unawaited(value.close()),
      );
      socket.setOption(SocketOption.tcpNoDelay, true);
      wire = _Wire(socket);
      beginStage('proxyConnect');
      await wire.write(
        'CONNECT $authority HTTP/1.1\r\nHost: $authority\r\n\r\n',
        deadline,
      );
      final tunnel = await wire.response(deadline, headOnly: true);
      if (tunnel.status < 200 || tunnel.status >= 300) {
        lastStatus = tunnel.status;
        throw HttpException('Proxy CONNECT returned HTTP ${tunnel.status}');
      }
      beginStage('tls');
      final subscription = wire.release();
      secure = await deadline.wait<RawSecureSocket>(
        RawSecureSocket.secure(
          socket,
          subscription: subscription,
          host: host,
          context: securityContext,
          supportedProtocols: const ['http/1.1'],
        ),
        onLate: (value) => unawaited(value.close()),
      );
      wire = _Wire(secure);
      for (var attempt = 0; attempt < (keepAlive ? 2 : 1); attempt++) {
        beginStage(attempt == 0 ? 'firstGet' : 'warmGet');
        final started = deadline.elapsedMs;
        await wire.write(
          'GET $target HTTP/1.1\r\nHost: $hostHeader\r\n'
          'User-Agent: KEQDIS/1.0\r\nAccept: */*\r\n'
          'Connection: ${keepAlive ? 'keep-alive' : 'close'}\r\n\r\n',
          deadline,
        );
        final response = await wire.response(deadline);
        lastStatus = response.status;
        if (response.status < 200 || response.status >= 400) {
          throw HttpException('HTTP ${response.status}');
        }
        completed++;
        if (attempt == 0) {
          coldMs = deadline.elapsedMs;
          firstStatus = response.status;
        } else {
          return (
            success: true,
            latencyMs: deadline.elapsedMs - started,
            error: '',
            httpStatus: response.status,
            diagnostics: details('warm'),
          );
        }
        if (!keepAlive || response.closing) {
          return (
            success: true,
            latencyMs: coldMs,
            error: '',
            httpStatus: firstStatus,
            diagnostics: details(
              keepAlive ? 'coldFallback' : 'cold',
              warning: keepAlive
                  ? 'The server closed the connection; the first complete request is shown.'
                  : null,
            ),
          );
        }
      }
      throw StateError('No HTTP result');
    } catch (error) {
      final reason = error is TimeoutException
          ? 'GET probe timed out at $stage (${deadline.elapsedMs} ms; total budget ${timeout.inMilliseconds} ms)'
          : 'GET probe failed at $stage: $error';
      if (coldMs != null && error is! ProbeCancelled) {
        return (
          success: true,
          latencyMs: coldMs,
          error: '',
          httpStatus: firstStatus,
          diagnostics: details('coldFallback', warning: reason),
        );
      }
      return (
        success: false,
        latencyMs: null,
        error: reason,
        httpStatus: lastStatus,
        diagnostics: details('cold'),
      );
    } finally {
      // Close the original raw transport even when TLS has not completed yet.
      if (socket != null) unawaited(socket.close());
      if (secure != null) unawaited(secure.close());
      await wire?.close();
    }
  }
}

class ProbeCancelled implements Exception {
  const ProbeCancelled();
  @override
  String toString() => 'Probe cancelled';
}

class ProbeCancellation {
  final _cancelled = Completer<void>();
  bool get isCancelled => _cancelled.isCompleted;
  void cancel() {
    if (!isCancelled) _cancelled.complete();
  }
}

class _Deadline {
  final Duration budget;
  final ProbeCancellation? cancellation;
  final Stopwatch _clock = Stopwatch()..start();
  _Deadline(this.budget, this.cancellation);
  int get elapsedMs => _clock.elapsedMilliseconds;
  Duration get remaining => budget - _clock.elapsed;
  Future<T> wait<T>(Future<T> future, {void Function(T)? onLate}) async {
    var abandoned = false;
    final owned = future.then((value) {
      if (abandoned) onLate?.call(value);
      return value;
    });
    try {
      if (cancellation?.isCancelled == true) throw const ProbeCancelled();
      final left = remaining;
      if (left <= Duration.zero) throw TimeoutException('probe deadline');
      return await Future.any<T>([
        owned,
        if (cancellation != null)
          cancellation!._cancelled.future.then<T>(
            (_) => throw const ProbeCancelled(),
          ),
      ]).timeout(left);
    } catch (_) {
      abandoned = true;
      // Observe late failure even if the deadline expired before Future.any.
      unawaited(owned.then<void>((_) {}, onError: (Object _) {}));
      rethrow;
    }
  }
}

class _Wire {
  final RawSocket socket;
  late final StreamSubscription<RawSocketEvent> _subscription;
  final List<int> _buffer = [];
  Completer<void>? _readable;
  Completer<void>? _writable;
  Object? _error;
  bool _done = false;
  bool _released = false;
  static const _maxHeader = 64 * 1024;
  static const _maxBody = 2 * 1024 * 1024;

  _Wire(this.socket) {
    _subscription = socket.listen(
      (event) {
        if (event == RawSocketEvent.read) {
          final data = socket.read();
          if (data != null) _buffer.addAll(data);
          // Bounded buffering also protects a peer that sends unsolicited data.
          if (_buffer.length > _maxBody + _maxHeader) {
            _error = const FormatException('HTTP response exceeds probe limit');
            socket.close();
          }
          _wakeRead();
        } else if (event == RawSocketEvent.write) {
          socket.writeEventsEnabled = false;
          _writable?.complete();
          _writable = null;
        } else if (event == RawSocketEvent.readClosed) {
          _done = true;
          _wakeRead();
        }
      },
      onError: (Object error) {
        _error = error;
        _wakeRead();
        _writable?.complete();
        _writable = null;
      },
      onDone: () {
        _done = true;
        _wakeRead();
        _writable?.complete();
        _writable = null;
      },
    );
    socket.readEventsEnabled = true;
    socket.writeEventsEnabled = false;
  }

  void _wakeRead() {
    _readable?.complete();
    _readable = null;
  }

  Future<void> write(String message, _Deadline deadline) async {
    final bytes = utf8.encode(message);
    var offset = 0;
    while (offset < bytes.length) {
      if (_error != null) throw _error!;
      if (_done) throw const SocketException('Connection closed');
      if (deadline.cancellation?.isCancelled == true) {
        throw const ProbeCancelled();
      }
      if (deadline.remaining <= Duration.zero) throw TimeoutException('write');
      final count = socket.write(bytes, offset);
      if (count > 0) {
        offset += count;
        continue;
      }
      final ready = _writable ??= Completer<void>();
      socket.writeEventsEnabled = true;
      await deadline.wait(ready.future);
    }
  }

  Future<void> _more(_Deadline deadline) async {
    if (_error != null) throw _error!;
    if (_done) throw const SocketException('Truncated HTTP response');
    await deadline.wait((_readable ??= Completer<void>()).future);
  }

  int _find(List<int> needle) {
    for (var i = 0; i + needle.length <= _buffer.length; i++) {
      var matches = true;
      for (var j = 0; j < needle.length; j++) {
        if (_buffer[i + j] != needle[j]) {
          matches = false;
          break;
        }
      }
      if (matches) return i;
    }
    return -1;
  }

  Future<String> _line(_Deadline deadline) async {
    var end = -1;
    while ((end = _find(const [13, 10])) < 0) {
      if (_buffer.length > _maxHeader) {
        throw const FormatException('HTTP line too long');
      }
      await _more(deadline);
    }
    if (end > _maxHeader) throw const FormatException('HTTP line too long');
    final line = String.fromCharCodes(_buffer.sublist(0, end));
    _buffer.removeRange(0, end + 2);
    return line;
  }

  Future<({int status, bool closing})> response(
    _Deadline deadline, {
    bool headOnly = false,
  }) async {
    if (_error != null) throw _error!;
    for (var interim = 0; interim < 9; interim++) {
      final first = await _line(deadline);
      final statusLine = RegExp(
        r'^HTTP/(1\.[01]) ([0-9]{3})(?: |$)',
      ).firstMatch(first);
      if (statusLine == null) {
        throw const FormatException('Invalid HTTP status line');
      }
      final status = int.parse(statusLine.group(2)!);
      final headers = <String, List<String>>{};
      var headerBytes = first.length;
      while (true) {
        final line = await _line(deadline);
        headerBytes += line.length + 2;
        if (headerBytes > _maxHeader) {
          throw const FormatException('HTTP headers too large');
        }
        if (line.isEmpty) break;
        final colon = _headerColon(line);
        headers
            .putIfAbsent(line.substring(0, colon).toLowerCase(), () => [])
            .add(line.substring(colon + 1).trim());
      }
      if (status == 101) {
        throw const FormatException('Unexpected protocol upgrade');
      }
      if (status >= 100 && status < 200) continue;
      if (status < 200 || status > 599) {
        throw const FormatException('Invalid HTTP status');
      }
      final connection = (headers['connection'] ?? [])
          .join(',')
          .toLowerCase()
          .split(',')
          .map((v) => v.trim())
          .toSet();
      var closing =
          connection.contains('close') ||
          (statusLine.group(1) == '1.0' && !connection.contains('keep-alive'));
      if (headOnly || status == 204 || status == 304) {
        return (status: status, closing: closing);
      }
      final transfer = (headers['transfer-encoding'] ?? [])
          .join(',')
          .toLowerCase();
      final lengths = (headers['content-length'] ?? [])
          .expand((v) => v.split(','))
          .map((v) => v.trim())
          .toSet();
      if (transfer.isNotEmpty) {
        if (transfer != 'chunked' || lengths.isNotEmpty) {
          throw const FormatException('Unsupported HTTP response framing');
        }
        await _chunks(deadline);
      } else if (lengths.isNotEmpty) {
        final length =
            lengths.length == 1 && RegExp(r'^[0-9]+$').hasMatch(lengths.single)
            ? int.tryParse(lengths.single)
            : null;
        if (length == null || length < 0 || length > _maxBody) {
          throw const FormatException('Invalid HTTP content length');
        }
        await _drain(length, deadline);
      } else {
        closing = true; // HTTP response body is delimited by EOF.
        var total = 0;
        while (true) {
          total += _buffer.length;
          _buffer.clear();
          if (total > _maxBody) {
            throw const FormatException('HTTP body too large');
          }
          if (_error != null) throw _error!;
          if (_done) break;
          await _more(deadline);
        }
      }
      return (status: status, closing: closing);
    }
    throw const FormatException('Too many interim HTTP responses');
  }

  Future<void> _drain(int count, _Deadline deadline) async {
    while (count > 0) {
      if (_buffer.isEmpty) await _more(deadline);
      final take = count < _buffer.length ? count : _buffer.length;
      _buffer.removeRange(0, take);
      count -= take;
    }
  }

  static int _headerColon(String line) {
    final colon = line.indexOf(':');
    if (colon <= 0 ||
        !RegExp(
          r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$",
        ).hasMatch(line.substring(0, colon)) ||
        line
            .substring(colon + 1)
            .codeUnits
            .any((value) => (value < 32 && value != 9) || value == 127)) {
      throw const FormatException('Invalid HTTP header');
    }
    return colon;
  }

  Future<void> _chunks(_Deadline deadline) async {
    var total = 0;
    while (true) {
      final line = await _line(deadline);
      final number = line.split(';').first.trim();
      if (!RegExp(r'^[0-9a-fA-F]+$').hasMatch(number)) {
        throw const FormatException('Invalid HTTP chunk length');
      }
      final size = int.tryParse(number, radix: 16);
      if (size == null || size > _maxBody - total) {
        throw const FormatException('HTTP body too large');
      }
      total += size;
      if (size == 0) {
        var trailers = 0;
        while (true) {
          final trailer = await _line(deadline);
          trailers += trailer.length + 2;
          if (trailers > _maxHeader) {
            throw const FormatException('HTTP trailers too large');
          }
          if (trailer.isEmpty) return;
          _headerColon(trailer);
        }
      }
      await _drain(size, deadline);
      if (await _line(deadline) != '') {
        throw const FormatException('Invalid HTTP chunk terminator');
      }
    }
  }

  StreamSubscription<RawSocketEvent> release() {
    if (_buffer.isNotEmpty) {
      throw const FormatException('Unexpected bytes after CONNECT');
    }
    _released = true;
    return _subscription;
  }

  Future<void> close() async {
    if (!_released) {
      await socket.close();
      await _subscription.cancel();
    }
  }
}
