# PLAN — seasons: discover, claim, save, re-seed

**Date:** 2026-10-16 · **Status: PLANNED — nothing here is built yet.**
**Owner decisions recorded:** 2026-10-16 (see §12).

This is the design for turning the museum world into a long-running SMP. The
museum kit owns the world-facing parts: discovery, snapshots, the loot ledger
and the re-seed pipeline. The player-facing SMP parts (claim menus, protection,
the Base home, shard awards) are specified in the FriedcakeSMP repository
(`coconut`) as `spec/features/f17-base-claims.md` and
`spec/features/f18-reports-and-bounties.md`. The cross-repo brief is
`coconut/INTEGRATION-museum-import-kit.md`.

## 1. The idea in one paragraph

Each **season** is one world seed. The 2b2t bases are scattered across it in
new, biome-matched positions. Players hunt for them. Finding a base earns an
advancement and, for the first finder, public credit and the right to claim it.
A claim protects a base for the season. A **saved** base, bought with shards
and approved by an admin, rides into the next season exactly as its owner left
it. Everything else regenerates from the original world download. Everyone's
portable belongings live in their ender chest. When the season ends, a new seed
is built, saved bases are placed into it, and the cycle starts again.

## 2. Design principles (Raph Koster, *A Theory of Fun for Game Design*)

The book's argument is that fun is the feeling of learning a pattern, and that
a game goes stale once its pattern has been learned. The design leans on these
points:

| Principle (chapter) | How the design uses it |
|---|---|
| Fun is learning; mastered games become boring (ch. 3, 7) | A new seed every season gives a new space to learn. Base positions must change every season, or last season's coordinates kill discovery. |
| Know what the game teaches; cut systems that don't serve it (p. 93) | The lesson is *find history, choose what to keep, carry it forward.* Every system below serves one of those three verbs. |
| Ludeme checklist: preparation, space, core mechanic, range of challenges, range of abilities, skill, variable feedback, cost of failure, the Mastery Problem (ch. 7) | Preparation = packing the ender chest and choosing what to save. Space = the reshuffled world. Core mechanic = read clues, travel, discover. Challenges = ~208 bases of different size, dimension and biome. Cost of failure = what isn't in the ender chest or a saved base is gone. |
| Thoroughness and exploration are worth teaching (p. 54) | Discovery rewards careful exploration, not reflexes. |
| Pacing: too slow is boring, too fast is noise (ch. 3) | Clues escalate over the season so the last few bases never stall it. |
| Players reduce the possibility space and will exploit (ch. 7–8) | Teleport-carried discoveries don't count; exploits are paid for when reported instead of used (f18). |
| Exploiting is skill; hacking is a way of playing (ch. 7, 9) | Shards are earned by reporting bugs and exploits and by contributing fixes. |
| Players can generate content (ch. 8) | Saved player bases become part of the world others explore. |
| Legacy is a strong drive (ch. 11) | Saving a base, and having your name on a base you found first, persists across seasons. |
| Social feelings: fiero, naches, kvell (ch. 5) | First-finder broadcasts; credit when others discover a base you built. |

## 3. Season loop

1. **Expedition (day 0).** The new seed goes live. Unsaved museum bases are
   pristine. Saved bases arrive with their owners.
2. **Settlement.** Players discover bases, claim them, build and trade.
3. **Exodus.** Called by the operator. The automatic signals are "all bases
   discovered" and "next world built"; both only notify the admin at first.
   A hard cap replaces everything **every 2 months regardless** (owner,
   2026-10-16). Exodus is a countdown (PROPOSED 7 days) so players can pack
   their ender chests.
4. **Cut.** The single moment, with the server down, when everything that
   carries over is read (§6).
5. **Finish and swap.** Saved-base changes are written into the staged next
   world, which then goes live.

The cycle is run **manually** until the community gives feedback on its pace
(owner, 2026-10-16).

### 3.1 Timing constraint

The full import is CPU-bound (Lua chunk decoding plus the merge). Estimates
from other agents: about **one week** on a very fast box and about **one
month** on the deployment server. The README's 22 h figure is from an older,
lighter pipeline (README, "Rough timings"). A season is therefore at least as long as one build,
and the build for season N+1 starts on day 0 of season N.

## 4. Discovery and the catalog

### 4.1 Discovery

- **Trigger:** a player comes within about 24 nodes (PROPOSED) of the base's
  `warp_target` (already in the registry: the densest cluster of containers
  and signs), in the right dimension band.
- **No teleport carry:** arriving by any teleport (tpa, rtp, home, warp) in
  the previous 5 minutes (PROPOSED) does not count.
- **Every finder** gets an advancement (`awards.register_achievement`, the
  API Mineclonia ships in `mods/HUD/awards`), collection progress (this season
  and lifetime), and the base added to their personal `/warp` list.
- **The first finder on the server** also gets a broadcast (`mcl_title`), their
  name on the base's plaque (kept across seasons), the first claim window and
  renown.
- **Variable reward:** renown scales with difficulty: fewer earlier finders,
  smaller base, nether or End.

`/warp` lists only bases the player has discovered this season. Today it lists
every base, which would make discovery free.

### 4.2 Catalog and escalating clues

`/museum` opens the catalog. Initial hints per exhibit: era (the year in the
WDL path), dimension and size class. Hints escalate for bases nobody has found
(all PROPOSED):

| Day | Hint added |
|---:|---|
| 0 | era, dimension, size class |
| 7 | biome family |
| 14 | quadrant |
| 21 | distance band from spawn |
| 28 | a dowsing compass that points to within about 500 nodes |

Because placement is biome-matched, the biome hint is a real pattern players
can learn ("mesa bases land in mesa").

## 5. Claim and save

Two tiers. The player-facing rules are in `coconut/spec/features/f17-base-claims.md`.

| | Claim | Save |
|---|---|---|
| Cost | Free; requires having discovered the base this season and a minimum number of discoveries | A charter bought with shards (f18), carried out by an admin |
| Gives | Protection and a Base home for this season | The base rides into the next season with full fidelity |
| At season end | The base reverts to pristine | The base is placed again, identical |

- The first finder has an exclusive claim window (PROPOSED 1 hour), then any
  player who discovered the base may claim it.
- A player belongs to one claim at a time, as owner or member.
- A claim lapses after 14 days (PROPOSED) with no member online.
- **Unclaimed museum bases are griefable** and regenerate fully next season
  (owner, 2026-10-16).
- **Player-built bases** can be saved too, with a size cap (PROPOSED 64×64
  columns).

### 5.1 Full fidelity: "wake up home"

A player who logged off in their saved base must log in next season and see
no difference (owner, 2026-10-16). This applies to museum and player-built
bases alike. Carried exactly:

- **Blocks:** node names, param2 (grass and leaf tint), all node meta, sign
  text and **every inventory**, including chests and placed shulkers.
- **Item frames** with their contents, including shulkers with items inside.
  Filled maps keep their art (§7.5).
- **Node timers:** furnaces mid-smelt, growing crops.
- **Entities:** villagers with their trades, tamed animals, farm animals,
  armor stands.
- **Players inside the saved region at the cut:** their position and facing
  relative to the base, and their main inventory, are restored. A bed spawn
  inside the region is translated; one outside is cleared. (Check the
  player-meta key `mcl_spawn` uses before writing code.)
- **A margin of old terrain** (PROPOSED one 80-node mapchunk) rides with the
  base, so the near view is unchanged. The blend seam starts outside it.
- **Biome:** saved player bases get biome-fit placement like museum bases.
  Luanti computes the biome from noise at the position, so a base moved into a
  different biome would get a different sky, weather and mob spawns.
  Coordinates change; the Base home follows the base.

## 6. What carries over, and the single cut

**Carries over**

- Ender chest contents. With FriedcakeSMP this is the 54-slot
  `smp_enderchest` player-inventory list; without it, Mineclonia's 27-slot
  `enderchest` list (`mcl_chests/init.lua:1216`). Both live in the player
  database, not the map.
- Saved bases (§5.1), including the main inventory of players inside them.
- Money, ranks, stats, friends, settings, shards, lifetime discoveries and
  renown.

**Resets**

- Main inventory, armor and offhand of everyone not inside a saved base.
- Homes, except the Base home. Every old coordinate is meaningless in the new
  world.
- Player positions: on first join after the swap, a season-id check sends the
  player to spawn, or to their saved-base position.

**Auction and order escrow at the cut:** active listings, expired items and
uncollected deliveries go into the owner's ender chest if there is room, and
are lost otherwise. Escrow must not become storage outside the ender chest.

**The cut.** Everything that carries over is read once, with the server shut
down and all players kicked so inventories are flushed. Nothing is read
earlier, so there is no window in which an item can be moved after it was
recorded. This is what makes full fidelity dupe-safe.

## 7. Technical design

### 7.1 Base lineage

Every base has a **baseline**: the version placed at the start of the season.
For a pristine museum base that is its WDL capture. For a saved base it is the
snapshot taken at the previous cut. Every season's snapshot is archived; the
archive can later become a "history of this base" exhibit.

### 7.2 Build early, apply only the changes

1. **Day 0, season N:** choose seed N+1 (secret; set through `fixed_map_seed`
   in the build conf, see `import_tools/conf/microtest.conf`), fit the layout
   for that seed, and start the build. The build places every base from its
   baseline and fills loot from the ledger as it stood at build start (§8).
2. **During season N:** `core.register_on_mapblocks_changed`
   (Luanti `doc/lua_api.md`) records dirty mapblocks inside every claim
   region. Tracking runs all season; the admin chooses per charter whether the
   delta starts at season start or at claim time (the latter reverts griefing
   done before the claim).
3. **At the cut:** read the dirty-mapblock delta for each saved base, the
   entities of each saved region, the loot ledger, and the escrow.
4. **Finish, on staging:** write the dirty mapblocks and re-create the
   entities, apply the ledger shrink, copy map art.
5. **Swap.**

Downtime is proportional to what players changed, not to base size. Placing a
whole claimed base again at about 0.5 s per chunk would take hours per large
base, which is why only the delta is written at the cut.

**Lapses** are decided at build start, so a late lapse takes effect one season
later. This avoids re-placing a whole base during downtime.

**Seam rule:** a saved region is the capture footprint (or the player plot)
plus its margin, kept at least one mapchunk inside the blend ring. A delta must
never write old-seed terrain into the new seam.

### 7.3 Snapshot format and placer

- The snapshot is written per 16×16 column: a node-name palette, node ids,
  param2, node meta (fields and inventories), and node timers.
- It also writes the same per-chunk footprint (surface height, water, biome)
  that `import_tools/placement_fit/source_footprint.lua` produces, so
  placement fit and the gap-fill merge accept it unchanged.
- spawnimport gets a second chunk source next to `lua_import/anvil.lua`: a
  snapshot source behind the same decode interface. The existing merge then
  blends a snapshot into new terrain like any capture.
- Snapshots are native Luanti data, so they are **not Z-mirrored**. The mapart
  gallery's unmirror pass must skip saved regions.

### 7.4 Entities

`register_on_mapblocks_changed` tracks node changes only, and
`core.get_objects_in_area` sees only active objects. At the cut, parse each
saved mapblock's static-object list offline from `map.sqlite` (format in
Luanti `doc/world_format.md`), then re-create the entities in staging with
`core.add_entity(pos, name, staticdata)`. Test every entity type: villager
trades, tame owner, armor-stand pose. Item frames are a node plus the
`mcl_itemframes:item` display entity; the display entity is rebuilt from the
node.

### 7.5 Map art

Filled maps in item frames reference map ids and textures in
`<world>/mcl_maps/`. Copy the textures with the snapshot and remap ids so they
can't collide with maps in the new world. Saved regions are player content:
the admin runs `coconut/tools/mapart_scan.py` over them when approving a
charter.

### 7.6 Swap and data carry-over

`import_tools/full_rebuild.sh` wipes `mod_storage.sqlite` today. The swap must:

- keep `players.sqlite` (ender chests) and `auth.sqlite` (or `auth.txt`);
- take the map, `map_meta.txt`, `mcl_maps/` and the spawnimport, museumloot
  and museumwarp mod storage from the new world;
- take SMP and season data from the live world.

Simplest: point `smp_store` at its own database (it supports SQLite and
Postgres), so the swap never has to merge `mod_storage`.

### 7.7 Seed secrecy

The current seed must never reach players (`coconut` f15 rule). Placement
tie-breaks also get a secret salt: with the seed and the public manifest,
every base position could otherwise be computed.

### 7.8 Operator script

One script, explicit steps, each checking the previous step's output:
`season plan`, `season build`, `season exodus`, `season cut`,
`season finish`, `season swap`. Same reason `full_rebuild.sh` exists: nothing
is left to memory.

## 8. Loot ledger

`museumloot` seeds every roll from the absolute world position
(`mods/museumloot/init.lua:985`, `:1753`). Bases move every season, so as built
every container would get a fresh, full, deliberately generous roll each
season. That would flood the economy (owner, 2026-10-16: saving the loot is
better than re-running it).

- **Ledger:** each museum container is keyed by (base, position relative to
  the base anchor) and records the loot that remains.
- **At the cut:** `remaining = min(original roll, current count of that item)`
  per item. The ledger can only shrink. Items players add to a museum
  container never carry over. A destroyed container counts as looted.
- **Next build:** fill containers from the ledger, never from a fresh roll.
  Blocks regenerate; loot does not.
- **Saved bases are exempt:** their containers ride exactly (§5.1).
- **Trickle (open, §13):** re-roll a share R of emptied containers each
  season, in the least-discovered bases and the nether and End, so later
  newcomers still find something. A re-roll is seeded from base-relative
  position plus a season salt.

## 9. Economy

Money must be hard to get and keep its value (owner, 2026-10-16). There are no
dupes on the reference SMP; this pipeline must not add any.

**The structural risk.** Seasons destroy items (anything not in an ender chest
or saved base) while money persists. Each season, money grows against goods.
Also, a rational player sells everything to the server just before the wipe:
a predictable money spike every Exodus.

**Faucet controls (PROPOSED):**

- Remove loot-dominant categories from the `/sell` base-price table:
  enchanted gear, netherite, totems, elytra, shulkers. Loot then feeds only
  the player market, where trades move money but never create it.
- During Exodus, ramp the `/sell` multiplier down to 0. Players with spare
  ender-chest room buy cheaply from players who are leaving.
- Keep natural spawner conversion off (`spawners.acquisition.natural = false`
  in FriedcakeSMP). Imported 2b2t spawners are real `mcl_mobspawners` nodes
  that regenerate every season; converting them would be an endless faucet.

**Sinks:** money sinks are a future feature and not part of this design yet
(owner, 2026-10-16).

**Instrumentation** (before any tuning): money supply including escrow, a
per-source faucet ledger, a price index from auction and order sales of a
reference basket (diamonds, netherite, totems, shulkers, elytra), and the value
left in the loot pool. Tune prices and the trickle only between seasons, and
announce changes in advance.

## 10. Milestones

| # | Milestone | Ships to | Notes |
|---|---|---|---|
| M-1 | **Biome-matched placement per seed** | — | Prerequisite. Still open: see `HANDOFF-biome-placement.md`. The full layout is still packed by size only. |
| M0 | **Spike, go/no-go** | test world | Save one edited base; take the delta at the cut; finish into a world with a different seed; verify by block diff. Cover containers, frames holding shulkers, map art, every entity type and player position restore. Check whether a meta-only change (a chest inventory) fires `register_on_mapblocks_changed`; if not, read containers in the full region. Test a delta next to the seam. Measure downtime. |
| M1 | Season plumbing | test world | Operator script, carry-over rules, season id, position reset, escrow handling, economy instrumentation. Two seeds back to back on `manifest/museum_manifest_sample20.json`. |
| M2 | Discovery, catalog, warp gating | **current world** | Needs no re-seed. Playtest it bare first, as Koster advises (p. 124): time to first find, spread of find times, when players quit. |
| M2.5 | `/report` and shard awards (f18) | **current world** | Import-defect reports start flowing immediately. |
| M3 | Claim tier (f17) | live | Protection, Base home. |
| M4 | Save tier, loot ledger, Exodus, the full cut and finish | live | Charter request flow and admin approval tool. |
| M5 | Saved player-built bases | live | Biome-fit relocation, size cap. |
| M6 | Legacy | live | Ruins of lapsed player bases as exhibits credited to their builders, renown, season modifiers. |

## 11. Risks and exploits

- **Coordinate lists posted by players.** Accepted: they go stale every
  season, and first-find rewards give players a reason to keep finds private.
- **Alt accounts claiming bases.** The discovery threshold for claims.
- **Seed cracking.** A secret 64-bit seed plus the placement salt.
- **Seam artifacts from deltas.** The seam rule (§7.2), tested in M0.
- **Downtime.** Proportional to the delta; measured in M0.
- **Build length.** At least a season; the build for N+1 starts on day 0 of
  season N.

## 12. Owner decisions (2026-10-16)

1. The import is CPU-bound; a week on a fast box, about a month on the
   server. It is a necessary step.
2. Saving loot state is better than re-rolling it (avoids inflation).
3. Unclaimed museum bases are griefable and regenerate fully next pass.
4. The cycle is run manually for now; everything is replaced every 2 months
   regardless.
5. Money must be hard to get and keep its value. Money sinks are deferred.
6. Base saving is bought with shards and carried out by an admin. Shards come
   from bug fixes and from finding and reporting exploits.
7. A saved base must feel exactly the same after it is placed again, for
   museum and player-built bases alike. Item frames are not stripped.

## 13. Open questions

1. **Trickle rate R.** Start at 0 and add a refill only when newcomers find
   bases empty, or start at about 10%?
2. **Gear categories in `/sell`.** Remove them, or keep them at deliberately
   low prices?
3. **Spawner stacks in saved bases.** They ride as part of the base under the
   full-fidelity rule. Confirm, given they are the main capital good of the
   SMP economy.
4. **Shards between players.** PROPOSED: not transferable, so saving stays
   tied to contribution. Charter members share one saved base.
