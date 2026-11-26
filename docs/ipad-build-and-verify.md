# iPadOS Build & Verification Guide (aer-rdp)

> Status: Milestone 1 bootstrap outline. Full iPadOS Swift audio/input adapters and CocoaPods XCFramework linkage will be completed in Milestone 4.

## Overview

`aer-rdp` shares a single Flutter UI and pure-Rust RDP core (`crates/rdp-core` + `crates/rdp-ffi`) across Android (primary target) and iPadOS (secondary compatibility target).

## Target Configuration Summary

- `ios/Runner.xcodeproj/project.pbxproj`
  - `TARGETED_DEVICE_FAMILY = "1,2";` (supports iPhone & iPad)
  - `IPHONEOS_DEPLOYMENT_TARGET = 15.0;` (Flutter 3.50.1 baseline, >= 14.0 required for `UIApplicationSupportsIndirectInputEvents` / `UIPointerInteraction`)
- `ios/Runner/Info.plist`
  - `UISupportsIndirectInputEvents = true`
  - `UIRequiresFullScreen = false` (allows Split View / Slide Over on iPad)
  - `UIBackgroundModes = ["audio"]`
  - `UISupportedInterfaceOrientations~ipad` includes Portrait, PortraitUpsideDown, LandscapeLeft, LandscapeRight
- Rust FFI crate (`crates/rdp-ffi`):
  - `crate-type = ["staticlib", "cdylib", "rlib"]`
  - Verified on Linux/Windows via `cargo check --target aarch64-apple-ios -p rdp-ffi`

## Prerequisites (macOS Host for Final IPA/Device Build)

1. macOS with Xcode 15+ and CocoaPods (`gem install cocoapods` or `brew install cocoapods`).
2. Flutter `3.50.1` (`Dart 3.14.0`).
3. Rust stable with `aarch64-apple-ios` (and `aarch64-apple-ios-sim` for iOS Simulator) installed via `rustup target add`.

## Build & Verify Steps (macOS)

1. Build Rust static library for iOS:
   ```bash
   cargo build --release --target aarch64-apple-ios -p rdp-ffi
   ```
2. Install iOS pods and build:
   ```bash
   flutter pub get
   flutter build ios --release --no-codesign
   ```
3. Verify on iPad Simulator or physical iPad via Xcode (`open ios/Runner.xcworkspace`).

## Static Verification on Linux/Windows (CI & Builder VM)

When macOS/Xcode is unavailable, run:
```bash
cargo check --target aarch64-apple-ios -p rdp-ffi
flutter analyze
flutter test
```
