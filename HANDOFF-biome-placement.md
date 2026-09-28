# Handoff: biome-matched base placement (2026-09-28)

This is the task for the next agent. The owner will have the author of this
document check the work afterwards, so keep notes of what you did and why.

Read before starting:

1. This file, top to bottom.
2. `SESSION_2026-09-27_SUMMARY.md` (current state of the merge work).
3. `HANDOFF.md`, top section only.
4. Memory rules that apply: never guess Mineclonia node, item or biome
   names (grep `~/dev/mineclonia/mods`). Verify in a real world, not only
   by reading code.

## The problem

Each base's placement ignores biome. The full layout
(`manifest/museum_manifest_full.json`, 208 bases) was packed by size only.
The owner walked the 20-base test world and reported:

- **Mesa Mountain HQ** (a badlands/mesa capture) sits in a rainy temperate
  biome. It rains on the mesa, and the merge has to blend badlands into
  grassland.
- **IronWeasel's underwater base** (99% water chunks) is not in an ocean
  biome.
- **Gomorrah** (footprint biome `minecraft:desert`) is not in a desert.

The goal: every overworld base is placed where the world's own biomes
match the capture's biomes as closely as possible, with no overlaps.

## Key facts (verified 2026-09-28)

- **The worlds use `mg_name = v7`** with Mineclonia's v7 biomes
  (`mcl_singlenode_mapgen = false`, seed `16532709774040603227`). See
  `map_meta.txt` in `~/dev/museum-microtest`.
- **The old biome search is wrong for these worlds.**
  `import_tools/placement_fit/find_placement.lua` and
  `tools/find_biome_placement.lua` read biomes from Mineclonia's *levelgen*
  preset (`mcl_levelgen.make_overworld_preset`). That is a different
  generator from v7, so their biome map does not match the world. Don't
  reuse their results. Parts of their code (histogram scoring, candidate
  ranking, `placement_registry.json`) may still be useful.
- **The v7 biome at a position is queryable without generating terrain:**
  `core.get_biome_data(pos)` → `{biome, heat, humidity}` (Luanti
  `doc/lua_api.md` ~line 7075), then `core.get_biome_name(id)`. It needs a
  running server (headless is fine). The probe-world pattern in
  `SESSION_2026-09-27_SUMMARY.md` ("Probe method") shows how to run a
  throwaway worldmod against a copy of a world.
- **What each base has:** its footprint JSON
  (`import_tools/placement_fit/footprints/*.json`, path in each manifest
  entry's `footprint_path`) lists every captured chunk with a Minecraft
  `biome` name, `is_water` and heights. That's the capture's biome
  histogram.
- **Minecraft → Mineclonia biome names:**
  `mods/spawnimport/wdl_climate.lua` `climate.MC_TO_MCL` (the merge
  already uses it). Mineclonia registers biome variants such as
  `_ocean`, `_beach`, `_shore`. Compare biome families, not exact names:
  e.g. any `Desert*`, any `Mesa*`, any `*_ocean` / `*_deep_ocean`.
- **Water matters more than the biome name.** A mostly-water capture must
  go where v7 has ocean at sea level (`water_level = 1`). Checking sea
  level needs real terrain height, which `get_biome_data` doesn't give.
  The Phase 2 idea in `import_tools/placement_fit/README.md` (count water
  or land in the generated destination) is the right check. v7 height can
  be sampled roughly with `core.get_spawn_level(x, z)`, but it returns nil
  for anything outside `water_level`..`water_level + 16` and near rivers,
  so nil does not mean water. For a real land/water answer, emerge a
  sparse grid and read the surface.

## What to build

1. **Placement tool** (new, e.g. `tools/place_by_biome.py` plus a
   worldmod):
   - for each overworld base, read its footprint's biome and water
     histogram;
   - sample candidate anchors on a coarse grid (the v7 world is large;
     keep bases within the current layout's general area unless there's a
     reason to go wider);
   - score each candidate by biome-family match and land/water match over
     the base's chunk footprint (not just its centre);
   - place bases largest first, reject overlaps with already-placed bases
     (same rule as `build_full_manifest.py`'s overlap check, plus the
     merge margin: `(gap_fill.RING + gap_fill.MAX_EXTRA_RINGS) * 16` =
     128 blocks around each bbox);
   - write `dest_anchor_x/z` and `dest_bbox` back into a manifest.
2. **Apply it** to `manifest/museum_manifest_sample20.json` first (15
   overworld bases), then to `manifest/museum_manifest_full.json`
   (205 overworld). Don't move nether or End entries: their positions
   are chosen for other reasons (End gateway slots; see
   `build_full_manifest.assign_end_gateway_slots`).
3. **Keep these working:**
   - `tools/build_full_manifest.py` (band offset guard, End gateway slots,
     overlap check) must still pass on the new layout;
   - `warp_source` entries (e.g. Ravenholm) are in download coordinates
     and survive moves; don't convert them.

## How to verify

1. `python3 tools/build_full_manifest.py …` guards pass; no overlaps.
2. A 20-base rebuild in staging only:
   `MICRO_MANIFEST=manifest/museum_manifest_sample20.json GALLERY_RUN_TIMEOUT=7200 ./import_tools/micro_rebuild.sh --no-deploy`
   (~3–4 h, refuses to start while any luanti process runs). **Don't
   deploy** to `2b2t Museum TEST`; the owner deploys after review.
3. Probe (throwaway worldmod on a copy of `~/dev/museum-microtest`) the
   biome under each overworld base and in its merge ring, and report a
   table: base, capture's main biome family, destination biome family
   before and after, water share before and after. Mesa Mountain HQ,
   IronWeasel's and Gomorrah must match.
4. Check the build log: 20 "done. Placed", 0 skipped chunks, every
   `[gap-fill] audit` line with seam mismatches 0, no ServerError.
5. Run the tests: `cd mods/spawnimport && luajit test_harness.lua`
   (~15 min) and `luajit gap_field_test.lua`. Both must pass.

## Rules

- Commit on a branch and fast-forward `main` only when checks pass. Don't
  push (the owner pushes). End commit messages with the attribution line
  used in `git log`.
- Don't touch `~/Library/Application Support/minetest/worlds/2b2t Museum TEST`
  (the owner's live world) or `~/dev/museum-microtest` while another build
  is running (`pgrep -fl luanti`).
- Footprints are gitignored (1–170 MB each). Regenerate a missing one with
  `luajit import_tools/placement_fit/source_footprint.lua <region_dir> <out.json> [nether]`.
- Keep changes scoped to placement. If you find a merge or import bug,
  write it down in your report instead of fixing it.

## Smaller open items (only if time allows; report, don't guess)

- **Mob heads** probably have the same 180° error that standing signs had
  (`lua_import/palette.lua` uses `rotation * 15` for heads; signs were
  fixed to `(rotation * 15 + 120) % 240`). Verify against a real head in
  a capture before changing it.
- **Corner stairs** (`inner_left/right`, `outer_left/right`) may be
  mirrored like the door hinges were (imports are north-south mirror
  images; see memory note "imported bases are Z-mirrored"). Needs an
  in-game check.
- **Water elevators**: Mineclonia has no bubble columns, so captured
  sign-and-water elevators don't lift. The owner hasn't asked for a fix
  yet.
