# PLAN — fast build: measure, speed up and parallelise the full import

**Date:** 2026-10-16 · **Status: IN PROGRESS (owner go-ahead 2026-10-27, merges
reviewed and approved). Branch `fastbuild` off `main`. Phase 0 underway:**
0.1 committed, 0.2 done (Mineclonia pinned, one engine patch), 0.3 done
(`mods/spawnimport/prof.lua` + hooks; G1 green), 0.4–0.8 next.
Updated the same day after reviewing branch `vps-full-import-fixes` (§1.3).
That branch is now on `main` (`8a2db18`, plus the conf fix `6ab8723`), and
line numbers here are `main`'s. Owner decision 2026-10-16: the VPS that runs
FriedcakeSMP is the play server. It no longer builds; the world is built on a
temporary box and copied to it (Phase E5, F).

This plan replaces the "rent a big box and run it as-is" idea. The server log
of the 32-base run (`fullimport.log`, repo root, untracked) shows that a
bigger box alone helps little. The import runs one base at a time on one Lua
thread, and three quarters of the time goes into one function family, the
terrain merge writer. The plan has three stages, each useful on its own:

| Stage | What | Full 208-base build (estimate) |
|---|---|---|
| today | one process, as run on the server | ~10–12 days without swapping; the 32-base run took 98.5 h of server time |
| **A** | code speedups in the hot paths, output unchanged | ~5–6 days, one process |
| **B** | many bases at once, one Luanti process per base, merged into one world | ~11 h, bounded by the End bases' single jobs (Space Valkyria III alone is ~9.7 h) |
| **C** | split the biggest bases into tiles that run in parallel | **~3–6 h** on a 48–96-core box |

All times are in "reference-server core time", taken from the log. The
reference server's CPU model isn't known here. A modern 4.5 GHz core is
probably faster, and Phase E measures by how much before anything is rented
for the full run. Stage A's speedup factors are targets until Phase 0 measures
them. The B and C numbers come from a schedule model (Appendix B) fed with
those targets.

---

## 1. What the server log shows

`fullimport.log`, 30,286 lines, 2026-10-09 08:52 → 2026-10-14 11:06.

| | |
|---|---|
| server runs (restarts) | 19 runs, 98.5 h of server time |
| bases finished | 32; 29 have complete timings for their last attempt |
| useful work (last attempts) | 69.1 h |
| lost to repeated attempts | ~29 h. SquidBase was started 11 times and Expedition Orion 5 times. A base only counts once it is fully placed, so each crash redid the whole base. |
| crash cause | silent (no error line). SquidBase died three times at "widen round 2 start" with the Lua heap at ~2 GB; it had grown from 455 MB to 2,257 MB in one solve. That is consistent with running out of memory. The branch (§1.3) found the End/nether cause too: the 3-D blend never closed its VoxelManips. |
| heap and merge speed | the last run (10-12 02:54 → 10-14 11:06) was one process with the same code throughout. From x0XP to Lichtenburg ~3.5 GB stayed live and merge entries took 5.3–7.3 s; placement took mostly 0.3–0.56 s per chunk. From CreamOFtheSlops on, the heap was 0.5–1 GB and they took ~1.0 s and ~0.15 s. Swap was in use during the slow stretch. §2.5 has the numbers. |
| longest single server step | 1,801 s (the 500k base merge plan) |
| emerge threads | one (`Emerge-0` only): pre-generation ran on a single thread. Luanti 5.17 uses one thread for every mapgen except singlenode, because of an unfinished-slice bug (`emerge.cpp:181–187`, issue #9357). |
| loot | **13 of the 32 bases never got a loot pass in this log** (no `stage 3 done` line), including all 12 imported last. The pass started mid-batch with the 20 bases placed by then, and the shutdown test compared those 20 with `museum_target_bases`, so that boot's target was at most 20. It shut down after `ALL DONE - looted 20 base(s)`. Endhaven's loot scan alone ran 19.7 h, alongside the imports. Check `/museumloot status` on that world before anyone plays it. |

### 1.1 Where the time went (29 bases, last attempts)

| phase | hours | share | unit cost with a small heap (≤ 1 GB, no swapping) |
|---|---:|---:|---|
| **merge writes** (write + regrow of each merge chunk) | 51.4 | **74.4%** | 0.95–1.05 s per entry; 2 entries per merge chunk |
| captured-chunk placement | 7.1 | 10.2% | 0.12–0.16 s per chunk |
| pre-generation (Mineclonia mapgen) | 6.0 | 8.7% | 0.36–0.50 s per 80³ mapchunk, 1 thread |
| merge plan (field solve + widening) | 3.8 | 5.5% | 170–1,800 s per base, as one blocking step |
| gap-fill audit | 0.5 | 0.8% | |
| loot + mobs | 0.3 | 0.4% | |

Example, Ravenholm 2018 (2,878 chunks): pre-generation 543 s, placement
~350 s, plan 215 s, then 2,281 s of merge writes for an 819-chunk merge domain,
and a 36 s audit.

Projected to all 208 bases with these unit costs (ring sizes computed from the
real footprints, End bases from their measured times): **about 240 h ≈ 10
days** in one process without swapping. The README's "about a month on the
deployment server" matches the 32-base run once the crash loops and swapping
are counted.

### 1.2 Corrections to my earlier advice (2026-10-16)

- **Tick pacing gives nothing on this server.** The log shows
  `steplen=0.05`, and every chunk already takes longer than one tick, so no
  tick sits idle. I'm dropping that suggestion.
- **The "8x cap" is gone.** It assumed bases can't be split. Stage C splits
  the big ones.

### 1.3 Branch `vps-full-import-fixes` (reviewed 2026-10-16)

One commit, `8a2db18`, on top of `main` (`9d58d10`), so it fast-forwards. It
changes 15 files and none of the files modified in the working tree. It brings
the server agent's fixes into git, which §2.5 said were missing, plus the
10-15 loot and portal changes.

| change | verdict |
|---|---|
| `wgen_blend3d.lua`: close both VoxelManips per chunk; reuse four job-scoped `get_data` buffers | Correct. This was the End/nether out-of-memory cause. Checked: no code reads a reused buffer by length or keeps it past its chunk. |
| `wgen_write.lua` and the `gap_fill.lua` scan reuse buffers the same way | Correct. This is the buffer part of A6/A7. |
| full `collectgarbage("collect")` after every merge write and regrow (`wgen_write.lua:419`, `:512`), every 3-D blend chunk (`wgen_blend3d.lua:607`, `:648`), every 128 plan scans and before each solve | Safe. But each one walks the whole live heap, twice per merge chunk. See A10. |
| `gap_fill.lua`: drop the previous round's field at round start; heap log lines | Safe: `last_field` is set again (`:917`) before the round can exit. SquidBase finished after this change. |
| `museumloot`: 160³ tiles; loot only after all target bases are placed; `looted` saved in the registry; `museumloot_force_reloot` | The tiles fix the 10-15 "chests are empty" report (containers in unloaded blocks were never found). The saved flag stops the re-loot on every boot (Phase B listed it). Problems below. |
| `museumportals`: nether portals teleport again (owner 2026-10-15); End gateways stay gated | Matches Mineclonia `5bdce566f` (`mcl_portals:portal`, `object_teleport_allowed(obj)`). |
| `prepare_world.sh`: v7 settings and seed in `map_meta.txt`, only the 4 runtime mods, manifest copied after the first boot, port 30001 | Good. It replaces my E3 remark that the script still writes singlenode. |
| `rewrite_manifest_paths.py` (footprints too), `supervise.sh` (fresh world), `regen_footprints_full.sh`, `build_library_index.py` | Fine. |

**Fixed in `6ab8723` (2026-10-16).** `tools/import.conf` was the server's
loot-only re-run conf, committed as it was:
1. `museumloot_force_reloot = true`. With it, `already_looted()` is always
   false. After each full pass, the next globalstep starts the pass again, and
   the shutdown check never passes. The server re-loots every base forever and
   never exits. If the server runs with it now, stop it after one full pass.
2. `museum_target_bases = 0`. The batch then places nothing, and both the loot
   start and the shutdown test `n >= 0`. A fresh world shuts down on its first
   globalstep. `prepare_world.sh` writes 208, so this only bites when the
   committed file is used as it is.
3. `port = 30000`. The import ran on 30001 (log line 13), because FriedcakeSMP
   holds 30000 on that box.

**Smaller issues:**
- **The loot start depends on a count.** It waits for
  `n >= museum_target_bases`. But a manifest entry that fails to start is
  skipped and never registered (`init.lua:2724`). Then loot never starts and
  the server never exits. Phase B's change fixes this: start loot when the
  batch is finished (spawnimport logs `batch complete`, `:2735`).
- **Signs in big bases.** The loot sign search runs after all tiles
  (`museumloot/init.lua:1265`). `find_nodes_in_area` reads unloaded blocks as
  `ignore` (Luanti `map.h:245`), and the server unloads them after 5 s. So
  signs near containers in early tiles are missed, and those chests get
  fallback loot instead of sign-themed loot. A later pass can't repair that,
  because it only fills empty containers. Fix: `core.load_area(near_min,
  near_max)` before the search. Filling chests is safe, because metadata
  access reloads the block (`map.cpp:494`).
- **The gallery fill will skip frames with the 5 s timeout.**
  `place_frames_worldmod.lua:32–45` emerges, then reads with `get_node`. This
  bug skipped 34 frames on 09-24 (`microtest.conf:61–66`). Run the gallery
  with a long timeout, or add `load_area`.
- **Mob dedup can't see stored mobs.** `mobplacement.lua:370` looks for
  existing mobs with `get_objects_in_area`, which only sees active objects. In
  a headless run no block is active, so a repeated mob pass spawns duplicates.
  Every mob pass in this log spawned 0 mobs, so the 32-base world isn't
  affected.
- `last_gap` (`init.lua:2191`) now also keeps the previous job's buffers
  alive. A9 still applies.
- **Seed.** It is now in two more files, `tools/import.conf` and
  `world_template/map_meta_settings.txt`. It was already public on `main`.
  See Phase F.
- The session summary's "3–4 days" counts pre-generation and placement only.
  It leaves out the merge writes (74%), so it agrees with §1's ~10 days.
- **The server's build lacks both patches,** per the summary: Luanti runs
  without the engine patch (merge rings got stock, biome-unfiltered
  decoration), and `setup_remote.sh` skipped the `mcl_maps` patch until the
  agent applied it by hand. E3 makes both hard checks.
- **FriedcakeSMP shares the box,** per the summary
  (`/srv/museum/luanti/worlds/FriedcakeSMP`, UDP 30000). See §9.6.

**Done (owner OK 2026-10-16):** `main` was fast-forwarded to `8a2db18`, then
`6ab8723` fixed the three lines. The file now equals what `prepare_world.sh`
writes with its defaults. Neither commit is pushed yet. Phase 0.1 is down to
one diff of the server's live `worldmods/` against `main`.

---

## 2. Why the code is slow (hot paths, with line numbers)

### 2.1 Merge writer, 74% of the time — `mods/spawnimport/wgen_write.lua`

- `write.place_chunk` (`:195`) reads a VoxelManip one node past the chunk on
  every side (`:204`), at full height `GAP_Y_MIN..GAP_Y_MAX` = −130..319. The
  border exists only so seam columns can read the neighbouring captured
  column (`seam_materials`).
- 206 of the 208 manifest anchors are off the 16-node mapblock grid; 203 of
  them are exactly 8 nodes off on X (`(dest_anchor_x − origin_x) mod 16 = 8`,
  aligned on Z). So that VM covers **2×3
  mapblock columns × 29 blocks ≈ 174 mapblocks**. It loads all of them into
  Lua twice (`get_data`, `get_param2_data`), writes all of them back, and
  relights all of them (`write_to_map(true)`, `:415`), to change one 16×16
  column, about 24–29 mapblocks.
- `write.grow_chunk` (`:425`) restores non-merge columns with a
  string-keyed lookup per column (`plan.by_key[sx .. "," .. sz]`, `:497`) and
  keeps two full copies of its VM data (reused buffers since the branch).
- Since the branch, both functions end with a full `collectgarbage("collect")`
  (`:419`, `:512`). A full collection walks the whole live heap, so its cost
  grows with heap size, and it runs twice per merge chunk. Its share isn't
  measured yet (0.3).

### 2.2 Merge plan, 5.5% — `gap_fill.lua` / `gap_field.lua`

- The solver (`gap_field.solve`, `:305`) runs up to 120 sweeps × 3 solves ×
  up to 7 widening rounds. In every sweep each column parses its own string
  key with a pattern match (`parse_key`, `:87`). That is not JIT-compiled, so
  the whole loop falls back to the interpreter. Each column also builds four
  neighbour keys by string concatenation (`field.key`, `:35`).
- All per-column state lives in tables keyed by strings like `"x,z"`. That is
  where SquidBase's 1.8 GB jump within one widen round came from.

### 2.3 Captured-chunk placement, 10% — `init.lua`, `lua_import/`

- `palette.resolve_detailed(name, props)` runs **for every non-air block**
  (`init.lua:1238`), although a section has at most a few dozen distinct
  palette entries. Each call does pattern matches and allocates a result
  table (`palette.lua:1213`).
- The VM write loop runs `bn[i]:match("^(mcl_doors:.-)_b_(%d)$")` on every
  block (`init.lua:1516`). That pattern match is not JIT-compiled, so the
  whole loop runs in the interpreter.
- Kelp, seagrass, tall plants and gateways each build a position table keyed
  by `bx .. "," .. by .. "," .. bz` over **all** blocks of the chunk
  (`:1364`, `:1391`, `:1425`, `:1451`). That is up to ~90k strings per pass,
  and up to four passes per chunk in ocean or grassland chunks.
- The 8-node offset doubles this VM too: 2 mapblock columns instead of 1.

### 2.4 Pre-generation, 9% here, ~22% across the whole corpus

- This is Mineclonia's own mapgen; we must not change it, because the play
  server has to generate identical terrain. Its `register_on_generated` work
  (`mcl_mapgen_core/api.lua:16`) copies the whole mapgen VM into Lua and runs
  Lua generators. That runs on the server's main Lua state, so extra emerge
  threads inside **one** process help little. Luanti also keeps v7 on one
  emerge thread unless forced (§1). Separate processes do help.
- The pre-generated box is the base's bbox ±128 nodes (RING 2 + 6 widening
  rings, `init.lua:851`), full height.

### 2.5 Memory

- `last_gap = { job = self, plan = self.gap_plan }` (`init.lua:2191`) keeps
  the previous base's whole job and plan alive until the next base finishes.
  Since the branch, that includes the job's reused VM buffers.
- **Something else held ~3 GB for ten bases.** Each plan's first solve starts
  with a full collection, and the heap logged right after it was 3.5–4.1 GB
  for ten bases in a row (500k base → Lichtenburg). It then fell to
  0.5–1.0 GB from CreamOFtheSlops on, with no restart in between. `last_gap`
  is replaced at every base, so it can't hold a block that size for ten bases.
  The cause is unknown; 0.3 adds a heap census to find it.
- **Merge speed followed the live heap** in that one process:

  | bases (last run) | heap after the first solve | merge, s per entry |
  |---|---:|---:|
  | SquidBase | 2.1–2.3 GB | 4.8 |
  | x0XP → Lichtenburg (11 bases) | 2.9–4.1 GB | 5.3–7.3 |
  | CreamOFtheSlops → New M (8 bases) | 0.5–1.0 GB | 0.95–1.05 |

  Two causes fit: swapping (the heap grew to ~2x its live size between
  collections, up to 7.9 GB on a 7.8 GB box), or the full collections in the
  merge loop, whose cost grows with the heap. 0.3 tells them apart. Either
  way, a small heap is worth up to ~6x on merge writes.
- The server agent's memory fix and "lua heap" log lines are now in git, on
  `vps-full-import-fixes` (§1.3).

---

## 3. Design of the parallel build (stages B and C)

### 3.1 Jobs

A **job** is one short-lived `luantiserver` process running on its own small
world directory. Every job world uses the same `map_meta.txt` as the master
world, so it has the same seed and mapgen settings and generates the same
terrain. There are three job types:

| job | does | used for |
|---|---|---|
| `FULL` | pre-generation, placement, merge, audit, registry entry, then loot pass 1 and pass 2 | every base that isn't split |
| `TILE` | pre-generation and placement of the captured chunks inside one set of whole mapchunks; no merge, no registry, no loot; writes a tile-state file | the biggest bases (stage C) |
| `MERGE` | the merge only (the existing `spawnimport_gap_only` path), plus the tile-state files, then finish, registry and loot | the second half of a split base |

### 3.2 Block sets, seeding and harvesting

Every job has a block set **S**: all mapblocks of the 80-node mapchunks that
its pre-generation box touches, at full pre-generation height, plus a
one-mapblock shell around that box. The shell is where mapgen spills trees.

- **Seed:** before a job starts, the orchestrator copies master's blocks in S
  into the job's fresh `map.sqlite`.
- **Harvest:** after a job succeeds, every block of S in the job database is
  written back into master in one transaction.
- **Unexpected writes:** any block outside S in the job database is listed.
  Known globals, such as the spawn platform at (0,150,0), are dropped. Anything
  else fails the job.

The unit is **whole mapchunks** because of an engine rule I checked in the
Luanti source. When mapgen runs, it regenerates the whole mapchunk and writes
back every block in it (`servermap.cpp:291`). Terrain only fills nodes that are
still empty (`mapgen_v7.cpp:544`), but biomes, caves and ores change the
existing ones. If master ever held part of a mapchunk with placed content, a
later emerge would regenerate that mapchunk over the content. That is the
"25.97% integrity" accident in `HANDOVER.md`. So master only ever receives
whole mapchunks.

### 3.3 Order and dependencies

Bases get one fixed global **order**. Within a split base, its tiles come
before its merge job. Job *j* waits for job *i* when *i* comes earlier in the
order and their S sets overlap. The one exception is the tiles of the same
base, which don't wait for each other (see §3.5).

The result is the same world as a one-at-a-time build in that order. Every job
sees exactly the neighbours a serial run would have finished before it, and
nothing that comes after it. Jobs whose S sets don't overlap never touch the
same block, so it doesn't matter when they run. This needs no change to the
merge logic, including how it avoids already-placed bases.

**The order (owner decision §9.2):** colour the conflict graph with a greedy
colouring, biggest merge first. That gave 6 colours with the current layout.
Then order colour by colour, biggest base first within a colour. Bases of one
colour never conflict, so they all run at once. The model puts the longest
chain of dependent merges at **2.4 h with this order, against 3.3 h for plain
biggest-first**. It is *not* the manifest order the owner has walked so far,
so gap strips between neighbours come out different (equal quality, different
blocks).

### 3.4 What gets merged into master at the end

| item | how |
|---|---|
| map blocks | harvests (above) |
| `spawnimport` registry (`placed_bases`) | union of every job's own entry, sorted by manifest index; done with a small `luajit` helper, since the value is a `core.serialize` string |
| `mcl_maps/*.tga` | union. Import textures are `imported_<base>_<id>`, unique per base. Gallery textures are written once, at the end. |
| `museum_gateways.json` | from the last End job. Both End bases share the main-island blocks, so they run one after the other. |
| village POIs (`mcl_villages`: `village_pois`, an AreaStore string) | union of every job's store, built by a one-shot merge worldmod and written into master's `mod_storage.sqlite`. Without this, imported villagers lose their beds and job sites. |
| other game mod storage (`mcl_levelgen` stronghold cache, `mcl_weather`, `mobs_mc`, `mcl_redstone`, `mcl_raids`, `awards`, `mcl_init`) | copied from one job; they are seed-derived or world-global. `mcl_end` comes from the End job. |
| `env_meta.txt` | `lbm_introduction_times` checked identical across jobs (all `~0` today); `game_time` = the maximum over jobs, so no block's timestamp is in the future |

### 3.5 Splitting a big base (stage C)

- **Tiles are sets of whole mapchunk columns.** A captured chunk is placed by
  every tile whose mapchunks it touches. Each tile harvests only its own
  mapchunks, so a chunk that straddles a tile line is written identically from
  both sides. Records with a position (warp-interest cells, gateways, mob
  counts per mapblock) are kept only inside the tile's own area, so nothing is
  counted twice. This works with the current 8-node offset. Alignment (A5)
  only makes it cheaper.
- **The rim tile:** every mapchunk column that reaches outside the bbox goes
  into one tile, generated by one process. That makes the outer margin, where
  untouched natural terrain survives, seamless.
- **Tile lines inside the bbox** cross captured columns, which are cleared top
  to bottom and rewritten, or the merge ring, which is rewritten and replanted.
  A tree mapgen spills across a tile line can therefore only survive cut in a
  hole farther than the merge ring from any captured chunk. That is rare;
  gate G5 counts them.
- **Tile-state file** (`fastbuild_tile_<base>_<n>.json`), read by the merge
  job:
  - empty captured chunks, End empty chunks and gateways (the lists `new_job`
    and `place_one_chunk` keep: `empty_captured`, `end_empty`, `gateways`);
  - warp-interest cells and y range of placed content (`interest`,
    `result_bbox`);
  - counters: placed chunks and blocks, skipped chunks, repaired doors,
    activated spawners, frames, mobs, maps (`any_content`, `doors_repaired`,
    `spawners_activated`, `frames_placed`, `mobs_placed`, `maps_rendered`,
    `broken_map_frames`, `placed_chunks`, `placed_blocks`, `skipped_chunks`).
- **Villager names** come from a per-base list that advances in placement
  order (`init.lua:2032`). Tiles would restart that list, so a split base
  takes each villager's name from a hash of its position instead. Bases that
  aren't split keep today's names exactly.
- **First candidates:**
  - **End bases first:** Space Valkyria III (~9 h of pre-generation in the
    log) and Endhaven. End islands have almost nothing to spill.
  - **Then the overworld:** La Rosa, Eastmarch, Acheron, Veritas, SquidBase.

---

## 4. Work plan

Each step lists files, the change, and the gate that proves it. Branch:
`fastbuild` off `main`.

### Phase 0 — sync, measure, tooling (≈1 session; nothing rented yet)

**0.1 Bring the server's changes home.** Mostly done: the branch
`vps-full-import-fixes` is on `main` (§1.3). Left: diff the server's live
`/srv/museum/luanti/worlds/2b2t-museum/worldmods/{spawnimport,museumloot,museumwarp,museumportals}`
and run conf against `main`, to confirm nothing else diverged. Also still
uncommitted in the working tree, to commit before the `fastbuild` branch:
- modified: 11 docs and `import_tools/micro_rebuild.sh`;
- untracked: `PLAN-seasons.md`, this file, `import_tools/conf/`,
  `import_tools/engine_patches/` and `fullimport.log`.

**0.2 Pin versions.**
- Mineclonia `5bdce566f` plus the `mcl_maps` headless patch.
- Luanti `5.17.0` plus the engine patch.

The two copies of the engine patch differ only by a `.gitignore` hunk; keep
one. `tools/setup_remote.sh` currently clones Mineclonia HEAD. Add
`MINECLONIA_REF` and make the script fail when the checkout differs.
**Done 2026-10-27:** the `game_patches/` copy is kept (with the extra
`.gitignore` hunk folded in), `engine_patches/` is gone; `setup_remote.sh`
has `MINECLONIA_REF` (default `5bdce566f`) and hard-fails on a mismatch.

**0.3 Profiling counters in spawnimport.** New file
`mods/spawnimport/prof.lua`, about 60 lines: `prof.add(phase, microseconds)`
and `prof.dump(job)`. With `spawnimport_profile = true`, each base logs one
line at finish:

```
[prof] <base>: decode_nbt= resolve= post_blocks= vm_read= vm_fill= vm_write= liquids=
  meta= entities= scan= solve= w_read= w_cols= w_write= g_read= g_deco= g_restore=
  g_write= audit= heap_peak_mb= rss_peak_mb=
```

Also log the heap at each phase boundary, as the server's agent did (via
`collectgarbage("count")`). Two additions after the branch review:
- `gc=`: the time spent in every `collectgarbage` call, so A10 can be judged.
- A heap census at each base boundary: after a full collection, count tables
  and bytes reachable from the job, the plan, `last_gap`, the registry and
  each module's file-level tables. It should name the ~3 GB block of §2.5.

**0.4 Optional LuaJIT sampling profile.** With
`spawnimport_jit_profile = <file>`, call `insecure.require("jit.p")`, start it
in `new_job` and stop it in `finish`. That gives function-level hot spots. It
is skipped silently when `jit.p` isn't installed.

**0.5 `tools/fastbuild/logphases.py`.** The log parser that produced §1:
phases per base, attempts, heap and lag peaks, and unlooted bases. It also
becomes the progress report during builds.

**0.6 Benchmark set** `manifest/museum_manifest_bench.json`:
- Ravenholm 2018: a heavy merge, 3,456 s in the log;
- Ponponheads first base 2011-08-09: small, ring-heavy, 854 s;
- Taylobase 4 (Nether): the 3-D blend path.

`tools/fastbuild/bench.sh <bin> <conf> <manifest>` builds a fresh world, runs
pass 1 and writes a JSON summary of the `[prof]` lines. Every Stage A change
is measured with it, and so is each candidate box in Phase E.

**0.7 `tools/fastbuild/blockfmt.py` and `worlddiff.py`.**
- Decode Luanti mapblock format 29: one zstd stream per block, node ids
  through each block's own name-id table, param1, param2, node metadata,
  static objects. The 5.17 schema is `blocks(x,y,z,data)` with primary key
  `(x,z,y)` (`database-sqlite3.cpp:234`).
- `worlddiff.py A B --region …` compares two worlds and reports mismatches per
  base: names, param2, meta, object counts, and light separately. It also has
  a shift mode for A5, which compares in base-relative coordinates.

**0.8 Noise baseline.** Build the micro set twice on the same machine and diff
the two worlds. This measures run-to-run noise (emerge timing, liquid flow,
mob positions, merge iteration order over string keys) so later gates have a
tolerance. If the merge itself differs between identical runs, record by how
much; FINDINGS already mentions `pairs()` churn.

### Phase A — single-process speedups

A1–A4, A6, A7 and A10 must give **identical output**: gate G2, `worlddiff` = 0
beyond the 0.8 noise. Do one change at a time, and run the bench before and
after each.

| # | change | where | expected |
|---|---|---|---|
| **A6** | **Shrink the merge-writer VM.** Compute each seam column's captured-neighbour materials at plan time with a read-only VM; the plan already reads every domain chunk read-only. Store them on the column (`col.seam_top`, `col.seam_filler`), so the write VM needs no border. Write-VM x/z = the chunk's own 16×16. Write-VM y = from the lowest rewrite bottom (`rewrite_lo`) in the chunk to the highest of: top non-air (`T`; the scan records it, carry it into the plan column), the sea surface, and surface + 1 for snow. Above that everything is already air. (Buffer reuse through `get_data(buf)` is already in the branch.) | `wgen_write.lua:195–420`, `gap_fill.lua` (plan) | largest single win: ~174 → ~10–30 mapblocks written and relit per merge chunk. **Target 3x on merge writes**, which needs A10 too; measure write, light and GC shares first (0.3). |
| A7 | Regrow pass: numeric column keys instead of `sx..","..sz`; one data copy instead of two (buffers are already reused) | `wgen_write.lua:425–513` | smaller |
| A4 | Solver key caches: per solve, build `XZ[key] = {x, z}` and `NB[key] = {k1..k4}` once and use them in `solve`, `bounds`, `violations`, `deflate_steps`, `median3` and the assembly loops in `build_plan`. Same `pairs()` traversal, same arithmetic, so same heights. | `gap_field.lua`, `gap_fill.lua` | **target 4x on the plan**, and far less garbage (the 1.8 GB peaks) |
| A1 | Resolve each section palette entry **once**. `decode_section_blocks` resolves its palette (≤ a few dozen entries) and the per-block callback gets the cached resolution. Legacy 1.12 path: memo keyed by `id*16+meta`. `resolve_detailed` is a pure function of (name, props): no randomness, no time, no position. | `anvil.lua:230`, `init.lua:1229–1253`, `legacy` path | big cut in decode cost |
| A2 | Node-name info memo for the write loop: `NODEINFO[name] = {cid, liquid, construct, door_top}`. No pattern match per block, so the loop gets JIT-compiled. | `init.lua:1497–1530` | |
| A3 | One shared integer position index per chunk, `((y−ymin)*16 + (z−zmin))*16 + (x−xmin)`, built lazily, replacing the four string-keyed `at` tables | `init.lua:1360–1460` | |
| A1–A3 together | | | **target 2.5x on placement** |
| **A5** | **Snap anchors to the mapblock grid.** New `tools/align_manifest.py` shifts `dest_anchor_*` and `dest_bbox` by `−((anchor − origin) mod 16)`; re-checks pairwise gaps and the End gateway slots; shifts `manifest/base_patches.json` (dest-space boxes and nodes) by each base's offset; checks that `verified_real_map_clusters.json` follows moved bases. Then rebuild the micro, sample20 and full manifests. | manifests, `base_patches.json` | halves placement VM work. **This moves 206 bases by up to 15 nodes (203 of them by 8), so seams differ from what the owner walked (gate G3, owner walk).** Worth doing together with biome-matched placement (M-1 in PLAN-seasons) if that comes soon. |
| A8 | Settings for build worlds: keep `num_emerge_threads = 1`. Luanti 5.17 runs v7 on one thread because of the unfinished-slice bug (§1); forcing more threads risks incomplete mapchunks, so parallelism comes from processes (B). `sqlite_synchronous = 0` in **job** worlds only, since they're disposable. Unload timeout: from each job's RAM budget, never the VPS's 5 s (§1.3), and only after the `load_area` fixes, which make any value safe. `bind_address = 127.0.0.1` and a unique `port` per job | job conf template | |
| A9 | Stop holding the previous base in memory: drop `last_gap` unless `spawnimport_keep_last_gap = true` (only needed for `/worldplace gapaudit`), and remove whatever holds the ~3 GB block once the 0.3 census names it | `init.lua:2191` | removes the swap problem in single-process runs; up to ~6x on merge writes in the worst stretch of the last run (§2.5) |
| A10 | GC policy: replace the per-chunk full collections (`wgen_write.lua:419`, `:512`, `wgen_blend3d.lua:607`, `:648`) with a threshold: collect only when the heap has grown by more than N MB (start with 256) since the last full collection. Keep the buffer reuse. GC timing can't change results, so G2 must show no difference. | `wgen_write.lua`, `wgen_blend3d.lua`, `gap_fill.lua` | depends on `gc=` from 0.3; at a 0.5–1 GB heap, two full collections per merge chunk may be a large part of the ~1 s |

After Phase A, a serial run, `micro_rebuild.sh` or the server's existing
supervisor, is already about **2x faster overall**. That's a useful stopping
point if the parallel work waits.

### Phase B — parallel builder `tools/fastbuild/` (≈2 sessions)

| file | job |
|---|---|
| `plan.py` | Reads the manifest and footprints. Computes each base's pre-generation box, mapchunk set and S, the conflict graph, the colouring and order, the jobs and dependency edges, and a RAM class per job (from footprint size and merge-domain estimate, then corrected with measured peaks). Writes `plan.json`; `--dry-run` prints the critical path. |
| `mapdb.py` | `seed(master, job, S)` and `harvest(job, master, S)` with `ATTACH` and range `INSERT … SELECT` in C (no Python per row). Master in WAL mode; the orchestrator is its only writer; one harvest at a time. Also `outside(job, S)` for the unexpected-write check, and `integrity(db)`. |
| `jobworld.py` | Makes a job world: `world.mt` (sqlite3 backends, exactly the four worldmods), master's `map_meta.txt`, a one-base `museum_manifest.json`, `base_patches.json`, `museum_gateways.json` (End jobs), and seeded `map.sqlite` and `mod_storage.sqlite` (registry = every base already in master, so the merge avoids them exactly as in a serial run). Writes the job conf. |
| `run.py` | The scheduler. Worker slots plus a RAM budget; job states (pending → seeding → pass1 → pass2 → checking → harvesting → done/failed); up to 2 retries on a fresh copy of the seed; resumable `state.json`; a log directory per job; a progress line every 60 s; `stop-after-current` on SIGUSR1. Job check: exit code, a `[fastbuild] job done` marker, the audit line PASS, and no unexpected writes. |
| `assemble.py` | Everything in §3.4, then the gallery, removal of `museumloot`, integrity checks, and the `GUIDE-vps.md` §4 checklist. Writes `assemble_report.json`. |
| `regmerge.lua` | `luajit` helper: loads `core.serialize` registry strings and writes the merged one |
| `merge_pois/` | Throw-away worldmod that unions `village_pois` AreaStores and writes them to a file for `assemble.py` |

**Mod changes, small and setting-gated, defaults unchanged:**

- `museumloot`:
  - The branch saves `looted = true` in each registry entry, so bases seeded
    from master that are already looted get skipped. `regmerge.lua` must keep
    that field. `museumloot_only_manifest = true` (loot only the bases in this
    run's manifest) stays as a safety net.
  - Start loot when spawnimport's batch is finished, and shut down when every
    base in this run's manifest is looted. spawnimport sets a flag where it
    logs `batch complete` (`init.lua:2735`) or stops at its limit. Today both
    the loot start and the shutdown compare a count with
    `museum_target_bases` (`museumloot/init.lua:2195`, `:2210`). That hangs
    when an entry fails to start, and stops early when the target is too low
    (§1.3, and the 13 unlooted bases in §1). Fix it for serial runs as well.
  - Make the re-loot override one-shot: a setting
    `museumloot_reloot_generation = N`, and each entry stores the generation
    it was looted at. The pass then ends and the shutdown works.
  - Call `core.load_area` before the sign search in `finish()` (`:1265`).
- `spawnimport`:
  - `fastbuild_mode = tile|merge` and `fastbuild_tile = {mapchunk list}` on
    the manifest entry.
    - Tile mode filters the cursor list to chunks touching the tile and
      pre-generates only the tile. It adds no merge entries, writes no registry
      entry, and writes the tile-state file.
    - Merge mode uses the `GAP_ONLY` path, reads the tile states, and runs
      finish and registry as today.
  - Write `fastbuild_frames_<base>.json` when frames are placed (position,
    param2, item, map id, node). The gallery then reads those files instead of
    loading every base's whole bbox in one process. Today that survey is
    another memory risk, since it emerges each full bbox under the gallery
    conf's 3600 s unload timeout; with a short timeout it skips frames
    instead (§1.3). Gate: the frame list must equal the survey's on sample20.
  - A line `[fastbuild] job done <base>` at the very end, for the job check.

### Phase C — split big bases (≈1–2 sessions)

- `plan.py` picks bases whose single job would exceed half of the target wall
  time, splits them into a rim tile plus k×k-mapchunk interior tiles, and adds
  a MERGE job per split base.
- Space Valkyria III and Endhaven first (End: no trees, void stays void),
  then the overworld five.
- The tile-state file and the villager-name hash as in §3.5.

### Phase D — gates (on the box or the Mac)

| gate | what passes |
|---|---|
| G1 | `luajit mods/spawnimport/gap_field_test.lua` and `mods/spawnimport/test_harness.lua` green |
| G2 | for A1–A4, A6, A7, A10: micro set before and after, `worlddiff` with no node/param2/meta differences beyond the 0.8 noise; light differences listed and explained; the bench shows the speedup |
| G3 | for A5: sample20 aligned, every audit line PASS with seam mismatches 0, and the **owner walks** the seam list from `FINDINGS-2026-10-06-…` (coordinates shifted) |
| G4 | for B: sample20 built one-at-a-time in the B order against sample20 built in parallel (8 workers). `worlddiff` over every base's S: no differences beyond noise. Registry entries equal (except `placed_at`), same loot and mob counts per base, same gateways and POIs. |
| G5 | for C: sample20 with 3 bases force-split into small tiles against the unsplit G4 world. Only villager names on split bases and natural columns in holes at tile lines may differ; both are counted and reported; owner walk. |
| G6 | full build: 208 registry entries; **every base looted** (`logphases.py` reports none unlooted); every audit PASS; no unexpected writes; SQLite integrity `ok`; gallery placed with the unmirror marker written once; `worldmods/` ends as `museumportals`, `museumwarp`, `spawnimport`; coconut `mapart_scan.py --no-exempt` reviewed |

### Phase E — the temporary build server

**Requirements:**
- Ubuntu 24.04 x86_64;
- ≥ 48 physical cores at ≥ 4 GHz boost (the work is Lua, single-threaded per
  job);
- ≥ 4 GiB RAM per job slot (merge jobs of big bases need several GB; the
  scheduler enforces a RAM budget);
- 300–400 GB of SSD at ≥ 10k IOPS;
- billed by the hour, with an API.

| candidate (list prices seen 2026-10) | cores | RAM | price |
|---|---|---|---|
| **AWS m8a.24xlarge** (AMD Turin, 4.5 GHz, 1 vCPU = 1 physical core) | 96 | 384 GiB | ~$5.84/h on-demand (us-east-1); spot ~$1.75/h |
| AWS c8a.24xlarge (same CPU) | 96 | 192 GiB | ~$5.17/h; enough only if measured job RAM ≤ 2 GiB on average |
| Hetzner CCX63 (dedicated vCPU, SMT) | 48 vCPU = 24 cores | 192 GB | ~€1.37/h |

A full run of ~6 h, plus ~3 h of setup and checks, on m8a.24xlarge is about
$55; validation on a small box adds ~$20.

**E1 Pick the instance type with data.** Run the Phase 0 bench for 15 minutes
on the reference server, on m8a.2xlarge (or c8a.2xlarge) and on a Hetzner
CCX33. Compare cost per merge entry and per chunk, then decide. The reference
server is now the play server, so run its bench at a quiet time, on another
port.

**E2 `tools/fastbuild/provision/{aws,hetzner}.sh`.** Wrappers around the
provider CLI that print the IP, write an SSH config entry and tag the box. For
example (check AMI and flags at the time):

```
aws ec2 run-instances --instance-type m8a.24xlarge \
  --image-id resolve:ssm:/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id \
  --key-name museum-build --security-group-ids <ssh-from-your-ip-only> \
  --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=400,VolumeType=gp3,Iops=16000,Throughput=1000,DeleteOnTermination=true}' \
  --instance-initiated-shutdown-behavior terminate \
  --user-data file://tools/fastbuild/cloud-init.yaml

tools/fastbuild/provision/hetzner.sh create --type ccx63 \
  --user-data tools/fastbuild/cloud-init.yaml
```

The Hetzner wrapper exists (2026-10-17). It calls the Cloud API with curl and
`HETZNER_API_KEY`, so no `hcloud` CLI is needed. It also has `types` (specs
and hourly prices, read-only), `list`, `status` and `delete` (Phase G; it
also removes the uploaded SSH key).

**Run it from the VPS, not the Mac** (owner 2026-10-17). The token is set in
`/home/dara/.bashrc` there. Run it from an interactive shell or tmux, because
Ubuntu's `.bashrc` returns early in non-interactive shells such as
`ssh vps 'cmd'`. Then the VPS holds the build box's SSH key, so E5 can pull
the world with `rsync` from the VPS, and the build box needs no key for the
VPS.

**E3 `tools/fastbuild/bootstrap.sh`** (idempotent; for this purpose it
replaces `prepare_world.sh`, which the branch fixed to write v7):
- Packages, then Luanti 5.17.0 plus the engine patch, built server-only.
  **Fail unless `luantiserver --version` reports LuaJIT**, and check that the
  Lua heap can grow past 2 GB (GC64). The server's build could: its log shows
  7.9 GB. **Fail at the first boot unless
  `core.generate_decorations_with_inputs` exists.** The VPS build lacks it,
  so its merge rings got biome-unfiltered decoration (§1.3).
- Mineclonia at the pinned commit plus the `mcl_maps` patch; fail on any
  other commit, and fail if the patch isn't applied (`setup_remote.sh`
  skipped it on the VPS).
- Kit by `rsync` from the Mac at a recorded commit, so no deploy key is
  needed.
- WDL archive: `git clone --depth 1` from GitHub, ~13 GB.
- `museum-maparts/output/` **with all three pools**. The gallery uses
  `final`, `wiki` and `mapartindex`, ~150 MB; GUIDE-vps still says `final`
  only.
- Footprints: regenerate in parallel. The branch's
  `tools/regen_footprints_full.sh` writes the job list, then runs it
  serially; feed that list to `xargs -P$(nproc)` instead. Compare a sample of
  hashes against the Mac copies (2.2 GB), or rsync them from the Mac.
- Manifest paths rewritten; check that every `source_region_dir` and
  `footprint_path` exists.
- Template world: boot once, check `mg_name = v7`, the seed and the
  `mgv7_*` block in `map_meta.txt`. The seed comes from a file outside the
  repo (Phase F, seed).
- Swap off (a job running out of memory must fail fast and be retried, not
  thrash).

**E4 Run.**
1. On the box: sample20 one-at-a-time and in parallel at the same time (gate
   G4).
2. Then `fastbuild run --workers <cores−4> --ram-gb <RAM−16> plan.json` in
   tmux.
3. `logphases.py` progress every minute, and `assemble.py` at the end (gate
   G6).

The orchestrator is resumable, so spot instances are fine for validation runs
as long as the data volume survives.

**E5 Package and ship straight to the play server**, which is the VPS that
runs FriedcakeSMP (owner 2026-10-16).
- Before the build: check `df -h /srv` on the VPS. It needs room for the
  staged archive plus the unpacked world. No backup is needed: nothing has
  been played there, and the owner had both of its worlds deleted
  (2026-10-18).
- `tar | zstd -T0 -3`.
- On the VPS, `rsync -P` from the build box into a staging directory there,
  using the build box's SSH config entry that `hetzner.sh create` wrote. The
  build box never gets a key for the VPS. Compare checksums. FriedcakeSMP
  keeps running during the copy.
- Also put one copy in object storage (S3 or a Hetzner Storage Box) before
  the box goes away.
- Install: move the new world into place and start FriedcakeSMP on it. No
  player data carries over. Check one warp per dimension.

### Phase F — the play server (with FriedcakeSMP from `../coconut`)

The play server is the VPS: the box that ran the 32-base import and already
runs FriedcakeSMP on UDP 30000, with 7.8 GB RAM plus 8 GB swap. It no longer
builds. Owner 2026-10-18: both of its worlds, `2b2t-museum` (the 32-base test
import) and `FriedcakeSMP`, are test worlds and get deleted without a backup.
FriedcakeSMP stays stopped until the new build arrives. Keep each world's
`world.mt` and any non-map config for the Phase F setup.

First, on the VPS:
- **Stop the old import server** if it still runs. With the re-loot flag it
  never exits (§1.3), and it takes RAM from the play server.
- **Record the versions:** `luantiserver --version`, and
  `git -C /srv/museum/luanti/games/mineclonia rev-parse HEAD` plus its patch
  state. `setup_remote.sh` cloned Mineclonia HEAD, so it may not be the Mac's
  `5bdce566f`. Pick one commit for the build box and the VPS, and check that
  coconut's mods work with it.

Same items as in my earlier review:
- **Same versions as the build.** The play server must run the same Luanti
  5.17.0 and the same Mineclonia commit. Otherwise terrain generated later,
  past the pre-built area, won't line up. The engine patch only adds a Lua
  API (plus a client-side fullbright switch) and doesn't change mapgen, so
  the VPS's unpatched Luanti is fine for play.
- **Mods:**
  - Install `spawnimport`, `museumwarp`, `museumportals` and the friedcake
    modpack. Leave `museumloot` out.
  - **Blocker:** turn off the privilege grant in `museumwarp`
    (`init.lua:305`): every joining player gets `give`, `fly`, `noclip`,
    `teleport` and `settime`. Gate it behind a setting such as
    `museumwarp_grant_explore_privs`, defaulting to true for the museum
    client.
  - Decide the `/warp` clash with `smp_tp`.
- **World settings:**
  - Set `creative_mode` and `enable_damage` for an SMP.
  - Keep mod security on, with `secure.trusted_mods = spawnimport,smp_store`.
  - Put `smp_store` data in its own database.
  - Start with fresh `auth` and `players` data (nothing carries over).
- **Content check:** run coconut's mapart scan on the build box before
  shipping.

New after the branch review:
- **Nether portals now teleport** (`museumportals`, owner 2026-10-15).
  Mineclonia picks the nether target from the portal's own position and
  builds a portal there when it finds none. Check where portals from a few
  museum bases land, and that those auto-built portals don't cut into nether
  exhibits.
- **Seed.** coconut's `smp_world` forbids showing players the current
  season's seed (`INTEGRATION-museum-import-kit.md`, "Seed secrecy"). The
  museum seed is in this public repo: `prepare_world.sh`, `GUIDE-vps.md` and
  the handoffs on `main`, plus `tools/import.conf` and
  `world_template/map_meta_settings.txt` on the branch. If this build becomes
  a season world, it needs a fresh seed that is never committed. The
  fast-build scripts read it from a file outside the repo.

### Phase G — teardown

- Terminate the instance or `hcloud server delete`, and delete leftover
  volumes, snapshots, IPs, the key pair and the security group.
- Remove the temporary SSH key from the play server.
- Record the cost.

---

## 5. Order of work and what each step buys

| step | effort | result if we stop here |
|---|---|---|
| Phase 0 | 1 session | real profile numbers; the branch merged; loot-gap fix; unit costs per box |
| A6 + A4 + A9 + A10 | 1 session | merge ~3x and plan ~4x faster, no swap risk: about 2x overall, serial |
| A1–A3 | 0.5 session | placement ~2.5x faster |
| A5 | 0.5 session + owner walk | placement VM halved; new seam walk |
| B | 2 sessions | about 11 h for all 208 bases on a 16+-core box |
| C | 1–2 sessions | about 3–6 h on 48–96 cores |
| E–G | 1 session + build time | world on the play server, box gone |

---

## 6. Risks

- **Different build order.** The world equals a one-at-a-time build in the
  new order, not the manifest order the owner walked. Gap strips between
  neighbours change. G4 proves the equivalence; the owner walk judges the
  look.
- **Alignment (A5)** moves 206 bases by up to 15 nodes. Seams change, and the
  dest-space base patches must move with their bases.
- **Lighting after A6** is recomputed over a smaller area. The engine's VM
  lighting is supposed to fix neighbours too; G2 compares light and lists any
  differences.
- **Village POI merge** (§3.4). If it's wrong, villagers lose their beds and
  job sites. G4 checks a village base, e.g. Fort Alcazar.
- **Tile lines (C)** can leave a cut tree in holes deep inside a split base.
  G5 counts them.
- **Memory per job** is unknown until measured. The scheduler's RAM budget
  plus a fast failure and retry (swap off) contain it.
- **Version drift** (Mineclonia HEAD) breaks blocks silently. Bootstrap
  enforces the pinned commit.
- **Short unload timeouts break reads silently.** `find_nodes_in_area` and
  `get_node` read unloaded blocks as `ignore`, and nothing reports it. The VPS
  runs with 5 s. Loot discovery is fixed by the branch's tiles; the sign
  search and the gallery fill are still exposed (§1.3). Every such read gets
  a `load_area` first, and G6 counts frames and themed chests.
- **Pass 2 now runs per base, before later neighbours exist.** Loot and mobs
  stay inside the bbox; only structure detection near a bbox edge could read
  a strip a later neighbour rewrites. That is minor; G4 compares loot counts.

## 7. What stays the same

`micro_rebuild.sh` stays the reference serial path, and every gate compares
against it. All the merge, loot and placement behaviour the owner has walked
stays unchanged, except A5 (moves bases) and the build order (B/C). All
Mineclonia mapgen settings stay the same.

## 8. Not doing (considered)

- **Moving the import into mapgen-environment scripts or `core.handle_async`
  decoding.** That means rewriting the most-debugged code (metadata, entities
  and containers need the main thread), for less gain than separate processes.
- **Changing or skipping Mineclonia mapgen.** The play server must generate
  identical terrain beyond the pre-built area.
- **One shared "mapgen farm" for the whole world.** Mapchunk borders between
  farm workers would leave cut trees in untouched terrain everywhere, not just
  in rare holes.

## 9. Owner decisions needed

1. **Alignment (A5):** OK to move every base by up to 15 nodes (8 for 204 of
   them) and re-walk seams? Or postpone it to the biome-matched re-pack?
2. **Build order:** colour order (fastest) instead of manifest order?
3. **Box:** AWS m8a.24xlarge (fastest), Hetzner CCX63 (cheapest), or decide
   after the E1 bench?
4. **The VPS:** please share `lscpu`, `free -g` and `df -h /srv`. The CPU
   is the baseline for the E1 bench, and the disk must fit the new world
   (E5). The diff against its live `worldmods/` is one command (0.1).
5. ~~The 32-base world: rerun loot?~~ Moot: the new build replaces that
   world. Only stop the old import server if it still runs (Phase F).
6. **Play server:** decided 2026-10-16: the VPS, receiving the world built
   elsewhere. Decided 2026-10-18: no player data carries over and no
   downtime window is needed. Both VPS worlds are test worlds and are
   deleted.
7. ~~Branch `vps-full-import-fixes`~~: done 2026-10-16 (`8a2db18` +
   `6ab8723` on `main`; not pushed yet).

---

## Appendix A — unit costs used

All from `fullimport.log`, bases with a small heap (≤ 1 GB) and no swapping:

| unit | cost |
|---|---|
| pre-generation | 0.43 s per mapchunk (80³); one emerge thread |
| placement | 0.15 s per captured chunk |
| merge plan | 0.20 s per merge entry |
| merge write | 1.0 s per merge entry |
| audit | 0.02 s per merge entry |
| loot | 0.01 s per captured chunk |

- Merge entries ≈ 3.1 × the ring size, where ring = chunks within 2 of a
  captured chunk; this ratio is measured over the 29 bases.
- End bases use their measured totals: Space Valkyria III 32,231 s
  pre-generation, 38,986 s job; Endhaven 6,218 s and 8,124 s.
- Corpus: 936,029 captured chunks (footprints within `chunk_bounds`) and
  169,527 ring chunks.

## Appendix B — schedule model

List scheduling over the job DAG of §3.3, longest-path priority:
- tiles of ≤600 mapchunks;
- Stage A speedups of 2.5x placement, 4x plan, 3x merge (targets);
- pre-generation unchanged.

| | 1 worker | 16 | 32–96 |
|---|---:|---:|---:|
| no code speedups, bases not split | 239 h | 17.9 h | 17.9 h |
| no code speedups, big bases split | — | 15.0 h | 10.9 h |
| Stage A, bases not split | 129 h | 10.7 h | 10.7 h |
| Stage A, big bases split | — | 8.1 h | **5.5 h** (2.4 h longest merge chain with colour order) |
