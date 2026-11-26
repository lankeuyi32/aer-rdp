import 'dart:typed_data';

import 'package:aer_rdp/models/connection_profile.dart';
import 'package:aer_rdp/models/session_models.dart';
import 'package:aer_rdp/services/audio_sink_controller.dart';
import 'package:aer_rdp/services/rdp_session_client.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeAudioSinkPlatform implements AudioSinkPlatform {
  bool opened = false;
  bool paused = false;
  bool closed = false;
  int writes = 0;
  int polls = 0;
  int nextDelta = 960;

  @override
  Future<bool> open({
    required int sampleRate,
    required int channels,
    required int bitsPerSample,
  }) async {
    opened = true;
    return true;
  }

  @override
  Future<AudioPlayoutStatus> writePcm(Uint8List pcmBytes) async {
    writes++;
    return AudioPlayoutStatus(framesPlayedDelta: nextDelta, paused: paused);
  }

  @override
  Future<AudioPlayoutStatus> pollPlayoutDelta() async {
    polls++;
    return AudioPlayoutStatus(
      framesPlayedDelta: paused ? 0 : nextDelta,
      paused: paused,
    );
  }

  @override
  Future<void> pause() async {
    paused = true;
  }

  @override
  Future<void> resume() async {
    paused = false;
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

class FakeAudioSession implements RdpSessionController {
  final List<int> creditedFrames = <int>[];
  bool lastMuted = false;
  double lastVolume = 1.0;
  Uint8List nextPcm = Uint8List.fromList(List<int>.filled(960 * 4, 7));

  @override
  Stream<RdpSessionEvent> get events => const Stream<RdpSessionEvent>.empty();

  @override
  AudioStats readAudioPcm({
    required int requestedFrames,
    required int framesPlayedSinceLastRead,
  }) {
    creditedFrames.add(framesPlayedSinceLastRead);
    return AudioStats(
      pcmBytes: nextPcm,
      framesRead: nextPcm.isEmpty ? 0 : 960,
      sampleRate: 48000,
      channels: 2,
      bitsPerSample: 16,
    );
  }

  @override
  Future<void> setAudioMute(bool muted) async => lastMuted = muted;

  @override
  Future<void> setAudioVolume(double volume) async => lastVolume = volume;

  @override
  Future<void> disconnect() async {}

  @override
  void dispose() {}

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
  Future<void> submitCertDecision(CertTrustDecision decision) async {}

  @override
  Future<void> submitCredentials(AuthCredentials creds) async {}

  @override
  Future<FramePatch?> takeFramePatch({bool forceFull = false}) async => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AudioSinkController', () {
    test('opens sink, writes PCM, forwards playout deltas, and drains on pause',
        () async {
      final platform = FakeAudioSinkPlatform();
      final session = FakeAudioSession();
      final ctrl = AudioSinkController(platform: platform);

      await ctrl.start(
        session: session,
        sampleRate: 48000,
        channels: 2,
        bitsPerSample: 16,
      );
      expect(platform.opened, isTrue);

      await ctrl.pumpOnce();
      expect(platform.writes, 1);
      expect(session.creditedFrames.last, 0);

      await ctrl.pumpOnce();
      expect(platform.writes, 2);
      expect(session.creditedFrames.last, 960);

      // End-of-burst empty PCM still calls writePcm(0) to drain pendingTail.
      session.nextPcm = Uint8List(0);
      await ctrl.pumpOnce();
      expect(platform.writes, 3);
      expect(platform.polls, 0);

      await ctrl.setMuted(true);
      expect(session.lastMuted, isTrue);
      await ctrl.setVolume(0.5);
      expect(session.lastVolume, 0.5);

      await ctrl.onAppPaused();
      await ctrl.pumpOnce();
      expect(platform.polls, 1);
      expect(session.creditedFrames.last, greaterThan(0));

      await ctrl.onAppResumed();
      await ctrl.stop();
      expect(platform.closed, isTrue);
    });

    test('runs virtual-clock drain cleanly when platform channel unavailable',
        () async {
      final session = FakeAudioSession();
      final ctrl = AudioSinkController();
      await ctrl.start(
        session: session,
        sampleRate: 48000,
        channels: 2,
        bitsPerSample: 16,
      );
      await ctrl.pumpOnce();
      expect(session.creditedFrames.last, greaterThan(0));
      await ctrl.stop();
    });
  });

  // Reference AudioMode to avoid unused import warning if needed.
  test('AudioMode enum exposes local/remote/off', () {
    expect(AudioMode.values, hasLength(3));
  });
}
