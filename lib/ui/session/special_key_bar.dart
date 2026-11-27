import 'package:material_ui/material_ui.dart';

import '../../services/scancode_mapper.dart';
import '../aer_keys.dart';

/// Termius-style docked bottom shortcut bar for remote desktop sessions.
///
/// Sits at the bottom row of the screen (and lifts flush above the soft
/// keyboard when IME opens). The right-end up/down button (`⌃` / `⌄`) expands
/// and collapses a full multi-row grid of extended navigation, function, and
/// Windows shortcut combo keys directly above the bottom strip.
class SpecialKeyBar extends StatelessWidget {
  const SpecialKeyBar({
    super.key,
    required this.activeModifiers,
    required this.onToggleModifier,
    required this.onPressSpecialKey,
    required this.onCtrlAltDel,
    this.onSendCombo,
    this.keyboardVisible = false,
    this.expanded = false,
    this.onToggleKeyboard,
    this.onToggleExpanded,
    this.bottomSafeInset = 0.0,
  });

  static const double barHeight = 42.0;
  static const double expandedPanelHeight = 204.0;

  static const Color _barBg = Color(0xF514171F);
  static const Color _panelBg = Color(0xF8181C26);
  static const Color _barBorder = Color(0xFF282F3E);
  static const Color _dividerColor = Color(0xFF2B3242);

  static const ScancodeSpec _ctrl = ScancodeSpec(0x1D);
  static const ScancodeSpec _alt = ScancodeSpec(0x38);
  static const ScancodeSpec _shift = ScancodeSpec(0x2A);
  static const ScancodeSpec _win = ScancodeSpec(0x5B, extended: true);

  static const List<({String label, ScancodeSpec spec})> _leadingKeys =
      <({String label, ScancodeSpec spec})>[
    (label: 'Esc', spec: ScancodeSpec(0x01)),
    (label: 'Tab', spec: ScancodeSpec(0x0F)),
  ];

  static const List<({String label, ScancodeSpec spec})> _arrowKeys =
      <({String label, ScancodeSpec spec})>[
    (label: '←', spec: ScancodeSpec(0x4B, extended: true)),
    (label: '↓', spec: ScancodeSpec(0x50, extended: true)),
    (label: '↑', spec: ScancodeSpec(0x48, extended: true)),
    (label: '→', spec: ScancodeSpec(0x4D, extended: true)),
  ];

  static const List<({String label, ScancodeSpec spec})> _quickTailKeys =
      <({String label, ScancodeSpec spec})>[
    (label: 'Del', spec: ScancodeSpec(0x53, extended: true)),
    (label: '⌫', spec: ScancodeSpec(0x0E)),
    (label: '⏎', spec: ScancodeSpec(0x1C)),
  ];

  static const List<({String label, ScancodeSpec spec})> _navRowKeys =
      <({String label, ScancodeSpec spec})>[
    (label: 'Ins', spec: ScancodeSpec(0x52, extended: true)),
    (label: 'Del', spec: ScancodeSpec(0x53, extended: true)),
    (label: 'Home', spec: ScancodeSpec(0x47, extended: true)),
    (label: 'End', spec: ScancodeSpec(0x4F, extended: true)),
    (label: 'PgUp', spec: ScancodeSpec(0x49, extended: true)),
    (label: 'PgDn', spec: ScancodeSpec(0x51, extended: true)),
  ];

  static const List<({String label, ScancodeSpec spec})> _fRow1 =
      <({String label, ScancodeSpec spec})>[
    (label: 'F1', spec: ScancodeSpec(0x3B)),
    (label: 'F2', spec: ScancodeSpec(0x3C)),
    (label: 'F3', spec: ScancodeSpec(0x3D)),
    (label: 'F4', spec: ScancodeSpec(0x3E)),
    (label: 'F5', spec: ScancodeSpec(0x3F)),
    (label: 'F6', spec: ScancodeSpec(0x40)),
  ];

  static const List<({String label, ScancodeSpec spec})> _fRow2 =
      <({String label, ScancodeSpec spec})>[
    (label: 'F7', spec: ScancodeSpec(0x41)),
    (label: 'F8', spec: ScancodeSpec(0x42)),
    (label: 'F9', spec: ScancodeSpec(0x43)),
    (label: 'F10', spec: ScancodeSpec(0x44)),
    (label: 'F11', spec: ScancodeSpec(0x57)),
    (label: 'F12', spec: ScancodeSpec(0x58)),
  ];

  static const List<({String label, List<ScancodeSpec> specs})> _comboRow1 =
      <({String label, List<ScancodeSpec> specs})>[
    (label: 'Alt+Tab', specs: <ScancodeSpec>[_alt, ScancodeSpec(0x0F)]),
    (label: 'Win+D', specs: <ScancodeSpec>[_win, ScancodeSpec(0x20)]),
    (label: 'Win+E', specs: <ScancodeSpec>[_win, ScancodeSpec(0x12)]),
    (
      label: 'Ctrl+Alt+Del',
      specs: <ScancodeSpec>[_ctrl, _alt, ScancodeSpec(0x53, extended: true)],
    ),
  ];

  static const List<({String label, List<ScancodeSpec> specs})> _comboRow2 =
      <({String label, List<ScancodeSpec> specs})>[
    (label: 'Ctrl+C', specs: <ScancodeSpec>[_ctrl, ScancodeSpec(0x2E)]),
    (label: 'Ctrl+V', specs: <ScancodeSpec>[_ctrl, ScancodeSpec(0x2F)]),
    (label: 'Ctrl+Z', specs: <ScancodeSpec>[_ctrl, ScancodeSpec(0x2C)]),
    (
      label: '任务管理',
      specs: <ScancodeSpec>[_ctrl, _shift, ScancodeSpec(0x01)],
    ),
  ];

  final Set<StickyModifier> activeModifiers;
  final ValueChanged<StickyModifier> onToggleModifier;
  final ValueChanged<ScancodeSpec> onPressSpecialKey;
  final VoidCallback onCtrlAltDel;
  final ValueChanged<List<ScancodeSpec>>? onSendCombo;
  final bool keyboardVisible;
  final bool expanded;
  final VoidCallback? onToggleKeyboard;
  final VoidCallback? onToggleExpanded;
  final double bottomSafeInset;

  void _triggerCombo(List<ScancodeSpec> specs) {
    if (onSendCombo != null) {
      onSendCombo!(specs);
    } else if (specs.length == 3 &&
        specs[0] == _ctrl &&
        specs[1] == _alt &&
        specs[2] == const ScancodeSpec(0x53, extended: true)) {
      onCtrlAltDel();
    } else if (specs.isNotEmpty) {
      onPressSpecialKey(specs.last);
    }
  }

  Widget _buildEqualSpecRow(List<({String label, ScancodeSpec spec})> items) {
    return Row(
      children: [
        for (int i = 0; i < items.length; i++) ...[
          Expanded(
            child: ShortcutKeycap(
              label: items[i].label,
              minWidth: 0,
              horizontalPadding: 4,
              onTap: () => onPressSpecialKey(items[i].spec),
            ),
          ),
          if (i + 1 < items.length) const SizedBox(width: 6),
        ],
      ],
    );
  }

  Widget _buildEqualComboRow(
    List<({String label, List<ScancodeSpec> specs})> items,
  ) {
    return Row(
      children: [
        for (int i = 0; i < items.length; i++) ...[
          Expanded(
            child: ShortcutKeycap(
              label: items[i].label,
              minWidth: 0,
              horizontalPadding: 4,
              onTap: () => _triggerCombo(items[i].specs),
            ),
          ),
          if (i + 1 < items.length) const SizedBox(width: 6),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool hasRightControls =
        onToggleKeyboard != null || onToggleExpanded != null;

    return Material(
      key: AerKeys.specialKeyBar,
      color: _barBg,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (expanded)
            Container(
              key: AerKeys.specialKeyBarExpandedPanel,
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
              decoration: const BoxDecoration(
                color: _panelBg,
                border: Border(
                  top: BorderSide(color: _barBorder, width: 1),
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildEqualComboRow(_comboRow1),
                  const SizedBox(height: 6),
                  _buildEqualComboRow(_comboRow2),
                  const SizedBox(height: 6),
                  _buildEqualSpecRow(_navRowKeys),
                  const SizedBox(height: 6),
                  _buildEqualSpecRow(_fRow1),
                  const SizedBox(height: 6),
                  _buildEqualSpecRow(_fRow2),
                ],
              ),
            ),
          Container(
            width: double.infinity,
            padding: EdgeInsets.only(bottom: bottomSafeInset),
            decoration: const BoxDecoration(
              border: Border(
                top: BorderSide(color: _barBorder, width: 1),
              ),
            ),
            child: SizedBox(
              height: barHeight,
              child: Row(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final entry in _leadingKeys) ...[
                            ShortcutKeycap(
                              label: entry.label,
                              onTap: () => onPressSpecialKey(entry.spec),
                            ),
                            const SizedBox(width: 5),
                          ],
                          for (final mod in StickyModifier.values) ...[
                            ShortcutKeycap(
                              label: mod.label,
                              selected: activeModifiers.contains(mod),
                              isStickyIndicator: true,
                              onTap: () => onToggleModifier(mod),
                            ),
                            const SizedBox(width: 5),
                          ],
                          for (final arrow in _arrowKeys) ...[
                            ShortcutKeycap(
                              label: arrow.label,
                              minWidth: 33,
                              onTap: () => onPressSpecialKey(arrow.spec),
                            ),
                            const SizedBox(width: 5),
                          ],
                          for (int i = 0; i < _quickTailKeys.length; i++) ...[
                            ShortcutKeycap(
                              label: _quickTailKeys[i].label,
                              onTap: () =>
                                  onPressSpecialKey(_quickTailKeys[i].spec),
                            ),
                            if (i + 1 < _quickTailKeys.length)
                              const SizedBox(width: 5),
                          ],
                          if (!expanded) ...[
                            const SizedBox(width: 5),
                            ShortcutKeycap(
                              label: 'Ctrl+Alt+Del',
                              onTap: onCtrlAltDel,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  if (hasRightControls) ...[
                    Container(
                      width: 1,
                      height: 22,
                      color: _dividerColor,
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (onToggleKeyboard != null)
                            ShortcutKeycap(
                              key: AerKeys.specialKeyBarKeyboardToggle,
                              icon: keyboardVisible
                                  ? Icons.keyboard_hide_rounded
                                  : Icons.keyboard_rounded,
                              tooltip: keyboardVisible ? '收起软键盘' : '呼出软键盘',
                              selected: keyboardVisible,
                              minWidth: 36,
                              onTap: onToggleKeyboard!,
                            ),
                          if (onToggleKeyboard != null &&
                              onToggleExpanded != null)
                            const SizedBox(width: 5),
                          if (onToggleExpanded != null)
                            ShortcutKeycap(
                              key: AerKeys.specialKeyBarExpandToggle,
                              icon: expanded
                                  ? Icons.keyboard_arrow_down_rounded
                                  : Icons.keyboard_arrow_up_rounded,
                              tooltip: expanded ? '收起更多快捷键' : '展开更多快捷键',
                              selected: expanded,
                              minWidth: 34,
                              horizontalPadding: 6,
                              onTap: onToggleExpanded!,
                            ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Individual crisp Termius-style keycap button used inside [SpecialKeyBar].
class ShortcutKeycap extends StatelessWidget {
  const ShortcutKeycap({
    super.key,
    this.label,
    this.icon,
    this.tooltip,
    required this.onTap,
    this.selected = false,
    this.isStickyIndicator = false,
    this.subtle = false,
    this.minWidth = 36.0,
    this.horizontalPadding = 9.0,
  }) : assert(label != null || icon != null);

  static const Color _idleBg = Color(0xFF222733);
  static const Color _idleBorder = Color(0xFF313849);
  static const Color _activeBg = Color(0xFF2563EB);
  static const Color _activeBorder = Color(0xFF60A5FA);
  static const Color _fgIdle = Color(0xFFE6EAF2);

  final String? label;
  final IconData? icon;
  final String? tooltip;
  final VoidCallback onTap;
  final bool selected;
  final bool isStickyIndicator;
  final bool subtle;
  final double minWidth;
  final double horizontalPadding;

  @override
  Widget build(BuildContext context) {
    final Color bg = selected
        ? _activeBg
        : (subtle ? Colors.transparent : _idleBg);
    final Color border = selected
        ? _activeBorder
        : (subtle ? Colors.transparent : _idleBorder);
    final Color fg = selected
        ? Colors.white
        : (subtle ? const Color(0xFFA6B0C3) : _fgIdle);

    Widget button = Semantics(
      button: true,
      selected: selected,
      label: tooltip ?? label,
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(7),
        child: InkWell(
          borderRadius: BorderRadius.circular(7),
          splashColor: Colors.white24,
          highlightColor: Colors.white10,
          onTap: onTap,
          child: Container(
            height: 31,
            constraints: BoxConstraints(minWidth: minWidth),
            padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(7),
              border: Border.all(color: border, width: 1),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (isStickyIndicator && selected) ...[
                  Container(
                    width: 5,
                    height: 5,
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 4),
                ],
                if (icon != null)
                  Icon(icon, size: 18, color: fg)
                else
                  Flexible(
                    child: Text(
                      label!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: fg,
                        fontSize: 12.0,
                        fontWeight:
                            selected ? FontWeight.w700 : FontWeight.w600,
                        height: 1.0,
                        letterSpacing: 0.1,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );

    if (tooltip != null && tooltip!.isNotEmpty) {
      button = Tooltip(message: tooltip!, child: button);
    }
    return button;
  }
}
