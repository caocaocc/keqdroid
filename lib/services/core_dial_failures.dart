// двойник is_server_dial_failure из forkexec.c, правила обязаны совпадать
abstract final class CoreDialFailures {
  static int _count = 0;

  static int get count => _count;

  /// Native session readers report only new failures, never the rolling log.
  static void add(int failures) {
    if (failures > 0) _count += failures;
  }

  /// Строка вывода ядра сессии: если это отказ дозвона до сервера — считаем.
  static void observe(String line) {
    if (isServerDialFailure(line)) _count++;
  }

  // UDP не считаем: сервер без UDP отвечает отказом на каждый QUIC
  static bool isServerDialFailure(String line) {
    if (line.contains('failed to find an available destination')) return true;

    final xhttp = line.indexOf('splithttp: ');
    if (xhttp >= 0) {
      final what = line.substring(xhttp + 'splithttp: '.length);
      if (what.startsWith('failed to create')) return false;
      return what.startsWith('failed to ') ||
          what.startsWith('unexpected status ');
    }

    final dial = line.indexOf('[TCP] dial ');
    if (dial >= 0) {
      if (!line.contains(' error: ')) return false;
      final target = line.substring(dial + '[TCP] dial '.length);
      return !target.startsWith('DIRECT') && !target.startsWith('REJECT');
    }

    if (line.contains('open connection to ') &&
        line.contains(' using outbound/')) {
      return !line.contains('outbound/direct[') &&
          !line.contains('outbound/block[');
    }
    return false;
  }
}
