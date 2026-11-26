import 'dart:async';

import 'package:aer_rdp/models/connection_profile.dart';
import 'package:aer_rdp/models/session_models.dart';
import 'package:aer_rdp/services/audio_sink_controller.dart';
import 'package:aer_rdp/services/rdp_session_client.dart';
import 'package:flutter/services.dart';
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

    test('ignores stale in-flight writePcm completion after stop and restart',
        () async {
      final writeCompleter = Completer<AudioPlayoutStatus>();
      final platform = _DelayedWritePlatform(writeCompleter);
      final s1 = FakeAudioSession();
      final s2 = FakeAudioSession();
      final ctrl = AudioSinkController(platform: platform);

      await ctrl.start(
        session: s1,
        sampleRate: 48000,
        channels: 2,
        bitsPerSample: 16,
      );
      // Start an in-flight writePcm on s1 that stays pending across stop() + start(s2).
      final inflightPump = ctrl.pumpOnce();
      await Future<void>.delayed(Duration.zero);

      await ctrl.stop();
      await ctrl.start(
        session: s2,
        sampleRate: 48000,
        channels: 2,
        bitsPerSample: 16,
      );

      // Resolve s1's stale writePcm with 960 frames played; s2 must NOT credit them.
      writeCompleter.complete(
        const AudioPlayoutStatus(framesPlayedDelta: 960, paused: false),
      );
      await inflightPump;

      await ctrl.pumpOnce();
      expect(s2.creditedFrames, <int>[0]);
      await ctrl.stop();
    });

    test(
        'falls back to virtual-clock drain when platform writePcm reports paused/dead track',
        () async {
      final platform = FakeAudioSinkPlatform()..nextDelta = 0;
      final session = FakeAudioSession();
      final ctrl = AudioSinkController(platform: platform);

      await ctrl.start(
        session: session,
        sampleRate: 48000,
        channels: 2,
        bitsPerSample: 16,
      );
      await ctrl.pumpOnce();
      expect(session.creditedFrames.last, 0);

      // Simulate AudioTrack.write returning negative error code -> Sink returns paused: true.
      platform.paused = true;
      await ctrl.pumpOnce();
      expect(ctrl.isPaused, isTrue);

      // Subsequent pump must switch to virtual-clock drain and credit > 0 frames without stalling.
      await ctrl.pumpOnce();
      expect(session.creditedFrames.last, greaterThan(0));
      await ctrl.stop();
    });

    test(
        'start() interrupted by stop() during pending close() does not resurrect timer or reopen platform',
        () async {
      final closeCompleter = Completer<void>();
      final platform = _LifecycleProbePlatform();
      final s1 = FakeAudioSession();
      final s2 = FakeAudioSession();
      final ctrl = AudioSinkController(platform: platform);

      await ctrl.start(
        session: s1,
        sampleRate: 48000,
        channels: 2,
        bitsPerSample: 16,
      );
      expect(platform.openCalls, 1);
      expect(ctrl.isRunning, isTrue);

      // Gate the close() triggered by the next start(s2) call.
      platform.nextCloseFuture = closeCompleter.future;
      final staleStart = ctrl.start(
        session: s2,
        sampleRate: 48000,
        channels: 2,
        bitsPerSample: 16,
      );
      await Future<void>.delayed(Duration.zero);

      // Interrupt with stop() while close() is still pending.
      final stopFuture = ctrl.stop();
      await Future<void>.delayed(Duration.zero);

      closeCompleter.complete();
      await Future.wait<void>(<Future<void>>[staleStart, stopFuture]);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(ctrl.isRunning, isFalse);
      expect(platform.openCalls, 1);
      expect(platform.closeCalls, 1);
      expect(platform.events, <String>['open', 'close']);
      expect(s2.creditedFrames, isEmpty);
    });

    test('stop() during pending open() closes native platform once open completes',
        () async {
      final open1Completer = Completer<bool>();
      final platform = _LifecycleProbePlatform()
        ..nextOpenFuture = open1Completer.future;
      final s1 = FakeAudioSession();
      final s2 = FakeAudioSession();
      final ctrl = AudioSinkController(platform: platform);

      final start1 = ctrl.start(
        session: s1,
        sampleRate: 48000,
        channels: 2,
        bitsPerSample: 16,
      );
      await Future<void>.delayed(Duration.zero);

      final stopFuture = ctrl.stop();
      final start2 = ctrl.start(
        session: s2,
        sampleRate: 48000,
        channels: 2,
        bitsPerSample: 16,
      );
      await Future<void>.delayed(Duration.zero);

      // Only once open1 resolves should close() run, followed strictly by open2.
      expect(platform.events, <String>['open']);
      open1Completer.complete(true);
      await Future.wait<void>(<Future<void>>[start1, stopFuture, start2]);

      expect(platform.closeCalls, greaterThanOrEqualTo(1));
      expect(platform.events, <String>['open', 'close', 'open']);
      expect(ctrl.isRunning, isTrue);

      await ctrl.stop();
      expect(ctrl.isRunning, isFalse);
      expect(platform.events, <String>['open', 'close', 'open', 'close']);
      expect(s1.creditedFrames, isEmpty);
    });

    test(
        'rapid synchronous start -> stop -> start skips stale open and swallows teardown platform errors',
        () async {
      final platform = _LifecycleProbePlatform()
        ..closeError = PlatformException(code: 'TEARDOWN_ERR');
      final s1 = FakeAudioSession();
      final s2 = FakeAudioSession();
      final ctrl = AudioSinkController(platform: platform);

      final f1 = ctrl.start(
        session: s1,
        sampleRate: 48000,
        channels: 2,
        bitsPerSample: 16,
      );
      final fStop = ctrl.stop();
      final f2 = ctrl.start(
        session: s2,
        sampleRate: 48000,
        channels: 2,
        bitsPerSample: 16,
      );

      await Future.wait<void>(<Future<void>>[f1, fStop, f2]);
      expect(ctrl.isRunning, isTrue);
      expect(platform.events, <String>['open']);
      expect(s1.creditedFrames, isEmpty);

      await ctrl.stop();
      expect(ctrl.isRunning, isFalse);
      expect(platform.events, <String>['open', 'close']);
    });
  });

  // Reference AudioMode to avoid unused import warning if needed.
  test('AudioMode enum exposes local/remote/off', () {
    expect(AudioMode.values, hasLength(3));
  });
}

class _DelayedWritePlatform extends FakeAudioSinkPlatform {
  _DelayedWritePlatform(this.pendingWrite);

  final Completer<AudioPlayoutStatus> pendingWrite;
  bool useImmediate = false;

  @override
  Future<AudioPlayoutStatus> writePcm(Uint8List pcmBytes) {
    writes++;
    if (!useImmediate) {
      useImmediate = true;
      return pendingWrite.future;
    }
    return Future<AudioPlayoutStatus>.value(
      const AudioPlayoutStatus(framesPlayedDelta: 0, paused: false),
    );
  }
}

class _LifecycleProbePlatform extends FakeAudioSinkPlatform {
  final List<String> events = <String>[];
  int openCalls = 0;
  int closeCalls = 0;
  Future<bool>? nextOpenFuture;
  Future<void>? nextCloseFuture;
  Object? closeError;

  @override
  Future<bool> open({
    required int sampleRate,
    required int channels,
    required int bitsPerSample,
  }) async {
    openCalls++;
    events.add('open');
    final pending = nextOpenFuture;
    nextOpenFuture = null;
    opened = pending != null ? await pending : true;
    return opened;
  }

  @override
  Future<void> close() async {
    closeCalls++;
    events.add('close');
    final pending = nextCloseFuture;
    nextCloseFuture = null;
    if (pending != null) {
      await pending;
    }
    final err = closeError;
    if (err != null) {
      throw err;
    }
    closed = true;
  }
}
