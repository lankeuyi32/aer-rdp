import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../models/connection_profile.dart';
import '../../models/session_models.dart';
import '../../services/rdp_session_client.dart';
import '../aer_keys.dart';
import 'viewport_controller.dart';

enum _TwoFingerGestureKind {
  undecided,
  scroll,
  pinch,
}

class SessionCanvas extends StatefulWidget {
  const SessionCanvas({
    super.key,
    required this.controller,
    required this.viewportController,
    required this.inputMode,
    required this.swapButtons,
    this.cursorState,
    this.frameRevision = 0,
    this.touchResetEpoch = 0,
    this.bottomObstruction = 0.0,
    this.targetFps = 60,
    this.customMaxBandwidthMbps,
    this.onPointerDownFocus,
  });

  final RdpSessionController controller;
  final ViewportController viewportController;
  final InputMode inputMode;
  final bool swapButtons;
  final CursorState? cursorState;
  final int frameRevision;
  final int touchResetEpoch;
  final double bottomObstruction;
  final int targetFps;
  final int? customMaxBandwidthMbps;
  final VoidCallback? onPointerDownFocus;

  @override
  State<SessionCanvas> createState() => _SessionCanvasState();
}

class _SessionCanvasState extends State<SessionCanvas> {
  ui.Image? _frameImage;
  int _fbWidth = 0;
  int _fbHeight = 0;
  bool _inFlightPull = false;
  bool _pendingPull = false;
  bool _pendingForceFull = false;
  bool _vsyncCallbackArmed = false;
  Duration? _lastPullVsyncTs;
  int _lastPatchBytes = 0;

  final Map<int, Offset> _activeTouches = <int, Offset>{};
  final Map<int, DateTime> _touchUpdatedAt = <int, DateTime>{};
  int _pressedTouchButtonMask = 0;
  int _pressedMouseButtonMask = 0;
  double _virtualCursorX = 640;
  double _virtualCursorY = 360;
  bool _virtualCursorInitialized = false;
  late final ValueNotifier<int> _cursorPaintTick;
  bool _pointerModeMoved = false;
  Offset _pointerDownViewportPos = Offset.zero;
  Timer? _pointerLongPressTimer;
  DateTime? _lastPointerTapAt;
  Offset? _lastPointerTapPos;
  bool _twoFingerGestureActive = false;
  bool _twoFingerMoved = false;
  _TwoFingerGestureKind _twoFingerKind = _TwoFingerGestureKind.undecided;
  final Map<int, Offset> _twoFingerStartPositions = <int, Offset>{};
  Offset _twoFingerFocalDown = Offset.zero;
  Offset? _lastTwoFingerFocal;
  double _pinchBaseZoom = 1.0;
  double _pinchStartDistance = 0.0;
  double _twoFingerScrollRemainderV = 0.0;
  double _trackpadBaseZoom = 1.0;
  bool _trackpadPinching = false;
  double _trackpadScrollRemainderV = 0.0;
  double _trackpadScrollRemainderH = 0.0;

  @override
  void initState() {
    super.initState();
    _virtualCursorX = widget.viewportController.remoteWidth / 2.0;
    _virtualCursorY = widget.viewportController.remoteHeight / 2.0;
    _virtualCursorInitialized = true;
    _cursorPaintTick = ValueNotifier<int>(0);
    widget.viewportController.addListener(_onViewportChanged);
    unawaited(_pullFrame(forceFull: true));
  }

  @override
  void didUpdateWidget(covariant SessionCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.viewportController != widget.viewportController) {
      oldWidget.viewportController.removeListener(_onViewportChanged);
      widget.viewportController.addListener(_onViewportChanged);
    }
    if (oldWidget.touchResetEpoch != widget.touchResetEpoch) {
      _resetAllActiveTouches();
    }
    if (oldWidget.inputMode != widget.inputMode) {
      _ensureCursorCenteredIfNeeded();
      _bumpCursorPaint();
    }
    if (oldWidget.frameRevision != widget.frameRevision ||
        oldWidget.controller != widget.controller) {
      _scheduleFramePull(forceFull: oldWidget.controller != widget.controller);
    }
  }

  void _ensureCursorCenteredIfNeeded() {
    final int rw = widget.viewportController.remoteWidth;
    final int rh = widget.viewportController.remoteHeight;
    if (!_virtualCursorInitialized ||
        _virtualCursorX < 0 ||
        _virtualCursorY < 0 ||
        _virtualCursorX >= rw ||
        _virtualCursorY >= rh) {
      _virtualCursorX = (rw / 2.0).clamp(0.0, (rw - 1).clamp(0, 8191).toDouble());
      _virtualCursorY = (rh / 2.0).clamp(0.0, (rh - 1).clamp(0, 8191).toDouble());
      _virtualCursorInitialized = true;
    }
  }

  void _bumpCursorPaint() {
    _cursorPaintTick.value = (_cursorPaintTick.value + 1) & 0x3fffffff;
  }

  void _resetAllActiveTouches() {
    _pointerLongPressTimer?.cancel();
    _pointerLongPressTimer = null;
    _activeTouches.clear();
    _touchUpdatedAt.clear();
    _twoFingerGestureActive = false;
    _twoFingerMoved = false;
    _twoFingerKind = _TwoFingerGestureKind.undecided;
    _twoFingerStartPositions.clear();
    _twoFingerScrollRemainderV = 0.0;
    _lastTwoFingerFocal = null;
    _releaseTouchButton(Offset(_virtualCursorX, _virtualCursorY));
    _bumpCursorPaint();
  }

  void _pruneStaleTouches(int incomingPointer) {
    if (_activeTouches.isEmpty) return;
    final DateTime now = DateTime.now();
    final List<int> staleIds = <int>[];
    _touchUpdatedAt.forEach((int ptr, DateTime ts) {
      if (ptr != incomingPointer &&
          now.difference(ts) > const Duration(milliseconds: 1500)) {
        staleIds.add(ptr);
      }
    });
    if (staleIds.isNotEmpty) {
      for (final int id in staleIds) {
        _activeTouches.remove(id);
        _touchUpdatedAt.remove(id);
      }
      if (_activeTouches.isEmpty) {
        _twoFingerGestureActive = false;
        _twoFingerMoved = false;
        _twoFingerKind = _TwoFingerGestureKind.undecided;
        _twoFingerStartPositions.clear();
        _twoFingerScrollRemainderV = 0.0;
        _lastTwoFingerFocal = null;
        _releaseTouchButton(Offset(_virtualCursorX, _virtualCursorY));
      }
    }
  }

  @override
  void dispose() {
    _pointerLongPressTimer?.cancel();
    _pointerLongPressTimer = null;
    widget.viewportController.removeListener(_onViewportChanged);
    _cursorPaintTick.dispose();
    _frameImage?.dispose();
    super.dispose();
  }

  void _onViewportChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  int _computeMinIntervalUs() {
    final int fps = widget.targetFps.clamp(15, 120);
    int minIntervalUs = (1000000 / fps).round();
    final int? customMbps = widget.customMaxBandwidthMbps;
    if (customMbps != null && customMbps > 0 && _lastPatchBytes > 0) {
      final int approxWireBits = (_lastPatchBytes * 8) ~/ 6;
      final int bwIntervalUs =
          (approxWireBits / customMbps).round().clamp(0, 100000);
      if (bwIntervalUs > minIntervalUs) {
        minIntervalUs = bwIntervalUs;
      }
    }
    return minIntervalUs;
  }

  void _scheduleFramePull({bool forceFull = false}) {
    if (!mounted) return;
    if (_inFlightPull) {
      _pendingPull = true;
      if (forceFull) {
        _pendingForceFull = true;
      }
      return;
    }
    if (forceFull || _lastPullVsyncTs == null) {
      unawaited(_pullFrame(forceFull: forceFull));
      return;
    }
    if (_vsyncCallbackArmed) {
      return;
    }
    _vsyncCallbackArmed = true;
    SchedulerBinding.instance.scheduleFrameCallback(_onVsyncTick);
  }

  void _onVsyncTick(Duration timeStamp) {
    _vsyncCallbackArmed = false;
    if (!mounted) return;
    if (_inFlightPull) {
      _pendingPull = true;
      return;
    }
    final Duration? prevTs = _lastPullVsyncTs;
    final int minIntervalUs = _computeMinIntervalUs();
    if (prevTs != null) {
      final int elapsedUs = (timeStamp - prevTs).inMicroseconds;
      // Guard against non-monotonic timestamps across test bindings; allow >= 85% of vsync budget so 60fps doesn't skip every other 60Hz tick.
      if (elapsedUs >= 0 && elapsedUs < (minIntervalUs * 85) ~/ 100) {
        _vsyncCallbackArmed = true;
        SchedulerBinding.instance.scheduleFrameCallback(_onVsyncTick);
        return;
      }
    }
    _lastPullVsyncTs = timeStamp;
    final bool nextFull = _pendingForceFull;
    _pendingForceFull = false;
    unawaited(_pullFrame(forceFull: nextFull, recordedTs: timeStamp));
  }

  Future<void> _pullFrame({bool forceFull = false, Duration? recordedTs}) async {
    if (_inFlightPull) {
      _pendingPull = true;
      if (forceFull) {
        _pendingForceFull = true;
      }
      return;
    }
    _inFlightPull = true;
    if (recordedTs != null) {
      _lastPullVsyncTs = recordedTs;
    } else if (SchedulerBinding.instance.schedulerPhase !=
        SchedulerPhase.idle) {
      _lastPullVsyncTs = SchedulerBinding.instance.currentFrameTimeStamp;
    } else {
      _lastPullVsyncTs ??= Duration.zero;
    }
    int lastPatchBytes = 0;
    try {
      final bool requestFull = forceFull || _frameImage == null;
      final patch =
          await widget.controller.takeFramePatch(forceFull: requestFull);
      if (patch != null &&
          mounted &&
          patch.fbWidth > 0 &&
          patch.fbHeight > 0 &&
          patch.w > 0 &&
          patch.h > 0) {
        lastPatchBytes = patch.rgbaBytes.length;
        final ui.Image? nextImage = await _composePatchGpu(patch);
        if (nextImage != null) {
          if (mounted) {
            final old = _frameImage;
            setState(() {
              _frameImage = nextImage;
            });
            if (!identical(old, nextImage)) {
              old?.dispose();
            }
          } else {
            nextImage.dispose();
          }
        }
      }
    } finally {
      _lastPatchBytes = lastPatchBytes;
      _inFlightPull = false;
      if (_pendingPull && mounted) {
        final bool nextFull = _pendingForceFull;
        _pendingPull = false;
        _pendingForceFull = false;
        _scheduleFramePull(forceFull: nextFull);
      }
    }
  }

  Future<ui.Image?> _composePatchGpu(FramePatch patch) async {
    final bool sizeChanged =
        _fbWidth != patch.fbWidth || _fbHeight != patch.fbHeight;
    if (sizeChanged) {
      final bool firstSetup = _fbWidth == 0 || _fbHeight == 0;
      _fbWidth = patch.fbWidth;
      _fbHeight = patch.fbHeight;
      widget.viewportController.setRemoteSize(_fbWidth, _fbHeight);
      if (firstSetup ||
          !_virtualCursorInitialized ||
          _virtualCursorX >= _fbWidth ||
          _virtualCursorY >= _fbHeight) {
        _virtualCursorX = _fbWidth / 2.0;
        _virtualCursorY = _fbHeight / 2.0;
        _virtualCursorInitialized = true;
      }
    }

    final int neededBytes = patch.w * patch.h * 4;
    if (patch.rgbaBytes.length < neededBytes) {
      return null;
    }
    final Uint8List exactRgba = patch.rgbaBytes.length == neededBytes
        ? patch.rgbaBytes
        : Uint8List.sublistView(patch.rgbaBytes, 0, neededBytes);

    if (patch.isFullFrame &&
        patch.x == 0 &&
        patch.y == 0 &&
        patch.w == patch.fbWidth &&
        patch.h == patch.fbHeight) {
      return _decodeRgbaImage(exactRgba, patch.fbWidth, patch.fbHeight);
    }

    final ui.Image subImage =
        await _decodeRgbaImage(exactRgba, patch.w, patch.h);
    final ui.Image? baseImage = !sizeChanged ? _frameImage : null;
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(
      recorder,
      Rect.fromLTWH(
        0,
        0,
        patch.fbWidth.toDouble(),
        patch.fbHeight.toDouble(),
      ),
    );
    if (baseImage != null &&
        baseImage.width == patch.fbWidth &&
        baseImage.height == patch.fbHeight) {
      canvas.drawImage(
        baseImage,
        Offset.zero,
        Paint()
          ..blendMode = BlendMode.src
          ..filterQuality = FilterQuality.none,
      );
    } else {
      canvas.drawRect(
        Rect.fromLTWH(
          0,
          0,
          patch.fbWidth.toDouble(),
          patch.fbHeight.toDouble(),
        ),
        Paint()..color = const Color(0xFF000000),
      );
    }
    canvas.drawImage(
      subImage,
      Offset(patch.x.toDouble(), patch.y.toDouble()),
      Paint()
        ..blendMode = BlendMode.src
        ..filterQuality = FilterQuality.none,
    );
    final ui.Picture picture = recorder.endRecording();
    try {
      return await picture.toImage(patch.fbWidth, patch.fbHeight);
    } finally {
      picture.dispose();
      subImage.dispose();
    }
  }

  Future<ui.Image> _decodeRgbaImage(Uint8List rgba, int width, int height) {
    final Completer<ui.Image> completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      rgba,
      width,
      height,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }

  int _primaryButtonMask() =>
      widget.swapButtons ? RdpPointerButtons.right : RdpPointerButtons.left;

  int _secondaryButtonMask() =>
      widget.swapButtons ? RdpPointerButtons.left : RdpPointerButtons.right;

  int _mapMouseButtons(int flutterButtons) {
    int mask = RdpPointerButtons.none;
    if ((flutterButtons & kPrimaryMouseButton) != 0) {
      mask |=
          widget.swapButtons ? RdpPointerButtons.right : RdpPointerButtons.left;
    }
    if ((flutterButtons & kSecondaryMouseButton) != 0) {
      mask |=
          widget.swapButtons ? RdpPointerButtons.left : RdpPointerButtons.right;
    }
    if ((flutterButtons & kMiddleMouseButton) != 0) {
      mask |= RdpPointerButtons.middle;
    }
    return mask;
  }

  void _releaseTouchButton(Offset lastRemote) {
    if (_pressedTouchButtonMask == 0) return;
    final mask = _pressedTouchButtonMask;
    _pressedTouchButtonMask = 0;
    _bumpCursorPaint();
    unawaited(
      widget.controller.sendPointerEvent(
        x: lastRemote.dx.round(),
        y: lastRemote.dy.round(),
        buttonMask: mask,
        down: false,
      ),
    );
  }

  void _handlePointerDown(PointerDownEvent event) {
    widget.onPointerDownFocus?.call();
    if (event.kind == PointerDeviceKind.touch) {
      _pruneStaleTouches(event.pointer);
      final DateTime now = DateTime.now();
      _activeTouches[event.pointer] = event.localPosition;
      _touchUpdatedAt[event.pointer] = now;
      if (_activeTouches.length == 1) {
        _twoFingerGestureActive = false;
        _twoFingerMoved = false;
        _twoFingerKind = _TwoFingerGestureKind.undecided;
        _twoFingerStartPositions.clear();
        _twoFingerScrollRemainderV = 0.0;
        _lastTwoFingerFocal = null;
        _pointerModeMoved = false;
        _pointerDownViewportPos = event.localPosition;
        if (widget.inputMode == InputMode.directTouch) {
          final remote =
              widget.viewportController.viewportToRemote(event.localPosition);
          if (remote != null) {
            _virtualCursorX = remote.dx;
            _virtualCursorY = remote.dy;
            _virtualCursorInitialized = true;
            widget.viewportController.setFocusRemoteY(remote.dy);
            _pressedTouchButtonMask = _primaryButtonMask();
            unawaited(
              widget.controller.sendPointerEvent(
                x: remote.dx.round(),
                y: remote.dy.round(),
                buttonMask: _pressedTouchButtonMask,
                down: true,
              ),
            );
          }
        } else {
          _ensureCursorCenteredIfNeeded();
          final bool isDoubleTapDrag = _lastPointerTapAt != null &&
              _lastPointerTapPos != null &&
              now.difference(_lastPointerTapAt!) <=
                  const Duration(milliseconds: 300) &&
              (event.localPosition - _lastPointerTapPos!).distance <= 42.0;
          if (isDoubleTapDrag) {
            _lastPointerTapAt = null;
            _lastPointerTapPos = null;
            _pressedTouchButtonMask = _primaryButtonMask();
            _bumpCursorPaint();
            unawaited(
              widget.controller.sendPointerEvent(
                x: _virtualCursorX.round(),
                y: _virtualCursorY.round(),
                buttonMask: _pressedTouchButtonMask,
                down: true,
              ),
            );
          } else {
            _pointerLongPressTimer?.cancel();
            _pointerLongPressTimer = Timer(
              const Duration(milliseconds: 350),
              () {
                if (!mounted ||
                    _activeTouches.length != 1 ||
                    _pointerModeMoved ||
                    _pressedTouchButtonMask != 0 ||
                    widget.inputMode != InputMode.pointer) {
                  return;
                }
                _pressedTouchButtonMask = _primaryButtonMask();
                _bumpCursorPaint();
                unawaited(HapticFeedback.selectionClick());
                unawaited(
                  widget.controller.sendPointerEvent(
                    x: _virtualCursorX.round(),
                    y: _virtualCursorY.round(),
                    buttonMask: _pressedTouchButtonMask,
                    down: true,
                  ),
                );
              },
            );
          }
        }
      } else if (_activeTouches.length == 2) {
        _pointerLongPressTimer?.cancel();
        _pointerLongPressTimer = null;
        _releaseTouchButton(Offset(_virtualCursorX, _virtualCursorY));
        _twoFingerGestureActive = true;
        _twoFingerMoved = false;
        _twoFingerKind = _TwoFingerGestureKind.undecided;
        _twoFingerStartPositions
          ..clear()
          ..addAll(_activeTouches);
        _twoFingerScrollRemainderV = 0.0;
        final pts = _activeTouches.values.toList(growable: false);
        _pinchStartDistance = (pts[0] - pts[1]).distance.clamp(1.0, 10000.0);
        _pinchBaseZoom = widget.viewportController.zoom;
        _twoFingerFocalDown = (pts[0] + pts[1]) / 2.0;
        _lastTwoFingerFocal = _twoFingerFocalDown;
      }
      return;
    }

    final remote =
        widget.viewportController.viewportToRemote(event.localPosition);
    if (remote == null) return;
    _virtualCursorX = remote.dx;
    _virtualCursorY = remote.dy;
    _virtualCursorInitialized = true;
    _bumpCursorPaint();
    final int mapped = _mapMouseButtons(event.buttons);
    final int effectiveMask = mapped == 0 ? _primaryButtonMask() : mapped;
    final int newlyPressed = effectiveMask & ~_pressedMouseButtonMask;
    _pressedMouseButtonMask |= effectiveMask;
    unawaited(
      widget.controller.sendPointerEvent(
        x: remote.dx.round(),
        y: remote.dy.round(),
        buttonMask: newlyPressed != 0 ? newlyPressed : effectiveMask,
        down: true,
      ),
    );
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (event.kind == PointerDeviceKind.touch) {
      if (!_activeTouches.containsKey(event.pointer)) {
        return;
      }
      _activeTouches[event.pointer] = event.localPosition;
      _touchUpdatedAt[event.pointer] = DateTime.now();
      if (_activeTouches.length >= 2) {
        final entries = _activeTouches.entries.take(2).toList(growable: false);
        final int id0 = entries[0].key;
        final int id1 = entries[1].key;
        final Offset p0 = entries[0].value;
        final Offset p1 = entries[1].value;
        final double dist = (p0 - p1).distance.clamp(1.0, 10000.0);
        final Offset focal = (p0 + p1) / 2.0;
        final double distDelta = (dist - _pinchStartDistance).abs();
        final double focalDelta = (focal - _twoFingerFocalDown).distance;
        if (distDelta > 10.0 || focalDelta > 10.0) {
          _twoFingerMoved = true;
        }
        if (_twoFingerKind == _TwoFingerGestureKind.undecided) {
          final Offset start0 = _twoFingerStartPositions[id0] ?? p0;
          final Offset start1 = _twoFingerStartPositions[id1] ?? p1;
          final Offset d0 = p0 - start0;
          final Offset d1 = p1 - start1;
          final double len0 = d0.distance;
          final double len1 = d1.distance;
          final double cosAngle = (len0 > 3.0 && len1 > 3.0)
              ? ((d0.dx * d1.dx + d0.dy * d1.dy) / (len0 * len1))
              : 0.0;

          if (len0 > 6.0 &&
              len1 > 6.0 &&
              cosAngle > 0.5 &&
              focalDelta >= 10.0 &&
              focalDelta >= distDelta * 1.1) {
            // Both fingers moving in the same general direction -> lock to scroll/pan!
            _twoFingerKind = _TwoFingerGestureKind.scroll;
          } else if (len0 > 4.0 &&
              len1 > 4.0 &&
              cosAngle <= 0.15 &&
              distDelta > 14.0) {
            // Two fingers spreading or pinching in opposing directions -> lock to pinch!
            _twoFingerKind = _TwoFingerGestureKind.pinch;
          } else if ((len0 < 6.0 || len1 < 6.0) &&
              distDelta > 18.0 &&
              distDelta > focalDelta * 1.6) {
            // One finger anchored while second finger spreads/pinches -> lock to pinch!
            _twoFingerKind = _TwoFingerGestureKind.pinch;
          } else if (focalDelta > 20.0 && focalDelta > distDelta * 1.35) {
            _twoFingerKind = _TwoFingerGestureKind.scroll;
          }
        }
        if (_twoFingerKind == _TwoFingerGestureKind.pinch) {
          widget.viewportController.setZoom(
            _pinchBaseZoom * (dist / _pinchStartDistance),
            focalPoint: focal,
          );
          if (_lastTwoFingerFocal != null) {
            widget.viewportController.panBy(focal - _lastTwoFingerFocal!);
          }
        } else if ((_twoFingerKind == _TwoFingerGestureKind.scroll ||
                _twoFingerMoved) &&
            _lastTwoFingerFocal != null) {
          final Offset step = focal - _lastTwoFingerFocal!;
          if (step.dy.abs() >= step.dx.abs() * 0.7) {
            _twoFingerScrollRemainderV += -step.dy * 2.2;
            final int wheelV =
                _twoFingerScrollRemainderV.truncate().clamp(-256, 255);
            if (wheelV != 0) {
              _twoFingerScrollRemainderV -= wheelV;
              final Offset targetCursor = widget.inputMode == InputMode.pointer
                  ? Offset(_virtualCursorX, _virtualCursorY)
                  : (widget.viewportController.viewportToRemote(focal) ??
                      Offset(_virtualCursorX, _virtualCursorY));
              unawaited(
                widget.controller.sendPointerEvent(
                  x: targetCursor.dx.round(),
                  y: targetCursor.dy.round(),
                  buttonMask: RdpPointerButtons.none,
                  down: false,
                  wheelDeltaV: wheelV,
                ),
              );
            }
          } else {
            widget.viewportController.panBy(step);
          }
        }
        _lastTwoFingerFocal = focal;
        return;
      }

      if (_twoFingerGestureActive) {
        return;
      }

      if (widget.inputMode == InputMode.directTouch) {
        final remote =
            widget.viewportController.viewportToRemote(event.localPosition);
        if (remote != null) {
          _virtualCursorX = remote.dx;
          _virtualCursorY = remote.dy;
          _virtualCursorInitialized = true;
          widget.viewportController.setFocusRemoteY(remote.dy);
          unawaited(
            widget.controller.sendPointerEvent(
              x: remote.dx.round(),
              y: remote.dy.round(),
              buttonMask: _pressedTouchButtonMask,
              down: _pressedTouchButtonMask != 0,
            ),
          );
        }
      } else {
        if ((event.localPosition - _pointerDownViewportPos).distance > 4.0 ||
            event.localDelta.distance > 0.5) {
          _pointerModeMoved = true;
          if (_pressedTouchButtonMask == 0) {
            _pointerLongPressTimer?.cancel();
            _pointerLongPressTimer = null;
          }
        }
        final int rw = widget.viewportController.remoteWidth;
        final int rh = widget.viewportController.remoteHeight;
        final int maxW = (rw - 1).clamp(0, 8191);
        final int maxH = (rh - 1).clamp(0, 8191);

        // Convert logical touch delta into remote desktop pixel movement with smooth acceleration.
        final Rect rect = widget.viewportController.computeDisplayRect();
        final double baseScaleX =
            (rect.width > 1.0 && rw > 0) ? (rw / rect.width) : 1.0;
        final double baseScaleY =
            (rect.height > 1.0 && rh > 0) ? (rh / rect.height) : 1.0;
        final double speed = event.localDelta.distance;
        final double accel = (1.15 + speed * 0.05).clamp(1.15, 2.25);

        _virtualCursorX =
            (_virtualCursorX + event.localDelta.dx * baseScaleX * accel)
                .clamp(0.0, maxW.toDouble());
        _virtualCursorY =
            (_virtualCursorY + event.localDelta.dy * baseScaleY * accel)
                .clamp(0.0, maxH.toDouble());
        _virtualCursorInitialized = true;
        widget.viewportController.setFocusRemoteY(_virtualCursorY);

        // Auto-pan zoomed or keyboard-lifted viewport when virtual cursor nears visible edges.
        if ((widget.viewportController.zoom > 1.01 ||
                widget.viewportController.bottomObstruction > 0.0) &&
            !rect.isEmpty) {
          final Size vpSize = widget.viewportController.viewportSize;
          final double cx = rect.left + (_virtualCursorX / rw) * rect.width;
          final double cy = rect.top + (_virtualCursorY / rh) * rect.height;
          const double edgeMargin = 28.0;
          final double visibleBottom = (vpSize.height -
                  widget.viewportController.bottomObstruction)
              .clamp(edgeMargin * 2.0, vpSize.height);
          double panDx = 0.0;
          double panDy = 0.0;
          if (cx < edgeMargin) {
            panDx = edgeMargin - cx;
          } else if (cx > vpSize.width - edgeMargin) {
            panDx = (vpSize.width - edgeMargin) - cx;
          }
          if (cy < edgeMargin) {
            panDy = edgeMargin - cy;
          } else if (cy > visibleBottom - edgeMargin) {
            panDy = (visibleBottom - edgeMargin) - cy;
          }
          if (panDx != 0.0 || panDy != 0.0) {
            widget.viewportController.panBy(Offset(panDx, panDy));
          }
        }

        _bumpCursorPaint();
        unawaited(
          widget.controller.sendPointerEvent(
            x: _virtualCursorX.round(),
            y: _virtualCursorY.round(),
            buttonMask: _pressedTouchButtonMask,
            down: _pressedTouchButtonMask != 0,
          ),
        );
      }
      return;
    }

    final remote =
        widget.viewportController.viewportToRemote(event.localPosition);
    if (remote == null) return;
    _virtualCursorX = remote.dx;
    _virtualCursorY = remote.dy;
    _virtualCursorInitialized = true;
    _bumpCursorPaint();
    final int currentMask = _mapMouseButtons(event.buttons);
    final int released = _pressedMouseButtonMask & ~currentMask;
    final int pressed = currentMask & ~_pressedMouseButtonMask;
    _pressedMouseButtonMask = currentMask;
    if (released != 0) {
      unawaited(
        widget.controller.sendPointerEvent(
          x: remote.dx.round(),
          y: remote.dy.round(),
          buttonMask: released,
          down: false,
        ),
      );
    }
    if (pressed != 0) {
      unawaited(
        widget.controller.sendPointerEvent(
          x: remote.dx.round(),
          y: remote.dy.round(),
          buttonMask: pressed,
          down: true,
        ),
      );
    }
    if (released == 0 && pressed == 0) {
      unawaited(
        widget.controller.sendPointerEvent(
          x: remote.dx.round(),
          y: remote.dy.round(),
          buttonMask: currentMask,
          down: currentMask != 0,
        ),
      );
    }
  }

  void _handlePointerUp(PointerUpEvent event) {
    if (event.kind == PointerDeviceKind.touch) {
      _activeTouches.remove(event.pointer);
      _touchUpdatedAt.remove(event.pointer);
      _pointerLongPressTimer?.cancel();
      _pointerLongPressTimer = null;
      if (_twoFingerGestureActive) {
        if (_activeTouches.isEmpty) {
          if (!_twoFingerMoved) {
            final Offset remote = widget.inputMode == InputMode.pointer
                ? Offset(_virtualCursorX, _virtualCursorY)
                : (widget.viewportController
                        .viewportToRemote(_twoFingerFocalDown) ??
                    Offset(_virtualCursorX, _virtualCursorY));
            final int mask = _secondaryButtonMask();
            unawaited(
              widget.controller.sendPointerEvent(
                x: remote.dx.round(),
                y: remote.dy.round(),
                buttonMask: mask,
                down: true,
              ),
            );
            unawaited(
              widget.controller.sendPointerEvent(
                x: remote.dx.round(),
                y: remote.dy.round(),
                buttonMask: mask,
                down: false,
              ),
            );
          }
          _twoFingerGestureActive = false;
          _twoFingerMoved = false;
          _twoFingerKind = _TwoFingerGestureKind.undecided;
          _twoFingerStartPositions.clear();
          _twoFingerScrollRemainderV = 0.0;
          _lastTwoFingerFocal = null;
        }
        return;
      }
      if (widget.inputMode == InputMode.directTouch) {
        final remote =
            widget.viewportController.viewportToRemote(event.localPosition) ??
                Offset(_virtualCursorX, _virtualCursorY);
        _releaseTouchButton(remote);
      } else if (_pressedTouchButtonMask != 0) {
        _releaseTouchButton(Offset(_virtualCursorX, _virtualCursorY));
      } else if (!_pointerModeMoved && _activeTouches.isEmpty) {
        _lastPointerTapAt = DateTime.now();
        _lastPointerTapPos = event.localPosition;
        final int mask = _primaryButtonMask();
        final int x = _virtualCursorX.round();
        final int y = _virtualCursorY.round();
        unawaited(
          widget.controller.sendPointerEvent(
            x: x,
            y: y,
            buttonMask: mask,
            down: true,
          ),
        );
        unawaited(
          widget.controller.sendPointerEvent(
            x: x,
            y: y,
            buttonMask: mask,
            down: false,
          ),
        );
      }
      return;
    }

    final remote =
        widget.viewportController.viewportToRemote(event.localPosition) ??
            Offset(_virtualCursorX, _virtualCursorY);
    final int currentMask = _mapMouseButtons(event.buttons);
    final int released = _pressedMouseButtonMask & ~currentMask;
    _pressedMouseButtonMask = currentMask;
    final int releaseMask = released != 0 ? released : _primaryButtonMask();
    unawaited(
      widget.controller.sendPointerEvent(
        x: remote.dx.round(),
        y: remote.dy.round(),
        buttonMask: releaseMask,
        down: false,
      ),
    );
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    _activeTouches.remove(event.pointer);
    _touchUpdatedAt.remove(event.pointer);
    _pointerLongPressTimer?.cancel();
    _pointerLongPressTimer = null;
    if (_activeTouches.isEmpty) {
      _twoFingerGestureActive = false;
      _twoFingerMoved = false;
      _twoFingerKind = _TwoFingerGestureKind.undecided;
      _twoFingerStartPositions.clear();
      _twoFingerScrollRemainderV = 0.0;
      _lastTwoFingerFocal = null;
    }
    _releaseTouchButton(Offset(_virtualCursorX, _virtualCursorY));
    if (_pressedMouseButtonMask != 0) {
      final int mouseMask = _pressedMouseButtonMask;
      _pressedMouseButtonMask = 0;
      final remote =
          widget.viewportController.viewportToRemote(event.localPosition) ??
              Offset(_virtualCursorX, _virtualCursorY);
      unawaited(
        widget.controller.sendPointerEvent(
          x: remote.dx.round(),
          y: remote.dy.round(),
          buttonMask: mouseMask,
          down: false,
        ),
      );
    }
  }

  void _handlePointerHover(PointerHoverEvent event) {
    final remote =
        widget.viewportController.viewportToRemote(event.localPosition);
    if (remote == null) return;
    _virtualCursorX = remote.dx;
    _virtualCursorY = remote.dy;
    _virtualCursorInitialized = true;
    _bumpCursorPaint();
    unawaited(
      widget.controller.sendPointerEvent(
        x: remote.dx.round(),
        y: remote.dy.round(),
        buttonMask: RdpPointerButtons.none,
        down: false,
      ),
    );
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      final remote =
          widget.viewportController.viewportToRemote(event.localPosition) ??
              Offset(_virtualCursorX, _virtualCursorY);
      final int wheelV = (-event.scrollDelta.dy).round().clamp(-256, 255);
      final int wheelH = event.scrollDelta.dx.round().clamp(-256, 255);
      if (wheelV != 0 || wheelH != 0) {
        unawaited(
          widget.controller.sendPointerEvent(
            x: remote.dx.round(),
            y: remote.dy.round(),
            buttonMask: RdpPointerButtons.none,
            down: false,
            wheelDeltaV: wheelV,
            wheelDeltaH: wheelH,
          ),
        );
      }
    }
  }

  void _handlePanZoomStart(PointerPanZoomStartEvent event) {
    _trackpadBaseZoom = widget.viewportController.zoom;
    _trackpadPinching = false;
    _trackpadScrollRemainderV = 0.0;
    _trackpadScrollRemainderH = 0.0;
  }

  void _handlePanZoomUpdate(PointerPanZoomUpdateEvent event) {
    if ((event.scale - 1.0).abs() > 0.02) {
      _trackpadPinching = true;
    }
    if (_trackpadPinching) {
      widget.viewportController.setZoom(
        _trackpadBaseZoom * event.scale,
        focalPoint: event.localPosition,
      );
      return;
    }
    final remote =
        widget.viewportController.viewportToRemote(event.localPosition) ??
            Offset(_virtualCursorX, _virtualCursorY);
    _trackpadScrollRemainderV += -event.localPanDelta.dy;
    _trackpadScrollRemainderH += event.localPanDelta.dx;
    final int wheelV = _trackpadScrollRemainderV.truncate().clamp(-256, 255);
    final int wheelH = _trackpadScrollRemainderH.truncate().clamp(-256, 255);
    if (wheelV != 0 || wheelH != 0) {
      _trackpadScrollRemainderV -= wheelV;
      _trackpadScrollRemainderH -= wheelH;
      unawaited(
        widget.controller.sendPointerEvent(
          x: remote.dx.round(),
          y: remote.dy.round(),
          buttonMask: RdpPointerButtons.none,
          down: false,
          wheelDeltaV: wheelV,
          wheelDeltaH: wheelH,
        ),
      );
    }
  }

  void _handlePanZoomEnd(PointerPanZoomEndEvent event) {
    _trackpadPinching = false;
    _trackpadScrollRemainderV = 0.0;
    _trackpadScrollRemainderH = 0.0;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        if (widget.viewportController.viewportSize != size ||
            (widget.viewportController.bottomObstruction -
                        widget.bottomObstruction)
                    .abs() >
                0.25) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            widget.viewportController.updateLayoutMetrics(
              viewportSize: size,
              bottomObstruction: widget.bottomObstruction,
            );
          });
        }

        final displayRect = widget.viewportController.computeDisplayRect(size);

        return MouseRegion(
          cursor: SystemMouseCursors.basic,
          child: Listener(
            key: AerKeys.sessionCanvas,
            behavior: HitTestBehavior.opaque,
            onPointerDown: _handlePointerDown,
            onPointerMove: _handlePointerMove,
            onPointerUp: _handlePointerUp,
            onPointerCancel: _handlePointerCancel,
            onPointerHover: _handlePointerHover,
            onPointerSignal: _handlePointerSignal,
            onPointerPanZoomStart: _handlePanZoomStart,
            onPointerPanZoomUpdate: _handlePanZoomUpdate,
            onPointerPanZoomEnd: _handlePanZoomEnd,
            child: SizedBox.expand(
              child: ValueListenableBuilder<int>(
                valueListenable: _cursorPaintTick,
                builder: (context, tick, _) {
                  return CustomPaint(
                    painter: _SessionPainter(
                      image: _frameImage,
                      displayRect: displayRect,
                      showVirtualCursor: widget.inputMode == InputMode.pointer,
                      virtualCursorX: _virtualCursorX,
                      virtualCursorY: _virtualCursorY,
                      cursorDragging: _pressedTouchButtonMask != 0,
                      remoteWidth: widget.viewportController.remoteWidth,
                      remoteHeight: widget.viewportController.remoteHeight,
                      paintTick: tick,
                    ),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SessionPainter extends CustomPainter {
  const _SessionPainter({
    required this.image,
    required this.displayRect,
    required this.showVirtualCursor,
    required this.virtualCursorX,
    required this.virtualCursorY,
    required this.cursorDragging,
    required this.remoteWidth,
    required this.remoteHeight,
    required this.paintTick,
  });

  final ui.Image? image;
  final Rect displayRect;
  final bool showVirtualCursor;
  final double virtualCursorX;
  final double virtualCursorY;
  final bool cursorDragging;
  final int remoteWidth;
  final int remoteHeight;
  final int paintTick;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFF000000),
    );

    if (image != null && !displayRect.isEmpty) {
      final src = Rect.fromLTWH(
        0,
        0,
        image!.width.toDouble(),
        image!.height.toDouble(),
      );
      canvas.drawImageRect(
        image!,
        src,
        displayRect,
        Paint()..filterQuality = FilterQuality.low,
      );
    }

    // Draw compact, crisp Windows-style mouse pointer arrow in Pointer/Trackpad mode.
    if (showVirtualCursor &&
        !displayRect.isEmpty &&
        remoteWidth > 0 &&
        remoteHeight > 0) {
      final double normX =
          (virtualCursorX / (remoteWidth <= 1 ? 1 : (remoteWidth - 1)))
              .clamp(0.0, 1.0);
      final double normY =
          (virtualCursorY / (remoteHeight <= 1 ? 1 : (remoteHeight - 1)))
              .clamp(0.0, 1.0);
      final double cx = displayRect.left + normX * displayRect.width;
      final double cy = displayRect.top + normY * displayRect.height;

      if (cursorDragging) {
        canvas.drawCircle(
          Offset(cx, cy),
          8.0,
          Paint()
            ..color = const Color(0x552196F3)
            ..style = PaintingStyle.fill,
        );
      }

      final Path arrow = Path()
        ..moveTo(cx, cy)
        ..lineTo(cx, cy + 10.8)
        ..lineTo(cx + 2.7, cy + 8.3)
        ..lineTo(cx + 4.5, cy + 12.2)
        ..lineTo(cx + 6.1, cy + 11.4)
        ..lineTo(cx + 4.3, cy + 7.5)
        ..lineTo(cx + 7.6, cy + 7.5)
        ..close();

      canvas.drawShadow(arrow, const Color(0x99000000), 2.0, false);
      canvas.drawPath(
        arrow,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.fill,
      );
      canvas.drawPath(
        arrow,
        Paint()
          ..color = const Color(0xEE111111)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0
          ..strokeJoin = StrokeJoin.round,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SessionPainter oldDelegate) {
    return oldDelegate.image != image ||
        oldDelegate.displayRect != displayRect ||
        oldDelegate.showVirtualCursor != showVirtualCursor ||
        oldDelegate.virtualCursorX != virtualCursorX ||
        oldDelegate.virtualCursorY != virtualCursorY ||
        oldDelegate.cursorDragging != cursorDragging ||
        oldDelegate.paintTick != paintTick;
  }
}
