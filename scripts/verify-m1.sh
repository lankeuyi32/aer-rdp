#!/usr/bin/env bash
set -euo pipefail

if [ -f "$HOME/.aer-rdp-env.sh" ]; then
  . "$HOME/.aer-rdp-env.sh"
fi

echo "=== [1/5] cargo test --workspace ==="
cargo test --workspace

echo "=== [2/5] iOS target readiness & static config check ==="
INSTALLED_TARGETS="$(rustup target list --installed)"
printf '%s\n' "$INSTALLED_TARGETS" | grep -Fxq "aarch64-apple-ios"
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
flutter build apk --debug --target-platform android-arm64,android-x64

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

APK_PATH="build/app/outputs/flutter-apk/app-debug.apk"
python3 - "$APK_PATH" <<'PY'
import sys
import zipfile

apk_path = sys.argv[1]
with zipfile.ZipFile(apk_path, "r") as zf:
    bad_entry = zf.testzip()
    if bad_entry is not None:
        raise SystemExit(f"ERROR: corrupt zip entry in APK: {bad_entry}")

    names = set(zf.namelist())
    manifest_bytes = zf.read("AndroidManifest.xml")
    manifest_utf16 = manifest_bytes.decode("utf-16le", errors="ignore")
    manifest_utf8 = manifest_bytes.decode("utf-8", errors="ignore")
    if "dev.aer.rdp.MainActivity" not in manifest_utf16 and "dev.aer.rdp.MainActivity" not in manifest_utf8:
        raise SystemExit("ERROR: dev.aer.rdp.MainActivity missing from APK AndroidManifest.xml")

    dex_names = sorted(n for n in names if n.startswith("classes") and n.endswith(".dex"))
    if not dex_names:
        raise SystemExit("ERROR: no classes*.dex found in APK")

    has_target_activity = False
    has_stale_activity = False
    for dex_name in dex_names:
        dex_bytes = zf.read(dex_name)
        if b"Ldev/aer/rdp/MainActivity;" in dex_bytes:
            has_target_activity = True
        if b"Ldev/aer/aer_rdp/MainActivity;" in dex_bytes:
            has_stale_activity = True

    if not has_target_activity:
        raise SystemExit("ERROR: Ldev/aer/rdp/MainActivity; missing from classes*.dex")
    if has_stale_activity:
        raise SystemExit("ERROR: stale Ldev/aer/aer_rdp/MainActivity; still present in classes*.dex")

    for abi_so in ("lib/arm64-v8a/librdp_ffi.so", "lib/x86_64/librdp_ffi.so"):
        if abi_so not in names:
            raise SystemExit(f"ERROR: missing {abi_so} in APK")

    stale_32bit = [n for n in names if n.startswith("lib/armeabi-v7a/") or n.startswith("lib/x86/")]
    if stale_32bit:
        raise SystemExit(f"ERROR: unexpected 32-bit ABI libraries in APK: {stale_32bit}")

print("APK manifest, DEX MainActivity, and ABI parity verified.")
PY

if [ -n "${ANDROID_HOME:-}" ] && [ -x "$ANDROID_HOME/build-tools/35.0.0/aapt2" ]; then
  BADGING_OUTPUT="$("$ANDROID_HOME/build-tools/35.0.0/aapt2" dump badging "$APK_PATH")"
  printf '%s\n' "$BADGING_OUTPUT" | grep -Fq "launchable-activity: name='dev.aer.rdp.MainActivity'"
fi

echo "=== M1 VERIFICATION PASSED ==="
