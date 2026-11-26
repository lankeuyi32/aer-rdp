import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

import '../../models/connection_profile.dart';
import '../../models/session_models.dart';
import '../../services/rdp_session_client.dart';
import '../aer_keys.dart';
import 'viewport_controller.dart';

class SessionCanvas extends StatefulWidget {
  const SessionCanvas({
    super.key,
    required this.controller,
    required this.viewportController,
    required this.inputMode,
    required this.swapButtons,
    this.cursorState,
    this.frameRevision = 0,
    this.onPointerDownFocus,
  });

  final RdpSessionController controller;
  final ViewportController viewportController;
  final InputMode inputMode;
  final bool swapButtons;
  final CursorState? cursorState;
  final int frameRevision;
  final VoidCallback? onPointerDownFocus;

  @override
  State<SessionCanvas> createState() => _SessionCanvasState();
}

class _SessionCanvasState extends State<SessionCanvas> {
  ui.Image? _frameImage;
  Uint8List? _backingRgba;
  int _fbWidth = 0;
  int _fbHeight = 0;
  bool _inFlightPull = false;
  bool _pendingPull = false;

  final Map<int, Offset> _activeTouches = <int, Offset>{};
  int _pressedTouchButtonMask = 0;
  int _pressedMouseButtonMask = 0;
  double _virtualCursorX = 0;
  double _virtualCursorY = 0;
  bool _virtualCursorInitialized = false;
  bool _pointerModeMoved = false;
  Offset _pointerDownViewportPos = Offset.zero;
  Timer? _pointerLongPressTimer;
  DateTime? _lastPointerTapAt;
  Offset? _lastPointerTapPos;
  bool _twoFingerGestureActive = false;
  bool _twoFingerMoved = false;
  bool _isTwoFingerPinch = false;
  Offset _twoFingerFocalDown = Offset.zero;
  Offset? _lastTwoFingerFocal;
  double _pinchBaseZoom = 1.0;
  double _pinchStartDistance = 0.0;
  double _trackpadBaseZoom = 1.0;
  bool _trackpadPinching = false;
  double _trackpadScrollRemainderV = 0.0;
  double _trackpadScrollRemainderH = 0.0;

  @override
  void initState() {
    super.initState();
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
    if (oldWidget.frameRevision != widget.frameRevision ||
        oldWidget.controller != widget.controller) {
      unawaited(_pullFrame(forceFull: oldWidget.controller != widget.controller));
    }
  }

  @override
  void dispose() {
    _pointerLongPressTimer?.cancel();
    _pointerLongPressTimer = null;
    widget.viewportController.removeListener(_onViewportChanged);
    _frameImage?.dispose();
    super.dispose();
  }

  void _onViewportChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _pullFrame({bool forceFull = false}) async {
    if (_inFlightPull) {
      _pendingPull = true;
      return;
    }
    _inFlightPull = true;
    try {
      final patch = await widget.controller.takeFramePatch(forceFull: forceFull);
      if (patch != null && mounted) {
        _applyPatch(patch);
        final decoded = await _decodeRgbaImage(
          _backingRgba!,
          _fbWidth,
          _fbHeight,
        );
        if (mounted) {
          final old = _frameImage;
          setState(() {
            _frameImage = decoded;
          });
          old?.dispose();
        } else {
          decoded.dispose();
        }
      }
    } finally {
      _inFlightPull = false;
      if (_pendingPull && mounted) {
        _pendingPull = false;
        unawaited(_pullFrame());
      }
    }
  }

  void _applyPatch(FramePatch patch) {
    final int expectedBytes = patch.fbWidth * patch.fbHeight * 4;
    if (_backingRgba == null ||
        _fbWidth != patch.fbWidth ||
        _fbHeight != patch.fbHeight ||
        _backingRgba!.length != expectedBytes) {
      _fbWidth = patch.fbWidth;
      _fbHeight = patch.fbHeight;
      _backingRgba = Uint8List(expectedBytes);
      widget.viewportController.setRemoteSize(_fbWidth, _fbHeight);
      if (!_virtualCursorInitialized) {
        _virtualCursorX = _fbWidth / 2.0;
        _virtualCursorY = _fbHeight / 2.0;
        _virtualCursorInitialized = true;
      }
    }

    final Uint8List target = _backingRgba!;
    if (patch.isFullFrame &&
        patch.x == 0 &&
        patch.y == 0 &&
        patch.w == patch.fbWidth &&
        patch.h == patch.fbHeight) {
      final int copyLen =
          patch.rgbaBytes.length < expectedBytes ? patch.rgbaBytes.length : expectedBytes;
      target.setRange(0, copyLen, patch.rgbaBytes);
      return;
    }

    final int rowBytes = patch.w * 4;
    final int fbStride = _fbWidth * 4;
    for (int row = 0; row < patch.h; row++) {
      final int srcOffset = row * rowBytes;
      final int dstOffset = (patch.y + row) * fbStride + patch.x * 4;
      if (srcOffset + rowBytes <= patch.rgbaBytes.length &&
          dstOffset + rowBytes <= target.length) {
        target.setRange(
          dstOffset,
          dstOffset + rowBytes,
          patch.rgbaBytes,
          srcOffset,
        );
      }
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
      _activeTouches[event.pointer] = event.localPosition;
      if (_activeTouches.length == 1) {
        _twoFingerGestureActive = false;
        _twoFingerMoved = false;
        _isTwoFingerPinch = false;
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
          final DateTime now = DateTime.now();
          final bool isDoubleTapDrag = _lastPointerTapAt != null &&
              _lastPointerTapPos != null &&
              now.difference(_lastPointerTapAt!) <=
                  const Duration(milliseconds: 300) &&
              (event.localPosition - _lastPointerTapPos!).distance <= 40.0;
          if (isDoubleTapDrag) {
            _lastPointerTapAt = null;
            _lastPointerTapPos = null;
            _pressedTouchButtonMask = _primaryButtonMask();
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
        _isTwoFingerPinch = false;
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
      _activeTouches[event.pointer] = event.localPosition;
      if (_activeTouches.length >= 2) {
        final pts = _activeTouches.values.toList(growable: false);
        final double dist = (pts[0] - pts[1]).distance.clamp(1.0, 10000.0);
        final Offset focal = (pts[0] + pts[1]) / 2.0;
        final double distDelta = (dist - _pinchStartDistance).abs();
        final double focalDelta = (focal - _twoFingerFocalDown).distance;
        if (distDelta > 12.0 || focalDelta > 12.0) {
          _twoFingerMoved = true;
        }
        if (distDelta > 14.0) {
          _isTwoFingerPinch = true;
        }
        if (_isTwoFingerPinch) {
          widget.viewportController.setZoom(
            _pinchBaseZoom * (dist / _pinchStartDistance),
            focalPoint: focal,
          );
          if (_lastTwoFingerFocal != null) {
            widget.viewportController.panBy(focal - _lastTwoFingerFocal!);
          }
        } else if (_twoFingerMoved && _lastTwoFingerFocal != null) {
          final Offset step = focal - _lastTwoFingerFocal!;
          if (step.dy.abs() >= step.dx.abs() && step.dy.abs() > 0.25) {
            final remote = widget.viewportController.viewportToRemote(focal) ??
                Offset(_virtualCursorX, _virtualCursorY);
            final int wheelV = (-step.dy * 2.0).round().clamp(-256, 255);
            if (wheelV != 0) {
              unawaited(
                widget.controller.sendPointerEvent(
                  x: remote.dx.round(),
                  y: remote.dy.round(),
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
        final int maxW = (widget.viewportController.remoteWidth - 1).clamp(0, 8191);
        final int maxH =
            (widget.viewportController.remoteHeight - 1).clamp(0, 8191);
        _virtualCursorX =
            (_virtualCursorX + event.localDelta.dx).clamp(0.0, maxW.toDouble());
        _virtualCursorY =
            (_virtualCursorY + event.localDelta.dy).clamp(0.0, maxH.toDouble());
        _virtualCursorInitialized = true;
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
      _pointerLongPressTimer?.cancel();
      _pointerLongPressTimer = null;
      if (_twoFingerGestureActive) {
        if (_activeTouches.isEmpty) {
          if (!_twoFingerMoved) {
            final remote =
                widget.viewportController.viewportToRemote(_twoFingerFocalDown) ??
                    Offset(_virtualCursorX, _virtualCursorY);
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
          _isTwoFingerPinch = false;
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
    _pointerLongPressTimer?.cancel();
    _pointerLongPressTimer = null;
    if (_activeTouches.isEmpty) {
      _twoFingerGestureActive = false;
      _twoFingerMoved = false;
      _isTwoFingerPinch = false;
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
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            widget.viewportController.setViewportSize(size);
          }
        });

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
              child: CustomPaint(
                painter: _SessionPainter(
                  image: _frameImage,
                  displayRect: displayRect,
                  cursor: widget.cursorState,
                  remoteWidth: widget.viewportController.remoteWidth,
                  remoteHeight: widget.viewportController.remoteHeight,
                ),
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
    required this.cursor,
    required this.remoteWidth,
    required this.remoteHeight,
  });

  final ui.Image? image;
  final Rect displayRect;
  final CursorState? cursor;
  final int remoteWidth;
  final int remoteHeight;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFF111318),
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

    final c = cursor;
    if (c != null && c.visible && !displayRect.isEmpty && remoteWidth > 0 && remoteHeight > 0) {
      final double cx = displayRect.left + (c.x / remoteWidth) * displayRect.width;
      final double cy = displayRect.top + (c.y / remoteHeight) * displayRect.height;
      canvas.drawCircle(
        Offset(cx, cy),
        4,
        Paint()
          ..color = const Color(0xCCFFFFFF)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SessionPainter oldDelegate) {
    return oldDelegate.image != image ||
        oldDelegate.displayRect != displayRect ||
        oldDelegate.cursor != cursor;
  }
}
