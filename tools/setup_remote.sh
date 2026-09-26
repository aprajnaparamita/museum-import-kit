#!/bin/bash
# Bootstrap the museum import rig on a fresh dedicated VPS (Debian/Ubuntu).
#
# Clones every upstream itself -- no data copies from the Mac needed except
# the maparts (scp, see below):
#
#   museum-import-kit   git@github.com:aprajnaparamita/museum-import-kit.git  (private)
#   2b2tmuseum-WDL      https://github.com/TwinkNet/2b2tmuseum-WDL.git        (~13 GB)
#   mineclonia          https://codeberg.org/mineclonia/mineclonia.git
#   luanti              https://github.com/luanti-org/luanti (tag 5.17.0)
#
# Everything lives under one private root (default /srv/museum, mode 700,
# owned by the invoking sudo user -- nothing world-readable, no root-owned
# runtime). Applies the two museum patches:
#
#   import_tools/game_patches/luanti-5.17.0-museum-import.patch   (engine:
#     core.generate_decorations_with_inputs, used by gap-fill tree placement)
#   import_tools/game_patches/mcl_maps-load_map-headless.patch     (mineclonia:
#     filled-map headless bug -- without it, map frames in imports multiply
#     display entities: 50 frames -> 50,050 objects, observed 2026-09-25)
#
# Usage (from the cloned kit, or set KIT to an existing checkout):
#   sudo MUSEUM_ROOT=/srv/museum ./tools/setup_remote.sh
#
# Env overrides: MUSEUM_ROOT, OWNER, LUANTI_VERSION, KIT_GIT, WDL_GIT,
# MINECLONIA_GIT, SKIP_MCL_MAPS_PATCH=1 (e.g. once upstream merges the fix).
set -euo pipefail

MUSEUM_ROOT="${MUSEUM_ROOT:-/srv/museum}"
OWNER="${OWNER:-${SUDO_USER:-}}"
LUANTI_VERSION="${LUANTI_VERSION:-5.17.0}"
KIT_GIT="${KIT_GIT:-git@github.com:aprajnaparamita/museum-import-kit.git}"
WDL_GIT="${WDL_GIT:-https://github.com/TwinkNet/2b2tmuseum-WDL.git}"
MINECLONIA_GIT="${MINECLONIA_GIT:-https://codeberg.org/mineclonia/mineclonia.git}"
LUANTI_GIT="${LUANTI_GIT:-https://github.com/luanti-org/luanti.git}"
SKIP_MCL_MAPS_PATCH="${SKIP_MCL_MAPS_PATCH:-0}"

[ "$(id -u)" = 0 ] || { echo "ERROR: run with sudo (needs apt + $MUSEUM_ROOT)"; exit 1; }
if [ -z "$OWNER" ] || [ "$OWNER" = root ]; then
    echo "ERROR: run via sudo from a normal user account (OWNER came out as '${OWNER:-<empty>}')."
    echo "The rig runs as that user; root-owned runtime files are not what we want."
    exit 1
fi

# Where is the kit? Prefer an existing checkout (the script lives in one);
# otherwise clone it below.
KIT="${KIT:-}"
if [ -z "$KIT" ]; then
    HERE="$(cd "$(dirname "$0")/.." && pwd)"
    [ -d "$HERE/mods" ] && [ -d "$HERE/manifest" ] && KIT="$HERE"
fi
KIT="${KIT:-$MUSEUM_ROOT/museum-import-kit}"

LUANTI="$MUSEUM_ROOT/luanti"
WDL="$MUSEUM_ROOT/2b2tmuseum-WDL"
DEPLOY_KEY="$MUSEUM_ROOT/.ssh/museum_deploy_ed25519"

log() { echo "=== $*"; }
as_owner() { sudo -u "$OWNER" -H "$@"; }

log "packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
  build-essential cmake git ca-certificates pkg-config \
  libsqlite3-dev libleveldb-dev libzstd-dev zlib1g-dev \
  libluajit-5.1-dev libgmp-dev libjsoncpp-dev libcurl4-openssl-dev libssl-dev \
  python3 sqlite3 rsync screen

log "private root $MUSEUM_ROOT (owner $OWNER, mode 700)"
mkdir -p "$MUSEUM_ROOT" "$MUSEUM_ROOT/.ssh"
chown "$OWNER":"$OWNER" "$MUSEUM_ROOT" "$MUSEUM_ROOT/.ssh"
chmod 700 "$MUSEUM_ROOT" "$MUSEUM_ROOT/.ssh"

log "kit -> $KIT"
if [ -d "$KIT/.git" ]; then
    echo "  already present"
else
    if [ ! -f "$DEPLOY_KEY" ]; then
        as_owner ssh-keygen -t ed25519 -N "" -C "museum-import-kit readonly deploy key" -f "$DEPLOY_KEY" >/dev/null
        echo "  *** NEW DEPLOY KEY -- add this as a READ-ONLY deploy key on"
        echo "  *** https://github.com/aprajnaparamita/museum-import-kit/settings/keys :"
        cat "$DEPLOY_KEY.pub"
    fi
    chmod 600 "$DEPLOY_KEY"; chown "$OWNER":"$OWNER" "$DEPLOY_KEY" "$DEPLOY_KEY.pub"
    as_owner env GIT_SSH_COMMAND="ssh -i $DEPLOY_KEY -o IdentitiesOnly=yes" \
        git clone "$KIT_GIT" "$KIT"
fi

log "WDL archive -> $WDL (~13 GB, the long step)"
if [ -d "$WDL/.git" ]; then
    echo "  already present"
else
    # shallow: it is data, not history (drop --depth 1 if you want the full repo)
    as_owner git clone --depth 1 "$WDL_GIT" "$WDL"
fi

log "luanti $LUANTI_VERSION -> $LUANTI"
if [ -d "$LUANTI/.git" ]; then
    echo "  already present"
else
    as_owner git clone --depth 1 --branch "$LUANTI_VERSION" "$LUANTI_GIT" "$LUANTI"
fi
if grep -q generate_decorations_with_inputs "$LUANTI/src/script/lua_api/l_mapgen.cpp" 2>/dev/null; then
    echo "  engine patch already applied"
else
    as_owner git -C "$LUANTI" apply "$KIT/import_tools/game_patches/luanti-5.17.0-museum-import.patch"
    echo "  applied museum engine patch (generate_decorations_with_inputs)"
fi

log "mineclonia -> $LUANTI/games/mineclonia"
if [ -d "$LUANTI/games/mineclonia/.git" ]; then
    echo "  already present"
else
    as_owner git clone "$MINECLONIA_GIT" "$LUANTI/games/mineclonia"
fi
if [ "$SKIP_MCL_MAPS_PATCH" = 1 ]; then
    echo "  SKIP_MCL_MAPS_PATCH=1 -- mcl_maps headless fix NOT applied"
elif grep -q "no player exists to send it to" "$LUANTI/games/mineclonia/mods/ITEMS/mcl_maps/init.lua"; then
    echo "  mcl_maps patch already applied (or upstreamed)"
elif as_owner git -C "$LUANTI/games/mineclonia" apply --check \
        "$KIT/import_tools/game_patches/mcl_maps-load_map-headless.patch" 2>/dev/null; then
    as_owner git -C "$LUANTI/games/mineclonia" apply \
        "$KIT/import_tools/game_patches/mcl_maps-load_map-headless.patch"
    echo "  applied mcl_maps headless patch (map-frame entity pile fix)"
else
    echo "  WARNING: mcl_maps patch does not apply and the fix is not detected."
    echo "  WARNING: importing filled maps into item frames will multiply display"
    echo "  WARNING: entities until this is resolved. Check mods/ITEMS/mcl_maps/init.lua."
fi

log "build luanti (server only)"
cd "$LUANTI"
as_owner cmake . \
  -DCMAKE_BUILD_TYPE=Release \
  -DRUN_IN_PLACE=TRUE \
  -DBUILD_CLIENT=FALSE \
  -DBUILD_SERVER=TRUE \
  -DENABLE_LEVELDB=TRUE \
  -DENABLE_POSTGRESQL=FALSE \
  -DENABLE_REDIS=FALSE \
  -DENABLE_PROMETHEUS=FALSE
as_owner make -j"$(nproc)"
ls -la bin/luantiserver

chown -R "$OWNER":"$OWNER" "$MUSEUM_ROOT"
chmod 700 "$MUSEUM_ROOT"

echo
echo "=== done. next steps (not automated) ==="
cat <<TXT
  1. Maparts (the only scp step -- NOT in any git repo):
       scp -r museum-maparts/output/final VPS:$MUSEUM_ROOT/museum-maparts/output/
     (121 pre-quantized map-sized PNGs; only needed for mapart gallery fill)
  2. Prepare the world (as $OWNER, no sudo):
       $KIT/tools/prepare_world.sh
  3. Start the import:
       screen -dmS import env LUANTI_BIN=$LUANTI/bin/luantiserver \\
         IMPORT_CONF=$KIT/tools/import.conf \\
         $KIT/tools/supervise.sh $LUANTI/worlds/2b2t-museum /tmp/fullimport.log 208 300

  Hardening notes (already applied): $MUSEUM_ROOT is mode 700, owned by
  $OWNER; the deploy key is read-only and lives at $DEPLOY_KEY; nothing
  here runs as root. Consider also: ufw allow OpenSSH && ufw enable, and
  key-only sshd auth. Back the world up OFF the box when the run finishes.
TXT
