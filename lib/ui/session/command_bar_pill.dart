import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../models/connection_profile.dart';
import '../aer_keys.dart';

enum _DockSide { none, left, right }

class CommandBarPill extends StatefulWidget {
  const CommandBarPill({
    super.key,
    required this.areaSize,
    required this.inputMode,
    required this.keyboardVisible,
    required this.muted,
    required this.onDisconnect,
    required this.onToggleInputMode,
    required this.onToggleKeyboard,
    required this.onToggleMute,
    required this.onResetZoom,
    this.safePadding = EdgeInsets.zero,
    this.stretchToFill = false,
  });

  final Size areaSize;
  final InputMode inputMode;
  final bool keyboardVisible;
  final bool muted;
  final VoidCallback onDisconnect;
  final VoidCallback onToggleInputMode;
  final VoidCallback onToggleKeyboard;
  final VoidCallback onToggleMute;
  final VoidCallback onResetZoom;
  final EdgeInsets safePadding;
  final bool stretchToFill;

  @override
  State<CommandBarPill> createState() => _CommandBarPillState();
}

class _CommandBarPillState extends State<CommandBarPill> {
  static const double _margin = 8.0;
  static const double _dockedTabWidth = 26.0;
  static const double _dockedTabHeight = 48.0;
  static const double _floatingBallWidth = 46.0;
  static const double _expandedWidth = 308.0;
  static const double _pillHeight = 46.0;
  static const double _edgeSnapThreshold = 36.0;

  bool _expanded = false;
  _DockSide _dockSide = _DockSide.none;
  Offset? _position;

  double get _minTop => math.max(_margin, widget.safePadding.top + 4.0);

  double _clampY(double rawY, double height) {
    final double maxH = math.max(
      _minTop,
      widget.areaSize.height - widget.safePadding.bottom - height - _margin,
    );
    return rawY.clamp(_minTop, maxH);
  }

  Offset _clampedFloatingPosition(Offset raw, double width) {
    final double maxW =
        math.max(_margin, widget.areaSize.width - width - _margin);
    return Offset(
      raw.dx.clamp(_margin, maxW),
      _clampY(raw.dy, _pillHeight),
    );
  }

  void _snapOrKeepAfterDrag(Offset currentPos, double currentWidth) {
    final double areaW = widget.areaSize.width;
    if (areaW <= 0) return;
    final double centerX = currentPos.dx + currentWidth / 2.0;
    final bool nearLeft = currentPos.dx <= _edgeSnapThreshold;
    final bool nearRight =
        (currentPos.dx + currentWidth) >= (areaW - _edgeSnapThreshold);

    if (nearLeft || nearRight) {
      setState(() {
        _expanded = false;
        _dockSide = (nearLeft && !nearRight)
            ? _DockSide.left
            : (!nearLeft && nearRight)
                ? _DockSide.right
                : (centerX < areaW / 2.0 ? _DockSide.left : _DockSide.right);
        _position = Offset(
          _dockSide == _DockSide.left ? 0.0 : areaW - _dockedTabWidth,
          _clampY(currentPos.dy, _dockedTabHeight),
        );
      });
    }
  }

  void _handlePillTap(Offset currentPos, double activeWidth) {
    final double areaW = widget.areaSize.width;
    if (!_expanded) {
      // Expand inward from docked edge or current floating position.
      final double expandedW = math.min(
        _expandedWidth,
        math.max(48.0, areaW - _margin * 2),
      );
      double targetX = currentPos.dx;
      if (_dockSide == _DockSide.left) {
        targetX = _margin;
      } else if (_dockSide == _DockSide.right) {
        targetX = math.max(_margin, areaW - expandedW - _margin);
      }
      setState(() {
        _expanded = true;
        _position = _clampedFloatingPosition(
          Offset(targetX, currentPos.dy),
          expandedW,
        );
      });
    } else {
      // Collapse and dock to nearest screen edge so it hides cleanly out of the way.
      final double centerX = currentPos.dx + activeWidth / 2.0;
      final _DockSide side =
          centerX <= areaW / 2.0 ? _DockSide.left : _DockSide.right;
      setState(() {
        _expanded = false;
        _dockSide = side;
        _position = Offset(
          side == _DockSide.left ? 0.0 : math.max(0.0, areaW - _dockedTabWidth),
          _clampY(currentPos.dy, _dockedTabHeight),
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final double availableMaxWidth =
        math.max(48.0, widget.areaSize.width - _margin * 2);

    final bool isDockedCollapsed = !_expanded && _dockSide != _DockSide.none;
    final double activeWidth = _expanded
        ? math.min(_expandedWidth, availableMaxWidth)
        : (isDockedCollapsed
            ? _dockedTabWidth
            : math.min(_floatingBallWidth, availableMaxWidth));
    final double activeHeight =
        isDockedCollapsed ? _dockedTabHeight : _pillHeight;

    final Offset defaultPos = Offset(
      math.max(0.0, widget.areaSize.width - _floatingBallWidth - _margin),
      _minTop + 8.0,
    );

    final Offset pos;
    if (isDockedCollapsed) {
      final double rawY = (_position ?? defaultPos).dy;
      pos = Offset(
        _dockSide == _DockSide.left
            ? 0.0
            : math.max(0.0, widget.areaSize.width - _dockedTabWidth),
        _clampY(rawY, activeHeight),
      );
    } else {
      pos = _clampedFloatingPosition(_position ?? defaultPos, activeWidth);
    }

    final BorderRadius borderRadius = isDockedCollapsed
        ? (_dockSide == _DockSide.left
            ? const BorderRadius.horizontal(right: Radius.circular(18))
            : const BorderRadius.horizontal(left: Radius.circular(18)))
        : BorderRadius.circular(24);

    final bool isPointerMode = widget.inputMode == InputMode.pointer;

    return Positioned(
      left: pos.dx,
      top: pos.dy,
      child: Opacity(
        opacity: isDockedCollapsed ? 0.58 : (_expanded ? 0.96 : 0.78),
        child: GestureDetector(
          onPanUpdate: (details) {
            setState(() {
              _dockSide = _DockSide.none;
              final double dragW = _expanded
                  ? math.min(_expandedWidth, availableMaxWidth)
                  : math.min(_floatingBallWidth, availableMaxWidth);
              final double maxX = math.max(0.0, widget.areaSize.width - dragW);
              _position = Offset(
                (pos.dx + details.delta.dx).clamp(0.0, maxX),
                _clampY(pos.dy + details.delta.dy, _pillHeight),
              );
            });
          },
          onPanEnd: (_) {
            final cur = _position ?? pos;
            final double dragW = _expanded
                ? math.min(_expandedWidth, availableMaxWidth)
                : math.min(_floatingBallWidth, availableMaxWidth);
            _snapOrKeepAfterDrag(cur, dragW);
          },
          child: Material(
            elevation: isDockedCollapsed ? 2 : 6,
            shadowColor: Colors.black54,
            borderRadius: borderRadius,
            color: colorScheme.surfaceContainerHigh,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: isDockedCollapsed ? _dockedTabWidth : availableMaxWidth,
                minHeight: activeHeight,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  GestureDetector(
                    key: AerKeys.commandBarPill,
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _handlePillTap(pos, activeWidth),
                    child: SizedBox(
                      width: isDockedCollapsed ? _dockedTabWidth : 42.0,
                      height: activeHeight,
                      child: Center(
                        child: Icon(
                          isDockedCollapsed
                              ? (_dockSide == _DockSide.left
                                  ? Icons.chevron_right
                                  : Icons.chevron_left)
                              : (_expanded
                                  ? (_dockSide == _DockSide.right
                                      ? Icons.chevron_right
                                      : Icons.chevron_left)
                                  : Icons.tune),
                          size: 20,
                        ),
                      ),
                    ),
                  ),
                  if (_expanded)
                    Flexible(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Tooltip(
                                message: isPointerMode
                                    ? '当前：鼠标指针模式（点击切换为触控直点）'
                                    : '当前：触控直点模式（点击切换为鼠标指针）',
                                child: InkWell(
                                  key: AerKeys.commandBarInputMode,
                                  borderRadius: BorderRadius.circular(16),
                                  onTap: widget.onToggleInputMode,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 6,
                                    ),
                                    decoration: BoxDecoration(
                                      color: isPointerMode
                                          ? colorScheme.primaryContainer
                                          : colorScheme.surfaceContainerHighest,
                                      borderRadius: BorderRadius.circular(16),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          isPointerMode
                                              ? Icons.mouse
                                              : Icons.touch_app,
                                          size: 18,
                                          color: isPointerMode
                                              ? colorScheme.onPrimaryContainer
                                              : colorScheme.onSurfaceVariant,
                                        ),
                                        const SizedBox(width: 4),
                                        Text(
                                          isPointerMode ? '指针' : '触控',
                                          style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                            color: isPointerMode
                                                ? colorScheme.onPrimaryContainer
                                                : colorScheme.onSurfaceVariant,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 2),
                              IconButton(
                                key: AerKeys.commandBarKeyboard,
                                icon: Icon(
                                  widget.keyboardVisible
                                      ? Icons.keyboard_hide
                                      : Icons.keyboard,
                                  size: 20,
                                  color: widget.keyboardVisible
                                      ? colorScheme.primary
                                      : null,
                                ),
                                tooltip: widget.keyboardVisible ? '收起键盘' : '呼出键盘',
                                visualDensity: VisualDensity.compact,
                                onPressed: widget.onToggleKeyboard,
                              ),
                              IconButton(
                                key: AerKeys.commandBarMute,
                                icon: Icon(
                                  widget.muted
                                      ? Icons.volume_off
                                      : Icons.volume_up,
                                  size: 20,
                                ),
                                tooltip: widget.muted ? '取消静音' : '静音',
                                visualDensity: VisualDensity.compact,
                                onPressed: widget.onToggleMute,
                              ),
                              IconButton(
                                key: AerKeys.commandBarZoomReset,
                                icon: Icon(
                                  widget.stretchToFill
                                      ? Icons.fullscreen_exit
                                      : Icons.fit_screen,
                                  size: 20,
                                  color: widget.stretchToFill
                                      ? colorScheme.primary
                                      : null,
                                ),
                                tooltip: '适应/铺满屏幕',
                                visualDensity: VisualDensity.compact,
                                onPressed: widget.onResetZoom,
                              ),
                              IconButton(
                                key: AerKeys.commandBarDisconnect,
                                icon: Icon(
                                  Icons.call_end,
                                  size: 20,
                                  color: colorScheme.error,
                                ),
                                tooltip: '断开连接',
                                visualDensity: VisualDensity.compact,
                                onPressed: widget.onDisconnect,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
