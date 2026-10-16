#!/bin/bash
# Creates the import world, installs the mods, rewrites manifest paths and
# writes the settings that matter. Run AFTER setup_remote.sh, as the
# regular user (no sudo) -- everything under MUSEUM_ROOT is already yours.
set -euo pipefail

MUSEUM_ROOT="${MUSEUM_ROOT:-/srv/museum}"
KIT="${KIT:-$MUSEUM_ROOT/museum-import-kit}"
LUANTI="${LUANTI:-$MUSEUM_ROOT/luanti}"
WORLD="${WORLD:-$LUANTI/worlds/2b2t-museum}"
WDL="${WDL:-$MUSEUM_ROOT/2b2tmuseum-WDL}"
# The manifest JSONs store source paths from the Mac rig; rewrite them to
# wherever the archive lives here. footprint_path also still points at the
# Mac kit, so rewrite that too.
WDL_OLD_PREFIX="${WDL_OLD_PREFIX:-/Users/dara/dev/2b2tmuseum-WDL}"
FP_OLD_PREFIX="${FP_OLD_PREFIX:-/Volumes/Dara/dev/museum-import-kit}"
MANIFEST="${MANIFEST:-museum_manifest_full.json}"
TARGET="${TARGET:-208}"
# The headless import still binds a UDP socket; pick a port that won't
# collide with any other Luanti server on the box (e.g. FriedcakeSMP on
# 30000).
PORT="${PORT:-30001}"

[ -d "$LUANTI/games/mineclonia" ] || { echo "ERROR: Mineclonia not at $LUANTI/games/mineclonia"; exit 1; }
[ -d "$WDL" ] || { echo "ERROR: WDL archive not at $WDL"; exit 1; }
[ -x "$LUANTI/bin/luantiserver" ] || { echo "ERROR: no luantiserver built"; exit 1; }
[ -f "$KIT/manifest/$MANIFEST" ] || { echo "ERROR: manifest $KIT/manifest/$MANIFEST missing"; exit 1; }

echo "=== world + mods ==="
mkdir -p "$WORLD/worldmods"
# Exactly the four mods the verified rebuild installs. fullimport is the
# OLD batch driver and would race museumloot (which now starts the batch).
rm -rf "$WORLD/worldmods/fullimport"
for mod in spawnimport museumloot museumwarp museumportals; do
    rm -rf "$WORLD/worldmods/$mod"
    cp -R "$KIT/mods/$mod" "$WORLD/worldmods/"
done
cp "$KIT/world_template/world.mt" "$WORLD/world.mt"

echo "=== import.conf ==="
cat > "$KIT/tools/import.conf" <<CONF
fixed_map_seed = 16532709774040603227
port = $PORT
# 7.8 GB RAM / no swap: unload unused mapblocks aggressively so the
# per-base pregen+placement cache doesn't get OOM-killed (rc=137 seen
# on the first base at the default 29s).
server_unload_unused_data_timeout = 5
emergequeue_limit_total = 256
secure.enable_security = false
server_announce = false
max_users = 1
max_objects_per_block = 50000
mcl_disabled_structures = large_dripstone_column,large_dripstone_stalagmite,large_dripstone_stalagtite,basalt_column,basalt_pillar,small_end_city,end_shipwreck,end_boat
spawnimport_lua_import_path = $KIT/lua_import/
museum_manifest_path = $WORLD/museum_manifest.json
museum_target_bases = $TARGET
CONF

# First boot, to generate map_meta.txt. The manifest is intentionally NOT
# copied into the world yet: museumloot would otherwise kick off the whole
# batch during this throwaway boot. It just logs a "could not open
# manifest" error and idles, which is what we want here.
echo "=== first boot, to generate map_meta.txt ==="
timeout 120 "$LUANTI/bin/luantiserver" --config "$KIT/tools/import.conf" \
  --world "$WORLD" --gameid mineclonia --logfile /tmp/firstboot.log </dev/null >/dev/null 2>&1 || true
[ -f "$WORLD/map_meta.txt" ] || { echo "ERROR: map_meta.txt was not created"; exit 1; }

echo "=== mapgen settings (must go BEFORE [end_of_params]) ==="
python3 - "$WORLD/map_meta.txt" <<'PY'
import sys
p = sys.argv[1]
want = {
    # Verified museum worlds (see SESSION_2026-09-27_SUMMARY.md): v7 with
    # Mineclonia's own levelgen OFF. singlenode generates no terrain, so
    # every base would float in void with nothing to merge into.
    'mg_name': 'v7',
    'mcl_singlenode_mapgen': 'false',
    'seed': '16532709774040603227',
    'water_level': '1',
    'chunksize': '5',
    'mgv7_spflags': 'mountains, ridges, nofloatlands, caverns',
}
lines = [l for l in open(p).read().split('\n')
         if not any(l.startswith(k + ' ') or l.startswith(k + '=')
                    or l.startswith(k + ' =') for k in want)]
i = lines.index('[end_of_params]') if '[end_of_params]' in lines else len(lines)
for k, v in reversed(list(want.items())):
    lines.insert(i, f'{k} = {v}')
open(p, 'w').write('\n'.join(lines))
print("  set: " + ", ".join(f"{k}={v}" for k, v in want.items()))
PY
grep -nE "^mg_name|^mcl_singlenode_mapgen|^seed|^water_level|^chunksize|^mgv7_spflags|^mapgen_limit" "$WORLD/map_meta.txt"

# Now that map_meta.txt exists, copy the manifest in and rewrite its paths.
echo "=== manifest ($MANIFEST, $TARGET bases) paths -> $WDL / $MUSEUM_ROOT/museum-import-kit ==="
cp "$KIT/manifest/$MANIFEST" "$WORLD/museum_manifest.json"
python3 "$KIT/tools/rewrite_manifest_paths.py" "$WORLD/museum_manifest.json" \
  "$WDL_OLD_PREFIX" "$WDL" \
  "$FP_OLD_PREFIX" "$MUSEUM_ROOT/museum-import-kit"

# fresh world: drop anything the boot created so the import starts clean
rm -f "$WORLD/map.sqlite" "$WORLD/mod_storage.sqlite" "$WORLD/env_meta.txt" "$WORLD/force_loaded.txt"
rm -rf "$WORLD/mcl_maps" "$WORLD/mod_storage" "$WORLD/mapart_unmirrored.txt" "$WORLD/museum_gateways.json"

echo
echo "Ready. Start the import with:"
echo "  screen -dmS import env LUANTI_BIN=$LUANTI/bin/luantiserver \\"
echo "    IMPORT_CONF=$KIT/tools/import.conf \\"
echo "    $KIT/tools/supervise.sh $WORLD /tmp/fullimport.log $TARGET 300"
