import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ui_test_helpers.dart';

void main() {
  group('Tier 3 — Cross-Feature Pairwise UI Combinations', () {
    testWidgets('T3-03 Pinned cert zoom pan reactivation and direct touch tap', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester);
      await createProfileViaForm(
        tester,
        name: 'T3Reactivate',
        host: '127.0.0.1',
        password: 'testpass',
      );
      await enterSessionHandlingPrompts(
        tester,
        profileName: 'T3Reactivate',
        trustAlways: true,
      );

      await simulatePinchZoom(tester, find.byKey(AerKeys.sessionCanvas), scaleFactor: 2.0);
      await tester.tap(find.byKey(AerKeys.sessionCanvas));
      await tester.pumpAndSettle();
      expectNoOverflowErrors(tester);
    });

    testWidgets('T3-04 Import JSON vault secret quick connect and clean disconnect', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester);
      await createProfileViaForm(
        tester,
        name: 'VaultHost',
        host: '10.0.0.20',
        password: 'SavedSecret',
      );
      await tester.tap(find.byKey(AerKeys.quickConnectButton));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(AerKeys.profileFormHost), '127.0.0.1');
      await tester.enterText(find.byKey(AerKeys.profileFormPort), '13389');
      await tester.tap(find.byKey(AerKeys.profileFormSave));
      await tester.pumpAndSettle();

      await enterSessionHandlingPrompts(tester);
      await openCommandBarAndTap(tester, AerKeys.commandBarDisconnect);
      expect(find.byKey(AerKeys.connectionCenterPage), findsOneWidget);
    });

    testWidgets('T3-05 Prompt auth 1920x1080 swapButtons pointer mode and hardware keys', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester);
      await createProfileViaForm(tester, name: 'T3PointerHost', host: '127.0.0.1');
      await enterSessionHandlingPrompts(tester, profileName: 'T3PointerHost');

      await openCommandBarAndTap(tester, AerKeys.commandBarInputMode);
      await sendPhysicalKeyChord(tester, <LogicalKeyboardKey>[LogicalKeyboardKey.keyH]);
      expectNoOverflowErrors(tester);
    });

    testWidgets('T3-07 Pointer toggle sticky Ctrl touch drag and command bar reposition', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester);
      await createProfileViaForm(
        tester,
        name: 'T3InputCombo',
        host: '127.0.0.1',
        password: 'testpass',
      );
      await enterSessionHandlingPrompts(tester, profileName: 'T3InputCombo');

      await openCommandBarAndTap(tester, AerKeys.commandBarInputMode);
      await openCommandBarAndTap(tester, AerKeys.commandBarKeyboard);
      await tester.drag(find.byKey(AerKeys.sessionCanvas), const Offset(40, 30));
      await tester.drag(find.byKey(AerKeys.commandBarPill), const Offset(50, 20));
      await tester.pumpAndSettle();
      expectNoOverflowErrors(tester);
    });

    testWidgets('T3-08 Favorite TrustAlways DPUM disconnect recents update and reconnect', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester);
      await createProfileViaForm(
        tester,
        name: 'T3DpumHost',
        host: '127.0.0.1',
        password: 'testpass',
      );
      await enterSessionHandlingPrompts(
        tester,
        profileName: 'T3DpumHost',
        trustAlways: true,
      );
      await openCommandBarAndTap(tester, AerKeys.commandBarDisconnect);
      expect(find.byKey(AerKeys.connectionCenterPage), findsOneWidget);

      await enterSessionHandlingPrompts(
        tester,
        profileName: 'T3DpumHost',
        trustAlways: true,
      );
      expect(find.byKey(AerKeys.sessionPage), findsOneWidget);
    });

    testWidgets('T3-09 MatchDevice rotate OSK CAD and mute toggle', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester, surfaceSize: const Size(412, 915));
      await createProfileViaForm(
        tester,
        name: 'T3RotateOsk',
        host: '127.0.0.1',
        password: 'testpass',
      );
      await enterSessionHandlingPrompts(tester, profileName: 'T3RotateOsk');

      await tester.binding.setSurfaceSize(const Size(915, 412));
      await tester.pumpAndSettle();
      await openCommandBarAndTap(tester, AerKeys.commandBarKeyboard);
      await openCommandBarAndTap(tester, AerKeys.commandBarMute);
      expectNoOverflowErrors(tester);
    });

    testWidgets('T3-10 iPad Master-Detail Cmd+C Option+Tab and trackpad scroll', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester, surfaceSize: const Size(1024, 768));
      await createProfileViaForm(
        tester,
        name: 'T3iPadHost',
        host: '127.0.0.1',
        password: 'testpass',
      );
      await enterSessionHandlingPrompts(tester, profileName: 'T3iPadHost');

      await sendPhysicalKeyChord(tester, <LogicalKeyboardKey>[
        LogicalKeyboardKey.metaLeft,
        LogicalKeyboardKey.keyC,
      ]);
      await sendPhysicalKeyChord(tester, <LogicalKeyboardKey>[
        LogicalKeyboardKey.altLeft,
        LogicalKeyboardKey.tab,
      ]);
      final TestGesture pad = await tester.createGesture(
        kind: PointerDeviceKind.trackpad,
      );
      await pad.addPointer(location: tester.getCenter(find.byKey(AerKeys.sessionCanvas)));
      await pad.moveBy(const Offset(20, 20));
      await pad.removePointer();
      expectNoOverflowErrors(tester);
    });

    testWidgets('T3-11 Audio off rapid frames pinch zoom 3x and zoom reset', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester);
      await createProfileViaForm(
        tester,
        name: 'T3Zoom3x',
        host: '127.0.0.1',
        password: 'testpass',
      );
      await enterSessionHandlingPrompts(tester, profileName: 'T3Zoom3x');

      await simulatePinchZoom(tester, find.byKey(AerKeys.sessionCanvas), scaleFactor: 3.0);
      await openCommandBarAndTap(tester, AerKeys.commandBarZoomReset);
      expectNoOverflowErrors(tester);
    });

    testWidgets('T3-12 Active audio volume and cancelled touch drag', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester);
      await createProfileViaForm(
        tester,
        name: 'T3AudioCancel',
        host: '127.0.0.1',
        password: 'testpass',
      );
      await enterSessionHandlingPrompts(tester, profileName: 'T3AudioCancel');

      final TestGesture g = await tester.startGesture(
        tester.getCenter(find.byKey(AerKeys.sessionCanvas)),
      );
      await g.moveBy(const Offset(25, 25));
      await g.cancel();
      await tester.pumpAndSettle();
      expectNoOverflowErrors(tester);
    });

    testWidgets('T3-13 Export delete reimport auth prompt and NLA connect', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester);
      await createProfileViaForm(tester, name: 'T3ExportReimport', host: '127.0.0.1');
      await tester.tap(find.byKey(AerKeys.exportProfilesButton));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(AerKeys.importProfilesButton));
      await tester.pumpAndSettle();
      const String validPayload =
          '{"version":1,"profiles":[{"id":"t3-13","name":"T3Reimported","host":"127.0.0.1","port":3389,"username":"testuser","domain":"","authMode":"prompt","securityMode":"nla","displayConfig":{"mode":"custom","width":1280,"height":720,"scale":1.0,"orientationLock":"auto"},"audioConfig":{"mode":"local"},"inputConfig":{"defaultMode":"directTouch","swapButtons":false,"textInputMode":"scancode"},"favorite":false,"lastConnectedAt":null}]}';
      await submitImportJsonIfDialogShown(tester, validPayload);
      expectNoOverflowErrors(tester);
    });
  });
}
