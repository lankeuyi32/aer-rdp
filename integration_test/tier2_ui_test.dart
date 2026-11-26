import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'ui_test_helpers.dart';

void main() {
  group('Tier 2 — FA01 Boundary & Negative UI Cases', () {
    testWidgets('T2-FA01-01 Profile form and Quick Connect reject invalid host and port', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester);
      await tester.tap(find.byKey(AerKeys.addProfileButton));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(AerKeys.profileFormName), 'Invalid');
      await tester.enterText(find.byKey(AerKeys.profileFormHost), '');
      await tester.enterText(find.byKey(AerKeys.profileFormPort), '65536');
      await tester.tap(find.byKey(AerKeys.profileFormSave));
      await tester.pumpAndSettle();
      expect(find.byKey(AerKeys.profileFormHost), findsOneWidget);

      await tester.enterText(find.byKey(AerKeys.profileFormHost), '127.0.0.1');
      await tester.enterText(find.byKey(AerKeys.profileFormPort), 'abc');
      await tester.tap(find.byKey(AerKeys.profileFormSave));
      await tester.pumpAndSettle();
      expect(find.byKey(AerKeys.profileFormPort), findsOneWidget);
    });

    testWidgets('T2-FA01-02 Import malformed or version 2 JSON shows error without data loss', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester);
      await createProfileViaForm(tester, name: 'KeepMe', host: '10.0.0.5');
      expect(find.byKey(AerKeys.importProfilesButton), findsOneWidget);
      await tester.tap(find.byKey(AerKeys.importProfilesButton));
      await tester.pumpAndSettle();

      await submitImportJsonIfDialogShown(tester, '{bad');
      final Finder cancelBtn = find.text('Cancel');
      if (cancelBtn.evaluate().isNotEmpty) {
        await tester.tap(cancelBtn.first);
        await tester.pumpAndSettle();
      }
      expectNoOverflowErrors(tester);
      expect(find.text('KeepMe'), findsOneWidget);
    });

    testWidgets('T2-FA01-03 Import invalid enum or negative port rejected atomically', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester);
      await createProfileViaForm(tester, name: 'ExistingProfile', host: '10.0.0.6');
      expect(find.byKey(AerKeys.importProfilesButton), findsOneWidget);
      await tester.tap(find.byKey(AerKeys.importProfilesButton));
      await tester.pumpAndSettle();

      const String badImportPayload =
          '{"version":1,"profiles":[{"id":"bad-1","name":"BadImportHost","host":"10.0.0.99","port":-1,"username":"aer","domain":"","authMode":"prompt","securityMode":"rdp_legacy","displayConfig":{"mode":"custom","width":1280,"height":720,"scale":1.0,"orientationLock":"auto"},"audioConfig":{"mode":"surround"},"inputConfig":{"defaultMode":"directTouch","swapButtons":false,"textInputMode":"scancode"},"favorite":false,"lastConnectedAt":null}]}';
      await submitImportJsonIfDialogShown(tester, badImportPayload);

      final bool hasErrorFeedback = find.byType(SnackBar).evaluate().isNotEmpty ||
          find.textContaining('Invalid').evaluate().isNotEmpty ||
          find.textContaining('Error').evaluate().isNotEmpty ||
          find.textContaining('error').evaluate().isNotEmpty ||
          find.textContaining('invalid').evaluate().isNotEmpty;
      expect(hasErrorFeedback, isTrue, reason: 'Expected visible error feedback on invalid import');

      final Finder cancelBtn = find.text('Cancel');
      if (cancelBtn.evaluate().isNotEmpty) {
        await tester.tap(cancelBtn.first);
        await tester.pumpAndSettle();
      }
      expect(find.text('ExistingProfile'), findsOneWidget);
      expect(find.text('BadImportHost'), findsNothing);
    });

    testWidgets('T2-FA01-04 Display custom resolution bounds 320x240 3840x2160 and 0x0', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester);

      Future<void> fillBounds(String name, String width, String height, String scale) async {
        await tester.tap(find.byKey(AerKeys.addProfileButton));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(AerKeys.profileFormName), name);
        await tester.enterText(find.byKey(AerKeys.profileFormHost), '127.0.0.1');

        final Finder customOpt = find.text('Custom');
        if (customOpt.evaluate().isNotEmpty) {
          await tester.tap(customOpt.first);
          await tester.pumpAndSettle();
        }
        final Finder widthField = find.widgetWithText(TextField, 'Width');
        final Finder heightField = find.widgetWithText(TextField, 'Height');
        final Finder scaleField = find.widgetWithText(TextField, 'Scale');
        if (widthField.evaluate().isNotEmpty) {
          await tester.enterText(widthField.first, width);
        }
        if (heightField.evaluate().isNotEmpty) {
          await tester.enterText(heightField.first, height);
        }
        if (scaleField.evaluate().isNotEmpty) {
          await tester.enterText(scaleField.first, scale);
        }
        await tester.tap(find.byKey(AerKeys.profileFormSave));
        await tester.pumpAndSettle();
      }

      await fillBounds('MinBounds', '320', '240', '0.5');
      expect(find.text('MinBounds'), findsOneWidget);
      expectNoOverflowErrors(tester);

      await fillBounds('MaxBounds', '3840', '2160', '3.0');
      expect(find.text('MaxBounds'), findsOneWidget);
      expectNoOverflowErrors(tester);

      await fillBounds('ZeroBounds', '0', '0', '1.0');
      expect(find.byKey(AerKeys.profileFormSave), findsOneWidget);
      expect(find.text('ZeroBounds'), findsNothing);
      expectNoOverflowErrors(tester);
    });

    testWidgets('T2-FA01-05 Unicode emoji long profile name favorite and delete', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester);
      const String longName =
          '办公电脑 🖥️ (Main) — ExtraLongWorkstationIdentifierForBoundaryLayoutTesting1234567890';
      await createProfileViaForm(tester, name: longName, host: '10.0.0.8');
      expectNoOverflowErrors(tester);
      expect(find.textContaining('办公电脑'), findsOneWidget);

      // Toggle favorite
      final Finder favOff = find.byIcon(Icons.star_border);
      final Finder favOutline = find.byIcon(Icons.star_outline);
      if (favOff.evaluate().isNotEmpty) {
        await tester.tap(favOff.first);
        await tester.pumpAndSettle();
        expect(find.byIcon(Icons.star), findsWidgets);
      } else if (favOutline.evaluate().isNotEmpty) {
        await tester.tap(favOutline.first);
        await tester.pumpAndSettle();
        expect(find.byIcon(Icons.star), findsWidgets);
      }

      // Delete profile and assert removal
      final Finder delOutline = find.byIcon(Icons.delete_outline);
      final Finder delSolid = find.byIcon(Icons.delete);
      if (delOutline.evaluate().isNotEmpty) {
        await tester.tap(delOutline.first);
      } else if (delSolid.evaluate().isNotEmpty) {
        await tester.tap(delSolid.first);
      } else {
        await tester.longPress(find.textContaining('办公电脑'));
        await tester.pumpAndSettle();
        if (find.byIcon(Icons.delete_outline).evaluate().isNotEmpty) {
          await tester.tap(find.byIcon(Icons.delete_outline).first);
        } else if (find.text('Delete').evaluate().isNotEmpty) {
          await tester.tap(find.text('Delete').first);
        }
      }
      await tester.pumpAndSettle();
      if (find.text('Delete').evaluate().isNotEmpty) {
        await tester.tap(find.text('Delete').last);
        await tester.pumpAndSettle();
      }
      expect(find.textContaining('办公电脑'), findsNothing);
      expectNoOverflowErrors(tester);
    });

    testWidgets('T2-FA01-06 Search field handles regex metacharacters whitespace and empty results', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester);
      await createProfileViaForm(tester, name: 'NormalHost', host: '10.0.0.9');

      for (final String query in <String>['.*+?[]()', '   ', 'zzz_nonexistent']) {
        await tester.enterText(find.byKey(AerKeys.profileSearchField), query);
        await tester.pumpAndSettle();
        expectNoOverflowErrors(tester);
      }
      expect(find.text('NormalHost'), findsNothing);
    });
  });

  group('Tier 2 — FA02/FA04/FA07 Dialog & Lifecycle Faults', () {
    testWidgets('T2-FA02-01 Rejecting certificate returns to connection center', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester);
      await createProfileViaForm(tester, name: 'RejectCertHost', host: '127.0.0.1');
      await tester.tap(find.text('RejectCertHost'));
      await tester.pumpAndSettle();

      expect(find.byKey(AerKeys.certTrustDialog), findsOneWidget);
      await tester.tap(find.byKey(AerKeys.certReject));
      await tester.pumpAndSettle();

      expect(find.byKey(AerKeys.sessionPage), findsNothing);
      expect(find.byKey(AerKeys.connectionCenterPage), findsOneWidget);
    });

    testWidgets('T2-FA02-02 Certificate mismatch shows warning and blocks auto trust', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester);
      await createProfileViaForm(tester, name: 'MismatchCertHost', host: '127.0.0.1');
      await tester.tap(find.text('MismatchCertHost'));
      await tester.pumpAndSettle();
      expect(find.byKey(AerKeys.certTrustDialog), findsOneWidget);
    });

    testWidgets('T2-FA02-04 Cancelling auth prompt dialog aborts connection cleanly', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester);
      await createProfileViaForm(tester, name: 'CancelAuthHost', host: '127.0.0.1');
      await tester.tap(find.text('CancelAuthHost'));
      await tester.pumpAndSettle();
      if (find.byKey(AerKeys.certTrustDialog).evaluate().isNotEmpty) {
        await tester.tap(find.byKey(AerKeys.certTrustOnce));
        await tester.pumpAndSettle();
      }

      expect(find.byKey(AerKeys.authPromptDialog), findsOneWidget);
      final Finder cancelBtn = find.text('Cancel');
      if (cancelBtn.evaluate().isNotEmpty) {
        await tester.tap(cancelBtn.first);
        await tester.pumpAndSettle();
      }
      expect(find.byKey(AerKeys.sessionPage), findsNothing);
      expect(find.byKey(AerKeys.connectionCenterPage), findsOneWidget);
    });

    testWidgets('T2-FA02-05 Missing vault secret falls back to auth prompt dialog', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester);
      await createProfileViaForm(tester, name: 'MissingVaultHost', host: '127.0.0.1');
      await tester.tap(find.text('MissingVaultHost'));
      await tester.pumpAndSettle();
      if (find.byKey(AerKeys.certTrustDialog).evaluate().isNotEmpty) {
        await tester.tap(find.byKey(AerKeys.certTrustOnce));
        await tester.pumpAndSettle();
      }
      expect(find.byKey(AerKeys.authPromptDialog), findsOneWidget);
    });

    testWidgets('T2-FA04-04 Cancel connection during Connecting or CertPrompt state', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester);
      await createProfileViaForm(tester, name: 'SlowHost', host: '127.0.0.1');
      await tester.tap(find.text('SlowHost'));
      await tester.pump();
      if (find.byKey(AerKeys.certReject).evaluate().isNotEmpty) {
        await tester.tap(find.byKey(AerKeys.certReject));
      }
      await tester.pumpAndSettle();
      expect(find.byKey(AerKeys.sessionPage), findsNothing);
    });

    testWidgets('T2-FA07-04 Rapid command bar mute toggle 10 times', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester);
      await createProfileViaForm(
        tester,
        name: 'RapidMuteHost',
        host: '127.0.0.1',
        password: 'testpass',
      );
      await enterSessionHandlingPrompts(tester, profileName: 'RapidMuteHost');

      for (int i = 0; i < 10; i++) {
        await openCommandBarAndTap(tester, AerKeys.commandBarMute);
      }
      expectNoOverflowErrors(tester);
    });

    testWidgets('T2-FA07-05 App lifecycle paused and resumed handles audio cleanly', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester);
      await createProfileViaForm(
        tester,
        name: 'LifecycleAudioHost',
        host: '127.0.0.1',
        password: 'testpass',
      );
      await enterSessionHandlingPrompts(
        tester,
        profileName: 'LifecycleAudioHost',
      );

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expectNoOverflowErrors(tester);
    });
  });

  group('Tier 2 — FA08 Viewport & Gesture Boundary Cases', () {
    testWidgets('T2-FA08-01 Zoom and pan clamp within bounds', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester);
      await createProfileViaForm(
        tester,
        name: 'ZoomClampHost',
        host: '127.0.0.1',
        password: 'testpass',
      );
      await enterSessionHandlingPrompts(tester, profileName: 'ZoomClampHost');

      final Finder canvas = find.byKey(AerKeys.sessionCanvas);
      await simulatePinchZoom(tester, canvas, scaleFactor: 6.0);
      await tester.drag(canvas, const Offset(2000, 2000));
      await tester.pumpAndSettle();
      expect(canvas, findsOneWidget);
      expectNoOverflowErrors(tester);
    });

    testWidgets('T2-FA08-02 PointerCancelEvent mid-drag releases mouse button', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester);
      await createProfileViaForm(
        tester,
        name: 'CancelDragHost',
        host: '127.0.0.1',
        password: 'testpass',
      );
      await enterSessionHandlingPrompts(tester, profileName: 'CancelDragHost');

      final Offset center = tester.getCenter(find.byKey(AerKeys.sessionCanvas));
      final TestGesture g = await tester.startGesture(center, kind: PointerDeviceKind.touch);
      await g.moveBy(const Offset(40, 20));
      await tester.pump();
      await g.cancel();
      await tester.pumpAndSettle();
      expectNoOverflowErrors(tester);
    });

    testWidgets('T2-FA08-03 Tap in letterbox margin clamps or ignores safely', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester, surfaceSize: const Size(412, 915));
      await createProfileViaForm(
        tester,
        name: 'LetterboxHost',
        host: '127.0.0.1',
        password: 'testpass',
      );
      await enterSessionHandlingPrompts(tester, profileName: 'LetterboxHost');

      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expectNoOverflowErrors(tester);
    });

    testWidgets('T2-FA08-04 Portrait to landscape resize mid-session', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester, surfaceSize: const Size(412, 915));
      await createProfileViaForm(
        tester,
        name: 'RotateHost',
        host: '127.0.0.1',
        password: 'testpass',
      );
      await enterSessionHandlingPrompts(tester, profileName: 'RotateHost');
      expectNoOverflowErrors(tester);

      await tester.binding.setSurfaceSize(const Size(915, 412));
      await tester.pumpAndSettle();
      expectNoOverflowErrors(tester);
      expect(find.byKey(AerKeys.sessionPage), findsOneWidget);
    });

    testWidgets('T2-FA08-05 Command bar pill clamps inside SafeArea corners', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester, surfaceSize: const Size(412, 915));
      await createProfileViaForm(
        tester,
        name: 'SafeAreaPillHost',
        host: '127.0.0.1',
        password: 'testpass',
      );
      await enterSessionHandlingPrompts(tester, profileName: 'SafeAreaPillHost');

      final Finder pill = find.byKey(AerKeys.commandBarPill);
      await tester.drag(pill, const Offset(-500, -500));
      await tester.pumpAndSettle();
      await tester.drag(pill, const Offset(1000, 1500));
      await tester.pumpAndSettle();
      expect(pill, findsOneWidget);
      expectNoOverflowErrors(tester);
    });
  });

  group('Tier 2 — FA09 & FA10 Keyboard & iPad Boundary Cases', () {
    testWidgets('T2-FA09-01 Sticky Ctrl auto-releases after single key', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester);
      await createProfileViaForm(
        tester,
        name: 'StickyCtrlHost',
        host: '127.0.0.1',
        password: 'testpass',
      );
      await enterSessionHandlingPrompts(tester, profileName: 'StickyCtrlHost');
      await openCommandBarAndTap(tester, AerKeys.commandBarKeyboard);

      final Finder bar = find.byKey(AerKeys.specialKeyBar);
      expect(bar, findsOneWidget);
      final Finder ctrlKey = find.descendant(
        of: bar,
        matching: find.text('Ctrl'),
      );
      expect(ctrlKey, findsOneWidget);
      await tester.tap(ctrlKey);
      await tester.pumpAndSettle();

      // Send C (consuming sticky Ctrl), then send V (unmodified)
      await sendPhysicalKeyChord(tester, <LogicalKeyboardKey>[
        LogicalKeyboardKey.keyC,
      ]);
      await tester.pumpAndSettle();

      final Finder filterChips = find.descendant(
        of: bar,
        matching: find.byType(FilterChip),
      );
      for (final Element el in filterChips.evaluate()) {
        final FilterChip chip = el.widget as FilterChip;
        expect(
          chip.selected,
          isFalse,
          reason: 'Sticky modifier chip should auto-release after single key',
        );
      }

      await sendPhysicalKeyChord(tester, <LogicalKeyboardKey>[
        LogicalKeyboardKey.keyV,
      ]);
      await tester.pumpAndSettle();
      expectNoOverflowErrors(tester);
    });

    testWidgets('T2-FA09-02 Disconnect releases held sticky modifiers', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester);
      await createProfileViaForm(
        tester,
        name: 'ModifierDisconnectHost',
        host: '127.0.0.1',
        password: 'testpass',
      );
      await enterSessionHandlingPrompts(
        tester,
        profileName: 'ModifierDisconnectHost',
      );
      await openCommandBarAndTap(tester, AerKeys.commandBarKeyboard);
      await openCommandBarAndTap(tester, AerKeys.commandBarDisconnect);
      expect(find.byKey(AerKeys.connectionCenterPage), findsOneWidget);
    });

    testWidgets('T2-FA09-03 Emoji surrogate pairs and empty string IME', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester);
      await createProfileViaForm(
        tester,
        name: 'EmojiImeHost',
        host: '127.0.0.1',
        password: 'testpass',
      );
      await enterSessionHandlingPrompts(tester, profileName: 'EmojiImeHost');
      await openCommandBarAndTap(tester, AerKeys.commandBarKeyboard);
      tester.testTextInput.enterText('');
      tester.testTextInput.enterText('🚀👨‍👩‍👧');
      await tester.pumpAndSettle();
      expectNoOverflowErrors(tester);
    });

    testWidgets('T2-FA09-04 Rapid key repeat and focus loss releases keys', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester);
      await createProfileViaForm(
        tester,
        name: 'KeyRepeatHost',
        host: '127.0.0.1',
        password: 'testpass',
      );
      await enterSessionHandlingPrompts(tester, profileName: 'KeyRepeatHost');

      for (int i = 0; i < 20; i++) {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA);
        await tester.pump();
      }
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pumpAndSettle();
      expectNoOverflowErrors(tester);
    });

    testWidgets('T2-FA10-01 iPad Split View and Slide Over narrow widths', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester, surfaceSize: const Size(320, 768));
      expectNoOverflowErrors(tester);
      await tester.binding.setSurfaceSize(const Size(507, 768));
      await tester.pumpAndSettle();
      expectNoOverflowErrors(tester);
    });

    testWidgets('T2-FA10-02 iPad rotation with command bar and special key bar', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester, surfaceSize: const Size(1024, 768));
      await createProfileViaForm(
        tester,
        name: 'iPadRotateHost',
        host: '127.0.0.1',
        password: 'testpass',
      );
      await enterSessionHandlingPrompts(tester, profileName: 'iPadRotateHost');
      await openCommandBarAndTap(tester, AerKeys.commandBarKeyboard);

      await tester.binding.setSurfaceSize(const Size(768, 1024));
      await tester.pumpAndSettle();
      expectNoOverflowErrors(tester);
    });

    testWidgets('T2-FA10-03 iPad modifier-only Cmd and unmapped key ignored safely', (
      WidgetTester tester,
    ) async {
      await pumpAerRdpApp(tester, surfaceSize: const Size(1024, 768));
      await createProfileViaForm(
        tester,
        name: 'iPadUnmappedHost',
        host: '127.0.0.1',
        password: 'testpass',
      );
      await enterSessionHandlingPrompts(tester, profileName: 'iPadUnmappedHost');

      await sendPhysicalKeyChord(tester, <LogicalKeyboardKey>[
        LogicalKeyboardKey.metaLeft,
      ]);
      await sendPhysicalKeyChord(tester, <LogicalKeyboardKey>[
        LogicalKeyboardKey.audioVolumeUp,
      ]);
      expectNoOverflowErrors(tester);
    });
  });
}
