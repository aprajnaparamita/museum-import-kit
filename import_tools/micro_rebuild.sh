#!/bin/bash
# micro_rebuild.sh -- one-command rebuild of the MICRO test world (2026-09-25).
#
# The micro world is the tight iteration loop: 4 small bases covering BOTH
# import format families and all three dimension bands --
#
#   Taylobase 4 (Nether)          144 chunks   OLD 1.12 numeric  (DataVersion 1343)
#   Tactical Nuke 2023-09       1,403 chunks   NEW 1.18+          (DataVersion 3465)
#   Hausemaster Base 2012 (Nether) 1,160 chunks  OLD 1.12 numeric  (DataVersion 1343)
#   Endhaven (End trim2x2)      4,037 chunks   NEW 1.18+          (DataVersion 3465)
#
# Manifest source of truth: $KIT/manifest/museum_manifest_micro.json
# (copied into the world on every run -- edit it there, not in the world).
# base_patches.json likewise comes from $KIT/manifest/.
#
# Differences from full_rebuild.sh (deliberate, keep it that way):
#   - NO mapart gallery-fill: not a display world, skip the extra pass.
#   - worlddata is wiped every run (loop = full deterministic rebuild).
# The full 205-base import runs on the destination server, not here.
#
# Usage: ./micro_rebuild.sh [--no-deploy] [--continue]
#   default: rebuild, then deploy -> "2b2t Museum TEST" (museumloot
#   stripped so the owner can walk around without the batch restarting).
#   --continue: do NOT wipe; keep whatever bases are already placed and
#   only import what's missing (survives a mid-run crash -- e.g. the
#   external drive dropping gives SIGBUS on the mmap'd map.sqlite, which
#   is what this flag was added for on 2026-09-26).

set -euo pipefail

STAGING="/Users/dara/dev/museum-microtest"
DEPLOYED="/Users/dara/Library/Application Support/minetest/worlds/2b2t Museum TEST"
LUANTI_BIN="$HOME/dev/luanti/bin/luanti"          # 5.17.0 -- NOT museum-testrig's 5.16.1
LUANTI_CONF="$HOME/dev/museum-testrig/conf/microtest.conf"
KIT="/Volumes/Dara/dev/museum-import-kit"
LOGDIR="/tmp"
NO_DEPLOY=0
CONTINUE=0
for arg in "$@"; do
    case "$arg" in
        --no-deploy) NO_DEPLOY=1 ;;
        --continue)  CONTINUE=1 ;;
        *) echo "unknown arg: $arg" >&2; exit 1 ;;
    esac
done

log() { echo "[micro_rebuild] $*"; }

if pgrep -f "$LUANTI_BIN" > /dev/null; then
    echo "ERROR: a luanti process is already running -- close the client and any" >&2
    echo "background server before rebuilding." >&2
    exit 1
fi

log "syncing kit -> world (worldmods, manifest, base_patches)"
mkdir -p "$STAGING/worldmods"
for mod in spawnimport museumloot museumwarp museumportals; do
    rm -rf "$STAGING/worldmods/$mod"
    cp -R "$KIT/mods/$mod" "$STAGING/worldmods/"
done
cp "$KIT/manifest/museum_manifest_micro.json" "$STAGING/museum_manifest.json"
cp "$KIT/manifest/base_patches.json" "$STAGING/base_patches.json"

if [ "$CONTINUE" = "1" ]; then
    log "--continue: keeping existing world data (bases already placed stay)"
else
    log "wiping world data"
    rm -f "$STAGING/map.sqlite" "$STAGING/mod_storage.sqlite" "$STAGING/map_meta.txt" \
          "$STAGING/env_meta.txt" "$STAGING/force_loaded.txt"
    rm -rf "$STAGING/mod_storage" "$STAGING/mcl_maps"
fi

log "pass 1: import + gap-fill + loot"
# Truncate the run logs: the engine APPENDS to --logfile, and the
# ServerError scan below would trip over a PREVIOUS run's error
# (2026-09-27: exactly that -- a stale v7 crash aborted a perfectly good
# v8 pass 1).
: > "$LOGDIR/micro_pass1.log"
: > "$LOGDIR/micro_pass2.log"
"$LUANTI_BIN" --server --config "$LUANTI_CONF" --world "$STAGING" --gameid mineclonia \
    --logfile "$LOGDIR/micro_pass1.log" > "$LOGDIR/micro_pass1.stdout" 2>&1
if grep -qi "ServerError" "$LOGDIR/micro_pass1.log"; then
    echo "ERROR: pass 1 hit a ServerError, see $LOGDIR/micro_pass1.log" >&2
    exit 1
fi

log "pass 2: verification/convergence"
"$LUANTI_BIN" --server --config "$LUANTI_CONF" --world "$STAGING" --gameid mineclonia \
    --logfile "$LOGDIR/micro_pass2.log" > "$LOGDIR/micro_pass2.stdout" 2>&1
if grep -qi "ServerError" "$LOGDIR/micro_pass2.log"; then
    echo "ERROR: pass 2 hit a ServerError, see $LOGDIR/micro_pass2.log" >&2
    exit 1
fi

log "resetting mapart-gallery variety registry for this fresh run"
echo '{}' > "$KIT/import_tools/mapart_gallery/used_pieces_registry.json"

log "mapart gallery fill (Tactical Nuke's gallery + real-map cluster fixes)"
# The gallery's own engine run must NOT see a museum_manifest_path: the
# batch would re-run and museumloot's auto-kick can request_shutdown under
# the gallery's worldmod work. Strip that one line from the run conf.
sed '/^museum_manifest_path/d' "$LUANTI_CONF" > "$LOGDIR/micro_gallery.conf"
GALLERY_LUANTI_BIN="$LUANTI_BIN" GALLERY_LUANTI_CONF="$LOGDIR/micro_gallery.conf" \
    python3 "$KIT/import_tools/mapart_gallery/auto_gallery_fill.py" \
        --world "$STAGING" --manifest "$STAGING/museum_manifest.json" \
        > "$LOGDIR/micro_gallery.log" 2>&1 || {
    echo "ERROR: mapart gallery fill failed -- see $LOGDIR/micro_gallery.log" >&2
    exit 1
}

log "sqlite integrity check"
for f in map.sqlite mod_storage.sqlite; do
    [ -f "$STAGING/$f" ] || continue
    result=$(sqlite3 "$STAGING/$f" "PRAGMA integrity_check;" 2>&1)
    if [ "$result" != "ok" ]; then
        echo "ERROR: $f integrity check failed: $result" >&2
        exit 1
    fi
done

if [ "$NO_DEPLOY" = "1" ]; then
    log "done (--no-deploy given, staging only)"
    exit 0
fi

if pgrep -f "$LUANTI_BIN" > /dev/null; then
    echo "ERROR: a luanti process started running before deploy -- aborting deploy" >&2
    exit 1
fi

BACKUP="/tmp/micro_deploy_backup_$$"
mkdir -p "$BACKUP"
log "backing up deployed auth/players"
# Player state can live in auth.sqlite + players.sqlite (older layout) OR
# in a players/ directory (what the client writes for THIS world) -- back
# up all three or the owner's position/inventory silently resets every
# deploy (2026-09-26: caught the empty players/ dir being copied over the
# real one).
for f in auth.sqlite players.sqlite players; do
    if [ -e "$DEPLOYED/$f" ]; then
        cp -R "$DEPLOYED/$f" "$BACKUP/$f"
    fi
done

log "deploying staging -> live world"
rm -rf "$DEPLOYED"
mkdir -p "$DEPLOYED"
cp -R "$STAGING/." "$DEPLOYED/"
for f in auth.sqlite players.sqlite players; do
    if [ -e "$BACKUP/$f" ]; then
        rm -rf "$DEPLOYED/$f"
        cp -R "$BACKUP/$f" "$DEPLOYED/$f"
    fi
done
rm -rf "$DEPLOYED/worldmods/museumloot"

log "done -- deployed to '2b2t Museum TEST'"
