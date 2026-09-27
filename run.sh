#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

# Let CMake check every required output and input, including configuration and
# patches. Its incremental build avoids the old directory-timestamp heuristic.
./build-bridge.sh

swift build -c release

exec .build/release/WallpaperEngine "$@"
