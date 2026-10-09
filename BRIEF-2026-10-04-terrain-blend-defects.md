# BRIEF — terrain blending defects: upside down pyramid & cutecurly's City

**Date:** 2026-10-04 · **Repo:** `/Volumes/Dara/dev/museum-import-kit` · **Status:** diagnosis + fix requested, nothing committed

You are taking over a Minecraft→Luanti (Mineclonia) museum import kit. Two overworld
bases show square, unblended terrain edges in the deployed test world. Find the root
cause, fix it, and prove it. This brief tells you where the code is, what the owner
reported, which measurement blind spots to distrust, and which invariants you may not
break.

---

## 1. What this project does

The kit downloads real 2b2t bases (WorldTools `.mca` regions), imports them into a
Luanti world, and then **blends the generated Mineclonia terrain around them** so a
player walking out of a base doesn't hit a wall at a chunk boundary.

- Kit root: `/Volumes/Dara/dev/museum-import-kit`
- Test world (live): `~/Library/Application Support/minetest/worlds/2b2t Museum TEST`
- Staging world: `/Users/dara/dev/museum-microtest` (rebuild target; deploy copies it over the live world)
- Engine: `$HOME/dev/luanti/bin/luanti` (5.17.0) · game `mineclonia`
- Manifest of what gets built: `manifest/museum_manifest_sample20.json` (20 bases)
- Every base's destination geometry (anchor, `dest_bbox`, `chunk_bounds`,
  `footprint_path`) is in that manifest — read it, it is the source of truth.

**Latest successful build (2026-10-03 09:13) is deployed and green.** The two defects
below are the *next* round of work; they are not build failures.

---

## 2. Read before you touch anything

| file | why |
|---|---|
| `FEATURE-gap-fill-blend.md` | the blend algorithm, the audit, tuning knobs, **known limitations** |
| `FEATURE-gap-fill-mapgen.md` | why the ring is post-processed generation rather than raw levelgen |
| `HANDOFF.md` / `HANDOVER.md` | environment map, hard-won facts (e.g. the −61 sea-level offset) |
| `mods/spawnimport/README.md` | mod internals |
| `mods/spawnimport/gap_fill.lua` | **the 2-D merge — this is where your bug lives** |
| `mods/spawnimport/gap_field.lua` | the height-field solver (`solve`, `violations`, `deflate_steps`) |
| `mods/spawnimport/wgen_inputs.lua` | per-column targets fed into the field |

> ⚠️ `FEATURE-gap-fill-blend.md` says `gap_fill.MAX_EXTRA_RINGS = 3`; the code says
> `6` (`gap_fill.lua:373`). The doc is stale — trust the code.

### Which blend path runs where

`mods/spawnimport/init.lua:2314` picks the path with `blend3d.band(self)`:

- **`"end"` / `"nether"` → `wgen_blend3d.build_plan`** (3-D blend). Recently changed —
  see §7.
- **overworld → `gap_fill.build_plan`** (2-D merge). Both bases in this brief are
  `dimension_type = overworld`, so **you are in the 2-D path**.

---

## 3. What the owner reported (verbatim)

### Issue 1 — no blending where snow/dirt meet ocean and ice
> "The terrain generation is not blending mineclonia terrain into the world download
> terrain correctly. Snow and dirt meet ocean and ice, there is no blending on these
> edges, the block types change immediately leading to perfect square edges — such as
> **6567, 11183**.
> **What should happen:** terrain blocks below water should blend with the water/ice
> level, also blending."

### Issue 2 — mountains do not descend to the blended sea level
> "Mountains do not properly descend fully to the blended chunk sea level, whether ice
> or water — which both should be treated equally, with ice meeting ice and water
> meeting water. Below the water line similarly the terrain should blend and the sea
> floor should meet sea floor at a similar level.
> Example at **6648, 10830** where there is a steep square cliff wall which does not
> descend over the blend all the way properly. Another edge of that is at **6648,
> 10846** and **6632, 10830**. Another is at **6664, 10846**, another at **6696,
> 11008** and **6664, 11862** and **6680, 11008**, and **6696, 10960**, and **6712,
> 10960** and **6712, 10910**. Another is at **6584, 11152** and **6616, 1152**.
> In these examples the highest block at the border does not descend to the level of
> the matching chunk and match the same biome/block types.
> **What should happen:** there should be a smooth blend with similar block heights.
> It shouldn't be obvious to a player they are crossing a chunk boundary."

### Issue 3 — desert cliff faces at cutecurly's City
> "There are cliff faces in a desert biome which do not similarly blend. For example at
> **-10328, 8671** where there is an 18 block high cliff at right angles, **-10296,
> 8671**, **-10296, 8687**, **-10280, 8687**, and another at **-10248, 8735**,
> **-10232, 8735**, **-10232, 8751**, **-10212, 8751**, another at **-10216, 8767**,
> another at **-10135, 8831**, **-10136, 8963**, **-10136, 8991**."

> **⚠️ The owner noted: "the coordinates here were taken by hand and may not be
> accurate within 1 block."** Treat them as search centres, not exact cells.

### Coordinates resolved against the manifest

**`upside down pyramid 2013-01-25`** (index 2, overworld, `dest_y_offset = -61`,
`dest_bbox` x 6232..6727, z 10720..11183, footprint
`import_tools/placement_fit/footprints/upside_down_pyramid_2013_01_25_1774235327089.json`)

- inside `dest_bbox`: 6567/11183 · 6648/10830 · 6648/10846 · 6632/10830 · 6664/10846 ·
  6696/11008 · 6680/11008 · 6696/10960 · 6712/10960 · 6712/10910 · 6584/11152
- **outside** `dest_bbox` (i.e. in the merge ring, or a typo): `6664, 11862` (z is 679
  blocks past `z_max` — likely `11062`/`10862`) and `6616, 1152` (z is 968 short of
  `z_min` — likely `11152`, matching its partner `6584, 11152`)

**`cutecurly's City`** (index 14, overworld, `dest_y_offset = -61`,
`dest_bbox` x -11208..-10185, z 8448..9247, footprint
`import_tools/placement_fit/footprints/cutecurly_s_City.json`)

- inside `dest_bbox`: -10328/8671 · -10296/8671 · -10296/8687 · -10280/8687 ·
  -10248/8735 · -10232/8735 · -10232/8751 · -10212/8751 · -10216/8767
- **outside** `dest_bbox` (east edge, ~49 blocks → merge ring): -10135/8831 ·
  -10136/8963 · -10136/8991

### Critical geometry fact before you start

**The blend seam is the footprint edge (`real` = chunks that actually contain captured
content), NOT the `dest_bbox` edge.** For Krobar the `dest_bbox` was 4096 chunks but
`real` was only 90. Load each base's `footprint_path` JSON to get the real chunk set,
then map every reported coordinate to its distance from *that* boundary. Coordinates
"inside the bbox" are usually sitting on the footprint edge; coordinates outside it are
in the merge ring.

---

## 4. Where to suspect (hypotheses to test — do not treat as conclusions)

`FEATURE-gap-fill-blend.md` documents three limitations that match the symptoms
almost word for word. Verify each one against real data before believing it:

1. **"Surface MATERIAL is not matched at the seam (height + biome tint only) — the ring
   keeps its natural material (grass/sand/…)."**
   This is the leading candidate for Issue 1 (snow/dirt changing to ocean/ice in one
   block) and Issue 3 (desert cliff at right angles with a different material).
2. **"Land-to-water steps are sea cliffs and sea floor relief and are not counted at
   all."** The code agrees — `gap_fill.lua:781-789`: slope constraints apply only to
   land-to-land edges, and `aquatic` columns are re-classified and re-solved in a loop.
   **So a square snow→ice or dirt→sea-floor edge is invisible to `gap_fill.audit`.**
   Issue 2 lives exactly in this blind spot.
3. **"Cliff bases are steep but continuous … 2–4 blocks/column … deliberately
   rejected"** widening. The owner now explicitly disagrees: Issue 2 asks for the
   mountain to descend *all the way* to the blended sea level. Note the tension with
   the documented design decision — surface it in your write-up rather than silently
   changing the ramp budget.

Other leads worth checking:

- `gap_field.deflate_steps` collapses "square jogs" (`gap_fill.lua:794-798`) — does it
  run for aquatic columns at all?
- `gap_field.edge_cap(a, b, aquatic)` / `edge_ok` — how does the cap differ across the
  shoreline (`gap_field.lua:52-64`)?
- Ice vs water: the owner wants **ice meeting ice, water meeting water**. Search for
  where the surface family decides frozen vs liquid (`gap_fill.lua:452` "ice on a
  frozen sea", `gap_fill.lua:728` "straight ice/water chunk edges",
  `gap_fill.lua:1090-1094` ice special-casing in the junk audit). Is the ring's
  surface family taken from the capture, from the biome, or from generated height?
- `WATER_LEVEL` (`gap_fill.lua:91`, from `water_level` in map_meta) vs the
  `mcl_levelgen` preset's `sea_level` 63 — the comment warns they are not the same.
  Both bases use `dest_y_offset = -61`.
- `gap_fill.smooth_edge_lines` and `add_seam_tints` (`gap_fill.lua:465`, `568`) — what
  do they actually fix, and are they even reached for these bases?

### Current measured state (build 2026-10-03, from `/tmp/micro_pass1.stdout`)

```
audit upside down pyramid 2013-01-25: seam mismatches 0 (worst 0.0),
  merge slopes over cap 6576 (worst 15.0 at (727,4041)=72..(728,4041)=87 [pins:nil/nil], cap 1.5),
  natural relief steps 2015 (worst 132.0 at (783,4037)=58..(783,4038)=190),
  spilled base water blocks 0, floating junk blocks 0, floating veg 0 -- 8.00s

audit cutecurly's City: seam mismatches 0 (worst 0.0),
  merge slopes over cap 1336 (worst 7.0 at (-2385226,460893)=1..(-2385227,460893)=-6 [pins:nil/nil], cap 1.5),
  natural relief steps 1375 (worst 65.0 at (-2385153,460799)=60..(-2385153,460800)=-5),
  spilled base water blocks 0, floating junk blocks 966, floating veg 87 -- 23.43s
```

Note the coordinates in the audit are **source** coordinates, not destination — you must
offset before you can go look at them. Also note **the audit says PASS-critical items
are all 0** while the owner sees obvious defects: that is the measurement gap you are
here to close. `cutecurly's` 966 floating junk blocks and `upside down pyramid`'s
132-block "natural relief step" both deserve an explanation as part of your diagnosis.

---

## 5. How to measure (the recipe that worked last round)

### a) Mock-engine harness (fast, no server)

```
cd /Volumes/Dara/dev/museum-import-kit
tools/setup_harness_world.sh            # one-time symlink setup
luajit mods/spawnimport/test_harness.lua
```
Current baseline: **`ALL CHECKS PASSED` — 70 ok, 0 FAIL.** It must still be green when
you finish. Relevant assertions: tests 6b/6c ("End ring outer edge keeps Mineclonia's
own islands exactly", "seam exact"), and the decoration-survival check that requires
weight < 0.5 at `capture_dist >= 24`.

### b) Focused rebuild (no deploy)

Make a 2-base manifest (copy entries index 2 and 14 from
`manifest/museum_manifest_sample20.json` into `manifest/museum_manifest_two.json`), then:

```
MICRO_MANIFEST=$PWD/manifest/museum_manifest_two.json \
  ./import_tools/micro_rebuild.sh --no-deploy
```
- The script **wipes** `/Users/dara/dev/museum-microtest` every run (that's intended).
- `--continue` survives a mid-run crash but may leave a half-imported base; prefer a
  clean wipe for anything you intend to measure.
- It refuses to run while any luanti matching `$LUANTI_BIN` is up.
- It **resets `import_tools/mapart_gallery/used_pieces_registry.json` to `{}`** — run
  `git checkout -- import_tools/mapart_gallery/used_pieces_registry.json` afterwards or
  you lose the owner's gallery-variety state.
- The audit line you want prints as `[gap-fill] audit <name>: …`.

### c) In-world probe (the way to see a square edge)

Write a throwaway worldmod that emerges a window and logs per-column surface data, then
parse it in Python. Working pattern from last round:

1. **Copy** the world (never probe the live one in place — and never add the probe mod
   to the live world):
   `rsync -a "<live world>/" <tmp>/probe_world/`
2. **Move the kit worldmods out** of the copy (`spawnimport`, `museumwarp`,
   `museumportals`). `spawnimport/init.lua:30` calls
   `core.request_insecure_environment()`, which fails with the probe conf unless
   `spawnimport` is in `secure.trusted_mods` — so the probe world must contain **only**
   the `probe` worldmod.
3. Probe conf already exists at `/tmp/zprobe.conf` (it sets
   `museum_manifest_path = /nonexistent/museum_manifest.json` so museumloot's auto-kick
   never fires; `max_users = 1`, `name = probe`).
4. Run:
   ```
   luanti --server --port 31199 --gameid mineclonia --config /tmp/zprobe.conf \
     --world <tmp>/probe_world --logfile <tmp>/probe.log
   ```
5. Log `core.log("action", "[PX] …")` lines and `grep '\[PX\]' <tmp>/probe.log > out.txt`.

For this brief your probe should emit, per column over a window: **surface height,
surface node name, node name at `water_level`/ice level, and the biome** — so you can
detect (a) a height step of N blocks across a boundary, (b) a material change with no
height transition, (c) an ice/water family mismatch across the seam. Reuse the
`VoxelArea`/content-id-caching pattern from `mods/spawnimport/gap_fill.lua` and respect
VoxelManip's **150,000,000-node volume cap** (split large windows).

Reference implementations left in
`/private/var/folders/g3/gyt5_9n948bgk9d7h37nj3h40000gn/T/opencode/krobar_probe/`
(`probe4_init.lua`, `probe5_init.lua`, `coast_metric.py`) — the `coast_metric.py`
"flush at edge / longest constant run / distinct cut positions" idea generalises
directly to a **step-height and material-change metric** for these two bases. Build that
metric *first*, take a **BEFORE** reading, then fix, then take an AFTER reading.

---

## 6. Acceptance criteria (owner's words are the bar)

1. **No square edges.** Where captured terrain meets generated terrain — land, shoreline,
   or sea floor — a player must not be able to see or walk into a right-angle boundary.
   Explicitly: *"It shouldn't be obvious to a player they are crossing a chunk
   boundary."*
2. **Material continuity:** snow/dirt → ocean/ice transitions must blend rather than
   switch in one block (Issue 1); desert cliff faces must not be 18-block right-angle
   walls (Issue 3).
3. **Sea level:** mountains must descend fully to the blended sea level; the sea floor
   must meet the sea floor at a similar level (Issue 2).
4. **Ice and water are treated equally** — ice meets ice, water meets water; neither
   family is privileged over the other.
5. **Reproduce and show before/after numbers** for every reported coordinate cluster
   (and explain the two that look like typos).
6. **Harness green**, **all 20 audit lines still PASS**, `seam mismatches 0` and
   `spilled base water blocks 0` everywhere — a fix that trades a square edge for a seam
   break is not a fix.

---

## 7. Invariants you must not break

- **Player structures are never blended.** Only nodes whitelisted as terrain
  (`gap_fill.is_terrain_name`, `capture_solid`) may be written by the merge. Buildings,
  chests, redstone, signs, trees — untouched.
- **Seam exactness is PASS-critical:** merged surface vs the capture's ground must be
  exactly 0 mismatches on every base.
- **The End/Nether 3-D blend just changed** and is verified: a capture-perimeter ring
  (`blend3d.RING = 2`, `wgen_blend3d.lua:281`) plus a two-octave coastline jitter with
  taper `16*t*t*(1-t)*(1-t)` (`wgen_blend3d.lua:392`), and `init.lua` now queues every
  `plan.chunk_order` key not already in `gap_fill_chunks` (`init.lua:2316`). Measured
  effect at Krobar: flush-at-edge columns 158/155/187/189 → **0**, longest constant run
  55/33/50/71 → **4–7**, minimum cut 11 blocks. **Do not regress this**, and if your
  overworld work touches shared code, re-run the End probe.
- **Jitter amplitude is capped by the harness:** the decoration-survival check assumes
  weight < 0.5 at `capture_dist >= 24`, so the round-2 amplitude (`(noise2(x,z,23)-0.5)*20
  + (noise2(x,z,7)-0.5)*10` with the quartic taper) is the ceiling. Going larger fails
  the suite.
- **Download void chunks stay void.** Hole detection (`HOLE_MAX_CHUNKS = 24`,
  `HOLE_ENCLOSED = 0.6`) is unchanged and must stay unchanged.
- **Witches are disabled** — `WITCH_SPAWNING_ENABLED = false` in
  `mods/museumloot/mobplacement.lua`; detection code stays for possible re-enable.
  The last build logged `spawned 0 … witch(es)` for all 20 bases. Don't re-enable.
- **The −61 sea-level offset:** `OVERWORLD_Y_CORRECTION` (`init.lua:358`) and the
  manifest's `dest_y_offset` must change together. Ocean bases flood if they drift apart.

### Uncommitted work you must not lose

These three files are **modified but uncommitted** (owner is reviewing them):

```
mods/spawnimport/wgen_blend3d.lua      # End perimeter ring + coastline jitter
mods/spawnimport/init.lua              # generalised merge-chunk queue
mods/museumloot/mobplacement.lua       # WITCH_SPAWNING_ENABLED = false
```
Also dirty but unrelated to you: `FEATURE-loot.md`, `data/`.
**Do not commit anything without the owner's explicit approval.**

---

## 8. Working conventions

- **Never guess node or item names.** Look them up in the game's registered nodes first.
- **Syntax-check every Lua file you touch:**
  `luajit -e "assert(loadfile('<path>'))"`
- If you touch the palette, keep `palette.py` and `palette.lua` in sync.
- Prefer a narrow change at the right layer over a broad one; state the root cause in
  the write-up, not just the diff.
- Logs worth keeping around: `/tmp/micro_pass1.log`, `/tmp/micro_pass1.stdout`,
  `/tmp/deploy20.log`, `/tmp/micro_run.conf`.

## 9. Deploying (dangerous — last step, owner-gated)

`./import_tools/micro_rebuild.sh` **without** `--no-deploy` will:

1. `rm -rf` the entire live world `2b2t Museum TEST`, then
2. copy staging over it, restoring only `auth.txt` / `players/` from a backup.

It refuses to run while any luanti matching `$LUANTI_BIN` is up, so **the owner's client
must be closed.** Never deploy a reduced manifest — a 2-base deploy would delete the
other 18 bases. Full deploy uses `manifest/museum_manifest_sample20.json`.

## 10. Deliverables

1. **Root-cause write-up**: for each of the three issues, what actually produces the
   square edge, with the file:line responsible and a measurement that demonstrates it.
2. **Fix**, minimal and at the right layer, with the harness still 70/70.
3. **Before/after metric** for both bases (step height across the seam, material-change
   count, ice/water family mismatches) taken the same way both times.
4. **A 2-base rebuild with all audits PASS**, then the owner's sign-off before deploy.
5. Note explicitly anything you had to *change by design* rather than repair — the
   "steep but continuous" ramp budget and "material is not matched at the seam" lines
   in `FEATURE-gap-fill-blend.md` are documented decisions the owner may want revisited,
   not accidents.
