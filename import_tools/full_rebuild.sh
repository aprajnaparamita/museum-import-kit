#!/bin/bash
# Full rebuild driver for museum-playtest (round 30). Chains every step
# that must happen for a correct rebuild, in order -- wipe, pass 1
# (real import + gap-fill), pass 2 (verification/convergence), automatic
# mapart gallery-fill (round 29's orchestrator: fills empty frames from
# museum-maparts + fixes scrambled real ceiling/floor grids), then
# deploy to the live client world.
#
# Written because gallery-fill was, until round 29, a manual step nobody
# remembered to redo after a full rebuild -- Tactical Nuke's restored
# gallery silently vanished across at least two rebuilds before the
# owner noticed. This script exists so "rebuild the museum" always means
# ALL of the above, not "whatever steps I remembered this time."
#
# Usage: ./full_rebuild.sh [--no-deploy]
#
# Preconditions: no luanti client connected to either the staging world
# or the deployed world (checked below, not just assumed).

set -euo pipefail

STAGING="/Users/dara/dev/museum-playtest"
DEPLOYED="/Users/dara/Library/Application Support/minetest/worlds/2b2t Museum TEST"
LUANTI_BIN="$HOME/dev/museum-testrig/bin/luanti"
LUANTI_CONF="$HOME/dev/museum-testrig/conf/playtest.conf"
KIT="/Volumes/Dara/dev/museum-import-kit"
LOGDIR="/tmp"
NO_DEPLOY=0
[ "${1:-}" = "--no-deploy" ] && NO_DEPLOY=1

log() { echo "[full_rebuild] $*"; }

if pgrep -f "$LUANTI_BIN" > /dev/null; then
    echo "ERROR: a luanti process is already running -- close the client and any" >&2
    echo "background server before running a full rebuild." >&2
    exit 1
fi

log "syncing kit worldmods -> staging (spawnimport, museumloot, museumwarp)"
for mod in spawnimport museumloot museumwarp; do
    if [ -d "$KIT/mods/$mod" ]; then
        rm -rf "$STAGING/worldmods/$mod"
        cp -R "$KIT/mods/$mod" "$STAGING/worldmods/"
    fi
done

log "wiping staging world data"
rm -f "$STAGING/map.sqlite" "$STAGING/mod_storage.sqlite" "$STAGING/map_meta.txt" \
      "$STAGING/env_meta.txt" "$STAGING/force_loaded.txt"
rm -rf "$STAGING/mod_storage" "$STAGING/mcl_maps"

log "resetting mapart-gallery variety registry for this fresh run"
echo '{}' > "$KIT/import_tools/mapart_gallery/used_pieces_registry.json"

log "pass 1: real import"
"$LUANTI_BIN" --server --config "$LUANTI_CONF" --world "$STAGING" --gameid mineclonia \
    --logfile "$LOGDIR/rebuild_pass1.log" > "$LOGDIR/rebuild_pass1.stdout" 2>&1
if grep -qi "ServerError" "$LOGDIR/rebuild_pass1.log"; then
    echo "ERROR: pass 1 hit a ServerError, see $LOGDIR/rebuild_pass1.log" >&2
    exit 1
fi
log "pass 1 done"

log "pass 2: verification pass"
"$LUANTI_BIN" --server --config "$LUANTI_CONF" --world "$STAGING" --gameid mineclonia \
    --logfile "$LOGDIR/rebuild_pass2.log" > "$LOGDIR/rebuild_pass2.stdout" 2>&1
if grep -qi "ServerError" "$LOGDIR/rebuild_pass2.log"; then
    echo "ERROR: pass 2 hit a ServerError, see $LOGDIR/rebuild_pass2.log" >&2
    exit 1
fi
log "pass 2 done"

log "sqlite integrity check"
for f in map.sqlite mod_storage.sqlite; do
    result=$(sqlite3 "$STAGING/$f" "PRAGMA integrity_check;" 2>&1)
    if [ "$result" != "ok" ]; then
        echo "ERROR: $f integrity check failed: $result" >&2
        exit 1
    fi
done

log "automatic mapart gallery-fill (all bases in staging's manifest)"
python3 "$KIT/import_tools/mapart_gallery/auto_gallery_fill.py" --world "$STAGING"

log "post-gallery-fill sqlite integrity check"
for f in map.sqlite mod_storage.sqlite; do
    result=$(sqlite3 "$STAGING/$f" "PRAGMA integrity_check;" 2>&1)
    if [ "$result" != "ok" ]; then
        echo "ERROR: $f integrity check failed after gallery-fill: $result" >&2
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

BACKUP="/tmp/deploy_backup_$$"
mkdir -p "$BACKUP"
log "backing up deployed auth/players"
cp "$DEPLOYED/auth.sqlite" "$BACKUP/auth.sqlite"
cp "$DEPLOYED/players.sqlite" "$BACKUP/players.sqlite"

log "deploying staging -> live world"
rm -rf "$DEPLOYED"
mkdir -p "$DEPLOYED"
cp -R "$STAGING/." "$DEPLOYED/"
cp "$BACKUP/auth.sqlite" "$DEPLOYED/auth.sqlite"
cp "$BACKUP/players.sqlite" "$DEPLOYED/players.sqlite"
rm -rf "$DEPLOYED/worldmods/museumloot"

log "final integrity check on deployed world"
for f in map.sqlite mod_storage.sqlite; do
    result=$(sqlite3 "$DEPLOYED/$f" "PRAGMA integrity_check;" 2>&1)
    if [ "$result" != "ok" ]; then
        echo "ERROR: deployed $f integrity check failed: $result" >&2
        exit 1
    fi
done

log "done -- deployed and verified"
