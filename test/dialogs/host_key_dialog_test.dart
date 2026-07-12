import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/dialogs/host_key_dialog.dart';
import 'package:ssterm/models/known_hosts_store.dart';

void main() {
  const existing = KnownHostEntry(
    hostname: 'example.com',
    port: 22,
    keyType: 'ssh-ed25519',
    fingerprint: 'aabbcc',
  );

  // showHostKeyChangedDialog must be triggered from an event handler, not
  // from a widget's build() — calling it directly inside Builder.builder
  // trips Flutter's `!navigator._debugLocked` assertion (Navigator.push
  // during a build/layout pass is unsafe). A button press mirrors how the
  // real app invokes it (from createHostKeyVerifier's async callback).
  Future<Future<bool>> pumpDialog(WidgetTester tester) async {
    late Future<bool> resultFuture;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () {
            resultFuture = showHostKeyChangedDialog(
              context,
              hostname: 'example.com',
              port: 22,
              existing: existing,
              keyType: 'ssh-ed25519',
              fingerprint: 'ddeeff',
            );
          },
          child: const Text('open dialog'),
        ),
      ),
    ));
    await tester.tap(find.text('open dialog'));
    await tester.pumpAndSettle();
    return resultFuture;
  }

  group('showHostKeyChangedDialog', () {
    testWidgets('shows the warning title and both action buttons',
        (tester) async {
      await pumpDialog(tester);

      expect(find.text('Host Key Changed'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      expect(find.text('Update Key and Connect'), findsOneWidget);
    });

    testWidgets('Cancel resolves the future to false', (tester) async {
      final resultFuture = await pumpDialog(tester);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(await resultFuture, isFalse);
    });

    testWidgets('"Update Key and Connect" resolves the future to true',
        (tester) async {
      final resultFuture = await pumpDialog(tester);

      await tester.tap(find.text('Update Key and Connect'));
      await tester.pumpAndSettle();

      expect(await resultFuture, isTrue);
    });
  });
}
