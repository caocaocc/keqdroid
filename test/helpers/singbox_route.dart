import 'dart:convert';

import 'package:keqdroid/utils/singbox_tun_config.dart';

/// Куда в итоге уходит трафик, не совпавший ни с одним правилом sing-box.
///
/// Блок `final` записать не может — там только тег выхода, — поэтому он живёт
/// последним правилом без условий, а `final` в конфиге тогда нет.
String effectiveRouteFinal(String json) {
  final route = (jsonDecode(json) as Map<String, dynamic>)['route'] as Map;
  final rules = (route['rules'] as List).cast<Map<String, dynamic>>();
  if (!route.containsKey('final') &&
      rules.isNotEmpty &&
      rules.last.length == kSingboxBlockAction.length &&
      kSingboxBlockAction.entries.every((e) => rules.last[e.key] == e.value)) {
    return 'block';
  }
  return route['final'] as String;
}

/// Правило sing-box блокирует — действием, а не выходом `block`.
bool isSingboxBlockRule(Map<String, dynamic> rule) =>
    kSingboxBlockAction.entries.every((e) => rule[e.key] == e.value);
