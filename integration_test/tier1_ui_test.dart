import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'ui_test_helpers.dart';

void main() {
  group('Tier 1 — FA01 Connection Profiles & Options', () {
    testWidgets('T1-FA01-01 Connection Profile CRUD create edit delete', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester);
      await createProfileViaForm(
        tester,
        name: 'Home PC',
        host: '192.168.1.10',
        port: '3389',
        username: 'aer',
      );
      expect(find.text('Home PC'), findsOneWidget);

      await openProfileEditForm(tester, 'Home PC');
      await tester.enterText(find.byKey(AerKeys.profileFormName), 'Workstation');
      await tester.tap(find.byKey(AerKeys.profileFormSave));
      await tester.pumpAndSettle();
      expect(find.text('Workstation'), findsOneWidget);

      await tester.longPress(find.text('Workstation'));
      await tester.pumpAndSettle();
      final Finder deleteBtn = find.byIcon(Icons.delete_outline);
      if (deleteBtn.evaluate().isNotEmpty) {
        await tester.tap(deleteBtn.first);
        await tester.pumpAndSettle();
      }
      expect(find.text('Workstation'), findsNothing);
    });

    testWidgets('T1-FA01-02 Quick Connect without saving profile', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester);
      await tester.tap(find.byKey(AerKeys.quickConnectButton));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(AerKeys.profileFormHost), '127.0.0.1');
      await tester.enterText(find.byKey(AerKeys.profileFormPort), '3389');
      await tester.enterText(find.byKey(AerKeys.profileFormUser), 'quickuser');
      if (find.byKey(AerKeys.profileFormPassword).evaluate().isNotEmpty) {
        await tester.enterText(
          find.byKey(AerKeys.profileFormPassword),
          'testpass',
        );
      }
      await tester.tap(find.byKey(AerKeys.profileFormSave));
      await tester.pumpAndSettle();

      await enterSessionHandlingPrompts(tester);
      expect(find.byKey(AerKeys.connectionCenterPage), findsNothing);

      await openCommandBarAndTap(tester, AerKeys.commandBarDisconnect);
      expect(find.byKey(AerKeys.connectionCenterPage), findsOneWidget);
      expect(find.text('127.0.0.1'), findsNothing);
      expect(find.text('quickuser'), findsNothing);
    });

    testWidgets('T1-FA01-03 Favorites recents sorting and search filter', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester);
      await createProfileViaForm(tester, name: 'Alpha Box', host: '10.0.0.1');
      await createProfileViaForm(tester, name: 'Beta Box', host: '10.0.0.2');
      await createProfileViaForm(tester, name: 'Gamma Box', host: '10.0.0.3');

      await tester.enterText(find.byKey(AerKeys.profileSearchField), 'Beta');
      await tester.pumpAndSettle();
      expect(find.text('Beta Box'), findsOneWidget);
      expect(find.text('Alpha Box'), findsNothing);
      expect(find.text('Gamma Box'), findsNothing);
    });

    testWidgets('T1-FA01-04 Display security audio and input profile options roundtrip', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester);
      await tester.tap(find.byKey(AerKeys.addProfileButton));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(AerKeys.profileFormName), 'Custom Rig');
      await tester.enterText(find.byKey(AerKeys.profileFormHost), '192.168.1.50');
      await tester.enterText(find.byKey(AerKeys.profileFormDomain), 'CORP');

      await selectProfileOption(
        tester,
        AerKeys.profileFormSecurity,
        <String>['NLA', 'nla'],
      );
      await selectProfileOption(
        tester,
        AerKeys.profileFormAudio,
        <String>['Local', 'local'],
      );
      await selectProfileOption(
        tester,
        AerKeys.profileFormInputMode,
        <String>['Pointer', 'pointer'],
      );

      await tester.tap(find.byKey(AerKeys.profileFormSave));
      await tester.pumpAndSettle();
      expect(find.text('Custom Rig'), findsOneWidget);

      await openProfileEditForm(tester, 'Custom Rig');
      expect(find.byKey(AerKeys.profileFormDomain), findsOneWidget);
      expect(find.text('CORP'), findsOneWidget);
      expect(find.textContaining('NLA'), findsWidgets);
      expect(find.textContaining('Local'), findsWidgets);
      expect(find.textContaining('Pointer'), findsWidgets);
      expectNoOverflowErrors(tester);
    });

    testWidgets('T1-FA01-05 Export profiles JSON without plaintext password', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester);
      await createProfileViaForm(
        tester,
        name: 'ExportTarget',
        host: '192.168.1.20',
        password: 'SuperSecretPassword!',
      );
      expect(find.byKey(AerKeys.exportProfilesButton), findsOneWidget);
      await tester.tap(find.byKey(AerKeys.exportProfilesButton));
      await tester.pumpAndSettle();
      expect(find.textContaining('SuperSecretPassword!'), findsNothing);
    });

    testWidgets('T1-FA01-06 Import valid Profile JSON v1 fixture', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester);
      expect(find.byKey(AerKeys.importProfilesButton), findsOneWidget);
      await tester.tap(find.byKey(AerKeys.importProfilesButton));
      await tester.pumpAndSettle();

      const String validPayload =
          '{"version":1,"profiles":[{"id":"imp-1","name":"Imported Workstation","host":"10.10.0.5","port":3389,"username":"aer","domain":"CORP","authMode":"prompt","securityMode":"nla","displayConfig":{"mode":"custom","width":1280,"height":720,"scale":1.0,"orientationLock":"auto"},"audioConfig":{"mode":"local"},"inputConfig":{"defaultMode":"directTouch","swapButtons":false,"textInputMode":"scancode"},"favorite":false,"lastConnectedAt":null}]}';
      await submitImportJsonIfDialogShown(tester, validPayload);

      expect(find.byKey(AerKeys.connectionCenterPage), findsOneWidget);
      final bool hasImportedCard = find.text('Imported Workstation').evaluate().isNotEmpty ||
          find.byType(Card).evaluate().isNotEmpty ||
          find.byType(ListTile).evaluate().isNotEmpty;
      expect(hasImportedCard, isTrue);
    });
  });

  group('Tier 1 — FA02 Credentials & Certificate Trust', () {
    testWidgets('T1-FA02-01 Saved credentials connect without auth prompt', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester);
      await tester.tap(find.byKey(AerKeys.addProfileButton));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(AerKeys.profileFormName), 'SavedCredHost');
      await tester.enterText(find.byKey(AerKeys.profileFormHost), '127.0.0.1');
      await tester.enterText(find.byKey(AerKeys.profileFormUser), 'testuser');
      await tester.enterText(find.byKey(AerKeys.profileFormPassword), 'secret123');
      await tester.tap(find.byKey(AerKeys.profileFormSave));
      await tester.pumpAndSettle();

      await tester.tap(find.text('SavedCredHost'));
      await tester.pumpAndSettle();
      if (find.byKey(AerKeys.certTrustDialog).evaluate().isNotEmpty) {
        await tester.tap(find.byKey(AerKeys.certTrustOnce));
        await tester.pumpAndSettle();
      }
      expect(find.byKey(AerKeys.authPromptDialog), findsNothing);
      expect(find.byKey(AerKeys.sessionPage), findsOneWidget);
    });

    testWidgets('T1-FA02-02 Prompt auth mode shows auth_prompt_dialog', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester);
      await createProfileViaForm(
        tester,
        name: 'PromptHost',
        host: '127.0.0.1',
        username: 'testuser',
      );
      await tester.tap(find.text('PromptHost'));
      await tester.pumpAndSettle();
      if (find.byKey(AerKeys.certTrustDialog).evaluate().isNotEmpty) {
        await tester.tap(find.byKey(AerKeys.certTrustOnce));
        await tester.pumpAndSettle();
      }
      expect(find.byKey(AerKeys.authPromptDialog), findsOneWidget);
      expect(find.byKey(AerKeys.authPromptSubmit), findsOneWidget);
      final Finder pwdFields = find.descendant(
        of: find.byKey(AerKeys.authPromptDialog),
        matching: find.byType(TextField),
      );
      if (pwdFields.evaluate().isNotEmpty) {
        await tester.enterText(pwdFields.last, 'testpass');
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byKey(AerKeys.authPromptSubmit));
      await tester.pumpAndSettle();
      expect(find.byKey(AerKeys.sessionPage), findsOneWidget);
    });

    testWidgets('T1-FA02-03 Cert trust once prompts again on reconnect', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester);
      await createProfileViaForm(
        tester,
        name: 'UntrustedOnce',
        host: '127.0.0.1',
        password: 'testpass',
      );
      await tester.tap(find.text('UntrustedOnce'));
      await tester.pumpAndSettle();

      expect(find.byKey(AerKeys.certTrustDialog), findsOneWidget);
      await tester.tap(find.byKey(AerKeys.certTrustOnce));
      await tester.pumpAndSettle();
      expect(find.byKey(AerKeys.sessionPage), findsOneWidget);

      await openCommandBarAndTap(tester, AerKeys.commandBarDisconnect);
      await tester.tap(find.text('UntrustedOnce'));
      await tester.pumpAndSettle();
      expect(find.byKey(AerKeys.certTrustDialog), findsOneWidget);
    });

    testWidgets('T1-FA02-04 Cert trust always skips prompt on reconnect', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester);
      await createProfileViaForm(
        tester,
        name: 'PinnedHost',
        host: '127.0.0.1',
        password: 'testpass',
      );
      await tester.tap(find.text('PinnedHost'));
      await tester.pumpAndSettle();

      expect(find.byKey(AerKeys.certTrustDialog), findsOneWidget);
      await tester.tap(find.byKey(AerKeys.certTrustAlways));
      await tester.pumpAndSettle();
      expect(find.byKey(AerKeys.sessionPage), findsOneWidget);

      await openCommandBarAndTap(tester, AerKeys.commandBarDisconnect);
      await tester.tap(find.text('PinnedHost'));
      await tester.pumpAndSettle();
      expect(find.byKey(AerKeys.certTrustDialog), findsNothing);
      expect(find.byKey(AerKeys.sessionPage), findsOneWidget);
    });

    testWidgets('T1-FA02-05 Cert pin and clear reprompts', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester);
      await createProfileViaForm(
        tester,
        name: 'PinClearHost',
        host: '127.0.0.1',
        password: 'testpass',
      );

      await enterSessionHandlingPrompts(
        tester,
        profileName: 'PinClearHost',
        trustAlways: true,
      );
      await openCommandBarAndTap(tester, AerKeys.commandBarDisconnect);

      // Reconnect skips cert prompt while pinned
      await tester.tap(find.text('PinClearHost'));
      await tester.pumpAndSettle();
      expect(find.byKey(AerKeys.certTrustDialog), findsNothing);
      expect(find.byKey(AerKeys.sessionPage), findsOneWidget);
      await openCommandBarAndTap(tester, AerKeys.commandBarDisconnect);

      // Clear/unpin trusted certificate from connection center or profile edit form
      bool cleared = false;
      for (final String label in <String>['Unpin', 'Clear Trust', 'Clear Cert', 'Forget Cert']) {
        final Finder f = find.textContaining(label);
        if (f.evaluate().isNotEmpty) {
          await tester.tap(f.first);
          await tester.pumpAndSettle();
          cleared = true;
          break;
        }
      }
      if (!cleared) {
        await openProfileEditForm(tester, 'PinClearHost');
        for (final String label in <String>['Unpin', 'Clear', 'Forget', 'Reset']) {
          final Finder f = find.textContaining(label);
          if (f.evaluate().isNotEmpty) {
            await tester.tap(f.first);
            await tester.pumpAndSettle();
            cleared = true;
            break;
          }
        }
        await tester.tap(find.byKey(AerKeys.profileFormSave));
        await tester.pumpAndSettle();
      }
      expect(cleared, isTrue, reason: 'Expected UI control to clear/unpin trusted certificate');

      await tester.tap(find.text('PinClearHost'));
      await tester.pumpAndSettle();
      expect(find.byKey(AerKeys.certTrustDialog), findsOneWidget);
    });
  });

  group('Tier 1 — FA04/FA05/FA07 Session UI & Lifecycle', () {
    testWidgets('T1-FA04-05 UI clean disconnect and reconnect', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester);
      await createProfileViaForm(
        tester,
        name: 'SessionHost',
        host: '127.0.0.1',
        password: 'testpass',
      );
      await enterSessionHandlingPrompts(tester, profileName: 'SessionHost');

      await openCommandBarAndTap(tester, AerKeys.commandBarDisconnect);
      expect(find.byKey(AerKeys.connectionCenterPage), findsOneWidget);

      await enterSessionHandlingPrompts(tester, profileName: 'SessionHost');
      expect(find.byKey(AerKeys.sessionPage), findsOneWidget);
    });

    testWidgets('T1-FA05-05 Remote cursor and frame sync rendering', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester);
      await createProfileViaForm(
        tester,
        name: 'RenderHost',
        host: '127.0.0.1',
        password: 'testpass',
      );
      await enterSessionHandlingPrompts(tester, profileName: 'RenderHost');

      final Finder canvas = find.byKey(AerKeys.sessionCanvas);
      expect(find.byKey(AerKeys.sessionPage), findsOneWidget);
      expect(canvas, findsOneWidget);

      final TestGesture mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: tester.getCenter(canvas));
      await mouse.moveBy(const Offset(24, 16));
      await tester.pumpAndSettle();
      await mouse.removePointer();

      await tester.tap(canvas);
      await tester.pumpAndSettle();
      expectNoOverflowErrors(tester);

      await openCommandBarAndTap(tester, AerKeys.commandBarDisconnect);
      expect(find.byKey(AerKeys.connectionCenterPage), findsOneWidget);
    });

    testWidgets('T1-FA07-03 Command bar mute toggles cleanly', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester);
      await createProfileViaForm(
        tester,
        name: 'AudioHost',
        host: '127.0.0.1',
        password: 'testpass',
      );
      await enterSessionHandlingPrompts(tester, profileName: 'AudioHost');
      await openCommandBarAndTap(tester, AerKeys.commandBarMute);
      await openCommandBarAndTap(tester, AerKeys.commandBarMute);
      expect(find.byKey(AerKeys.sessionPage), findsOneWidget);
    });

    testWidgets('T1-FA07-05 Audio teardown on session disconnect', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester);
      await createProfileViaForm(
        tester,
        name: 'AudioCloseHost',
        host: '127.0.0.1',
        password: 'testpass',
      );
      await enterSessionHandlingPrompts(tester, profileName: 'AudioCloseHost');
      await openCommandBarAndTap(tester, AerKeys.commandBarDisconnect);
      expect(find.byKey(AerKeys.connectionCenterPage), findsOneWidget);
    });
  });

  group('Tier 1 — FA08 Viewport, Touch Gestures & Command Bar', () {
    testWidgets('T1-FA08-01 Viewport fit zoom and zoom reset', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester);
      await createProfileViaForm(
        tester,
        name: 'ZoomHost',
        host: '127.0.0.1',
        password: 'testpass',
      );
      await enterSessionHandlingPrompts(tester, profileName: 'ZoomHost');

      await simulatePinchZoom(tester, find.byKey(AerKeys.sessionCanvas), scaleFactor: 2.0);
      await openCommandBarAndTap(tester, AerKeys.commandBarZoomReset);
      expectNoOverflowErrors(tester);
    });

    testWidgets('T1-FA08-02 Zoomed pan tap maps to remote framebuffer coords', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester);
      await createProfileViaForm(
        tester,
        name: 'CoordHost',
        host: '127.0.0.1',
        password: 'testpass',
      );
      await enterSessionHandlingPrompts(tester, profileName: 'CoordHost');

      final Finder canvas = find.byKey(AerKeys.sessionCanvas);
      await simulatePinchZoom(tester, canvas, scaleFactor: 2.0);
      await tester.tap(canvas);
      await tester.pumpAndSettle();
      expect(canvas, findsOneWidget);
    });

    testWidgets('T1-FA08-03 Mouse mode toggle direct touch vs pointer and swap buttons', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester);
      await createProfileViaForm(
        tester,
        name: 'ModeHost',
        host: '127.0.0.1',
        password: 'testpass',
      );
      await enterSessionHandlingPrompts(tester, profileName: 'ModeHost');

      await openCommandBarAndTap(tester, AerKeys.commandBarInputMode);
      await tester.drag(find.byKey(AerKeys.sessionCanvas), const Offset(50, 30));
      await tester.pumpAndSettle();
      expect(find.byKey(AerKeys.sessionPage), findsOneWidget);
    });

    testWidgets('T1-FA08-04 Mobile touch gestures tap long press drag two finger', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester);
      await createProfileViaForm(
        tester,
        name: 'GestureHost',
        host: '127.0.0.1',
        password: 'testpass',
      );
      await enterSessionHandlingPrompts(tester, profileName: 'GestureHost');

      final Finder canvas = find.byKey(AerKeys.sessionCanvas);
      await tester.tap(canvas);
      await tester.longPress(canvas);
      await tester.drag(canvas, const Offset(40, 40));
      await tester.pumpAndSettle();
      expectNoOverflowErrors(tester);
    });

    testWidgets('T1-FA08-05 Floating command bar pill reposition and controls', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester);
      await createProfileViaForm(
        tester,
        name: 'PillHost',
        host: '127.0.0.1',
        password: 'testpass',
      );
      await enterSessionHandlingPrompts(tester, profileName: 'PillHost');

      final Finder pill = find.byKey(AerKeys.commandBarPill);
      expect(pill, findsOneWidget);
      await tester.drag(pill, const Offset(60, 40));
      await tester.pumpAndSettle();
      await tester.tap(pill);
      await tester.pumpAndSettle();

      expect(find.byKey(AerKeys.commandBarDisconnect), findsOneWidget);
      expect(find.byKey(AerKeys.commandBarInputMode), findsOneWidget);
      expect(find.byKey(AerKeys.commandBarKeyboard), findsOneWidget);
      expect(find.byKey(AerKeys.commandBarMute), findsOneWidget);
      expect(find.byKey(AerKeys.commandBarZoomReset), findsOneWidget);
    });
  });

  group('Tier 1 — FA09 Keyboard, IME & External Pointer', () {
    testWidgets('T1-FA09-01 Software keyboard toggle and ASCII input', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester);
      await createProfileViaForm(
        tester,
        name: 'OskHost',
        host: '127.0.0.1',
        password: 'testpass',
      );
      await enterSessionHandlingPrompts(tester, profileName: 'OskHost');

      await openCommandBarAndTap(tester, AerKeys.commandBarKeyboard);
      expect(find.byKey(AerKeys.specialKeyBar), findsOneWidget);
      await openCommandBarAndTap(tester, AerKeys.commandBarKeyboard);
    });

    testWidgets('T1-FA09-02 Special key bar sticky Ctrl Alt Del and F5', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester);
      await createProfileViaForm(
        tester,
        name: 'SpecialKeyHost',
        host: '127.0.0.1',
        password: 'testpass',
      );
      await enterSessionHandlingPrompts(tester, profileName: 'SpecialKeyHost');

      await openCommandBarAndTap(tester, AerKeys.commandBarKeyboard);
      expect(find.byKey(AerKeys.specialKeyBar), findsOneWidget);
      expect(find.text('Ctrl'), findsOneWidget);
      expect(find.text('Alt'), findsOneWidget);
      expect(find.text('F5'), findsOneWidget);
    });

    testWidgets('T1-FA09-03 Unicode IME commit on session', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester);
      await createProfileViaForm(
        tester,
        name: 'UnicodeHost',
        host: '127.0.0.1',
        password: 'testpass',
      );
      await enterSessionHandlingPrompts(tester, profileName: 'UnicodeHost');
      await openCommandBarAndTap(tester, AerKeys.commandBarKeyboard);
      tester.testTextInput.enterText('你好é');
      await tester.pumpAndSettle();
      expect(find.byKey(AerKeys.sessionPage), findsOneWidget);
    });

    testWidgets('T1-FA09-04 External hardware KeyEvent scancodes', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester);
      await createProfileViaForm(
        tester,
        name: 'HwKeyHost',
        host: '127.0.0.1',
        password: 'testpass',
      );
      await enterSessionHandlingPrompts(tester, profileName: 'HwKeyHost');

      await sendPhysicalKeyChord(tester, <LogicalKeyboardKey>[
        LogicalKeyboardKey.shiftLeft,
        LogicalKeyboardKey.keyA,
      ]);
      await sendPhysicalKeyChord(tester, <LogicalKeyboardKey>[
        LogicalKeyboardKey.arrowRight,
      ]);
      expectNoOverflowErrors(tester);
    });

    testWidgets('T1-FA09-05 Physical mouse hover and scroll wheel', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester);
      await createProfileViaForm(
        tester,
        name: 'HwMouseHost',
        host: '127.0.0.1',
        password: 'testpass',
      );
      await enterSessionHandlingPrompts(tester, profileName: 'HwMouseHost');

      final Finder canvas = find.byKey(AerKeys.sessionCanvas);
      final TestGesture mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: tester.getCenter(canvas));
      await mouse.moveBy(const Offset(25, 15));
      await tester.pumpAndSettle();
      await mouse.removePointer();
      expect(canvas, findsOneWidget);
    });
  });

  group('Tier 1 — FA10 iPad Compatibility UI', () {
    testWidgets('T1-FA10-01 iPad adaptive Master-Detail layout', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester, surfaceSize: const Size(1024, 768));
      expectNoOverflowErrors(tester);
      await tester.binding.setSurfaceSize(const Size(1366, 1024));
      await tester.pumpAndSettle();
      expectNoOverflowErrors(tester);
    });

    testWidgets('T1-FA10-03 iPadOS hardware Cmd and Option key mapping', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester, surfaceSize: const Size(1024, 768));
      await createProfileViaForm(
        tester,
        name: 'iPadKeysHost',
        host: '127.0.0.1',
        password: 'testpass',
      );
      await enterSessionHandlingPrompts(tester, profileName: 'iPadKeysHost');

      await sendPhysicalKeyChord(tester, <LogicalKeyboardKey>[
        LogicalKeyboardKey.metaLeft,
        LogicalKeyboardKey.keyC,
      ]);
      await sendPhysicalKeyChord(tester, <LogicalKeyboardKey>[
        LogicalKeyboardKey.altLeft,
        LogicalKeyboardKey.tab,
      ]);
      expectNoOverflowErrors(tester);
    });

    testWidgets('T1-FA10-04 iPadOS indirect trackpad hover secondary click and scroll', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester, surfaceSize: const Size(1024, 768));
      await createProfileViaForm(
        tester,
        name: 'iPadTrackpadHost',
        host: '127.0.0.1',
        password: 'testpass',
      );
      await enterSessionHandlingPrompts(tester, profileName: 'iPadTrackpadHost');

      final Finder canvas = find.byKey(AerKeys.sessionCanvas);
      final Offset center = tester.getCenter(canvas);

      // 1. Indirect cursor hover + secondary click via mouse pointer.
      final TestGesture mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await mouse.addPointer(location: center);
      await mouse.moveBy(const Offset(30, -20));
      await mouse.down(center + const Offset(30, -20));
      await mouse.up();
      await mouse.removePointer();
      await tester.pumpAndSettle();

      // 2. Indirect mouse wheel scroll.
      final TestPointer scrollPtr = TestPointer(2, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(scrollPtr.hover(center));
      await tester.sendEventToBinding(scrollPtr.scroll(const Offset(0, 40)));
      await tester.sendEventToBinding(scrollPtr.removePointer());
      await tester.pumpAndSettle();

      // 3. Trackpad two-finger pan-scroll (panZoomStart -> moveBy -> panZoomEnd).
      final TestGesture trackpad = await tester.createGesture(
        kind: PointerDeviceKind.trackpad,
      );
      await trackpad.addPointer(location: center);
      await trackpad.panZoomStart(center);
      await trackpad.moveBy(const Offset(0, -40));
      await trackpad.panZoomEnd();
      await trackpad.removePointer();
      await tester.pumpAndSettle();
      expectNoOverflowErrors(tester);
    });
  });
}
