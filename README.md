# Import a World Downloader (WDL) Anvil files into Luanti Mineclonia mod

This is a system to effortlessly import World Download files into
Luanti. You can save your base and import it into your Mineclonia
world! Or you can browse world downloads of other's bases. See
FriedcakeSMP (coming soon) to visit these bases in a fun SMP environment.

# 2b2t Museum import kit

In order to fully test the mod's effectiveness I decided to pick a large
database of available world downloads from a real active server. Here is
everything needed to import the 2b2tmuseum-WDL archive into a single packed
Luanti / Mineclonia world. Explore some of the greatest bases ever made

## What you need

1. **Luanti 5.17.x** (server build is enough — no GUI needed; the
   client must run the SAME Mineclonia as the server).
2. **Mineclonia** in `games/mineclonia`.
3. **The WDL archive** — clone the github  (~13 GB).
4. **This kit.**
5. **Disk**: budget ~25 GB for the finished world.

## Setup

> **Before a full run, read `GUIDE-vps.md` → "Read this before a full run".**
> The steps below are older than the nether/End merge, the End gateways and
> the mapart unmirror. As written they build a terrain-less singlenode world,
> copy every mod (including a second batch driver), skip the merge wherever
> footprints are missing, and leave multi-map art reversed. The guide lists
> the fixes, and ends with a ready-made agent prompt for the whole run.
> The verified reference is `import_tools/micro_rebuild.sh`.

```bash
# 1. mods
mkdir -p ~/.minetest/worlds/2b2t-museum/worldmods
cp -R museum-import-kit/mods/* ~/.minetest/worlds/2b2t-museum/worldmods/

# 2. world config
cp museum-import-kit/world_template/world.mt ~/.minetest/worlds/2b2t-museum/

# 3. point the manifest at wherever the WDL archive landed
./museum-import-kit/tools/rewrite_manifest_paths.py \
    museum-import-kit/manifest/museum_manifest.json \
    /Users/dara/dev/2b2tmuseum-WDL /root/2b2tmuseum-WDL

# 4. edit museum-import-kit/world_template/import.conf so the two absolute
#    paths match this machine, then start the server once to create
#    map_meta.txt, let it exit, and add the settings from
#    world_template/map_meta_settings.txt BEFORE the [end_of_params] line.

# 5. run it, supervised
./museum-import-kit/tools/supervise.sh \
    ~/.minetest/worlds/2b2t-museum \
    /tmp/fullimport.log 205 300
```

`supervise.sh` expects `import.conf` next to itself — copy it into
`tools/` or edit the `CONF=` line at the top.

## Why the odd settings

Each of these was diagnosed the hard way; changing them will break things
in ways that are not obvious for hours.

- **`mg_name = v7` (real terrain) + gap-fill** — the early "self-contained
  capture" idea (`mg_name = singlenode`) was abandoned: the world now
  generates real Mineclonia terrain everywhere, and `spawnimport`'s
  gap-fill MERGES the single-chunk ring around each base into the
  world download: seam heights match the capture's ground exactly,
  slopes are walkable, and generated surface water / floating masses
  become air. See `FEATURE-gap-fill-blend.md`. Turning off
  `mcl_singlenode_mapgen` was worth ~23x on pre-generation (178.7s → 7.6s
  per base-sized volume) back when singlenode was in play.

- **Pre-generation before placing (in `spawnimport`)** — a VoxelManip write
  does *not* mark blocks generated. Blocks that aren't flagged generated are
  (a) regenerated over by the emerge thread and (b) **never sent to the
  client at all**. Both were observed: ~80% of imported blocks destroyed,
  and bases rendering as empty sky. Generating first and overwriting fixes
  both, because `blitBackAll` overwrites generated blocks by default and
  `MapBlock::copyFrom` doesn't clear the flag.

- **`mapgen_limit` left at default** — setting it to 0 stops mapgen
  overwriting imports but also permanently blocks delivery to clients.

- **Clearing only the chunk's own 16x16 footprint** — `read_from_map`
  expands to whole mapblocks, so blanking the emerged volume erased the
  neighbouring chunk. Produced evenly-spaced strips of terrain with
  full-height air canyons between them.

## Expect these in the results

- **Space Valkyria III skips ~7,138 chunks.** They're pre-1.18 legacy
  format mixed into an otherwise-modern capture. Roughly 38% of them hold
  real blocks, so ~2% of that base is missing. Supporting the old format
  (numeric IDs + damage nibbles) is the only fix.
- **`raw_copper_block`** has no Mineclonia equivalent — 4 blocks corpus-wide.
- **Some doors arrive without their upper half**; the importer synthesises
  the missing top so they don't render as half-height.

## Known engine fault

Luanti 5.16.1 intermittently aborts under sustained heavy writes:

```
DatabaseException: Failed to commit SQLite3 transaction:
cannot commit transaction - SQL statements in progress
```

`supervise.sh` restarts through it, resuming from the registry checkpoint
(a base is only recorded once fully placed). On the local run this fired
every 20–30 minutes early on, then not once in 8+ hours after Mineclonia's
Lua levelgen was disabled — less write pressure, apparently.

**On a fast box, consider `backend = leveldb` in `world.mt`** if your build
has it. It sidesteps this fault entirely, and the import is write-heavy
enough that it may also be faster.

## Rough timings (from the local run)

Measured on USB 2.0 (~40 MB/s, ~800 IOPS) — NVMe should beat these
comfortably, though chunk placement is CPU-bound on Lua decoding, so CPU
matters as much as disk.

| | |
|---|---|
| pre-generation | ~0.010 s per bbox-chunk |
| placement | ~0.043 s per captured chunk |
| corpus total | 1,135,329 chunks across 205 bases |
| full run | ~22 h |

## Verifying afterwards

The strongest check is a block-by-block diff of the placed world against
the original `.mca` files — decode source chunks, resolve through
`palette.resolve_detailed`, compare against a VoxelManip read at the
destination. The local run scored **99.982%** across 633,597 blocks
(the residue is flowing lava/water settling after `update_liquids`).

Also worth checking per base: containers > 0, signs carry `utext`, no
orphaned door bottoms, and no Mineclonia terrain in the column beneath.
