import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

class ViewportController extends ChangeNotifier {
  ViewportController({
    int remoteWidth = 1280,
    int remoteHeight = 720,
  })  : _remoteWidth = remoteWidth,
        _remoteHeight = remoteHeight;

  static const double minZoom = 1.0;
  static const double maxZoom = 4.0;

  int _remoteWidth;
  int _remoteHeight;
  Size _viewportSize = Size.zero;
  double _zoom = 1.0;
  Offset _panOffset = Offset.zero;

  int get remoteWidth => _remoteWidth;
  int get remoteHeight => _remoteHeight;
  Size get viewportSize => _viewportSize;
  double get zoom => _zoom;
  Offset get panOffset => _panOffset;

  void setRemoteSize(int width, int height) {
    final w = math.max(1, width);
    final h = math.max(1, height);
    if (_remoteWidth == w && _remoteHeight == h) return;
    _remoteWidth = w;
    _remoteHeight = h;
    _clampPan();
    notifyListeners();
  }

  void setViewportSize(Size size) {
    if (_viewportSize == size) return;
    _viewportSize = size;
    _clampPan();
    notifyListeners();
  }

  Rect computeFittedBaseRect([Size? explicitViewportSize]) {
    final vp = explicitViewportSize ?? _viewportSize;
    if (vp.width <= 0 || vp.height <= 0) {
      return Rect.zero;
    }
    final double remoteAspect = _remoteWidth / _remoteHeight;
    final double vpAspect = vp.width / vp.height;

    final double fitW;
    final double fitH;
    if (vpAspect > remoteAspect) {
      fitH = vp.height;
      fitW = fitH * remoteAspect;
    } else {
      fitW = vp.width;
      fitH = fitW / remoteAspect;
    }
    final double left = (vp.width - fitW) / 2.0;
    final double top = (vp.height - fitH) / 2.0;
    return Rect.fromLTWH(left, top, fitW, fitH);
  }

  Rect computeDisplayRect([Size? explicitViewportSize]) {
    final vp = explicitViewportSize ?? _viewportSize;
    final base = computeFittedBaseRect(vp);
    if (base.isEmpty) return Rect.zero;
    final double scaledW = base.width * _zoom;
    final double scaledH = base.height * _zoom;
    final Offset center = base.center + _panOffset;
    return Rect.fromCenter(
      center: center,
      width: scaledW,
      height: scaledH,
    );
  }

  void setZoom(double nextZoom, {Offset? focalPoint}) {
    final double clampedZoom = nextZoom.clamp(minZoom, maxZoom).toDouble();
    if ((clampedZoom - _zoom).abs() < 1e-4) return;
    if (focalPoint != null && !_viewportSize.isEmpty) {
      final Rect before = computeDisplayRect();
      if (!before.isEmpty) {
        final double relX = (focalPoint.dx - before.center.dx) / _zoom;
        final double relY = (focalPoint.dy - before.center.dy) / _zoom;
        final double newCenterX = focalPoint.dx - relX * clampedZoom;
        final double newCenterY = focalPoint.dy - relY * clampedZoom;
        final Rect base = computeFittedBaseRect();
        _panOffset = Offset(
          newCenterX - base.center.dx,
          newCenterY - base.center.dy,
        );
      }
    }
    _zoom = clampedZoom;
    _clampPan();
    notifyListeners();
  }

  void panBy(Offset delta) {
    if (delta == Offset.zero) return;
    _panOffset += delta;
    _clampPan();
    notifyListeners();
  }

  void reset() {
    if (_zoom == minZoom && _panOffset == Offset.zero) return;
    _zoom = minZoom;
    _panOffset = Offset.zero;
    notifyListeners();
  }

  void _clampPan() {
    if (_viewportSize.isEmpty) {
      _panOffset = Offset.zero;
      return;
    }
    final base = computeFittedBaseRect();
    final double scaledW = base.width * _zoom;
    final double scaledH = base.height * _zoom;
    final double maxDx = math.max(0.0, (scaledW - _viewportSize.width) / 2.0);
    final double maxDy = math.max(0.0, (scaledH - _viewportSize.height) / 2.0);
    _panOffset = Offset(
      _panOffset.dx.clamp(-maxDx, maxDx),
      _panOffset.dy.clamp(-maxDy, maxDy),
    );
  }

  /// Maps a viewport local position to remote framebuffer coordinates `[0, w-1] x [0, h-1]`.
  /// Returns `null` if [localPos] falls in the letterbox margin outside the desktop image.
  Offset? viewportToRemote(Offset localPos, {Size? explicitViewportSize}) {
    final rect = computeDisplayRect(explicitViewportSize);
    if (rect.isEmpty || !rect.contains(localPos)) {
      return null;
    }
    final double normX = ((localPos.dx - rect.left) / rect.width).clamp(0.0, 1.0);
    final double normY = ((localPos.dy - rect.top) / rect.height).clamp(0.0, 1.0);
    final int rx = (normX * (_remoteWidth - 1)).round().clamp(0, _remoteWidth - 1);
    final int ry = (normY * (_remoteHeight - 1)).round().clamp(0, _remoteHeight - 1);
    return Offset(rx.toDouble(), ry.toDouble());
  }
}
