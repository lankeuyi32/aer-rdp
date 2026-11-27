#!/usr/bin/env bash
set -euo pipefail

if [ -f "$HOME/.aer-rdp-env.sh" ]; then
  . "$HOME/.aer-rdp-env.sh"
fi

MODE="${1:-}"
ARGS=(-t arm64-v8a -t x86_64 -o android/app/src/main/jniLibs build -p rdp-ffi)
case "$MODE" in
  --release)
    ARGS+=(--release)
    ;;
  --debug|"")
    ;;
  *)
    echo "Usage: $0 [--debug|--release]" >&2
    exit 1
    ;;
esac

# Remove stale ABI directories/.so outputs before cargo-ndk runs so switching
# between --debug and --release never leaves older-mtime binaries skipped.
rm -rf android/app/src/main/jniLibs
mkdir -p android/app/src/main/jniLibs
cargo ndk "${ARGS[@]}"

# Bundle NDK libc++_shared.so alongside librdp_ffi.so (required by bundled OpenH264 C++ runtime).
SYSROOT_LIB="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib"
cp "$SYSROOT_LIB/aarch64-linux-android/libc++_shared.so" android/app/src/main/jniLibs/arm64-v8a/libc++_shared.so
cp "$SYSROOT_LIB/x86_64-linux-android/libc++_shared.so" android/app/src/main/jniLibs/x86_64/libc++_shared.so
