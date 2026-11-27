import 'dart:convert';

import 'connection_profile.dart';

class ProfileBundleValidationResult {
  const ProfileBundleValidationResult({
    required this.profiles,
    required this.errors,
  });

  final List<ConnectionProfile> profiles;
  final List<String> errors;

  bool get isValid => errors.isEmpty;
}

abstract final class ProfileValidator {
  static const Set<String> forbiddenSecretFields = <String>{
    'password',
    'secret',
    'pass',
    'plaintextPassword',
    'token',
    'passwd',
    'privateKey',
  };

  static const List<String> requiredProfileFields = <String>[
    'id',
    'name',
    'host',
    'port',
    'username',
    'domain',
    'authMode',
    'securityMode',
    'displayConfig',
    'audioConfig',
    'inputConfig',
    'favorite',
    'lastConnectedAt',
  ];

  static String? validateHost(String raw) {
    if (raw.trim().isEmpty) {
      return 'Host must not be empty';
    }
    return null;
  }

  static int? parseValidPort(String raw) {
    final parsed = int.tryParse(raw.trim());
    if (parsed == null || parsed < 1 || parsed > 65535) {
      return null;
    }
    return parsed;
  }

  static int? parseValidDimension(String raw) {
    final parsed = int.tryParse(raw.trim());
    if (parsed == null || parsed < 1 || parsed > 16384) {
      return null;
    }
    return parsed;
  }

  static double? parseValidScale(String raw) {
    final parsed = double.tryParse(raw.trim());
    if (parsed == null || parsed.isNaN || parsed < 0.25 || parsed > 8.0) {
      return null;
    }
    return parsed;
  }

  static int? parseValidFps(String raw) {
    final parsed = int.tryParse(raw.trim());
    if (parsed == null || parsed < 15 || parsed > 120) {
      return null;
    }
    return parsed;
  }

  static int? parseValidBandwidthMbps(String raw) {
    final parsed = int.tryParse(raw.trim());
    if (parsed == null || parsed < 1 || parsed > 200) {
      return null;
    }
    return parsed;
  }

  static ProfileBundleValidationResult validateBundleJson(String rawJson) {
    final Object? decoded;
    try {
      decoded = jsonDecode(rawJson);
    } on FormatException catch (e) {
      return ProfileBundleValidationResult(
        profiles: const <ConnectionProfile>[],
        errors: <String>['Invalid JSON format: ${e.message}'],
      );
    }

    if (decoded is! Map<String, dynamic>) {
      return const ProfileBundleValidationResult(
        profiles: <ConnectionProfile>[],
        errors: <String>['Invalid payload: top-level JSON must be an object.'],
      );
    }

    final List<String> errors = <String>[];
    final Object? version = decoded['version'];
    if (version is! int || version != ProfileBundleV1.currentVersion) {
      errors.add(
        'Invalid or unsupported schema version: $version (expected ${ProfileBundleV1.currentVersion}).',
      );
    }

    final Object? rawProfiles = decoded['profiles'];
    if (rawProfiles is! List<Object?>) {
      errors.add("Invalid payload: missing or non-list 'profiles' field.");
      return ProfileBundleValidationResult(
        profiles: const <ConnectionProfile>[],
        errors: errors,
      );
    }

    final List<ConnectionProfile> parsedProfiles = <ConnectionProfile>[];
    final Set<String> seenIds = <String>{};

    for (int i = 0; i < rawProfiles.length; i++) {
      final String prefix = 'profiles[$i]';
      final Object? item = rawProfiles[i];
      if (item is! Map<String, dynamic>) {
        errors.add('$prefix: must be a JSON object.');
        continue;
      }

      for (final String secretKey in forbiddenSecretFields) {
        if (item.containsKey(secretKey)) {
          final Object? val = item[secretKey];
          if (val != null && val != '') {
            errors.add(
              '$prefix: plaintext secret field "$secretKey" is forbidden.',
            );
          }
        }
      }

      for (final String req in requiredProfileFields) {
        if (!item.containsKey(req)) {
          errors.add('$prefix: missing required field "$req".');
        }
      }

      final Object? rawId = item['id'];
      String id = '';
      if (rawId is! String || rawId.trim().isEmpty) {
        errors.add('$prefix.id: must be a non-empty string.');
      } else if (seenIds.contains(rawId)) {
        errors.add('$prefix.id: duplicate profile id "$rawId".');
      } else {
        seenIds.add(rawId);
        id = rawId;
      }

      final Object? rawName = item['name'];
      String name = '';
      if (rawName is! String || rawName.trim().isEmpty) {
        errors.add('$prefix.name: must be a non-empty string.');
      } else {
        name = rawName;
      }

      final Object? rawHost = item['host'];
      String host = '';
      if (rawHost is! String || rawHost.trim().isEmpty) {
        errors.add('$prefix.host: must be a non-empty string.');
      } else {
        host = rawHost.trim();
      }

      final Object? rawPort = item['port'];
      int port = 3389;
      if (rawPort is! int || rawPort < 1 || rawPort > 65535) {
        errors.add('$prefix.port: must be integer in [1, 65535], got $rawPort.');
      } else {
        port = rawPort;
      }

      final Object? rawUser = item['username'];
      String username = '';
      if (item.containsKey('username')) {
        if (rawUser is! String) {
          errors.add('$prefix.username: must be a string.');
        } else {
          username = rawUser;
        }
      }

      final Object? rawDomain = item['domain'];
      String domain = '';
      if (item.containsKey('domain')) {
        if (rawDomain is! String) {
          errors.add('$prefix.domain: must be a string.');
        } else {
          domain = rawDomain;
        }
      }

      String? credentialId;
      if (item.containsKey('credentialId') && item['credentialId'] != null) {
        final Object? rawCredId = item['credentialId'];
        if (rawCredId is! String || rawCredId.trim().isEmpty) {
          errors.add('$prefix.credentialId: must be a non-empty string.');
        } else {
          credentialId = rawCredId.trim();
        }
      }

      final AuthMode? authMode = AuthMode.fromJson(item['authMode']);
      if (authMode == null) {
        errors.add('$prefix.authMode: invalid value "${item['authMode']}".');
      }

      final SecurityMode? securityMode =
          SecurityMode.fromJson(item['securityMode']);
      if (securityMode == null) {
        errors.add(
          '$prefix.securityMode: invalid value "${item['securityMode']}".',
        );
      }

      DisplayConfig displayConfig = const DisplayConfig();
      final Object? rawDisplay = item['displayConfig'];
      if (rawDisplay is! Map<String, dynamic>) {
        errors.add('$prefix.displayConfig: must be an object.');
      } else {
        final DisplayMode? dMode = DisplayMode.fromJson(rawDisplay['mode']);
        if (dMode == null) {
          errors.add(
            '$prefix.displayConfig.mode: invalid value "${rawDisplay['mode']}".',
          );
        }
        final Object? w = rawDisplay['width'];
        if (w is! int || w < 1 || w > 16384) {
          errors.add(
            '$prefix.displayConfig.width: must be integer in [1, 16384], got $w.',
          );
        }
        final Object? h = rawDisplay['height'];
        if (h is! int || h < 1 || h > 16384) {
          errors.add(
            '$prefix.displayConfig.height: must be integer in [1, 16384], got $h.',
          );
        }
        final Object? s = rawDisplay['scale'];
        if (s is! num || s.toDouble() < 0.25 || s.toDouble() > 8.0) {
          errors.add(
            '$prefix.displayConfig.scale: must be number in [0.25, 8.0], got $s.',
          );
        }
        final OrientationLock? oLock =
            OrientationLock.fromJson(rawDisplay['orientationLock']);
        if (oLock == null) {
          errors.add(
            '$prefix.displayConfig.orientationLock: invalid value "${rawDisplay['orientationLock']}".',
          );
        }

        int targetFps = 60;
        bool fpsOk = true;
        if (rawDisplay.containsKey('targetFps') &&
            rawDisplay['targetFps'] != null) {
          final Object? rawFps = rawDisplay['targetFps'];
          if (rawFps is! int || rawFps < 15 || rawFps > 120) {
            errors.add(
              '$prefix.displayConfig.targetFps: must be integer in [15, 120], got $rawFps.',
            );
            fpsOk = false;
          } else {
            targetFps = rawFps;
          }
        }

        BandwidthMode bwMode = BandwidthMode.balanced;
        bool bwModeOk = true;
        if (rawDisplay.containsKey('bandwidthMode') &&
            rawDisplay['bandwidthMode'] != null) {
          final BandwidthMode? parsedBw =
              BandwidthMode.fromJson(rawDisplay['bandwidthMode']);
          if (parsedBw == null) {
            errors.add(
              '$prefix.displayConfig.bandwidthMode: invalid value "${rawDisplay['bandwidthMode']}".',
            );
            bwModeOk = false;
          } else {
            bwMode = parsedBw;
          }
        }

        int maxBwMbps = 15;
        bool maxBwOk = true;
        if (rawDisplay.containsKey('maxBandwidthMbps') &&
            rawDisplay['maxBandwidthMbps'] != null) {
          final Object? rawMaxBw = rawDisplay['maxBandwidthMbps'];
          if (rawMaxBw is! int || rawMaxBw < 1 || rawMaxBw > 200) {
            errors.add(
              '$prefix.displayConfig.maxBandwidthMbps: must be integer in [1, 200], got $rawMaxBw.',
            );
            maxBwOk = false;
          } else {
            maxBwMbps = rawMaxBw;
          }
        }

        if (dMode != null &&
            w is int &&
            h is int &&
            s is num &&
            oLock != null &&
            fpsOk &&
            bwModeOk &&
            maxBwOk) {
          displayConfig = DisplayConfig(
            mode: dMode,
            width: w,
            height: h,
            scale: s.toDouble(),
            orientationLock: oLock,
            targetFps: targetFps,
            bandwidthMode: bwMode,
            maxBandwidthMbps: maxBwMbps,
          );
        }
      }

      AudioConfig audioConfig = const AudioConfig();
      final Object? rawAudio = item['audioConfig'];
      if (rawAudio is! Map<String, dynamic>) {
        errors.add('$prefix.audioConfig: must be an object.');
      } else {
        final AudioMode? aMode = AudioMode.fromJson(rawAudio['mode']);
        if (aMode == null) {
          errors.add(
            '$prefix.audioConfig.mode: invalid value "${rawAudio['mode']}".',
          );
        } else {
          audioConfig = AudioConfig(mode: aMode);
        }
      }

      InputConfig inputConfig = const InputConfig();
      final Object? rawInput = item['inputConfig'];
      if (rawInput is! Map<String, dynamic>) {
        errors.add('$prefix.inputConfig: must be an object.');
      } else {
        final InputMode? iMode = InputMode.fromJson(rawInput['defaultMode']);
        if (iMode == null) {
          errors.add(
            '$prefix.inputConfig.defaultMode: invalid value "${rawInput['defaultMode']}".',
          );
        }
        final Object? swap = rawInput['swapButtons'];
        if (swap is! bool) {
          errors.add('$prefix.inputConfig.swapButtons: must be a boolean.');
        }
        final TextInputMode? textMode =
            TextInputMode.fromJson(rawInput['textInputMode']);
        if (textMode == null) {
          errors.add(
            '$prefix.inputConfig.textInputMode: invalid value "${rawInput['textInputMode']}".',
          );
        }
        if (iMode != null && swap is bool && textMode != null) {
          inputConfig = InputConfig(
            defaultMode: iMode,
            swapButtons: swap,
            textInputMode: textMode,
          );
        }
      }

      final Object? rawFav = item['favorite'];
      bool favorite = false;
      if (item.containsKey('favorite')) {
        if (rawFav is! bool) {
          errors.add('$prefix.favorite: must be a boolean.');
        } else {
          favorite = rawFav;
        }
      }

      final Object? rawLast = item['lastConnectedAt'];
      DateTime? lastConnectedAt;
      if (rawLast != null) {
        if (rawLast is! String ||
            rawLast.trim().isEmpty ||
            (!rawLast.contains('T') && !rawLast.contains(':'))) {
          errors.add(
            '$prefix.lastConnectedAt: invalid ISO-8601 timestamp "$rawLast".',
          );
        } else {
          final DateTime? parsedDt = DateTime.tryParse(rawLast);
          if (parsedDt == null) {
            errors.add(
              '$prefix.lastConnectedAt: invalid ISO-8601 timestamp "$rawLast".',
            );
          } else {
            lastConnectedAt = parsedDt.toUtc();
          }
        }
      }

      if (errors.isEmpty && authMode != null && securityMode != null) {
        parsedProfiles.add(
          ConnectionProfile(
            id: id,
            name: name,
            host: host,
            port: port,
            username: username,
            domain: domain,
            credentialId: credentialId,
            authMode: authMode,
            securityMode: securityMode,
            displayConfig: displayConfig,
            audioConfig: audioConfig,
            inputConfig: inputConfig,
            favorite: favorite,
            lastConnectedAt: lastConnectedAt,
          ),
        );
      }
    }

    if (errors.isNotEmpty) {
      return ProfileBundleValidationResult(
        profiles: const <ConnectionProfile>[],
        errors: errors,
      );
    }
    return ProfileBundleValidationResult(
      profiles: parsedProfiles,
      errors: const <String>[],
    );
  }
}
