#!/usr/bin/env bash
set -euo pipefail

if [ -f "$HOME/.aer-rdp-env.sh" ]; then
  . "$HOME/.aer-rdp-env.sh"
fi

ARGS=(-t arm64-v8a -t x86_64 -o android/app/src/main/jniLibs build -p rdp-ffi)
if [ "${1:-}" = "--release" ]; then
  ARGS+=(--release)
fi

mkdir -p android/app/src/main/jniLibs
cargo ndk "${ARGS[@]}"