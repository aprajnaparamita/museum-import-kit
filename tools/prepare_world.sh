#!/bin/bash
# Creates the import world, installs the mods, rewrites manifest paths and
# writes the settings that matter. Run after setup_remote.sh, once
# Mineclonia + the WDL archive are in place.
set -euo pipefail

PREFIX="${PREFIX:-$HOME}"
KIT="${KIT:-$PREFIX/museum-import-kit}"
LUANTI="${LUANTI:-$PREFIX/luanti}"
WORLD="${WORLD:-$LUANTI/worlds/2b2t-museum}"
WDL="${WDL:-$PREFIX/2b2tmuseum-WDL}"
WDL_OLD_PREFIX="${WDL_OLD_PREFIX:-/Users/dara/dev/2b2tmuseum-WDL}"

[ -d "$LUANTI/games/mineclonia" ] || { echo "ERROR: Mineclonia not at $LUANTI/games/mineclonia"; exit 1; }
[ -d "$WDL" ] || { echo "ERROR: WDL archive not at $WDL"; exit 1; }
[ -x "$LUANTI/bin/luantiserver" ] || { echo "ERROR: no luantiserver built"; exit 1; }

echo "=== world + mods ==="
mkdir -p "$WORLD/worldmods"
cp -R "$KIT/mods/"* "$WORLD/worldmods/"
cp "$KIT/world_template/world.mt" "$WORLD/world.mt"

echo "=== manifest paths -> $WDL ==="
cp "$KIT/manifest/museum_manifest.json" "$WORLD/museum_manifest.json"
python3 "$KIT/tools/rewrite_manifest_paths.py" "$WORLD/museum_manifest.json" \
  "$WDL_OLD_PREFIX" "$WDL"

echo "=== import.conf ==="
cat > "$KIT/tools/import.conf" <<CONF
secure.enable_security = false
server_announce = false
max_users = 1
spawnimport_lua_import_path = $KIT/lua_import/
museum_manifest_path = $WORLD/museum_manifest.json
museum_target_bases = 205
CONF

echo "=== first boot, to generate map_meta.txt ==="
timeout 120 "$LUANTI/bin/luantiserver" --server --config "$KIT/tools/import.conf" \
  --world "$WORLD" --gameid mineclonia --logfile /tmp/firstboot.log </dev/null >/dev/null 2>&1 || true
[ -f "$WORLD/map_meta.txt" ] || { echo "ERROR: map_meta.txt was not created"; exit 1; }

echo "=== mapgen settings (must go BEFORE [end_of_params]) ==="
python3 - "$WORLD/map_meta.txt" <<'PY'
import sys
p = sys.argv[1]
lines = [l for l in open(p).read().split('\n')
         if not l.startswith(('mg_name', 'mcl_singlenode_mapgen'))]
want = ['mg_name = singlenode', 'mcl_singlenode_mapgen = false']
i = lines.index('[end_of_params]') if '[end_of_params]' in lines else len(lines)
for w in reversed(want):
    lines.insert(i, w)
open(p, 'w').write('\n'.join(lines))
print("  set:", ", ".join(want))
PY
grep -nE "^mg_name|^mcl_singlenode_mapgen|^mapgen_limit" "$WORLD/map_meta.txt"

# fresh world: drop anything the boot created so the import starts clean
rm -f "$WORLD/map.sqlite" "$WORLD/mod_storage.sqlite" "$WORLD/env_meta.txt"

echo
echo "Ready. Start the import with:"
echo "  screen -dmS import env LUANTI_BIN=$LUANTI/bin/luantiserver \\"
echo "    IMPORT_CONF=$KIT/tools/import.conf \\"
echo "    $KIT/tools/supervise.sh $WORLD /tmp/fullimport.log 205 300"
