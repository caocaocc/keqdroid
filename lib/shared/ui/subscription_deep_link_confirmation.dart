import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:keqdroid/l10n/app_localizations.dart';
import 'package:keqdroid/utils/subscription_deep_link.dart';

/// Shows the destination locally, without fetching or persisting the URL.
Future<bool> showSubscriptionDeepLinkConfirmation(
  BuildContext context,
  String url,
) async {
  final l10n = AppLocalizations.of(context)!;
  return await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(l10n.subscriptionsAddSubscription),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  Uri.tryParse(url)?.host ?? '',
                  textDirection: TextDirection.ltr,
                  style: Theme.of(dialogContext).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                Text(l10n.subscriptionUrlLabel),
                SelectableText(url, textDirection: TextDirection.ltr),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(
                MaterialLocalizations.of(dialogContext).cancelButtonLabel,
              ),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(l10n.subscriptionsAddAndFetch),
            ),
          ],
        ),
      ) ==
      true;
}

/// Used only by the macOS entry points. Other platforms keep their existing
/// import behavior. A native wake can arrive while a dialog is open: it must
/// not consume the next native link until the current decision has completed.
class SubscriptionDeepLinkImportQueue {
  SubscriptionDeepLinkImportQueue({
    required this.isActive,
    required this.readPending,
    required this.confirmSubscription,
    required this.importLink,
  });

  final bool Function() isActive;
  final Future<String?> Function() readPending;
  final Future<bool> Function(String url) confirmSubscription;
  final Future<void> Function(String raw) importLink;

  final _direct = Queue<String>();
  Future<void>? _draining;
  bool _wakeRequested = false;

  Future<void> drain({String? raw}) {
    if (!isActive()) return Future<void>.value();
    final trimmed = raw?.trim();
    if (trimmed != null && trimmed.isNotEmpty) _direct.add(trimmed);
    _wakeRequested = true;
    if (_draining != null) return _draining!;

    final completed = Completer<void>();
    _draining = completed.future;
    unawaited(
      _run().then<void>(
        (_) => completed.complete(),
        onError: completed.completeError,
      ),
    );
    return completed.future;
  }

  Future<void> _run() async {
    // The native duplicate window is short. Keep duplicates suppressed for
    // this whole batch, including the time the user spends deciding.
    final seen = <String>{};
    try {
      do {
        _wakeRequested = false;
        while (isActive()) {
          final raw = _direct.isNotEmpty
              ? _direct.removeFirst()
              : await readPending();
          if (!isActive() || raw == null) break;
          final trimmed = raw.trim();
          if (trimmed.isEmpty || !seen.add(trimmed)) continue;
          final url = subscriptionUrlFromDeepLink(trimmed);
          if (url != null && !await confirmSubscription(url)) continue;
          if (isActive()) await importLink(trimmed);
        }
      } while (_wakeRequested && isActive());
    } finally {
      _draining = null;
      if (!isActive()) _direct.clear();
    }
  }
}
