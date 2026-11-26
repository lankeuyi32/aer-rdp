import 'package:aer_rdp/models/connection_profile.dart';
import 'package:aer_rdp/models/session_models.dart';
import 'package:aer_rdp/services/cert_trust_store.dart';
import 'package:aer_rdp/services/demo_rdp_session_client.dart';
import 'package:aer_rdp/services/scancode_mapper.dart';
import 'package:aer_rdp/ui/aer_keys.dart';
import 'package:aer_rdp/ui/session/session_page.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  group('ScancodeMapper', () {
    test('maps letters, arrows, and iPad Cmd/Option keys accurately', () {
      expect(
        ScancodeMapper.mapLogicalKey(LogicalKeyboardKey.keyA),
        const ScancodeSpec(0x1E),
      );
      expect(
        ScancodeMapper.mapLogicalKey(LogicalKeyboardKey.arrowRight),
        const ScancodeSpec(0x4D, extended: true),
      );
      expect(
        ScancodeMapper.mapLogicalKey(LogicalKeyboardKey.metaLeft),
        const ScancodeSpec(0x5B, extended: true),
      );
      expect(
        ScancodeMapper.mapLogicalKey(LogicalKeyboardKey.altLeft),
        const ScancodeSpec(0x38),
      );
      expect(
        ScancodeMapper.mapLogicalKey(LogicalKeyboardKey.f5),
        const ScancodeSpec(0x3F),
      );
    });

    test('returns null safely for unmapped media/hardware keys', () {
      expect(
        ScancodeMapper.mapLogicalKey(LogicalKeyboardKey.audioVolumeUp),
        isNull,
      );
    });

    test('encodes CJK and emoji surrogate pairs into UTF-16 code units', () {
      final units = ScancodeMapper.encodeTextToUtf16Units('A你🚀');
      // 'A' = 0x0041, '你' = 0x4F60, '🚀' = U+1F680 -> 0xD83D, 0xDE80
      expect(units, <int>[0x0041, 0x4F60, 0xD83D, 0xDE80]);
    });

    test('maps ASCII printable characters to scancodes and returns null for non-ASCII', () {
      final lowerA = ScancodeMapper.mapAsciiChar('a'.codeUnitAt(0));
      expect(lowerA?.spec, const ScancodeSpec(0x1E));
      expect(lowerA?.shift, isFalse);

      final upperA = ScancodeMapper.mapAsciiChar('A'.codeUnitAt(0));
      expect(upperA?.spec, const ScancodeSpec(0x1E));
      expect(upperA?.shift, isTrue);

      final bang = ScancodeMapper.mapAsciiChar('!'.codeUnitAt(0));
      expect(bang?.spec, const ScancodeSpec(0x02));
      expect(bang?.shift, isTrue);

      expect(ScancodeMapper.mapAsciiChar('你'.runes.first), isNull);
    });
  });

  group('SessionPage IME & textInputMode', () {
    Future<DemoRdpSessionController> pumpSessionWithTextMode(
      WidgetTester tester,
      TextInputMode textInputMode,
    ) async {
      final profile = ConnectionProfile(
        id: 'ime-${textInputMode.name}',
        name: 'IME',
        host: '127.0.0.1',
        authMode: AuthMode.saved,
        inputConfig: InputConfig(textInputMode: textInputMode),
      );
      final controller = DemoRdpSessionController(
        request: ConnectRequest(
          profile: profile,
          initialCredentials:
              const AuthCredentials(username: 'u', password: 'pw'),
          pinnedCertSha256: DemoRdpSessionClient.defaultDemoFingerprint,
        ),
        serverFingerprint: DemoRdpSessionClient.defaultDemoFingerprint,
      );
      controller.start();
      addTearDown(controller.dispose);
      final trust = CertTrustStore.inMemory();
      addTearDown(trust.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: SessionPage(
            profile: profile,
            controller: controller,
            certTrustStore: trust,
            onEnded: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(AerKeys.commandBarPill));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(AerKeys.commandBarKeyboard));
      await tester.pumpAndSettle();
      return controller;
    }

    testWidgets(
        'IME backspace ab->a->empty and replacement teh->the emit Backspace scancodes',
        (WidgetTester tester) async {
      final controller =
          await pumpSessionWithTextMode(tester, TextInputMode.unicode);

      tester.testTextInput.enterText('ab');
      await tester.pump();
      expect(
        controller.recordedInputs
            .where((e) => e.kind == 'unicode' && e.down)
            .map((e) => e.codeUnit)
            .toList(),
        <int>[97, 98],
      );

      controller.recordedInputs.clear();
      tester.testTextInput.enterText('a');
      await tester.pump();
      expect(
        controller.recordedInputs
            .where((e) => e.kind == 'scancode')
            .map((e) => (e.code, e.down))
            .toList(),
        <(int, bool)>[(0x0E, true), (0x0E, false)],
      );
      expect(
        controller.recordedInputs.where((e) => e.kind == 'unicode'),
        isEmpty,
      );

      controller.recordedInputs.clear();
      tester.testTextInput.enterText('');
      await tester.pump();
      expect(
        controller.recordedInputs
            .where((e) => e.kind == 'scancode')
            .map((e) => (e.code, e.down))
            .toList(),
        <(int, bool)>[(0x0E, true), (0x0E, false)],
      );

      controller.recordedInputs.clear();
      tester.testTextInput.enterText('teh');
      await tester.pump();
      controller.recordedInputs.clear();
      tester.testTextInput.enterText('the');
      await tester.pump();
      expect(
        controller.recordedInputs
            .where((e) => e.kind == 'scancode')
            .map((e) => (e.code, e.down))
            .toList(),
        <(int, bool)>[
          (0x0E, true),
          (0x0E, false),
          (0x0E, true),
          (0x0E, false),
        ],
      );
      expect(
        controller.recordedInputs
            .where((e) => e.kind == 'unicode' && e.down)
            .map((e) => e.codeUnit)
            .toList(),
        <int>[104, 101], // 'h', 'e'
      );
    });

    testWidgets(
        'TextInputMode.scancode emits scancodes for ASCII and falls back to sendUnicode for CJK/emoji',
        (WidgetTester tester) async {
      final controller =
          await pumpSessionWithTextMode(tester, TextInputMode.scancode);

      tester.testTextInput.enterText('A你🚀');
      await tester.pump();

      final scancodes = controller.recordedInputs
          .where((e) => e.kind == 'scancode')
          .map((e) => (e.code, e.down))
          .toList();
      expect(
        scancodes,
        <(int, bool)>[
          (0x2A, true),
          (0x1E, true),
          (0x1E, false),
          (0x2A, false),
        ],
      );

      final unicodes = controller.recordedInputs
          .where((e) => e.kind == 'unicode' && e.down)
          .map((e) => e.codeUnit)
          .toList();
      expect(unicodes, <int>[0x4F60, 0xD83D, 0xDE80]);
    });
  });
}
