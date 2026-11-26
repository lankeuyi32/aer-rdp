import 'dart:async';

import '../models/connection_profile.dart';
import '../models/session_models.dart';
import '../src/rust/api.dart' as rust_api;
import 'rdp_session_client.dart';

class RustRdpSessionClient implements RdpSessionClient {
  const RustRdpSessionClient();

  @override
  Future<RdpSessionController> connect(ConnectRequest request) async {
    final config = rust_api.FfiConnectConfig(
      host: request.profile.host,
      port: request.profile.port,
      width: request.effectiveWidth,
      height: request.effectiveHeight,
      scaleFactor: request.effectiveScaleFactor,
      securityMode: _mapSecurityMode(request.profile.securityMode),
      audioMode: _mapAudioMode(request.profile.audioConfig.mode),
      clientName: request.clientName,
      pinnedCertSha256: request.pinnedCertSha256,
      enableServerPointer: true,
      pointerSoftwareRendering: false,
    );

    final creds = request.initialCredentials;
    final ffiCreds = creds == null
        ? null
        : rust_api.FfiCredentials(
            username: creds.username,
            domain: creds.domain,
            password: creds.password,
          );

    final handle = rust_api.createSession(
      config: config,
      initialCreds: ffiCreds,
    );

    return RustRdpSessionController(
      handle: handle,
      expectedPinnedSha256: request.pinnedCertSha256,
    );
  }

  static rust_api.FfiSecurityMode _mapSecurityMode(SecurityMode mode) {
    return switch (mode) {
      SecurityMode.auto => rust_api.FfiSecurityMode.auto,
      SecurityMode.nla => rust_api.FfiSecurityMode.nla,
      SecurityMode.tls => rust_api.FfiSecurityMode.tls,
    };
  }

  static rust_api.FfiAudioMode _mapAudioMode(AudioMode mode) {
    return switch (mode) {
      AudioMode.local => rust_api.FfiAudioMode.local,
      AudioMode.remote => rust_api.FfiAudioMode.remote,
      AudioMode.off => rust_api.FfiAudioMode.off,
    };
  }
}

class RustRdpSessionController implements RdpSessionController {
  RustRdpSessionController({
    required rust_api.FfiSessionHandle handle,
    String? expectedPinnedSha256,
  })  : _handle = handle,
        _expectedPinnedSha256 = expectedPinnedSha256 {
    _sub = _handle.subscribeEvents().listen(
      (ev) {
        _broadcaster.add(_mapEvent(ev));
      },
      onError: (Object err, StackTrace st) {
        _broadcaster.add(
          SessionStateChangedEvent(
            SessionState.disconnected(reason: err.toString(), clean: false),
          ),
        );
      },
      onDone: () {
        _broadcaster.closeWhenDrained();
      },
    );
  }

  final rust_api.FfiSessionHandle _handle;
  final String? _expectedPinnedSha256;
  final SessionEventBroadcaster _broadcaster = SessionEventBroadcaster();
  late final StreamSubscription<rust_api.FfiSessionEvent> _sub;
  bool _disposed = false;

  @override
  Stream<RdpSessionEvent> get events => _broadcaster.stream;

  RdpSessionEvent _mapEvent(rust_api.FfiSessionEvent ev) {
    switch (ev.kind) {
      case rust_api.FfiSessionEventKind.stateChanged:
        final st = ev.state;
        if (st == null) {
          return const SessionStateChangedEvent(SessionState.connecting());
        }
        return SessionStateChangedEvent(_mapState(st));
      case rust_api.FfiSessionEventKind.frameUpdated:
        return FrameUpdatedEvent(
          dirtyX: ev.dirtyX,
          dirtyY: ev.dirtyY,
          dirtyW: ev.dirtyW,
          dirtyH: ev.dirtyH,
          width: ev.width,
          height: ev.height,
          frameSync: ev.frameSync,
          presentationMs: ev.presentationMs.toInt(),
        );
      case rust_api.FfiSessionEventKind.cursorUpdated:
        return CursorUpdatedEvent(
          CursorState(
            x: ev.cursorX,
            y: ev.cursorY,
            visible: ev.cursorVisible,
            hotspotX: ev.cursorHotspotX,
            hotspotY: ev.cursorHotspotY,
            width: ev.width,
            height: ev.height,
            rgbaPixels: ev.cursorRgbaPixels,
          ),
        );
      case rust_api.FfiSessionEventKind.audioStreamOpened:
        return AudioStreamOpenedEvent(
          sampleRate: ev.sampleRate,
          channels: ev.channels,
          bitsPerSample: ev.bitsPerSample,
        );
      case rust_api.FfiSessionEventKind.audioVolumeChanged:
        return AudioVolumeChangedEvent(
          left: ev.volumeLeft,
          right: ev.volumeRight,
        );
    }
  }

  SessionState _mapState(rust_api.FfiSessionState st) {
    switch (st.kind) {
      case rust_api.FfiSessionStateKind.connecting:
        return const SessionState.connecting();
      case rust_api.FfiSessionStateKind.certPrompt:
        final cert = st.cert;
        return SessionState.certPrompt(
          CertInfo(
            sha256Hex: cert?.sha256Hex ?? '',
            subjectCn: cert?.subjectCn,
            sanEntries: cert?.sanEntries ?? const <String>[],
            issuer: cert?.issuer ?? '',
            notBefore: cert?.notBefore ?? '',
            notAfter: cert?.notAfter ?? '',
            derBytes: cert?.derBytes,
            expectedSha256Hex: _expectedPinnedSha256,
          ),
        );
      case rust_api.FfiSessionStateKind.authPrompt:
        return SessionState.authPrompt(reason: st.reason);
      case rust_api.FfiSessionStateKind.active:
        return SessionState.active(width: st.width, height: st.height);
      case rust_api.FfiSessionStateKind.reactivating:
        return const SessionState.reactivating();
      case rust_api.FfiSessionStateKind.disconnected:
        return SessionState.disconnected(
          reason: st.reason ?? 'disconnected',
          clean: st.clean,
        );
    }
  }

  @override
  Future<void> submitCertDecision(CertTrustDecision decision) async {
    if (_disposed) return;
    final mapped = switch (decision) {
      CertTrustDecision.trustOnce => rust_api.FfiCertTrustDecision.trustOnce,
      CertTrustDecision.trustAlways =>
        rust_api.FfiCertTrustDecision.trustAlways,
      CertTrustDecision.reject => rust_api.FfiCertTrustDecision.reject,
    };
    _handle.submitCertDecision(decision: mapped);
  }

  @override
  Future<void> submitCredentials(AuthCredentials creds) async {
    if (_disposed) return;
    _handle.submitCredentials(
      creds: rust_api.FfiCredentials(
        username: creds.username,
        domain: creds.domain,
        password: creds.password,
      ),
    );
  }

  @override
  Future<void> sendPointerEvent({
    required int x,
    required int y,
    required int buttonMask,
    required bool down,
    int wheelDeltaV = 0,
    int wheelDeltaH = 0,
  }) async {
    if (_disposed) return;
    _handle.sendPointerEvent(
      x: x,
      y: y,
      buttonMask: buttonMask,
      down: down,
      wheelDeltaV: wheelDeltaV,
      wheelDeltaH: wheelDeltaH,
    );
  }

  @override
  Future<void> sendScancode({
    required int code,
    required bool extended,
    required bool down,
  }) async {
    if (_disposed) return;
    _handle.sendScancode(code: code, extended: extended, down: down);
  }

  @override
  Future<void> sendUnicode({required int codeUnit, required bool down}) async {
    if (_disposed) return;
    _handle.sendUnicode(codeUnit: codeUnit, down: down);
  }

  @override
  Future<void> setAudioMute(bool muted) async {
    if (_disposed) return;
    _handle.setAudioMute(muted: muted);
  }

  @override
  Future<void> setAudioVolume(double volume) async {
    if (_disposed) return;
    _handle.setAudioVolume(volume: volume);
  }

  @override
  Future<FramePatch?> takeFramePatch({bool forceFull = false}) async {
    if (_disposed) return null;
    final patch = await _handle.takeFramePatch(forceFull: forceFull);
    if (patch == null) return null;
    return FramePatch(
      x: patch.x,
      y: patch.y,
      w: patch.w,
      h: patch.h,
      fbWidth: patch.fbWidth,
      fbHeight: patch.fbHeight,
      isFullFrame: patch.isFullFrame,
      rgbaBytes: patch.rgbaBytes,
    );
  }

  @override
  AudioStats readAudioPcm({
    required int requestedFrames,
    required int framesPlayedSinceLastRead,
  }) {
    if (_disposed) {
      return const AudioStats();
    }
    final res = _handle.readAudioPcm(
      requestedFrames: requestedFrames,
      framesPlayedSinceLastRead: framesPlayedSinceLastRead,
    );
    return AudioStats(
      pcmBytes: res.pcmBytes,
      framesRead: res.framesRead,
      queuedMs: res.queuedMs,
      driftMs: res.driftMs.toInt(),
      drops: res.drops.toInt(),
      underruns: res.underruns.toInt(),
      waveConfirmsSent: res.waveConfirmsSent.toInt(),
      sampleRate: res.sampleRate,
      channels: res.channels,
      bitsPerSample: res.bitsPerSample,
    );
  }

  @override
  Future<void> disconnect() async {
    if (_disposed) return;
    try {
      _handle.disconnect();
    } catch (_) {
      // Ignore already-closed channel on disconnect.
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _sub.cancel();
    _handle.dispose();
    _broadcaster.dispose();
  }
}
