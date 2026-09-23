# Gap-fill — natural-surface blend on the single-chunk ring

This is the current gap-fill behaviour (2026-09-23, rounds 28→32). It
replaced the original round-28 "flat IDW fill" and the round-30 synthetic
"meet half-way" fill. Full design discussion: `FEATURE-gap-fill-mapgen.md`.

## The problem it solves

A base's `chunk_bounds` rectangle is mostly Mineclonia-generated terrain;
only the captured ("world download") chunks have real content. Leaving the
gaps as raw Mineclonia terrain produced hard seams at the base boundary
(water intrusion, floating fragments). The first fix replaced *every* gap
chunk with synthetic stone/dirt/grass — correct height, wrong look, and
far too much terrain destroyed.

## Current behaviour

1. **Scope — only the single-chunk ring.** A gap chunk is blended only if
   its 8-neighbourhood touches a captured chunk. Everything further out
   stays real Mineclonia terrain.
2. **Keep the natural terrain.** For each ring chunk, read the generated
   terrain's solid surface (top walkable, non-leaf/log/liquid block — the
   ground, or the ocean floor for water). Do NOT clear and re-fill.
3. **Blend the surface height.** Average the surface toward the adjacent
   world-download chunk's solid surface at each edge ("meet half-way"),
   relax the 14×14 interior, then shift the surface up/down to the blended
   height — keeping the natural surface material (grass/sand/dirt/stone).
4. **Water.** Columns whose blended surface is below `water_level` become
   open water up to `water_level` (use `core.get_mapgen_setting
   ("water_level")`, the real v7 ocean surface — NOT the levelgen preset's
   `sea_level`, which is 2 blocks off).
5. **Biome re-tint.** Edge grass is re-coloured with the world-download
   chunk's biome (from the footprint `biome` field) via Mineclonia's
   `_mcl_palette_index` param2.
6. **Bedrock and void.** The column ends at Mineclonia's real bedrock
   (`mcl_vars.mg_bedrock_overworld_min..max`, −128..−124 in v7) with
   `mcl_core:bedrock`, and `mcl_core:void` below it — it does NOT run solid
   stone to the bottom of the pregen range (which extended ~60 blocks below
   bedrock). The blended surface `B` is rounded to a whole number first; a
   float `B` made the fill loop's y non-integer, which `area:index`
   truncates, shifting the surface and the bedrock boundary by one block.

## Footprint fields (all extracted by `source_footprint.lua`)

- `cols` — per-column top block (top non-air), 256 ints.
- `solid_cols` — per-column solid surface (top non-liquid), 256 ints; this
  is what the height blend uses.
- `biome` — per-chunk surface biome (`sections[].biomes` palette[1]).
- `height` / `is_water` — per-chunk summary (unchanged).

## The −61 sea-level offset

See `HANDOVER.md`'s hard-won facts. In short: overworld bases use
`dest_y_offset = −61` (sea-level aligned), not −64 (bedrock aligned), or
ocean bases flood 2 blocks deep. `OVERWORLD_Y_CORRECTION` in
`mods/spawnimport/init.lua` and the manifest must change together.

## Known limitations

- The world-download "solid surface" includes *structures* (buildings), not
  just terrain, so a ring chunk next to a tall structure blends toward the
  structure's top. Acceptable for now; needs a structure-vs-terrain split
  in the footprint to fix properly.
- Water is placed only below `water_level`; the ring blend does not yet
  recreate shorelines/sand or match the world-download *material* at the
  edge (it keeps the natural material and only matches height + biome).
