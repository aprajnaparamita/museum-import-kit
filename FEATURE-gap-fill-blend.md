# Gap-fill — "merge chunk": world download meets generated terrain

> **SUPERSEDED (2026-09-25)** by the worldgen-merge method in
> `PLAN-worldgen-merge.md` — the "merge chunk" blend below was replaced
> after the owner's 2026-09-24 review ("the edges should always match
> the level/characteristics of the touching world download blocks").
> Kept for design history; do not implement from this document.

Current gap-fill behaviour (2026-09-24). It replaces the earlier rounds
(flat IDW fill → synthetic "meet half-way" ring → natural-surface blend)
and is documented here in full; `FEATURE-gap-fill-mapgen.md` keeps the
original design discussion for context.

## The problem it solves

A base's captured ("world download") chunks end at a hard border against
Mineclonia's generated terrain. Leaving the gap chunks as raw generated
terrain produced hard seams at the base border (water intrusion, floating
fragments, and where heights differed, cliffs at the chunk edge). The
old "meet half-way" blend matched heights only *on average*, leaving half
the height difference as a step exactly at the chunk border, blended each
ring chunk independently (steps where two ring chunks met), dragged
generated water up with raised chunks, and ramped terrain toward *roofs*
because the footprint's "surface" was just the topmost solid block.

Goals (owner's words): it must **look normal to a player** and they must
be able to **move up/down more easily**; generated water at surface level
must be **replaced by air**, and floating blocks/islands must **never move
the chunk up**.

## Inputs

From `import_tools/placement_fit/source_footprint.lua` (per captured
chunk, 256 columns in local `lx*16+lz` order):

- `terrain_cols` — the topmost **natural terrain** block per column with
  floating masses rejected (a run ≤ 2 blocks thick over a ≥ 3 gap is a
  platform/stilted floor/floating island, not ground). **This is the seam
  target** — the ground the base sits on. Verified name whitelists for
  vanilla (1.13+ flattened) names. `solid_cols` (topmost non-liquid) and
  `cols` (topmost anything) remain for reference/back-compat but must NOT
  be used as merge targets: on a base they report roofs and walls.
- `biome` — per-chunk surface biome, for the seam grass re-tint.

From the generated map itself (read after pre-generation, before any gap
chunk is written): the natural surface of every column to be written —
same terrain whitelist (Mineclonia names) and floating-mass rule.

## The algorithm

**Scope — the single-chunk ring.** A gap chunk is merged only if its
8-neighbourhood touches a captured chunk. Everything further out stays
real generated terrain (filling wider areas destroys far too much of it).
The domain may grow *beyond* the ring only where a ramp needs room (see
Widening).

**Merged height field — solved jointly over all ring chunks** (the old
per-chunk blend left steps where two ring chunks met). Per column:

1. **Seam columns** (adjacent to a captured chunk, edge contact first,
   corner contact only when unconstrained) are PINNED to that chunk's
   `terrain_cols` height — the seam is **exact**, zero step. The capture's
   own terrain relief along the seam (a cliff the base is built against)
   is matched, not smoothed away: continuity with the museum piece wins.
   The16-column seam lines are lightly smoothed first so one misdetected
   footprint column cannot leave a spike.
2. **Boundary columns** facing untouched generated terrain are pinned to
   their own natural height, and the untouched neighbour columns enter
   the solve as *guards* (fixed values, never written): the merge is
   invisible where it meets real terrain and any step against it is
   seen by the violation analysis.
3. **Everything between** is solved by `mods/spawnimport/gap_field.lua`:
   no slope over `spawnimport_gap_max_step` (default 1 block/column —
   walkable/jumpable), and as close to each column's own natural height
   as possible ("disturb natural terrain as little as possible"). The
   solver pre-solves the exact pin-implied bounds (taut-string box) and
   then only cleans up local jumps in the natural surface.
4. **Water edges are not slope-constrained.** Land dropping to the base's
   sea floor is a sea cliff (you fall and swim); the sea floor may be as
   steep as it likes. Which columns continue as water (merged height
   below `water_level`) is classified and re-solved until stable.
   Constraining these edges too (the first real-world test) dragged whole
   coastlines down to sea level and demanded impossible ramps.

**Widening.** Where a ramp does not fit in the ring (seam target far above
or below the natural level), the domain grows into more natural chunks —
up to `gap_fill.MAX_EXTRA_RINGS` = 3 rings — and the ramp lands there.
Widening stops as soon as it stops helping (the unresolvable-slope count
is not improving by ≥ 25% per ring): a base built against a cliff can
never be ramped walkable at bounded width, and churning ring after ring
of natural terrain for a hopeless ramp is worse than a steep but
continuous hillside. Widening never touches captured chunks or another
base's footprint.

**Writing a merged column** (`gap_fill.place_gap_chunk`):

- *Land column* (merged height ≥ water level): the natural **surface skin
  (4 blocks) + the vegetation on it** (leaves/logs/plants/vines/snow
  cover) are SHIFTED by the height change — real material, real trees,
  original `param2` preserved. **Everything else above the surface becomes
  AIR** — this is the fix for generated water riding up with a raised
  chunk and for floating islands/junk surviving the merge. Below: natural
  sub/deep material, then Mineclonia bedrock and void at the real levels.
- *Water column* (merged height < water level): floor at the merged
  height, open water up to `water_level`, air above — leftovers cleared,
  never carried up.
- The seam edge's grass is re-tinted with the world-download biome.

## The audit (`gap_fill.audit`, automatic at every import + `/worldplace gapaudit`)

Re-reads every written column and reports/verifies:

1. **seam mismatches** — merged surface vs the capture's ground must be
   exactly 0 (PASS-critical);
2. **raised water blocks** — liquid above `water_level` must be 0 (a water
   column's own water stops AT sea level) (PASS-critical);
3. **merge slopes over cap** — steps the merge made *steeper than they
   already were* between two land columns (reported; some seams cannot be
   ramped walkable at bounded width and are steep-but-continuous on
   purpose — see below);
4. **natural relief steps** — pre-existing cliffs (in the capture seam or
   the generated terrain) that were matched or left alone (informational:
   the merge is not blamed for, and must not destroy, terrain that
   predates it);
5. **floating junk blocks** — non-vegetation left above the merged
   surfaces (informational; ~0 expected).

Land-to-water steps are sea cliffs and sea floor relief and are not
counted at all.

## Real-world numbers (all 4 test bases, 2026-09-24 rebuild audits)

| base | merge chunks (ring → +widened) | seam mismatches | merge slopes over cap (worst) | spilled base water | floating junk |
|---|---|---|---|---|---|
| cutecurly's City | 221 → 709 | **0** | 1246 (2.0) | 78 | 0 |
| Tactical Nuke 2023-09 | 201 → 407 | **0** | 1524 (4.0) | 17 | 0 |
| Fort Alcazar | ~290 → 709+ | **0** | 4704 (14.0) | 639 | 0 |
| Dark Souls Castle | ~250 → 709+ | **0** | 572 (3.0) | 127 | 0 |

Seam exactness (the owner's "gaps in height near the edges") is 0/3172–3908
seam columns per base. The remaining "merge slopes over cap" are gentle
2–4 block steps (14 at Fort Alcazar, a castle against big cliffs) where
the relief exceeds the ramp budget — steep-but-continuous by design.
"Spilled base water" is the captured base's own canals/fountains/moats
pouring onto the merge after the write (gap-only runs without the base
placed report 0; the merge's write path cannot produce water above sea
level at all). Plan ~10–30 s, audit ~2–5 s per base.

## The −61 sea-level offset

See `HANDOVER.md`'s hard-won facts: overworld bases use
`dest_y_offset = −61` (sea-level aligned) or ocean bases flood;
`OVERWORLD_Y_CORRECTION` in `mods/spawnimport/init.lua` and the manifest
must change together.

## Known limitations

- **Cliff bases are steep but continuous.** Where the capture's terrain
  at the seam is tens of blocks above/below the generated terrain and the
  budget runs out, the merge produces a steep (2–4 blocks/column) but
  unbroken hillside — never a gap at the border. Fully walkable ramps in
  those cases need unbounded widening (destroying real terrain), which is
  deliberately rejected.
- **Surface MATERIAL is not matched at the seam** (height + biome tint
  only): the ring keeps its natural material (grass/sand/…). A material
  strip along the seam would look stitched; a height-exact grass-into-grass
  join is invisible in practice.
- **Trees shift per column** (preserving what was there), so a wide canopy
  can shear slightly where the shift differs across columns. Trees are
  never dropped and never drag the height.
- Captured columns whose ground cannot be detected at all (fully
  structure-covered to bedrock) fall back to `solid_cols`/`cols`/`height`.

## Tuning knobs

- `spawnimport_gap_max_step` (setting, default 1.0) — max slope in blocks
  per column.
- `spawnimport_gap_only` (setting, `true`) — skip placing the captured
  chunks and run only pregen + merge; a minutes-fast loop for merge
  tuning (use `mods/fullimport` as the driver — it shuts the server down
  when done).
- `/worldplace gapaudit` — re-run the audit for the last imported base.
- `gap_fill.MAX_EXTRA_RINGS` (constant, 3) — widening budget.
