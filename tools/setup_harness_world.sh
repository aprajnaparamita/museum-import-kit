#!/bin/bash
# Sets up tools/harness_world -- the fake "WorldTools export" folder that
# mods/spawnimport/test_harness.lua drives /worldplace against.
#
# The harness mocks the Luanti engine but decodes REAL capture bytes, so
# it needs one real .mca region file. Constraints on the file (enforced by
# mods/spawnimport/test_harness.lua's own probes):
#   * MODERN (1.18+ `sections`) chunks -- the decoder rejects pre-1.18
#     numeric-ID captures;
#   * at least 2 chunks adjacent along one axis (Test 5's
#     neighbouring-chunk-erasure regression needs a real neighbour pair).
# Default: cutecurly's City (WDL/2025) r.-4660.898.mca -- 5 modern chunks,
# 4 of them contiguous along x, ~180k blocks. This script symlinks that
# capture's region/ directory into a WorldTools-style layout; the
# harness's mocked directory listings then scope every read down to that
# single region file.
#
# Idempotent. Safe to re-run after the WDL archive moves (edit WDL_REGION).
set -euo pipefail

WDL_REGION="$HOME/dev/2b2tmuseum-WDL/WDL/2025/cutecurly's City/region"
DEST="$(cd "$(dirname "$0")" && pwd)/harness_world/dimensions/minecraft/worlds/2b2t/2b2t_1"

if [ ! -d "$WDL_REGION" ]; then
    echo "ERROR: WDL region dir not found: $WDL_REGION" >&2
    exit 1
fi

mkdir -p "$DEST"
ln -sfn "$WDL_REGION" "$DEST/region"
echo "harness_world ready: $DEST/region -> $WDL_REGION"
