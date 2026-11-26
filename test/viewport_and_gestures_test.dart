import 'package:aer_rdp/models/connection_profile.dart';
import 'package:aer_rdp/models/session_models.dart';
import 'package:aer_rdp/services/demo_rdp_session_client.dart';
import 'package:aer_rdp/ui/aer_keys.dart';
import 'package:aer_rdp/ui/session/session_canvas.dart';
import 'package:aer_rdp/ui/session/viewport_controller.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  group('ViewportController', () {
    test('computes aspect-preserving rect and ignores letterbox margins', () {
      final vp = ViewportController(remoteWidth: 1280, remoteHeight: 720);
      vp.setViewportSize(const Size(400, 800));

      final rect = vp.computeDisplayRect();
      expect(rect.width, closeTo(400.0, 0.01));
      expect(rect.height, closeTo(225.0, 0.01));
      expect(rect.top, closeTo(287.5, 0.01));

      expect(vp.viewportToRemote(const Offset(200, 10)), isNull);
      expect(vp.viewportToRemote(const Offset(200, 790)), isNull);

      final center = vp.viewportToRemote(const Offset(200, 400));
      expect(center, isNotNull);
      expect(center!.dx, closeTo(640, 2));
      expect(center.dy, closeTo(360, 2));
    });

    test('clamps zoom to [1.0, 4.0] and clamps pan bounds', () {
      final vp = ViewportController(remoteWidth: 1280, remoteHeight: 720);
      vp.setViewportSize(const Size(1280, 720));

      vp.setZoom(10.0);
      expect(vp.zoom, 4.0);
      vp.panBy(const Offset(99999, 99999));
      expect(vp.panOffset.dx, closeTo((1280 * 4 - 1280) / 2, 0.1));
      expect(vp.panOffset.dy, closeTo((720 * 4 - 720) / 2, 0.1));

      vp.setZoom(0.2);
      expect(vp.zoom, 1.0);
      expect(vp.panOffset, Offset.zero);
    });
  });

  group('SessionCanvas gestures', () {
    testWidgets('PointerCancelEvent mid-drag releases held pointer button',
        (WidgetTester tester) async {
      const profile = ConnectionProfile(
        id: 'p1',
        name: 'Test',
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

      final vp = ViewportController();
      addTearDown(vp.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SessionCanvas(
              controller: controller,
              viewportController: vp,
              inputMode: InputMode.directTouch,
              swapButtons: false,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final center = tester.getCenter(find.byKey(AerKeys.sessionCanvas));
      final g = await tester.startGesture(center, kind: PointerDeviceKind.touch);
      await g.moveBy(const Offset(30, 20));
      await g.cancel();
      await tester.pump();

      final pointerEvents =
          controller.recordedInputs.where((e) => e.kind == 'pointer').toList();
      expect(pointerEvents, isNotEmpty);
      expect(pointerEvents.last.down, isFalse);
    });

    testWidgets('swapButtons maps primary touch to right mouse button',
        (WidgetTester tester) async {
      const profile = ConnectionProfile(
        id: 'p2',
        name: 'Swap',
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

      final vp = ViewportController();
      addTearDown(vp.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SessionCanvas(
              controller: controller,
              viewportController: vp,
              inputMode: InputMode.directTouch,
              swapButtons: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(AerKeys.sessionCanvas));
      await tester.pump();

      final downs = controller.recordedInputs
          .where((e) => e.kind == 'pointer' && e.down)
          .toList();
      expect(downs, isNotEmpty);
      expect(downs.first.buttonMask, RdpPointerButtons.right);
    });

    Future<(DemoRdpSessionController, ViewportController)> pumpCanvas(
      WidgetTester tester, {
      InputMode inputMode = InputMode.directTouch,
      bool swapButtons = false,
    }) async {
      const profile = ConnectionProfile(
        id: 'p-canvas',
        name: 'Canvas',
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

      final vp = ViewportController();
      addTearDown(vp.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SessionCanvas(
              controller: controller,
              viewportController: vp,
              inputMode: inputMode,
              swapButtons: swapButtons,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return (controller, vp);
    }

    testWidgets(
        'mouse right-click and middle-click release exact pressed button mask (including swapButtons)',
        (WidgetTester tester) async {
      final (controller, _) = await pumpCanvas(tester, swapButtons: false);
      final center = tester.getCenter(find.byKey(AerKeys.sessionCanvas));

      // Right click -> mask 2 down, mask 2 up.
      final rightMouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await rightMouse.down(center);
      await tester.pump();
      await rightMouse.up();
      await tester.pump();
      await rightMouse.removePointer();

      var ptrs =
          controller.recordedInputs.where((e) => e.kind == 'pointer').toList();
      expect(ptrs.length, 2);
      expect(ptrs[0].down, isTrue);
      expect(ptrs[0].buttonMask, RdpPointerButtons.right);
      expect(ptrs[1].down, isFalse);
      expect(ptrs[1].buttonMask, RdpPointerButtons.right);

      // Middle click -> mask 4 down, mask 4 up.
      controller.recordedInputs.clear();
      final midMouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
        buttons: kMiddleMouseButton,
      );
      await midMouse.down(center);
      await tester.pump();
      await midMouse.up();
      await tester.pump();
      await midMouse.removePointer();

      ptrs =
          controller.recordedInputs.where((e) => e.kind == 'pointer').toList();
      expect(ptrs.length, 2);
      expect(ptrs[0].down, isTrue);
      expect(ptrs[0].buttonMask, RdpPointerButtons.middle);
      expect(ptrs[1].down, isFalse);
      expect(ptrs[1].buttonMask, RdpPointerButtons.middle);

      // PointerCancelEvent on mouse releases held right button (mask 2).
      controller.recordedInputs.clear();
      final cancelMouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await cancelMouse.down(center);
      await tester.pump();
      await cancelMouse.cancel();
      await tester.pump();
      await cancelMouse.removePointer();

      ptrs =
          controller.recordedInputs.where((e) => e.kind == 'pointer').toList();
      expect(ptrs.last.down, isFalse);
      expect(ptrs.last.buttonMask, RdpPointerButtons.right);

      // With swapButtons: true, primary mouse button sends right(2) down+up, secondary sends left(1) down+up.
      final (swappedCtrl, _) = await pumpCanvas(tester, swapButtons: true);
      final swappedPrimary = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
        buttons: kPrimaryMouseButton,
      );
      await swappedPrimary.down(center);
      await tester.pump();
      await swappedPrimary.up();
      await tester.pump();
      await swappedPrimary.removePointer();

      ptrs =
          swappedCtrl.recordedInputs.where((e) => e.kind == 'pointer').toList();
      expect(ptrs[0].down, isTrue);
      expect(ptrs[0].buttonMask, RdpPointerButtons.right);
      expect(ptrs[1].down, isFalse);
      expect(ptrs[1].buttonMask, RdpPointerButtons.right);

      swappedCtrl.recordedInputs.clear();
      final swappedSecondary = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await swappedSecondary.down(center);
      await tester.pump();
      await swappedSecondary.up();
      await tester.pump();
      await swappedSecondary.removePointer();

      ptrs =
          swappedCtrl.recordedInputs.where((e) => e.kind == 'pointer').toList();
      expect(ptrs[0].down, isTrue);
      expect(ptrs[0].buttonMask, RdpPointerButtons.left);
      expect(ptrs[1].down, isFalse);
      expect(ptrs[1].buttonMask, RdpPointerButtons.left);
    });

    testWidgets(
        '2-finger tap sends right-click, 2-finger vertical drag scrolls, and pinch still zooms',
        (WidgetTester tester) async {
      final (controller, vp) = await pumpCanvas(tester);
      final center = tester.getCenter(find.byKey(AerKeys.sessionCanvas));

      // 2-finger tap -> right click (mask=2 down & up).
      final g1 = await tester.startGesture(
        center - const Offset(20, 0),
        kind: PointerDeviceKind.touch,
      );
      final g2 = await tester.startGesture(
        center + const Offset(20, 0),
        kind: PointerDeviceKind.touch,
      );
      await tester.pump();
      await g1.up();
      await g2.up();
      await tester.pump();

      final rightEvents = controller.recordedInputs
          .where((e) => e.kind == 'pointer' && e.buttonMask == RdpPointerButtons.right)
          .toList();
      expect(rightEvents.length, 2);
      expect(rightEvents[0].down, isTrue);
      expect(rightEvents[1].down, isFalse);

      // 2-finger vertical drag -> wheelDeltaV scroll without zooming.
      controller.recordedInputs.clear();
      final s1 = await tester.startGesture(
        center - const Offset(20, 0),
        kind: PointerDeviceKind.touch,
      );
      final s2 = await tester.startGesture(
        center + const Offset(20, 0),
        kind: PointerDeviceKind.touch,
      );
      await s1.moveBy(const Offset(0, -30));
      await s2.moveBy(const Offset(0, -30));
      await tester.pump();
      await s1.up();
      await s2.up();
      await tester.pump();

      expect(vp.zoom, closeTo(1.0, 0.01));
      final scrollEvents = controller.recordedInputs
          .where((e) => e.kind == 'pointer' && e.wheelDeltaV != 0)
          .toList();
      expect(scrollEvents, isNotEmpty);

      // Horizontal pinch spread -> zooms > 1.0 cleanly.
      final p1 = await tester.startGesture(
        center - const Offset(30, 0),
        kind: PointerDeviceKind.touch,
      );
      final p2 = await tester.startGesture(
        center + const Offset(30, 0),
        kind: PointerDeviceKind.touch,
      );
      await p1.moveBy(const Offset(-40, 0));
      await p2.moveBy(const Offset(40, 0));
      await tester.pump();
      await p1.up();
      await p2.up();
      await tester.pump();
      expect(vp.zoom, greaterThan(1.5));
    });

    testWidgets('Pointer-mode long-press touch-drag sends button-down move and release',
        (WidgetTester tester) async {
      final (controller, _) = await pumpCanvas(
        tester,
        inputMode: InputMode.pointer,
      );
      final center = tester.getCenter(find.byKey(AerKeys.sessionCanvas));

      final g = await tester.startGesture(center, kind: PointerDeviceKind.touch);
      await tester.pump(const Duration(milliseconds: 400));
      await g.moveBy(const Offset(35, 25));
      await tester.pump();
      await g.up();
      await tester.pump();

      final ptrs =
          controller.recordedInputs.where((e) => e.kind == 'pointer').toList();
      expect(ptrs.any((e) => e.down && e.buttonMask == RdpPointerButtons.left), isTrue);
      expect(ptrs.last.down, isFalse);
      expect(ptrs.last.buttonMask, RdpPointerButtons.left);
    });

    testWidgets(
        'fast narrow staggered 2-finger vertical drag scrolls without latching pinch, and anchored 1-finger pinch still zooms',
        (WidgetTester tester) async {
      final (controller, vp) = await pumpCanvas(tester);
      final center = tester.getCenter(find.byKey(AerKeys.sessionCanvas));

      // Fast staggered 2-finger vertical scroll (40px apart, 60px then 40px vertical step).
      final g1 = await tester.startGesture(
        center - const Offset(20, 0),
        kind: PointerDeviceKind.touch,
      );
      final g2 = await tester.startGesture(
        center + const Offset(20, 0),
        kind: PointerDeviceKind.touch,
      );
      await g1.moveBy(const Offset(0, -60));
      await g2.moveBy(const Offset(0, -60));
      await tester.pump();
      await g1.moveBy(const Offset(0, -40));
      await g2.moveBy(const Offset(0, -40));
      await tester.pump();
      await g1.up();
      await g2.up();
      await tester.pump();

      expect(vp.zoom, closeTo(1.0, 0.01));
      final scrollEvents = controller.recordedInputs
          .where((e) => e.kind == 'pointer' && e.wheelDeltaV != 0)
          .toList();
      expect(scrollEvents, isNotEmpty);

      // Anchored 1-finger pinch (1 finger stationary, 1 finger spreads twice) still zooms > 1.5.
      final a1 = await tester.startGesture(
        center - const Offset(20, 0),
        kind: PointerDeviceKind.touch,
      );
      final a2 = await tester.startGesture(
        center + const Offset(20, 0),
        kind: PointerDeviceKind.touch,
      );
      await a2.moveBy(const Offset(25, 0));
      await tester.pump();
      await a2.moveBy(const Offset(25, 0));
      await tester.pump();
      await a1.up();
      await a2.up();
      await tester.pump();

      expect(vp.zoom, greaterThan(1.5));
    });
  });
}
