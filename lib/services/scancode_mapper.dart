import 'package:flutter/services.dart';

class ScancodeSpec {
  const ScancodeSpec(this.code, {this.extended = false});

  final int code;
  final bool extended;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ScancodeSpec &&
          runtimeType == other.runtimeType &&
          code == other.code &&
          extended == other.extended;

  @override
  int get hashCode => code.hashCode ^ extended.hashCode;
}

enum StickyModifier {
  ctrl(ScancodeSpec(0x1D), 'Ctrl'),
  alt(ScancodeSpec(0x38), 'Alt'),
  shift(ScancodeSpec(0x2A), 'Shift'),
  win(ScancodeSpec(0x5B, extended: true), 'Win');

  const StickyModifier(this.scancode, this.label);
  final ScancodeSpec scancode;
  final String label;
}

abstract final class ScancodeMapper {
  static final Map<LogicalKeyboardKey, ScancodeSpec> _logicalMap =
      <LogicalKeyboardKey, ScancodeSpec>{
    LogicalKeyboardKey.escape: const ScancodeSpec(0x01),
    LogicalKeyboardKey.digit1: const ScancodeSpec(0x02),
    LogicalKeyboardKey.digit2: const ScancodeSpec(0x03),
    LogicalKeyboardKey.digit3: const ScancodeSpec(0x04),
    LogicalKeyboardKey.digit4: const ScancodeSpec(0x05),
    LogicalKeyboardKey.digit5: const ScancodeSpec(0x06),
    LogicalKeyboardKey.digit6: const ScancodeSpec(0x07),
    LogicalKeyboardKey.digit7: const ScancodeSpec(0x08),
    LogicalKeyboardKey.digit8: const ScancodeSpec(0x09),
    LogicalKeyboardKey.digit9: const ScancodeSpec(0x0A),
    LogicalKeyboardKey.digit0: const ScancodeSpec(0x0B),
    LogicalKeyboardKey.minus: const ScancodeSpec(0x0C),
    LogicalKeyboardKey.equal: const ScancodeSpec(0x0D),
    LogicalKeyboardKey.backspace: const ScancodeSpec(0x0E),
    LogicalKeyboardKey.tab: const ScancodeSpec(0x0F),
    LogicalKeyboardKey.keyQ: const ScancodeSpec(0x10),
    LogicalKeyboardKey.keyW: const ScancodeSpec(0x11),
    LogicalKeyboardKey.keyE: const ScancodeSpec(0x12),
    LogicalKeyboardKey.keyR: const ScancodeSpec(0x13),
    LogicalKeyboardKey.keyT: const ScancodeSpec(0x14),
    LogicalKeyboardKey.keyY: const ScancodeSpec(0x15),
    LogicalKeyboardKey.keyU: const ScancodeSpec(0x16),
    LogicalKeyboardKey.keyI: const ScancodeSpec(0x17),
    LogicalKeyboardKey.keyO: const ScancodeSpec(0x18),
    LogicalKeyboardKey.keyP: const ScancodeSpec(0x19),
    LogicalKeyboardKey.bracketLeft: const ScancodeSpec(0x1A),
    LogicalKeyboardKey.bracketRight: const ScancodeSpec(0x1B),
    LogicalKeyboardKey.enter: const ScancodeSpec(0x1C),
    LogicalKeyboardKey.numpadEnter: const ScancodeSpec(0x1C, extended: true),
    LogicalKeyboardKey.controlLeft: const ScancodeSpec(0x1D),
    LogicalKeyboardKey.controlRight: const ScancodeSpec(0x1D, extended: true),
    LogicalKeyboardKey.keyA: const ScancodeSpec(0x1E),
    LogicalKeyboardKey.keyS: const ScancodeSpec(0x1F),
    LogicalKeyboardKey.keyD: const ScancodeSpec(0x20),
    LogicalKeyboardKey.keyF: const ScancodeSpec(0x21),
    LogicalKeyboardKey.keyG: const ScancodeSpec(0x22),
    LogicalKeyboardKey.keyH: const ScancodeSpec(0x23),
    LogicalKeyboardKey.keyJ: const ScancodeSpec(0x24),
    LogicalKeyboardKey.keyK: const ScancodeSpec(0x25),
    LogicalKeyboardKey.keyL: const ScancodeSpec(0x26),
    LogicalKeyboardKey.semicolon: const ScancodeSpec(0x27),
    LogicalKeyboardKey.quoteSingle: const ScancodeSpec(0x28),
    LogicalKeyboardKey.backquote: const ScancodeSpec(0x29),
    LogicalKeyboardKey.shiftLeft: const ScancodeSpec(0x2A),
    LogicalKeyboardKey.backslash: const ScancodeSpec(0x2B),
    LogicalKeyboardKey.keyZ: const ScancodeSpec(0x2C),
    LogicalKeyboardKey.keyX: const ScancodeSpec(0x2D),
    LogicalKeyboardKey.keyC: const ScancodeSpec(0x2E),
    LogicalKeyboardKey.keyV: const ScancodeSpec(0x2F),
    LogicalKeyboardKey.keyB: const ScancodeSpec(0x30),
    LogicalKeyboardKey.keyN: const ScancodeSpec(0x31),
    LogicalKeyboardKey.keyM: const ScancodeSpec(0x32),
    LogicalKeyboardKey.comma: const ScancodeSpec(0x33),
    LogicalKeyboardKey.period: const ScancodeSpec(0x34),
    LogicalKeyboardKey.slash: const ScancodeSpec(0x35),
    LogicalKeyboardKey.shiftRight: const ScancodeSpec(0x36),
    LogicalKeyboardKey.altLeft: const ScancodeSpec(0x38),
    LogicalKeyboardKey.altRight: const ScancodeSpec(0x38, extended: true),
    LogicalKeyboardKey.space: const ScancodeSpec(0x39),
    LogicalKeyboardKey.capsLock: const ScancodeSpec(0x3A),
    LogicalKeyboardKey.f1: const ScancodeSpec(0x3B),
    LogicalKeyboardKey.f2: const ScancodeSpec(0x3C),
    LogicalKeyboardKey.f3: const ScancodeSpec(0x3D),
    LogicalKeyboardKey.f4: const ScancodeSpec(0x3E),
    LogicalKeyboardKey.f5: const ScancodeSpec(0x3F),
    LogicalKeyboardKey.f6: const ScancodeSpec(0x40),
    LogicalKeyboardKey.f7: const ScancodeSpec(0x41),
    LogicalKeyboardKey.f8: const ScancodeSpec(0x42),
    LogicalKeyboardKey.f9: const ScancodeSpec(0x43),
    LogicalKeyboardKey.f10: const ScancodeSpec(0x44),
    LogicalKeyboardKey.f11: const ScancodeSpec(0x57),
    LogicalKeyboardKey.f12: const ScancodeSpec(0x58),
    LogicalKeyboardKey.home: const ScancodeSpec(0x47, extended: true),
    LogicalKeyboardKey.arrowUp: const ScancodeSpec(0x48, extended: true),
    LogicalKeyboardKey.pageUp: const ScancodeSpec(0x49, extended: true),
    LogicalKeyboardKey.arrowLeft: const ScancodeSpec(0x4B, extended: true),
    LogicalKeyboardKey.arrowRight: const ScancodeSpec(0x4D, extended: true),
    LogicalKeyboardKey.end: const ScancodeSpec(0x4F, extended: true),
    LogicalKeyboardKey.arrowDown: const ScancodeSpec(0x50, extended: true),
    LogicalKeyboardKey.pageDown: const ScancodeSpec(0x51, extended: true),
    LogicalKeyboardKey.insert: const ScancodeSpec(0x52, extended: true),
    LogicalKeyboardKey.delete: const ScancodeSpec(0x53, extended: true),
    LogicalKeyboardKey.metaLeft: const ScancodeSpec(0x5B, extended: true),
    LogicalKeyboardKey.metaRight: const ScancodeSpec(0x5C, extended: true),
  };

  static final Map<PhysicalKeyboardKey, ScancodeSpec> _physicalMap =
      <PhysicalKeyboardKey, ScancodeSpec>{
    PhysicalKeyboardKey.escape: const ScancodeSpec(0x01),
    PhysicalKeyboardKey.digit1: const ScancodeSpec(0x02),
    PhysicalKeyboardKey.digit2: const ScancodeSpec(0x03),
    PhysicalKeyboardKey.digit3: const ScancodeSpec(0x04),
    PhysicalKeyboardKey.digit4: const ScancodeSpec(0x05),
    PhysicalKeyboardKey.digit5: const ScancodeSpec(0x06),
    PhysicalKeyboardKey.digit6: const ScancodeSpec(0x07),
    PhysicalKeyboardKey.digit7: const ScancodeSpec(0x08),
    PhysicalKeyboardKey.digit8: const ScancodeSpec(0x09),
    PhysicalKeyboardKey.digit9: const ScancodeSpec(0x0A),
    PhysicalKeyboardKey.digit0: const ScancodeSpec(0x0B),
    PhysicalKeyboardKey.minus: const ScancodeSpec(0x0C),
    PhysicalKeyboardKey.equal: const ScancodeSpec(0x0D),
    PhysicalKeyboardKey.backspace: const ScancodeSpec(0x0E),
    PhysicalKeyboardKey.tab: const ScancodeSpec(0x0F),
    PhysicalKeyboardKey.keyQ: const ScancodeSpec(0x10),
    PhysicalKeyboardKey.keyW: const ScancodeSpec(0x11),
    PhysicalKeyboardKey.keyE: const ScancodeSpec(0x12),
    PhysicalKeyboardKey.keyR: const ScancodeSpec(0x13),
    PhysicalKeyboardKey.keyT: const ScancodeSpec(0x14),
    PhysicalKeyboardKey.keyY: const ScancodeSpec(0x15),
    PhysicalKeyboardKey.keyU: const ScancodeSpec(0x16),
    PhysicalKeyboardKey.keyI: const ScancodeSpec(0x17),
    PhysicalKeyboardKey.keyO: const ScancodeSpec(0x18),
    PhysicalKeyboardKey.keyP: const ScancodeSpec(0x19),
    PhysicalKeyboardKey.bracketLeft: const ScancodeSpec(0x1A),
    PhysicalKeyboardKey.bracketRight: const ScancodeSpec(0x1B),
    PhysicalKeyboardKey.enter: const ScancodeSpec(0x1C),
    PhysicalKeyboardKey.numpadEnter: const ScancodeSpec(0x1C, extended: true),
    PhysicalKeyboardKey.controlLeft: const ScancodeSpec(0x1D),
    PhysicalKeyboardKey.controlRight: const ScancodeSpec(0x1D, extended: true),
    PhysicalKeyboardKey.keyA: const ScancodeSpec(0x1E),
    PhysicalKeyboardKey.keyS: const ScancodeSpec(0x1F),
    PhysicalKeyboardKey.keyD: const ScancodeSpec(0x20),
    PhysicalKeyboardKey.keyF: const ScancodeSpec(0x21),
    PhysicalKeyboardKey.keyG: const ScancodeSpec(0x22),
    PhysicalKeyboardKey.keyH: const ScancodeSpec(0x23),
    PhysicalKeyboardKey.keyJ: const ScancodeSpec(0x24),
    PhysicalKeyboardKey.keyK: const ScancodeSpec(0x25),
    PhysicalKeyboardKey.keyL: const ScancodeSpec(0x26),
    PhysicalKeyboardKey.semicolon: const ScancodeSpec(0x27),
    PhysicalKeyboardKey.quote: const ScancodeSpec(0x28),
    PhysicalKeyboardKey.backquote: const ScancodeSpec(0x29),
    PhysicalKeyboardKey.shiftLeft: const ScancodeSpec(0x2A),
    PhysicalKeyboardKey.backslash: const ScancodeSpec(0x2B),
    PhysicalKeyboardKey.keyZ: const ScancodeSpec(0x2C),
    PhysicalKeyboardKey.keyX: const ScancodeSpec(0x2D),
    PhysicalKeyboardKey.keyC: const ScancodeSpec(0x2E),
    PhysicalKeyboardKey.keyV: const ScancodeSpec(0x2F),
    PhysicalKeyboardKey.keyB: const ScancodeSpec(0x30),
    PhysicalKeyboardKey.keyN: const ScancodeSpec(0x31),
    PhysicalKeyboardKey.keyM: const ScancodeSpec(0x32),
    PhysicalKeyboardKey.comma: const ScancodeSpec(0x33),
    PhysicalKeyboardKey.period: const ScancodeSpec(0x34),
    PhysicalKeyboardKey.slash: const ScancodeSpec(0x35),
    PhysicalKeyboardKey.shiftRight: const ScancodeSpec(0x36),
    PhysicalKeyboardKey.altLeft: const ScancodeSpec(0x38),
    PhysicalKeyboardKey.altRight: const ScancodeSpec(0x38, extended: true),
    PhysicalKeyboardKey.space: const ScancodeSpec(0x39),
    PhysicalKeyboardKey.capsLock: const ScancodeSpec(0x3A),
    PhysicalKeyboardKey.f1: const ScancodeSpec(0x3B),
    PhysicalKeyboardKey.f2: const ScancodeSpec(0x3C),
    PhysicalKeyboardKey.f3: const ScancodeSpec(0x3D),
    PhysicalKeyboardKey.f4: const ScancodeSpec(0x3E),
    PhysicalKeyboardKey.f5: const ScancodeSpec(0x3F),
    PhysicalKeyboardKey.f6: const ScancodeSpec(0x40),
    PhysicalKeyboardKey.f7: const ScancodeSpec(0x41),
    PhysicalKeyboardKey.f8: const ScancodeSpec(0x42),
    PhysicalKeyboardKey.f9: const ScancodeSpec(0x43),
    PhysicalKeyboardKey.f10: const ScancodeSpec(0x44),
    PhysicalKeyboardKey.f11: const ScancodeSpec(0x57),
    PhysicalKeyboardKey.f12: const ScancodeSpec(0x58),
    PhysicalKeyboardKey.home: const ScancodeSpec(0x47, extended: true),
    PhysicalKeyboardKey.arrowUp: const ScancodeSpec(0x48, extended: true),
    PhysicalKeyboardKey.pageUp: const ScancodeSpec(0x49, extended: true),
    PhysicalKeyboardKey.arrowLeft: const ScancodeSpec(0x4B, extended: true),
    PhysicalKeyboardKey.arrowRight: const ScancodeSpec(0x4D, extended: true),
    PhysicalKeyboardKey.end: const ScancodeSpec(0x4F, extended: true),
    PhysicalKeyboardKey.arrowDown: const ScancodeSpec(0x50, extended: true),
    PhysicalKeyboardKey.pageDown: const ScancodeSpec(0x51, extended: true),
    PhysicalKeyboardKey.insert: const ScancodeSpec(0x52, extended: true),
    PhysicalKeyboardKey.delete: const ScancodeSpec(0x53, extended: true),
    PhysicalKeyboardKey.metaLeft: const ScancodeSpec(0x5B, extended: true),
    PhysicalKeyboardKey.metaRight: const ScancodeSpec(0x5C, extended: true),
  };

  static ScancodeSpec? mapKeyEvent(KeyEvent event) {
    return _logicalMap[event.logicalKey] ?? _physicalMap[event.physicalKey];
  }

  static ScancodeSpec? mapLogicalKey(LogicalKeyboardKey key) =>
      _logicalMap[key];

  static ScancodeSpec? mapPhysicalKey(PhysicalKeyboardKey key) =>
      _physicalMap[key];

  static bool isModifierKey(LogicalKeyboardKey key) {
    return key == LogicalKeyboardKey.controlLeft ||
        key == LogicalKeyboardKey.controlRight ||
        key == LogicalKeyboardKey.altLeft ||
        key == LogicalKeyboardKey.altRight ||
        key == LogicalKeyboardKey.shiftLeft ||
        key == LogicalKeyboardKey.shiftRight ||
        key == LogicalKeyboardKey.metaLeft ||
        key == LogicalKeyboardKey.metaRight;
  }

  /// Encodes a committed string into UTF-16 code units (preserving emoji surrogate pairs).
  static List<int> encodeTextToUtf16Units(String text) => text.codeUnits;

  static const Map<int, ({ScancodeSpec spec, bool shift})> _asciiCharMap =
      <int, ({ScancodeSpec spec, bool shift})>{
    0x09: (spec: ScancodeSpec(0x0F), shift: false), // \t
    0x0A: (spec: ScancodeSpec(0x1C), shift: false), // \n
    0x20: (spec: ScancodeSpec(0x39), shift: false), // space
    0x21: (spec: ScancodeSpec(0x02), shift: true), // !
    0x22: (spec: ScancodeSpec(0x28), shift: true), // "
    0x23: (spec: ScancodeSpec(0x04), shift: true), // #
    0x24: (spec: ScancodeSpec(0x05), shift: true), // $
    0x25: (spec: ScancodeSpec(0x06), shift: true), // %
    0x26: (spec: ScancodeSpec(0x08), shift: true), // &
    0x27: (spec: ScancodeSpec(0x28), shift: false), // '
    0x28: (spec: ScancodeSpec(0x0A), shift: true), // (
    0x29: (spec: ScancodeSpec(0x0B), shift: true), // )
    0x2A: (spec: ScancodeSpec(0x09), shift: true), // *
    0x2B: (spec: ScancodeSpec(0x0D), shift: true), // +
    0x2C: (spec: ScancodeSpec(0x33), shift: false), // ,
    0x2D: (spec: ScancodeSpec(0x0C), shift: false), // -
    0x2E: (spec: ScancodeSpec(0x34), shift: false), // .
    0x2F: (spec: ScancodeSpec(0x35), shift: false), // /
    0x30: (spec: ScancodeSpec(0x0B), shift: false), // 0
    0x31: (spec: ScancodeSpec(0x02), shift: false), // 1
    0x32: (spec: ScancodeSpec(0x03), shift: false), // 2
    0x33: (spec: ScancodeSpec(0x04), shift: false), // 3
    0x34: (spec: ScancodeSpec(0x05), shift: false), // 4
    0x35: (spec: ScancodeSpec(0x06), shift: false), // 5
    0x36: (spec: ScancodeSpec(0x07), shift: false), // 6
    0x37: (spec: ScancodeSpec(0x08), shift: false), // 7
    0x38: (spec: ScancodeSpec(0x09), shift: false), // 8
    0x39: (spec: ScancodeSpec(0x0A), shift: false), // 9
    0x3A: (spec: ScancodeSpec(0x27), shift: true), // :
    0x3B: (spec: ScancodeSpec(0x27), shift: false), // ;
    0x3C: (spec: ScancodeSpec(0x33), shift: true), // <
    0x3D: (spec: ScancodeSpec(0x0D), shift: false), // =
    0x3E: (spec: ScancodeSpec(0x34), shift: true), // >
    0x3F: (spec: ScancodeSpec(0x35), shift: true), // ?
    0x40: (spec: ScancodeSpec(0x03), shift: true), // @
    0x41: (spec: ScancodeSpec(0x1E), shift: true), // A
    0x42: (spec: ScancodeSpec(0x30), shift: true), // B
    0x43: (spec: ScancodeSpec(0x2E), shift: true), // C
    0x44: (spec: ScancodeSpec(0x20), shift: true), // D
    0x45: (spec: ScancodeSpec(0x12), shift: true), // E
    0x46: (spec: ScancodeSpec(0x21), shift: true), // F
    0x47: (spec: ScancodeSpec(0x22), shift: true), // G
    0x48: (spec: ScancodeSpec(0x23), shift: true), // H
    0x49: (spec: ScancodeSpec(0x17), shift: true), // I
    0x4A: (spec: ScancodeSpec(0x24), shift: true), // J
    0x4B: (spec: ScancodeSpec(0x25), shift: true), // K
    0x4C: (spec: ScancodeSpec(0x26), shift: true), // L
    0x4D: (spec: ScancodeSpec(0x32), shift: true), // M
    0x4E: (spec: ScancodeSpec(0x31), shift: true), // N
    0x4F: (spec: ScancodeSpec(0x18), shift: true), // O
    0x50: (spec: ScancodeSpec(0x19), shift: true), // P
    0x51: (spec: ScancodeSpec(0x10), shift: true), // Q
    0x52: (spec: ScancodeSpec(0x13), shift: true), // R
    0x53: (spec: ScancodeSpec(0x1F), shift: true), // S
    0x54: (spec: ScancodeSpec(0x14), shift: true), // T
    0x55: (spec: ScancodeSpec(0x16), shift: true), // U
    0x56: (spec: ScancodeSpec(0x2F), shift: true), // V
    0x57: (spec: ScancodeSpec(0x11), shift: true), // W
    0x58: (spec: ScancodeSpec(0x2D), shift: true), // X
    0x59: (spec: ScancodeSpec(0x15), shift: true), // Y
    0x5A: (spec: ScancodeSpec(0x2C), shift: true), // Z
    0x5B: (spec: ScancodeSpec(0x1A), shift: false), // [
    0x5C: (spec: ScancodeSpec(0x2B), shift: false), // \
    0x5D: (spec: ScancodeSpec(0x1B), shift: false), // ]
    0x5E: (spec: ScancodeSpec(0x07), shift: true), // ^
    0x5F: (spec: ScancodeSpec(0x0C), shift: true), // _
    0x60: (spec: ScancodeSpec(0x29), shift: false), // `
    0x61: (spec: ScancodeSpec(0x1E), shift: false), // a
    0x62: (spec: ScancodeSpec(0x30), shift: false), // b
    0x63: (spec: ScancodeSpec(0x2E), shift: false), // c
    0x64: (spec: ScancodeSpec(0x20), shift: false), // d
    0x65: (spec: ScancodeSpec(0x12), shift: false), // e
    0x66: (spec: ScancodeSpec(0x21), shift: false), // f
    0x67: (spec: ScancodeSpec(0x22), shift: false), // g
    0x68: (spec: ScancodeSpec(0x23), shift: false), // h
    0x69: (spec: ScancodeSpec(0x17), shift: false), // i
    0x6A: (spec: ScancodeSpec(0x24), shift: false), // j
    0x6B: (spec: ScancodeSpec(0x25), shift: false), // k
    0x6C: (spec: ScancodeSpec(0x26), shift: false), // l
    0x6D: (spec: ScancodeSpec(0x32), shift: false), // m
    0x6E: (spec: ScancodeSpec(0x31), shift: false), // n
    0x6F: (spec: ScancodeSpec(0x18), shift: false), // o
    0x70: (spec: ScancodeSpec(0x19), shift: false), // p
    0x71: (spec: ScancodeSpec(0x10), shift: false), // q
    0x72: (spec: ScancodeSpec(0x13), shift: false), // r
    0x73: (spec: ScancodeSpec(0x1F), shift: false), // s
    0x74: (spec: ScancodeSpec(0x14), shift: false), // t
    0x75: (spec: ScancodeSpec(0x16), shift: false), // u
    0x76: (spec: ScancodeSpec(0x2F), shift: false), // v
    0x77: (spec: ScancodeSpec(0x11), shift: false), // w
    0x78: (spec: ScancodeSpec(0x2D), shift: false), // x
    0x79: (spec: ScancodeSpec(0x15), shift: false), // y
    0x7A: (spec: ScancodeSpec(0x2C), shift: false), // z
    0x7B: (spec: ScancodeSpec(0x1A), shift: true), // {
    0x7C: (spec: ScancodeSpec(0x2B), shift: true), // |
    0x7D: (spec: ScancodeSpec(0x1B), shift: true), // }
    0x7E: (spec: ScancodeSpec(0x29), shift: true), // ~
  };

  /// Maps an ASCII code point to a US QWERTY scancode + Shift flag, or null for non-ASCII.
  static ({ScancodeSpec spec, bool shift})? mapAsciiChar(int rune) =>
      _asciiCharMap[rune];

  static const List<({String label, ScancodeSpec spec})> specialKeys =
      <({String label, ScancodeSpec spec})>[
    (label: 'Esc', spec: ScancodeSpec(0x01)),
    (label: 'Tab', spec: ScancodeSpec(0x0F)),
    (label: 'Del', spec: ScancodeSpec(0x53, extended: true)),
    (label: 'F1', spec: ScancodeSpec(0x3B)),
    (label: 'F2', spec: ScancodeSpec(0x3C)),
    (label: 'F3', spec: ScancodeSpec(0x3D)),
    (label: 'F4', spec: ScancodeSpec(0x3E)),
    (label: 'F5', spec: ScancodeSpec(0x3F)),
    (label: 'F6', spec: ScancodeSpec(0x40)),
    (label: 'F7', spec: ScancodeSpec(0x41)),
    (label: 'F8', spec: ScancodeSpec(0x42)),
    (label: 'F9', spec: ScancodeSpec(0x43)),
    (label: 'F10', spec: ScancodeSpec(0x44)),
    (label: 'F11', spec: ScancodeSpec(0x57)),
    (label: 'F12', spec: ScancodeSpec(0x58)),
    (label: '←', spec: ScancodeSpec(0x4B, extended: true)),
    (label: '↑', spec: ScancodeSpec(0x48, extended: true)),
    (label: '↓', spec: ScancodeSpec(0x50, extended: true)),
    (label: '→', spec: ScancodeSpec(0x4D, extended: true)),
  ];
}
