# Running the 2b2t museum import on a dedicated VPS

End-to-end guide for a fresh Debian (or Ubuntu) box with a sudo user.
Everything except the maparts is cloned from public remotes by the setup
script -- no rsync of the 13 GB archive from the Mac.

| what | remote | notes |
|---|---|---|
| museum-import-kit | `git@github.com:aprajnaparamita/museum-import-kit.git` | private; needs a read-only deploy key |
| 2b2t WDL archive | `https://github.com/TwinkNet/2b2tmuseum-WDL.git` | ~13 GB, the long step |
| mineclonia | `https://codeberg.org/mineclonia/mineclonia.git` | + 1 small headless patch (see "The two patches") |
| luanti | `https://github.com/luanti-org/luanti` tag `5.17.0` | + museum engine patch |
| maparts | **scp only** | 121 PNGs, `~/dev/museum-maparts/output/final/` on the Mac |

Everything lives under one private root, default **`/srv/museum`** (mode
700, owned by the sudo user -- nothing world-readable, nothing runs as
root). The deploy key is read-only and stays on the box.

## Read this before a full run (2026-09-28)

The scripts below predate the nether/End 3-D merge, the End gateways and the
mapart unmirror. As of 2026-09-28 they have five problems. Any one of them
gives a broken world with no obvious error. Fix or work around all five
first. The verified reference is `import_tools/micro_rebuild.sh`, the
Mac run the owner has walked in-game. Match its run order: pass 1
(import, merge, loot), pass 2 (convergence), mapart gallery pass, then
strip `museumloot`. Background is in `SESSION_2026-09-27_SUMMARY.md`.

1. **Mapgen must be v7, not singlenode.** `prepare_world.sh` writes
   `mg_name = singlenode`. Singlenode generates no terrain, so every base
   would float in void with nothing to merge into. The verified worlds use
   `mg_name = v7`, `mcl_singlenode_mapgen = false`,
   `seed = 16532709774040603227` (also `fixed_map_seed` in the conf),
   `water_level = 1`, `chunksize = 5` and
   `mgv7_spflags = mountains, ridges, nofloatlands, caverns`. Under v7,
   Mineclonia's bands are nether −29067 and End −27073, which are the
   manifest's `dest_y_offset` values. spawnimport logs
   `<name>: <dim> band, dest_y_offset N` for each nether/End job and logs
   an ERROR on a mismatch. End jobs log band + 14 on purpose (the
   island-top lift).
2. **Footprints are not in git.** They're `.gitignore`d and regenerable
   (1–170 MB each). Without its footprint, a base gets **no merge**: no
   error, just hard chunk edges. The manifest's `footprint_path` values
   also point at the Mac (`/Volumes/Dara/dev/museum-import-kit/...`), and
   `rewrite_manifest_paths.py` only rewrites the archive paths. For every
   entry, run
   `luajit import_tools/placement_fit/source_footprint.lua <source_region_dir> <footprints/same-name.json> [nether]`
   (pass `nether` for nether entries only), then repoint `footprint_path`.
   Check that every `source_region_dir` and `footprint_path` exists before
   starting.
3. **Install exactly four mods.** `prepare_world.sh` copies all of `mods/`,
   including `fullimport`. `museumloot` also drives the batch: it starts
   `/museumimport`, loots each base and shuts down. Install only
   `spawnimport`, `museumloot`, `museumwarp` and `museumportals`, as
   `micro_rebuild.sh` does, and check that `supervise.sh`'s resume still
   works with `museumloot` as the driver. `museum_target_bases` = number
   of manifest entries (208).
4. **Run the mapart gallery pass.** Besides filling empty frames, it
   reverses real multi-map walls (`unmirror_real_map_walls`). Imported
   bases are north-south mirror images because z isn't negated, so
   without this pass every multi-map picture shows its tiles in reversed
   order. Its art library path is hardcoded to `~/dev/museum-maparts/output`
   (`build_library_index.py`); symlink it to
   `/srv/museum/museum-maparts/output`. Run it like `micro_rebuild.sh`:
   `GALLERY_LUANTI_BIN`, `GALLERY_LUANTI_CONF` pointing at a conf **without**
   `museum_manifest_path`, and a large `GALLERY_RUN_TIMEOUT` (e.g. 14400).
   Reset `used_pieces_registry.json` to `{}` first. The pass writes
   `<world>/mapart_unmirrored.txt`; never unmirror one world twice.
5. **Strip `museumloot` at the end** (`rm -r <world>/worldmods/museumloot`),
   or opening the world restarts the batch.

A ready-made prompt for handing this run to an agent is in
"Agent prompt" at the end of this file.

## Sizing

The job is **CPU-bound on single-core performance** (Lua chunk decoding);
GPU is irrelevant. Expect **14–20 hours** for the full 208-base import and
a world of ~13–15 GB. Disk: archive 13 GB + world ~15 GB + build ~3 GB +
maparts ~0.5 GB → **60 GB free** is comfortable. NVMe strongly preferred.

## 0. Deploy key (only because the kit repo is private)

`setup_remote.sh` generates a dedicated ed25519 key at
`/srv/museum/.ssh/museum_deploy_ed25519` and prints the public key. Add
it on GitHub → repo Settings → Deploy keys, **read-only**.

## 1. Bootstrap

```bash
# clone the kit first (it carries the setup script + patches)
sudo mkdir -p /srv/museum && sudo chown "$USER" /srv/museum
git clone git@github.com:aprajnaparamita/museum-import-kit.git /srv/museum/museum-import-kit
# (if the deploy key isn't set up yet, the script below generates one and
#  clones the kit itself -- both flows work)

sudo MUSEUM_ROOT=/srv/museum /srv/museum/museum-import-kit/tools/setup_remote.sh
```

The script: installs build packages, clones the archive / mineclonia /
luanti `5.17.0`, applies both museum patches, builds a **server-only**
Luanti (with leveldb), and locks `$MUSEUM_ROOT` to mode 700.

## 2. Maparts (the only copy step)

From the Mac:

```bash
scp -r ~/dev/museum-maparts/output/final VPS:/srv/museum/museum-maparts/output/
```

121 pre-quantized map-sized PNGs (`<piece>_<row>_<col>.png`). Only needed
for the mapart gallery fill (chore: the gallery tooling still has its own
pending migration, see `BRIEF-2026-09-26.md` §6.3). The gallery fill
respects `GALLERY_LUANTI_BIN` / `GALLERY_LUANTI_CONF` env overrides so it
can run against the VPS build + conf.

## 3. Prepare and run

```bash
# as the regular user, no sudo
/srv/museum/museum-import-kit/tools/prepare_world.sh

screen -dmS import env \
  LUANTI_BIN=/srv/museum/luanti/bin/luantiserver \
  IMPORT_CONF=/srv/museum/museum-import-kit/tools/import.conf \
  /srv/museum/museum-import-kit/tools/supervise.sh \
  /srv/museum/luanti/worlds/2b2t-museum /tmp/fullimport.log 208 300
```

`prepare_world.sh` creates the world, installs the worldmods, rewrites
the manifest's stored source paths to the archive location, boots once to
generate `map_meta.txt`, and writes the mapgen settings into it.

Watch it:

```bash
tail -f /tmp/fullimport.log | grep -E "progress:|done\. Placed|ALL DONE"
```

The supervisor restarts the server through Luanti's SQLite abort, resuming
from the registry (a base is recorded only once fully placed). It gives up
only after three consecutive attempts with no progress. To avoid the
SQLite abort entirely, set `backend = leveldb` in the world's `world.mt`
**before the first import run** (you cannot switch a populated world).

## 4. Verify before trusting it

```bash
grep -c "done\. Placed" /tmp/fullimport.log        # should be 208
grep "chunk(s) skipped" /tmp/fullimport.log | grep -v "(0 chunk"
```

Only **Space Valkyria III** should report skips (~7,138 pre-1.18 legacy
chunks mixed into an otherwise-modern capture, ~2% of that base). Any
other base reporting skips is worth investigating.

Then in-game: `/warp list` should show all bases and warps should land
inside builds, not empty terrain (warp targets come from each base's
densest cluster of containers and signs).

Also check (2026-09-28):

- one `[gap-fill] audit <name>:` line per base, none FAIL. For nether/End
  bases the line reads `3-D blend ... seam voxel mismatches 0 -- PASS`;
- no `is not this world's band` errors;
- `museumloot` reaches `ALL DONE - looted`;
- `<world>/museum_gateways.json` links each End base to a different
  main-island slot;
- the gallery log shows placements and `real-map wall group ... reversing`
  lines;
- `worldmods/` ends up as `museumportals`, `museumwarp`, `spawnimport`.

## 5. Bring it home

```bash
# on the VPS
cd /srv/museum/luanti/worlds && tar -c 2b2t-museum | zstd -3 -T0 -o museum.tar.zst

# on the Mac
rsync -avP VPS:/srv/museum/luanti/worlds/museum.tar.zst .
tar --use-compress-program=unzstd -xf museum.tar.zst
```

Symlink the extracted world into `~/Library/Application Support/minetest/worlds/`.
To browse it you also need in `minetest.conf`:

```
secure.enable_security = false
spawnimport_lua_import_path = /path/to/museum-import-kit/lua_import/
```

Both are required because `museumwarp` reads its warp data through
`spawnimport`, which needs filesystem access to load its chunk decoder.

## The two patches (not the same thing -- easy to conflate)

1. **`mcl_maps-load_map-headless.patch`** (mineclonia, `mods/ITEMS/mcl_maps/init.lua`)
   -- a **game-mod** fix, needed on the server. With zero players
   connected, `dynamic_add_media`'s callback never fires, so mcl_itemframes
   retries `update_entity` every step and spawns a NEW display entity each
   time. Observed during the 2026-09-25 museum import: one mapblock with
   50 map frames ended up with **50,050 entities**. Still unfixed upstream
   (checked `mineclonia/mineclonia@main`) -- `setup_remote.sh` applies it
   and warns loudly if it ever stops applying. `SKIP_MCL_MAPS_PATCH=1`
   opts out (e.g. after upstream merges it).
2. **`luanti-5.17.0-museum-import.patch`** (engine) -- two unrelated
   things in one patch file: `core.generate_decorations_with_inputs` in
   `l_mapgen` (server-side; gap-fill places trees/plants on merged terrain
   with it -- the code degrades gracefully without it, merged areas just
   lose decoration), and client-side extensions (`set_fullbright`,
   `send_interact` -- the fullbright/xray client-mod API). The client
   hunks are inert in a server-only build; they matter only for the Mac
   client.

## Security notes

- `$MUSEUM_ROOT` is mode 700, owned by the sudo user; the run happens as
  that user, never root.
- The only credential on the box is the **read-only deploy key** for the
  private kit repo.
- Recommended: `ufw allow OpenSSH && ufw enable`, key-only `sshd`
  (`PasswordAuthentication no`), `unattended-upgrades` for a box that
  will sit unattended for a day-long import.
- **Back the finished world off the box** (step 5) rather than leaving it
  as the only copy.

## Gotchas that cost hours locally

- **Mapgen settings must sit BEFORE `[end_of_params]`** in
  `map_meta.txt`. Settings after that marker are silently ignored.
  (`mcl_singlenode_mapgen = false` there once gave a 23× pre-generation
  speedup on the old singlenode setup; the world must now be v7, see
  "Read this before a full run".)
- **Never set `mapgen_limit = 0`.** It stops mapgen overwriting imports,
  but also stops the server ever sending those blocks to a client, and the
  world renders as empty sky.
- **Don't skip pre-generation.** A VoxelManip write doesn't mark blocks
  generated; ungenerated blocks are both regenerated over *and* never sent
  to clients.
- **Mineclonia version drift is silent.** The palette maps to exact node
  names; if a node vanishes, blocks become plain stone instead of erroring.
  That is why the setup clones a known Mineclonia rather than whatever
  ships with a Luanti release.

## Agent prompt

Paste this to hand the full run to a fresh coding agent on the server.
Adjust the paths if the root isn't `/srv/museum`.

````
You are running the full 2b2t museum import on a dedicated Linux server.
Everything lives under /srv/museum:
  - kit:      /srv/museum/museum-import-kit   (git repo, main branch)
  - Luanti:   already built and configured; confirm the server binary and the
              Mineclonia game path yourself (GUIDE-vps.md expects
              /srv/museum/luanti/bin/luantiserver and
              /srv/museum/luanti/games/mineclonia)
  - archive:  the 2b2t WDL corpus (expected at /srv/museum/2b2tmuseum-WDL)
  - maparts:  /srv/museum/museum-maparts/output/final (121 PNGs)
Goal: import every base in manifest/museum_manifest_full.json into one fresh
world, with the nether/End 3-D merge, loot, mapart gallery and End gateways,
exactly as import_tools/micro_rebuild.sh does on the Mac. That run is the
one verified in-game.

Read first, in this order:
  1. GUIDE-vps.md, especially "Read this before a full run": five problems in
     the server scripts that you MUST fix or work around before starting
     (mapgen v7 not singlenode; regenerate footprints and repoint
     footprint_path; install exactly spawnimport/museumloot/museumwarp/
     museumportals; run the mapart gallery pass; strip museumloot at the end)
  2. SESSION_2026-09-27_SUMMARY.md (current state, and why)
  3. import_tools/micro_rebuild.sh (the verified run order)
  4. HANDOFF.md, only the top section
Don't re-run package installs or rebuild Luanti if they already work; check
first. Never guess Mineclonia node/item names; grep the game source.

Run under screen/tmux (expect 14-20 h). Before starting, confirm that every
source_region_dir and footprint_path in the world's manifest exists, and
that map_meta.txt says mg_name = v7.

Verify before calling it done, and report the numbers, using the checklist
in GUIDE-vps.md section 4 ("Verify before trusting it").

Rules:
  - Don't commit or push unless asked. Keep script changes small and list
    them at the end, so they can be committed back to the kit.
  - Don't delete or overwrite anything outside the new world directory
    without asking.
  - If something fails, investigate the logs and the code before re-running;
    don't just retry.
````
