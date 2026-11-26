import 'dart:convert';

enum AuthMode {
  saved('saved', 'Saved'),
  prompt('prompt', 'Prompt');

  const AuthMode(this.jsonValue, this.label);
  final String jsonValue;
  final String label;

  static AuthMode? fromJson(Object? raw) {
    for (final mode in values) {
      if (mode.jsonValue == raw) return mode;
    }
    return null;
  }
}

enum SecurityMode {
  auto('auto', 'Auto'),
  nla('nla', 'NLA'),
  tls('tls', 'TLS');

  const SecurityMode(this.jsonValue, this.label);
  final String jsonValue;
  final String label;

  static SecurityMode? fromJson(Object? raw) {
    for (final mode in values) {
      if (mode.jsonValue == raw) return mode;
    }
    return null;
  }
}

enum DisplayMode {
  matchDevice('matchDevice', 'Match Device'),
  custom('custom', 'Custom');

  const DisplayMode(this.jsonValue, this.label);
  final String jsonValue;
  final String label;

  static DisplayMode? fromJson(Object? raw) {
    for (final mode in values) {
      if (mode.jsonValue == raw) return mode;
    }
    return null;
  }
}

enum OrientationLock {
  auto('auto', 'Auto'),
  landscape('landscape', 'Landscape'),
  portrait('portrait', 'Portrait');

  const OrientationLock(this.jsonValue, this.label);
  final String jsonValue;
  final String label;

  static OrientationLock? fromJson(Object? raw) {
    for (final lock in values) {
      if (lock.jsonValue == raw) return lock;
    }
    return null;
  }
}

enum AudioMode {
  local('local', 'Local'),
  remote('remote', 'Remote'),
  off('off', 'Off');

  const AudioMode(this.jsonValue, this.label);
  final String jsonValue;
  final String label;

  static AudioMode? fromJson(Object? raw) {
    for (final mode in values) {
      if (mode.jsonValue == raw) return mode;
    }
    return null;
  }
}

enum InputMode {
  directTouch('directTouch', 'Direct Touch'),
  pointer('pointer', 'Pointer');

  const InputMode(this.jsonValue, this.label);
  final String jsonValue;
  final String label;

  static InputMode? fromJson(Object? raw) {
    for (final mode in values) {
      if (mode.jsonValue == raw) return mode;
    }
    return null;
  }
}

enum TextInputMode {
  scancode('scancode', 'Scancode'),
  unicode('unicode', 'Unicode');

  const TextInputMode(this.jsonValue, this.label);
  final String jsonValue;
  final String label;

  static TextInputMode? fromJson(Object? raw) {
    for (final mode in values) {
      if (mode.jsonValue == raw) return mode;
    }
    return null;
  }
}

class DisplayConfig {
  const DisplayConfig({
    this.mode = DisplayMode.matchDevice,
    this.width = 1280,
    this.height = 720,
    this.scale = 1.0,
    this.orientationLock = OrientationLock.auto,
  });

  final DisplayMode mode;
  final int width;
  final int height;
  final double scale;
  final OrientationLock orientationLock;

  DisplayConfig copyWith({
    DisplayMode? mode,
    int? width,
    int? height,
    double? scale,
    OrientationLock? orientationLock,
  }) {
    return DisplayConfig(
      mode: mode ?? this.mode,
      width: width ?? this.width,
      height: height ?? this.height,
      scale: scale ?? this.scale,
      orientationLock: orientationLock ?? this.orientationLock,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'mode': mode.jsonValue,
        'width': width,
        'height': height,
        'scale': scale,
        'orientationLock': orientationLock.jsonValue,
      };
}

class AudioConfig {
  const AudioConfig({this.mode = AudioMode.local});

  final AudioMode mode;

  AudioConfig copyWith({AudioMode? mode}) {
    return AudioConfig(mode: mode ?? this.mode);
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'mode': mode.jsonValue,
      };
}

class InputConfig {
  const InputConfig({
    this.defaultMode = InputMode.directTouch,
    this.swapButtons = false,
    this.textInputMode = TextInputMode.scancode,
  });

  final InputMode defaultMode;
  final bool swapButtons;
  final TextInputMode textInputMode;

  InputConfig copyWith({
    InputMode? defaultMode,
    bool? swapButtons,
    TextInputMode? textInputMode,
  }) {
    return InputConfig(
      defaultMode: defaultMode ?? this.defaultMode,
      swapButtons: swapButtons ?? this.swapButtons,
      textInputMode: textInputMode ?? this.textInputMode,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'defaultMode': defaultMode.jsonValue,
        'swapButtons': swapButtons,
        'textInputMode': textInputMode.jsonValue,
      };
}

class ConnectionProfile {
  const ConnectionProfile({
    required this.id,
    required this.name,
    required this.host,
    this.port = 3389,
    this.username = '',
    this.domain = '',
    this.authMode = AuthMode.prompt,
    this.securityMode = SecurityMode.auto,
    this.displayConfig = const DisplayConfig(),
    this.audioConfig = const AudioConfig(),
    this.inputConfig = const InputConfig(),
    this.favorite = false,
    this.lastConnectedAt,
  });

  final String id;
  final String name;
  final String host;
  final int port;
  final String username;
  final String domain;
  final AuthMode authMode;
  final SecurityMode securityMode;
  final DisplayConfig displayConfig;
  final AudioConfig audioConfig;
  final InputConfig inputConfig;
  final bool favorite;
  final DateTime? lastConnectedAt;

  ConnectionProfile copyWith({
    String? id,
    String? name,
    String? host,
    int? port,
    String? username,
    String? domain,
    AuthMode? authMode,
    SecurityMode? securityMode,
    DisplayConfig? displayConfig,
    AudioConfig? audioConfig,
    InputConfig? inputConfig,
    bool? favorite,
    DateTime? lastConnectedAt,
    bool clearLastConnectedAt = false,
  }) {
    return ConnectionProfile(
      id: id ?? this.id,
      name: name ?? this.name,
      host: host ?? this.host,
      port: port ?? this.port,
      username: username ?? this.username,
      domain: domain ?? this.domain,
      authMode: authMode ?? this.authMode,
      securityMode: securityMode ?? this.securityMode,
      displayConfig: displayConfig ?? this.displayConfig,
      audioConfig: audioConfig ?? this.audioConfig,
      inputConfig: inputConfig ?? this.inputConfig,
      favorite: favorite ?? this.favorite,
      lastConnectedAt: clearLastConnectedAt
          ? null
          : (lastConnectedAt ?? this.lastConnectedAt),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'name': name,
        'host': host,
        'port': port,
        'username': username,
        'domain': domain,
        'authMode': authMode.jsonValue,
        'securityMode': securityMode.jsonValue,
        'displayConfig': displayConfig.toJson(),
        'audioConfig': audioConfig.toJson(),
        'inputConfig': inputConfig.toJson(),
        'favorite': favorite,
        'lastConnectedAt': lastConnectedAt?.toUtc().toIso8601String(),
      };
}

class ProfileBundleV1 {
  const ProfileBundleV1({
    this.version = currentVersion,
    required this.profiles,
  });

  static const int currentVersion = 1;

  final int version;
  final List<ConnectionProfile> profiles;

  Map<String, Object?> toJson() => <String, Object?>{
        'version': version,
        'profiles': profiles.map((p) => p.toJson()).toList(growable: false),
      };

  String toPrettyJson() => const JsonEncoder.withIndent('  ').convert(toJson());
}
