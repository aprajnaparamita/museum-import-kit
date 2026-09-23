#!/bin/bash
# One-shot setup for a fresh Ubuntu box (vast.ai instance, VPS, whatever).
# Builds a server-only Luanti and prepares the import world.
#
# Does NOT fetch Mineclonia or the WDL archive -- copy those from your own
# machine (see GUIDE-vastai.md). Using *your* Mineclonia matters: the block
# palette was verified against that install's actual registered node names,
# and a different version can rename nodes.
set -euo pipefail

LUANTI_VERSION="${LUANTI_VERSION:-5.16.1}"
PREFIX="${PREFIX:-$HOME}"
KIT="${KIT:-$PREFIX/museum-import-kit}"

echo "=== packages ==="
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
  build-essential cmake git ca-certificates pkg-config \
  libsqlite3-dev libleveldb-dev libzstd-dev zlib1g-dev \
  libluajit-5.1-dev libgmp-dev libjsoncpp-dev libcurl4-openssl-dev libssl-dev \
  python3 sqlite3 rsync screen

echo "=== build luanti $LUANTI_VERSION (server only) ==="
cd "$PREFIX"
if [ ! -d luanti ]; then
  git clone --depth 1 --branch "$LUANTI_VERSION" https://github.com/luanti-org/luanti.git
fi
cd luanti
cmake . \
  -DCMAKE_BUILD_TYPE=Release \
  -DRUN_IN_PLACE=TRUE \
  -DBUILD_CLIENT=FALSE \
  -DBUILD_SERVER=TRUE \
  -DENABLE_LEVELDB=TRUE \
  -DENABLE_POSTGRESQL=FALSE \
  -DENABLE_REDIS=FALSE \
  -DENABLE_PROMETHEUS=FALSE
make -j"$(nproc)"
ls -la bin/luantiserver

echo
echo "=== next steps (not automated - they need YOUR files) ==="
cat <<TXT
  1. Copy Mineclonia from your machine into $PREFIX/luanti/games/mineclonia
  2. Copy the WDL archive to $PREFIX/2b2tmuseum-WDL
  3. Copy this kit to $KIT
  4. Then run:  $KIT/tools/prepare_world.sh
TXT
