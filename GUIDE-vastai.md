# Running the 2b2t museum import on vast.ai

End-to-end guide. Assumes the kit at `~/dev/museum-import-kit` and the WDL
archive at `~/dev/2b2tmuseum-WDL` on your Mac.

## 1. Pick an instance

This job is **CPU-bound on single-core performance** — the time goes into
Lua decoding of Minecraft chunks, which does not parallelise across cores.
A GPU is irrelevant; rent the cheapest instance that has a fast core.

| what | why |
|---|---|
| **High single-core clock** | placement is ~0.043 s/chunk × 1.13M chunks |
| **Cores: 4–8 is plenty** | only the emerge threads use extra cores |
| **RAM: 16 GB+** | the server holds a large block cache |
| **Disk: 60 GB** | 13 GB archive + ~15 GB world + ~3 GB build + headroom |
| **NVMe** | avoids the I/O wall that made the local run slow |

Disk is allocated **at rental time** on vast.ai and can't easily grow
later — ask for 60 GB even though ~35 GB is the true need.

Image: any plain `ubuntu:22.04`. You don't need a CUDA image.

**Check the price of interruptible vs on-demand.** This run takes 14–20
hours; an interruptible instance that gets reclaimed halfway is fine —
the import is checkpointed and resumes — but only if the *disk* survives,
so on-demand is the safer choice for an overnight run.

## 2. Transfer the data

The archive is the slow part: ~13 GB up. Start it first and let it run
while you do everything else.

```bash
# from your Mac. get HOST/PORT from the vast.ai instance page
export VAST="root@HOST -p PORT"

# the kit (tiny)
rsync -avz -e "ssh -p PORT" ~/dev/museum-import-kit/ root@HOST:~/museum-import-kit/

# Mineclonia -- use YOUR copy, not a fresh clone (see note below)
rsync -avz -e "ssh -p PORT" \
  ~/Library/Application\ Support/minetest/games/mineclonia/ \
  root@HOST:~/mineclonia/

# the archive (~13 GB, the long one)
rsync -avz --partial --progress -e "ssh -p PORT" \
  ~/dev/2b2tmuseum-WDL/ root@HOST:~/2b2tmuseum-WDL/
```

`--partial` matters: if the transfer drops, rerunning resumes instead of
restarting.

**Why your Mineclonia and not a fresh clone:** the block palette maps
Minecraft names to *exact* Mineclonia node names, verified against the
3,180 nodes your install actually registers. A newer Mineclonia can rename
or drop nodes, and the failure mode is silent — unmapped blocks become
plain stone rather than erroring.

## 3. Build and prepare

```bash
ssh root@HOST -p PORT
~/museum-import-kit/tools/setup_remote.sh          # ~10 min
mkdir -p ~/luanti/games && mv ~/mineclonia ~/luanti/games/mineclonia
~/museum-import-kit/tools/prepare_world.sh
```

`prepare_world.sh` creates the world, installs the mods, rewrites the
manifest's absolute paths to point at the archive's new location, boots
once to generate `map_meta.txt`, and writes the mapgen settings into it.

## 4. Run it

```bash
screen -dmS import env \
  LUANTI_BIN=$HOME/luanti/bin/luantiserver \
  IMPORT_CONF=$HOME/museum-import-kit/tools/import.conf \
  $HOME/museum-import-kit/tools/supervise.sh \
  $HOME/luanti/worlds/2b2t-museum /tmp/fullimport.log 205 300
```

Watch it:

```bash
tail -f /tmp/fullimport.log | grep -E "progress:|done\. Placed|ALL DONE"
```

The supervisor restarts the server through Luanti's SQLite abort, resuming
from the registry (a base is recorded only once fully placed). It gives up
only after three consecutive attempts with no progress.

Expect **14–20 hours** and a world around 13–15 GB.

## 5. Consider leveldb

`setup_remote.sh` builds with leveldb support. If you want to avoid the
SQLite abort entirely, set `backend = leveldb` in the world's `world.mt`
**before the first import run** (you cannot switch a populated world by
editing this). The workload is write-heavy enough that it may also be
faster. The supervisor stays useful either way.

## 6. Bring it home

```bash
# on the instance
cd ~/luanti/worlds && tar -c 2b2t-museum | zstd -3 -T0 -o museum.tar.zst

# on your Mac
rsync -avP -e "ssh -p PORT" root@HOST:~/luanti/worlds/museum.tar.zst .
tar --use-compress-program=unzstd -xf museum.tar.zst
```

Put the extracted world wherever you want it and symlink it into
`~/Library/Application Support/minetest/worlds/`.

To browse it you also need, in your `minetest.conf`:

```
secure.enable_security = false
spawnimport_lua_import_path = /path/to/museum-import-kit/lua_import/
```

Both are required because `museumwarp` reads its warp data through
`spawnimport`, which needs filesystem access to load its chunk decoder.

## 7. Verify before trusting it

```bash
grep -c "done\. Placed" /tmp/fullimport.log        # should be 205
grep "chunk(s) skipped" /tmp/fullimport.log | grep -v "(0 chunk"
```

Only **Space Valkyria III** should report skips (~7,138 chunks of pre-1.18
legacy format mixed into an otherwise-modern capture — about 2% of that
base). Any other base reporting skips is worth investigating.

Then in-game: `/warp list` should show 205, and warps should land you
inside a build rather than in empty terrain — warp targets are computed
from each base's densest cluster of containers and signs.

## Gotchas that cost hours locally

- **`mcl_singlenode_mapgen = false` must sit BEFORE `[end_of_params]`** in
  `map_meta.txt`. Settings after that marker are silently ignored. Worth a
  23× speedup on pre-generation (178.7 s → 7.6 s per base-sized volume).
- **Never set `mapgen_limit = 0`.** It stops mapgen overwriting imports,
  but also stops the server ever sending those blocks to a client, and the
  world renders as empty sky.
- **Don't skip pre-generation.** A VoxelManip write doesn't mark blocks
  generated; ungenerated blocks are both regenerated over *and* never sent
  to clients.
- **Watch your storage.** Every corruption locally came from a flaky USB
  cable. On a rented box the equivalent risk is the instance being
  reclaimed — snapshot or download the world once it finishes rather than
  leaving it there.
