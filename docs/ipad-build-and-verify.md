# iPadOS Build & Verification Guide (aer-rdp)

`aer-rdp` shares a single Flutter UI (`package:material_ui/material_ui.dart`) and pure-Rust RDP protocol engine (`crates/rdp-core` + `crates/rdp-ffi`) across Android (primary target) and iPadOS (secondary compatibility target).

## Target Architecture & M4 Configuration Summary

- **Xcode Project (`ios/Runner.xcodeproj/project.pbxproj`)**:
  - `TARGETED_DEVICE_FAMILY = "1,2";` (universal iPhone + iPad)
  - `IPHONEOS_DEPLOYMENT_TARGET = 15.0;`
  - `SUPPORTED_PLATFORMS = "iphoneos iphonesimulator";` across `Debug`, `Profile`, and `Release`
  - `Build Rust FFI` `PBXShellScriptBuildPhase` invokes `/bin/sh "${SRCROOT}/Scripts/build-rust-ios.sh"` before `Sources` (`build-rust-ios.sh` is POSIX `/bin/sh`-compatible and inspects `PLATFORM_NAME`, `CONFIGURATION`, and `ARCHS`)
  - `OTHER_LDFLAGS` links `$(BUILT_PRODUCTS_DIR)/librdp_ffi.a` with `-Wl,-force_load,$(BUILT_PRODUCTS_DIR)/librdp_ffi.a`, `-lz`, `-lc++`, and frameworks `Security`, `SystemConfiguration`, `AVFAudio`
  - `DEAD_CODE_STRIPPING = NO;` and `STRIP_STYLE = "non-global";` across `Debug`, `Profile`, and `Release` on the `Runner` target
- **CocoaPods & xcconfig (`ios/Podfile`, `ios/Flutter/Debug.xcconfig`, `ios/Flutter/Release.xcconfig`)**:
  - `platform :ios, '15.0'`, `use_frameworks!`, `use_modular_headers!`
  - `post_install` runs `flutter_additional_ios_build_settings(target)` and pins `IPHONEOS_DEPLOYMENT_TARGET = '15.0'`
  - `Debug.xcconfig` / `Release.xcconfig` include `Pods-Runner.{debug,release}.xcconfig` before `Generated.xcconfig`
- **FRB Static Symbol Retention & Loader**:
  - `crates/rdp-ffi/src/lib.rs` exports `dummy_method_to_enforce_bundling() -> usize` referencing all 16 `frb_generated` & `flutter_rust_bridge` C ABI symbols
  - `ios/Runner/Runner-Bridging-Header.h` declares `size_t dummy_method_to_enforce_bundling(void);`
  - `ios/Runner/AppDelegate.swift` calls `_ = dummy_method_to_enforce_bundling()` at launch
  - `lib/main.dart` passes `ExternalLibrary.process(iKnowHowToUseIt: true)` on `TargetPlatform.iOS`
- **iPadOS Audio Session & Sink (`ios/Runner/AudioEngineSink.swift`, `ios/Runner/AppDelegate.swift`)**:
  - `AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])`
  - `AVAudioEngine` + `AVAudioPlayerNode` converting interleaved `Int16` LE PCM to non-interleaved `Float32` `AVAudioPCMBuffer`
  - `MethodChannel("dev.aer.rdp/audio")` registered via `FlutterImplicitEngineDelegate` (`engineBridge.pluginRegistry.registrar(forPlugin: "AerRdpAudioPlugin")`) implementing `open`, `writePcm`, `pollPlayoutDelta`, `pause`, `resume`, `close`
  - Handles `AVAudioSession.interruptionNotification`, `AVAudioSession.routeChangeNotification`, `AVAudioEngineConfigurationChange`, and background/foreground lifecycle transitions
- **iPadOS Permissions & Capabilities (`ios/Runner/Info.plist`)**:
  - `UIApplicationSupportsIndirectInputEvents = true` & `UISupportsIndirectInputEvents = true`
  - `UIRequiresFullScreen = false` (supports Split View & Slide Over)
  - `UIBackgroundModes = ["audio"]`
  - `UISupportedInterfaceOrientations~ipad` lists all 4 orientations
  - `NSLocalNetworkUsageDescription` declared for LAN RDP host connectivity

## Prerequisites (macOS Host for Xcode / Simulator / IPA Builds)

1. macOS with Xcode 15+ (Command Line Tools selected via `xcode-select`) and CocoaPods (`brew install cocoapods` or `gem install cocoapods`).
2. Flutter `3.50.1` (`Dart 3.14.0`).
3. Rust toolchain (`rustup`) with both iOS targets installed:
   ```bash
   rustup target add aarch64-apple-ios aarch64-apple-ios-sim
   ```

## Reproducible Build & Verification Steps (macOS)

1. **Install Flutter packages & CocoaPods**:
   ```bash
   flutter pub get
   (cd ios && pod install)
   ```
2. **Build Rust static libraries / XCFramework** (optional standalone check; Xcode also runs `ios/Scripts/build-rust-ios.sh` automatically during archive/build):
   ```bash
   ./ios/Scripts/build-rust-ios.sh --xcframework --release
   ```
   Or build a single architecture slice directly:
   ```bash
   # Device
   PLATFORM_NAME=iphoneos CONFIGURATION=Release ./ios/Scripts/build-rust-ios.sh
   # Simulator (Apple Silicon)
   PLATFORM_NAME=iphonesimulator CONFIGURATION=Debug ./ios/Scripts/build-rust-ios.sh
   ```
3. **Build unsigned iOS app / IPA**:
   ```bash
   flutter build ios --release --no-codesign
   flutter build ipa --release --no-codesign
   ```
4. **Verify on iPad Simulator**:
   ```bash
   xcrun simctl list devices available | grep -i ipad
   open -a Simulator
   flutter run -d "iPad"
   ```
   Or open `ios/Runner.xcworkspace` in Xcode, select an iPad Simulator or physical iPad target, and run `Product -> Build` / `Product -> Run`.
   Verify on iPad Simulator / device:
   - Connection Center renders Master-Detail split in landscape/portrait (`>= 600dp`) and single-pane in Split View (`507pt`) / Slide Over (`320pt`).
   - Hardware keyboard `Cmd`/`Option`/`F1-F12`/`Esc`/`Tab`/arrows and indirect trackpad hover/scroll/pinch zoom function in session.
   - Local `rdpsnd` audio plays via `AVAudioEngine` and resumes cleanly across route changes / interruptions.

## Static Verification on Linux / Windows (WSL2 Builder & CI)

When macOS / `xcrun` / `xcodebuild` is unavailable, run the comprehensive static verification script from the repo root:

```bash
./scripts/verify-ios-static.sh
```

What `./scripts/verify-ios-static.sh` verifies:
1. `aarch64-apple-ios` Rust target is installed; runs `cargo check --locked --target aarch64-apple-ios -p rdp-ffi` when `xcrun` is available, or validates `cargo tree` + `cargo metadata --filter-platform aarch64-apple-ios` when `xcrun` is absent on Linux.
2. Confirms `aws-lc-sys` / `aws-lc-rs` are absent from the `aarch64-apple-ios` dependency tree and `crates/rdp-core/src` has zero platform leaks (`android`, `jni`, `UIKit`, `AVAudioSession`, `AudioTrack`, `oboe`).
3. Audits `ios/Podfile`, `ios/Flutter/*.xcconfig`, `ios/Scripts/build-rust-ios.sh` (`test -x`, `sh -n`, `bash -n`), `Runner-Bridging-Header.h`, `AudioEngineSink.swift`, `AppDelegate.swift` (`case "open":`..`case "close":`), `crates/rdp-ffi/src/lib.rs` (all 16 FRB symbols), and `lib/main.dart`.
4. Validates `ios/Runner/Info.plist` (`plistlib`) and `ios/Runner.xcodeproj/project.pbxproj` (balanced syntax, `TARGETED_DEVICE_FAMILY = "1,2"`, `IPHONEOS_DEPLOYMENT_TARGET = 15.0`, `DEAD_CODE_STRIPPING = NO`, `STRIP_STYLE = "non-global"`, `SWIFT_OBJC_BRIDGING_HEADER`, `Build Rust FFI` before `Sources`, `-force_load`, no dangling UUIDs).
5. Verifies `0` `package:flutter/material.dart` imports, all `31` canonical `AerKeys`, and runs `flutter analyze` + `flutter test`.
