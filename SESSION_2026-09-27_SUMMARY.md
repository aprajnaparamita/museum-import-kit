# Session 2026-09-27 (afternoon): nether/End 3-D merge, band-offset fix, mapart mirror fix

**Start here if you are taking over.** This session's work is UNCOMMITTED in
the working tree (see "State of the tree" below). It has been rebuilt and
deployed to the owner's test world "2b2t Museum TEST" and verified with
probes. The owner has not walked it yet.

Environment and paths are unchanged (see `HANDOFF.md` / `BRIEF-2026-09-26.md`):
kit at `/Volumes/Dara/dev/museum-import-kit` (same volume as `~/dev`), Luanti
5.17 at `~/dev/luanti/bin/luanti`, Mineclonia source at `~/dev/mineclonia`,
micro staging world `~/dev/museum-microtest`, deployed world
`~/Library/Application Support/minetest/worlds/2b2t Museum TEST`.

## What the owner reported (start of session)

- End islands still generating at y -27010, one block tall (e.g. 4366, 6579),
  with the same gap. Wanted: the world download's End islands moved DOWN to
  Mineclonia's normal island height, looking like normal islands, merging
  as contiguous blobs.
- Nether roof still doesn't connect at (15157, -28944, -7699), and the gap is
  big enough to walk out. The roof in one chunk was at -28946 and in the
  adjacent one at -28940 ("the nether roof could be safely moved up").
- Netherite (ancient debris) visible through a one-block-thick nether floor
  with no bedrock at (15165, -29068, -7689).
- "All maparts from the world download are flipped backwards" (mirrored
  text), which also explains why maparts had needed reordering patches.
- Design direction: the nether is 3-D with no sky/ocean reference, so match
  the chunk edges on ALL sides. The End has no such assumption either.
  Success = a player can't tell they crossed from a world-download chunk
  into a Mineclonia chunk.

A previous agent (another model) had left an uncommitted `ring_chunks`
"merge every interior hole" edit. It was REVERTED: it duplicated ring
entries and would have exploded on sparse bboxes (the full-manifest End
entry is ~632x372 chunks).

## Root cause #1: wrong dimension band offsets

Mineclonia (`mods/CORE/mcl_init/init.lua` ~237-275) has two band layouts:

| | levelgen (singlenode + mcl_levelgen) | **v7 (our worlds)** |
|---|---|---|
| nether min | -29072 | **-29067** |
| End min | -26880 | **-27073** |

The museum worlds run `mg_name = v7`, `mcl_singlenode_mapgen = false`
(checked in the TEST world's map_meta.txt; `microtest.conf` doesn't set
mg_name, so v7 is the default). Commit `767b3cc` (2026-09-26) put the
levelgen pair into `museum_manifest_full.json` and
`museum_manifest_micro.json`. The older `museum_manifest.json` and
`mods/museumwarp` already used the v7 values, so nether/End warps had been
missing their per-band scan tables.

Consequences: the nether capture sat 5 blocks low (roof -28945 vs
Mineclonia's -28939, the owner's "-28946 vs -28940"). The End sat 193 blocks
high. Most of the 09-26/27 merge hacks (roof regen, End void clearing,
island slabs, hold-seam) were compensating for this.

With v7 offsets the capture lines up with Mineclonia row for row:
- nether: floor bedrock src 0..4; lava sea src 31 (= mg_lava_nether_max);
  roof bedrock (Mineclonia is 129 tall, top bedrock src 124..128; vanilla
  roof 123..127).
- End: platform at min+48, Mineclonia's v7 outer islands are end_stone
  strata ores at src 64..80 (`mcl_biomes/init.lua` ~3620), and Endhaven's
  islands top out around src ~56-66.

## Root cause #2 (found mid-session): the job never knew its dimension

`start_job` never passed `dimension_type` into `new_job`. The batch passed
`entry.dimension_type` only as `dimension_path_override`, so
`job.dimension_type` was ALWAYS nil. Every earlier band check survived only
because it fell back to guessing from `dest_y_offset`. The new nether roof
seal and the band-offset guard checked the field directly and silently
never ran.

Found by probing: 99 of 1168 Hausemaster chunks were unsealed. These were
exactly the chunks whose capture has blocks at y>=128 (roof mushrooms), so
their clear went up to y 143 and removed Mineclonia's own top bedrock row.
The other chunks only *looked* sealed. Fixed and covered by a harness check.

## What changed (files)

- `manifest/museum_manifest_full.json`, `manifest/museum_manifest_micro.json`:
  offsets -29072 -> -29067, -26880 -> -27073.
- `tools/build_full_manifest.py`: refuses nether/End entries whose offset
  isn't the v7 band.
- `mods/spawnimport/init.lua`:
  - loads `wgen_blend3d.lua`, which is the gap plan/write/audit for
    nether/End (no widening, no height targets, no grow pass);
  - `dimension_type` is plumbed from the manifest entry -> `start_job` opts
    -> `new_job`;
  - at job start it logs `"<name>: <dim> band, dest_y_offset N"` and logs an
    ERROR if the offset isn't `mcl_vars.mg_nether_min` / `mg_end_min`;
  - captured-chunk clear for nether/End is now the vanilla dimension height:
    nether src 0..128 plus the capture's own span, End 0..255 plus the
    capture's own span. The old "clear the full pregen range" extension is
    removed (it deleted Mineclonia's nether floor);
  - nether roof seal: in captured columns where src 127 is bedrock and 128
    is air, 128 becomes bedrock. That gives one flat top plate across
    captured and generated chunks. Builds or mushrooms on the roof are left
    alone.
- `mods/spawnimport/wgen_blend3d.lua` (NEW): the 3-D blend. Read its header.
  In short, per merge column, in the RING=2 around captured chunks:
  - Two vertical profiles: the capture sampled MIRRORED across the seam
    plane (terrain whitelist only, never builds), and Mineclonia's natural
    column (walkable = solid).
  - Each becomes a 1-D signed distance along y, mixed with a weight w
    (1 at the seam -> 0 at column distance 33, smoothstep plus value-noise
    jitter mid-ring only). Solid where the mix < 0.
  - Bands: nether writes src 5..123 (bedrock rows never written); lava fills
    carved space at y <= src 31. End writes src 0..255 with a small air cap
    (8) and alpha_top = 2, so islands erode from the bottom first: flat tops,
    tapering undersides.
  - Materials come from the dominant side. Natural decoration is kept where
    the local geometry is unchanged.
  - The audit checks seam voxel mismatches, which must be 0, in the same
    `[gap-fill] audit <name>:` log format.
- `mods/spawnimport/wgen_write.lua`, `gap_fill.lua`, `wgen_inputs.lua`: removed
  the End island-slab/void-column/hold-seam code and the nether roof-regen
  code (this path is overworld-only now). `gap_fill.is_terrain_name` is
  exported.
- `mods/spawnimport/wdl_climate.lua`: a botched replace in `c5a562a`
  (2026-09-25) had pasted the hash2/noise2/jitter/surface_family block into
  four function bodies. Removed; behaviour was already correct because a
  top-level copy existed.
- `mods/spawnimport/test_harness.lua`: Tests 6b/6c rewritten for the 3-D blend:
  - seam exact;
  - ring outer edge identical to generated terrain;
  - bedrock rows untouched;
  - lava <= src 31;
  - decoration kept where geometry is unchanged;
  - End keeps Mineclonia islands at the outer edge, no liquid, nothing below
    the band;
  - the job carries its dimension_type.
  Result: **69 checks, ALL PASS** (`luajit mods/spawnimport/test_harness.lua`,
  ~15 min). `gap_field_test.lua` passes.
- `lua_import/mapdata.lua`: removed the east-west mirror (`row[128-x]` ->
  `row[x+1]`), added 2026-09-23 on the false theory that item frames mirror
  maps. Mineclonia's own `mcl_maps` writes `pixels[z][x]` with west on the
  left, and the gallery art path never flipped. The north-south fix
  (`pixels[128-z]`) stays.
- `import_tools/mapart_gallery/verified_real_map_clusters.json`: the three
  hand-solved reorders plus `column_swaps` moved under `retired_2026_09_27`
  (kept, not applied). They were solved against mirrored tiles; the
  `_comment` explains why. `clusters` and `column_swaps` are now empty.
- `mods/museumportals/init.lua`: comment offsets updated (END_BAND range
  -27100..-26500 still covers the new placement).
- `PLAN-worldgen-merge.md`: a top note explaining the nether/End method and
  the band-offset precondition.

Memory: `project_dimension_band_offsets.md` records the offset gotcha.

## Verification done (deployed TEST world, micro rebuild v12, 17:34-18:05)

- All jobs log their band. No offset errors, no placement failures.
- 3-D blend audits, all PASS with 0 seam voxel mismatches: Taylobase 4
  (116 merge chunks, 798 seam cols), Hausemaster (481, 3717), Endhaven (412,
  3338). Tactical Nuke (overworld) ran the unchanged path with its usual
  numbers.
- Hausemaster roof: 298,540 captured columns sealed, 0 unsealed, 468 "other"
  (mushrooms or builds on the roof). Row 128 over the whole Hausemaster
  area: 0 air columns out of 632,121, so there's no walk-out.
- (15165, -7689): bedrock bottom row at -29067 with Mineclonia lava above it.
  (4366, 6579): the -27010 layer is gone. (15157, -7699): solid top plate at
  -28939 with Mineclonia's natural (holed) roof pattern under it.
- ASCII cross-sections (probe method below): the nether west seam at x=15207
  (z=-7700) has no step; the lava sea meets the capture along a sloped cliff.
  The End island seam at (5119, 6489) continues exactly and rounds off
  ~20 columns out, and Mineclonia's sheet at src 67-72 is untouched.

Probe method: copy the deployed world to the scratchpad, delete
`worldmods/{spawnimport,museumwarp,museumportals}`, add a tiny worldmod that
emerge_area's the region, prints `core.get_node` runs/slices via
core.log, and calls request_shutdown. Run
`luanti --server --port <free port> --config /tmp/zprobe.conf --world <copy>`.
Use `--port`, not a `port =` conf line: a second server on 30000 fails with
"Failed to bind socket". `/tmp/zprobe.conf` points museum_manifest_path at a
nonexistent file so no batch runs.

To decode source chunks standalone:
`cd lua_import && luajit` with
`anvil = dofile("anvil.lua"); anvil.decompress = dofile("gzip.lua").decompress`,
then use `anvil.iter_region_chunks`.

## Open items / next steps

1. **Owner walk-through** of the TEST world: nether seams, the roof, the End
   islands, and the maparts.
2. **Mapart walls to re-check in-game** now that the mirror is gone and the
   hand reorders are retired: Fort Alcazar's ceiling 3x3, cutecurly's City
   5x5 (both faces), Tactical Nuke's 2x3 and 3-wide. If one is still wrong,
   restore its entry from `retired_2026_09_27` (or re-solve it). Note: the
   micro world only contains Tactical of those bases.
3. Watch item: in one nether slice, where a natural cavern closed against the
   capture's solid rock, the blend's "nearest solid material" fallback made a
   tall ~15-wide band of soul sand. If the owner dislikes it, prefer
   netherrack for newly-solid voxels unless the dominant side is solid at
   that voxel.
4. Not touched: `museumwarp` keys the overworld tables on -64 while overworld
   bases use -61 (harmless fallback). Dead nether/End branches remain in the
   overworld planner (gap_fill scan ceiling exclusion, audit guard); they are
   harmless. `world_template/map_meta_settings.txt` still says
   `mg_name = singlenode` (stale; real worlds are v7).
5. **Commit** when the owner is happy: nothing from this session is committed
   yet. One commit covering all of the above is appropriate. The previous
   HEAD is `9d73808`.
6. The full 205-base manifest (`museum_manifest_full.json`) is already
   corrected. Any regenerated manifest goes through
   `build_full_manifest.py`'s guard.

## State of the tree (uncommitted)

```
 M PLAN-worldgen-merge.md
 M import_tools/mapart_gallery/verified_real_map_clusters.json
 M lua_import/mapdata.lua
 M manifest/museum_manifest_full.json
 M manifest/museum_manifest_micro.json
 M mods/museumportals/init.lua
 M mods/spawnimport/gap_fill.lua
 M mods/spawnimport/init.lua
 M mods/spawnimport/test_harness.lua
 M mods/spawnimport/wdl_climate.lua
 M mods/spawnimport/wgen_inputs.lua
 M mods/spawnimport/wgen_write.lua
 M tools/build_full_manifest.py
?? mods/spawnimport/wgen_blend3d.lua
?? SESSION_2026-09-27_SUMMARY.md
```

Rebuild + deploy loop: `./import_tools/micro_rebuild.sh` (~35 min; refuses to
run while any luanti process is up; backs up player/auth data on deploy).

## Follow-up round (evening): owner walk of v12

Owner report: the End capture's islands sit at -27018 while Mineclonia's sit
at -27003. A Mineclonia island looked "extremely square edged". Floating live
shulkers. Base chests had no OP loot, and end-ship chests had normal loot.
Tactical's 3-panel map wall was in the wrong order again ("when replaced as
patched would be the correct order"). Other map text now reads correctly.

Findings (measured on a sqlite `.backup` snapshot of the TEST world, probe
method above):

- **Maparts: root cause.** spawnimport places at anchor + (source - origin)
  and never negates z. MC +z is south and Luanti +z is north, so every base
  is a north-south MIRROR image. Single maps read correctly; multi-map
  pictures show their tiles in reversed left-right order. Proven by
  stitching Tactical's 3x3 portrait (x 15718-15720, y 4-6, z -10974, p2 5)
  and its 2x3 poster (x 15720, z -10980..-10979, p2 3) from the TGAs: the
  reversed order is seamless and the poster's text reads. The Fort/City
  entries were solved 09-22, against UN-mirrored tiles, so this afternoon's
  "retire them" reasoning was wrong; they are ACTIVE again. The Tactical
  `column_swaps` were never read by any code.
- **End heights.** Captured (vanilla) islands: top src median 58 (10-90%
  48-64), bottom ~20, ~38 thick. Mineclonia v7 End outside the ring: top
  ~72, ~4 thick. It's the placeholder `stratum` ore in mcl_biomes centred
  at band+70, which gives flat slabs with vertical sides (the "square"
  look). Owner chose: lift the captures +14.
- The square patches inside Endhaven's captured area are in the download
  itself. 1712 of 4037 chunks are fully generated but contain zero blocks,
  and some of them slice through islands. All 4037 chunks have status full.
- **Shulkers.** Mineclonia's end_boat/end_shipwreck spawn shulker ENTITIES
  at mapgen time. Our clear/blend removes the ship nodes, not the entities.
  An unattached shulker only tries +-8 teleports, so it floats in void
  forever.
- **Loot.** Structure detection sent Endhaven chests to vanilla end_city
  tables and 785 of Tactical's 1104 containers to vanilla DUNGEON loot
  (spawner farms). The 09-26 boost (x3 plus 1-2 jackpot) still reads as
  normal loot. Mineclonia's own end-ship chests just outside the bbox are
  never scanned; owner: keep those vanilla.

Changes:

- `import_tools/mapart_gallery/auto_gallery_fill.py`: new
  `unmirror_real_map_walls()`. It reverses every real-map WALL group (p2
  2/3 along z, p2 4/5 along x), skips groups covered by a verified entry,
  and logs ceiling/floor groups (item rotation is mirrored too). It isn't
  idempotent, so it's gated by `<world>/mapart_unmirrored.txt`. Both
  rebuild scripts wipe that marker.
- `verified_real_map_clusters.json`: Fort/City clusters active again, and
  `_comment` corrected. Tactical column_swaps are under `retired`.
- `mods/spawnimport/init.lua`: `new_job` keeps the manifest offset as
  `band_y_offset` (band key, guard, registry `dest_y_offset` for
  museumwarp) and places End jobs at band + `spawnimport_end_island_lift`
  (default 14). Harness Test 6c checks it.
- `mods/museumloot/init.lua`: base containers always get the themed base-
  stash (OP) pool. `structure_match` is still recorded for mobplacement.
  `museumloot_vanilla_structures = true` restores vanilla tables.
- `mods/museumportals/init.lua`: an End-band shulker that can't attach for
  about 10 s is removed via `safe_remove` (a plain `object:remove()` inside
  ai_step crashes mcl_mobs' on_step). Tested live: a void shulker was
  removed and a purpur-attached one kept.
- `import_tools/full_rebuild.sh` now ships museumportals (it never did).

## Later rounds (2026-09-27 night to 09-28): End edges, banners, gateways

Owner confirmed working: the nether, loot, Tactical maparts, the End
height lift and the shulker fix. Final deployed build is micro v19, plus the
museumportals updates copied in afterwards.

- **Empty download chunks stay void (owner rule).** Around 1712 of
  Endhaven's 4037 chunks are fully generated but hold zero blocks. Two
  attempts to "heal" island cuts at them were reverted:
  - v16 extruded neighbouring islands into them. It also left cliffs at the
    bbox edge, because ring chunks stopped fading toward those chunks.
  - v17 left Mineclonia terrain in them. That put end-stone slabs through a
    captured end city.

  Owner: the base floats in a player-cleared area, so "void chunks from the
  download should remain void and not be filled". Straight edges at those
  chunks (e.g. (5086, 6415)) are the download's own. The TNT-duper trench
  near (4820, 6976) is real captured terrain.
- **Wall banners** (`spawnimport/init.lua`): mcl_banners takes the entity's
  facing from node meta `rotation_level`, and the colour from an item in the
  node's "banner" list. Only on_place sets them, so every imported banner
  faced one way and was white. The import now sets both: facing from
  wallmounted param2, same rule as on_place; colour from the Minecraft name
  (`light_gray`→`silver`, `gray`→`grey`, else the same key). Patterns are
  still not read.
- **Mineclonia's end-ship banners** had the same bug. museumportals has an
  LBM that sets `rotation_level` from param2 on any hanging banner missing
  it, and turns the entity. It never touches a banner that already has one.
- **End gateways**:
  - `spawnimport/gateway_link.lua` pairs each End base's captured gateway
    with the free main-island slot nearest the base's direction. It uses
    Mineclonia's 20-slot ring (literal table copied from
    portal_gateway.lua), builds Mineclonia's gateway schematic there, and
    writes `<world>/museum_gateways.json`.
  - museumportals:
    - linked gateways teleport to their partner; landing on the main
      island is beside the exit portal;
    - unlinked outer gateways (bases past slot 20) go to the main island;
    - Mineclonia-owned gateways (unlinked main-island ones, and far-out
      ones that carry `mcl_portals:gateway_destination`) run Mineclonia's
      own `gateway_teleport`. They trigger within 2 blocks: the gateway is
      solid, and Mineclonia's ABM needs objects within 1 of its centre;
    - ender pearls teleport their thrower;
    - `mcl_portals.spawn_gateway_portal` (dragon kill) skips slots bases
      hold.
  - `tools/build_full_manifest.py` `assign_end_gateway_slots` gives each End
    base its own slot direction. It rotates a clashing base around the
    origin and refuses End overlaps. Today no move is needed: Endhaven gets
    slot 4, Space Valkyria slot 2.
  - Owner walk: all verified in play, including the dragon loop, after the
    2-block trigger fix.
- **Stranded shulkers**: a shulker with no `group:opaque` node within 8 is
  removed at once. Mineclonia's teleport never searches further, so it could
  never re-attach. Any other shulker gets the 10 s timer. The client log
  showed 43 removals in one walk; these came from Mineclonia end ships
  generated before import.
- Rebuild scripts wipe `mapart_unmirrored.txt` and `museum_gateways.json`.
- The empty-chunk experiment code (`captured_nonair`, hollow chunks) is
  gone. `wgen_blend3d.lua` is back to ring-only merge chunks.
