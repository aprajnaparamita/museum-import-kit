#!/usr/bin/env python3
"""
Generates the 256-entry loot vocabulary JSON from a structured theme list.

Companion to vocab_design.md. Output: loot_vocab.json.

Contract (FEATURE-loot.md §4):
- 256 integer-keyed entries, 0..255
- index = rarity rank (0 = most common in these wealthy bases, 255 = rarest)
- each entry has: name, theme, dimension, rarity_rank, items[]
- "items" is descriptive at this stage (human-readable bundles); the
  real mcl_* itemstring mapping happens at stage 3 against this
  Mineclonia checkout's registered_nodes.

Wealthy-base rarity model (owner-confirmed 2026-09-28):
- "Misc"-labeled chest  -> common junk / mass supplies (low rank)
- "Boots"-labeled chest -> max enchanted netherite boots (low rank,
   because these bases hoard OP)
- Diamond / iron gear   -> uncommon downgrade (mid rank)
- Raw ores (coal/iron)  -> uncommon (mid rank) — wealthy players
                           have these smelted into blocks already
- mace / trident max    -> rare even for wealthy (mid-high rank)
- god books / beacons   -> rare (high rank)
- pvp kits              -> rare in unlabeled corpus, common in labeled
                           kit rooms (universal slots, ranked high)
"""

import json
import os

# -- 84 content themes, grouped. Order within group = order they appear
#    in the dim-suffixed triplets below. --
THEMES = [
    # ---- Blocks bulk (20) ----
    ("cobblestone",                "blocks"),
    ("stone",                      "blocks"),
    ("dirt_gravel_sand",           "blocks"),
    ("logs_all",                   "blocks"),
    ("planks_all",                 "blocks"),
    ("wool_carpet",                "blocks"),
    ("terracotta_concrete",        "blocks"),
    ("glass_stained",              "blocks"),
    ("bricks_general",             "blocks"),
    ("obsidian_bulk",              "blocks"),
    ("netherrack_basalt_blackstone", "blocks"),
    ("end_stone_purpur",           "blocks"),
    ("deepslate",                  "blocks"),
    ("sandstone",                  "blocks"),
    ("stone_variants_igneous",     "blocks"),
    ("prismarine",                 "blocks"),
    ("copper_blocks",              "blocks"),
    ("stairs_slabs_walls",         "blocks"),
    ("doors_trapdoors_fences",     "blocks"),
    ("lanterns_torches",           "blocks"),
    # ---- Minerals / ores (8) ----
    ("coal",                       "minerals"),
    ("iron",                       "minerals"),
    ("gold",                       "minerals"),
    ("diamond",                    "minerals"),
    ("emerald",                    "minerals"),
    ("lapis",                      "minerals"),
    ("redstone",                   "minerals"),
    ("netherite_block",            "minerals"),
    # ---- Food (7) ----
    ("cooked_meat_fish",           "food"),
    ("bread_baked_goods",          "food"),
    ("golden_carrots_baked_potato","food"),
    ("sweet_berries_melon_block",  "food"),
    ("raw_produce_garden",         "food"),
    ("seeds_bulk",                 "food"),
    ("cake_pumpkin_pie_cookies",   "food"),
    # ---- Combat (11) ----
    ("arrows_tipped",              "combat"),
    ("bows_crossbows",             "combat"),
    ("swords_iron",                "combat"),
    ("swords_diamond",             "combat"),
    ("swords_netherite_max",       "combat"),
    ("mace_max",                   "combat"),
    ("trident_max",                "combat"),
    ("axes_netherite_max",         "combat"),
    ("shields",                    "combat"),
    ("cobwebs_pvp_trap",           "combat"),
    ("TNT",                        "combat"),
    # ---- Armor (8) ----
    ("leather_armor",              "armor"),
    ("iron_armor",                 "armor"),
    ("diamond_armor",              "armor"),
    ("netherite_armor_max",        "armor"),
    ("gold_helmet_boots",          "armor"),
    ("elytra_max",                 "armor"),
    ("horse_wolf_armor",           "armor"),
    ("smithing_templates_trims",   "armor"),
    # ---- Tools (6) ----
    ("wood_stone_tools",           "tools"),
    ("iron_tools",                 "tools"),
    ("diamond_tools",              "tools"),
    ("netherite_tools_max",        "tools"),
    ("fishing_rod",                "tools"),
    ("shears_compass_clock_lead",  "tools"),
    # ---- Consumables (8) ----
    ("golden_apples",              "consumables"),
    ("enchanted_golden_apples_64stack", "consumables"),
    ("experience_bottles_64stack", "consumables"),
    ("totems_of_undying",          "consumables"),
    ("fireworks_rockets_64stack",  "consumables"),
    ("ender_pearls_16stack",       "consumables"),
    ("splash_healing_max",         "consumables"),
    ("splash_harming_max",         "consumables"),
    # ---- Potions (5) ----
    ("strength_swiftness_splash_max", "potions"),
    ("invisibility_splash_extended_max", "potions"),
    ("fire_resistance_splash_max", "potions"),
    ("water_breathing_splash",     "potions"),
    ("weakness_poison_lingering",  "potions"),
    # ---- Mob drops (7) ----
    ("rotten_flesh_bone_string",   "mob_drops"),
    ("gunpowder_spider_eye",       "mob_drops"),
    ("blaze_rod_powder_ghast_tear","mob_drops"),
    ("phantom_membrane",           "mob_drops"),
    ("ender_pearl_eye_of_ender",   "mob_drops"),
    ("slime_ball_magma_cream",     "mob_drops"),
    ("wither_skull_trophy",        "mob_drops"),
    # ---- Enchanting / brewing (4) ----
    ("enchanted_books_god_max",    "enchant"),
    ("regular_enchanted_books",    "enchant"),
    ("brewing_ingredients",        "enchant"),
    ("nether_wart_blaze_powder_fermented", "enchant"),
]

assert len(THEMES) == 84, f"theme count is {len(THEMES)}, expected 84"

# -- Rarity ranks, wealthy-base model (owner-confirmed 2026-09-28).
#    Within each group, list is FIFO matching the THEMES order above. --
#
# Tier bands:
#   0..39   common in wealthy bases: PvP staples + OP netherite max gear
#            + common building blocks + common supplies
#   40..89  common resources: building blocks mid, food, shulkers,
#            brewing, raw obsidian (2b2t staple)
#   90..149 uncommon (downgrade): diamond/iron gear, raw ores, gold,
#            decorative blocks, regular enchant books, mob drops
#   150..209 rare: mace/trident max, god books, beacons, wither skull,
#            netherite block (rare even for wealthy)
#   210..249 very rare: pvp kits (universal slots live here)
#   250..255 universal + legendary

RARITY_BY_GROUP = {
    # blocks: cobble+stone+dirt are ultra-common (every mega-base has
    # thousands), obsidian is a 2b2t staple, decorative blocks drop
    "blocks": [
        5,    # cobblestone
        30,   # stone
        25,   # dirt_gravel_sand
        35,   # logs_all
        38,   # planks_all
        70,   # wool_carpet
        75,   # terracotta_concrete
        72,   # glass_stained
        78,   # bricks_general
        8,    # obsidian_bulk (2b2t staple)
        55,   # netherrack_basalt_blackstone
        58,   # end_stone_purpur
        62,   # deepslate
        68,   # sandstone
        50,   # stone_variants_igneous
        80,   # prismarine
        82,   # copper_blocks
        40,   # stairs_slabs_walls
        42,   # doors_trapdoors_fences
        28,   # lanterns_torches
    ],
    # minerals: raw ores are uncommon in wealthy bases (smelted into
    # blocks already); netherite block is rare even for wealthy
    "minerals": [
        85,   # coal
        88,   # iron
        105,  # gold (raw)
        130,  # diamond (raw)
        128,  # emerald
        132,  # lapis
        100,  # redstone
        160,  # netherite_block (rare even for wealthy)
    ],
    # food: cooked/PvP-ready foods common, raw produce uncommon
    "food": [
        18,   # cooked_meat_fish
        20,   # bread_baked_goods
        15,   # golden_carrots_baked_potato (PvP staple)
        22,   # sweet_berries_melon_block
        90,   # raw_produce_garden
        95,   # seeds_bulk
        32,   # cake_pumpkin_pie_cookies
    ],
    # combat: PvP staples + netherite max are common, mace/trident max
    # are rare (hard to obtain), iron/diamond swords are downgrade
    "combat": [
        12,   # arrows_tipped
        110,  # bows_crossbows (less common than melee)
        95,   # swords_iron (downgrade)
        120,  # swords_diamond (downgrade)
        25,   # swords_netherite_max
        175,  # mace_max (newer, rare)
        180,  # trident_max (hard to get)
        28,   # axes_netherite_max
        78,   # shields
        10,   # cobwebs_pvp_trap (PvP staple)
        14,   # TNT (PvP staple)
    ],
    # armor: netherite max + elytra are common (wealthy), iron/diamond
    # are uncommon downgrade, gold is niche, leather is mid
    "armor": [
        80,   # leather_armor
        100,  # iron_armor (uncommon downgrade)
        125,  # diamond_armor (uncommon downgrade)
        22,   # netherite_armor_max (THE OP bread-and-butter)
        130,  # gold_helmet_boots (niche piglin use)
        35,   # elytra_max (common in wealthy bases)
        145,  # horse_wolf_armor
        140,  # smithing_templates_trims
    ],
    # tools: netherite max common, others uncommon downgrade
    "tools": [
        88,   # wood_stone_tools
        92,   # iron_tools (downgrade)
        118,  # diamond_tools (downgrade)
        30,   # netherite_tools_max
        115,  # fishing_rod
        98,   # shears_compass_clock_lead
    ],
    # consumables: ALL PvP staples, common (these are the labeled
    # "potions"/"pearls"/"totems"/"apples" chest default)
    "consumables": [
        18,   # golden_apples (common)
        5,    # enchanted_golden_apples_64stack (very common PvP staple)
        6,    # experience_bottles_64stack
        8,    # totems_of_undying
        11,   # fireworks_rockets_64stack
        4,    # ender_pearls_16stack (most common PvP staple)
        9,    # splash_healing_max
        10,   # splash_harming_max
    ],
    # potions: PvP-useful splash max common, niche ones mid
    "potions": [
        12,   # strength_swiftness_splash_max (PvP staple)
        14,   # invisibility_splash_extended_max
        50,   # fire_resistance_splash_max (Nether use)
        105,  # water_breathing_splash (Aquatic use)
        115,  # weakness_poison_lingering
    ],
    # mob drops: common ones (rotten flesh, bone) common, rare drops rare
    "mob_drops": [
        75,   # rotten_flesh_bone_string
        78,   # gunpowder_spider_eye
        102,  # blaze_rod_powder_ghast_tear
        110,  # phantom_membrane
        88,   # ender_pearl_eye_of_ender (note: also consumable PvP staple,
              # but here is the mob-drop categorization; ender_pearls_16stack
              # above covers the PvP-chest intent at rank 4)
        115,  # slime_ball_magma_cream
        175,  # wither_skull_trophy
    ],
    # enchant: god books rare, regular books mid, brewing supplies mid
    "enchant": [
        195,  # enchanted_books_god_max (rare even for wealthy)
        100,  # regular_enchanted_books
        105,  # brewing_ingredients
        110,  # nether_wart_blaze_powder_fermented
    ],
}

# group order for assignment
GROUP_ORDER = [
    "blocks", "minerals", "food", "combat", "armor", "tools",
    "consumables", "potions", "mob_drops", "enchant",
]

# Sanity: every group has len == number of themes in that group
for grp in GROUP_ORDER:
    n_themes = sum(1 for _, g in THEMES if g == grp)
    n_ranks  = len(RARITY_BY_GROUP[grp])
    assert n_themes == n_ranks, f"{grp}: {n_themes} themes vs {n_ranks} ranks"

# Build flat list of (theme_name, group, rank) in THEMES order
ranked_themes = []
for theme_name, group in THEMES:
    rank = RARITY_BY_GROUP[group].pop(0)
    ranked_themes.append((theme_name, group, rank))

# Expand into dim variants. Order: ow, nether, end, repeated per theme.
DIMS = ["overworld", "nether", "end"]

entries = []
for theme_name, group, base_rank in ranked_themes:
    # Per-dim perturbation: same theme's 3 dim variants land at 3 nearby
    # indices. End is slightly rarer than OW for some themes (rare to
    # find labeled chests in the End at all), nether slightly more
    # common for some (more Nether activity in 2b2t mega-bases).
    # Default: rank+0/1/2 so within-theme triples stay contiguous.
    for dim_idx, dim in enumerate(DIMS):
        rank = base_rank + dim_idx
        if rank > 251:
            rank = 251
        entries.append({
            "name": f"{theme_name}_{dim}",
            "theme": theme_name,
            "group": group,
            "dimension": dim,
            "rarity_rank": rank,
            "items": [f"[TBD stage 3: {theme_name} bundle, dim={dim}]"],
        })

assert len(entries) == 252, f"dim-tripled entries = {len(entries)}, expected 252"

# Append 4 universal themes (dim-agnostic, rarity 252..255).
# Note: pvp_kit entries live at the TOP of the rare tier (210..)
# in unlabeled corpus, but Jev will land on them given a "kit" /
# "loadout" sign via the runner's labelled-sign upweight path.
UNIVERSAL = [
    ("pvp_kit_standard",     252, "full enchanted netherite Tux-style kit (per pvpkits.kit_standard)"),
    ("pvp_kit_closet",       253, "5-9 nested kit shulkers, mixed archetypes (pvpkits.build_closet)"),
    ("fallback_local_misc",  254, "generic-misc roll, stage-3 dim/biome bias via cluster scan"),
    ("empty_chest",          255, "deliberately empty (the ~3-5% texture-from-searches rule)"),
]
for name, rank, desc in UNIVERSAL:
    entries.append({
        "name": name,
        "theme": name,
        "group": "universal",
        "dimension": "any",
        "rarity_rank": rank,
        "items": [f"[TBD stage 3: {desc}]"],
    })

assert len(entries) == 256, f"total entries = {len(entries)}, expected 256"

# Sort by rarity_rank (then by theme for stable ordering within tier),
# then renumber index 0..255.
entries.sort(key=lambda e: (e["rarity_rank"], e["theme"], e["dimension"]))

vocab = {}
for idx, e in enumerate(entries):
    assert idx not in vocab, f"collision at {idx}"
    vocab[idx] = e

# Final sanity: 256 unique keys, 0..255
assert set(vocab.keys()) == set(range(256)), "vocab keys != 0..255"

# Coverage report
groups = {}
dims = {}
tier_count = [0,0,0,0,0,0]  # 0:0-39, 1:40-89, 2:90-149, 3:150-209, 4:210-249, 5:250-255
for e in entries:
    groups[e["group"]] = groups.get(e["group"], 0) + 1
    dims[e["dimension"]] = dims.get(e["dimension"], 0) + 1
    r = e["rarity_rank"]
    if   r <= 39:  tier_count[0] += 1
    elif r <= 89:  tier_count[1] += 1
    elif r <= 149: tier_count[2] += 1
    elif r <= 209: tier_count[3] += 1
    elif r <= 249: tier_count[4] += 1
    else:          tier_count[5] += 1

print(f"groups: {groups}")
print(f"dims:   {dims}")
print(f"tiers:  {tier_count}  (0..39, 40..89, 90..149, 150..209, 210..249, 250..255)")
print(f"total:  {len(entries)}")

# Write
out_dir = os.path.dirname(os.path.abspath(__file__))
out_path = os.path.join(out_dir, "loot_vocab.json")
with open(out_path, "w") as f:
    json.dump(vocab, f, indent=2, sort_keys=True)
print(f"wrote {out_path}")