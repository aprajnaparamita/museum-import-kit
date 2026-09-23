# Session 2026-09-23 — status & changes (fresh-agent handoff)

Read this first if you're picking up the project cold. It covers the
whole 2026-09-22→23 session: what was changed, why, what's deployed, and
what's still open. The older `HANDOVER.md` has the long-lived "hard-won
facts" (some now corrected — see below); `HANDOFF.md` is a 2026-09-17
session log and is stale in places.

## One-paragraph context

2b2t Museum imports historic 2b2t base world-downloads into one packed
Mineclonia (Luanti) world. This session was an iteration loop on the
**test rig** (`~/dev/museum-tactical-test`, Tactical Nuke only) rather than
the full 205-base run. The two big themes were (1) upgrading the engine and
game (Luanti 5.16.1 → 5.17.0, Mineclonia 35899 → `~/dev/mineclonia-git`)
and (2) repeatedly reworking the **gap-fill** (the synthetic terrain that
bridges each base's captured chunks into the surrounding generated world).

## Environment (all on the internal disk; `~/dev` = `/Volumes/Dara/dev`)

| path | what |
|---|---|
| `~/dev/museum-import-kit/` | **the kit** — source of truth, edit here |
| `~/dev/luanti/bin/luanti` | Luanti **5.17.0** (the upgraded binary) |
| `~/dev/mineclonia-git/` | latest Mineclonia (0.123.1-75-g5bdce566f) |
| `~/dev/luanti/games/mineclonia` | symlink → `~/dev/mineclonia-git` (server's game) |
| `~/Library/Application Support/minetest/games/mineclonia` | symlink → `~/dev/mineclonia-git` (client's game; old copy = `mineclonia.bak-35899`) |
| `~/dev/museum-tactical-test/` | **test world** (Tactical Nuke only) |
| `~/dev/museum-tactical-manifest.json` | the 1-base manifest |
| `~/dev/museum-testrig/conf/tactical.conf` | headless config (`museum_target_bases = 1`) |
| `~/Library/Application Support/minetest/worlds/2b2t Museum TEST` | **deployed** client-facing world |
| `~/dev/museum-maparts/output/{final,mapartindex,wiki}/` | collection mapart library |

Headless run command:

```bash
~/dev/luanti/bin/luanti --server \
  --config ~/dev/museum-testrig/conf/tactical.conf \
  --world ~/dev/museum-tactical-test --gameid mineclonia \
  --logfile /tmp/tac.log < /dev/null
```

## What changed this session (with rationale)

### 1. Engine + game upgrade
Luanti 5.17.0 and Mineclonia git. The client game was still 35899 and its
wall system lacks `mcl_walls:*_short_pillar`, so every wall rendered as an
"unknown/invalid" block client-side. Fixed by symlinking the client's game
to the same checkout. **Client and server must run the SAME Mineclonia.**

### 2. Gap-fill (rewritten three times)
`mods/spawnimport/gap_fill.lua`. Progression:
- round 28 (pre-session): flat IDW fill — wrong (walls/bowls).
- round 30: single-chunk "meet half-way" synthetic ring.
- round 31: **only the single-chunk ring** around each base (8-neighbourhood
  "touched" chunks), never the whole bbox.
- round 32 → now: **natural-surface blend + shift**. For each ring chunk,
  keep the generated terrain: read the natural solid surface `S`, blend it
  toward the adjacent world-download surface, then **shift** the natural
  surface stack + trees vertically by `(B−S)` — preserving natural material
  and trees instead of replacing with flat synthetic grass. Water columns
  (blended surface below `water_level`) become open water. Edge grass is
  re-tinted with the world-download biome.

Key facts learned (see `HANDOVER.md` hard-won facts for the full list):
- **`dest_y_offset` is −61, not −64.** −64 aligned bedrock but left ocean
  bases 2–3 blocks underwater (Tactical's hangar flooded). −61 aligns sea
  level. Constant: `OVERWORLD_Y_CORRECTION` in `mods/spawnimport/init.lua`,
  and `dest_y_offset` in every overworld manifest entry — change together.
- **The real sea level is `core.get_mapgen_setting("water_level")` (=1),
  not the levelgen preset's `sea_level` (63).** `gap_fill.lua` uses the
  former.
- **Bedrock/void**: the gap-fill column ends at `mcl_vars.mg_bedrock_overworld_
  min..max` (−128..−124 in v7) with `mcl_core:bedrock`, then `mcl_core:void`
  below — it must not run solid stone 60 blocks below bedrock.
- **`B` must be rounded to an integer** (`math.floor(B+0.5)`) — the height
  relaxation leaves floats, and `area:index` truncates them, shifting the
  surface + bedrock by one block.

### 3. Footprint extension
`import_tools/placement_fit/source_footprint.lua` now emits, per real chunk:
`cols` (256 per-column top block), `solid_cols` (256 per-column solid
surface — used by the height blend), `biome` (surface biome from
`sections[].biomes`). `lua_import/anvil.lua` gained
`decode_section_biomes`.

### 4. Map orientation — world-download maps
`lua_import/mapdata.lua` reversed the **x-axis** (`row[128-x]`) so captured
maps render west-on-left again. This is a confirmed win (Tactical's captured
maps are now correct). Only the world-download maps needed this; the
collection maps were already correct and must NOT be flipped.

### 5. Shulker boxes
Two fixes in `mods/museumloot/init.lua`:
- imported shulkers had **no node-meta formspec** (VoxelManip never runs
  `after_place_node`/the formspec LBM), so right-click animated them open
  with no dialog. The loot pass now sets it.
- the formspec must include `mcl_formspec.get_itemslot_bg_v4(...)` slot
  backgrounds, or the 9×3 slot grid doesn't render ("items load but the
  grid does not").

### 6. Mapart gallery fill
`import_tools/mapart_gallery/auto_gallery_fill.py`:
- **size matching**: a cluster gets a piece of its exact size (3×2 → 3×2,
  5×5 → 5×5). Do not fall back to 1×1 for a multi-tile cluster.
- **`final/` priority is weighted**: `SOURCE_WEIGHTS = {final:3,
  mapartindex:2, wiki:1}` (final has higher odds, not a hard priority).
- **no duplicates**: each piece is placed once (registry-backed; reset
  `used_pieces_registry.json` if you want a clean library).
- Repointed `LUANTI_BIN`/`LUANTI_CONF` at the 5.17.0 binary + tactical
  config.
- The column-swap patches for a few world-download clusters are noted in
  `verified_real_map_clusters.json` (`column_swaps`) but **not auto-applied**
  — they need the real map ids (or display names like `"1-3"`).

### 7. Gap-fill "abrupt edges" (open)
The "meet half-way" blend leaves a half-step at the chunk border. Trees are
now preserved, but if edges still look abrupt this is a separate tuning
item (soften the blend / widen the transition).

## Current state

- **Deployed** (`…/worlds/2b2t Museum TEST`): Tactical Nuke only, rebuilt
  with everything above. `map.sqlite`/`mod_storage.sqlite` integrity ok,
  `mcl_maps` = 313 textures, `worldmods` = `museumwarp` + `spawnimport`
  (museumloot stripped). auth/players preserved.
- **Verified**: world-download maps correct; gap-fill 201/201 (0 errors);
  6 shulkers repaired; gallery fill 293 placements / 0 unfilled / 293
  distinct textures.
- **Unverified (needs owner's eyes)**: gap-fill trees/vegetation look, the
  "abrupt edges" tuning, shulker grid rendering, `final/` weighting feel.

## Key files changed this session

- `mods/spawnimport/init.lua` — `OVERWORLD_Y_CORRECTION = -61`, clear-to-
  sky-limit, gap-fill integration.
- `mods/spawnimport/gap_fill.lua` — natural-surface blend + shift, water,
  bedrock/void, float rounding.
- `mods/museumloot/init.lua` — shulker formspec + inventory.
- `lua_import/mapdata.lua` — x-axis flip.
- `lua_import/anvil.lua` — `decode_section_biomes`.
- `import_tools/placement_fit/source_footprint.lua` — `cols`/`solid_cols`/
  `biome`.
- `import_tools/mapart_gallery/auto_gallery_fill.py` — size matching,
  weighted `final/`, no-reuse, new binary path.
- `import_tools/mapart_gallery/verified_real_map_clusters.json` — noted
  column-swap patches (pending ids).
- `manifest/*.json`, `~/dev/museum-*-manifest.json` — `dest_y_offset = -61`.
- `FEATURE-gap-fill-blend.md`, `FEATURE-gap-fill-mapgen.md`, `HANDOVER.md`,
  `README.md` — updated to match.

## To rebuild (the established cycle)

```bash
# 1. sync worldmods from the kit
for m in spawnimport museumloot museumwarp; do
  rm -rf ~/dev/museum-tactical-test/worldmods/$m
  cp -R ~/dev/museum-import-kit/mods/$m ~/dev/museum-tactical-test/worldmods/$m
done
# 2. wipe + import
cd ~/dev/museum-tactical-test
rm -f map.sqlite mod_storage.sqlite map_meta.txt env_meta.txt force_loaded.txt
rm -rf mod_storage mcl_maps
~/dev/luanti/bin/luanti --server --config ~/dev/museum-testrig/conf/tactical.conf \
  --world ~/dev/museum-tactical-test --gameid mineclonia --logfile /tmp/tac.log < /dev/null
# 3. gallery fill
cd ~/dev/museum-import-kit/import_tools/mapart_gallery
python3 auto_gallery_fill.py --world ~/dev/museum-tactical-test \
  --manifest ~/dev/museum-tactical-manifest.json --bases "Tactical Nuke 2023-09"
# 4. deploy (client closed), preserving auth/players, stripping museumloot
```

## Rules of thumb

- Rebuilds are ~17 min (import) + ~2 min (gallery fill). Make sure the
  **client is closed** before the deploy `rm -rf`/`cp`.
- The manifest `dest_y_offset` and `OVERWORLD_Y_CORRECTION` move together.
- Collection maparts: correct as-shipped — don't add horizontal mirrors.
  World-download maps: the `mapdata.lua` x-flip is deliberate and correct.
