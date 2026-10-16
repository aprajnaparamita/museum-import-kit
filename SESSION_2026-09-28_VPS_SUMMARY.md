# Session 2026-09-28: full 208-base import on the dedicated Linux VPS

The first full-manifest import run on the VPS. The Mac only ever verified the
4-base micro world; the 208-base run surfaced a set of VPS-specific problems
that are documented here. All fixes are UNCOMMITTED in the working tree.

Everything lives under `/srv/museum` except the kit, which is actually at
`/home/dara/museum-import-kit`. A symlink makes the documented paths work:

```
/srv/museum/museum-import-kit -> /home/dara/museum-import-kit
```

Confirmed on arrival: Luanti 5.17.0 server-only binary at
`/srv/museum/luanti/bin/luantiserver`, Mineclonia at
`/srv/museum/luanti/games/mineclonia`, archive at `/srv/museum/2b2tmuseum-WDL`.
The maparts were NOT on the box (see open items).

---

## Problems found and fixed (in the order they were hit)

### 1. Kit path mismatch
The repo is at `/home/dara/museum-import-kit`, not `/srv/museum/museum-import-kit`.
Created the symlink above. Every manifest/conf path now points at
`/srv/museum/museum-import-kit/...` as GUIDE-vps.md expects.

### 2. Missing Mineclonia `mcl_maps` headless patch
`setup_remote.sh` had not applied it (clean git tree). Without it, headless
map-frame loading piles up display entities (50 frames -> 50,050 objects).
Applied `import_tools/game_patches/mcl_maps-load_map-headless.patch`
(game-mod fix, no engine rebuild). It applied cleanly.

### 3. Missing Luanti engine patch (deliberately NOT applied)
`generate_decorations_with_inputs` is absent from the built binary (clean
tree, patch never applied). The importer degrades gracefully: `wgen_write.lua`
falls back to stock `core.generate_decorations(vm,p1,p2,false)`, which still
places decoration, just biome-unfiltered. Per "don't rebuild Luanti if it
works", I left the engine unpatched. If biome-exact decoration in the merge
ring is ever required, rebuild Luanti with
`import_tools/game_patches/luanti-5.17.0-museum-import.patch`.

### 4. `prepare_world.sh` wrote `mg_name = singlenode` and installed the wrong mods
- Mapgen was `singlenode` -> no terrain at all, every base would float in void.
  Now writes the verified v7 settings into `map_meta.txt` (before
  `[end_of_params]`): `mg_name = v7`, `mcl_singlenode_mapgen = false`,
  `seed = 16532709774040603227`, `water_level = 1`, `chunksize = 5`,
  `mgv7_spflags = mountains, ridges, nofloatlands, caverns`.
- It copied every mod in `mods/` including `fullimport` (the OLD batch driver),
  which would race `museumloot` (the current driver). Now installs exactly
  spawnimport, museumloot, museumwarp, museumportals.
- The manifest is now copied into the world only AFTER the throwaway first
  boot, so museumloot can't kick off the whole batch during that boot.
- Added `port = 30001` (FriedcakeSMP already owns UDP 30000).

### 5. `rewrite_manifest_paths.py` only rewrote WDL source paths
Extended it to also rewrite `footprint_path` from the Mac kit prefix
(`/Volumes/Dara/dev/museum-import-kit`) to the VPS kit path, and to verify
that every `source_region_dir` and `footprint_path` exists.

### 6. `world_template/world.mt` loaded `fullimport`
Changed to `load_mod_museumloot = true` and `load_mod_museumportals = true`
(removed `fullimport`).

### 7. Footprints were missing (gitignored) and Mac-pointed
Wrote `tools/regen_footprints_full.sh` and regenerated all 208 footprints into
`import_tools/placement_fit/footprints/` with `luajit source_footprint.lua`,
passing the `nether` flag only for the nether entry. (First version of the
script had a tab/field bug that appended " nether" to the Hausemaster
filename and dropped the flag; fixed, and Hausemaster regenerated correctly.)
Verified: 208/208 source dirs and footprints exist.

### 8. `supervise.sh` deadlocked on a fresh world
`placed()` returned -1 when `mod_storage.sqlite` did not exist yet, so it
looped forever and never started the server. Now returns 0 for a missing file
or missing `entries` table (fresh world = nothing placed), reserving -1 for
genuine read errors (volume problem).

### 9. OOM #1 — `wgen_blend3d.lua` never closed its VoxelManips
The nether/End 3-D blend's `place_chunk` and `audit` created VoxelManips and
never called `close()`. The overworld path (`wgen_write.lua`) closes its VMs;
the new blend code did not. Result: per-chunk C++ VManip buffers (tens of MB)
accumulated and the 7.8 GB box OOM-killed the server (rc=137) right after
`done. Placed`, before the registry save — so `supervise.sh` saw "no progress"
and every base re-placed. Fixed by closing `rvm`/`vm` in both functions.

### 10. OOM #2 — `get_data()`/`get_param2_data()` copy into fresh Lua tables
`VoxelManip:get_data()` copies the whole VM contents into a brand-new Lua
table (it does NOT return a view). `close()` frees only the C++ side. For the
3-D blend the read VM is large (chunk + mirror sources, up to ~128x288x128
nodes for the End), so each chunk allocated tens of MB of Lua tables. Endhaven
has 1365 merge chunks; even with `close()` the Lua heap high-water climbed to
~5.8 GB and the server was OOM-killed during the NEXT base's pregen.
Two-part fix in `wgen_blend3d.lua`:
- `place_chunk` now reuses four job-scoped buffer tables
  (`job._blend_rbuf/_p2buf/_dbuf/_p2dbuf`) passed to
  `get_data(buf)`/`get_param2_data(buf)`. A buffer grows once and is refilled
  in place; indices past the current volume are never read because the code
  indexes through the current `VoxelArea`.
- Both `place_chunk` and `audit` call `collectgarbage("collect")` per chunk to
  collect the small remaining per-chunk profile arrays.

### 11. Port collision with the existing FriedcakeSMP server
FriedcakeSMP (`/srv/museum/luanti/worlds/FriedcakeSMP`) holds UDP 30000. The
import server now uses `port = 30001`. That server is unrelated and was left
running untouched.

### 12. Mapart library path / missing art
`import_tools/mapart_gallery/build_library_index.py` hardcoded
`~/dev/museum-maparts/output`. Added `MAPART_OUTPUT_DIR` env override, and made
`load_final_manifest()` return `{}` when the art dir/manifest is absent (so
the unmirror pass still runs with no art). Gallery will be run with
`MAPART_OUTPUT_DIR=/srv/museum/museum-maparts/output` and a
`museum_manifest_path`-stripped conf.

---

## Verification so far (live run, `tail -f /tmp/fullimport.log`)

- No `[spawnimport] ... is not this world's band` errors.
- Hausemaster (nether): `nether band, dest_y_offset -29067`, 481 merge chunks,
  audit `3-D blend (nether) ... seam voxel mismatches 0 -- PASS`, registry
  saved (1/208).
- Endhaven (End): `end band, dest_y_offset -27059` (= -27073 + 14 lift),
  1365 merge chunks,
  `done. Placed 92355189 blocks across 26148 chunks (0 skipped)`,
  audit `3-D blend (end) ... seam voxel mismatches 0 -- PASS`, registry saved
  (2/208).
- `Space Valkyria III` is now pre-generating (the ~155k-chunk base).

## Known open items / notes

- **Maparts are not on the server.** Gallery fill will place 0 pieces until
  `/srv/museum/museum-maparts/output/final` is populated; the unmirror step
  still runs.
- **Engine patch absent** (see #3): merge rings get stock, biome-unfiltered
  decoration.
- **Timeline.** v7 mapgen runs single-threaded emerge (Luanti only enables
  multithreaded emerge for `singlenode` — open issue luanti#9357 "unfinished
  y-slices"). Measured ~250-300 mapblocks/s, ~56.7 M mapblocks total pregen +
  ~1.16 M chunks placement => roughly 3-4 days, not the 14-20 h estimate.
  Forcing `num_emerge_threads = 4` would ~4x pregen but risks missing
  caves/ores/biomes in generated slices; not done without explicit approval.
- Gallery will be run on an overworld-only manifest (End/Nether bboxes would
  otherwise force mapgen of billions of ungenerated overworld blocks).

## Remaining order (unchanged from the Mac path)

pass 1 (import + merge + loot, museumloot drives and shuts down) ->
pass 2 (verification) -> mapart gallery (fill + unmirror) ->
remove `worldmods/museumloot` -> verify and report the numbers.
