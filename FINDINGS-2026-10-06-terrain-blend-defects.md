# FINDINGS — terrain blend defects (BRIEF-2026-10-04)

**Date:** 2026-10-06 · **Repo:** `/Volumes/Dara/dev/museum-import-kit` · **Status: committed in `bb140d7` (2026-10-09) after owner review**
Covers Issues 1–3 of the brief, plus one secondary solver defect the fix surfaced
(the harness widening regression).

Working tree after this round (all uncommitted, do not lose):

```
mods/spawnimport/gap_field.lua     # bounds/solve/violations fixes (this round)
mods/spawnimport/gap_fill.lua      # clay whitelist + lateral guard (this round)
mods/spawnimport/gap_field_test.lua# one contract updated to written-step semantics
mods/spawnimport/init.lua          # pre-existing, owner review
mods/spawnimport/wgen_blend3d.lua  # pre-existing, owner review
mods/museumloot/mobplacement.lua   # pre-existing (witches disabled)
FEATURE-loot.md, data/             # unrelated, pre-existing
```

---

## 0. TL;DR

| issue | root cause (file:line) | fix |
|---|---|---|
| 1 — snow/dirt vs ocean/ice square edge (6567,11183) | `gap_field.bounds()` per-edge jitter *decay* accumulated over the cone → L inflated at distance; `solve` inits at L (`gap_field.lua:293`) and early-exits on free-free edges → column frozen 28 blocks above target | exact-cone bounds + bounded shared wiggle (`gap_field.lua:184-245`) |
| 2 — mountain flank never reaches blended sea level (6648,10830 …) | same decay → spurious `L>U` pinch → old midpoint init parked the flank at `(L+U)/2` ≈ 46–48 vs target ≈ 15 | exact-cone bounds; pinch init = pull target `s` (`gap_field.lua:281-299`) |
| 3 — desert right-angle cliffs (−10136,8991 …) | (a) `mcl_colorblocks:hardened_clay*` missing from `is_terrain_name`; (b) float rule `surface_from_tops` returned the floor 90–120 blocks under a thin top mass | clay prefix (`gap_fill.lua:156`) + lateral corroboration guard (`gap_field`… see §3) |
| harness 8-FAIL (found during fix) | `violations()` counted float residuals `cap+2e-6` → phantom `fixable=12` → domain 45→79 → job entries 163 > 120-tick budget | `violations()` compares **written** heights `floor(h+0.5)` (`gap_field.lua:433-455`) |

Harness: **70/70 ALL CHECKS PASSED** (after instrumentation removal).
`gap_field_test.lua`: ALL PASSED.

---

## 1. Issue 1 — "snow and dirt meet ocean and ice, no blending" (6567, 11183)

### Root cause

`gap_field.bounds()` propagated each cone edge with a jitter-reduced factor
(`×(1 − jitter·…)` per edge). Over a long path this multiplies: at capture distance the
**lower bound L drifted UP and U drifted DOWN** relative to the exact slope cone.

At pyramid source row 4239/4240 (destination z 11183/11184, the row of the owner's
6567,11183) the instrumented run measured:

```
apex column (635,4240):  h == L == 22.619768476464     height target = -6
                         U = 22.619768476464 + 2       (L>U pinch east of x634)
```

Mechanism chain:

1. decayed cone gives `L ≈ 22.62` where the exact cone floor would be ≈ target −6;
2. `solve` inits a column at `L` when `s < L` (`gap_field.lua:293-294`);
3. every free-free edge around it was already ≤ cap, so the early-exit fired on the
   first batch (`gap_field.lua:352+` — "watch FREE-FREE edges only") and the column
   never moved toward its target;
4. the ring therefore stayed ~23 blocks above the ocean surface (capture ground ≈ 2),
   and the writer painted snow/dirt ground directly against ocean/ice nodes in one
   column: the square edge the owner photographed.

### Fix

`gap_field.bounds()` (`gap_field.lua:184-245`) now:

* propagates the **exact** cones — per-edge jitter removed entirely;
* adds a bounded post-pass wiggle over FREE keys only:
  `w = step*jitter*4*(0.65*noise2(x,z,11) + 0.35*noise2(x,z,4))`, applied to **both**
  `L[key] += w; U[key] += w`.

Why both: L and U move by the same amount, so (a) L ≥ exact-cone floor always
(the pin envelope can only be preserved, never eroded), (b) no new `L>U` pinches are
created, (c) the organic-contour jitter the owner liked is kept (amplitude ≤ 1.4 blocks
at jitter 0.35). Two rejected designs are documented in the file header: `1−jitter`
re-decays (the defect itself), `1+jitter` drops the floor below the envelope and erodes
terraces (gap_field_test pin-exact edge fails).

---

## 2. Issue 2 — "mountains do not descend fully to the blended sea level" (6648,10830 …)

### Root cause

Same `bounds()` decay, different failure branch. At pyramid source row 3886
(destination z 10830 — the owner's 6648,10830):

```
x=727:  L≈86.6   U≈22.75   -> L>U pinch   h≈48.3   height target ≈ 15
```

The decayed cone from a distant mountain pin pushed L up past the (simultaneously
deflated) U: a pinch that does not exist in the exact geometry. The old code
initialized pinch columns at the midpoint `(L+U)/2`, which parked the whole flank at
≈46–48 when the truth was ≈15 — a 30+ block wall against the ring that never descends
to the blended sea level. `metric_before.txt` shows the owner's coordinates as
near-class steps of 11–66 blocks: (6648,10830) dH=11 · (6664,10846) dH=21 ·
(6696,11008) dH=66 · (6696,10960) dH=32 · (6712,10960) dH=64 · (6712,10910) dH=50 ·
(6664,11062) dH=35.

### Fix

Exact-cone bounds (§1) remove the spurious pinches; true pinches (real cliff-vs-seam
geometry) now init at `s`, the pull target (`gap_field.lua:281-299`) — the neighbour
band below is the local authority, so the flank settles at its target instead of the
average of two unusable cones.

---

## 3. Issue 3 — "cliff faces in a desert biome … 18 blocks high at right angles" (cutecurly's City)

Two independent defects, both proven against `probe_nat` (pristine mapgen control):

### (a) capture clay was not in the terrain whitelist

`is_terrain_name` (`gap_fill.lua:146-156`) whitelists which captured nodes the merge
may scan and write. `mcl_colorblocks:hardened_clay*` (the desert plateau's own mass,
orange/red/yellow variants) was missing — the plateau columns fell through the
whitelist, so the seam next to them was written against "non-terrain" and never
blended. Probe BEFORE: `(−10328,8671) mat=sand/cb:hardened_clay dH=25`,
`(−10296,8671) mat=cb:hardened_clay/sand dH=26`,
`(−10216,8767) mat=dirt_with_grass/sand dH=42`.

Fix: `if name:match("^mcl_colorblocks:hardened_clay") then return true end`
(`gap_fill.lua:156`).

### (b) float rule returned the floor under a thin mass

`surface_from_tops` (`gap_fill.lua:248-259`) treats a top run `≤ FLOAT_MAX_THICK (2)`
sitting over a gap `≥ FLOAT_MIN_GAP (3)` as floating junk and returns the **floor**
under it. On the desert plateau the top of the mass read as thin-over-gap, so `S` came
back 90–120 blocks below the visual surface. Instrumented scan of source row 460815
(destination z 8991 — the owner's −10136,8991):

```
raw T = 89..122   raw S = -5 / -6     (floor beneath the capture)
```

The plan then believed the capture surface was at −5 while a player sees 116, and the
ring was built as a right-angle wall against the phantom step: probe BEFORE
`(−10136,8991) dH=121 H=−5/116`, `(−10136,8963) dH=94`.

Fix: the scan now stores `Sbase/t1/mat_top/float` per column (`gap_fill.lua:456-470`)
and a **lateral corroboration guard** (`gap_fill.lua:686-745`) gates the float rule:
the floor answer is only kept when the *neighbourhood* says there is no real surface
there — fire only if **both**

1. none of the 4 distance-1 neighbours has `Sbase` within ±`GUARD_TOL (5)` of my raw
   top `t1`, **and**
2. fewer than `GUARD_NEED (8)` of the 16 distance-2 ring cells share my `t1` within ±5;

otherwise keep the raw top. Decisions read only `Sbase/t1` (order-independent, no
recursion). Validated offline (`guard_matrix2.py`): 0 wrong calls + island fixture 16/16.
Nether/End `surface_from_runs` path untouched; harness nephertest/endtest stayed at
45 chunks (= baseline).

---

## 4. Secondary defect found during the fix — phantom widening (harness 8-FAIL)

Symptom: after the bounds fix, `gaptest` widened 45→79 chunks (163 job entries > the
harness's `run_job_to_completion(120)` budget) → "job reported done" FAIL cascading to
8 checks; the audit itself still showed seam 0 / slopes 0.

Measured mechanism (instrumented solve/deflate/violations, one 12-column row):

* `solve`'s stall threshold (`prev_worst − worst < 1e-4`) aborts while float residuals
  sit at ~2e-6, above `violations`' eps `1e-6`;
* `deflate_steps` then splits a free-free micro-overflow (target float `12.0000029`
  vs band `11`) and pushes the free column UP → free↔soft-pin edge = `1.0000027`;
* `violations()` counted `diff > cap + 1e-6` → 12 phantom `fixable` edges → widening.

Baseline passed only by luck (tighter bounds → init ≈ equilibrium → sub-eps residuals).

Fix: `violations()` now compares the **written** heights `floor(h + 0.5)` — the exact
rounding the writer applies (`gap_field.lua:433-455`). A `1.0000027` float edge writes
as a 1-block step: there is nothing to widen. A residual on the `.5` rounding boundary
still writes as a 2-block step and still widens. After the fix: `fixable=0` round 1,
`gaptest` ring-only 90 merge chunks (= 2×45, exactly baseline), 95 job entries ≤ 120.

Consequence: `gap_field_test.lua`'s terrace contract was float-based
(`worst <= 1.5`); it now asserts `worst <= 2` (written steps) with a comment — a float
terrace residual of ≤1.5 rounds to at most a 2-block written step at a cliff whose own
relief is structural anyway.

---

## 5. Verification

* **Harness:** `luajit mods/spawnimport/test_harness.lua` → `ALL CHECKS PASSED` **70 ok**
  (final run, all `[PXD]` instrumentation removed). `gap_field_test.lua` → ALL PASSED.
* **Instrumentation:** all `[PXD]` / `pxd_*` code removed from `gap_fill.lua`
  (grep clean); no sentinel files left.
* **2-base rebuild** (`MICRO_MANIFEST=…/museum_manifest_two.json ./import_tools/micro_rebuild.sh
  --no-deploy`, exit 0, no ServerError, registry restored afterwards):

  ```
  audit upside down pyramid 2013-01-25: seam mismatches 0 (worst 0.0),
    merge slopes over cap 1681 (worst 60.0 at (740,4042)…), natural relief steps 1260 (worst 116.0),
    spilled base water blocks 0, floating junk blocks 0, floating veg 0, kelp out of water 0 -- 7.93s
  audit cutecurly's City: seam mismatches 0 (worst 0.0),
    merge slopes over cap 2094 (worst 20.0 at (-2385765,461031)…), natural relief steps 2081 (worst 39.0),
    spilled base water blocks 0, floating junk blocks 963, floating veg 83, kelp out of water 0 -- 26.34s
  ```

  PASS-critical (seam, spilled) = **0/0** on both bases. `spawned 0 … witch(es)` for both.
  Informational context vs the deployed 2026-10-03 build: pyramid merge slopes
  6576 → 1681 (worst 15 → 60), relief 2015 → 1260; cutecurly slopes 1336 → 2094
  (worst 7 → 20), relief 1375 → 2081, junk 966 → 963. These counters count
  *structural* pairs too — the capture's own cliffs and pre-existing natural relief
  that widening cannot fix by design (see §6) — and the shape of the ring changed
  with the new bounds, so which pairs land where shifted; the before/after metric
  below is the comparable measure.
* **Before/after metric:** BEFORE = `metric_before.txt` (`python3 metric.py
  probe_before.px probe_nat.px`); AFTER = `metric_after.txt` (`python3 metric.py
  probe_after.px probe_nat.px`) — same windows, same probe mod, same natural control.

  | class | before | after (round 1) |
  |---|---|---|
  | pyramid seam | pairs 1888, mean 0.32, >1 41, >3 28 | *byte-identical* (1888 / 0.32 / 41 / 28) |
  | pyramid near | mean 0.71, >1 12278, >3 2454, >8 1327, >16 995 | mean 0.49, >1 **6370**, >3 **2259**, >8 **699**, >16 **520** |
  | cut seam | pairs 3904, mean 0.28, >1 123, >3 77 | mean 0.28, >1 121, >3 77 |
  | cut near | mean 0.67, >1 18801, >3 7486, >8 4756, >16 259 | mean 0.68, >1 20845, >3 7929, >8 4862, >16 340 |

  Seam exactness unchanged (byte-identical / −2); pyramid near-class steps
  roughly halved by the widening. Cut near rose in round 1 — the bounds change
  reshaped the ring (documented in §6/§8.6); the seam class is unaffected.

### Invariants re-checked this round

| invariant | state |
|---|---|
| player structures never blended | `is_terrain_name` scope only *expanded* by the clay prefix (terrain nodes) |
| seam mismatches 0 everywhere | round-1 rebuild audit **0** both bases (block above); harness gaptest seam 0 |
| spilled base water 0 | round-1 audit **0** both bases (block above); harness 0 |
| End/Nether 3-D blend no regression | `wgen_blend3d.lua` untouched this round; harness end/nether = baseline 45 |
| jitter capped by decoration-survival | `wdl.jitter` untouched; wiggle ≤ 1.4 blocks < prior amplitude ceiling |
| hole detection unchanged | `HOLE_MAX_CHUNKS/HOLE_ENCLOSED` untouched |
| witches disabled | `WITCH_SPAWNING_ENABLED=false` untouched |
| −61 sea-level offset | untouched |

---

## 6. Changed **by design** (owner may want to revisit)

1. **Widen trigger measures written steps, not floats** (`gap_field.violations`) —
   see §4. Rationale: widening exists to prevent steps a player can *walk into*;
   sub-block float residuals cannot become one (except at the rounding boundary, which
   is still caught).
2. **One test contract updated** (`gap_field_test.lua` terrace check, §4).
3. **`bounds()` no longer applies per-edge jitter decay**; organic contour preserved
   by the shared bounded wiggle (jitter unit tests still green).
4. **Float rule is now corroboration-gated** (§3b): thin floats with lateral surface
   evidence keep the raw top instead of the floor.
5. `FEATURE-gap-fill-blend.md` lines the brief flagged remain **unchanged, pending your
   call**: the "steep but continuous 2–4 blocks/column" ramp budget was *not* widened,
   and "surface material is not matched at the seam" (height+biome tint only) was *not*
   reworked — Issue 3's material jumps were mis-detected *surfaces*, not that policy.

---

## 7. Repro commands

```bash
# harness
cd /Volumes/Dara/dev/museum-import-kit
luajit mods/spawnimport/test_harness.lua          # expect ALL CHECKS PASSED (70 ok)
luajit mods/spawnimport/gap_field_test.lua        # expect ALL GAP_FIELD TESTS PASSED

# 2-base rebuild (no deploy)
MICRO_MANIFEST=$PWD/manifest/museum_manifest_two.json \
  ./import_tools/micro_rebuild.sh --no-deploy
git checkout -- import_tools/mapart_gallery/used_pieces_registry.json

# metric (identical recipe both sides)
python3 /private/tmp/blend_diag/metric.py probe_after.px probe_nat.px \
  > /private/tmp/blend_diag/metric_after.txt
```

---

# ROUND 2 — owner's post-deploy defect report (2026-10-06 evening)

Owner playtested the deployed 2-base build and reported remaining seam defects:
snow/ice not blending, ice/water level off by one block, square/diamond contour
edges, a dried canyon/river, and a 25-step wall. BEFORE = `probe_after.px`
(the deployed round-1 build, taken 2026-10-06 08:30); AFTER = `probe_after2.px`
(identical windows, identical probe mod, identical scripts).

## 8.0 Round-2 TL;DR

| # | defect (owner coords) | root cause (file:line, post-fix refs) | fix (file:line) |
|---|---|---|---|
| A | ±1 step at every frozen seam + lid-edge water flows 1 block across the seam — 6566,11183; 6667/6583@11167; 6584@11151; flow rows z10892/10911/10912, z11062 x6664-6667 | seam height target = footprint/float-rule **sea-floor** fit (`surface_from_tops` gap_fill:248-262 returns the floor under a ≤2 float over a ≥3 gap; footprint `terrain_cols` = pre-download floor fit), but a frozen capture column's walkable surface is its **ice lid +1** — ring pinned one below → measured dH −1 ×264 / +1 ×150 of 455 | lid pass `build_plan` (gap_fill:822-849) stores per-column `r.lid` when the scan's first top is capture ice/packed/blue ice; `seam_target` (gap_fill:507-512) returns it first — feeding the field level callback (gap_fill:850-854), `seam_constraints` (gap_fill:532+), `plan.hard` and the audit automatically; land seams unchanged |
| B | snow layer on ring ice against bare capture ice — 6566,11183 ("the snow and ice does not blend"); 252× combo | `col.tsnow` = resolved snowy biome (wgen_inputs:363) paints ring snow; the only suppression (wgen_inputs:364-366) clears it for fam `grass`/`sand` at w>0.35 — never for fam `snow` (frozen seams) | capture's own snow **cover** propagated as 3rd `mat_at` return (gap_fill:865-881) through `field()` (wgen_inputs:113-121/140-145/162-165/169-171) to `col.scover` (gap_fill:1050-1055); `wgen_write` (355-364) cancels the snow add-fade where the capture top is bare — same seed/threshold as the add-fade (wgen_write:350-354), so both cancel exactly at the seam line |
| C | canyon/river dried — −10278,8733, dead-end river −10281,8783 | `height_targets` blend `w*level+(1-w)*s`: `slow_chunk` triples the fade distance, so even d=3-4 columns keep seam-level weight → submerged natural canyon bed lifted ~10 blocks to **above** sea → dry; the bounds wiggle could also re-lift a lakebed | sea cap `wgen_inputs.height_targets(…, sea)` (wgen_inputs:187,208-218): only when pristine `s < sea`, target ≤ `sea-1`; bounds skip the wiggle for submerged columns (gap_field:244-261); `sea`/`natural` threaded solve→bounds (gap_fill:950-952, gap_field:291-294); overworld-only (gap_fill:894-896) so End/Nether bands untouched |
| D | perfect 45° diamond contours — 6584,11151; 6667/6583@11167 | round-1 wiggle `step*jitter*4*(0.65*noise2(11)+0.35*noise2(4))`: local swing < 1 block over 20-30 columns → every Bellman ring survived intact | scale-29 noise at 3× amplitude `step*jitter*12*(0.75*noise2(29)+0.25*noise2(11))` (gap_field:244-261): organic swings up to ~4.2 blocks (jitter 0.35), lift-only (same w on L and U → no new pinches), slope still capped by solve's neighbour band; gap_field_test slope/jitter/pin checks green |
| E | 25-step wall at 6696,11008 | measured: capture ice H=1..2 at x≤6696 (frozen sea) hard against the piece's mountain toe H=26..30 at x≥6698 — the **capture's own cliff** truncated at its chunk border, with the single d=1 ring column between them wearing the copied ice material | *(measure after rebuild — see §8.6)* |

## 8.1 Defect A — frozen-seam ±1 step and lid-edge flow-over

**Mechanism.** For a frozen capture column the scan's first top is the ice lid
(`t1` = lid y), but `surface_from_tops` classifies `float = true` (lid ≤2 over
the water gap ≥3) and returns the **floor** — correct for building, wrong as a
*seam target*: the player walks on the lid. The footprint's `terrain_cols`
(pre-download heightmap fit) also fits the ocean floor. The ring's d=1 columns
were therefore pinned one block below the ice the owner stands on, and the
capture's open lid-edge water at lid level immediately flowed one column across
the ring (flowing water as topmost node measured at z10892 x6680-6688,
z10911 x6697-6717, z10912 x6712-6717, z11062 x6664-6667 — the owner's typo'd
6664,11862 → 6664,11062 cluster is exactly a flow row).

**Measurement BEFORE (probe_after, pyramid seam scan):**

```
seam pairs 1888 · H-mismatch 455 · fam-mismatch 584
dH dist: -1 ×264, +1 ×150 (414/455 = 91% are the ±1 step)
row example z11183/11184 at x6568: capture H=2 (ice lid) | ring H=1
```

**Fix.** `build_plan` runs a lid pass (gap_fill:822-849) over every real chunk's
scan columns: if `mat_top` is `mcl_core:ice`/`packed_ice`/`blue_ice` (terrain
whitelist), `r.lid[i] = c.t1 - dy` (source units). `seam_target` returns the lid
before the footprint edge (gap_fill:507-512). One overlay fixes all four
consumers (field level callback, seam constraints, plan.hard, audit) — the audit
still compares the same source of truth, so seam exactness is unaffected.

## 8.2 Defect B — biome snow painted on bare capture ice

**Mechanism.** `col.tsnow` (wgen_inputs:363) is true wherever the ring's
*resolved biome* is snowy, so the write paints a snow layer. The round-1
suppression (wgen_inputs:364-366) only cleared `tsnow` when the seam surface
family was `grass` or `sand` — frozen seams are family `snow`, so every ring
column next to bare capture ice got a snow layer the capture does not have:
`('ice','snow','ice','ice') ×252`, the dominant fam-mismatch combo.

**Fix.** The `mat_at` callback now also reports the capture top's actual cover —
true for `mcl_core:snow`/`snowblock`, false for ice/packed/blue ice, nil for
unknown tops (trees/builds: biome decision stays) — propagated through `field()`
into `col.scover`. `wgen_write` (355-364) suppresses the snow where the capture
is bare, using the **same** noise and threshold as the add-fade, so at a bare
snowy-fam seam the two rules cancel exactly (fade band fully bare) and a
snow-covered capture keeps its full fade.

## 8.3 Defect C (D2) — canyon and river dried

**Measurement BEFORE:**

```
natural control z8733: water_source at x -10287..-10266 (22 cols, includes -10278)
built z8733/z8734:     0 water columns anywhere in the rows (entire rows dry)
built floor at -10278,8733: H = +2..+5   natural floor: -7..-9   (lifted ~10)
z8783 river: built water x -11038..-10280 (dead-ends where the floor ramps above sea)
```

**Mechanism.** `height_targets` (wgen_inputs:187) blends the seam level with the
pristine surface `s` by distance weight `w`. `slow_chunk` triples the fade
distance, so canyon columns 3-4 chunks out still get mostly *seam-level* weight
— the target lands at/above sea and the canyon floor is lifted out of the
water; the round-1 bounds wiggle could then add up to ~1.4 more. The aquatic
classification (`is_water = h < SEA`, gap_fill:958-963) never sees a submerged
column, so no liquid is written.

**Fix (two parts).** (1) `height_targets(…, sea)`: when the pristine `s < sea`
and the blended target would reach `sea-1`, the target is capped at `sea-1`
(wgen_inputs:208-218) — only *submerged-natural* columns are lowered; land,
seam pins, and non-overworld bands (target_sea = nil for nether/End,
gap_fill:894-896) are untouched. (2) the bounds wiggle skips keys whose pristine
height is below sea (gap_field:244-261), so a lakebed can never be re-lifted by
the cone jitter. Waterways are therefore preserved where the pristine terrain is
sub-sea, and dry terrain stays dry — no rivers forced through land.

**Round-3 change (Fix A).** The cap above was narrowed in round 3
(wgen_inputs:207-227): it now reads the seam field level (`lvl =
field.level[skey]`) and only fires when `lvl > sea+1`. Waterline / frozen-lid
seams (`lvl ≤ sea+1`) keep their blended target — the round-2 cap was drowning
exactly those (§ round-3, R3-A) — while this defect's dry rim (lvl 14-25) keeps
the cap. Measured on the canyon box (x −10305..−10255, z 8715..8755, Σ|H−nat|):
round-2 **10 956** → round-3 **11 043** (+0.8%; 128 cells closer to natural,
147 further, worst +6 at x −10271, z8724-28). The changed cells restore their
round-1 values (round 1 had no cap at all) — round-2's cap had incidentally
held a few floor cells down. The defect itself is unchanged in all three
builds: z8733 floor +2..+9 vs natural −7..−9, water columns 7 (round 1: 7)
vs natural 29. **Status: documented; `edge_cap` natural-cliff clause is an open
owner decision (fix vs close).**

## 8.4 Defect D (D3) — 45° diamond contours

**Mechanism.** `noise2(x,z,scale)` is smooth value noise, but the round-1 wiggle
(scale 11 and 4, amplitude ≤1.4) produced a *local* swing under one block across
the 20-30-column runs a contour occupies — every column of a Bellman ring
received effectively the same offset, so the exact cones propagated perfect
45° diamonds (owner: "perfectly square/diamond pattern in the contour").

**Fix.** scale-29 dominant + scale-11 detail at 3× amplitude (gap_field:244-261):
`w = step*jitter*12*(0.75*noise2(x,z,29) + 0.25*noise2(x,z,11))`, w ∈ [0, jitter·12·step]
≈ up to 4.2 blocks at jitter 0.35, applied to L and U alike (lift-only, no new
pinches, pin envelope preserved). Slope safety is unchanged: solve's neighbour
band still caps every written step at `step` — `gap_field_test`'s "never exceeds
the slope cap" / "organic contour" / "pin still met exactly" all pass.

By design: this amplitude is the *height-contour* wiggle (bounds shaping), a
different quantity from the climate/decoration jitter ceiling
(`wdl.jitter` — decoration survival assumes weight < 0.5 at capture_dist ≥ 24;
round-2 climate amplitude `(noise2(23)-0.5)*20 + (noise2(7)-0.5)*10` untouched).

## 8.5 Defect E (D4) — 25-step wall at 6696,11008

**Measurement BEFORE:**

```
z11008: x6696 ice H=1 (frozen sea, capture) | x6697 H=26 (d=1 ring, copied ice) | x6698 dirt H=30 (capture mountain)
        → 25-step at the seam pair, ring column wearing ice at y26
z10994-10996: same wall, H 2 → 30 (28-step)
natural control z11008: mountain slope H=154..179 everywhere (no sea at all)
```

The capture piece itself carries frozen sea hard against its mountain toe; at
the chunk border the piece's intermediate column is replaced by one d=1 ring
column that must sit between the ice side (lid target ≈ 2) and the mountain
side (target ≈ 29) — the step itself is structural and stays (§ round-3
residuals). Status by build: round-2 lifted the lid (z11008 wall 1→26 becomes
2→29, ice-on-stone = **78** cells with M=ice on columns H>4, box x6697-6710
z10990-11030); round-3 removed the face ice (Fix C): ice-on-stone **78 → 0**,
face columns x6697-6700 → `dirt_with_grass(_snow)` — see § round-3.

## 8.6 Round-2 verification

* **Harness:** `luajit mods/spawnimport/test_harness.lua` → `ALL CHECKS PASSED`
  **70 ok** (final code state), `gap_field_test.lua` → **45 ok ALL PASSED**
  (slope cap holds under the ×12 wiggle). End probe inside the harness (endtest)
  stays seam-exact / no liquid / no below-band writes.
* **2-base rebuild** (`MICRO_MANIFEST=…/museum_manifest_two.json ./import_tools/micro_rebuild.sh
  --no-deploy`): round-2 build **exit 0**, deployed 2026-10-06 (live map.sqlite
  md5 `acaa26a992929b6d7d8c568b673f2d7c`, auth/players restored, museumloot
  stripped from worldmods). PASS-critical audits re-verified with the identical
  recipe in round 3: **seam mismatches 0 / spilled water 0, both bases**
  (round-2's own audit log was superseded by that run).
* **Seam scan AFTER (probe_after2, identical scan_seam.py):** pyramid seam pairs
  1888 · H-mismatch **74** · fam-mismatch **210** (dH dist: −2×7, −1×24, +1×25,
  +2×3, +3×2, +4×6, +5×4, +6×2, +8×1); cut 3906 · **328** · **959** (cut dH
  distribution unchanged — structural tail −38…−9). Dominant snow-on-ice combo
  `('ice','snow','ice','ice')`: 252 → **0** (direct count 0 in both the
  round-2 and round-3 probes).

### Round-2 seam metric, identically taken (scan_seam.py, both bases)

| metric (BEFORE = probe_after = round-1 build, AFTER = probe_after2 = round-2) | pyramid before | pyramid after | cut before | cut after |
|---|---|---|---|---|
| seam pairs | 1888 | 1888 | 3906 | 3906 |
| H-mismatch | 455 | **74** | 330 | **328** |
| fam-mismatch | 584 | **210** | 952 | 959 |
| dH −1 / +1 | 264 / 150 | **24 / 25** | — | — (structural tail, unchanged) |
| top fam combo `('ice','snow','ice','ice')` | 252 | **0** | 0 | 0 |

### Coordinate clusters (spot.py before/after, radius 14)

| cluster (owner) | before (measured) | after (probe_after2) |
|---|---|---|
| 6566,11183 square ice / blend | capture H2 → ring H1 at x6568 (±1), ring snow on bare ice | z11183/84 flat 2 through x6568; step moved one column inward (2\|1 at 6568\|6569 — the residual the owner re-reported in round 3); snow-on-ice cells (x6552-6580, z11170-96) **135 → 0** |
| 6425,11183 unblended seam | z11183 cap: sand→ice at x6425, N=ice, H2 · z11184 ring: x6426+ H1 (**±1**), x6425 N=snow on M=ice (**snow defect**) | z11184 ring x6426+ H1→**2** (row flat); N snow→ice at x6425 (snow-on-ice 1→0); z11183 unchanged — the 3→2 at x6423\|6424 is capture-internal (d=0 both sides) |
| 6360,11183 square edge | ring z11184 x6357-6365 N=snow on M=ice vs cap z11183 x6360+ N=ice (H aligned 2/2; dirt_snow→ice material line at x6355-6359) | z11184 last window col x6370 H1→**2**; N on M=ice (x6358-6364) snow→**ice**; snow-on-ice (x6346-6374) **86 → 4** |
| 6667/6583@11167, 6584@11151 contour edges | 45° diamond rows | `contour_run.py`, identical 14-row invocation: flat 8898→**8908**, \|dH\|=1 1777→**1764** (16.2→16.1%), \|dH\|≥2 287→**290**, longest same-way run 20→**18** (z11151 20→18, z11152 19→9, z11008 18→11, z11009 18→9); valley profile kept |
| 6696,11008 wall | 25-step (1→26), 28-step rows z10994-96 | wall becomes 27-step (2→29, structural); ice-on-stone **78 (unchanged in round 2; round 3 → 0)** |
| 6664,11062 + 6664,10862 (owner typo 11862) | water_flowing topmost x6664-6667 @z11062 | lid-edge flow-over fixed where capture top is ice: z10892 x6680-6683 and z10911 x6697-6702 water_flowing→**ice**; open-water seams unchanged (z10912 x6712-6717, z11062 x6664-6667 — capture top `water_source`, no lid to pin; owner did not re-report); round-3 probe byte-identical on all four rows |
| 6616,11152 (owner typo 1152) | z11152 x6610-6622 uniform: H1, M/N = bare ice (row itself clean; seam rows z11151/11183 carry the defects) | z11151/52 x6610-6617 H1→**2** (ring lid lift) with residual 2\|1 at 6616\|6617 / 6617\|6618; not re-reported — round 3 lifts both rows flat (§ round-3) |
| −10198,9027 / −10293,9118 cut pyramids | F ramp 10→16 ≈ N (round-1 walls gone) | ramps smooth in r1/r2/r3 (max adjacent step **1**, no walls; z9027 23→30→21, z9118 23→28→19); round 3 differs from round 2 by ≤2 on individual cells (`pairs()` churn) |
| −10278,8733 canyon | dry, floor lifted +10 (natural flooded −10287..−10266) | unchanged: z8733 floor +2..+9 vs natural −7..−9; water columns **7** (round 1: 7) vs natural 29 — §8.3 |
| −10281,8783 river | water dead-ends x−10280 (floor ramps above sea) | unchanged: z8783 water columns **57** in all three builds (natural 22) |

### Invariants re-checked this round

| invariant | state |
|---|---|
| player structures never blended | `is_terrain_name` scope unchanged this round; lid/cover reads are scan-only |
| seam mismatches 0 everywhere | round-3 rebuild audit **0** (both bases); harness gaptest seam 0 |
| spilled base water 0 | round-3 audit **0** (both bases); harness 0 |
| End/Nether 3-D blend no regression | `wgen_blend3d.lua` untouched; sea-cap explicitly nil for nether/End (gap_fill:894-896); harness endtest seam 0, no liquid, no below-band |
| jitter capped by decoration-survival | climate `wdl.jitter` untouched; height-contour wiggle is a separate quantity (§8.4) |
| hole detection unchanged | `HOLE_MAX_CHUNKS/HOLE_ENCLOSED` untouched |
| witches disabled | `WITCH_SPAWNING_ENABLED=false` untouched |
| −61 sea-level offset | untouched |

# ROUND 3 — owner's second post-deploy defect report (2026-10-08)

## 9.0 Owner report (verbatim)

> so at 6585, 11153 and 6585 1168 and 6568, 11168 and 6568, 11184 all have 1
> block difference in height which leads to a clearly obvious seam where the
> ice/snow is one block differdet. There is also a very clear cliff which
> didn't bled at 6696, 11008. this one is a corner where ice meets stone with
> no blending. One edge gors to 6679, 11008. there is ice which climbs up the
> stone. which looks odd because ice normally does not go up a mountain coming
> from a lake onto a mountain.

## 9.1 Root causes

**R3-A — the four ±1 lid-seam spots (6585,11153 / 6585,11168 / 6568,11168 /
6568,11184).** Round-2's sea cap in `height_targets` (wgen_inputs) fires on
`s < sea and tv > sea-1` regardless of the *seam* level. At a frozen-lid seam
the seam field level is `sea+1` (=2), so a ring column's target
`tv = w·lvl + (1−w)·s` correctly lands ≈2 — matching the capture lid the owner
walks on — and the cap then drowns it to 0 → written 1 against the capture's 2.
Round 2 had already pinned the *first* ring column exactly (chunk-seam pairs
(6583,6584)/(6567,6568) are 2|2 after round 2), so the step the owner sees sits
1-2 columns **inside** the ring — `near`-class, which is why `scan_seam`'s seam
class never contained these spots (verified: zero seam-class mismatch cells in
the owner-spot rows, before and after). Measured before (probe_after2,
rows_r3_before): z11153 and z11168 flat 2 only through x6584, **1 from x6585**;
z11169/70/11184 flat 2 only through x6568, **1 from x6569**.

**R3-C — "ice climbs up the stone" (6696 → 6679,11008).** `wgen_write`'s scree
geology copy (wgen_write:267-278) copied the geology of the nearest seam-side
column across ring columns with **no height gate**, so the lakebed ice geology
was painted up the mountain face: **78 cells** with `mcl_core:ice` as top
material on columns H>4 (box x6697-6710, z10990-11030), i.e. ice sitting on
stone at H 29-38 — in both the round-1 and round-2 builds (identical count).
The flat ice at x6674-6696 (H=2) west of the wall is the capture's own frozen
lake lid — by design, not climbing. The 27-step corner (H 2|29 at 6696|6697)
is structural (§8.5).

## 9.2 Fixes (both algorithmic, seed-independent — no per-seed tables)

**Fix A** — `wgen_inputs.lua:207-227`: the cap now reads the seam field level
and only applies strictly above the waterline:

```lua
local lvl = field.level[skey]
if sea and s < sea and tv > sea - 1 and (not lvl or lvl > sea + 1) then tv = sea - 1 end
```

Waterline / frozen-lid seams (`lvl ≤ sea+1`) keep their blended target; dry-land
seams (D2 rim lvl 14-25) keep the cap (§8.3); Nether/End untouched
(`target_sea` nil, gap_fill:894-896).

**Fix C** — two markers: `gap_fill.lua:1050-1055` collects the seam surface
height per column (`slvl = last_field and last_field.level and
last_field.level[skey] or nil`); `wgen_write.lua:267-278` gates the geology copy:

```lua
and (not col.slvl or col.B == nil or col.B <= col.slvl + 2)
```

i.e. geology may copy only within +2 of the seam surface height — face/wall
columns keep their own rock/grass geology; ice-lid columns (B ≈ lvl) still get
the lakebed geology as before. All touched Lua syntax-checked
(`luajit -e "assert(loadfile(...))"` OK: wgen_inputs, gap_fill, wgen_write,
gap_field_test).

## 9.3 Gates (final code state)

* `luajit mods/spawnimport/test_harness.lua` → ALL CHECKS PASSED **70 ok** (×2 runs).
* `luajit mods/spawnimport/gap_field_test.lua` → ALL GAP_FIELD TESTS PASSED
  **45 ok**; 15/15 consecutive runs green.
* One **test-only** adaptation (gap_field_test check ~205): round-2's written-
  step rounding can produce a *perfect* terrace (`worst==0, ns==0`) which the
  old "no such terrace" assertion rejected; the check is now
  `ns >= 1 or worst > 1 + 1e-6 or worst == 0`. Count stays 45. Flake root
  cause: LuaJIT `pairs()` iteration order is process-random (verified
  empirically) with an integer `worst`.
* End probe inside the harness unchanged: seam-exact, no liquid, no below-band writes.

## 9.4 Rebuild + audits (identical recipe, both bases)

`MICRO_MANIFEST=$PWD/manifest/museum_manifest_two.json
./import_tools/micro_rebuild.sh --no-deploy` → **exit 0** (logs
/tmp/micro_pass1.log … /tmp/micro_pass3.log):

* pass-1 audits: **seam mismatches 0 / spilled water 0, pyramid + cut**
  (PASS-critical), no ServerError, gallery + sqlite integrity ran;
  `used_pieces_registry.json` restored with `git checkout --` afterwards.
* merge plans: pyramid 390 chunks / 1892 seam cols / unresolvable 258 /
  structural 5024 / worst step 146 / mean move 5.18 (over-cap columns 1441);
  cut 749 chunks / 3908 seam cols / unresolvable 1577 / structural 9530 /
  worst 72 / mean move 7.27 (over-cap 2057).
* probe after3: `/private/tmp/blend_diag/probe_after3.px` (6 WIN, 372 NAM;
  after2 had 373 NAM).

LuaJIT `pairs()` makes rebuilds not bit-reproducible: ~1% scattered ±1 H-cell
churn between builds is baseline noise; only measured deltas are attributed to
the fixes.

## 9.5 Metrics — identically taken, both bases

**scan_seam.py (all three probes, same windows):**

| metric | pyr r1 | pyr r2 | pyr r3 | cut r1 | cut r2 | cut r3 |
|---|---|---|---|---|---|---|
| seam pairs | 1888 | 1888 | 1888 | 3906 | 3906 | 3906 |
| H-mismatch | 455 | 74 | 74 | 330 | 328 | 330 |
| fam-mismatch | 584 | 210 | 209 | 952 | 959 | 963 |
| dH −1 / +1 (pyr) | 264 / 150 | 24 / 25 | byte-identical to r2 | — | — | — |
| combo `('ice','snow','ice','ice')` | 252 | 0 | 0 | 0 | 0 | 0 |

Cut dH distribution: structural tail (−38…−9) unchanged in all three builds;
cut seam H-mismatch 328→330 is +2 structural-tail churn, fam 959→963 +4.
Pyramid seam dH dist r2 = r3 byte-for-byte. Owner-spot rows carry no
seam-class mismatch cells in any build (they are near-class).

**metric.py (before = probe_after2, after = probe_after3):**

| class | pyramid | cut |
|---|---|---|
| seam | *byte-identical*: mean 0.07, >1 25, >3 13, material-change 50 | step stats identical (mean 0.28, >1 121, >3 77); material-change 215→219 |
| near >1 | 6060 → **5974** | 21114 → 21202 |
| near >3 | 1894 → 1945 | 7966 → 7995 |
| near >8 / >16 | 704→703 / 529→524 | 4826→4802 / 360→340 |
| near material-change | 10864 → 11466 | 53433 → 53375 |
| near sea-level ice/water | 845 → **676** | 0 |
| near top-node ice/water | 901 → **701** | 0 |

**diff_all (H over common cells, r2 vs r3):** 2 032 753 common · **22 979
changed (1.1%)** in 4 985 clusters; ΔH −1 ×8193, +1 ×10036 (rest ≤ small).
W-column: water→land occurs only as lifts (ΔH ≥ +1, **0 genuine drying**);
land→water 137 cells — scattered, several gully cells (z11141/42) move *toward*
natural water, a few shore cells (z11134-40, x6624+) sit below natural's dry
shelf; net small, reported honestly.

**contour_run.py (identical 14-row invocation, probe_after → probe_after2):**
flat 8898→**8908**, |dH|=1 1777→**1764** (16.2%→16.1%), |dH|≥2 287→**290**,
longest same-way run 20→**18** (z11151 20→18, z11152 19→9, z11008 18→11,
z11009 18→9). Round-3 spot re-check at the contour clusters (6667,11167,
rows z11154-57): same valley profile within a ±1 envelope — round 3 did not
touch the contour wiggle (`gap_field` unchanged this round).

## 9.6 Owner-spot verification (before = probe_after2, after = probe_after3)

| owner coordinate | before (round 2, deployed) | after (round 3) | natural control |
|---|---|---|---|
| 6585,11153 | z11153: 2 through x6584, **1 from x6585** | **flat 2 through x6610** (no step in row window) | open lakebed −2…−4 |
| 6585,11168 | z11168: 2 through x6584, **1 from x6585** | 2 through x6588, step at 6588\|6589 = **natural's own −3\|−4 step** | −3 → −4 at 6588\|6589 |
| 6568,11168 | step at 6568\|6569 on rows z11169/70 (z11168 itself steps 6584\|6585) | rows z11169/70 **flat 2 through x6576** (window end) | −1…−3, flat in window |
| 6568,11184 | z11184: 2 through x6568, **1 from x6569** | 2 through x6572, step at 6572\|6573 = **natural's −3\|−4 step** | −3 → −4 at 6572\|6573 |
| 6696,11008 | wall 2→29; face **78** ice-on-stone cells | wall unchanged (structural); face **0** ice-on-stone (x6697-6700 → `dirt_with_grass(_snow)`) | mountain 159-170 |
| 6679,11008 | ice lid x6680-6696 (H2) + ice on face up to H38 | lid unchanged (capture's frozen lake, by design); face ice removed | mountain 145-164 |

Every lifted cell is the first free column up to the lid (designed lift), and
each residual written step in the spotted rows sits exactly where natural's own
lakebed steps. Spot dumps: `spots_after3_pyr.txt` (10 spots),
`spots_after3_cut.txt` (4), `spots_r3_pyr_after3.txt` (5) — no errors.
Spot-by-spot diff vs after2: 6360 spot unchanged; contour spots ±1 envelope;
owner cluster rows flat (table above).

**Flow rows (round-2 fix intact):** z10892 (x6678-6690), z10911 (x6695-6720),
z10912 (x6710-6718), z11062 (x6662-6670) — H and top-node **byte-identical
r2→r3** (0 diffs). Lid-edge flow-over remains fixed: z10892 x6680-6683 and
z10911 x6697-6702 read `ice` (round 1: `water_flowing`).

**D2 spot:** z8783 0 changed cells; z8733 ±1 in 8 cells; canyon-box Σ|H−nat|
10 956 → 11 043 — §8.3.

## 9.7 Residuals / by-design (no code change)

* **D4 27-step wall** at 6696,11008 — structural: the ring column must sit
  between the capture's frozen-sea lid (2) and the mountain foot (29) while the
  natural mountain there is 159+; documented, not fixed (material-only fix applied).
* **D2 canyon/river** — defect unchanged; `edge_cap` decision open (§8.3).
* **137 land→water cells** + cut seam churn (+2 H, +4 fam): within
  pair-iteration noise; pyramid seam class byte-identical.
* **gap_field_test check-205 adaptation** — test-only (§9.3).
* **Open-water flow rows** (z10912, z11062) unchanged by design — capture top
  is `water_source`, there is no lid to pin; the lake continues, and the owner
  did not re-report them.

## 9.8 Status

* **Not deployed** — round-3 world exists in staging only; awaiting explicit
  go-ahead (BRIEF §9 deploy recipe and live-world guardrails unchanged:
  refuses while luanti is up, backup/restore auth+players, museumloot stripped
  from deployed worldmods, never a reduced manifest).
* **Nothing committed** — commit approval withheld.
* Final gates: harness **70/70**, gap_field **45/45**, rebuild audits
  **0 seam mismatches / 0 spilled water, both bases**.

---

# ROUND 4 — D2 natural-cliff fix (`edge_cap`), 2-base verification (2026-10-09)

Round 3 handed D2 off as open (§8.3 "defect unchanged in all three builds",
§9.7 "`edge_cap` decision open"). The owner approved the natural-cliff clause;
this round implements it and verifies it **in the 2-base manifest only**
(`manifest/museum_manifest_two.json`, `--no-deploy`). No full build, no deploy.

## 10.0 Toolchain recovery note

A temp-cleanup at 2026-10-09 00:03 deleted the analysis toolchain
(`metric.py`, `row6.py`, `spot.py`, `extract_row.py`, `contour_run.py`,
`diff_all.py`, `scan_seam.py`, `probe/init.lua`, …) and emptied the probe
worldmod dir. All payloads were recovered from the OpenCode session DB
(`/private/tmp/blend_diag/_recovered/`); every recovered `.py` passes
`ast.parse`, the probe lua passes `luajit -e assert(loadfile())`. Recovery was
validated by exact reproduction of recorded numbers: `scan_seam.py
probe_after3.px` → round-3 row (pyr 1888/74/209, cut 3906/330/963);
`contour_run.py rows_after_pyr.txt` → round-2 contour totals (flat 8908,
|dH|=1 1764, |dH|≥2 290, run 18). The first r4 probe hung with 0 `[PX]` lines
because `worldmods/probe/init.lua` was gone (a mod dir without init.lua loads
silently); restoring it and re-running produced `probe_after4.px` — **18079
`[PX]` lines (identical count to after3), 6 WIN, 372 NAM, ALLDONE, EXIT=0**.
New natural control `probe_nat.px` (recreated from staging, same seed/map_meta)
supersedes the old one: `[final]` sections byte-identical to the old
comparison, only `[natural]` snow/veg noise differs, so `metric_r3_newnat.txt`
is the r3 baseline measured against the same control as r4.

## 10.1 Root cause — the bounds side of D2

Round-3's Fix A already fixed the *target* side (`height_targets` caps a
submerged-natural column at sea−1 when the seam field level is a dry rim,
wgen_inputs:207-227). The *written* floor could not reach those targets: the
per-edge slope bound used by bounds propagation (gap_field.lua:231), the
solve's neighbour band (:349) and the violation diff (:401) was a flat
`step` = 1.5/edge, so a ring canyon floor could only descend ~1.5 per column
off its rim pins — a dry ramp stranded +3…+14 above a sea−1 target, never
`h < sea` (gap_fill:958-963), therefore no liquid. Nature drops **32 blocks in
one column pair** at the rim (z8733, x −10287|−10286: +25 → −7).

**Clause** — `edge_cap` (gap_field.lua:64-85): when the *pristine* pair is
itself steeper than `step` (`|natural[a] − natural[b]| > step`), the edge cap
becomes exactly `|Δnatural|` — as steep as nature, never steeper. Flat natural
edges keep 1.5 (v7's continuous terrain is untouched, especially across the
seam line), aquatic edges keep `AQ_FACTOR`. `violations()`/`deflate_steps()`
already classify such written steps as natural relief, so no other rule had to
move.

## 10.2 Gates (final code state)

* `luajit mods/spawnimport/test_harness.lua` → **70 ok** ALL CHECKS PASSED
  (End probe inside; hole detection, jitter ceiling, witches untouched).
* `luajit mods/spawnimport/gap_field_test.lua` → **45 ok** ALL PASSED.
* `luajit -e "assert(loadfile('mods/spawnimport/gap_field.lua'))"` OK.
* Only `mods/spawnimport/gap_field.lua` changed this round (5 edits).
* Fixture proof: the gap_field canyon fixture floods with the clause and stays
  dry without it.

## 10.3 Rebuild + audits (2-base, `--no-deploy` → exit 0)

`MICRO_MANIFEST=$PWD/manifest/museum_manifest_two.json ./import_tools/micro_rebuild.sh
--no-deploy` → **exit 0**, no ServerError (logs /tmp/micro_pass1.log, pass2,
pass4; gallery + sqlite integrity ran; `used_pieces_registry.json` restored
with `git checkout --`).

**Audits (PASS-critical = seam / spilled water):**

| audit line | pyr r4 | cut r4 | pyr r2 ref | cut r2 ref |
|---|---|---|---|---|
| seam mismatches (worst) | **0** (0.0) | **0** (0.0) | 0 | 0 |
| spilled base water | **0** | **0** | 0 | 0 |
| floating junk / veg / kelp | 0 / 0 / 0 | 973 / 86 / 0 | 0 / 0 / 0 | 963 / 83 / 0 |
| merge slopes over cap (worst) | 838 (68.0) | 846 (10.0) | 1681 (60.0) | 2094 (20.0) |
| natural relief steps (worst, **tgt**) | 1016 (**171.0 tgt=171.0/171.0**) | 2413 (**73.0 tgt=73.0/73.0**) | 1260 (116.0) | 2081 (39.0) |

The relief counters now report written step **exactly equal to the natural
target** (the clause working); junk +10 / veg +3 on cut are cocoa/veg
decorations left floating where canyon floors dropped — informational, not a
PASS line. `spawned 0 … witch(es)` both bases, witch-spawn-disabled line
present.

**Merge plans (r3 → r4):**

| | pyr r3 | pyr r4 | cut r3 | cut r4 |
|---|---|---|---|---|
| chunks / seam cols | 390 / 1892 | 390 / 1892 | 749 / 3908 | 749 / 3908 |
| unresolvable (structural, worst) | 258 (5024, 146) | **164** (5140, 171) | 1577 (9530, 72) | **934** (16306, 75) |
| mean move | 5.18 | **4.71** | 7.27 | **6.77** |

Cut's structural count rising with unresolvable falling is the clause moving
pairs out of "impossible" into "structural-by-relief"; chunk and seam-column
counts are unchanged.

## 10.4 Metrics — identically taken, both bases (r3 vs r4, same natural control)

**scan_seam.py:**

| | pyr r3 | pyr r4 | cut r3 | cut r4 |
|---|---|---|---|---|
| seam pairs | 1888 | 1888 | 3906 | 3906 |
| H-mismatch | 74 | **74** | 330 | 328 |
| fam-mismatch | 209 | **209** | 963 | 976 |

Pyramid seam rows are byte-identical r3→r4 (dH dist and totals). Cut structural
dH tail (−38…−9) unchanged; H −2, fam +13 is vegetation-combo churn (leaves/
snow swaps), same band as previous rounds.

**metric.py — `seam` class (PASS-critical boundary):** steps byte-identical
pyr (mean 0.07, max 8, >8 = 0) and cut (mean 0.28, max 38); material-change
pyr 50→50, cut 219→217; pyr seam sea-level ice/water unchanged 496. Built seam
remains *smoother than natural's own* (nat pyr 0.31/max 28, nat cut 0.54/max 20).

**metric.py — `near` class, three-way (the attribution):**

| statistic | pyr r3 | pyr r4 | pyr nat | cut r3 | cut r4 | cut nat |
|---|---|---|---|---|---|---|
| step mean | 0.49 | 0.53 | 0.49 | 0.68 | 0.76 | 0.65 |
| p99 | 3 | 4 | 6 | 10 | 10 | 11 |
| max | 140 | **171** | **171** | 53 | **75** | **75** |
| >1 | 5974 | 6323 | 6071 | 21202 | 26394 | 24709 |
| >3 | 1945 | 2490 | 2900 | 7995 | 12618 | 15331 |
| >8 | 703 | 1014 | 1442 | 4802 | 6604 | 9463 |
| >16 | 524 | 692 | 932 | 340 | 774 | 1332 |
| material-change | 11466 | 11696 | 6768 | 53375 | 53471 | 49889 |
| sea-level ice/water | 676 | 729 | 0 | 0 | 0 | 0 |

r4 closes most of the structural gap to natural and **reproduces natural's max
step exactly** (171, 75) where r3 over-smoothed it; the fine-scale tail
slightly overshoots (see §10.6). `outer` class (untouched mapgen control)
r3≈r4≈nat (pyr >16 372/372/372, cut 2681/2683/2678) — 11 cells at capture-dist
≥9 moved ±1, which is the whole outer drift.

**Per-reported-coordinate (r3 → r4):** (6648,10846) near dH=1 → **seam dH=0**;
(6712,10960) near dH=12 → **2**; (−10248,8735) near dH=4 → **edge_wide dH=1**;
(6664,10846) unchanged dH=1 (worst location moved); **(6696,11008) wall pair
z11007 dH 27 → 31, z11008 27 → 29, face x6697-6706 +1…+4** (§10.7).

**diff_all (r3 → r4, common cells):** 2 032 753 common · **65 045 changed
(3.2%)** in 5 533 clusters; ΔH histogram negative-dominant (deep tail −10…−39
≈ 2.5k cells = the canyon deepening), +deep tail = wall face; M 7 991 (0.4%),
W 24 313 (1.2%).

**Water ledger (W identity, own-NAM per file):** dry→wet **2784**, wet→dry
**323** (net +2461).
Of the gains: **2123 sit where natural is sub-sea** (the D2-class fix — floors
0/−1/−2/−3/−8… now under water as nature has them); 642 where natural is dry,
of which **565 are at capture-distance ≤2** (ring extending a sea-carrying
piece's lid — the designed seam fade, none on captured ground: every changed
cell is ring), 73 at d=3, 4 at d≥9.
Of the losses: 242 where natural is dry (r3's spurious water removed = correct
direction), **81 where natural is water** (scattered shore cells, incl. 11
cave-hollow cases where H>sea with y1 water — reported honestly).
Direct sea-level water↔ice family swaps r3→r4: **4 cells**. D4 box:
0 gains / 0 losses. Audit spilled base water **0/0**.

## 10.5 D2 verification (the fix target)

**Canyon box (x −10305..−10255, z 8715..8755, Σ|H−nat| over 2091 cells):**

| | r2 | r3 | **r4** | natural |
|---|---|---|---|---|
| Σ\|H−nat\| | 10 956 | 11 043 | **3 005** | 0 |
| mean abs error | 5.24 | 5.28 | **1.44** | 0 |
| water columns (z8733 row, x −10305..−10255) | — | 7 | **23** | 29 |
| water columns (whole box) | — | 581 | **982** | 1061 |

**z8733 row vs natural, cell by cell (r3 → r4):** rim x −10300..−10288 was a
descending dry ramp 23→14 (floor riding the pin cone) → now **natural-exact**
24/25; the cliff lands at the natural edge (x −10287: 25 → **−7**, natural
−7); canyon floor −7…−8 = natural-exact at the head, within +4…+8 on the shore
ramp; W at sea level: r3 stone/sand (dry) → r4 **water_source** x −10287..−10271
(natural water spans −10294..−10266).

**Owner rows:** 32 of 40 extracted rows byte-identical r3→r4; every change is
either the D2 rows (z8733 H/M/N/W) or the D4 wall face (z11007/11008 H/N).
All owner-spot rows (z11153/11168/11169/11170/11183/11184) identical — player
structures untouched (§7).

**ice-on-stone (D4 box x6697-6710 z10990-11030, M=ice on H>4, per-file NAM):**
r3 **0** → r4 **0**.

**contour_run.py (identical invocations):** pyramid 14-row — flat 8908→**8939**,
|dH|=1 1764→1726 (16.1%→15.7%), |dH|≥2 290→**297**, longest same-way run
**18→15** (z11151 18→14, z11167 9→6, z11183 5→3; z11152 9→15 is the one row
that lengthened) — D3 improved, not regressed. Cut 8-row — totals
flat 7045→7093, |1| 2641→2550, ≥2 802→845, run 25→25 (max sits at z9027,
pre-existing); the canyon rows z8733/34 now run 5 (the cliff is single steps,
not a ramp).

## 10.6 Attribution of the near-class increase

The near class got "rougher" (cut >16 340→774) — **that is the fix**: those
pairs sit on natural cliffs the flat 1.5 cap used to erase. Proof: the same
statistic computed on the untouched natural control is *higher* than r4
everywhere structural (>16: 932 pyr / 1332 cut vs r4 692 / 774), r4's max
equals natural's max exactly (171 / 75), and r3 was far *below* natural
(over-smoothed). The residual overshoot is fine-scale only: cut near mean 0.76
vs natural 0.65 and >1 26394 vs 24709 (+7%) — the loosened bounds let the
solve place ±1 more freely between cliffs; seam and outer classes show no such
drift.

## 10.7 Residuals / by-design (no code change this round)

* **z8783 river mouth (x −10300..−10286) — unchanged r3→r4, byte-identical
  rows.** Natural there: land 15-17 | lake floor −4…−9 with 17 water columns |
  +24 cliff; built: one smooth dry ramp 7→0→… (dirt at sea, 3 misplaced water
  cols at x −10282..−10280 where natural is cliff). Root cause is the *target*
  side: at this near-waterline seam `lvl ≤ sea+1`, so round-3's Fix A cap
  deliberately does not fire (the R3-A drowning trade) and the blended target
  rides ≈2-3 → dry; `edge_cap` is bounds-only and cannot lower a target.
  Out of this round's mechanism — fixing it means re-litigating Fix A's
  exemption (owner decision open).
* **D4 wall at 6696,11008 grew 27 → 31 (z11007) and 27 → 29 (z11008):** the
  looser relief bounds let the mountain-foot face sit +1…+4 higher. Structural
  both sides (natural is 154+ there; capture pins force lid 2 | foot 29+);
  material stays clean (ice-on-stone 0), owner has not re-reported it.
* **cut near fine-roughness above natural** (§10.6) — within the design
  trade; seam/outer untouched.
* **junk 963→973, veg 83→86** (cut): floating cocoa/veg over dropped canyon
  floors; informational counter.
* **81 nat-wet wet→dry cells** (§10.4) and **4 water↔ice sea-level swaps**.
* **11 cells at capture-dist ≥9** moved ±1 (outer-class micro-drift).
* LuaJIT `pairs()` churn (~1% ±1) as before; **gap_field_test check-205**
  test-only adaptation (§9.3) unchanged.

## 10.8 Status

* **Verified in the 2-base manifest only** — rebuild exit 0, audits PASS-critical
  **0/0 both bases**, gates **70/70 + 45/45**, D2 box error **−73%**, water
  restored to near-natural, seam class byte-stable, owner rows untouched.
* **Full 20-base build + deploy: not started** — awaiting explicit owner
  go-ahead (never a reduced manifest; live world still the round-2 build).
* **Nothing committed** — commit approval withheld.
