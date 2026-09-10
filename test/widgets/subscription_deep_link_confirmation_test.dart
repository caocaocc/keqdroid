import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/l10n/app_localizations.dart';
import 'package:keqdroid/shared/ui/subscription_deep_link_confirmation.dart';

const _urlA = 'https://one.example.test/private-subscription?token=fixture';
const _urlB = 'https://two.example.test/subscription';

String _link(String url) => Uri(
  scheme: 'keqdroid',
  host: 'install-config',
  queryParameters: {'url': url},
).toString();

void main() {
  Future<BuildContext> host(WidgetTester tester) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (value) {
            context = value;
            return const Scaffold(body: Text('Application'));
          },
        ),
      ),
    );
    return context;
  }

  testWidgets('confirmation is required before persistence and fetch', (
    tester,
  ) async {
    final context = await host(tester);
    final writes = <String>[];
    final fetches = <String>[];
    final queue = SubscriptionDeepLinkImportQueue(
      isActive: () => context.mounted,
      readPending: () async => null,
      confirmSubscription: (url) =>
          showSubscriptionDeepLinkConfirmation(context, url),
      importLink: (raw) async {
        writes.add(raw);
        fetches.add(raw);
      },
    );

    final finished = queue.drain(raw: _link(_urlA));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('one.example.test'), findsOneWidget);
    expect(find.text(_urlA), findsOneWidget);
    expect(writes, isEmpty);
    expect(fetches, isEmpty);

    await tester.tap(find.text('Add & Fetch'));
    await tester.pumpAndSettle();
    await finished;
    expect(writes, [_link(_urlA)]);
    expect(fetches, [_link(_urlA)]);
  });

  for (final dismissal in ['Cancel', 'Escape', 'outside click']) {
    testWidgets('$dismissal never imports or fetches', (tester) async {
      final context = await host(tester);
      var imports = 0;
      final queue = SubscriptionDeepLinkImportQueue(
        isActive: () => context.mounted,
        readPending: () async => null,
        confirmSubscription: (url) =>
            showSubscriptionDeepLinkConfirmation(context, url),
        importLink: (_) async => imports++,
      );
      final finished = queue.drain(raw: _link(_urlA));
      await tester.pumpAndSettle();
      expect(imports, 0);
      switch (dismissal) {
        case 'Cancel':
          await tester.tap(find.text('Cancel'));
        case 'Escape':
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        case 'outside click':
          await tester.tapAt(const Offset(8, 8));
      }
      await tester.pumpAndSettle();
      await finished;
      expect(find.byType(AlertDialog), findsNothing);
      expect(imports, 0);
    });
  }

  testWidgets(
    'native wake events wait for each confirmation without losing links',
    (tester) async {
      final context = await host(tester);
      final pending = <String>[_link(_urlA)];
      final imported = <String>[];
      var reads = 0;
      final queue = SubscriptionDeepLinkImportQueue(
        isActive: () => context.mounted,
        readPending: () async {
          reads++;
          return pending.isEmpty ? null : pending.removeAt(0);
        },
        confirmSubscription: (url) =>
            showSubscriptionDeepLinkConfirmation(context, url),
        importLink: (raw) async => imported.add(raw),
      );

      final first = queue.drain();
      await tester.pumpAndSettle();
      pending.addAll([_link(_urlB), _link(_urlA)]);
      final second = queue.drain();
      final third = queue.drain();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text(_urlA), findsOneWidget);
      expect(reads, 1);
      expect(imported, isEmpty);

      await tester.tap(find.text('Add & Fetch'));
      await tester.pumpAndSettle();
      expect(imported, [_link(_urlA)]);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text(_urlB), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await Future.wait([first, second, third]);
      expect(pending, isEmpty);
      expect(find.byType(AlertDialog), findsNothing);
      expect(imported, [_link(_urlA)]);
    },
  );

  testWidgets('next confirmation waits until the accepted import finishes', (
    tester,
  ) async {
    final context = await host(tester);
    final pending = <String>[_link(_urlA), _link(_urlB)];
    final fetchFinished = Completer<void>();
    final imported = <String>[];
    final queue = SubscriptionDeepLinkImportQueue(
      isActive: () => context.mounted,
      readPending: () async => pending.isEmpty ? null : pending.removeAt(0),
      confirmSubscription: (url) =>
          showSubscriptionDeepLinkConfirmation(context, url),
      importLink: (raw) async {
        imported.add(raw);
        await fetchFinished.future;
      },
    );
    final finished = queue.drain();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add & Fetch'));
    await tester.pumpAndSettle();
    expect(imported, [_link(_urlA)]);
    expect(find.byType(AlertDialog), findsNothing);
    expect(pending, [_link(_urlB)]);
    fetchFinished.complete();
    await tester.pumpAndSettle();
    expect(find.text(_urlB), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await finished;
    expect(imported, [_link(_urlA)]);
  });

  testWidgets('cancelled link can be presented again in a later batch', (
    tester,
  ) async {
    final context = await host(tester);
    final imported = <String>[];
    final queue = SubscriptionDeepLinkImportQueue(
      isActive: () => context.mounted,
      readPending: () async => null,
      confirmSubscription: (url) =>
          showSubscriptionDeepLinkConfirmation(context, url),
      importLink: (raw) async => imported.add(raw),
    );
    final cancelled = queue.drain(raw: _link(_urlA));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await cancelled;
    expect(imported, isEmpty);
    final retried = queue.drain(raw: _link(_urlA));
    await tester.pumpAndSettle();
    expect(find.text(_urlA), findsOneWidget);
    await tester.tap(find.text('Add & Fetch'));
    await tester.pumpAndSettle();
    await retried;
    expect(imported, [_link(_urlA)]);
  });

  testWidgets('accepted dialog cannot import after its owner is disposed', (
    tester,
  ) async {
    final context = await host(tester);
    final decision = Completer<bool>();
    var active = true;
    var imports = 0;
    final queue = SubscriptionDeepLinkImportQueue(
      isActive: () => active && context.mounted,
      readPending: () async => null,
      confirmSubscription: (_) => decision.future,
      importLink: (_) async => imports++,
    );
    final finished = queue.drain(raw: _link(_urlA));
    await tester.pump();
    active = false;
    decision.complete(true);
    await finished;
    expect(imports, 0);
  });

  test('non-subscription links retain the existing import path', () async {
    final imported = <String>[];
    final queue = SubscriptionDeepLinkImportQueue(
      isActive: () => true,
      readPending: () async => null,
      confirmSubscription: (_) =>
          throw StateError('Must not confirm this link'),
      importLink: (raw) async => imported.add(raw),
    );
    const raw = 'vless://fixture@server.example.test:443';
    await queue.drain(raw: raw);
    expect(imported, [raw]);
  });
}
