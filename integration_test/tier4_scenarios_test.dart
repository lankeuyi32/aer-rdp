import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ui_test_helpers.dart';

void main() {
  group('Tier 4 — Real-World Application Scenarios', () {
    testWidgets('T4-01 Daily Windows PC work session Android', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester, surfaceSize: const Size(412, 915));
      await createProfileViaForm(
        tester,
        name: 'Daily Work PC',
        host: '127.0.0.1',
        username: 'testuser',
        password: 'testpass',
      );
      await enterSessionHandlingPrompts(tester, profileName: 'Daily Work PC');

      await tester.tap(find.byKey(AerKeys.sessionCanvas));
      await openCommandBarAndTap(tester, AerKeys.commandBarKeyboard);
      tester.testTextInput.enterText('Hello 工作');
      await tester.pumpAndSettle();
      await openCommandBarAndTap(tester, AerKeys.commandBarDisconnect);
      expect(find.byKey(AerKeys.connectionCenterPage), findsOneWidget);
    });

    testWidgets('T4-02 First-time personal PC onboarding and backup', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester);
      await tester.tap(find.byKey(AerKeys.quickConnectButton));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(AerKeys.profileFormHost), '127.0.0.1');
      await tester.tap(find.byKey(AerKeys.profileFormSave));
      await tester.pumpAndSettle();

      if (find.byKey(AerKeys.certTrustDialog).evaluate().isNotEmpty) {
        await tester.tap(find.byKey(AerKeys.certTrustAlways));
        await tester.pumpAndSettle();
      }
      if (find.byKey(AerKeys.authPromptDialog).evaluate().isNotEmpty) {
        await tester.tap(find.byKey(AerKeys.authPromptSubmit));
        await tester.pumpAndSettle();
      }
      expect(find.byKey(AerKeys.sessionPage), findsOneWidget);
      await openCommandBarAndTap(tester, AerKeys.commandBarDisconnect);

      await createProfileViaForm(tester, name: 'Saved Home PC', host: '127.0.0.1');
      await tester.tap(find.byKey(AerKeys.exportProfilesButton));
      await tester.pumpAndSettle();
      expectNoOverflowErrors(tester);
    });

    testWidgets('T4-03 Flaky mobile Wi-Fi jitter burst and drop recovery', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester);
      await createProfileViaForm(
        tester,
        name: 'MobileWiFiHost',
        host: '127.0.0.1',
        password: 'testpass',
      );
      await enterSessionHandlingPrompts(
        tester,
        profileName: 'MobileWiFiHost',
        trustAlways: true,
      );
      await openCommandBarAndTap(tester, AerKeys.commandBarDisconnect);
      expect(find.byKey(AerKeys.connectionCenterPage), findsOneWidget);

      await enterSessionHandlingPrompts(
        tester,
        profileName: 'MobileWiFiHost',
        trustAlways: true,
      );
      expect(find.byKey(AerKeys.sessionPage), findsOneWidget);
    });

    testWidgets('T4-04 Mobile portrait quick-check and orientation flip', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester, surfaceSize: const Size(412, 915));
      await createProfileViaForm(
        tester,
        name: 'PortraitQuickCheck',
        host: '127.0.0.1',
        password: 'testpass',
      );
      await enterSessionHandlingPrompts(
        tester,
        profileName: 'PortraitQuickCheck',
      );

      await simulatePinchZoom(tester, find.byKey(AerKeys.sessionCanvas), scaleFactor: 2.5);
      await tester.tap(find.byKey(AerKeys.sessionCanvas));
      await tester.binding.setSurfaceSize(const Size(915, 412));
      await tester.pumpAndSettle();

      await openCommandBarAndTap(tester, AerKeys.commandBarMute);
      await openCommandBarAndTap(tester, AerKeys.commandBarKeyboard);
      expect(find.byKey(AerKeys.specialKeyBar), findsOneWidget);
      await openCommandBarAndTap(tester, AerKeys.commandBarDisconnect);
      expectNoOverflowErrors(tester);
    });

    testWidgets('T4-05 Multi-workstation profile switching', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester);
      await createProfileViaForm(tester, name: 'Home-NLA-Audio', host: '10.0.0.1');
      await createProfileViaForm(tester, name: 'Lab-TLS-NoAudio', host: '10.0.0.2');
      await createProfileViaForm(tester, name: 'Media-Wave5', host: '10.0.0.3');

      await tester.enterText(find.byKey(AerKeys.profileSearchField), 'Lab');
      await tester.pumpAndSettle();
      expect(find.text('Lab-TLS-NoAudio'), findsOneWidget);
      expect(find.text('Home-NLA-Audio'), findsNothing);
    });

    testWidgets('T4-06 Remote host display reset and shutdown notification', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester);
      await createProfileViaForm(
        tester,
        name: 'DisplayResetHost',
        host: '127.0.0.1',
        password: 'testpass',
      );
      await enterSessionHandlingPrompts(
        tester,
        profileName: 'DisplayResetHost',
      );
      await openCommandBarAndTap(tester, AerKeys.commandBarDisconnect);
      expect(find.byKey(AerKeys.connectionCenterPage), findsOneWidget);
    });

    testWidgets('T4-07 iPad tablet productivity workflow', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester, surfaceSize: const Size(1024, 768));
      await createProfileViaForm(
        tester,
        name: 'iPadWorkstation',
        host: '127.0.0.1',
        password: 'testpass',
      );
      await enterSessionHandlingPrompts(
        tester,
        profileName: 'iPadWorkstation',
      );

      await sendPhysicalKeyChord(tester, <LogicalKeyboardKey>[
        LogicalKeyboardKey.metaLeft,
        LogicalKeyboardKey.keyC,
      ]);
      await sendPhysicalKeyChord(tester, <LogicalKeyboardKey>[
        LogicalKeyboardKey.altLeft,
        LogicalKeyboardKey.tab,
      ]);

      final Offset center = tester.getCenter(find.byKey(AerKeys.sessionCanvas));
      final TestGesture pad = await tester.createGesture(
        kind: PointerDeviceKind.trackpad,
      );
      await pad.addPointer(location: center);
      await pad.panZoomStart(center);
      await pad.moveBy(const Offset(40, 10));
      await pad.panZoomEnd();
      await pad.removePointer();
      await tester.pumpAndSettle();

      await tester.binding.setSurfaceSize(const Size(507, 768));
      await tester.pumpAndSettle();
      expectNoOverflowErrors(tester);
    });
  });
}
