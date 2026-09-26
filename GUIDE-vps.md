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

- **`mcl_singlenode_mapgen = false` must sit BEFORE `[end_of_params]`** in
  `map_meta.txt`. Settings after that marker are silently ignored. Worth a
  23× speedup on pre-generation (178.7 s → 7.6 s per base-sized volume).
  `prepare_world.sh` handles it -- but re-check if you hand-edit the file.
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
