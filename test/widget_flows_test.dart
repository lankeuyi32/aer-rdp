import 'dart:async';

import 'package:aer_rdp/main.dart';
import 'package:aer_rdp/models/connection_profile.dart';
import 'package:aer_rdp/models/session_models.dart';
import 'package:aer_rdp/services/cert_trust_store.dart';
import 'package:aer_rdp/services/credential_vault.dart';
import 'package:aer_rdp/services/demo_rdp_session_client.dart';
import 'package:aer_rdp/services/profile_store.dart';
import 'package:aer_rdp/services/rdp_session_client.dart';
import 'package:aer_rdp/ui/aer_keys.dart';
import 'package:aer_rdp/ui/connections/profile_form_dialog.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('Export preview is non-modal and Import rejects plaintext secret',
      (WidgetTester tester) async {
    final store = ProfileStore.inMemory(<ConnectionProfile>[
      const ConnectionProfile(
        id: 'p1',
        name: 'Desktop',
        host: '10.0.0.10',
        authMode: AuthMode.saved,
      ),
    ]);
    final vault = CredentialVault.inMemory();
    await vault.savePassword('p1', 'TopSecret99!');
    final trust = CertTrustStore.inMemory();

    await tester.pumpWidget(
      AerRdpApp(
        profileStore: store,
        credentialVault: vault,
        certTrustStore: trust,
        sessionClient: const DemoRdpSessionClient(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(AerKeys.exportProfilesButton));
    await tester.pumpAndSettle();
    expect(find.textContaining('TopSecret99!'), findsNothing);

    // Non-modal export allows immediate tap on import without dismissing a barrier.
    await tester.tap(find.byKey(AerKeys.importProfilesButton));
    await tester.pumpAndSettle();

    const leakyJson =
        '{"version":1,"profiles":[{"id":"x","name":"X","host":"1.2.3.4","port":3389,"username":"u","domain":"","password":"bad","authMode":"prompt","securityMode":"auto","displayConfig":{"mode":"matchDevice","width":1280,"height":720,"scale":1.0,"orientationLock":"auto"},"audioConfig":{"mode":"local"},"inputConfig":{"defaultMode":"directTouch","swapButtons":false,"textInputMode":"scancode"},"favorite":false,"lastConnectedAt":null}]}';
    await tester.enterText(
      find.descendant(of: find.byType(Dialog), matching: find.byType(TextField)),
      leakyJson,
    );
    await tester.tap(find.text('Import'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Invalid'), findsWidgets);
    expect(store.byId('x'), isNull);
  });

  testWidgets('Certificate mismatch displays warning banner',
      (WidgetTester tester) async {
    final store = ProfileStore.inMemory(<ConnectionProfile>[
      const ConnectionProfile(
        id: 'm1',
        name: 'PinnedBox',
        host: '127.0.0.1',
        authMode: AuthMode.saved,
      ),
    ]);
    final vault = CredentialVault.inMemory();
    await vault.savePassword('m1', 'pw');
    final trust = CertTrustStore.inMemory(<String, String>{
      '127.0.0.1:3389':
          '0000000000000000000000000000000000000000000000000000000000000000',
    });

    await tester.pumpWidget(
      AerRdpApp(
        profileStore: store,
        credentialVault: vault,
        certTrustStore: trust,
        sessionClient: const DemoRdpSessionClient(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('PinnedBox'));
    await tester.pumpAndSettle();

    expect(find.byKey(AerKeys.certTrustDialog), findsOneWidget);
    expect(find.textContaining('WARNING:'), findsOneWidget);

    await tester.tap(find.byKey(AerKeys.certReject));
    await tester.pumpAndSettle();
    expect(find.byKey(AerKeys.connectionCenterPage), findsOneWidget);
  });

  testWidgets('SessionPage handles AppLifecycleState paused and resumed cleanly',
      (WidgetTester tester) async {
    final store = ProfileStore.inMemory(<ConnectionProfile>[
      const ConnectionProfile(
        id: 'lc1',
        name: 'LifecycleHost',
        host: '127.0.0.1',
        authMode: AuthMode.saved,
      ),
    ]);
    final vault = CredentialVault.inMemory();
    await vault.savePassword('lc1', 'pw');
    final trust = CertTrustStore.inMemory(<String, String>{
      '127.0.0.1:3389': DemoRdpSessionClient.defaultDemoFingerprint,
    });

    await tester.pumpWidget(
      AerRdpApp(
        profileStore: store,
        credentialVault: vault,
        certTrustStore: trust,
        sessionClient: const DemoRdpSessionClient(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('LifecycleHost'));
    await tester.pumpAndSettle();
    expect(find.byKey(AerKeys.sessionPage), findsOneWidget);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  test('SessionEventBroadcaster replays events emitted during 0-listener handoff gap',
      () async {
    final broadcaster = SessionEventBroadcaster();
    final received1 = <RdpSessionEvent>[];
    final sub1 = broadcaster.stream.listen(received1.add);

    broadcaster.add(
      const SessionStateChangedEvent(
        SessionState.active(width: 1280, height: 720),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(received1.length, 1);

    // Cancel listener 1 (0 listeners attached).
    await sub1.cancel();

    // Emit audio open + disconnected while 0 listeners are attached.
    broadcaster.add(
      const AudioStreamOpenedEvent(
        sampleRate: 48000,
        channels: 2,
        bitsPerSample: 16,
      ),
    );
    broadcaster.add(
      const SessionStateChangedEvent(
        SessionState.disconnected(reason: 'server reset', clean: false),
      ),
    );
    broadcaster.closeWhenDrained();

    // Simulate 1+ frame delay before SessionPage subscribes.
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final received2 = <RdpSessionEvent>[];
    final done = Completer<void>();
    final sub2 = broadcaster.stream.listen(
      received2.add,
      onDone: done.complete,
    );
    await done.future;
    await sub2.cancel();
    broadcaster.dispose();

    expect(received2.length, 2);
    expect(received2[0], isA<AudioStreamOpenedEvent>());
    expect(received2[1], isA<SessionStateChangedEvent>());
    expect(
      (received2[1] as SessionStateChangedEvent).state.phase,
      SessionPhase.disconnected,
    );
  });

  testWidgets(
      'AerRdpApp delivers AudioStreamOpenedEvent and Disconnected emitted after SessionPhase.active without dropping',
      (WidgetTester tester) async {
    const audioChannel = MethodChannel('dev.aer.rdp/audio');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      audioChannel,
      (MethodCall call) async => throw MissingPluginException(),
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(audioChannel, null);
    });

    final client = _DelayedAudioSessionClient();
    final store = ProfileStore.inMemory(<ConnectionProfile>[
      const ConnectionProfile(
        id: 'race-1',
        name: 'RaceHost',
        host: '127.0.0.1',
        authMode: AuthMode.saved,
      ),
    ]);
    final vault = CredentialVault.inMemory();
    await vault.savePassword('race-1', 'pw');
    final trust = CertTrustStore.inMemory(<String, String>{
      '127.0.0.1:3389': DemoRdpSessionClient.defaultDemoFingerprint,
    });

    await tester.pumpWidget(
      AerRdpApp(
        profileStore: store,
        credentialVault: vault,
        certTrustStore: trust,
        sessionClient: client,
      ),
    );
    await tester.pumpAndSettle();

    // Case A: AudioStreamOpenedEvent emitted in the 1-frame pre-mount handoff window right after Active.
    await tester.tap(find.text('RaceHost'));
    await tester.pump();
    client.controller.emit(
      const SessionStateChangedEvent(
        SessionState.active(width: 1280, height: 720),
      ),
    );
    client.controller.emit(
      const AudioStreamOpenedEvent(
        sampleRate: 48000,
        channels: 2,
        bitsPerSample: 16,
      ),
    );
    await tester.pump();
    expect(find.byKey(AerKeys.sessionPage), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 25));
    expect(client.controller.readAudioCalls, greaterThan(0));

    client.controller.emit(
      const SessionStateChangedEvent(
        SessionState.disconnected(reason: 'remote closed', clean: true),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(AerKeys.connectionCenterPage), findsOneWidget);

    // Case B: AudioStreamOpenedEvent emitted 2 frames AFTER SessionPhase.active.
    client.resetController();
    await tester.tap(find.text('RaceHost'));
    await tester.pump();
    client.controller.emit(
      const SessionStateChangedEvent(
        SessionState.active(width: 1280, height: 720),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(find.byKey(AerKeys.sessionPage), findsOneWidget);

    client.controller.emit(
      const AudioStreamOpenedEvent(
        sampleRate: 48000,
        channels: 2,
        bitsPerSample: 16,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 25));
    expect(client.controller.readAudioCalls, greaterThan(0));

    client.controller.emit(
      const SessionStateChangedEvent(
        SessionState.disconnected(reason: 'remote closed 2', clean: true),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(AerKeys.connectionCenterPage), findsOneWidget);
  });

  testWidgets(
      'DisplayMode.matchDevice computes aligned dimensions and OrientationLock sets & restores preferred orientations',
      (WidgetTester tester) async {
    final List<List<String>> orientationCalls = <List<String>>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        if (call.method == 'SystemChrome.setPreferredOrientations') {
          orientationCalls.add(
            (call.arguments as List<dynamic>).cast<String>(),
          );
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    await tester.binding.setSurfaceSize(const Size(411, 915));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final client = _DelayedAudioSessionClient();
    final store = ProfileStore.inMemory(<ConnectionProfile>[
      const ConnectionProfile(
        id: 'orient-1',
        name: 'OrientHost',
        host: '127.0.0.1',
        authMode: AuthMode.saved,
        displayConfig: DisplayConfig(
          mode: DisplayMode.matchDevice,
          orientationLock: OrientationLock.landscape,
        ),
      ),
    ]);
    final vault = CredentialVault.inMemory();
    await vault.savePassword('orient-1', 'pw');
    final trust = CertTrustStore.inMemory();

    await tester.pumpWidget(
      AerRdpApp(
        profileStore: store,
        credentialVault: vault,
        certTrustStore: trust,
        sessionClient: client,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('OrientHost'));
    await tester.pump();
    expect(client.lastRequest, isNotNull);
    expect(client.lastRequest!.effectiveWidth % 4, 0);
    expect(client.lastRequest!.effectiveHeight % 4, 0);
    expect(client.lastRequest!.effectiveWidth, inInclusiveRange(200, 8192));
    expect(client.lastRequest!.effectiveHeight, inInclusiveRange(200, 8192));

    client.controller.emit(
      SessionStateChangedEvent(
        SessionState.active(
          width: client.lastRequest!.effectiveWidth,
          height: client.lastRequest!.effectiveHeight,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      orientationCalls.any(
        (list) =>
            list.contains('DeviceOrientation.landscapeLeft') &&
            list.contains('DeviceOrientation.landscapeRight'),
      ),
      isTrue,
    );

    client.controller.emit(
      const SessionStateChangedEvent(
        SessionState.disconnected(reason: 'done', clean: true),
      ),
    );
    await tester.pumpAndSettle();
    expect(orientationCalls.last, isEmpty);
  });

  testWidgets(
      'ProfileFormDialog preserves AuthMode.saved when saved before async password load completes',
      (WidgetTester tester) async {
    final vault = _SlowNullCredentialVault();
    const existing = ConnectionProfile(
      id: 'saved-1',
      name: 'OldName',
      host: '10.0.0.5',
      authMode: AuthMode.saved,
    );

    ProfileFormResult? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () async {
                result = await showDialog<ProfileFormResult>(
                  context: context,
                  builder: (_) => ProfileFormDialog(
                    existing: existing,
                    credentialVault: vault,
                  ),
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(AerKeys.profileFormName), 'NewName');
    await tester.tap(find.byKey(AerKeys.profileFormSave));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.profile.name, 'NewName');
    expect(result!.profile.authMode, AuthMode.saved);
    expect(result!.preserveSavedPassword, isTrue);
  });

  testWidgets(
      'AerRdpApp surfaces SnackBar on post-mount unclean Disconnected without losing clean-disconnect behavior',
      (WidgetTester tester) async {
    final client = _DelayedAudioSessionClient();
    final store = ProfileStore.inMemory(<ConnectionProfile>[
      const ConnectionProfile(
        id: 'disc-1',
        name: 'DiscHost',
        host: '127.0.0.1',
        authMode: AuthMode.saved,
      ),
    ]);
    final vault = CredentialVault.inMemory();
    await vault.savePassword('disc-1', 'pw');
    final trust = CertTrustStore.inMemory(<String, String>{
      '127.0.0.1:3389': DemoRdpSessionClient.defaultDemoFingerprint,
    });

    await tester.pumpWidget(
      AerRdpApp(
        profileStore: store,
        credentialVault: vault,
        certTrustStore: trust,
        sessionClient: client,
      ),
    );
    await tester.pumpAndSettle();

    // Unclean post-mount disconnect surfaces SnackBar with disconnectReason.
    await tester.tap(find.text('DiscHost'));
    await tester.pump();
    client.controller.emit(
      const SessionStateChangedEvent(
        SessionState.active(width: 1280, height: 720),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(AerKeys.sessionPage), findsOneWidget);

    client.controller.emit(
      const SessionStateChangedEvent(
        SessionState.disconnected(
          reason: 'TCP connection reset by peer',
          clean: false,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(AerKeys.connectionCenterPage), findsOneWidget);
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.text('TCP connection reset by peer'), findsOneWidget);

    // Clear SnackBar before clean disconnect check.
    ScaffoldMessenger.of(
      tester.element(find.byKey(AerKeys.connectionCenterPage)),
    ).clearSnackBars();
    await tester.pumpAndSettle();

    // Clean post-mount disconnect returns without showing a SnackBar.
    client.resetController();
    await tester.tap(find.text('DiscHost'));
    await tester.pump();
    client.controller.emit(
      const SessionStateChangedEvent(
        SessionState.active(width: 1280, height: 720),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(AerKeys.sessionPage), findsOneWidget);

    client.controller.emit(
      const SessionStateChangedEvent(
        SessionState.disconnected(
          reason: 'user initiated disconnect',
          clean: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(AerKeys.connectionCenterPage), findsOneWidget);
    expect(find.text('user initiated disconnect'), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
  });
}

class _SlowNullCredentialVault extends CredentialVault {
  _SlowNullCredentialVault() : super(inMemoryOnly: true);

  @override
  Future<String?> loadPassword(String profileId) async => null;
}

class _DelayedAudioSessionClient implements RdpSessionClient {
  _DelayedAudioSessionController controller = _DelayedAudioSessionController();
  ConnectRequest? lastRequest;

  void resetController() {
    controller = _DelayedAudioSessionController();
  }

  @override
  Future<RdpSessionController> connect(ConnectRequest request) async {
    lastRequest = request;
    return controller;
  }
}

class _DelayedAudioSessionController implements RdpSessionController {
  final SessionEventBroadcaster _broadcaster = SessionEventBroadcaster();
  int readAudioCalls = 0;

  @override
  Stream<RdpSessionEvent> get events => _broadcaster.stream;

  void emit(RdpSessionEvent event) => _broadcaster.add(event);

  @override
  AudioStats readAudioPcm({
    required int requestedFrames,
    required int framesPlayedSinceLastRead,
  }) {
    readAudioCalls++;
    return const AudioStats();
  }

  @override
  Future<void> disconnect() async {}

  @override
  void dispose() => _broadcaster.dispose();

  @override
  Future<void> sendPointerEvent({
    required int x,
    required int y,
    required int buttonMask,
    required bool down,
    int wheelDeltaV = 0,
    int wheelDeltaH = 0,
  }) async {}

  @override
  Future<void> sendScancode({
    required int code,
    required bool extended,
    required bool down,
  }) async {}

  @override
  Future<void> sendUnicode({required int codeUnit, required bool down}) async {}

  @override
  Future<void> setAudioMute(bool muted) async {}

  @override
  Future<void> setAudioVolume(double volume) async {}

  @override
  Future<void> submitCertDecision(CertTrustDecision decision) async {}

  @override
  Future<void> submitCredentials(AuthCredentials creds) async {}

  @override
  Future<FramePatch?> takeFramePatch({bool forceFull = false}) async => null;
}
