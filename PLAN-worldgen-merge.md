# PLAN — worldgen merge: patch gap chunks *before* trees, plants and structures

Status: **plan only — nothing implemented yet.**
Owner direction (2026-09-24): abandon the "merge chunk" post-processing
method (`FEATURE-gap-fill-blend.md`) — it produces smeared trees, huge
cliff faces, kelp on mountainsides and still leaves very large square-
edged cliffs. Instead generate gap chunks through the **natural Mineclonia
world generation**, patched to meet the world-download edges exactly,
*before* trees/plants/structures are added. Two chunks of blending on
each edge rather than one. The merge is import-time only; afterwards
normal Mineclonia generation continues unaided.

This document is based on a direct reading of the Luanti 5.17.0 engine
mapgen code (`~/dev/luanti/src/mapgen`, `src/emerge.cpp`,
`src/script/lua_api/l_mapgen.cpp`) and Mineclonia's mapgen mods
(`~/dev/mineclonia/mods/MAPGEN/*`) — file:line references below so the
findings can be re-checked without relearning them.

---

## 1. Why the current method can only go so far

The merge-chunk write path (`mods/spawnimport/gap_fill.lua`
`place_gap_chunk`) runs **after everything else**: it shifts the natural
surface skin plus whatever vegetation sits on it, per column. Therefore:

| symptom | root cause |
|---|---|
| smeared trees | a canopy spans columns that get shifted by different Δy — the tree is sheared block-column by block-column |
| kelp on mountainsides | sea-floor skins (with `mcl_ocean:kelp_*`, seagrass) get carried up when a water column is raised to land |
| huge cliff faces, square edges | the height field is solved over a 1-chunk ring; where the seam relief exceeds the ramp budget the leftover Δ becomes tall axis-aligned terraces; widening stops at hard domain boundaries (plateau edges) |
| surface material only tint-matched | the shifted skin keeps whatever material the *natural* biome had |

All four are structural: while trees/plants are written *before* the
terrain is moved, they can only be patched, never placed correctly. The
fix is to finish the terrain first and let Mineclonia's own decoration
rules grow the vegetation on it.

---

## 2. How natural chunk generation actually works (engine findings)

### 2.1 Generation pipeline

`MapgenV7::makeChunk` (`src/mapgen/mapgen_v7.cpp:299`; v5/valleys/
carpathian are identical in structure):

1. `generateTerrain()` — stone/air/water skeleton from v7 noise
2. `updateHeightmap()` — per column `heightmap[i] = findGroundLevel()` =
   **y of the topmost walkable node** (`src/mapgen/mapgen.cpp`,
   `Mapgen::updateHeightmap`)
3. `generateBiomes()` — top/filler/water-top/riverbed per column from the
   biome picked for the column (`MapgenBasic::generateBiomes`,
   `src/mapgen/mapgen.cpp:623`); fills `biomemap[]`
4. caves / caverns / randomwalk caves
5. `placeAllOres()`
6. `generateDungeons()`
7. **`placeAllDecos()` — trees, plants, grass, flowers, kelp, cactus…**
   (`src/mapgen/mg_decoration.cpp`)
8. `dustTopNodes()` — snow dusting
9. `updateLiquid()` + `calcLighting()`

Lua callback order around this (`src/emerge.cpp` `EmergeThread::run`,
`finishGen`):

```
makeChunk()                                <- C++: everything above
mapgen-env on_generated (register_mapgen_script / core.vmanip)
finishBlockMake()  (blitBackAll -> map)
server-env on_generated
   = mcl_mapgen_core generators:
     world_structure (bedrock/lava/void layers, priority 1)
     mcl_structures  (villages, huts, pyramids…, priority 100)
     end_fixes / set_param2_nodes (biome-colour param2, priority 9999)
```

So in Mineclonia's v7 path (the playtest world: `mg_name = v7`, see
`mods/spawnimport/init.lua` round-28 correction) **trees and plants are
placed by the engine inside makeChunk, before any Lua can run** — but
structures are placed by Lua *afterwards*. "Patch in before trees,
structures and plants" therefore means: run the terrain patch between
steps 3–7 and re-invoke step 7 on the patched terrain (below).

### 2.2 What the decoration placer consumes — "the inputs"

`Decoration::placeDeco` (`src/mapgen/mg_decoration.cpp:125`) decides
placement per column from exactly two mapgen objects plus its own rules:

- **height** — `mg->heightmap[mapindex]` (the topmost walkable node),
  or `mg->findGroundLevel()` (a scan of the VoxelManip) when no
  heightmap is attached, or `findLiquidSurface()` for `DECO_LIQUID_SURFACE`
  decorations (kelp/seagrass/lilies). `DECO_ALL_FLOORS` decorations scan
  all floors in the column (`getSurfaces`).
- **biome** — `mg->biomemap[mapindex]`, checked against the
  decoration's `biomes` set. If `biomemap` is absent the check is
  skipped entirely (every biome's decorations become eligible).

Then the usual rules apply: `place_on`, `spawn_by`, `y_min/y_max`,
`fill_ratio`/noise density per `sidelen`² cell, seeded from
`Mapgen::getBlockSeed`. Mineclonia specifics (`mods/MAPGEN/mcl_biomes/
init.lua`): most decorations use `sidelen = 16`; grass/fern/litter and
friends carry `param2 = <biome's _mcl_palette_index>` (grass tint comes
for free from correctly-biomed placement); kelp/seagrass are registered
on `mcl_ocean:kelp_sand/kelp_dirt/kelp_gravel` with liquid-surface rules
(so they physically cannot sit on a mountainside if placed *after* the
terrain is final).

**Conclusion:** if we hand the natural decoration pass (a) our merged
heights and (b) our world-download-derived biome ids, the engine will
place Mineclonia's own trees/plants/kelp exactly where they belong —
whole trees, right species, right tints, nothing floating. That is the
"correct inputs to hook into the natural luanti world gen".

### 2.3 The one gap in the Lua API (why a tiny engine shim is proposed)

`core.generate_decorations(vm, p1, p2, use_mapgen_biomes)`
(`src/script/lua_api/l_mapgen.cpp:1607`) offers two modes and neither
accepts caller-supplied inputs:

- `use_mapgen_biomes = false`: runs against a throwaway `Mapgen` with
  **no** heightmap/biomemap → placement heights are re-scanned from the
  vm (fresh, correct after our sculpt) but the **biome filter is
  disabled** (all biomes' trees compete on every grass column, combined
  density blowup).
- `use_mapgen_biomes = true`: uses the live mapgen's heightmap/biomemap
  — but (a) only inside mapgen context and with mapchunk extents, (b)
  the heightmap is the *pre-sculpt* natural surface (stale), and (c) the
  biomemap is the *natural* biome, not the world-download biome.

Also checked and rejected: swapping the decoration registry at runtime
to filter by biome — `EmergeParams` **clones** the DecorationManager per
mapgen at startup (`src/emerge.cpp:42-52`), so mapgen-time placements
are unaffected; and decoration ObjDef ids would be renumbered, breaking
`mcl_structures`' `core.get_decoration_id` triggers
(`mods/MAPGEN/mcl_structures/api.lua:290`). (Runtime registry swaps *do*
reach the out-of-context bare path — usable as a fallback, see
§5 backend B.)

Proposed shim (≈40 lines in `l_generate_decorations`): optional 4th/5th
arguments `heightmap`, `biomemap` (flat index tables, mapindex =
`carea_size*(z−minp.z) + (x−minp.x)`, heightmap semantics "y of topmost
walkable node", sentinel `32767` = skip column) used to populate the
throwaway `Mapgen`. Fully backwards compatible. The kit already builds
the engine (`tools/setup_remote.sh`, `~/dev/luanti/build-5.17.0`), so
shipping a patch is routine. Without the shim we degrade to §5
backend B (pure Lua, slightly coarser biome gating).

### 2.4 Constraints from hard-won facts (HANDOVER.md)

- Mapgen's unit is the mapchunk (80³) and re-running mapgen over a
  mapchunk destroys captured content — **gap columns that share a
  mapchunk with captured columns can never be generated by mapgen
  itself**; their merge must remain a post-generation VoxelManip write.
  The win is not *where* the merge runs but *when the vegetation is
  added*: after the write, via the natural decoration pass.
- Pre-generation stays mandatory (VoxelManip writes don't set the
  generated flag); `mapgen_limit` stays 31007.
- Water level = `core.get_mapgen_setting("water_level")` (dest space,
  = 1), never the levelgen preset's `sea_level`.
- `dest_y_offset = −61` for overworld bases (unchanged).

---

## 3. Design — "worldgen merge"

Per base, for every gap column within a **two-chunk ring** of a captured
column (plus today's bounded widening), during the import run only:

### 3.1 Inputs from the world download (new)

1. **Per-column biome field.** `lua_import/anvil.lua:278`
   (`anvil.decode_section_biomes`) already decodes the 1.18+ `biomes`
   palette + packed 4×4×4 cells. Extend
   `import_tools/placement_fit/source_footprint.lua` to emit, per
   captured chunk, a 16×16 `biome_cols[]` grid — the surface-cell biome
   of each column (sampled at `terrain_cols` y) — instead of only the
   current single `biomes.palette[1]`.
2. **Temperature map.** For each column derive the Minecraft climate:
   biome `temperature`/`downfall` from a small MC biome table (values
   match `mineclonia/mods/MAPGEN/mcl_levelgen/biomes.lua`, kept as
   reference data), with MC's altitude adjustment
   (`temp − max(0, y_surface − 64)·0.05`) for snow decisions. Emit
   `temp_cols[]` alongside `biome_cols[]`. (Ground truth cross-check:
   snow/ice blocks present in the capture.)
3. **Gap-column extrapolation.** Gap columns have no capture data;
   extrapolate outward from the captured border: each gap column takes a
   distance-weighted blend of (temperature, downfall) of the nearest
   captured border columns, converted to Mineclonia biomes the same way
   the engine does it — nearest `heat_point`/`humidity_point`
   (`core.registered_biomes`, `mcl_biomes/init.lua`) — so the ring's
   biome distribution is a natural continuation of the capture's.
4. **MC→Mineclonia mapping** reuses `MC_TO_MCL_BIOME`
   (`gap_fill.lua:62`) but resolves to full biome defs (top/filler
   nodes+depths, `_mcl_palette_index`, `dust_node`) instead of palette
   index only.

### 3.2 Height field — two-chunk ring (the owner's "two chunks on an edge")

Reuse `mods/spawnimport/gap_field.lua` unchanged (pure solver:
`field.solve(free, fixed, opts)`, `field.violations`, `field.frontier`).
New pin layout over a domain = every gap chunk within **2** chunks
(Chebyshev) of a captured chunk, plus widening as today:

- **Seam pins (exact):** gap columns edge-adjacent to captured chunks are
  pinned to that chunk's `terrain_cols` ground — seam = zero step
  (unchanged behaviour, still smoothed per 16-column seam line).
- **Outer pins (exact):** the domain boundary facing untouched terrain is
  pinned to the untouched natural surface — the merge is a zero-step
  continuation into real Mineclonia chunks ("edges match perfectly" on
  *both* sides). These columns are guards: computed, never written.
- **Interior:** 2×16 = 32 columns of ramp per side instead of 16 —
  `spawnimport_gap_max_step` (1 block/column) now absorbs ±32 blocks of
  seam relief walkably; beyond that the existing terracing + bounded
  widening applies, but over double the run, which removes the tall
  square-edged leftovers almost everywhere.
- Water columns remain slope-unconstrained (sea cliffs stay cliffs).

Widening budget (`MAX_EXTRA_RINGS = 3`) and "stop when it stops helping"
stay; pregen margin becomes `(2 + MAX_EXTRA_RINGS) * 16`.

### 3.3 The write — terrain first, nothing organic carried

Replace `gap_fill.place_gap_chunk`'s "shift skin + vegetation" with a
**column rebuild** per merged column (still a VoxelManip pass in the
server env, same step-budgeted cursor flow):

1. Keep the natural underground (caves/ores untouched below the rebuilt
   zone; the rebuilt zone is top+filler depths + the Δ-shift margin).
2. Build the surface from the **target biome's** rules
   (`core.registered_biomes[name]`): `node_top`/`depth_top`,
   `node_filler`/`depth_filler`, `node_dust` (snow) — this replaces the
   "material not matched" limitation; at seam columns prefer the
   *neighbouring captured column's* top/filler node names so exposed
   seam cliff faces continue the capture's geology.
3. Water columns: floor at merged height, `mapgen_water_source` to
   `water_level`, air above. Land columns: air above the surface. **All
   organic material (leaves/logs/plants/vine/kelp/snow) in the column is
   removed** — it will be regrown naturally in step 3.4. Nothing is ever
   shifted, so nothing smears and nothing floats.
4. `set_lighting{day=0,night=0}` + `calc_lighting` + `write_to_map` +
   `update_liquids` (as today).
5. Param2 tint: surface `biomecolor` nodes get the target biome's
   `_mcl_palette_index` (existing `biome_palette` logic, kept).

### 3.4 The vegetation pass — natural decorations on finished terrain

Per merged **mapchunk-sized area (80×80 XZ, square as `placeDeco`
requires)** after the writes — one call, natural density semantics:

```lua
core.generate_decorations(vm, p1, p2, false,
    { heightmap = H, biomemap = B })   -- engine shim (§2.3)
```

- `H[i]` = merged surface y (topmost walkable node — same semantics the
  engine uses), or the **skip sentinel** (above `p2.y`) for columns that
  must not be decorated: captured columns (never grow trees on a base!),
  columns with structures left in place, columns outside the plan.
- `B[i]` = target Mineclonia biome id (`core.get_biome_id`) from §3.1 —
  per column, so a coastline column set gets kelp/seagrass and a land
  column next to it gets grass and the right tree species.
- Kelp/seagrass/water-lilies place through their natural
  `DECO_LIQUID_SURFACE`/floor rules against the *final* water column —
  the kelp-on-mountainsides class of bug becomes structurally impossible.
- Grass/fern/litter arrive with the correct grass palette param2
  straight from the decoration defs.
- Because unmoved-but-cleared columns are regrown from the same rules,
  tree density across the ring is statistically identical to untouched
  terrain.

Fallback backends when the engine shim is not available — §5.

### 3.5 Structures and later passes

- **mcl_structures** (server-env generator) already runs at mapgen time,
  i.e. before our write. Policy: structures whose footprints intersect a
  merged column are **cleared** together with organic clutter (matches
  today's behaviour; a half-shifted village is worse than none). The
  merge plan records them via `mcl_structures` placement/`gennotify`
  data so untouched structure columns can be sentinel-masked instead
  when the owner prefers to keep them.
- `set_param2_nodes` (mcl_mapgen_core) ran at mapgen time on the natural
  biomemap — before our write; our own tint (§3.3.5) is therefore the
  final word. No ordering conflict.
- Bedrock/lava/void layers (`world_structure`) are below the merge zone;
  unchanged.

### 3.6 Lifecycle — enabled only during import

- The subsystem lives in `mods/spawnimport` (new files, §4) and is
  driven by the existing job/registry/cursor machinery. It only ever
  plans/writes chunks listed in a base's gap plan.
- A single switch (`spawnimport_worldgen_merge` setting, default off)
  gates it; remove the setting / the mod after the 205-base import and
  the world generates normally (chunks beyond the imported area were
  never touched: outer pins guarantee continuity with plain Mineclonia
  generation).
- `spawnimport_gap_only` (fast iteration) and `/worldplace gapaudit`
  keep working, extended (§6).

---

## 4. Module layout (what gets written)

| file | action |
|---|---|
| `import_tools/placement_fit/source_footprint.lua` | extend: per-column `biome_cols[256]`, `temp_cols[256]` per chunk (from `decode_section_biomes` + MC climate table) |
| `mods/spawnimport/wdl_climate.lua` (new) | MC biome → (temperature, downfall) table; height-adjusted temperature; MC→Mineclonia biome resolution via heat/humidity nearest-match |
| `mods/spawnimport/wgen_inputs.lua` (new) | gap-column biome/temperature extrapolation from captured border; per-chunk target biome ids + palette indexes; seam-face material lookup |
| `mods/spawnimport/gap_field.lua` | unchanged (solver) |
| `mods/spawnimport/wgen_plan.lua` (new) | 2-chunk-ring domain, seam pins / outer exact pins / guards, calls `field.solve`, widening as today |
| `mods/spawnimport/wgen_write.lua` (new) | column rebuild (§3.3) — replaces `gap_fill.place_gap_chunk` |
| `mods/spawnimport/wgen_decor.lua` (new) | vegetation pass (§3.4) with pluggable backend (A shim / B registry-swap / C unfiltered) |
| `mods/spawnimport/gap_fill.lua` | slim down: audit kept + reworked (§6); old write path retired (git history keeps it) |
| `mods/spawnimport/init.lua` | pregen margin `(2+MAX_EXTRA_RINGS)*16`; cursor/plan hooks call the new modules; setting gate |
| engine: `src/script/lua_api/l_mapgen.cpp` | optional shim (§2.3) — `generate_decorations` input maps |
| `mods/spawnimport/test_harness.lua` | Test 6 rewritten for rebuild semantics + decoration backend mocks; keep 54-check baseline green |
| `tools/prepare_world.sh`, `world_template/map_meta_settings.txt` | unchanged mapgen config (`v7`); document `spawnimport_worldgen_merge` |

---

## 5. Decoration backends (ordered preference)

**A — engine shim (recommended, exact).** §2.3. Natural placement rules
with caller-supplied heightmap/biomemap. ~40 lines C++, backwards
compatible, deployed wherever the kit builds Luanti.

**B — pure-Lua registry swap (stock engine, approximate).**
Outside mapgen context `generate_decorations` uses the shared (editable)
DecorationManager. Per mapchunk: snapshot
`core.registered_decorations`, `clear_registered_decorations()`,
re-register only decorations whose `biomes` intersect the target biomes,
run **per 16×16 tile × target-biome** passes (columns of other biomes
masked by clearing their surface to non-`place_on` during the pass or by
pass splitting), restore the registry. Known deviations: biome gating at
16-block tile granularity instead of per column, `sidelen` > 16
decorations compressed to tile size. Must verify decoration-id stability
for `mcl_structures` triggers (expected safe: mapgen uses the cloned
manager, ids fixed at startup — re-check in the harness).

**C — unfiltered bare pass (stock engine, degraded).** Fresh heights,
no biome filtering: right-looking trees at right heights, but species
mixing at biome borders and combined densities. Acceptable only as an
emergency fallback.

Backend chosen by capability probe at load; logged explicitly.

---

## 6. Verification & audit

Extend `gap_fill.audit` / `/worldplace gapaudit` (all PASS-critical
first):

1. **seam mismatches = 0** vs `terrain_cols` (unchanged).
2. **outer-edge mismatches = 0** vs the untouched natural surface
   (new — proves "edges match perfectly" against Mineclonia terrain).
3. **raised water = 0** (unchanged).
4. **merge slopes over cap** report (unchanged; expect near-zero with 2
   chunks of ramp).
5. **floating vegetation = 0** (new: every plant/log/leaf node must have
   a walkable `place_on` node directly beneath — catches smearing-class
   regressions globally).
6. **kelp/seagrass only below `water_level` and on sea-floor materials**
   (new).
7. **biome tint continuity** (new): `biomecolor` param2 of seam columns
   equals the capture neighbour's palette index.
8. structure intersections reported (cleared or masked — informational).

Testing loop (unchanged discipline):

- `luajit gap_field_test.lua` (33 checks) — still green.
- `luajit test_harness.lua` — Test 6 rewritten around column-rebuild +
  decoration-pass mocks (synthetic capture with trees/kelp/snow;
  asserts whole trees at new heights, kelp only in water, seam exact).
- `spawnimport_gap_only = true` runs against the 4 test bases (Tactical
  Nuke first — ocean/coastline exercises water+kelp; Fort Alcazar —
  cliffs exercise the 2-chunk ramp).
- Owner's eyes on the deployed rebuild (the real acceptance test), then
  `import_tools/full_rebuild.sh`, then the 205-base vast.ai run.

---

## 7. Phases

1. **WDL climate inputs** — footprint per-column biome+temperature,
   `wdl_climate.lua`, `wgen_inputs.lua`; harness coverage on real
   capture bytes. (Independent; also immediately useful for the
   base-side re-tint TODO in HANDOVER.)
2. **Terrain: 2-chunk ring + column rebuild** — `wgen_plan.lua`,
   `wgen_write.lua`, outer exact pins, seam-face materials, snow/dust
   rules, no-organic-carry. Gap-only runs against Tactical Nuke; audit
   items 1–4 green before vegetation work starts.
3. **Vegetation pass** — engine shim (or backend B), `wgen_decor.lua`,
   audit items 5–7. This is the phase that kills smeared trees and
   kelp-on-mountainsides; measure and compare tree density vs untouched
   ring terrain.
4. **Structures policy + integration** — clear/mask rules, `init.lua`
   wiring, pregen margins, `full_rebuild.sh` runs on all 4 bases,
   owner review.
5. **Switch & document** — `spawnimport_worldgen_merge` gate, docs
   (`FEATURE-gap-fill-blend.md` marked superseded), 205-base readiness
   (footprints regenerate with the new `source_footprint.lua` fields).

---

## 8. Decisions needed from the owner

1. **Engine shim OK?** (Backend A: ~40-line, backwards-compatible patch
   to `generate_decorations`; the kit already builds Luanti from source
   on both ends.) Recommended yes — it is literally "feeding the correct
   inputs into the natural worldgen". Otherwise backend B ships.
2. **Ring width:** 2 chunks per edge as directed (tunable via
   `spawnimport_gap_ring_chunks`, default 2).
3. **Structures in the ring:** clear (recommended, matches today) or
   mask-and-keep where they fit the merged terrain.
4. **Expectation setting:** beyond the ring, the world's own v7 terrain
   keeps its natural cliffs (this seed has ~90-block mountains). The
   merge removes seams and square edges; it does not flatten real
   mountains. (If MC-style gentler terrain is wanted world-wide, the
   alternative is Mineclonia's Lua levelgen — see below.)

## Appendix — alternatives considered and rejected

- **Mineclonia Lua levelgen (`mcl_levelgen`) as the merge host**
  (singlenode + `mcl_singlenode_mapgen`): everything is Lua-hookable
  (terrain, biome/temperature tables, features, structures) and the
  terrain is Minecraft-faithful. Rejected for now: measured 23× slower
  pre-generation (HANDOVER), a different terrain idiom from the deployed
  v7 world, and a much larger rework of the tested import pipeline. Its
  hook order (mg_register.lua: terrain → surface → carvers → features →
  structures) does validate the "patch before trees" ordering.
- **Merging at mapgen time** (patch inside `on_generated` before
  `finishBlockMake`): impossible for gap columns sharing a mapchunk with
  captured content — mapgen re-generation of a mapchunk overwrites the
  base (HANDOVER: integrity 25.97% when tried).
- **Shifting vegetation along with the skin** (status quo): by
  construction cannot fix the four symptoms (§1).
- **Feeding noise parameters instead of maps**: v7 terrain/biome noise
  params are world-global; no per-column injection point exists
  (`MapgenParams::readParams` once at startup). The heightmap/biomemap
  maps are the correct injection surface (§2.2).
