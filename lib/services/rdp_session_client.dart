import 'dart:async';

import '../models/session_models.dart';

/// Broadcasts [RdpSessionEvent]s without dropping events while 0 listeners are attached.
class SessionEventBroadcaster {
  SessionEventBroadcaster({void Function()? onFirstListen})
      : _onFirstListen = onFirstListen {
    _controller = StreamController<RdpSessionEvent>.broadcast(
      onListen: _handleListen,
      onCancel: _handleCancel,
    );
  }

  final void Function()? _onFirstListen;
  late final StreamController<RdpSessionEvent> _controller;
  final List<RdpSessionEvent> _bufferedEvents = <RdpSessionEvent>[];
  bool _hadAnyListener = false;
  bool _hasListener = false;
  bool _flushScheduled = false;
  bool _pendingClose = false;
  bool _disposed = false;

  Stream<RdpSessionEvent> get stream => _controller.stream;

  bool get isClosed => _controller.isClosed;

  void add(RdpSessionEvent event) {
    if (_disposed || _controller.isClosed) return;
    if (!_hasListener || _flushScheduled || _bufferedEvents.isNotEmpty) {
      _bufferedEvents.add(event);
    } else {
      _controller.add(event);
    }
  }

  void closeWhenDrained() {
    _pendingClose = true;
    if (_hasListener &&
        !_flushScheduled &&
        _bufferedEvents.isEmpty &&
        !_controller.isClosed) {
      _controller.close();
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _bufferedEvents.clear();
    if (!_controller.isClosed) {
      _controller.close();
    }
  }

  void _handleListen() {
    _hasListener = true;
    if (!_hadAnyListener) {
      _hadAnyListener = true;
      _onFirstListen?.call();
    }
    if (_bufferedEvents.isNotEmpty) {
      _scheduleFlush();
    } else if (_pendingClose && !_controller.isClosed) {
      scheduleMicrotask(() {
        if (!_disposed &&
            _hasListener &&
            _bufferedEvents.isEmpty &&
            !_controller.isClosed) {
          _controller.close();
        }
      });
    }
  }

  void _handleCancel() {
    if (!_controller.hasListener) {
      _hasListener = false;
    }
  }

  void _scheduleFlush() {
    if (_flushScheduled) return;
    _flushScheduled = true;
    scheduleMicrotask(() {
      _flushScheduled = false;
      if (_disposed || _controller.isClosed || !_hasListener) return;
      while (_bufferedEvents.isNotEmpty &&
          _hasListener &&
          !_disposed &&
          !_controller.isClosed) {
        final ev = _bufferedEvents.removeAt(0);
        _controller.add(ev);
      }
      if (_pendingClose &&
          _bufferedEvents.isEmpty &&
          !_controller.isClosed) {
        _controller.close();
      }
    });
  }
}

abstract class RdpSessionController {
  Stream<RdpSessionEvent> get events;

  Future<void> submitCertDecision(CertTrustDecision decision);

  Future<void> submitCredentials(AuthCredentials creds);

  Future<void> sendPointerEvent({
    required int x,
    required int y,
    required int buttonMask,
    required bool down,
    int wheelDeltaV = 0,
    int wheelDeltaH = 0,
  });

  Future<void> sendScancode({
    required int code,
    required bool extended,
    required bool down,
  });

  Future<void> sendUnicode({
    required int codeUnit,
    required bool down,
  });

  Future<void> setAudioMute(bool muted);

  Future<void> setAudioVolume(double volume);

  Future<FramePatch?> takeFramePatch({bool forceFull = false});

  AudioStats readAudioPcm({
    required int requestedFrames,
    required int framesPlayedSinceLastRead,
  });

  Future<void> disconnect();

  void dispose();
}

abstract class RdpSessionClient {
  Future<RdpSessionController> connect(ConnectRequest request);
}
