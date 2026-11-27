import 'package:aer_rdp/main.dart';
import 'package:aer_rdp/models/connection_profile.dart';
import 'package:aer_rdp/models/session_models.dart';
import 'package:aer_rdp/services/cert_trust_store.dart';
import 'package:aer_rdp/services/credential_vault.dart';
import 'package:aer_rdp/services/demo_rdp_session_client.dart';
import 'package:aer_rdp/services/profile_store.dart';
import 'package:aer_rdp/services/scancode_mapper.dart';
import 'package:aer_rdp/ui/aer_keys.dart';
import 'package:aer_rdp/ui/connections/connection_center_page.dart';
import 'package:aer_rdp/ui/connections/profile_form_dialog.dart';
import 'package:aer_rdp/ui/session/auth_prompt_dialog.dart';
import 'package:aer_rdp/ui/session/cert_trust_dialog.dart';
import 'package:aer_rdp/ui/session/session_canvas.dart';
import 'package:aer_rdp/ui/session/session_page.dart';
import 'package:aer_rdp/ui/session/special_key_bar.dart';
import 'package:aer_rdp/ui/session/viewport_controller.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  Future<void> setViewportSize(WidgetTester tester, Size size) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = size;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  void expectNoFlutterError(WidgetTester tester) {
    final err = tester.takeException();
    expect(err, isNull, reason: 'Unexpected widget/layout error: $err');
  }

  group('1. iPad Master-Detail Layout', () {
    for (final Size tabletSize in const <Size>[
      Size(1024, 768),
      Size(1366, 1024),
      Size(600, 800),
    ]) {
      testWidgets(
          'renders Master-Detail at ${tabletSize.width.toInt()}x${tabletSize.height.toInt()} with unique profile name finder',
          (WidgetTester tester) async {
        await setViewportSize(tester, tabletSize);

        const profile = ConnectionProfile(
          id: 'ipad-1',
          name: 'Lab iPad Host',
          host: '192.168.10.50',
          port: 3389,
          username: 'aer',
          domain: 'CORP',
          authMode: AuthMode.saved,
          displayConfig: DisplayConfig(
            mode: DisplayMode.custom,
            width: 1920,
            height: 1200,
            scale: 2.0,
            orientationLock: OrientationLock.landscape,
          ),
        );
        final store = ProfileStore.inMemory(<ConnectionProfile>[profile]);
        final vault = CredentialVault.inMemory();
        final trust = CertTrustStore.inMemory();
        addTearDown(store.dispose);
        addTearDown(trust.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: ConnectionCenterPage(
              profileStore: store,
              credentialVault: vault,
              certTrustStore: trust,
              engineStatus: 'ready',
              onConnect: (_, {explicitPassword, required ephemeral}) {},
            ),
          ),
        );
        await tester.pumpAndSettle();

        expectNoFlutterError(tester);
        expect(find.byType(VerticalDivider), findsOneWidget);
        expect(find.text('Connection Details'), findsOneWidget);
        expect(find.text('Profile: Lab iPad Host'), findsOneWidget);
        expect(find.text('Endpoint: 192.168.10.50:3389'), findsOneWidget);
        // Critical: exact profile.name must match only the list tile so E2E tap(find.text(name)) stays unambiguous.
        expect(find.text('Lab iPad Host'), findsOneWidget);
      });
    }
  });

  group('2. Split View & Slide Over Narrow Widths', () {
    for (final Size narrowSize in const <Size>[
      Size(507, 768),
      Size(320, 768),
    ]) {
      testWidgets(
          'single-pane ConnectionCenterPage & dialogs do not overflow at ${narrowSize.width.toInt()}x${narrowSize.height.toInt()}',
          (WidgetTester tester) async {
        await setViewportSize(tester, narrowSize);

        const profile = ConnectionProfile(
          id: 'split-1',
          name:
              'Very Long Workstation Name That Could Overflow Narrow Slide Over Pane',
          host: 'workstation-very-long-hostname.internal.local',
          port: 3389,
          username: 'administrator',
          domain: 'WORKGROUP',
          authMode: AuthMode.saved,
        );
        final store = ProfileStore.inMemory(<ConnectionProfile>[profile]);
        final vault = CredentialVault.inMemory();
        final trust = CertTrustStore.inMemory();
        addTearDown(store.dispose);
        addTearDown(trust.dispose);

        await tester.pumpWidget(
          AerRdpApp(
            profileStore: store,
            credentialVault: vault,
            certTrustStore: trust,
            sessionClient: const DemoRdpSessionClient(),
          ),
        );
        await tester.pumpAndSettle();

        expectNoFlutterError(tester);
        expect(find.byType(VerticalDivider), findsNothing);

        // Export preview card at narrow width.
        await tester.tap(find.byKey(AerKeys.exportProfilesButton));
        await tester.pumpAndSettle();
        expectNoFlutterError(tester);

        // ProfileFormDialog including Custom resolution + Orientation/Keyboard dropdowns.
        await tester.tap(find.byKey(AerKeys.addProfileButton));
        await tester.pumpAndSettle();
        expectNoFlutterError(tester);

        await tester.ensureVisible(find.text('自定义分辨率'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('自定义分辨率'));
        await tester.pumpAndSettle();
        expectNoFlutterError(tester);
        expect(find.text('宽度'), findsOneWidget);
        expect(find.text('高度'), findsOneWidget);
        expect(find.text('缩放'), findsOneWidget);

        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();

        // QuickConnectDialog at narrow width.
        await tester.tap(find.byKey(AerKeys.quickConnectButton));
        await tester.pumpAndSettle();
        expectNoFlutterError(tester);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
      });
    }

    testWidgets(
        'CertTrustDialog & AuthPromptDialog render cleanly at 320x768 Slide Over',
        (WidgetTester tester) async {
      await setViewportSize(tester, const Size(320, 768));

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CertTrustDialog(
              host: '192.168.1.99',
              port: 3389,
              cert: const CertInfo(
                sha256Hex:
                    'a1b2c3d4e5f60718293a4b5c6d7e8f90112233445566778899aabbccddeeff00',
                subjectCn: 'rdp.local',
                sanEntries: <String>['rdp.local'],
                issuer: 'CN=SelfSigned',
                notBefore: '2026-01-01T00:00:00Z',
                notAfter: '2027-01-01T00:00:00Z',
              ),
              onDecision: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expectNoFlutterError(tester);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AuthPromptDialog(
              initialUsername: 'user',
              initialDomain: 'DOMAIN',
              reason: 'NLA authentication required',
              onSubmit: (_) {},
              onCancel: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expectNoFlutterError(tester);
    });

    testWidgets('ProfileFormDialog saves edits cleanly at 320x768',
        (WidgetTester tester) async {
      await setViewportSize(tester, const Size(320, 768));

      ProfileFormResult? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () async {
                    saved = await showDialog<ProfileFormResult>(
                      context: context,
                      builder: (_) => const ProfileFormDialog(),
                    );
                  },
                  child: const Text('OpenForm'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('OpenForm'));
      await tester.pumpAndSettle();
      expectNoFlutterError(tester);

      await tester.enterText(find.byKey(AerKeys.profileFormName), 'SlideOver');
      await tester.enterText(find.byKey(AerKeys.profileFormHost), '10.0.0.42');
      await tester.tap(find.byKey(AerKeys.profileFormSave));
      await tester.pumpAndSettle();
      expectNoFlutterError(tester);
      expect(saved?.profile.name, 'SlideOver');
      expect(saved?.profile.host, '10.0.0.42');
    });
  });

  group('3. Mid-Session Orientation & Window Resize', () {
    testWidgets(
        'CommandBarPill and SpecialKeyBar stay bounded across 1024x768 -> 768x1024 -> 507x768 -> 320x768',
        (WidgetTester tester) async {
      await setViewportSize(tester, const Size(1024, 768));

      const profile = ConnectionProfile(
        id: 'rot-1',
        name: 'RotateHost',
        host: '127.0.0.1',
        authMode: AuthMode.saved,
      );
      final controller = DemoRdpSessionController(
        request: const ConnectRequest(
          profile: profile,
          initialCredentials: AuthCredentials(username: 'u', password: 'pw'),
          pinnedCertSha256: DemoRdpSessionClient.defaultDemoFingerprint,
          effectiveWidth: 1024,
          effectiveHeight: 768,
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
      expectNoFlutterError(tester);

      // Drag CommandBarPill toward bottom-right and expand it + open SpecialKeyBar.
      await tester.drag(
        find.byKey(AerKeys.commandBarPill),
        const Offset(500, 500),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(AerKeys.commandBarPill));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(AerKeys.commandBarKeyboard));
      await tester.pumpAndSettle();
      expect(find.byKey(AerKeys.specialKeyBar), findsOneWidget);

      for (final Size nextSize in const <Size>[
        Size(768, 1024),
        Size(507, 768),
        Size(320, 768),
        Size(1024, 768),
      ]) {
        tester.view.physicalSize = nextSize;
        await tester.pumpAndSettle();
        expectNoFlutterError(tester);

        final pillRect = tester.getRect(find.byKey(AerKeys.commandBarPill));
        expect(pillRect.left, greaterThanOrEqualTo(0));
        expect(pillRect.top, greaterThanOrEqualTo(0));
        expect(pillRect.right, lessThanOrEqualTo(nextSize.width + 0.5));
        expect(pillRect.bottom, lessThanOrEqualTo(nextSize.height + 0.5));
        expect(find.byKey(AerKeys.specialKeyBar), findsOneWidget);
      }
    });
  });

  group('4. Apple Hardware Keyboard & Focus Retention', () {
    test('ScancodeMapper supports Cmd/Option/F-keys and opt-in mapCommandToCtrl',
        () {
      expect(
        ScancodeMapper.mapLogicalKey(LogicalKeyboardKey.metaLeft),
        const ScancodeSpec(0x5B, extended: true),
      );
      expect(
        ScancodeMapper.mapLogicalKey(LogicalKeyboardKey.metaRight),
        const ScancodeSpec(0x5C, extended: true),
      );
      expect(
        ScancodeMapper.mapLogicalKey(LogicalKeyboardKey.altLeft),
        const ScancodeSpec(0x38),
      );
      expect(
        ScancodeMapper.mapLogicalKey(LogicalKeyboardKey.altRight),
        const ScancodeSpec(0x38, extended: true),
      );

      final KeyDownEvent cmdDown = KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.metaLeft,
        logicalKey: LogicalKeyboardKey.metaLeft,
        timeStamp: Duration.zero,
      );
      expect(
        ScancodeMapper.mapKeyEvent(cmdDown),
        const ScancodeSpec(0x5B, extended: true),
      );
      expect(
        ScancodeMapper.mapKeyEvent(cmdDown, mapCommandToCtrl: true),
        const ScancodeSpec(0x1D),
      );

      final KeyDownEvent cmdRightDown = KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.metaRight,
        logicalKey: LogicalKeyboardKey.metaRight,
        timeStamp: Duration.zero,
      );
      expect(
        ScancodeMapper.mapKeyEvent(cmdRightDown, mapCommandToCtrl: true),
        const ScancodeSpec(0x1D, extended: true),
      );
    });

    testWidgets(
        'dispatches Cmd/Option/F1-F12/Esc/Tab/arrows, preserves sticky modifiers on modifier-only Cmd, ignores unmapped keys, and releases held keys on focus loss',
        (WidgetTester tester) async {
      await setViewportSize(tester, const Size(1024, 768));

      const profile = ConnectionProfile(
        id: 'kbd-1',
        name: 'KbdHost',
        host: '127.0.0.1',
        authMode: AuthMode.saved,
      );
      final controller = DemoRdpSessionController(
        request: const ConnectRequest(
          profile: profile,
          initialCredentials: AuthCredentials(username: 'u', password: 'pw'),
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

      final List<(LogicalKeyboardKey, ScancodeSpec)> expectedKeys =
          <(LogicalKeyboardKey, ScancodeSpec)>[
        (LogicalKeyboardKey.metaLeft, const ScancodeSpec(0x5B, extended: true)),
        (
          LogicalKeyboardKey.metaRight,
          const ScancodeSpec(0x5C, extended: true)
        ),
        (LogicalKeyboardKey.altLeft, const ScancodeSpec(0x38)),
        (LogicalKeyboardKey.altRight, const ScancodeSpec(0x38, extended: true)),
        (LogicalKeyboardKey.escape, const ScancodeSpec(0x01)),
        (LogicalKeyboardKey.tab, const ScancodeSpec(0x0F)),
        (LogicalKeyboardKey.arrowUp, const ScancodeSpec(0x48, extended: true)),
        (
          LogicalKeyboardKey.arrowDown,
          const ScancodeSpec(0x50, extended: true)
        ),
        (
          LogicalKeyboardKey.arrowLeft,
          const ScancodeSpec(0x4B, extended: true)
        ),
        (
          LogicalKeyboardKey.arrowRight,
          const ScancodeSpec(0x4D, extended: true)
        ),
        (LogicalKeyboardKey.f1, const ScancodeSpec(0x3B)),
        (LogicalKeyboardKey.f12, const ScancodeSpec(0x58)),
      ];

      for (final (key, spec) in expectedKeys) {
        controller.recordedInputs.clear();
        await tester.sendKeyDownEvent(key);
        await tester.sendKeyUpEvent(key);
        await tester.pump();
        final sc = controller.recordedInputs
            .where((e) => e.kind == 'scancode')
            .map((e) => (e.code, e.extended, e.down))
            .toList();
        expect(
          sc,
          <(int, bool, bool)>[
            (spec.code, spec.extended, true),
            (spec.code, spec.extended, false),
          ],
          reason: 'Mismatch for $key',
        );
      }

      // Cmd+C & Option+Tab sequences.
      controller.recordedInputs.clear();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();
      expect(
        controller.recordedInputs
            .where((e) => e.kind == 'scancode')
            .map((e) => (e.code, e.extended, e.down))
            .toList(),
        <(int, bool, bool)>[
          (0x5B, true, true),
          (0x2E, false, true),
          (0x2E, false, false),
          (0x5B, true, false),
        ],
      );

      // Unmapped media key is ignored cleanly.
      controller.recordedInputs.clear();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.audioVolumeUp);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.audioVolumeUp);
      await tester.pump();
      expect(controller.recordedInputs, isEmpty);

      // SpecialKeyBar is docked at the bottom row by default (Termius-style);
      // toggle Shift sticky, then press modifier-only Cmd -> Shift stays active.
      expect(find.byKey(AerKeys.specialKeyBar), findsOneWidget);
      final Rect barRect = tester.getRect(find.byKey(AerKeys.specialKeyBar));
      expect(barRect.bottom, closeTo(768.0, 0.5));
      expect(barRect.left, closeTo(0.0, 0.5));
      expect(barRect.right, closeTo(1024.0, 0.5));

      await tester.tap(find.text('Shift'));
      await tester.pump();

      // Reclaim canvas focus by tapping canvas (also tests pointer-down focus recovery).
      await tester.tap(find.byKey(AerKeys.sessionCanvas));
      await tester.pump();
      expect(
        tester
            .widget<ShortcutKeycap>(find.widgetWithText(ShortcutKeycap, 'Shift'))
            .selected,
        isTrue,
      );

      controller.recordedInputs.clear();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();
      expect(
        controller.recordedInputs.any((e) => e.code == 0x2A && !e.down),
        isFalse,
      );
      expect(
        tester
            .widget<ShortcutKeycap>(find.widgetWithText(ShortcutKeycap, 'Shift'))
            .selected,
        isTrue,
      );

      // Pressing a non-modifier key (keyA) afterward consumes & releases sticky Shift.
      controller.recordedInputs.clear();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
      await tester.pump();
      expect(
        controller.recordedInputs.any(
          (e) => e.kind == 'scancode' && e.code == 0x2A && !e.down,
        ),
        isTrue,
      );
      expect(
        tester
            .widget<ShortcutKeycap>(find.widgetWithText(ShortcutKeycap, 'Shift'))
            .selected,
        isFalse,
      );

      // Verify right-end up/down button expands and collapses the multi-row shortcut tray.
      expect(find.byKey(AerKeys.specialKeyBarExpandedPanel), findsNothing);
      await tester.tap(find.byKey(AerKeys.specialKeyBarExpandToggle));
      await tester.pumpAndSettle();
      expect(find.byKey(AerKeys.specialKeyBarExpandedPanel), findsOneWidget);
      expect(find.text('Win+D'), findsOneWidget);
      expect(find.text('F12'), findsOneWidget);

      controller.recordedInputs.clear();
      await tester.tap(find.text('Win+D'));
      await tester.pump();
      expect(
        controller.recordedInputs
            .where((e) => e.kind == 'scancode')
            .map((e) => (e.code, e.extended, e.down))
            .toList(),
        <(int, bool, bool)>[
          (0x5B, true, true),
          (0x20, false, true),
          (0x20, false, false),
          (0x5B, true, false),
        ],
      );

      await tester.tap(find.byKey(AerKeys.specialKeyBarExpandToggle));
      await tester.pumpAndSettle();
      expect(find.byKey(AerKeys.specialKeyBarExpandedPanel), findsNothing);

      // Verify right-pinned keyboard button toggles IME and bar lifts above viewInsets.bottom.
      await tester.tap(find.byKey(AerKeys.specialKeyBarKeyboardToggle));
      await tester.pumpAndSettle();
      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      final Rect liftedBarRect =
          tester.getRect(find.byKey(AerKeys.specialKeyBar));
      expect(liftedBarRect.bottom, closeTo(768.0 - 260.0, 0.5));
      await tester.tap(find.byKey(AerKeys.specialKeyBarKeyboardToggle));
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();

      // Hold 'A' key, then move focus away -> focus loss must release held key (0x1E down=false).
      controller.recordedInputs.clear();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA);
      await tester.pump();
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      expect(
        controller.recordedInputs.any(
          (e) => e.kind == 'scancode' && e.code == 0x1E && !e.down,
        ),
        isTrue,
      );
    });
  });

  group('5. iPadOS Indirect Pointer & Trackpad', () {
    Future<(DemoRdpSessionController, ViewportController)> pumpCanvas(
      WidgetTester tester, {
      bool swapButtons = false,
      Size viewportSize = const Size(1024, 768),
    }) async {
      await setViewportSize(tester, viewportSize);
      const profile = ConnectionProfile(
        id: 'tp-1',
        name: 'Trackpad',
        host: '127.0.0.1',
        authMode: AuthMode.saved,
      );
      final controller = DemoRdpSessionController(
        request: const ConnectRequest(
          profile: profile,
          initialCredentials: AuthCredentials(username: 'u', password: 'pw'),
          pinnedCertSha256: DemoRdpSessionClient.defaultDemoFingerprint,
        ),
        serverFingerprint: DemoRdpSessionClient.defaultDemoFingerprint,
      );
      controller.start();
      addTearDown(controller.dispose);
      final vp = ViewportController(remoteWidth: 1280, remoteHeight: 720);
      addTearDown(vp.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SessionCanvas(
              controller: controller,
              viewportController: vp,
              inputMode: InputMode.pointer,
              swapButtons: swapButtons,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return (controller, vp);
    }

    testWidgets(
        'hover wraps MouseRegion(basic), sends pointer move, and ignores letterbox margins',
        (WidgetTester tester) async {
      // Portrait 768x1024 with 1280x720 desktop creates letterbox margins top/bottom.
      final (controller, vp) = await pumpCanvas(
        tester,
        viewportSize: const Size(768, 1024),
      );

      final MouseRegion mouseRegion = tester.widget<MouseRegion>(
        find.ancestor(
          of: find.byKey(AerKeys.sessionCanvas),
          matching: find.byType(MouseRegion),
        ).first,
      );
      expect(mouseRegion.cursor, SystemMouseCursors.basic);

      expect(vp.viewportToRemote(const Offset(384, 10)), isNull);

      final center = tester.getCenter(find.byKey(AerKeys.sessionCanvas));
      await tester.sendEventToBinding(
        PointerHoverEvent(
          pointer: 10,
          kind: PointerDeviceKind.trackpad,
          position: const Offset(384, 10),
        ),
      );
      await tester.pump();
      expect(controller.recordedInputs, isEmpty);

      await tester.sendEventToBinding(
        PointerHoverEvent(
          pointer: 10,
          kind: PointerDeviceKind.trackpad,
          position: center,
        ),
      );
      await tester.pump();
      final hovers =
          controller.recordedInputs.where((e) => e.kind == 'pointer').toList();
      expect(hovers.length, 1);
      expect(hovers.first.buttonMask, RdpPointerButtons.none);
      expect(hovers.first.down, isFalse);
    });

    testWidgets('secondary click & swapButtons work for mouse/indirect pointer',
        (WidgetTester tester) async {
      final (controller, _) = await pumpCanvas(tester, swapButtons: false);
      final center = tester.getCenter(find.byKey(AerKeys.sessionCanvas));

      final sec = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await sec.down(center);
      await tester.pump();
      await sec.up();
      await tester.pump();
      await sec.removePointer();

      var ptrs =
          controller.recordedInputs.where((e) => e.kind == 'pointer').toList();
      expect(ptrs.map((e) => (e.buttonMask, e.down)).toList(), <(int, bool)>[
        (RdpPointerButtons.right, true),
        (RdpPointerButtons.right, false),
      ]);

      final (swapped, _) = await pumpCanvas(tester, swapButtons: true);
      final swappedSec = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await swappedSec.down(center);
      await tester.pump();
      await swappedSec.up();
      await tester.pump();
      await swappedSec.removePointer();

      ptrs = swapped.recordedInputs.where((e) => e.kind == 'pointer').toList();
      expect(ptrs.map((e) => (e.buttonMask, e.down)).toList(), <(int, bool)>[
        (RdpPointerButtons.left, true),
        (RdpPointerButtons.left, false),
      ]);
    });

    testWidgets(
        'PointerScrollEvent and PointerPanZoom* handle scroll (with sub-pixel accumulation) and non-exponential pinch zoom cleanly',
        (WidgetTester tester) async {
      final (controller, vp) = await pumpCanvas(tester);
      final center = tester.getCenter(find.byKey(AerKeys.sessionCanvas));

      // PointerScrollEvent -> wheelDeltaV & wheelDeltaH (and zero-delta sub-pixel scroll is ignored).
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: center,
          scrollDelta: const Offset(0.1, 0.1),
        ),
      );
      await tester.pump();
      expect(controller.recordedInputs, isEmpty);

      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: center,
          scrollDelta: const Offset(15, -40),
        ),
      );
      await tester.pump();
      expect(controller.recordedInputs.last.wheelDeltaV, 40);
      expect(controller.recordedInputs.last.wheelDeltaH, 15);

      // Trackpad two-finger scroll via PointerPanZoom* (including sub-pixel deltas).
      controller.recordedInputs.clear();
      await tester.sendEventToBinding(
        PointerPanZoomStartEvent(
          pointer: 21,
          position: center,
        ),
      );
      await tester.sendEventToBinding(
        PointerPanZoomUpdateEvent(
          pointer: 21,
          position: center,
          pan: const Offset(0.4, -0.4),
          panDelta: const Offset(0.4, -0.4),
          scale: 1.0,
        ),
      );
      await tester.sendEventToBinding(
        PointerPanZoomUpdateEvent(
          pointer: 21,
          position: center,
          pan: const Offset(0.8, -0.8),
          panDelta: const Offset(0.4, -0.4),
          scale: 1.0,
        ),
      );
      await tester.sendEventToBinding(
        PointerPanZoomUpdateEvent(
          pointer: 21,
          position: center,
          pan: const Offset(1.2, -1.2),
          panDelta: const Offset(0.4, -0.4),
          scale: 1.0,
        ),
      );
      await tester.sendEventToBinding(
        PointerPanZoomEndEvent(
          pointer: 21,
          position: center,
        ),
      );
      await tester.pump();

      expect(vp.zoom, closeTo(1.0, 0.001));
      final panScrolls = controller.recordedInputs
          .where((e) => e.wheelDeltaV != 0 || e.wheelDeltaH != 0)
          .toList();
      expect(panScrolls, hasLength(1));
      expect(panScrolls.first.wheelDeltaV, 1);
      expect(panScrolls.first.wheelDeltaH, 1);

      // Trackpad pinch zoom: scale=1.5 then scale=1.8 must yield ~1.8 (NOT 1.5*1.8=2.7) and zero scroll events.
      controller.recordedInputs.clear();
      await tester.sendEventToBinding(
        PointerPanZoomStartEvent(
          pointer: 22,
          position: center,
        ),
      );
      await tester.sendEventToBinding(
        PointerPanZoomUpdateEvent(
          pointer: 22,
          position: center,
          pan: const Offset(0, -10),
          panDelta: const Offset(0, -10),
          scale: 1.5,
        ),
      );
      await tester.sendEventToBinding(
        PointerPanZoomUpdateEvent(
          pointer: 22,
          position: center,
          pan: const Offset(0, -20),
          panDelta: const Offset(0, -10),
          scale: 1.8,
        ),
      );
      await tester.sendEventToBinding(
        PointerPanZoomEndEvent(
          pointer: 22,
          position: center,
        ),
      );
      await tester.pump();

      expect(vp.zoom, closeTo(1.8, 0.01));
      expect(controller.recordedInputs, isEmpty);
    });
  });
}
