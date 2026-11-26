import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../models/connection_profile.dart';
import '../aer_keys.dart';

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

  @override
  State<CommandBarPill> createState() => _CommandBarPillState();
}

class _CommandBarPillState extends State<CommandBarPill> {
  static const double _margin = 8.0;
  static const double _collapsedWidth = 56.0;
  static const double _expandedWidth = 296.0;
  static const double _pillHeight = 44.0;

  bool _expanded = false;
  Offset? _position;

  Offset _clampedPosition(Offset raw, double width) {
    final double maxW = math.max(_margin, widget.areaSize.width - width - _margin);
    final double maxH =
        math.max(_margin, widget.areaSize.height - _pillHeight - _margin);
    return Offset(
      raw.dx.clamp(_margin, maxW),
      raw.dy.clamp(_margin, maxH),
    );
  }

  @override
  Widget build(BuildContext context) {
    final double availableMaxWidth =
        math.max(48.0, widget.areaSize.width - _margin * 2);
    final double activeWidth = _expanded
        ? math.min(_expandedWidth, availableMaxWidth)
        : math.min(_collapsedWidth, availableMaxWidth);

    final Offset defaultPos = Offset(
      math.max(_margin, (widget.areaSize.width - activeWidth) / 2.0),
      _margin,
    );
    final Offset pos = _clampedPosition(_position ?? defaultPos, activeWidth);

    return Positioned(
      left: pos.dx,
      top: pos.dy,
      child: Material(
        elevation: 4,
        borderRadius: BorderRadius.circular(24),
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: availableMaxWidth,
            minHeight: _pillHeight,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              GestureDetector(
                key: AerKeys.commandBarPill,
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _expanded = !_expanded),
                onPanUpdate: (details) {
                  setState(() {
                    _position = _clampedPosition(
                      pos + details.delta,
                      activeWidth,
                    );
                  });
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: Icon(
                    _expanded ? Icons.chevron_left : Icons.tune,
                    size: 20,
                  ),
                ),
              ),
              if (_expanded)
                Flexible(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          key: AerKeys.commandBarInputMode,
                          icon: Icon(
                            widget.inputMode == InputMode.directTouch
                                ? Icons.touch_app
                                : Icons.mouse,
                            size: 20,
                          ),
                          tooltip: widget.inputMode.label,
                          visualDensity: VisualDensity.compact,
                          onPressed: widget.onToggleInputMode,
                        ),
                        IconButton(
                          key: AerKeys.commandBarKeyboard,
                          icon: Icon(
                            widget.keyboardVisible
                                ? Icons.keyboard_hide
                                : Icons.keyboard,
                            size: 20,
                          ),
                          tooltip: 'Keyboard',
                          visualDensity: VisualDensity.compact,
                          onPressed: widget.onToggleKeyboard,
                        ),
                        IconButton(
                          key: AerKeys.commandBarMute,
                          icon: Icon(
                            widget.muted ? Icons.volume_off : Icons.volume_up,
                            size: 20,
                          ),
                          tooltip: widget.muted ? 'Unmute' : 'Mute',
                          visualDensity: VisualDensity.compact,
                          onPressed: widget.onToggleMute,
                        ),
                        IconButton(
                          key: AerKeys.commandBarZoomReset,
                          icon: const Icon(Icons.fit_screen, size: 20),
                          tooltip: 'Reset Zoom',
                          visualDensity: VisualDensity.compact,
                          onPressed: widget.onResetZoom,
                        ),
                        IconButton(
                          key: AerKeys.commandBarDisconnect,
                          icon: Icon(
                            Icons.call_end,
                            size: 20,
                            color: Theme.of(context).colorScheme.error,
                          ),
                          tooltip: 'Disconnect',
                          visualDensity: VisualDensity.compact,
                          onPressed: widget.onDisconnect,
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
