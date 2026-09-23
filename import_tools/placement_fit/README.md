# Placement-fitting pipeline (round 25, 2026-09-20)

Owner's ask, paraphrased: the old biome-only placement search let
Tactical Nuke land somewhere that scored fine on biome-name overlap but
was secretly full of water above sea level intruding into the real
build -- nothing ever checked actual terrain. Build something more
robust, since there will be many more bases to check.

## Why two phases

Biome is a pure deterministic noise field, queryable standalone (no
engine, no world generation) via `mcl_levelgen`'s own
`level:index_biomes(x,y,z)` -- this is what the OLD
`tools/find_biome_placement.lua` already used, and it's very fast
(millions of samples/sec).

Real terrain **height** is NOT queryable this way. `ersatz_terrain:
get_one_height()` (mineclonia's own mapgen code, `mods/MAPGEN/
mcl_levelgen/ersatz.lua:560`) depends on `mcl_mapgen_models.
get_mapgen_model()`, which is only meaningfully initialized inside a
running engine -- confirmed this round by reading that code path, not
assumed. So any real height/water check needs an actual headless Luanti
server, which is slow (emerge_area on ungenerated terrain triggers real
mapgen, not just a disk read).

The pipeline therefore runs in two phases:

1. **Phase 1 (fast, standalone, `find_placement.lua`)**: the existing
   biome-histogram search, extended to keep the top-K candidates (not
   just the single best) and to skip any candidate overlapping an
   already-placed base (via `placement_registry.json`, see below).
2. **Phase 2 (slow, headless engine, `dest_eval_worldmod/`)**: for just
   those K candidates, checks REAL destination terrain: an exhaustive
   count of water nodes strictly above the map's established sea level
   (`water_level` in `map_meta.txt`) within each candidate's full
   footprint. This is the validated signature of the actual bug class --
   it's literally the metric that found and explained Tactical Nuke's
   real water-intrusion bug this round (see HANDOFF.md's round 25/25c
   writeups). A secondary, cheaper "real-chunk land/water match" check
   (sampling the base's own real captured chunk centers) is also
   reported for context, but is NOT the primary gate -- validated this
   round to be a weaker/misleading signal on its own (Tactical Nuke's
   CURRENT bad placement actually scores 96%+ on this metric, because
   the base itself is 64% water and lands somewhere naturally watery
   too -- the bug is specifically in the *gap* chunks that have no real
   captured data at all, which this metric doesn't see).

## Why NOT footprint-density scoping

An earlier attempt this round tried to scope water cleanup to areas
"near" the base's real content (grid the bbox, only touch water in
dense cells). This failed for Tactical Nuke: its real content is spread
across ~26% of the bounding rectangle in an interleaved,
archipelago-style pattern, not one compact landmass -- even a 1-cell
buffer around "dense" cells covered 93% of the whole area. Height
(above/below the map's real sea level) turned out to be the actually
discriminating signal, not spatial proximity to real content.

## Files

- `source_footprint.lua` -- standalone (luajit), reads a base's real
  source region files via `lua_import/anvil.lua` (same decoder
  spawnimport itself uses -- do not reinvent chunk decoding) and
  produces a per-chunk real footprint: which chunks actually have saved
  data (not a bounding rectangle -- `chunk_bounds` in
  `museum_manifest.json` has ALWAYS just been a rectangle, never a real
  per-chunk mask, confirmed this round), plus each chunk's surface
  height and land/water classification (from the chunk's own decoded
  block data, checking the raw Minecraft block name `minecraft:water`
  directly -- 1.18+ format only, same limitation the main import
  pipeline already has for pre-1.18 source data).
  Usage: `luajit source_footprint.lua <source_region_dir> <output_json>`

- `find_placement.lua` -- standalone (luajit, must run from inside
  `~/dev/mineclonia/mods/MAPGEN/mcl_levelgen`, same constraint as the
  old `tools/find_biome_placement.lua`). Phase 1: biome search, top-K
  candidates, registry-aware overlap skip. Writes
  `/tmp/dest_eval_params.json` for phase 2.
  Usage: `luajit find_placement.lua "<base display name>" <footprint_json>`
  (origin_x/z looked up from `museum-playtest/museum_manifest.json` if
  the base already has an entry there; pass as extra args otherwise.)

- `dest_eval_worldmod/` -- headless worldmod, phase 2. Install into a
  world's `worldmods/`, launch the testrig
  (`~/dev/museum-testrig/bin/luanti --server --config ~/dev/
  museum-testrig/conf/playtest.conf --world <world> --gameid mineclonia`),
  reads `/tmp/dest_eval_params.json`, writes `/tmp/dest_eval_result.json`.
  Processes ALL candidates in one sequential run before calling
  `request_shutdown` once at the end -- **never** combine this with any
  other `request_shutdown`-calling worldmod in the same launch (that
  caused a real race-condition bug this round, see HANDOFF.md's round
  25b writeup: whichever finishes first kills the whole process).
  Remove from `worldmods/` after each run -- it's a debug/survey tool,
  not part of the deployed world's real content.

- `pick_best.py` -- combines phase 1 + phase 2 output into a ranked,
  human-readable report. Report only -- does not write to
  `placement_registry.json` or `museum_manifest.json`. Placing a base
  at a recommended spot is a separate, explicit step.

- `placement_registry.json` -- persistent record of every base's real
  `dest_bbox` in the shared world, checked by `find_placement.lua` on
  every future run to prevent overlap ACROSS separate runs (fixes a
  real documented incident: `tools/apply_biome_placement.py`'s own
  header comment describes an early run silently overwriting Fort
  Alcazar's and cutecurly's City's already-planned positions, because
  the old search's overlap tracking only knew about bases passed into
  that one invocation). Seeded from the 3 currently-deployed bases.
  **Any future placement must append its own entry here before
  finishing** -- not done automatically yet, do it by hand until this
  gets wired into an apply step.

## Validated this round (demonstration run, not applied)

Ran the full pipeline against Tactical Nuke's real source data as a
test case (already have validated source data for it; this does NOT
mean Tactical Nuke is being moved -- see HANDOFF.md, this was scoped as
"future bases only" per explicit owner decision).

- Source footprint: 1,403 real chunks found (out of a 6,144-chunk
  bounding rectangle -- only 23% actually has real data), 900 water /
  503 land.
- Validated the primary signal against Tactical Nuke's KNOWN bad
  current placement: 18,219 above-sea-level water nodes there (this is
  literally the count that was found and fixed live this round -- see
  HANDOFF.md's round 25d writeup).
- Phase 1 found 8 biome-matched, non-overlapping candidates (scores
  0.331-0.394, similar range to the current placement's own score,
  confirming this base's water-heavy real content limits how well ANY
  destination can match on biome alone).
- Phase 2 found EVERY one of those 8 candidates has substantially less
  above-sea-level water than the current placement (856-6,282 nodes vs.
  18,219) -- confirming the tool can reliably find meaningfully better
  spots than the old biome-only search did.
- Best candidate found: anchor (-2000, 6500), 856 above-sea-level water
  nodes (95% less than current), biome score 0.352.

## Known gaps / not done this round

- `import_tools/biome_survey.py` (generates a NEW base's biome
  histogram for `tools/source_biomes.lua`) is missing from this
  checkout -- referenced by `tools/find_biome_placement.lua`'s own
  header comment but not found anywhere in the repo. The 3 existing
  bases' histograms already exist in `source_biomes.lua`, so this only
  blocks running phase 1 for a genuinely NEW (never-profiled) base.
  Would need to be rewritten from scratch (parse Minecraft's per-chunk
  `Biomes` NBT array, not yet handled by `anvil.lua` at all) -- out of
  scope for this round's water-intrusion fix, flagged for whoever adds
  the next new base.
- No automated "apply" step yet (updating `museum_manifest.json` +
  `placement_registry.json` + actually running the import for a
  freshly-recommended spot) -- `pick_best.py` deliberately stops at a
  human-reviewable report.
- Phase 2's per-candidate cost is dominated by real mapgen for
  previously-ungenerated territory (slow, not a data-load). Kept K
  small (8) for this reason -- raising it trades search breadth for a
  proportionally longer phase 2 run.
