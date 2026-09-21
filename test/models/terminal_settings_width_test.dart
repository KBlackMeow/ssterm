import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/models/terminal_settings.dart';
import 'package:xterm/xterm.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TerminalSettings width policy persistence', () {
    test('defaults to modern widths with narrow ambiguous characters', () {
      final settings = TerminalSettings();
      expect(settings.widthProfile, equals('modern'));
      expect(settings.ambiguousDoubleWidth, isFalse);
      expect(terminalWidthPolicy.profile, equals(WidthProfile.modern));
    });

    test('round-trips width settings through JSON', () {
      final settings = TerminalSettings.fromJson(
        TerminalSettings(
          widthProfile: 'legacy',
          ambiguousDoubleWidth: true,
        ).toJson(),
      );
      expect(settings.widthProfile, equals('legacy'));
      expect(settings.ambiguousDoubleWidth, isTrue);
    });

    test('rejects unknown profile values and keeps the safe default', () {
      final settings = TerminalSettings.fromJson({
        'widthProfile': 'unicode-8',
        'ambiguousDoubleWidth': 'yes',
      });
      expect(settings.widthProfile, equals('modern'));
      expect(settings.ambiguousDoubleWidth, isFalse);
    });

    test(
      'applyTerminalWidthSettings pushes settings into the shared policy',
      () {
        applyTerminalWidthSettings(
          TerminalSettings(widthProfile: 'legacy', ambiguousDoubleWidth: true),
        );
        expect(terminalWidthPolicy.profile, equals(WidthProfile.legacy));
        expect(terminalWidthPolicy.ambiguousDoubleWidth, isTrue);

        // Back to defaults so other tests in this isolate stay deterministic.
        applyTerminalWidthSettings(TerminalSettings());
        expect(terminalWidthPolicy.profile, equals(WidthProfile.modern));
      },
    );
  });
}
