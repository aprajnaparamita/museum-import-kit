# Next steps — read SESSION_2026-09-17_SUMMARY.md first

Concrete, actionable items. Roughly in priority order. Check off / update
this file as you go rather than trusting memory across sessions.

**Update, Round 4 (same day, currently in progress as this is written)**:
the project owner corrected a wrong assumption from Round 3 — the
villages with no villagers/chests are **imported data from the real world
download, not freshly-generated Mineclonia terrain**. That reframed the
"no villagers" issue as squarely `mobplacement.lua`'s problem (its village
detection is supposed to compensate for entities never being imported —
see `HANDOVER.md`'s documented, intentional "entities/*.mca is never read"
scope limit), and led to a MUCH bigger discovery: a systematic audit of
one real base capture found **114 distinct Minecraft block types silently
becoming plain stone on import**, including `bell` and `composter` (which
starved village detection of both its signals — this is the actual root
cause of zero villages ever being detected all session) and several huge-
count blocks unrelated to villages at all: `nether_portal` (128,361
instances in one base!), `dripstone_block`+`pointed_dripstone` (~115,000),
`grass` the plant (~19,000), `bamboo` (~22,000). Full detail, current
status, and exactly where to resume is in the new "Round 4" section near
the bottom of this file — **read that section before doing anything else
if you're picking this up fresh**, it has the most current state.

**Also asked for for continuity**: this file plus `SESSION_2026-09-17_SUMMARY.md`
exist specifically so a fresh agent/session can take over without the
original conversation. Two data files also live alongside them for the
in-progress block-mapping audit: `SESSION_2026-09-17_remaining_block_defaults.txt`
(the worklist) and `SESSION_2026-09-17_block_samples_fort_alcazar.lua`
(real block+property samples to test against, avoiding needing to
re-decode the source capture). See "Round 4" for how to use them.

**Update, Round 3 (same day)**: live testing of the Round 2 build found
another batch of real bugs, now fixed. Full detail at the very bottom of
this file under "Round 3". Short version: `pvpkits.lua` had a real bug
(`tostring(itemstack)` instead of `itemstack:to_string()` — every kit
shulker showed "Unknown Item" in every slot, now fixed); double chests'
left/right halves now share one classification instead of rolling
independently (was reading as two unrelated loot types spliced together);
the loot-balance weights were reworked again after direct feedback that
diamond gear still dominated and iron/gold armor read as "trash" (root
cause: overly generic sign keywords like "anarchy"/"best"/"pro" were
routing far more containers into gear_diamond than intended); added
genuine "totally empty" and "totally full" variance; and a wall-sign
facing fix in `palette.lua` (reasoned from reading `mcl_signs`' actual
placement code, **not yet live-verified** — flagged clearly in-file).
**Also**: discovered the known emerge-timing undercount (documented back
in section 1) is worse than first measured — a second pass on the same
base found 760 containers vs. 478 on the first pass, and picked up entire
missed structure types (`dungeon`, `end_city`) the first pass never saw at
all. Running the loot pass twice before considering a world "done" is now
the standard procedure, not just a nice-to-have — see "Round 3" for the
exact numbers and consider whether this needs a real fix (e.g. the pass
retrying itself automatically) rather than a manual double-run, especially
before ever running this against the full 205-base `museum-world-rescue`
rebuild.

**Update, same day, later session**: everything in section 1 below was done
— the playtest world was rebuilt and redeployed with fixes #7-#10. Live
playtesting then found two MORE real bugs and one design request, all now
fixed/built (see "Round 2" section near the end of this file for full
detail). The world has been rebuilt and redeployed again since; what's live
in `2b2t Museum TEST` right now reflects everything through Round 2.

**Also**: the external drive (`/Volumes/Dara`, which `~/dev` symlinks to)
was briefly unplugged mid-session (physical accident, cable/USB came
loose) and has since been reconnected and verified intact — nothing was
lost, but if you're picking this up cold and any `~/dev/...` path fails,
check `df -h | grep -i dara` and `ls /Volumes/` before assuming something's
actually wrong. The project owner's actual playable world and the
installed Mineclonia game are both on the internal drive and were
unaffected either way.

## 1. Rebuild and redeploy the playtest world (immediate, blocks everything else)

The client-facing `2b2t Museum TEST` world currently reflects the state
*before* fixes #7-#10 in the summary doc (end_city/witch_hut false
positives, real enchantments, loot variety expansion). Nobody has seen
those fixes live yet. Do this:

```bash
# 1. Sync latest kit files into the headless dev copy
cp ~/dev/museum-import-kit/mods/museumloot/{init.lua,structures.lua,mobplacement.lua} \
   ~/dev/museum-playtest/worldmods/museumloot/

# 2. Wipe the world data (keep worldmods + world.mt + map_meta.txt + manifest)
rm -f ~/dev/museum-playtest/map.sqlite ~/dev/museum-playtest/mod_storage.sqlite \
      ~/dev/museum-playtest/auth.sqlite ~/dev/museum-playtest/players.sqlite \
      ~/dev/museum-playtest/env_meta.txt ~/dev/museum-playtest/force_loaded.txt
rm -rf ~/dev/museum-playtest/mcl_maps ~/dev/museum-playtest/templates ~/dev/museum-playtest/journals

# 3. Recreate the headless config (see SUMMARY.md's "environment map" for exact content)
#    at some path, e.g. /tmp/playtest.conf

# 4. Run headless (takes ~15-25 min for all 3 bases: placement + repair + loot + mobs)
~/dev/museum-testrig/bin/luanti --server --config /tmp/playtest.conf \
  --world ~/dev/museum-playtest --gameid mineclonia --logfile /tmp/playtest.log &
# poll: grep -n "ALL DONE\|ERROR" /tmp/playtest.log

# 5. Deploy to the client
DEST="/Users/dara/Library/Application Support/minetest/worlds/2b2t Museum TEST"
rm -rf "$DEST"
cp -R ~/dev/museum-playtest "$DEST"
rm -rf "$DEST/worldmods/museumloot"   # see SUMMARY.md for why this must be removed
```

**Before running the rebuild**, re-run the itemstring validator (cheap,
catches regressions from any further edits):

```python
import re
with open('/tmp/registered_items.txt') as f:  # regenerate this if it's gone, see below
    real = set(line.strip() for line in f if line.strip())
files = [
    '/Users/dara/dev/museum-import-kit/mods/museumloot/init.lua',
    '/Users/dara/dev/museum-import-kit/mods/museumloot/structures.lua',
]
pattern = re.compile(r'itemstring\s*=\s*"([^"]+)"')
item_call = re.compile(r'item\("([^"]+)"')
bad = {}
for path in files:
    text = open(path).read()
    found = set(pattern.findall(text)) | set(item_call.findall(text))
    for name in sorted(found):
        base = name.split(' ')[0]
        if base.startswith('group:'): continue
        if base not in real: bad.setdefault(path, []).append(base)
for path, names in bad.items():
    print(path); [print(' ', n) for n in names]
if not bad: print("all clear")
```

If `/tmp/registered_items.txt` is gone (it's in `/tmp`, won't survive a
reboot), regenerate it: add a throwaway worldmod to
`~/dev/museum-playtest/worldmods/zzitems/init.lua` —

```lua
core.register_on_mods_loaded(function()
	core.after(1, function()
		local f = io.open("/tmp/registered_items.txt", "w")
		local names = {}
		for name in pairs(core.registered_items) do names[#names+1] = name end
		table.sort(names)
		for _, n in ipairs(names) do f:write(n .. "\n") end
		f:close()
		core.after(1, function() core.request_shutdown("done", false, 0) end)
	end)
end)
```
plus a `mod.conf` with `name = zzitems`, boot headlessly, then delete the
throwaway mod.

Also syntax-check after any edit:
```bash
luajit -e "local f,err=loadfile('<path>'); if not f then print('SYNTAX ERROR: '..err) else print('OK') end"
```

## 2. Get the project owner to re-verify, specifically:

- Shulker boxes actually open now (fix #5 in summary — the *second*,
  correct fix, generating the formspec fresh rather than trusting stored
  meta). The screenshot showing "sticks open" predates this fix.
- Enchanted items now show real effects (fix #9).
- Loot variety feels right across the 8-category fallback split (fix #10)
  — the weights in `FALLBACK_POOL` (`museumloot/init.lua`, search for that
  name) are a first guess, expect to retune.
- No more wild shulkers/witches in random unrelated locations (fixes #7,
  #8) — witch false-positives are reduced, not eliminated; if still
  seeing them, the only real fix left is parsing witch_hut.lua's `.mts`
  schematic for a shape signature, which nobody's attempted yet.
- If a base with an actual detected village ever gets imported: confirm
  villagers actually appear with sensible professions. Not yet observed
  live (see summary).

## 3. Not started: DeepSeek LLM enrichment pass (stage 2)

Project owner's ask, paraphrased: gather nearby signs/blocks/entities as
structured context per container (e.g. `{"type":"sign","text":"Melons"}`),
send to DeepSeek, get back a themed suggestion, validate every returned
item name against `core.registered_items` before applying (this project has
already lost real time twice to unvalidated item names — see
`FEATURE-loot.md` and bug #6 in the summary — do not skip validation).
Key is ready at `~/dev/luanti/.env` (`DEEPSEEK_API_KEY`), gitignored.
`FEATURE-loot.md` section 4 has the original design spec for this stage
(batching, caching by content hash, theme-as-authoritative-over-item-list)
— re-read it, it's still the right design, just needs building. This is
explicitly meant to be a *separate* pass from the deterministic stage 1/3
system already built, not a replacement.

Suggested integration point: a new module (`llmloot.lua`?) that runs
*after* `structures.lua`'s check and *instead of* (or as a refinement to)
the sign-keyword `classify()` fallback, only for containers that have
actual sign text (per the spec: "containers with no nearby signs should not
be sent at all").

## 4. Not started: pillager outpost / woodland mansion mob detection

Both structures have loot tables already copied into `structures.lua`
(exposed as `structures.PILLAGER_OUTPOST_LOOT` /
`structures.WOODLAND_MANSION_LOOT`) but no detection heuristic — nobody's
found a reliable block signature without parsing the `.mts` schematic
files directly (`mods/MAPGEN/mcl_levelgen/pillager_outpost.lua` /
`woodland_mansion.lua`). If this matters enough to pursue: the schematic
files are binary `.mts` under those mods' own directories; Luanti's
schematic format is documented in `doc/lua_api.md` under "MTS" if you need
to parse one directly for a shape/size signature instead of relying on
block-type coincidence.

## 5. Not started: full `museum-world-rescue` rebuild

The project owner explicitly said they want a **full rebuild from scratch**
of the real 189-base world once the playtest world is verified — not an
in-place patch. Do NOT start this until step 2 above is confirmed good by
the project owner. When you do:

- The real corpus is at `~/dev/2b2tmuseum-WDL/` (13GB, 205 bases across the
  full manifest — `~/dev/museum-import-kit/manifest/museum_manifest.json`
  has all 205, not just the 3-base test set).
- `GUIDE-vps.md` (formerly GUIDE-vastai.md) has the original plan for running this on a rented box
  (full run was ~22h on USB 2.0 previously; should be much faster on a
  real machine/SSD, and this session's fixes don't change placement
  performance).
- Apply the dripstone-crash workaround (`mcl_disabled_structures =
  large_dripstone_column,large_dripstone_stalagmite,large_dripstone_stalagtite`)
  and `mcl_singlenode_mapgen = true` to whatever fresh `world.mt`/
  `map_meta.txt` you set up — these are NOT yet in `museum-world-rescue`'s
  current (old, being replaced) files, only in `museum-playtest`'s.
- `museumloot` should run as a genuine one-shot batch (its intended use —
  auto-kick + auto-shutdown when done), then get stripped from
  `worldmods/` before anyone plays the result, same as the playtest world.
- Expect the loot+mob pass to take a while longer than placement alone on
  205 bases — budget time accordingly, and consider running it as a
  separate pass after placement fully settles rather than back-to-back in
  the same session (this session found that running the loot pass
  immediately after placement, while other bases' pregen was still
  contending for the emerge thread pool, caused a transient
  massive-undercount on the first pass — a second run found everything
  correctly; not a correctness bug, just a timing quirk worth knowing
  about so it doesn't cause a false alarm).
- Barrels already placed as stone in the *old* `museum-world-rescue` are
  gone for good; the fresh rebuild fixes this going forward since the
  mapping fix (#4 in summary) is now in the kit.

## 6. Minor / lower priority

- `gear_netherite` theme (`museumloot/init.lua`) has no enchanted-variant
  entries yet, unlike `gear_diamond`/`gear_iron`/`gear_gold`. Trivial to
  add for consistency if it matters.
- `structures.lua`'s `structures.detect()` function signature still takes
  a `node_name` parameter that's now unused (the end_city container-node
  shortcut that used it was removed in fix #7). Harmless in Lua, but worth
  cleaning up the signature/docstring if you're back in that file anyway.
- Consider whether `museum-3bases` and `museum-freshtest` (older scratch
  worlds from mid-session debugging) are still needed or can be deleted —
  not asked for explicitly, use judgement / ask first.

## Round 2 (same day, after the section-1 rebuild): bugs found live, kit system built

Playing the rebuilt world surfaced two more real bugs and a substantial
new content request, all now fixed/built as of this writing. **The world
has been rebuilt and redeployed again after these** — if you're reading
this before doing your own rebuild, these are already live in
`2b2t Museum TEST`.

### Bug: shulker close animation never played, box "stuck open" and looked empty

Found right after the section-1 fixes went live: shulkers now opened and
showed real contents (fix #5 worked), but closing the formspec left the
box's 3D model stuck in the open pose, and — since `player_chest_close`
never ran — the entity's visual state never resynced, which read as "no
items were ever added." Root cause: `mods/ITEMS/mcl_chests/init.lua`'s
`core.register_on_player_receive_fields` global handler (the thing that
actually calls `player_chest_close` on `fields.quit`) only reacts to
formnames starting with `"mcl_chests:"` — fix #5's `"nodemeta:x,y,z"`
formname (needed at the time to make `list[context;...]` resolve) never
matched it. Real chests avoid this entirely: they never use `context` or
the `"nodemeta:"` naming convention at all — they address the inventory
list explicitly (`list[nodemeta:X,Y,Z;main;...]`) and use their own
`"mcl_chests:..."`-prefixed formname. Fixed the same way: the shulker's
`on_rightclick` now generates its formspec with `context` string-replaced
by an explicit `nodemeta:X,Y,Z` reference, and shows it under a
`"mcl_chests:shulker_X_Y_Z"` formname so the existing global close-handler
actually fires. Applied to both the dev checkout and the installed game
copy (they're back in sync — verify with `diff` if you're unsure, this is
exactly the kind of two-copies-diverge mistake this project has hit
before).

**This was found and fixed while the external drive was briefly
unplugged** (see the note at the top of this file) — the emergency patch
went straight to the installed game copy since that's all that was
reachable at the time, then was synced back to `~/dev/mineclonia` once the
drive returned. Both copies are confirmed identical now.

### Fix: sequential vs. random item placement (80/20 split)

Project owner's request: most chests should read as "packed in order"
(sequential slot fill), only a minority (20%) genuinely shuffled — the
previous behavior (`mcl_loot.fill_inventory`, always random-slot) made
every chest look deliberately jumbled, which reads as artificial.
`fill_inv_from_theme` (`museumloot/init.lua`) now rolls 20/80 on the same
seeded `pr` (deterministic per container) and either calls
`mcl_loot.fill_inventory` (random path, 20%) or does a plain sequential
`inv:set_stack("main", i, all_items[i])` loop (80%). Also cleaned up dead
code in the same function (`stacks_to_set` was built and then never used
— pre-existing before this session, harmless, just noise).

### Built: PvP kit shulker system (`museumloot/pvpkits.lua`, new file)

Project owner provided real reference screenshots from Oysterity (the
largest Luanti Mineclonia anarchy server) showing what player-packed "kit"
shulkers actually look like — full loadouts (armor+weapon+consumables)
packed into a single shulker box item, sometimes with a themed enchant
profile, sometimes with a nested shulker-inside-a-shulker "duplication
glitch" artifact. Built as a new sibling module (same `dofile` pattern as
`structures.lua`/`mobplacement.lua`), wired into `fill_inv_from_theme` via
two new theme keys:

- `"pvp_kit"` — places 1-3 pre-filled kit shulkers into a container.
  Triggered by sign keywords ("kit", "loadout", "pvp kit") and a modest
  weight (5) in the no-signal fallback roll.
- `"pvp_kit_closet"` — fills a container with 5-9 *different* kit
  shulkers, for the "a base might have an entire double chest full of
  them" case. Triggered by sign keywords ("kits", "kit room", "loadouts",
  "kit closet") — checked *before* the singular `"pvp_kit"` rule in
  `THEME_RULES`, since "kits" contains the substring "kit" and
  `THEME_RULES` matching is first-hit-wins.

**Important verified constraint, documented at the top of `pvpkits.lua`**:
this Mineclonia checkout has **no `protection`, `feather_falling`,
`thorns`, or `aqua_affinity` enchantments** (checked directly against
`mods/ITEMS/mcl_enchanting/enchantments.lua` — they simply aren't
registered, not a lookup miss). These exist in vanilla Minecraft and
apparently in Oysterity's version, but not here. Kit designs substitute
real equivalents instead of inventing fake enchant names that would
silently do nothing (e.g. the nether kit carries real
`mcl_potions:fire_resistance_splash` potions instead of a fictional "fire
protection" enchant). If the project owner wants closer parity with
Oysterity's enchant roster, those four enchantments would need to be
*implemented* in `mcl_enchanting` first — that's a real content-engineering
task, not a loot-table change, and nobody's attempted it.

Six kit templates built: `standard` (generic diamond PvP kit, Sharpness V),
`undead` (same chassis, Smite V instead — the project owner's own example
of a themed enchant swap), `nether` (netherite gear, Soul Speed III,
real fire resistance potions, nether valuables), `aquatic` (Respiration
III helmet, Depth Strider III boots, enchanted trident, enchanted fishing
rod, water/axolotl/tropical-fish buckets), `mineral` (no gear at all, just
full 64-stacks of diamond/emerald/netherite/gold/lapis/coal/quartz/iron
blocks), `restock` (bulk golden apples/potions/rockets, matches the
project owner's "チコRestock™" reference almost exactly). Plus three
single-item "mini kit" shulkers (Totems/Experience/Rockets, each a full
stack of one item across all 27 slots) used as the nested glitch payload.

**Nested glitch**: every "big" kit has a 5% chance (`NEST_CHANCE_PERCENT`
in `pvpkits.lua`) of replacing one filler slot with a mini-kit shulker
instead of a plain item stack — recreating the real anarchy-server
duplication-glitch aesthetic the project owner described. This works
because the kit shulker's contents are built directly via itemstack meta
(mirroring `mcl_chests`' own `get_shulker_stack()`/
`set_inventory_and_meta_from_stack()` round trip, not a real in-game
inventory-put interaction), so the normal "no shulkers inside shulkers"
restriction never gets a chance to apply.

All 296 itemstrings across `init.lua`/`structures.lua`/`pvpkits.lua`
validated against a fresh `/tmp/registered_items.txt` dump (regenerate via
the throwaway-worldmod pattern in section 1 above if it's gone — it's in
`/tmp`, won't survive a reboot). Exercised live end-to-end against all 3
playtest bases with zero errors: 84 kit shulkers generated across the 3
bases in the log run this was verified with (histogram key `pvp_kit`).

**Not yet verified by the project owner in-client**: whether a kit shulker
actually opens correctly and shows the packed contents as a real player
would see them (built via meta manipulation, syntax/logic-verified and
exercised in a real headless server with no errors, but nobody has
right-clicked one in the actual client yet), whether the nested-glitch
shulkers display/nest correctly when opened, and whether the kit
name/theme distribution feels right. Also not yet done: banners and base
names as loot/décor (the project owner mentioned these — "most bases have
a key to these too" — as separate observations about what real bases look
like, not yet translated into a specific build task; worth clarifying
scope with the project owner before guessing at one).

## Round 3 (same day): more live bugs found, loot rebalanced again

### Bug: every kit shulker showed "Unknown Item" in every slot

`pvpkits.lua`'s `build_kit_stack()` used Lua's generic `tostring(it)` to
serialize each `ItemStack` into the compressed meta blob, instead of the
real `ItemStack:to_string()` method. `tostring()` on the userdata does not
reliably produce a valid serialized itemstring, so every slot decoded back
into garbage on open. The real reference this mirrors
(`mcl_chests`' `get_shulker_stack()`) always calls `stack:to_string()`
explicitly — now fixed to match exactly. This is exactly the kind of thing
that looks like a data/content problem but was actually one wrong method
call; worth remembering if something similar happens again (e.g. a future
serialization helper) — check for `tostring(itemstack)` specifically.

### Bug: double chest halves rolled independent, mismatched loot

Confirmed live: a real double chest's left and right halves each got their
own independent `classify()`/structure-detect roll (since
`discover_containers_for_base` treats every container position
independently), which reads as broken once a player opens what's visually
one 54-slot chest and sees two unrelated loot types spliced together.
Fixed with a post-classification pass in `discover_containers_for_base`
(`museumloot/init.lua`) that finds `"_left"`/`"_right"` node-name pairs
within 2 blocks of each other and copies the `"_left"` half's
`theme_key`/`structure_match`/`structure_loot`/`structure_loot_use` onto
its `"_right"` partner. They still roll different *specific* items (each
half keeps its own position-seeded PRNG) — only the theme/pool is shared,
which is both correct (a real packed double chest isn't usually
item-for-item identical) and enough to fix the visible mismatch.

### Loot rebalance, round 2: sign keywords were over-triggering

Direct feedback after Round 2's rebuild: still "a lot lot lot of diamond
armor without much else... ~65% of boxes are a mix of diamond armor,
diamonds and a few other things," plain iron/gold armor reads as "trash by
the standards of most large stashes," and there wasn't enough true
fullness/emptiness variance. Root cause of the diamond dominance: sign
text takes priority over the fallback-pool roll entirely (see
`classify()`), and `THEME_RULES`' `gear_diamond` rule matched on
`"anarchy"`, `"best"`, `"meta"`, `"pro"` in addition to `"diamond"` — all
extremely common words in real 2b2t sign text for reasons that have
nothing to do with chest contents (base names, player names, general
bravado). That was routing a large fraction of *all labeled containers*
into `gear_diamond` regardless of real content. Dropped those four,
`"tools"` from `gear_iron` too (same over-triggering risk) — `"diamond"`/
`"pickaxe"`/etc. are left as genuine signals.

`FALLBACK_POOL` reworked again (weights sum to 100, in `museumloot/init.lua`,
search for that name for the current numbers): `gear_iron`/`gear_gold` cut
from 10 each to 4 each; added `gear_netherite` (was missing from the pool
entirely — a real gap, since netherite is exactly the "not trash" content
the feedback was asking for); added an `"empty"` key (weight 8) that
`fill_inv_from_theme` special-cases to skip filling entirely, for genuine
empty-container variance; `pvp_kit` bumped 5->8. A new "totally full"
mechanism: any container resolving through the plain `THEMES` path (not
structure loot, not a kit) has a 15% chance of running that theme's loot
roll a *second* time and appending the results, so a fraction of chests
end up packed near the 27-slot cap instead of every chest landing in the
same narrow "a handful of stacks" range.

**Not fully re-verified against the specific "65%/enchants are weak"
complaint** — the new weights and keyword tightening directly address the
described root cause and the live test run's theme histograms now show a
much flatter distribution (see the numbers in this round's log output),
but nobody has played the rebuilt world yet to confirm it *feels* right at
the target density. Retune weights further from played experience, not
guesswork.

### Suspected bug, reasoned but NOT live-verified: sign text on the wrong side

Project owner's own hypothesis ("signs not showing might be a placement
issue, i.e. they're on the wrong side") turned out to have real supporting
evidence: `mcl_signs`' own wall-sign `on_place`
(`mods/ITEMS/mcl_signs/init.lua`) computes its `param2` from
`core.dir_to_wallmounted(vector.subtract(under, above))` — i.e. the
direction **into** the wall the sign is attached to — not the direction
the sign/text faces the viewer, which is what Minecraft's `facing`
property (and the importer's original `FACING_TO_WALLMOUNTED` mapping)
represents. That's a systematic inversion for every wall sign the importer
places. Added a separate `SIGN_FACING_TO_WALLMOUNTED` table (inverted
north/south, east/west) used only at the wall-sign resolution site in
`lua_import/palette.lua`, and the matching fix in the Python oracle
(`import_tools/palette.py` on the external drive). **Deliberately did NOT
touch the shared `FACING_TO_WALLMOUNTED` table** — it's also used for wall
torches, ladders, wall heads/banners, and buttons, and nothing suggests
those have a custom `on_place` inverting the convention the way signs do;
changing the shared table risked fixing signs while silently breaking
several already-working node types. **This fix is reasoned from reading
mcl_signs' actual placement code, not confirmed by placing an imported
sign in-game and reading which way the text actually faces** — verify this
specifically before trusting it further. If it's still wrong after this
fix, the direction of the swap in `SIGN_FACING_TO_WALLMOUNTED` may need to
be reversed rather than removed.

### Confirmed real, likely NOT a bug in this project's code: villages generated by real terrain gen have no villagers or structure loot

Project owner found real Minecraft-style villages (screenshots show
farmland, composters, workstations, sandstone/desert-village architecture)
with no villagers and apparently no loot chests either. These are almost
certainly **freshly mapgen-generated villages in the real terrain now
surrounding the imported bases** (issue #2's fix — `mcl_singlenode_mapgen
= true` — means Mineclonia's own native village generation is running for
the first time in previously-unbuilt area), not imported content at all.
If so, villager/loot population for these is entirely `mcl_villages`' own
native responsibility, completely outside `spawnimport`/`museumloot`'s
reach — `mobplacement.lua` only ever scans the bbox of an *imported base*,
once, right after import; it has no way to know about or reach a village
mapgen created somewhere else in the world afterward, and wasn't designed
to. **This needs verification before concluding anything further**:
confirm these specific villages are actually outside every imported base's
registered bbox (almost certainly yes, but not checked), and separately
investigate whether Mineclonia's own native village population/loot
system works at all in this checkout when a village generates through
normal gameplay exploration (a completely separate question from anything
this project has built, and might be a real upstream engine/game issue,
or might just need more real-time-in-game for population to catch up, or
might need a settings flag nobody's checked). Do not assume this is
`spawnimport`/`museumloot`'s bug to fix without checking this first.

### Operational finding: the emerge-timing undercount is worse than documented, and stacked with itself across the session's builds

Section 1 already documented that running the loot pass immediately after
placement (while other bases' pregen is still active) can transiently
undercount containers, with "just run it again" as the fix. Round 3's
numbers make the scale of this much clearer: on the *very same* rebuilt
world, a first pass found 478/95/1453 containers across the three bases;
a second pass, run immediately after with nothing else changing, found
760/558/1453 — and picked up entire structure types (`structure:dungeon`,
`structure:end_city`) the first pass never detected *at all* for two of
the three bases. This isn't a small rounding difference; it's a large
fraction of a base's containers and, worse, entire *categories* of
structure-authentic loot silently missing on a single-pass run. **Always
run the loot pass at least twice before considering a build final** — this
is now standard procedure for every rebuild in this file, not optional
polish. Given the scale, this deserves a real fix before the full
205-base `museum-world-rescue` rebuild: either make `discover_containers_
for_base`'s emerge step actually wait out contention (e.g. check
`core.get_mapgen_stats()`-style backpressure, or simply don't start the
loot pass for a base until some time after its own placement completes,
not immediately after `stage 1`), or have the driver automatically re-run
each base's loot pass once more before marking it done. Nobody has
attempted either yet — the two-manual-runs approach used this session is
a workaround, not a fix.

## Round 4 (same day, IN PROGRESS as this is written — check for a background agent's completion before assuming this is done)

### Correction from the project owner

Round 3 wrongly assumed the villages-with-no-villagers screenshots were
freshly-generated Mineclonia terrain (from the `mcl_singlenode_mapgen =
true` fix). The project owner corrected this directly: those villages are
**inside the imported area, from the real world download** — confirmed by
checking the screenshot's debug-HUD coordinates against the manifest's
`dest_bbox` values (they fall inside Fort Alcazar's bbox). This is
imported content, squarely in this project's scope.

### Root cause of "zero villages ever detected, all session": `bell` and `composter` had NO import mapping at all

Checked `lua_import/palette.lua` and `import_tools/mc_to_mcl.json` (the
JSON is the source of truth for simple exact mappings, compiled into
`data.lua` via `import_tools/gen_lua_data.py` — never hand-edit
`data.lua`): neither `"minecraft:bell"` nor `"minecraft:composter"` had
any entry anywhere, at any tier. Both silently fell through the entire 4-
tier cascade to the tier-4 plain-stone default. `structures.lua`'s village
heuristic (a bell within 24 blocks, OR farmland+composter within 12) can
never fire if neither of those two node types has ever existed as a real
placed node in any imported base, on any run, all session — this fully
explains why `structure:village` never once appeared in any theme
histogram despite Fort Alcazar's real source data containing **25 real
bells** and (confirmed via the same NBT scan) **74 real villager entities**
in its `entities/*.mca` (never read by this pipeline by design — see
`HANDOVER.md` — `mobplacement.lua`'s village-spawn logic exists
specifically to compensate for that gap, but had nothing to detect against).

Fixed properly (not just a flat exact mapping — both need real property
handling):
- **bell**: MC's `attachment` property (`floor`/`ceiling`/`single_wall`/
  `double_wall`) selects between `mcl_bells:bell` (paramtype2="facedir"),
  `mcl_bells:bell_ceiling`, `mcl_bells:bell_wall` (both paramtype2=
  "wallmounted", confirmed by reading `mods/ITEMS/mcl_bells/init.lua`
  directly — nothing suggests a custom on_place inverting the wallmounted
  convention here the way signs do, so the ORIGINAL (non-inverted)
  `FACING_TO_WALLMOUNTED` table is used, not the sign-specific one).
- **composter**: MC's `level` property (0-8) selects between
  `mcl_composters:composter` (empty), `mcl_composters:composter_1..7`, or
  `mcl_composters:composter_ready` (level 8) — verified all 9 node names
  exist via a live `core.registered_items` dump before writing any of them.
- Both added to `lua_import/palette.lua`'s tier1 special-case section
  (property-based, can't be a flat JSON exact-mapping entry) AND mirrored
  in the Python oracle, `import_tools/palette.py` on the external drive.

### While fixing bell/composter, ran a full systematic audit — much bigger finding

Since two "obviously common" blocks turned out to have zero mapping,
audited comprehensively instead of waiting for the next one to surface via
a screenshot: decoded every distinct (block name, sample properties) pair
actually present in a full real base capture (Fort Alcazar — the biggest
of the 3 test bases, 473 distinct block types total) using the project's
own real Python NBT/Anvil decoder (`import_tools/anvil.py` — has real
zlib via Python stdlib, sidesteps the standalone-Lua harness's missing-
zlib limitation), dumped the results as a Lua-literal data file, and ran
them through the REAL production `palette.lua` (not the Python oracle,
which turned out to be stale/incomplete for at least wall-sign species —
worth knowing: **don't trust the Python oracle's coverage without
checking it against the Lua version first**, it lagged behind on at least
one thing this session already fixed in Lua months, uh, hours ago).

**Result: 114 of 473 distinct block types (24%) fell to the tier-4
default**, several with enormous instance counts in just this one base:
`nether_portal` 128,361(!), `dripstone_block` 93,180, `pointed_dripstone`
22,412, `bamboo` 21,801, `grass` (the plant) 19,164, `kelp_plant`+`kelp`
~19,900 combined, `polished_blackstone_bricks`+family ~11,900 combined,
plus dozens more (deepslate tile/brick variants, mud brick variants,
polished andesite/diorite/granite stairs/slabs, various walls, stripped-
log/wood species gaps, sculk family, and a long tail of smaller ones).
This means a large, currently-unmeasured fraction of every imported base's
visible terrain/architecture is silently wrong — solid gray stone where
there should be portals, dripstone caves, grass, bamboo, kelp, and a wide
range of stone/wood texture variants. This was never the focus of any
conversation this session (everything has been loot/mob/sign-focused) but
is almost certainly a bigger visual-fidelity issue than anything actually
discussed so far.

Fixed directly (highest-impact, simplest cases): `dripstone_block`
(direct 1:1), `grass`→`mcl_flowers:tallgrass`, `kelp`+`kelp_plant`→
`mcl_ocean:kelp` (MC's separate top/stem blocks collapse to Mineclonia's
one kelp node — an intentional simplification, not an oversight),
`nether_portal`→`mcl_portals:portal` (axis property → best-effort facedir,
a symmetric portal plane has no exact equivalent), `bamboo`→
`mcl_bamboo:bamboo_small` (no bare "bamboo" node exists in Mineclonia,
only staged small/big+leaf variants — closest reasonable stand-in),
`pointed_dripstone`→ a single collapsed tip shape (MC's thickness/
vertical_direction staged-growth properties aren't modeled — deliberate
simplification, matches the project's own "large dripstone STRUCTURE
GENERATION is already disabled for an unrelated engine crash, see
world.mt" note; placing the individual captured blocks is still correct
and safe, it just won't reproduce the exact original stalactite shape),
bare `shulker_box` (undyed, no color prefix — a real, distinct MC block,
not a typo) → `mcl_chests:violet_shulker_box_small` (violet is
Mineclonia's own canonical/default shulker color, matching vanilla's
naturally-purple undyed shulker). Also added several workstation blocks
found unmapped in the same sweep (relevant to villager profession
assignment in `mobplacement.lua`): `fletching_table`, `smithing_table`,
`cartography_table`, `stonecutter`, `loom`, `grindstone`, `blast_furnace`,
`smoker`, plus `lantern`, `campfire`, `lectern`, `chain`.

**Caught and corrected several wrong-guess node names before they shipped**
(verified against a live `/tmp/registered_items.txt` dump before writing
anything, per this session's hard-learned rule): guessed `mcl_chains:chain`
— real name is `mcl_lanterns:chain`; guessed `mcl_cartography_table:table`
— real is `mcl_cartography_table:cartography_table`; guessed
`mcl_lecterns:lectern` — real mod name is singular, `mcl_lectern:lectern`;
guessed `mcl_looms:loom` — real is `mcl_loom:loom`. This is exactly the
failure mode `FEATURE-loot.md` warned about, now hit and caught in a new
context (blocks, not items/enchants) — the verify-before-writing discipline
keeps paying for itself.

Re-ran the same audit after these fixes: **95 distinct block types still
default** (down from 114). These are the remaining fixes:
`SESSION_2026-09-17_remaining_block_defaults.txt` has the exact list with
counts, `SESSION_2026-09-17_block_samples_fort_alcazar.lua` has the real
sample properties for each. Mostly stone/deepslate/blackstone texture-
variant families (dozens of stair/slab/wall combinations — likely a
`STAIR_SLAB_SUBNAME`/`WALL_SUBNAME` table extension in `data.lua`/
`palette.lua`, not per-block special-casing, given the existing family-
driven pattern already in the file for other materials) and wood-species
gaps (stripped logs, "_wood" bark-all-sides variants, mangrove/crimson
species not in the current 6-entry `WOOD_SPECIES` list).

### Delegated: a background agent is fixing the remaining 95 (status unknown as of this writing)

A general-purpose agent was launched with the full worklist, the sample-
properties file, the exact verification methodology (grep real
`register_node` calls, cross-check against a live item dump, never guess),
and explicit instructions to sync `palette.lua` + the JSON/`data.lua` +
the Python oracle together, the same way this session has all along. **If
you're reading this and don't know whether that agent finished**: check
whether `lua_import/palette.lua` has changed since this file was last
touched, or just re-run the audit script yourself (see the Lua snippet a
few paragraphs up, or re-derive it — it's short) against
`SESSION_2026-09-17_block_samples_fort_alcazar.lua` to see the current
remaining-defaults count directly rather than trusting this doc's numbers,
which will go stale the moment that agent lands its changes.

### Not yet done as of this writing: rebuild + redeploy the playtest world with the Round 4 block-resolution fixes

`museum-playtest`'s headless config already points
`spawnimport_lua_import_path` straight at `~/dev/museum-import-kit/lua_import/`
(no separate copy needed for that world specifically), so the bell/
composter/nether_portal/bamboo/dripstone/shulker_box/workstation fixes
already committed to the kit will take effect on the next fresh rebuild
automatically. **A fresh rebuild has NOT been run since these Round 4
fixes landed** — do that (full wipe + rebuild + a second backfill pass,
per the now-standard two-pass procedure, then deploy to
`/Users/dara/Library/Application Support/minetest/worlds/2b2t Museum TEST`,
stripping `worldmods/museumloot` from the deployed copy same as always)
once the delegated agent's block-mapping work is confirmed complete —
doing it now would mean rebuilding twice. If you're picking this up and
the delegated agent's status is unknown/unclear, check its work is done
(re-run the audit) before deciding whether to rebuild now or wait.

### Still open, not addressed this round

- Villager profession assignment accuracy — depends on the workstation
  blocks fixed this round actually being present in a real village's
  captured area; not re-verified end-to-end (would need a real rebuild +
  a real detected village to check against, per the above).
- The `structures.lua` village-detection radius/heuristic itself (bell
  within 24 / farmland+composter within 12) was never actually wrong —
  only starved of real nodes to find. Once bells/composters resolve
  correctly, it should start firing; this has NOT been confirmed with a
  live rebuild yet (see above).
- Whether Mineclonia's sculk-family blocks exist as a concept in this
  checkout at all is unconfirmed — left to the delegated agent to
  determine and document rather than guess.
