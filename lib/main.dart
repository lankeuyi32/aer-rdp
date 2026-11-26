import 'dart:async';

import 'package:aer_rdp/src/rust/api.dart';
import 'package:aer_rdp/src/rust/frb_generated.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:material_ui/material_ui.dart';

import 'models/connection_profile.dart';
import 'models/session_models.dart';
import 'services/cert_trust_store.dart';
import 'services/credential_vault.dart';
import 'services/demo_rdp_session_client.dart';
import 'services/profile_store.dart';
import 'services/rdp_session_client.dart';
import 'services/rust_rdp_session_client.dart';
import 'ui/connections/connection_center_page.dart';
import 'ui/session/auth_prompt_dialog.dart';
import 'ui/session/cert_trust_dialog.dart';
import 'ui/session/session_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init(
    externalLibrary: (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS)
        ? ExternalLibrary.process(iKnowHowToUseIt: true)
        : null,
  );
  final summary = getEngineSummary();
  final status =
      '${summary.name} v${summary.version} • ${summary.tlsProvider} • rdpsnd=${summary.supportsRdpsnd}';
  runApp(AerRdpApp(engineStatus: status));
}

class AerRdpApp extends StatefulWidget {
  const AerRdpApp({
    super.key,
    this.engineStatus = 'aer-rdp-core ready',
    this.sessionClient,
    this.profileStore,
    this.credentialVault,
    this.certTrustStore,
  });

  final String engineStatus;
  final RdpSessionClient? sessionClient;
  final ProfileStore? profileStore;
  final CredentialVault? credentialVault;
  final CertTrustStore? certTrustStore;

  @override
  State<AerRdpApp> createState() => _AerRdpAppState();
}

class _AerRdpAppState extends State<AerRdpApp> {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  final GlobalKey<ScaffoldMessengerState> _messengerKey =
      GlobalKey<ScaffoldMessengerState>();

  late final ProfileStore _profileStore;
  late final CredentialVault _credentialVault;
  late final CertTrustStore _certTrustStore;
  late final RdpSessionClient _sessionClient;

  ConnectionProfile? _activeProfile;
  RdpSessionController? _activeController;
  AudioStreamOpenedEvent? _initialAudioFormat;
  int? _activeWidth;
  int? _activeHeight;

  RdpSessionController? _pendingController;
  StreamSubscription<RdpSessionEvent>? _handshakeSub;
  bool _handshakeDialogOpen = false;

  @override
  void initState() {
    super.initState();
    final bool rustReady = RustLib.instance.initialized;
    _sessionClient = widget.sessionClient ??
        (rustReady
            ? const RustRdpSessionClient()
            : const DemoRdpSessionClient());
    _profileStore =
        widget.profileStore ?? ProfileStore(inMemoryOnly: !rustReady);
    _credentialVault =
        widget.credentialVault ?? CredentialVault(inMemoryOnly: !rustReady);
    _certTrustStore =
        widget.certTrustStore ?? CertTrustStore(inMemoryOnly: !rustReady);

    _profileStore.load();
    _certTrustStore.load();
  }

  @override
  void dispose() {
    _handshakeSub?.cancel();
    _pendingController?.dispose();
    _activeController?.dispose();
    if (widget.profileStore == null) {
      _profileStore.dispose();
    }
    if (widget.certTrustStore == null) {
      _certTrustStore.dispose();
    }
    super.dispose();
  }

  Future<void> _startConnection(
    ConnectionProfile profile, {
    String? explicitPassword,
    required bool ephemeral,
  }) async {
    final Size mediaSize = MediaQuery.maybeSizeOf(context) ?? Size.zero;
    final double dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;

    await _cancelPendingHandshake();

    String? password = explicitPassword;
    if ((password == null || password.isEmpty) &&
        profile.authMode == AuthMode.saved &&
        !ephemeral) {
      password = await _credentialVault.loadPassword(profile.id);
    }

    final String? pinnedSha256 =
        _certTrustStore.getPinnedFingerprint(profile.host, profile.port);

    final AuthCredentials? initialCreds =
        (password != null && password.isNotEmpty)
            ? AuthCredentials(
                username: profile.username,
                domain: profile.domain.isEmpty ? null : profile.domain,
                password: password,
              )
            : null;

    final int effW;
    final int effH;
    if (profile.displayConfig.mode == DisplayMode.custom) {
      effW = profile.displayConfig.width;
      effH = profile.displayConfig.height;
    } else {
      final int rawW = (mediaSize.width * dpr).round();
      final int rawH = (mediaSize.height * dpr).round();
      if (rawW <= 0 || rawH <= 0) {
        effW = 1280;
        effH = 720;
      } else {
        effW = rawW.clamp(200, 8192) & ~3;
        effH = rawH.clamp(200, 8192) & ~3;
      }
    }
    final int effScale = (profile.displayConfig.scale * 100).round();

    final controller = await _sessionClient.connect(
      ConnectRequest(
        profile: profile,
        initialCredentials: initialCreds,
        pinnedCertSha256: pinnedSha256,
        effectiveWidth: effW,
        effectiveHeight: effH,
        effectiveScaleFactor: effScale,
      ),
    );

    if (!mounted) {
      controller.dispose();
      return;
    }

    _pendingController = controller;
    AudioStreamOpenedEvent? pendingAudio;
    bool handedOffToSession = false;

    _handshakeSub = controller.events.listen((event) {
      if (!mounted) return;
      if (!handedOffToSession && _pendingController != controller) return;
      if (handedOffToSession && _activeController != controller) return;
      switch (event) {
        case AudioStreamOpenedEvent():
          if (!handedOffToSession) {
            pendingAudio = event;
          } else {
            setState(() {
              _initialAudioFormat = event;
            });
          }
        case SessionStateChangedEvent(:final state):
          switch (state.phase) {
            case SessionPhase.certPrompt:
              if (handedOffToSession) break;
              final cert = state.certInfo;
              if (cert != null && !_handshakeDialogOpen) {
                unawaited(_promptCert(profile, controller, cert));
              }
            case SessionPhase.authPrompt:
              if (handedOffToSession) break;
              if (!_handshakeDialogOpen) {
                unawaited(_promptAuth(profile, controller, state.authReason));
              }
            case SessionPhase.active:
              if (handedOffToSession) break;
              handedOffToSession = true;
              _pendingController = null;
              if (!ephemeral) {
                unawaited(
                  _profileStore.markConnected(profile.id, DateTime.now().toUtc()),
                );
              }
              setState(() {
                _activeProfile = profile;
                _activeController = controller;
                _activeWidth = state.width > 0 ? state.width : effW;
                _activeHeight = state.height > 0 ? state.height : effH;
                _initialAudioFormat = pendingAudio;
              });
            case SessionPhase.disconnected:
              _handshakeSub?.cancel();
              _handshakeSub = null;
              if (!handedOffToSession) {
                _pendingController = null;
                controller.dispose();
              } else {
                _endSession();
              }
              if (!state.cleanDisconnect && state.disconnectReason.isNotEmpty) {
                _messengerKey.currentState?.showSnackBar(
                  SnackBar(content: Text(state.disconnectReason)),
                );
              }
            case SessionPhase.connecting:
            case SessionPhase.reactivating:
              break;
          }
        case FrameUpdatedEvent():
        case CursorUpdatedEvent():
        case AudioVolumeChangedEvent():
          break;
      }
    });
  }

  Future<void> _cancelPendingHandshake() async {
    await _handshakeSub?.cancel();
    _handshakeSub = null;
    final pending = _pendingController;
    _pendingController = null;
    if (pending != null) {
      await pending.disconnect();
      pending.dispose();
    }
  }

  Future<void> _promptCert(
    ConnectionProfile profile,
    RdpSessionController controller,
    CertInfo cert,
  ) async {
    final ctx = _navigatorKey.currentContext;
    if (ctx == null) return;
    _handshakeDialogOpen = true;
    final decision = await showDialog<CertTrustDecision>(
      context: ctx,
      barrierDismissible: false,
      builder: (dialogCtx) => CertTrustDialog(
        host: profile.host,
        port: profile.port,
        cert: cert,
        onDecision: (d) => Navigator.of(dialogCtx).pop(d),
      ),
    );
    _handshakeDialogOpen = false;
    final effective = decision ?? CertTrustDecision.reject;
    if (effective == CertTrustDecision.trustAlways) {
      await _certTrustStore.trustFingerprint(
        profile.host,
        profile.port,
        cert.sha256Hex,
      );
    }
    await controller.submitCertDecision(effective);
  }

  Future<void> _promptAuth(
    ConnectionProfile profile,
    RdpSessionController controller,
    String? reason,
  ) async {
    final ctx = _navigatorKey.currentContext;
    if (ctx == null) return;
    _handshakeDialogOpen = true;
    final creds = await showDialog<AuthCredentials>(
      context: ctx,
      barrierDismissible: false,
      builder: (dialogCtx) => AuthPromptDialog(
        initialUsername: profile.username,
        initialDomain: profile.domain,
        reason: reason,
        onSubmit: (c) => Navigator.of(dialogCtx).pop(c),
        onCancel: () => Navigator.of(dialogCtx).pop(null),
      ),
    );
    _handshakeDialogOpen = false;
    if (creds == null) {
      await _cancelPendingHandshake();
      return;
    }
    await controller.submitCredentials(creds);
  }

  void _onSessionPageAttached() {
    _handshakeSub?.cancel();
    _handshakeSub = null;
  }

  void _endSession() {
    _handshakeSub?.cancel();
    _handshakeSub = null;
    final old = _activeController;
    setState(() {
      _activeController = null;
      _activeProfile = null;
      _initialAudioFormat = null;
      _activeWidth = null;
      _activeHeight = null;
    });
    old?.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'aer-rdp',
      navigatorKey: _navigatorKey,
      scaffoldMessengerKey: _messengerKey,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0B57D0)),
        useMaterial3: true,
      ),
      home: _activeController != null && _activeProfile != null
          ? SessionPage(
              profile: _activeProfile!,
              controller: _activeController!,
              certTrustStore: _certTrustStore,
              initialAudioFormat: _initialAudioFormat,
              initialWidth: _activeWidth,
              initialHeight: _activeHeight,
              onAttached: _onSessionPageAttached,
              onEnded: _endSession,
              onDisconnected: (reason, clean) {
                _endSession();
                if (!clean && reason.isNotEmpty) {
                  _messengerKey.currentState?.showSnackBar(
                    SnackBar(content: Text(reason)),
                  );
                }
              },
            )
          : ConnectionCenterPage(
              profileStore: _profileStore,
              credentialVault: _credentialVault,
              certTrustStore: _certTrustStore,
              engineStatus: widget.engineStatus,
              onConnect: (profile,
                  {String? explicitPassword, required bool ephemeral}) {
                _startConnection(
                  profile,
                  explicitPassword: explicitPassword,
                  ephemeral: ephemeral,
                );
              },
            ),
    );
  }
}
