import 'dart:async';

import 'package:flutter/services.dart';

import 'rdp_session_client.dart';

class AudioPlayoutStatus {
  const AudioPlayoutStatus({
    required this.framesPlayedDelta,
    required this.paused,
  });

  final int framesPlayedDelta;
  final bool paused;
}

abstract class AudioSinkPlatform {
  Future<bool> open({
    required int sampleRate,
    required int channels,
    required int bitsPerSample,
  });

  Future<AudioPlayoutStatus> writePcm(Uint8List pcmBytes);

  Future<AudioPlayoutStatus> pollPlayoutDelta();

  Future<void> pause();

  Future<void> resume();

  Future<void> close();
}

class MethodChannelAudioSinkPlatform implements AudioSinkPlatform {
  const MethodChannelAudioSinkPlatform([
    MethodChannel? channel,
  ]) : _channel = channel ?? const MethodChannel('dev.aer.rdp/audio');

  final MethodChannel _channel;

  @override
  Future<bool> open({
    required int sampleRate,
    required int channels,
    required int bitsPerSample,
  }) async {
    final res = await _channel.invokeMethod<bool>(
      'open',
      <String, Object>{
        'sampleRate': sampleRate,
        'channels': channels,
        'bitsPerSample': bitsPerSample,
      },
    );
    return res ?? false;
  }

  @override
  Future<AudioPlayoutStatus> writePcm(Uint8List pcmBytes) async {
    final res = await _channel.invokeMapMethod<String, dynamic>(
      'writePcm',
      <String, Object>{'pcmBytes': pcmBytes},
    );
    return _parseStatus(res);
  }

  @override
  Future<AudioPlayoutStatus> pollPlayoutDelta() async {
    final res =
        await _channel.invokeMapMethod<String, dynamic>('pollPlayoutDelta');
    return _parseStatus(res);
  }

  AudioPlayoutStatus _parseStatus(Map<String, dynamic>? map) {
    if (map == null) {
      return const AudioPlayoutStatus(framesPlayedDelta: 0, paused: true);
    }
    final delta = (map['framesPlayedDelta'] as num?)?.toInt() ?? 0;
    final paused = (map['paused'] as bool?) ?? false;
    return AudioPlayoutStatus(
      framesPlayedDelta: delta < 0 ? 0 : delta,
      paused: paused,
    );
  }

  @override
  Future<void> pause() => _channel.invokeMethod<void>('pause');

  @override
  Future<void> resume() => _channel.invokeMethod<void>('resume');

  @override
  Future<void> close() => _channel.invokeMethod<void>('close');
}

class AudioSinkController {
  AudioSinkController({
    AudioSinkPlatform? platform,
  }) : _platform = platform ?? const MethodChannelAudioSinkPlatform();

  final AudioSinkPlatform _platform;

  RdpSessionController? _session;
  Timer? _pumpTimer;
  bool _platformAvailable = false;
  bool _platformPaused = false;
  bool _appPaused = false;
  bool _muted = false;
  double _volume = 1.0;
  int _sampleRate = 48000;
  int _lastPlayedDelta = 0;
  Stopwatch? _virtualClock;
  bool _pumpInFlight = false;

  bool get isMuted => _muted;
  double get volume => _volume;
  bool get isRunning => _pumpTimer != null;
  bool get isPaused => _appPaused || _platformPaused;

  Future<void> start({
    required RdpSessionController session,
    required int sampleRate,
    required int channels,
    required int bitsPerSample,
  }) async {
    await stop();
    _session = session;
    _sampleRate = sampleRate > 0 ? sampleRate : 48000;
    _lastPlayedDelta = 0;
    _platformPaused = false;
    _virtualClock = Stopwatch()..start();

    try {
      _platformAvailable = await _platform.open(
        sampleRate: _sampleRate,
        channels: channels,
        bitsPerSample: bitsPerSample,
      );
      if (_appPaused && _platformAvailable) {
        await _platform.pause();
        _platformPaused = true;
      }
    } on MissingPluginException {
      _platformAvailable = false;
    } on PlatformException {
      _platformAvailable = false;
    } on UnimplementedError {
      _platformAvailable = false;
    }

    _pumpTimer = Timer.periodic(
      const Duration(milliseconds: 20),
      (_) => unawaited(pumpOnce()),
    );
  }

  Future<void> pumpOnce() async {
    final session = _session;
    if (session == null || _pumpInFlight) return;
    _pumpInFlight = true;
    try {
      final int requestedFrames = ((_sampleRate * 20) ~/ 1000).clamp(1, 4096);
      final bool useVirtualClock =
          !_platformAvailable || _appPaused || _platformPaused;

      int creditFrames = _lastPlayedDelta;
      if (useVirtualClock) {
        final clock = _virtualClock;
        if (clock != null) {
          final elapsedUs = clock.elapsedMicroseconds;
          clock.reset();
          creditFrames = (elapsedUs * _sampleRate) ~/ 1000000;
          if (creditFrames <= 0) {
            creditFrames = requestedFrames;
          }
        }
      }

      final stats = session.readAudioPcm(
        requestedFrames: requestedFrames,
        framesPlayedSinceLastRead: creditFrames,
      );

      if (!_platformAvailable) {
        _lastPlayedDelta = 0;
        return;
      }

      try {
        final AudioPlayoutStatus status;
        if (_appPaused || _platformPaused) {
          status = await _platform.pollPlayoutDelta();
        } else {
          status = await _platform.writePcm(stats.pcmBytes ?? Uint8List(0));
        }
        _platformPaused = status.paused;
        _lastPlayedDelta = _platformPaused ? 0 : status.framesPlayedDelta;
        if (!_platformPaused) {
          _virtualClock?.reset();
        }
      } on MissingPluginException {
        _platformAvailable = false;
        _lastPlayedDelta = 0;
      } on PlatformException {
        _platformAvailable = false;
        _lastPlayedDelta = 0;
      }
    } finally {
      _pumpInFlight = false;
    }
  }

  Future<void> setMuted(bool muted) async {
    _muted = muted;
    await _session?.setAudioMute(muted);
  }

  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0.0, 1.0);
    await _session?.setAudioVolume(_volume);
  }

  Future<void> onAppPaused() async {
    _appPaused = true;
    if (_platformAvailable) {
      try {
        await _platform.pause();
      } on MissingPluginException {
        _platformAvailable = false;
      } on PlatformException {
        // Ignore platform pause errors.
      }
    }
  }

  Future<void> onAppResumed() async {
    _appPaused = false;
    _platformPaused = false;
    if (_platformAvailable) {
      try {
        await _platform.resume();
      } on MissingPluginException {
        _platformAvailable = false;
      } on PlatformException {
        // Ignore platform resume errors.
      }
    }
  }

  Future<void> stop() async {
    _pumpTimer?.cancel();
    _pumpTimer = null;
    _virtualClock?.stop();
    _virtualClock = null;
    _session = null;
    _lastPlayedDelta = 0;
    if (_platformAvailable) {
      try {
        await _platform.close();
      } on MissingPluginException {
        // Ignore on headless tests.
      } on PlatformException {
        // Ignore on teardown.
      }
    }
    _platformAvailable = false;
    _platformPaused = false;
  }
}
