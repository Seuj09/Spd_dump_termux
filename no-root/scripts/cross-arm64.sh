#!/usr/bin/env bash
# Static arm64 (aarch64) build. Same steps as cross-arm32.sh.
here=$(cd "$(dirname "$0")" && pwd)
exec env ARCH=arm64 "$here/cross-arm32.sh" "$@"
