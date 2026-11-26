#!/usr/bin/env bash
set -euo pipefail

if [ -f "$HOME/.aer-rdp-env.sh" ]; then
  # shellcheck disable=SC1091
  . "$HOME/.aer-rdp-env.sh"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

exec python3 "$SCRIPT_DIR/run_e2e.py" "$@"
