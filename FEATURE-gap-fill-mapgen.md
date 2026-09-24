# Gap-fill — real Mineclonia generation at blended heights/biomes

Owner proposal (2026-09-23). The round-28 flat fill and round-30 synthetic
"meet half-way" fill matched height but not the look (no biome colours, no
sand/snow/trees/water). This spec proposed running Mineclonia's own mapgen
for the ring chunks fed a blended height/biome field.

**Status (2026-09-23): Approach A is implemented.** The current code keeps
the natively-generated ring chunk and shifts its surface height toward the
world download (keeping natural blocks + water + edge biome re-tint).
Approach B (driving `mcl_levelgen` with a custom density field) was
assessed as the cleaner-but-much-harder path and is not built. The
implemented behaviour is documented in `FEATURE-gap-fill-blend.md`; the
rest of this file is the original design note kept for context.
**(2026-09-24: Approach A evolved into the "merge chunk" — seam-exact
height merge with a walkable slope cap and bounded widening; see
`FEATURE-gap-fill-blend.md` and `SESSION_2026-09-24_SUMMARY.md`.)**

## What Mineclonia's mapgen actually is (investigated)

Two generation paths exist, and the playtest world uses the first:

1. **Native v7 (what the playtest world uses — `mg_name = v7`).** The
   engine's C++ v7 mapgen produces base terrain (stone/dirt/grass/water),
   caves, the `biomemap`/`heatmap`/`humiditymap`, AND places Mineclonia's
   registered decorations (trees, plants) — all before Lua runs.
   Mineclonia's Lua (`mcl_mapgen_core`) then only recolours
   biome-tinted nodes via `param2` (`set_param2_nodes`) and places
   structures. The height and biome are already fixed by C++ by the time
   Lua can touch the chunk.

2. **Mineclonia Lua levelgen (`mcl_levelgen`, singlenode + `mcl_singlenode_
   mapgen`).** A full density-function reimplementation of the Minecraft
   worldgen: `make_overworld_preset(seed)` → `make_terrain_generator(...)`
   → `terrain_generator:generate(x,y,z, cids, param2s, structuremask,
   vm_index, biomes)`, plus `surface_system.lua` (dirt/grass/sand rules),
   `biomegen.lua` (`generate_biomes`), and the decor/feature pipeline.
   Heights come from density functions (`density_funcs.lua`); biomes from
   noise sampled by the preset.

So there are two viable ways to get "real generation at blended inputs":

### Approach A — post-process a natively-generated ring chunk (tractable)

For each ring chunk, after Mineclonia's on_generated pass:

1. read the natural surface + `biomemap`/`heatmap`/`humiditymap`;
2. compute the blended height field (as today) and a blended biome field
   (world-download biome at the edges, natural biome in the interior);
3. **shift** each column's surface vertically to the blended height,
   keeping the natural blocks (grass/dirt/sand/gravel/water) — a column
   move, not a re-fill;
4. re-apply the `param2` biome tint from the blended biome (grass/leaves);
5. handle water (below sea level → water surface), and drop trees that
   ended up floating above the shifted surface (or re-place them).

Pros: works with the existing v7 world, no world-wide mapgen change, keeps
real blocks/trees/water. Cons: trees/decorations are placed at the natural
height by C++ before Lua runs, so they must be corrected afterwards (moved
or regenerated); the "column shift" has edge cases (caves, ores, snow).

### Approach B — drive Mineclonia's Lua levelgen with a blended field (cleaner, harder)

Instantiate `mcl_levelgen`'s terrain generator per ring chunk and feed it a
blended height/biome, then run surface + biome + decorations so the chunk
is generated with the blended inputs end-to-end.

Pros: genuinely "run Mineclonia generation with a custom mixed map", trees
and biome correct by construction. Cons: the height is a density function
of noise — injecting an arbitrary blended heightmap means overriding the
density evaluation for those chunks (deep integration with
`density_funcs.lua`), and the decor/feature pipeline has to be re-run
manually outside the normal mapgen thread. Bigger and riskier.

## Recommendation

Start with **Approach A**, staged:

1. **Height shift + biome re-colour** — *done*.
2. **Water** — *done* (below `water_level`, which is the real v7 ocean
   surface, not the levelgen preset's `sea_level` — see `HANDOVER.md`).
3. **Trees/decorations** — *open*: currently anything above the shifted
   surface is cleared to air; regenerating decorations at the new surface
   is the remaining step.

## Key risks / decisions

- **v7 vs Lua-levelgen**: Approach A keeps v7; Approach B would need the
  world on singlenode + Lua levelgen (a whole-world mapgen change) OR
  calling `mcl_levelgen` out-of-band, which is untested and may desync from
  the surrounding v7 terrain.
- **Trees**: in v7 they are C++-placed before Lua runs; shifting the
  surface after the fact means manual tree handling. Approach B avoids this
  but is the big lift.
- **Water**: blending height across a land/ocean border needs a rule for
  what is water vs land on the blended side (the current land-only fill
  sidesteps this; Approach A/B must decide it).
- **Biome source of truth**: the world download's biome is derivable from
  the captured `sections[].biomes` (not currently extracted) or from the
  base's own terrain; this needs a new footprint field.

## Plan

1. ~~Write this up, confirm Approach A vs B with the owner.~~ Done — owner
   chose A.
2. ~~Prototype stage 1 (height shift + biome re-colour).~~ Done.
3. ~~Add water.~~ Done — below `water_level` columns become open water.
4. ~~Fold into the import and rebuild.~~ Done — `place_gap_chunk` keeps the
   natural terrain and shifts the surface; Tactical Nuke rebuilt and
   deployed. Trees/decorations are still cleared above the shifted surface
   rather than regenerated (stage 3, open).
