# 2b2t Museum — project handover

Brief for an agent picking this up cold. Read this first, then the specs it
points at.

## What this is

`~/dev/2b2tmuseum-WDL` (13 GB) is the community archive of historic 2b2t
base world-downloads. The goal is to import every usable base into **one
packed Luanti / Mineclonia world**, tightly packed and non-overlapping,
with `/warp <name>` to reach each one — a museum of bases that were
destroyed on the original server.

Intended destination: an anarchy server that resets regularly, where
exploring the old bases for loot is the draw.

## Where everything lives (all on the internal disk)

| path | size | what |
|---|---|---|
| `~/dev/museum-import-kit/` | 416 K | **the deployable kit** — mods, manifest, tools, guides |
| `~/dev/museum-world-rescue/` | 8.7 G | **playable world, 189 of 205 bases** (salvaged, see caveats) |
| `~/dev/museum-testrig/` | 12 M | server-only Luanti + `builtin/`, for headless testing |
| `~/dev/museum-worldgen-test/` | 61 M | one-base world proving worldgen-after-import works |
| `~/dev/2b2tmuseum-WDL/` | 13 G | the source archive (also a public GitHub repo) |

`/Volumes/Dara` is an external USB drive holding the original source tree
(`spawnmasons/`) and the Luanti build. **Its cable was failing and is being
replaced.** Nothing above depends on it; everything needed was copied off.

## Kit contents

```
mods/spawnimport      the importer: pre-generation, Anvil decode, palette,
                      door repair, sign text, warp-target recording
mods/museumwarp       /warp <name>, /warp list, spawn platform, privileges
mods/fullimport       batch driver (manifest path is a setting)
lua_import/           anvil.lua, nbt.lua, palette.lua, data.lua
manifest/             museum_manifest.json — 205 bases, packed, no overlaps
tools/supervise.sh    restarts through crashes AND drive disconnects
tools/setup_remote.sh builds server-only Luanti on Ubuntu
tools/prepare_world.sh creates the world, rewrites paths, writes settings
tools/rewrite_manifest_paths.py  repoint the manifest at a new archive path
world_template/       world.mt, import.conf, map_meta settings + why
README.md             kit overview
GUIDE-vps.md          end-to-end remote run guide (dedicated VPS)
FEATURE-warp-ui.md    spec: warp browser UI (not implemented)
FEATURE-loot.md       spec: container loot (not implemented)
HANDOVER.md           this file
```

## Status

- **Full 205-base import: incomplete.** Reached 189/205 locally before the
  external drive's cable failed and corrupted the map twice. The world was
  salvaged with SQLite `.recover` both times.
- **The plan** is to re-run the full import from scratch on a dedicated
  VPS — see `GUIDE-vps.md`. The kit is ready for that.
- **Two features specced, neither implemented**: the warp browser UI and
  container loot.
- **2026-09-23 session (Luanti 5.17.0 + Mineclonia git):** upgraded the
  harness to `~/dev/luanti/bin/luanti` (5.17.0) and `~/dev/mineclonia-git`
  (the client game is now a symlink to the same checkout). Gap-fill was
  rewritten three times — flat IDW fill → single-chunk "meet half-way"
  ring → **natural-surface blend** (keep Mineclonia's generated terrain,
  shift only the surface height toward the world download, add water below
  sea level, re-tint biome at the edges). The footprint grew `cols` /
  `solid_cols` / `biome`. Fixed a 3-block sea-level misalignment:
  overworld `dest_y_offset` is now **−61**, not −64 (see the hard-won fact
  below) — the only ocean base (Tactical Nuke) was flooding. Current test
  world is `~/dev/museum-tactical-test` (Tactical Nuke only).
- **2026-09-24 session ("merge chunk"):** gap-fill rewritten a fourth
  time into the current **merge-chunk** algorithm (see
  `FEATURE-gap-fill-blend.md`): seam heights now match the capture's
  ground EXACTLY (`terrain_cols` -- the ground under a base, not its
  roofs; the old "meet half-way" blend left half the difference as a
  cliff at the chunk border and ramped toward ROOF heights), the field is
  solved jointly over all ring chunks with a walkable slope cap,
  generated water in raised columns becomes air, floating islands/roofs
  never count as ground, and the domain widens (bounded, only while it
  helps) where a ramp needs room. An audit verifies seam exactness / no
  raised water / slopes at the end of every import (`/worldplace
  gapaudit`). The kit is now a **git repo** (branch `gap-fill-merge`
  holds this work). All 4 test bases rebuilt and deployed with it.

### Caveats on the rescue world

1. **16 bases missing** (189 of 205). The registry knows which.
2. **Possible silent data loss.** `.recover` also reads freelist pages,
   which can hold a block's *pre-import* version. Every mapblock was
   written twice (empty by pre-generation, then with content), so some may
   have come back empty. Three sampled bases looked correct; not verified
   across all 189.
3. Its `museumwarp`/`spawnimport` are copies; edit those, not the kit's,
   then sync.

To browse it, `minetest.conf` needs:

```
secure.enable_security = false
spawnimport_lua_import_path = /Users/dara/dev/museum-world-rescue/lua_import/
```

Both are required because `museumwarp` reads the registry through
`spawnimport`, which needs filesystem access to load its chunk decoder.

## Hard-won facts — do not relearn these

**Pre-generation is mandatory.** A VoxelManip write does *not* mark blocks
generated. Blocks that aren't flagged generated are (a) regenerated over by
the emerge thread and (b) **never sent to the client at all**
(`src/server/clientiface.cpp` only sends blocks where `isGenerated()`).
Both were observed: ~80% of imported blocks destroyed, and bases rendering
as empty sky. Fix: `core.emerge_area` first, then overwrite — `blitBackAll`
overwrites generated blocks by default and `MapBlock::copyFrom` doesn't
clear the flag.

**Never set `mapgen_limit = 0`.** It stops mapgen overwriting imports but
also permanently blocks delivery to clients.

**`mcl_singlenode_mapgen = false` must go BEFORE `[end_of_params]`** in
`map_meta.txt`; settings after that marker are silently ignored. Choosing
`mg_name = singlenode` *enables* Mineclonia's Lua levelgen by default
(`mcl_init/init.lua:71`). Turning it off was worth **23x** on
pre-generation (178.7 s → 7.6 s per base-sized volume).

**Clear only the chunk's own 16×16 footprint.** `read_from_map` expands to
whole mapblocks, so blanking the emerged volume erases the neighbouring
chunk — this produced evenly-spaced strips of terrain separated by
full-height air canyons.

**Mapgen's unit is the mapchunk (80³), not the mapblock.** Protection is
all-or-nothing per mapchunk. Deleting "gap" blocks inside a base's
mapchunks so terrain could flow in caused mapgen to regenerate those
mapchunks and destroy the base (integrity fell to 25.97%). Leaving them
alone gives **99.973%** integrity with terrain generated right up to the
edge — see `~/dev/museum-worldgen-test`.

**Verify every item/node name against the running game.** Two silent
failures came from unverified names: only oak signs were mapped, so 1,087
birch/spruce/jungle signs became solid stone; and `brewing_stand` pointed
at `mcl_brewing:stand`, which has never existed. Dump
`core.registered_nodes` / `registered_items` and check against it.

**`chat_send_player` to a disconnected player vanishes** — no log line at
all. Use `core.log("action", ...)` for anything you need to observe in a
headless run.

**Luanti 5.16.1 aborts intermittently** under sustained heavy writes:
`DatabaseException: Failed to commit SQLite3 transaction: cannot commit
transaction - SQL statements in progress`. `tools/supervise.sh` restarts
through it, resuming from the registry checkpoint. Consider
`backend = leveldb` instead (must be set before the first run).

**The overworld Y offset is −61, not −64.** −64 aligns *bedrock* (vanilla
−64 → Mineclonia −128) but leaves the imported *sea level* ~3 blocks below
Mineclonia's actual ocean surface. Mineclonia's v7 mapgen fills water at
`water_level = 1` (dest), which is 3 blocks higher, relative to bedrock,
than Minecraft's sea level — so vanilla water y=62 lands at dest −2 while
Mineclonia's ocean sits at dest 1. Every ocean base flooded 2 blocks deep
(Tactical Nuke's hangar; verified in-client). −61 aligns the sea level
(water 62 → dest 1, a base's sea-level floor 63 → dest 2, one block above
water) at the cost of bedrock landing at −125 instead of −128 — invisible.
Change `OVERWORLD_Y_CORRECTION` in `mods/spawnimport/init.lua` AND every
overworld entry's `dest_y_offset` in the manifest *together*; the End
bases' much larger negative offset must be left alone. Land bases carry
the same offset but don't reveal it — only water does.

**The v7 `water_level` is the real sea level, not the levelgen preset's
`sea_level`.** `mcl_levelgen.make_overworld_preset().sea_level` reports 63
(the air block one above the water), which is 2 blocks off from where v7
actually fills water. Gap-fill used the preset value and produced
2-block-low water. Use `core.get_mapgen_setting("water_level")` (dest
space) for any water-fill decision.

**Gap-fill: the single-chunk ring around a base, MERGED -- not filled.**
Filling the whole bounding box destroyed a huge amount of Mineclonia-
generated terrain; the merge only touches chunks whose 8-neighbourhood
touches a captured chunk (plus, where a ramp needs room, up to 3 more
rings -- bounded, and only while it helps). The ring KEEPS the natural
terrain (material, trees) and shifts it onto a height field that meets
the capture's `terrain_cols` ground EXACTLY at the seam (no "meet
half-way" step at the chunk border) with walkable slopes, drops surface
water and floating masses to air, and never lets a roof or floating block
set the height. See `FEATURE-gap-fill-blend.md` (current behaviour) and
`FEATURE-gap-fill-mapgen.md` (design history).

**Client and server must run the SAME Mineclonia.** The import used
`~/dev/mineclonia-git`, but the client still loaded release 35899, whose
wall system has no `mcl_walls:*_short_pillar` — every wall rendered as an
"unknown/invalid" block client-side while being perfectly valid in the
map. Fix: point the client's game at the same checkout (it is now a
symlink; the old copy is `mineclonia.bak-35899`).

## Numbers worth knowing

| | |
|---|---|
| bases in manifest | 205 (203 overworld, 2 End, 0 Nether) |
| captured chunks, corpus | 1,135,329 |
| blocks placed at 189 bases | ~8 billion |
| full run time | ~22 h on USB 2.0; CPU-bound on Lua chunk decode |
| pre-generation | ~0.010 s per bbox-chunk |
| placement | ~0.043 s per captured chunk |
| finished world size | ~13–15 G expected |
| import fidelity | **99.982%** vs source, block-for-block (633,597 sampled) |

Known gaps: **Space Valkyria III skips ~7,138 chunks** (pre-1.18 legacy
format mixed into a modern capture, ~2% of that base — supporting the old
numeric-ID format is the only fix). `raw_copper_block` has no Mineclonia
equivalent (4 blocks corpus-wide).

## Testing pattern

No GUI. Put a throwaway mod in the world's `worldmods/`, drive it from
`core.register_on_mods_loaded` + `core.after`, log with `core.log`, end
with `core.request_shutdown("done", false, 1)`, then grep the logfile.
Chat commands are callable directly:
`core.registered_chatcommands["warp"].func("singleplayer", "list")`.

```bash
~/dev/museum-testrig/bin/luanti --server --config /tmp/t.conf \
  --world ~/dev/museum-world-rescue --gameid mineclonia \
  --logfile /tmp/t.log < /dev/null
```

Harnesses exist and should stay green:
`mods/spawnimport/test_harness.lua` and (on the external drive)
`lua_import/test_harness.lua`.

## Next steps

1. **Run the full import on a dedicated VPS** — `GUIDE-vps.md`. It must use the
   current `dest_y_offset = −61` manifest and the rewritten gap-fill.
2. **Loot pass** — `FEATURE-loot.md` (revised: structure-matched chests use
   Mineclonia loot tables; the rest are themed by an LLM from nearby sign
   text).
3. **Warp browser UI** — `FEATURE-warp-ui.md`.
4. **Optional: worldgen for continuity** — proven to work, see above.
5. ~~**Rebuild the other three test bases** (cutecurly's City, Fort
   Alcazar, Dark Souls Castle) with the −61 offset.~~ Done 2026-09-24:
   all 4 test bases rebuilt with the merge-chunk gap-fill and deployed to
   `…/worlds/2b2t Museum TEST`.
6. **Biome colours.** The footprint now extracts each chunk's surface
   biome (`sections[].biomes`); the ring blend already re-tints the edge
   grass with it. Re-tinting the *bases themselves* still has to happen at
   import time (the `param2` palette indices from Mineclonia's
   `mcl_biomes`).


## Game patch required: mcl_maps load_map headless callback (2026-09-25)

`mods/ITEMS/mcl_maps/init.lua` -> `load_map()` must fall back to invoking
the media callback immediately when `#core.get_connected_players() == 0`.
Without it, map-frame imports multiply `mcl_itemframes:item` entities
without bound (mcl_itemframes:set_item's `core.after(0, update_entity)`
retry fires every step, and `find_entity` cannot see saved/static
objects): observed 50,050 frame entities in ONE mapblock from 50 source
frames, plus a near-crash during the gap-fill audit. See
`import_tools/game_patches/mcl_maps-load_map-headless.patch`. Applied to
`~/dev/mineclonia-git` on 2026-09-25 -- re-apply after upstream merges.
