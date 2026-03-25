#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

# Build C++ bridge only if missing (2-5 min first run, skipped after)
if [ ! -f build/lib/libwallpaperengine.a ]; then
    ./build-bridge.sh
fi

swift build -c release

exec .build/release/WallpaperEngine "$@"
