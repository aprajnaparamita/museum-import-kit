# Real 2b2t / Oysterity kit reference (project owner, 2026-09-18)

Ground truth for what a real anarchy-server ("Oysterity", the largest
Luanti Mineclonia anarchy server) PvP kit shulker actually looks like,
transcribed directly from the project owner's in-game screenshots so this
doesn't have to be re-derived or guessed later. **Implemented into
`pvpkits.lua` this session** (see that file's `kit_standard` and
`kit_nether` for the live code) — this doc is the citation trail, not a
spec still waiting to be built.

## Design principles (owner's own words, condensed)

- **Kits should always be exactly the same.** A given kit archetype's
  core loadout (armor/weapon/tool set + enchants + names) is fixed, not
  re-rolled per instance. Variety comes from *which* archetype gets
  picked and what fills the remaining slots, not from watering down a
  specific archetype's identity.
- **Everything in a kit is the same high quality gear** — real captures
  read as deliberately curated, not randomly assembled.
- Real 2b2t/Oysterity gear is commonly **OP beyond vanilla limits**: more
  enchants stacked on one item than vanilla Minecraft would allow
  (Knockback II + Sharpness V + Looting III + Fire Aspect II all on one
  sword), always including Mending.
- Custom item **names** (not just enchants) are part of the realism —
  `チコWarboots™w`, `FISHY 4`, `Tux's CubeSlayer™M`, etc.
- Kits vary by purpose: a Nether-flavored kit carries Fire Resistance
  potions, Potion of Invisibility **+** (the extended-duration variant,
  ~8 minutes), and Potion of Swiftness **II**.
- Some shulkers are **single-item mega-stacks**, not loadouts at all —
  e.g. a shulker that's nothing but Bottles o' Enchanting ×64 per slot,
  or nothing but Totems, or nothing but Enchanted Golden Apples ("Dgabs"
  in the owner's own shorthand).
- These single-item shulkers sometimes appear **nested inside** a bigger
  kit shulker (a real anarchy-server dupe-glitch aesthetic — see
  `pvpkits.lua`'s `maybe_nest`), and sometimes appear as **top-level**
  shulkers in their own right, not nested at all.
- Real color-coding observed for the single-item flavor: **green** =
  Bottles o' Enchanting, **yellow** = Totems, **red** = Fireworks.
- **Minerals shulker**: no armor/weapons, just full ×64 stacks of every
  valuable block (diamond/emerald/netherite/gold/lapis/coal/quartz/iron
  blocks), every slot full.
- **~50% of already-placed shulker boxes** in a base should end up as
  some kind of kit (PvP loadout, kit closet, or single-item mega-stack),
  not generic random loot — kits are common, not rare. (Bumped to 75%
  round 3, see `HANDOFF.md`.)
- **Kits are FIXED, deterministic sets — never randomly padded with
  singles** (owner, round 4): "Kits are FIXED sets of chosen items where
  every slot matters. Nobody would have one apple wasting a space." An
  Enchanted Golden Apple, Bottle o' Enchanting, Totem, or Firework Rocket
  never appears as a single/loose item in a real kit — always as a full
  27-slot mini-kit shulker of that one item (see "Universal essentials"
  below). Never more than one Obsidian stack ("these are anchors"), not
  normally more than one End Crystal stack, and exactly one Water Bucket
  x16 / Lava Bucket x16 each — never two of either.
- **No biome/mob/location-drop items, ever** (owner, round 4): "A kit
  should NEVER have items as drops from their location, biome or
  target. It would rather be for either fighting mobs there or PvP in
  that location/biome." (E.g. `kit_undead` should never contain a
  wither skull, zombie head, rotten flesh, or bone — those are drops,
  not combat gear. Replace with combat-useful items instead: potions,
  totems, etc.)

## "Tux Kit II" — the reference loadout (verbatim from screenshots)

This is now `pvpkits.lua`'s `kit_standard` (the highest-weight, "the
standard kit" pick). All items are netherite-tier, matching 2b2t's real
top-tier gear economy (diamond is not endgame there).

| Item | Custom name (verbatim) | Enchants shown in-game (verbatim) |
|---|---|---|
| Netherite helmet | `Tuxanian HeadProtector™` | Mending, Unbreaking III, Protection IV, Respiration III |
| Netherite chestplate | `Tuxanian Chestplate™` | Mending, Protection IV, Unbreaking III, + Wayfinder Armor Trim (Redstone Material) |
| Netherite leggings | `Tuxanian Leggings™` | Mending, Protection IV, Unbreaking III, + Wayfinder Armor Trim (Netherite Material) |
| Netherite boots | `TuxanianBoots™` | Depth Strider III, Protection IV, Unbreaking III, Mending, Soul Speed III, Feather Falling IV |
| Netherite sword | `FISHY 4` | Looting III, Fire Aspect II, Mending, Sharpness V, Unbreaking III, Knockback II |
| Mace | `Tux's CubeSlayer™M` | Unbreaking III, Mending, Breach IV, Fire Aspect II, Wind Burst I |
| Netherite axe | `Netherite Axe` | Silk Touch, Unbreaking III, Mending, Sharpness V, Efficiency V |
| Netherite pickaxe | `vivixyes pickaxe` | Mending, Efficiency V, Silk Touch, Unbreaking III |
| Elytra | *(none — literally shown as the internal id `mcl_wings`)* | Mending, Unbreaking III |

**What got filtered out and why**: this Mineclonia checkout has **no
`protection`, `feather_falling`, `thorns`, or `aqua_affinity`
enchantments registered at all** (verified against
`mods/ITEMS/mcl_enchanting/enchantments.lua` — this was already known
from earlier PvP-kit work, re-confirmed this session). Rather than
invent fake enchant names that would silently do nothing (this project
has lost real time to exactly that failure mode with item names before),
those are dropped from the implemented version.

**Correction (2026-09-18, found while verifying the fresh rebuild)**:
an earlier draft of this doc also claimed "no armor trim system" — that
was wrong, caught by not actually checking `mods/ITEMS/mcl_armor/trims.lua`
before writing it down (the exact mistake this project's own conventions
warn about). Armor trims **are** real and fully implemented here —
`mcl_armor.trim(itemstack, overlay, trim_material)` applies one
programmatically (no GUI needed), and `mcl_armor:wayfinder` (the trim
shown in the real reference) is a real registered craftitem via
`mcl_smithing_table`. The real chestplate/leggings' "Wayfinder Armor
Trim" upgrades are still **not wired into `kit_standard` yet** — that's
a legitimate follow-up, not something ruled out by an engine limitation.
Everything else above — including `breach`
(max level 4, confirmed) and `wind_burst` (max level 3, confirmed) on the
mace, and `knockback` (max level 2, confirmed) on the sword — uses only
enchantments actually verified present in `enchantments.lua` this
session, at their real max levels.

Real item ids used (verified against `~/dev/mineclonia` source, not
guessed): `mcl_tools:mace` (real, exists), `mcl_tools:axe_netherite`,
`mcl_tools:pick_netherite` (**not** `pickaxe_netherite` — the tool-set
registration in `mods/ITEMS/mcl_tools/init.lua` uses the short key
`"pick"`, not `"pickaxe"`, for every material tier), `mcl_tools:sword_netherite`.

## Nether Kit additions (owner explicit, 2026-09-18)

Added to `pvpkits.lua`'s `kit_nether`, alongside the fire resistance
splash potions already there:

- Potion of Invisibility **+** (extended duration, ~8 min real-Minecraft
  equivalent) — `mcl_potions:invisibility_splash` with itemstack meta
  `mcl_potions:potion_plus = 1` (verified against
  `mods/ITEMS/mcl_potions/potions.lua`'s `register_potion` — there is no
  separate "extended" itemstring, the tier lives in stack meta).
- Potion of Swiftness **II** — `mcl_potions:swiftness_splash` with meta
  `mcl_potions:potion_potent = 1` (same mechanism; verified swiftness's
  effect definition has `uses_factor = true` in
  `mods/ITEMS/mcl_potions/functions.lua`, so it actually supports a level
  tier, unlike e.g. invisibility).
- **"Stacked if possible" is not possible**: potions default to
  `stack_max = 1` in this engine and none of fire_resistance/invisibility/
  swiftness override that, matching real Minecraft potion behavior. Each
  fills its own slot instead.

## Single-item mega-stack shulkers ("mini kits")

Implemented in `pvpkits.lua`'s `MINI_KITS` + `build_mini_kit_of`,
selectable nested (5% `maybe_nest` chance inside a bigger kit), as a
shulker's entire top-level contents (`BIG_KITS`), AND — new in round 4,
the real "Tuxerian kit" reference — **unconditionally, every single
time, inside every big kit's `add_universal_essentials`**:

| Color | Contents |
|---|---|
| green | Bottle o' Enchanting ×64 per slot |
| yellow | Totem of Undying ×64 per slot |
| red | Firework Rocket ×64 per slot *(was incorrectly "black" before this session — real reference shows red)* |
| orange | Enchanted Golden Apple ("Dgabs") ×64 per slot |
| dark_grey | Potion of Invisibility+ ×64 per slot *(new round 4, "Invisibility+ ... pretty common" — top-level weight 3 + a `maybe_nest` option, NOT one of the four unconditional essentials above)* |

**Round 4, owner's own real "Tuxerian kit" reference** (images #41/#42):
"This Tuxerian kit from Oysterity contains a red shulker called rockets
which is full entirely... a green shulker called Experience which is
100% full... of Bottle o' Enchanting 64, And a Yellow shulker which is
full of ALL slots with totems... a shulker completely full with ALL
slots of stacks of Enchanted Golden Apples... All kits should have these
in place of the bare item, i.e. no Enchanted golden apples by
themselves, just the shulker... These kits are designed so killed
players can pull a shulker in a fight, grab everything inside and place
it in their inventory and then go back out." This settles the earlier
open question below about the "all three colors in one box" pattern:
every big kit's `add_universal_essentials` now always nests all four
(green/yellow/red/orange) at once, exactly matching this reference —
it's not a rare coincidence, it's the fixed design.

## Minerals shulker

Matches `pvpkits.lua`'s existing `kit_mineral` almost exactly already
(no changes needed) — full ×64 stacks of diamond/emerald/netherite/gold/
lapis/coal/quartz/iron blocks, no armor or weapons, every slot full.

## Netherite-armor "restock" shulker (observed, not yet implemented)

The owner's reference screenshot for "a shulker filled with Netherite
armor" shows **multiple duplicate copies** of full netherite gear sets
(several helmets, several chestplates, several sets of tools) — a
resupply shulker for a squad, not a single loadout. `pvpkits.lua`'s
existing `kit_restock` is consumables-only (golden apples / healing
potions / XP bottles). A gear-duplicate variant of restock is a
reasonable follow-up but was **not** added this session — flagging it
here rather than guessing at exactly how many duplicates/which pieces
real examples favor.

## Related block-mapping evidence (new this session, feeds C1/C2)

Two fresh screenshots from the project owner's playtest session
(2026-09-18, ~01:07-01:08 local) show block-mapping problems consistent
with the still-open C1/C2 items in `HANDOFF.md`:

- A cliff/tree area (pos ~419, 86, 362.6) where tree trunks read as plain
  stone texture instead of wood/leaves — likely another silently-defaulted
  block type in the same family as the C2 "mystery stone block" report,
  not yet root-caused.
- An interior room (pos ~477.9, 104.5, 326.4) where node name-tag labels
  read "Barrel" floating over blocks that visually render as plain stone/
  cobble rather than the real barrel texture — consistent with C1's
  hypothesis that VoxelManip bulk placement is breaking a container's
  visual state independent of its functional `on_construct` repair (the
  tag says "Barrel", the texture doesn't match).

Both need the standard Round 4 audit method (`HANDOFF.md`'s "Round 4
audit method" section): get the real coordinates' source-capture block
data, cross-reference against a live `registered_nodes` dump, don't
guess.
