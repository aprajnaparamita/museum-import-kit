# Loot vocabulary design — 256 chest categories

Companion to `FEATURE-loot.md` §3–§5. The vocabulary is the surface Jev
(`choice` question) picks from; this doc owns the taxonomy. Index `0` =
most common chest type, index `255` = rarest. Stage 3 (apply) reads
`index → name → items[]` and fills the container.

## Why 256

Hard-coded by the FEATURE spec, and it fits `choice`-question ergonomics
nicely (one byte, 8 bits of entropy per decision). The split below —
**4 universal + 84 themes × 3 dimensions = 256** — leaves room for 84
distinct content shapes and lets every theme's "what's actually inside"
shift with the dimension the container sits in, which is the whole point
of the user's "separate but the same categories based on the dimension"
ask.

## The split

```
┌─────────────────────────────────────────────────────────────────┐
│ 4 universal themes (no dim variant — same in every dim)         │
│   • pvp_kit_standard     — full enchanted netherite Tux-style   │
│   • pvp_kit_closet       — 5–9 nested kit shulkers              │
│   • fallback_local_misc  — catch-all, stage-3 dim/biome bias    │
│   • empty_chest          — deliberate ~3–5% empties             │
├─────────────────────────────────────────────────────────────────┤
│ 84 content themes × 3 dimensions (overworld / nether / end)     │
│   • theme name is dim-invariant; bundle contents are not        │
│   • Jev picks the dim-suffixed variant ("cobblestone_bulk_end")│
│   • stage 3 reads dim via container position, not from the pick │
└─────────────────────────────────────────────────────────────────┘
```

Why this shape rather than one entry per (theme, dim) pair for Jev and
let stage 3 swap contents based on dim at apply-time: Jev has no
position signal to read the dimension itself; the only signal it gets is
sign text + item frames + container type + cluster size (FEATURE-loot.md
§3). A container labelled "Building Blocks" in the End is more likely
end-stone than cobblestone regardless of what the sign says, so we want
Jev to *see* the dimensioned name as a distinct option — that lets its
prior knowledge of 2b2t-style storage kick in instead of forcing stage 3
to second-guess a dim-agnostic pick.

## The 84 themes

Grouped by the CSV/TSV catalog the user pointed at, condensed so the
84-count is met without overlap. Full per-entry items live in the JSON.

| group | count | themes |
|---|---:|---|
| **Blocks bulk** | 20 | cobblestone, stone, dirt_gravel_sand, logs_all, planks_all, wool_carpet, terracotta_concrete, glass_stained, bricks_general, obsidian_bulk, netherrack_basalt_blackstone (also covers quartz + amethyst, dim-inf: nether = full, end = end_stone skew, ow = small), end_stone_purpur, deepslate, sandstone, stone_variants_igneous (granite/diorite/andesite/tuff + sculk), prismarine, copper_blocks, stairs_slabs_walls, doors_trapdoors_fences, lanterns_torches |
| **Minerals/ores** | 8 | coal, iron, gold, diamond, emerald, lapis, redstone, netherite_block (rare) |
| **Food** | 7 | cooked_meat_fish, bread_baked_goods, golden_carrots_baked_potato, sweet_berries_melon_block, raw_produce_garden, seeds_bulk, cake_pumpkin_pie_cookies |
| **Combat** | 11 | arrows_tipped, bows_crossbows, swords_iron, swords_diamond, swords_netherite_max, mace_max, trident_max, axes_netherite_max, shields, cobwebs_pvp_trap, TNT |
| **Armor** | 8 | leather_armor, iron_armor, diamond_armor, netherite_armor_max (the OP bread-and-butter), gold_helmet_boots, elytra_max, horse_wolf_armor, smithing_templates_trims |
| **Tools** | 6 | wood_stone_tools, iron_tools, diamond_tools, netherite_tools_max, fishing_rod, shears_compass_clock_lead |
| **Consumables** | 8 | golden_apples, enchanted_golden_apples_64stack, experience_bottles_64stack, totems_of_undying, fireworks_rockets_64stack, ender_pearls_16stack, splash_healing_max, splash_harming_max |
| **Potions** | 5 | strength_swiftness_splash_max, invisibility_splash_extended_max, fire_resistance_splash_max, water_breathing_splash, weakness_poison_lingering |
| **Mob drops** | 7 | rotten_flesh_bone_string, gunpowder_spider_eye, blaze_rod_powder_ghast_tear, phantom_membrane, ender_pearl_eye_of_ender, slime_ball_magma_cream, wither_skull_trophy |
| **Enchanting/brewing** | 4 | enchanted_books_god_max, regular_enchanted_books, brewing_ingredients, nether_wart_blaze_powder_fermented |
| **Total** | **84** | |

(Counted: 20+8+7+11+8+6+8+5+7+4 = 84. Merges from the original 86-theme
draft: `quartz_amethyst` folded into `netherrack_basalt_blackstone`
(all nether-native blocks), `sculk_bulk` folded into
`stone_variants_igneous` (other miscellaneous stone-family blocks). Both
can split out later if the runner wants finer-grained dim-bias — see
"Open knobs" below.)

## Rarity ordering — wealthy-base model

The index ordering reflects **how common that chest type is across
these specific wealthy 2b2t bases**, not vanilla-Minecraft rarity, and
not raw value either. The owner confirmed the model on 2026-09-28 with
three direct examples:

- A "Misc"-labeled chest → almost certainly common junk / mass supplies
- A "Boots"-labeled chest → almost certainly max enchanted netherite
  boots (because these bases hoard OP — diamond boots wouldn't be in
  a labeled boots chest)
- Diamond / iron armor → uncommon downgrade, because "most of these
  bases have full netherite everywhere"

So vanilla-Minecraft rarity is inverted for the gear tiers. Raw ores
(coal, iron, raw diamond) drop to mid-rank because wealthy players have
already smelted them into blocks. Netherite-max gear sits LOW — Jev
should pick `netherite_armor_max_*` (idx ~54, rank 22) readily when it
sees an armor-themed signal. `diamond_armor_*` (idx ~216, rank 125)
and `iron_armor_*` (idx ~170, rank 100) sit in the uncommon tier.
PvP staples (ender pearls, totems, exp bottles, splash potions, golden
apples) sit LOW because they're what the labels actually point at.

Approximate tier breakdown of the 256 indices:

| tier | indices | what lives there |
|---|---|---|
| 0 — common in wealthy bases | 0–39 | PvP staples (pearls/totems/exp/golden apples/splash potions/cobwebs/TNT), cobble/stone/dirt, obsidian bulk, netherite-armor-max / swords-netherite-max / axes-netherite-max (full OP sets), cooked food, lanterns/torches, arrows |
| 1 — common | 40–89 | common building blocks (logs/planks/stairs/doors), netherrack/basalt/end-stone bulk, common food, sandstone/deepslate/stone-variants, shields, brewing supplies |
| 2 — uncommon (downgrade) | 90–149 | iron / diamond gear (enchanted), raw ores, gold/redstone, decorative blocks, leather/horse/wolf armor, fishing rod, mob drops, regular enchant books, water-breathing/weakness potions |
| 3 — rare | 150–209 | netherite block (rare even for wealthy), mace_max, trident_max, enchanted_books_god_max, wither_skull_trophy |
| 4 — very rare | 210–249 | (empty — pvp_kit entries live in universal slots 252–253) |
| 5 — universal | 250–255 | pvp_kit_standard, pvp_kit_closet, fallback_local_misc, empty_chest |

**Important:** the tier of a *category name* and the OP-ness of the
*bundle inside it* are decoupled. `netherite_armor_max` lives at a
*common* tier index (because in labeled armor chests across these
wealthy bases, OP netherite is the default), AND its `items[]` is the
most OP possible loadout — exactly what the project owner asked for
("the model should always pick OP items like Netherite everything
with max enchants"). Both properties point the same direction for
OP-gear entries: low index AND max-enchant contents.

**For Jev's argmax**: when a chest is sign-labeled "Boots", the
distribution will peak around the `netherite_armor_max` dim variants
(indices ~54–57), and the runner takes that argmax. When a chest is
sign-labeled "Misc", the distribution peaks around the
common-supplies entries (indices 1–35 — cobble/dirt/obsidian/ender
pearls/totems/exp bottles, etc.). When unlabeled, Jev's prior on the
corpus distribution kicks in and the peak is also in tier 0.

## OP-ification rule (the "chest plates" example)

Every "real gear" entry's `items[]` is the **end-state, max-enchant
form**, not the raw material. Concretely:

- `netherite_armor_max` items = full set of netherite helmet/chestplate/
  leggings/boots, each with the highest enchants this Mineclonia
  checkout actually registers (no Protection/Feather Falling/Thorns/
  Aqua Affinity — see `pvpkits.lua` header) — *not* a single chestplate
  stack.
- `swords_netherite_max` items = one or more max-enchant netherite
  swords (Sharpness V, Looting III, Fire Aspect II, Mending, Unbreaking
  III, Knockback II) plus the universal essentials — *not* a stack of
  swords.
- `diamond_gear` items = full enchanted diamond set — *not* raw diamonds.
- `ender_pearls_16stack` items = multiple stacks of 16 ender pearls —
  *not* a single pearl.

The vocabulary is the surface Jev picks from; "chest plates" the user
mentioned is shorthand for "a chest labelled / framed / themed as chest
plates would contain, which is the OP version of that intent."

## Dimension-influence rules

For each `theme × dim` triple, the `items[]` is built from a base
shape, then biased by dimension:

- **overworld** (`*_ow`): default baseline. Mass junk and building
  blocks dominate (per the corpus, ~70% of containers in OW bases are
  bulk blocks / ores / cobble).
- **nether** (`*_nether`): bias toward nether-native blocks/items
  (netherrack, basalt, blackstone, quartz, soul sand, nether wart,
  blaze rods, ghast tears, magma blocks). Glowstone/obsidian stacks
  inflated (2b2t staple for travel). Netherite-block entries bumped.
- **end** (`*_end`): bias toward end-native blocks (end stone, purpur,
  chorus, end rods). Dragon-head/wither-skull trophy entries bumped.
  Shulker-shell entries inflated. No mob drops except for ender
  pearls / chorus fruit.

The bias is at *stage 3*, not stage 2 — the picked category is
dim-suffixed, stage 3 reads the container's dimension from its position
and weights the bundle items accordingly. Jev just needs the dim name
in the option list; it doesn't need to know what each variant contains.

## Universal themes (4)

| index | name | items shape |
|---:|---|---|
| 252 | `pvp_kit_standard` | full netherite enchanted Tux-style kit (per `pvpkits.lua` `kit_standard`) |
| 253 | `pvp_kit_closet` | 5–9 nested kit shulkers, mixed archetypes |
| 254 | `fallback_local_misc` | generic-misc roll, weighted toward whatever blocks/items the container's local area contains (cluster scan + nearest-sign reads). Stage 3 picks, Jev gets ~zero probability here unless truly ambiguous. |
| 255 | `empty_chest` | deliberately empty (the 3–5% texture-from-searches rule) |

All four are dim-agnostic at stage 2; stage 3 re-reads position to
apply any dim bias needed (`fallback_local_misc` in particular).

## Verification targets (FEATURE-loot.md §7)

- [ ] every entry's `items[]` resolves to real registered itemstrings
      in this Mineclonia checkout (no fictional enchant names — see
      `pvpkits.lua` header for the enchant whitelist this codebase
      actually has)
- [ ] selection histogram, run on iTristan's stash, has tier-0/1
      categories dominating (~70–80% of containers given the wealthy
      corpus), tier-2 ~10–15%, tier-3 ~2–5%, tier-5 ~3–5%
      (deliberate empties)
- [ ] argmax on a clear "Building Blocks" sign in an End container
      lands on an `*_end` block variant (e.g. `end_stone_purpur_end`),
      not an overworld variant
- [ ] argmax on a "kit" / "loadout" sign lands on `pvp_kit_standard`,
      not on a generic netherite armor entry
- [ ] argmax on a "Boots" / "Armor" sign in an OW mega-base lands on
      `netherite_armor_max_overworld` (idx ~54), NOT `diamond_armor_*`
      or `iron_armor_*`
- [ ] argmax on a "Misc" / unlabeled chest in a wealthy base lands in
      tier 0 (pearls/totems/exp/cobble/obsidian), not in tier 1+

## Open knobs (worth a follow-up pass)

1. **84 vs more.** If 86 themes would help (no shape-merge), the
   surplus eats into the 4 universal slots — easy swap.
2. **Dim-bias at stage 3 vs stage 2.** Currently dim-bias is applied at
   stage 3 from container position; Jev only sees the dim-suffixed
   *name*. Alternative: collapse to dim-agnostic names and let stage 3
   pick the dim entirely. The chosen shape makes the option list
   longer but lets Jev's prior on real 2b2t storage fire on the
   dimension directly — probably the right trade for the Jev-decision
   paradigm in FEATURE-loot.md §4.
3. **PvP kit rarity.** The project owner wants kits *common* in
   labelled-kit rooms ("a base might have an entire double chest full
   of them" — `pvpkits.lua` header) but the corpus-wide rate is low
   because most containers aren't kit-labelled. The vocab reflects the
   corpus (kits rare) and the runner / `pvp_kit_closet` weighting can
   upweight when a container is sign-labelled "kit" / "loadout" /
   "closet". Worth confirming the runner's labelled-sign path does
   this before shipping.