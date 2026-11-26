#!/usr/bin/env bash
set -euo pipefail

if [ -f "$HOME/.aer-rdp-env.sh" ]; then
  . "$HOME/.aer-rdp-env.sh"
fi

echo "=== [1/5] cargo test --workspace ==="
cargo test --workspace

echo "=== [2/5] iOS target readiness & static config check ==="
rustup target list --installed | grep -qx "aarch64-apple-ios"
if command -v xcrun >/dev/null 2>&1; then
  cargo check --target aarch64-apple-ios -p rdp-ffi
else
  echo "INFO: xcrun/iPhoneOS.sdk unavailable on $(uname -s); skipping native C-sysroot iOS check (ring/libz-sys require macOS Xcode SDK)."
  grep -q 'TARGETED_DEVICE_FAMILY = "1,2";' ios/Runner.xcodeproj/project.pbxproj
  grep -q '<key>UISupportsIndirectInputEvents</key>' ios/Runner/Info.plist
  grep -q '<string>audio</string>' ios/Runner/Info.plist
fi

echo "=== [3/5] cargo ndk (arm64-v8a, x86_64) -p rdp-ffi ==="
./scripts/build-rust-android.sh

echo "=== [4/5] flutter pub get && analyze && test && build apk --debug ==="
flutter pub get
flutter analyze
flutter test
flutter build apk --debug

echo "=== [5/5] verify artifacts ==="
for f in \
  "android/app/src/main/jniLibs/arm64-v8a/librdp_ffi.so" \
  "android/app/src/main/jniLibs/x86_64/librdp_ffi.so" \
  "build/app/outputs/flutter-apk/app-debug.apk"
do
  if [ ! -s "$f" ]; then
    echo "ERROR: missing or empty artifact: $f" >&2
    exit 1
  fi
  ls -lh "$f"
done

echo "=== M1 VERIFICATION PASSED ==="