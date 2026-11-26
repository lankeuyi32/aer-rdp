import 'dart:async';
import 'dart:typed_data';

import '../models/connection_profile.dart';
import '../models/session_models.dart';
import 'rdp_session_client.dart';

class DemoRdpSessionClient implements RdpSessionClient {
  const DemoRdpSessionClient({
    this.serverFingerprint = defaultDemoFingerprint,
  });

  static const String defaultDemoFingerprint =
      'a1b2c3d4e5f60718293a4b5c6d7e8f90112233445566778899aabbccddeeff00';

  final String serverFingerprint;

  @override
  Future<RdpSessionController> connect(ConnectRequest request) async {
    final controller = DemoRdpSessionController(
      request: request,
      serverFingerprint: serverFingerprint,
    );
    controller.start();
    return controller;
  }
}

class DemoRecordedInput {
  const DemoRecordedInput({
    required this.kind,
    this.x = 0,
    this.y = 0,
    this.buttonMask = 0,
    this.down = false,
    this.wheelDeltaV = 0,
    this.wheelDeltaH = 0,
    this.code = 0,
    this.extended = false,
    this.codeUnit = 0,
  });

  final String kind;
  final int x;
  final int y;
  final int buttonMask;
  final bool down;
  final int wheelDeltaV;
  final int wheelDeltaH;
  final int code;
  final bool extended;
  final int codeUnit;
}

class DemoRdpSessionController implements RdpSessionController {
  DemoRdpSessionController({
    required this.request,
    required this.serverFingerprint,
  }) {
    _fbWidth = (request.effectiveWidth.clamp(200, 1920)) & ~3;
    _fbHeight = request.effectiveHeight.clamp(200, 1080);
    _rgba = Uint8List(_fbWidth * _fbHeight * 4);
    _paintSyntheticDesktop(markerX: _fbWidth ~/ 2, markerY: _fbHeight ~/ 2);
  }

  final ConnectRequest request;
  final String serverFingerprint;

  late final SessionEventBroadcaster _broadcaster = SessionEventBroadcaster(
    onFirstListen: _onFirstListen,
  );
  final List<DemoRecordedInput> recordedInputs = <DemoRecordedInput>[];

  late int _fbWidth;
  late int _fbHeight;
  late Uint8List _rgba;
  bool _dirty = true;
  bool _muted = false;
  double _volume = 1.0;
  int _waveConfirms = 0;
  int _markerColorSeed = 0;
  bool _started = false;
  bool _disposed = false;

  Completer<CertTrustDecision>? _certCompleter;
  Completer<AuthCredentials>? _authCompleter;

  bool get muted => _muted;
  double get volume => _volume;

  @override
  Stream<RdpSessionEvent> get events => _broadcaster.stream;

  void _onFirstListen() {
    if (_started || _disposed) return;
    _started = true;
    scheduleMicrotask(_runHandshake);
  }

  void start() {
    // Handshake starts on first stream listener via _onFirstListen, avoiding
    // dropped early events before SessionPage.initState subscribes.
  }

  Future<void> _runHandshake() async {
    if (_disposed) return;
    _emitState(const SessionState.connecting());

    final pinned = request.pinnedCertSha256?.toLowerCase();
    if (pinned == null || pinned != serverFingerprint.toLowerCase()) {
      _certCompleter = Completer<CertTrustDecision>();
      _emitState(
        SessionState.certPrompt(
          CertInfo(
            sha256Hex: serverFingerprint,
            subjectCn: request.profile.host,
            sanEntries: <String>[request.profile.host],
            issuer: 'CN=aer-rdp Demo CA',
            notBefore: '2026-01-01T00:00:00Z',
            notAfter: '2027-01-01T00:00:00Z',
            expectedSha256Hex: request.pinnedCertSha256,
          ),
        ),
      );
      final decision = await _certCompleter!.future;
      if (_disposed) return;
      if (decision == CertTrustDecision.reject) {
        _emitState(
          const SessionState.disconnected(
            reason: 'Certificate rejected by user',
            clean: true,
          ),
        );
        return;
      }
    }

    final creds = request.initialCredentials;
    final needsPrompt = request.profile.authMode == AuthMode.prompt ||
        creds == null ||
        creds.password.isEmpty;
    if (needsPrompt) {
      _authCompleter = Completer<AuthCredentials>();
      _emitState(const SessionState.authPrompt());
      await _authCompleter!.future;
      if (_disposed) return;
    }

    _dirty = true;
    _emitState(SessionState.active(width: _fbWidth, height: _fbHeight));
    _emit(
      FrameUpdatedEvent(
        dirtyX: 0,
        dirtyY: 0,
        dirtyW: _fbWidth,
        dirtyH: _fbHeight,
        width: _fbWidth,
        height: _fbHeight,
        frameSync: true,
        presentationMs: 0,
      ),
    );
    if (request.profile.audioConfig.mode == AudioMode.local) {
      _emit(
        const AudioStreamOpenedEvent(
          sampleRate: 44100,
          channels: 2,
          bitsPerSample: 16,
        ),
      );
    }
  }

  void _emit(RdpSessionEvent event) {
    if (!_disposed && !_broadcaster.isClosed) {
      _broadcaster.add(event);
    }
  }

  void _emitState(SessionState state) {
    _emit(SessionStateChangedEvent(state));
  }

  void _paintSyntheticDesktop({required int markerX, required int markerY}) {
    final int mx = markerX.clamp(0, _fbWidth - 1);
    final int my = markerY.clamp(0, _fbHeight - 1);
    final int accentR = (_markerColorSeed * 53 + 64) & 0xFF;
    final int accentG = (_markerColorSeed * 97 + 120) & 0xFF;
    final int accentB = (_markerColorSeed * 151 + 200) & 0xFF;

    for (int y = 0; y < _fbHeight; y++) {
      for (int x = 0; x < _fbWidth; x++) {
        final int idx = (y * _fbWidth + x) * 4;
        if (y < 36) {
          _rgba[idx] = 0x0B;
          _rgba[idx + 1] = 0x57;
          _rgba[idx + 2] = 0xD0;
          _rgba[idx + 3] = 0xFF;
        } else if ((x - mx).abs() < 14 && (y - my).abs() < 14) {
          _rgba[idx] = accentR;
          _rgba[idx + 1] = accentG;
          _rgba[idx + 2] = accentB;
          _rgba[idx + 3] = 0xFF;
        } else {
          final bool checker = ((x >> 5) + (y >> 5)).isEven;
          final int shade = checker ? 0x22 : 0x2C;
          _rgba[idx] = shade;
          _rgba[idx + 1] = shade + 6;
          _rgba[idx + 2] = shade + 14;
          _rgba[idx + 3] = 0xFF;
        }
      }
    }
    _dirty = true;
  }

  @override
  Future<void> submitCertDecision(CertTrustDecision decision) async {
    if (_certCompleter != null && !_certCompleter!.isCompleted) {
      _certCompleter!.complete(decision);
    }
  }

  @override
  Future<void> submitCredentials(AuthCredentials creds) async {
    if (_authCompleter != null && !_authCompleter!.isCompleted) {
      _authCompleter!.complete(creds);
    }
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
    recordedInputs.add(
      DemoRecordedInput(
        kind: 'pointer',
        x: x,
        y: y,
        buttonMask: buttonMask,
        down: down,
        wheelDeltaV: wheelDeltaV,
        wheelDeltaH: wheelDeltaH,
      ),
    );
    if (down) {
      _markerColorSeed++;
    }
    _paintSyntheticDesktop(markerX: x, markerY: y);
    _emit(
      FrameUpdatedEvent(
        dirtyX: 0,
        dirtyY: 0,
        dirtyW: _fbWidth,
        dirtyH: _fbHeight,
        width: _fbWidth,
        height: _fbHeight,
        frameSync: true,
        presentationMs: 16,
      ),
    );
  }

  @override
  Future<void> sendScancode({
    required int code,
    required bool extended,
    required bool down,
  }) async {
    recordedInputs.add(
      DemoRecordedInput(
        kind: 'scancode',
        code: code,
        extended: extended,
        down: down,
      ),
    );
    if (down) {
      _markerColorSeed++;
      _paintSyntheticDesktop(markerX: _fbWidth ~/ 2, markerY: _fbHeight ~/ 2);
      _emit(
        FrameUpdatedEvent(
          dirtyX: 0,
          dirtyY: 0,
          dirtyW: _fbWidth,
          dirtyH: _fbHeight,
          width: _fbWidth,
          height: _fbHeight,
          frameSync: true,
          presentationMs: 16,
        ),
      );
    }
  }

  @override
  Future<void> sendUnicode({required int codeUnit, required bool down}) async {
    recordedInputs.add(
      DemoRecordedInput(
        kind: 'unicode',
        codeUnit: codeUnit,
        down: down,
      ),
    );
  }

  @override
  Future<void> setAudioMute(bool muted) async {
    _muted = muted;
  }

  @override
  Future<void> setAudioVolume(double volume) async {
    _volume = volume.clamp(0.0, 1.0);
  }

  @override
  Future<FramePatch?> takeFramePatch({bool forceFull = false}) async {
    if (!forceFull && !_dirty) {
      return null;
    }
    _dirty = false;
    return FramePatch(
      x: 0,
      y: 0,
      w: _fbWidth,
      h: _fbHeight,
      fbWidth: _fbWidth,
      fbHeight: _fbHeight,
      isFullFrame: true,
      rgbaBytes: Uint8List.fromList(_rgba),
    );
  }

  @override
  AudioStats readAudioPcm({
    required int requestedFrames,
    required int framesPlayedSinceLastRead,
  }) {
    if (framesPlayedSinceLastRead > 0) {
      _waveConfirms++;
    }
    return AudioStats(
      pcmBytes: Uint8List(0),
      framesRead: 0,
      queuedMs: 0,
      driftMs: 0,
      drops: 0,
      underruns: 0,
      waveConfirmsSent: _waveConfirms,
      sampleRate: 44100,
      channels: 2,
      bitsPerSample: 16,
    );
  }

  @override
  Future<void> disconnect() async {
    if (_certCompleter != null && !_certCompleter!.isCompleted) {
      _certCompleter!.complete(CertTrustDecision.reject);
    }
    _emitState(
      const SessionState.disconnected(
        reason: 'user initiated disconnect',
        clean: true,
      ),
    );
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_certCompleter != null && !_certCompleter!.isCompleted) {
      _certCompleter!.complete(CertTrustDecision.reject);
    }
    _broadcaster.dispose();
  }
}
