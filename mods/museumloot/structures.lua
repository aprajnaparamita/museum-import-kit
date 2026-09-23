-- Vanilla-structure loot detection for museumloot.
--
-- Runs BEFORE the sign-keyword classifier in init.lua's per-container loop
-- (see discover_containers_for_base's finish()). If a container sits inside
-- a real Mineclonia-mapgen structure (mineshaft, dungeon, temple, outpost,
-- portal, stronghold, mansion, village, end city), we want it to read as
-- *authentic vanilla loot* -- not one of museumloot's own generosity-dialed
-- museum THEMES. So this module hand-copies the relevant structures' own
-- loot-table literals (they are file-local Lua variables in Mineclonia's
-- mapgen mods -- not exported through any registry, and not `require`/
-- `dofile`-able without re-running their core.register_* side effects and
-- crashing on duplicate registration) and ships a lightweight node-radius
-- heuristic to decide which one (if any) applies to a given container
-- position.
--
-- Every table below is copied VERBATIM from the cited file/line range in
-- /Users/dara/dev/mineclonia (verified against mods/MAPGEN/... and
-- mods/ITEMS/... as of this session, 2026-09-17). Do not paraphrase or
-- "clean up" these tables -- diff against the source if they ever need to
-- change.
--
-- Style: plain dofile-able module, no side effects, mirrors
-- lua_import/palette.lua (local helpers, one `return module_table` at the
-- end). museumloot/init.lua loads this with
-- `dofile(modpath .. "/structures.lua")`, matching how it already gets its
-- own `modpath` local at the top of that file.

local structures = {}

-- ---------------------------------------------------------------------
-- Node-name verification.
-- ---------------------------------------------------------------------
-- Every node name referenced below (both in the copied loot tables and in
-- the detection heuristics) was checked with
--   grep -rn "register_node" mods/ITEMS/... mods/MAPGEN/...
-- against /Users/dara/dev/mineclonia in this session -- see the per-table
-- and per-heuristic comments for exactly which file. This project has
-- twice lost a full day to an unverified/guessed node name silently
-- becoming stone or matching nothing; every name here was grepped for
-- real, not recalled from memory.

-- ---------------------------------------------------------------------
-- 1. Mineshaft.
-- ---------------------------------------------------------------------
-- Source: mods/MAPGEN/mcl_levelgen/mineshaft.lua:17-59, local `minecart_loot`.
-- Copied verbatim (all 3 pools). Used with mcl_loot.get_multi_loot, exactly
-- as mineshaft.lua itself uses it in principle (see get_multi_loot below).
--
-- SIMPLIFICATION: in real Mineclonia, this table only ever fills *minecart
-- chests*, which are entities (mcl_minecarts:chest_minecart), not nodes --
-- museumloot's container scan (core.find_nodes_in_area) cannot see them at
-- all (see FEATURE-loot.md section 3's own note on this). For our
-- purposes, a static chest/shulker *node* sitting near mineshaft
-- signatures (rails, cobwebs) almost certainly belonged to a mineshaft
-- stash built by the original player around/instead-of a minecart chest,
-- so we apply the same loot pool to it. This is a judgement call, not
-- something Mineclonia itself does.
--
-- 2026-09-18 round 4 (owner: "I see a lot of items in chests with Curse
-- of Vanishing, nobody would use or save these"): every
-- `mcl_enchanting.enchant_uniform_randomly(stack, exclude, pr)` call
-- below (and throughout this file) now excludes "curse_of_vanishing" in
-- addition to whatever it already excluded (usually "soul_speed", to
-- keep that enchant boots-only). Found live, via a real fresh rebuild,
-- that init.lua's own EXCLUDED_ENCHANTS fix did NOT cover this file --
-- this is a wholly separate call path (real vanilla structure loot
-- tables, not the THEMES/enchanted() pipeline) into the same underlying
-- `get_random_enchantment`, and it still rolled curse_of_vanishing onto
-- three real sampled items (gold leggings, gold hoe, an enchanted
-- fishing rod) before this fix. Second parameter to
-- `enchant_uniform_randomly` is an EXCLUDE list, not an allow-list --
-- confirmed against `mods/ITEMS/mcl_enchanting/engine.lua`'s real
-- implementation, worth remembering since the call reads almost the
-- opposite way at a glance.
local MINESHAFT_LOOT = {
	{
		stacks_min = 1,
		stacks_max = 1,
		items = {
			{ itemstring = "mcl_mobitems:nametag", weight = 30 },
			{ itemstring = "mcl_core:apple_gold", weight = 20 },
			{ itemstring = "mcl_books:book", weight = 10, func = function(stack, pr)
				  mcl_enchanting.enchant_uniform_randomly(stack, {"soul_speed", "curse_of_vanishing"}, pr)
			end },
			{ itemstring = "", weight = 5},
			{ itemstring = "mcl_tools:pick_iron", weight = 5 },
			{ itemstring = "mcl_core:apple_gold_enchanted", weight = 1 },
		}
	},
	{
		stacks_min = 2,
		stacks_max = 4,
		items = {
			{ itemstring = "mcl_farming:bread", weight = 15, amount_min = 1, amount_max = 3 },
			{ itemstring = "mcl_core:coal_lump", weight = 10, amount_min = 3, amount_max = 8 },
			{ itemstring = "mcl_farming:beetroot_seeds", weight = 10, amount_min = 2, amount_max = 4 },
			{ itemstring = "mcl_farming:melon_seeds", weight = 10, amount_min = 2, amount_max = 4 },
			{ itemstring = "mcl_farming:pumpkin_seeds", weight = 10, amount_min = 2, amount_max = 4 },
			{ itemstring = "mcl_core:iron_ingot", weight = 10, amount_min = 1, amount_max = 5 },
			{ itemstring = "mcl_core:lapis", weight = 5, amount_min = 4, amount_max = 9 },
			{ itemstring = "mcl_redstone:redstone", weight = 5, amount_min = 4, amount_max = 9 },
			{ itemstring = "mcl_core:gold_ingot", weight = 5, amount_min = 1, amount_max = 3 },
			{ itemstring = "mcl_core:diamond", weight = 3, amount_min = 1, amount_max = 2 },
		}
	},
	{
		stacks_min = 3,
		stacks_max = 3,
		items = {
			{ itemstring = "mcl_minecarts:rail", weight = 20, amount_min = 4, amount_max = 8 },
			{ itemstring = "mcl_torches:torch", weight = 15, amount_min = 1, amount_max = 16 },
			{ itemstring = "mcl_minecarts:activator_rail", weight = 5, amount_min = 1, amount_max = 4 },
			{ itemstring = "mcl_minecarts:detector_rail", weight = 5, amount_min = 1, amount_max = 4 },
			{ itemstring = "mcl_minecarts:golden_rail", weight = 5, amount_min = 1, amount_max = 4 },
		}
	},
}

-- ---------------------------------------------------------------------
-- 2. Dungeon.
-- ---------------------------------------------------------------------
-- Source: mods/MAPGEN/mcl_dungeons/init.lua:42-90, local `loottable`.
-- Copied verbatim. Used with mcl_loot.get_multi_loot.
local DUNGEON_LOOT = {
	{
		stacks_min = 1,
		stacks_max = 3,
		items = {
			{ itemstring = "mcl_mobitems:nametag", weight = 20 },
			{ itemstring = "mcl_mobitems:leather", weight = 20, amount_min = 1, amount_max = 5 },
			{ itemstring = "mcl_jukebox:record_13", weight = 15 },
			{ itemstring = "mcl_jukebox:record_far", weight = 15 },
			{ itemstring = "mcl_jukebox:record_mall", weight = 3 },
			{ itemstring = "mcl_mobitems:copper_horse_armor", weight = 15 },
			{ itemstring = "mcl_mobitems:iron_horse_armor", weight = 15 },
			{ itemstring = "mcl_core:apple_gold", weight = 15 },
			{ itemstring = "mcl_books:book", weight = 10, func = function(stack, pr)
				mcl_enchanting.enchant_uniform_randomly(stack, {"soul_speed", "curse_of_vanishing"}, pr)
			end },
			{ itemstring = "mcl_mobitems:gold_horse_armor", weight = 10 },
			{ itemstring = "mcl_mobitems:diamond_horse_armor", weight = 5 },
			{ itemstring = "mcl_core:apple_gold_enchanted", weight = 2 },
		}
	},
	{
		stacks_min = 1,
		stacks_max = 4,
		items = {
			{ itemstring = "mcl_farming:wheat_item", weight = 20, amount_min = 1, amount_max = 4 },
			{ itemstring = "mcl_farming:bread", weight = 20 },
			{ itemstring = "mcl_core:coal_lump", weight = 15, amount_min = 1, amount_max = 4 },
			{ itemstring = "mcl_redstone:redstone", weight = 15, amount_min = 1, amount_max = 4 },
			{ itemstring = "mcl_farming:beetroot_seeds", weight = 10, amount_min = 2, amount_max = 4 },
			{ itemstring = "mcl_farming:melon_seeds", weight = 10, amount_min = 2, amount_max = 4 },
			{ itemstring = "mcl_farming:pumpkin_seeds", weight = 10, amount_min = 2, amount_max = 4 },
			{ itemstring = "mcl_core:iron_ingot", weight = 10, amount_min = 1, amount_max = 4 },
			{ itemstring = "mcl_buckets:bucket_empty", weight = 10 },
			{ itemstring = "mcl_core:gold_ingot", weight = 5, amount_min = 1, amount_max = 4 },
		},
	},
	{
		stacks_min = 3,
		stacks_max = 3,
		items = {
			{ itemstring = "mcl_mobitems:bone", weight = 10, amount_min = 1, amount_max = 8 },
			{ itemstring = "mcl_mobitems:gunpowder", weight = 10, amount_min = 1, amount_max = 8 },
			{ itemstring = "mcl_mobitems:rotten_flesh", weight = 10, amount_min = 1, amount_max = 8 },
			{ itemstring = "mcl_mobitems:string", weight = 10, amount_min = 1, amount_max = 8 },
		},
	}
}

-- ---------------------------------------------------------------------
-- 3. Jungle temple.
-- ---------------------------------------------------------------------
-- Source: mods/MAPGEN/mcl_levelgen/jungle_temple.lua:10-31, local
-- `jungle_temple_loot`. Copied verbatim. This is a SINGLE pool (not an
-- array of pools) -- jungle_temple.lua itself calls
-- `mcl_loot.get_loot(jungle_temple_loot, pr)` (line 44), not
-- get_multi_loot. Use accordingly.
local JUNGLE_TEMPLE_LOOT = {
	stacks_min = 2,
	stacks_max = 6,
	items = {
		{ itemstring = "mcl_mobitems:bone", weight = 20, amount_min = 4, amount_max=6 },
		{ itemstring = "mcl_mobitems:rotten_flesh", weight = 16, amount_min = 3, amount_max=7 },
		{ itemstring = "mcl_core:gold_ingot", weight = 15, amount_min = 2, amount_max = 7 },
		{ itemstring = "mcl_bamboo:bamboo_small", weight = 15, amount_min = 1, amount_max=3 },
		{ itemstring = "mcl_core:iron_ingot", weight = 15, amount_min = 1, amount_max = 5 },
		{ itemstring = "mcl_core:diamond", weight = 3, amount_min = 1, amount_max = 3 },
		{ itemstring = "mcl_mobitems:saddle", weight = 3, },
		{ itemstring = "mcl_core:emerald", weight = 2, amount_min = 1, amount_max = 3 },
		{ itemstring = "mcl_books:book", weight = 1, func = function(stack, pr)
			  mcl_enchanting.enchant_uniform_randomly(stack, {"soul_speed", "curse_of_vanishing"}, pr)
		end },
		{ itemstring = "mcl_mobitems:iron_horse_armor", weight = 1, },
		{ itemstring = "mcl_mobitems:gold_horse_armor", weight = 1, },
		{ itemstring = "mcl_mobitems:diamond_horse_armor", weight = 1, },
		{ itemstring = "mcl_core:apple_gold_enchanted", weight = 2, },
		{ itemstring = "mcl_armor:wild", amount_min = 1, amount_max = 1, },
	},
}

-- ---------------------------------------------------------------------
-- 4. Desert pyramid.
-- ---------------------------------------------------------------------
-- Source: mods/MAPGEN/mcl_levelgen/desert_pyramid.lua:25-61, local
-- `desert_pyramid_loot`. Copied verbatim (both pools). Used with
-- mcl_loot.get_multi_loot (desert_pyramid.lua line 78 does the same).
local DESERT_PYRAMID_LOOT = {
	{
		stacks_min = 2,
		stacks_max = 4,
		items = {
			{ itemstring = "mcl_mobitems:bone", weight = 25, amount_min = 4, amount_max=6 },
			{ itemstring = "mcl_mobitems:rotten_flesh", weight = 25, amount_min = 3, amount_max=7 },
			{ itemstring = "mcl_mobitems:spider_eye", weight = 25, amount_min = 1, amount_max=3 },
			{ itemstring = "mcl_books:book", weight = 20, func = function(stack, pr)
				  mcl_enchanting.enchant_uniform_randomly(stack, {"soul_speed", "curse_of_vanishing"}, pr)
			end },
			{ itemstring = "mcl_mobitems:saddle", weight = 20, },
			{ itemstring = "mcl_core:apple_gold", weight = 20, },
			{ itemstring = "mcl_core:gold_ingot", weight = 15, amount_min = 2, amount_max = 7 },
			{ itemstring = "mcl_core:iron_ingot", weight = 15, amount_min = 1, amount_max = 5 },
			{ itemstring = "mcl_core:emerald", weight = 15, amount_min = 1, amount_max = 3 },
			{ itemstring = "", weight = 15, },
			{ itemstring = "mcl_mobitems:iron_horse_armor", weight = 15, },
			{ itemstring = "mcl_mobitems:gold_horse_armor", weight = 10, },
			{ itemstring = "mcl_mobitems:diamond_horse_armor", weight = 5, },
			{ itemstring = "mcl_core:diamond", weight = 5, amount_min = 1, amount_max = 3 },
			{ itemstring = "mcl_core:apple_gold_enchanted", weight = 2, },
			{ itemstring = "mcl_armor:dune", weight = 20, amount_min = 2, amount_max = 2},
		},
	},
	{
		stacks_min = 4,
		stacks_max = 4,
		items = {
			{ itemstring = "mcl_mobitems:bone", weight = 10, amount_min = 1, amount_max = 8 },
			{ itemstring = "mcl_mobitems:rotten_flesh", weight = 10, amount_min = 1, amount_max = 8 },
			{ itemstring = "mcl_mobitems:gunpowder", weight = 10, amount_min = 1, amount_max = 8 },
			{ itemstring = "mcl_core:sand", weight = 10, amount_min = 1, amount_max = 8 },
			{ itemstring = "mcl_mobitems:string", weight = 10, amount_min = 1, amount_max = 8 },
		},
	},
}

-- ---------------------------------------------------------------------
-- 5. Stronghold.
-- ---------------------------------------------------------------------
-- Source: mods/MAPGEN/mcl_levelgen/stronghold.lua:7-51 (the `corridor`
-- key only), local `stronghold_loot_pools`. Copied verbatim.
--
-- stronghold_loot_pools is keyed by loot_type; the file defines at least
-- "corridor" and "crossing" (and possibly more further down, not read in
-- full this session). We use "corridor" as the default: strongholds are
-- mostly corridor, corridor chests are by far the most commonly
-- encountered stronghold chest, and corridor's pool is also the one that
-- carries the Eye of Ender item (`mcl_armor:eye`), which is the single
-- most iconic stronghold loot item -- worth defaulting to over "crossing".
-- Used with mcl_loot.get_multi_loot (2 pools).
local STRONGHOLD_LOOT = {
	{
		stacks_min = 2,
		stacks_max = 3,
		items = {
			{ itemstring = "mcl_core:apple", weight = 15, amount_min = 1, amount_max = 3 },
			{ itemstring = "mcl_farming:bread", weight = 15, amount_min = 1, amount_max = 3 },
			{ itemstring = "mcl_core:iron_ingot", weight = 10, amount_min = 1, amount_max = 5 },
			{ itemstring = "mcl_throwing:ender_pearl", weight = 10, amount_min = 1, amount_max = 1 },
			{ itemstring = "mcl_redstone:redstone", weight = 5, amount_min = 4, amount_max = 9 },
			{ itemstring = "mcl_core:gold_ingot", weight = 5, amount_min = 1, amount_max = 3 },

			{ itemstring = "mcl_tools:pick_iron", weight = 5, amount_min = 1, amount_max=3 },
			{ itemstring = "mcl_tools:sword_iron", weight = 5, amount_min = 1, amount_max=3 },

			{ itemstring = "mcl_armor:helmet_iron", weight = 5, amount_min = 1, amount_max=3 },
			{ itemstring = "mcl_armor:chestplate_iron", weight = 5, amount_min = 1, amount_max=3 },
			{ itemstring = "mcl_armor:leggings_iron", weight = 5, amount_min = 1, amount_max=3 },
			{ itemstring = "mcl_armor:boots_iron", weight = 5, amount_min = 1, amount_max=3 },

			{ itemstring = "mcl_core:diamond", weight = 3, amount_min = 1, amount_max = 3 },

			{ itemstring = "mcl_jukebox:record_strad", weight = 1, },
			{
				itemstring = "mcl_books:book", weight = 1,
				func = function (stack, pr)
					mcl_enchanting.enchant_randomly (stack, 30, true, false, false, pr)
				end,
			},
			{ itemstring = "mcl_mobitems:saddle", weight = 1, },
			{ itemstring = "mcl_mobitems:iron_horse_armor", weight = 1, },
			{ itemstring = "mcl_mobitems:gold_horse_armor", weight = 1, },
			{ itemstring = "mcl_mobitems:diamond_horse_armor", weight = 1, },
			{ itemstring = "mcl_core:apple_gold", weight = 1, },
		},
	},
	{
		stacks_min = 1,
		stacks_max = 1,
		items = {
			{ itemstring = "mcl_armor:eye", weight = 1, amount_min = 1, amount_max = 1 },
		}
	},
}

-- ---------------------------------------------------------------------
-- 6. Pillager outpost.
-- ---------------------------------------------------------------------
-- Source: mods/MAPGEN/mcl_levelgen/pillager_outpost.lua:8-46, local
-- `pillager_outpost_loot`. Copied verbatim (4 pools). Used with
-- mcl_loot.get_multi_loot.
--
-- DETECTION SKIPPED for this structure -- see detect() below. No
-- distinctive block signature was found in the schematic/piece code
-- (mods/MAPGEN/mcl_levelgen/pillager_outpost.lua) short of parsing the
-- .mts schematic binaries directly: outposts are built mostly from dark
-- oak planks/logs and cobblestone, both of which are common in ordinary
-- player-built bases too, so a node-radius heuristic here would false-
-- positive constantly. The table is kept here (per spec, "copy the
-- tables") for a future maintainer who wants to parse the schematic
-- files for a real signature.
local PILLAGER_OUTPOST_LOOT = {
	{
		stacks_min = 2,
		stacks_max = 3,
		items = {
			{ itemstring = "mcl_farming:wheat_item", weight = 7, amount_min = 3, amount_max=5 },
			{ itemstring = "mcl_farming:carrot_item", weight = 5, amount_min = 3, amount_max=5 },
			{ itemstring = "mcl_farming:potato_item", weight = 5, amount_min = 2, amount_max=5 },
		}
	},
	{
		stacks_min = 1,
		stacks_max = 2,
		items = {
			{ itemstring = "mcl_experience:bottle", weight = 6, amount_min = 0, amount_max=1 },
			{ itemstring = "mcl_bows:arrow", weight = 4, amount_min = 2, amount_max=7 },
			{ itemstring = "mcl_mobitems:string", weight = 4, amount_min = 1, amount_max=6 },
			{ itemstring = "mcl_core:iron_ingot", weight = 3, amount_min = 1, amount_max = 3 },
			{ itemstring = "mcl_books:book", weight = 1, func = function(stack, pr)
				  mcl_enchanting.enchant_uniform_randomly(stack, {"soul_speed", "curse_of_vanishing"}, pr)
			end },
			{ itemstring = "mcl_armor:sentry"},
		},
	},
	{
		stacks_min = 1,
		stacks_max = 3,
		items = {
			{ itemstring = "mcl_trees:tree_dark_oak", amount_min = 2, amount_max=3 },
		},
	},
	{
		stacks_min = 1,
		stacks_max = 1,
		items = {
			{ itemstring = "mcl_bows:crossbow" },
		},
	},
}

-- ---------------------------------------------------------------------
-- 7. Ruined portal.
-- ---------------------------------------------------------------------
-- Source: mods/MAPGEN/mcl_levelgen/ruined_portal.lua:8-59, local
-- `ruined_portal_loot`. Copied verbatim. This is a SINGLE pool (not
-- wrapped in an array) -- use with mcl_loot.get_loot.
local RUINED_PORTAL_LOOT = {
	stacks_min = 4,
	stacks_max = 8,
	items = {
		{ itemstring = "mcl_core:iron_nugget", weight = 40, amount_min = 9, amount_max = 18 },
		{ itemstring = "mcl_core:flint", weight = 40, amount_min = 1, amount_max=4 },
		{ itemstring = "mcl_core:obsidian", weight = 40, amount_min = 1, amount_max=2 },
		{ itemstring = "mcl_fire:fire_charge", weight = 40, amount_min = 1, amount_max = 1 },
		{ itemstring = "mcl_fire:flint_and_steel", weight = 40, amount_min = 1, amount_max = 1 },
		{ itemstring = "mcl_core:gold_nugget", weight = 15, amount_min = 4, amount_max = 24 },
		{ itemstring = "mcl_core:apple_gold", weight = 15, },

		{ itemstring = "mcl_tools:axe_gold", weight = 15, func = function(stack, pr)
			  mcl_enchanting.enchant_uniform_randomly(stack, {"soul_speed", "curse_of_vanishing"}, pr)
		end },
		{ itemstring = "mcl_farming:hoe_gold", weight = 15, func = function(stack, pr)
			  mcl_enchanting.enchant_uniform_randomly(stack, {"soul_speed", "curse_of_vanishing"}, pr)
		end },
		{ itemstring = "mcl_tools:pick_gold", weight = 15, func = function(stack, pr)
			  mcl_enchanting.enchant_uniform_randomly(stack, {"soul_speed", "curse_of_vanishing"}, pr)
		end },
		{ itemstring = "mcl_tools:shovel_gold", weight = 15, func = function(stack, pr)
			  mcl_enchanting.enchant_uniform_randomly(stack, {"soul_speed", "curse_of_vanishing"}, pr)
		end },
		{ itemstring = "mcl_tools:sword_gold", weight = 15, func = function(stack, pr)
			  mcl_enchanting.enchant_uniform_randomly(stack, {"soul_speed", "curse_of_vanishing"}, pr)
		end },

		{ itemstring = "mcl_armor:helmet_gold", weight = 15, func = function(stack, pr)
			  mcl_enchanting.enchant_uniform_randomly(stack, {"soul_speed", "curse_of_vanishing"}, pr)
		end },
		{ itemstring = "mcl_armor:chestplate_gold", weight = 15, func = function(stack, pr)
			  mcl_enchanting.enchant_uniform_randomly(stack, {"soul_speed", "curse_of_vanishing"}, pr)
		end },
		{ itemstring = "mcl_armor:leggings_gold", weight = 15, func = function(stack, pr)
			  mcl_enchanting.enchant_uniform_randomly(stack, {"soul_speed", "curse_of_vanishing"}, pr)
		end },
		{ itemstring = "mcl_armor:boots_gold", weight = 15, func = function(stack, pr)
			  mcl_enchanting.enchant_uniform_randomly(stack, {"soul_speed", "curse_of_vanishing"}, pr)
		end },

		{ itemstring = "mcl_potions:speckled_melon", weight = 5, amount_min = 4, amount_max = 12 },
		{ itemstring = "mcl_farming:carrot_item_gold", weight = 5, amount_min = 4, amount_max = 12 },

		{ itemstring = "mcl_core:gold_ingot", weight = 5, amount_min = 2, amount_max = 8 },
		{ itemstring = "mcl_clock:clock", weight = 5, },
		{ itemstring = "mcl_mobitems:gold_horse_armor", weight = 1, },
		{ itemstring = "mcl_core:goldblock", weight = 1, amount_min = 1, amount_max = 2 },
		{ itemstring = "mcl_bells:bell", weight = 1, },
		{ itemstring = "mcl_core:apple_gold_enchanted", weight = 1, },
	}
}

-- ---------------------------------------------------------------------
-- 8. Woodland mansion.
-- ---------------------------------------------------------------------
-- Source: mods/MAPGEN/mcl_levelgen/woodland_mansion.lua:67-112, local
-- `woodland_mansion_loot`. Copied verbatim (3 pools). Used with
-- mcl_loot.get_multi_loot.
--
-- DETECTION SKIPPED for this structure -- same reasoning as pillager
-- outpost above: mansion rooms are drawn from ~50 named schematics
-- (see the `schematics` list at the top of woodland_mansion.lua) with no
-- single block that's both present in every room type and absent from
-- ordinary player builds. Kept here for a future maintainer.
local WOODLAND_MANSION_LOOT = {
	{
		stacks_min = 3,
		stacks_max = 3,
		items = {
			{ itemstring = "mcl_mobitems:bone", weight = 10, amount_min = 1, amount_max=8 },
			{ itemstring = "mcl_mobitems:gunpowder", weight = 10, amount_min = 1, amount_max = 8 },
			{ itemstring = "mcl_mobitems:rotten_flesh", weight = 10, amount_min = 1, amount_max=8 },
			{ itemstring = "mcl_mobitems:string", weight = 10, amount_min = 1, amount_max=8 },

			{ itemstring = "mcl_core:gold_ingot", weight = 15, amount_min = 2, amount_max = 7 },
		},
	},
	{
		stacks_min = 1,
		stacks_max = 4,
		items = {
			{ itemstring = "mcl_farming:wheat_item", weight = 20, amount_min = 1, amount_max = 4 },
			{ itemstring = "mcl_farming:bread", weight = 20, amount_min = 1, amount_max = 1 },
			{ itemstring = "mcl_core:coal_lump", weight = 15, amount_min = 1, amount_max = 4 },
			{ itemstring = "mcl_redstone:redstone", weight = 15, amount_min = 1, amount_max = 4 },
			{ itemstring = "mcl_farming:beetroot_seeds", weight = 10, amount_min = 2, amount_max = 4 },
			{ itemstring = "mcl_farming:melon_seeds", weight = 10, amount_min = 2, amount_max = 4 },
			{ itemstring = "mcl_farming:pumpkin_seeds", weight = 10, amount_min = 2, amount_max = 4 },
			{ itemstring = "mcl_core:iron_ingot", weight = 10, amount_min = 1, amount_max = 4 },
			{ itemstring = "mcl_buckets:bucket_empty", weight = 10, amount_min = 1, amount_max = 1 },
			{ itemstring = "mcl_core:gold_ingot", weight = 5, amount_min = 1, amount_max = 4 },
		},
	},
	{
		stacks_min = 1,
		stacks_max = 4,
		items = {
			-- FIXME:lead item left commented out in the original source.
			{ itemstring = "mcl_mobitems:nametag", weight = 2, amount_min = 1, amount_max = 3 },
			{ itemstring = "mcl_books:book", weight = 1,
			  func = function(stack, pr)
				  mcl_enchanting.enchant_uniform_randomly (stack, {"soul_speed", "curse_of_vanishing"}, pr)
			  end, },
			{ itemstring = "mcl_armor:chestplate_chain", weight = 1, },
			{ itemstring = "mcl_armor:chestplate_diamond", weight = 1, },
			{ itemstring = "mcl_core:apple_gold_enchanted", weight = 2, },
			{ itemstring = "mcl_armor:vex", amount_max = 1, },
		},
	},
}

-- ---------------------------------------------------------------------
-- 9. Village.
-- ---------------------------------------------------------------------
-- Source: mods/MAPGEN/mcl_villages/schemgen.lua:713-736 (local
-- `village_armorer`, the blacksmith table) and :952-1005 (local
-- `village_plains_house`, the generic-house table). Copied verbatim.
-- Each is a SINGLE pool (schemgen.lua's own verify_loot_table() at
-- line 1452 reads loot.stacks_max/loot.items directly, confirming these
-- are single pools, not arrays) -- use with mcl_loot.get_loot.
--
-- schemgen.lua actually keys ~12 building-specific tables
-- (schematic_loot_tables, line 1429) and 5 biome-house tables
-- (type_loot_tables, line 1444). Per spec we don't need every one -- this
-- is a representative "generic_village" fallback: village_armorer stands
-- in for "this was a workstation building" and village_plains_house
-- stands in for "this was an ordinary house", picked when a container is
-- detected as village but we have no schematic-name info to pick a more
-- specific table (museumloot's detection is node-radius only, it doesn't
-- know which named schematic placed the container).
local VILLAGE_ARMORER_LOOT = {
	stacks_min = 1,
	stacks_max = 5,
	items = {
		{
			weight = 2,
			itemstring = "mcl_core:iron_ingot",
			amount_min = 1,
			amount_max = 10,
		},
		{
			weight = 4,
			itemstring = "mcl_farming:bread",
			amount_min = 1,
			amount_max = 4,
		},
		{
			itemstring = "mcl_armor:helmet_iron",
		},
		{
			itemstring = "mcl_core:emerald",
		},
	},
}

local VILLAGE_PLAINS_HOUSE_LOOT = {
	stacks_min = 3,
	stacks_max = 8,
	items = {
		{
			itemstring = "mcl_core:gold_nugget",
			amount_min = 1,
			amount_max = 3,
		},
		{
			itemstring = "mcl_flowers:dandelion",
			weight = 2,
		},
		{
			itemstring = "mcl_flowers:poppy",
		},
		{
			itemstring = "mcl_farming:potato_item",
			amount_min = 1,
			amount_max = 7,
			weight = 10,
		},
		{
			itemstring = "mcl_farming:bread",
			amount_min = 1,
			amount_max = 4,
			weight = 10,
		},
		{
			itemstring = "mcl_core:apple",
			amount_min = 1,
			amount_max = 5,
			weight = 10,
		},
		{
			itemstring = "mcl_books:book",
		},
		{
			itemstring = "mcl_mobitems:feather",
		},
		{
			itemstring = "mcl_core:emerald",
			amount_min = 1,
			amount_max = 4,
			weight = 2,
		},
		{
			itemstring = "mcl_trees:sapling_oak",
			amount_min = 1,
			amount_max = 2,
			weight = 5,
		},
	},
}

-- ---------------------------------------------------------------------
-- 10. End city.
-- ---------------------------------------------------------------------
-- Source: mods/MAPGEN/mcl_structures/end_city.lua. That file actually
-- registers THREE separate End structures sharing one file
-- (end_shipwreck at line 21, end_boat at line 97, small_end_city at line
-- 145 -- "small_end_city" is the real end-city structure); each has its
-- own `loot = {...}` table keyed by node name (line 48, 111, 158
-- respectively). Per spec we copy at least the first one.
--
-- Copied verbatim: end_shipwreck's loot["mcl_chests:chest_small"] value
-- (line 56-93), which is an array containing ONE pool -- use with
-- mcl_loot.get_multi_loot (matches end_city.lua's own shape; nothing in
-- end_city.lua actually calls get_loot/get_multi_loot directly -- these
-- loot tables are consumed by mcl_structures' generic per-node
-- construct+fill path, which mcl_loot.get_multi_loot is
-- shape-compatible with).
--
-- SIMPLIFICATION: end_shipwreck's table also has a
-- loot["mcl_itemframes:frame"] entry (line 49-55) that is the actual
-- elytra drop -- item frames are a separate node type museumloot's
-- container scan doesn't touch (CONTAINER_KINDS only knows
-- chest/barrel/shulker/ender_chest nodes), so that entry is intentionally
-- NOT copied here; the elytra itself doesn't reach any museumloot-filled
-- container this way. end_boat (line 111) and small_end_city (line 158)
-- have their own near-identical but not-identical chest_small pools
-- (per-room variation, per the spec's own wording) -- not copied; a
-- future maintainer wanting per-structure-variant fidelity should add
-- them as separate tables and pick based on which schematic placed the
-- container (not knowable from a node-radius scan alone).
local END_CITY_LOOT = {
	{
		stacks_min = 2,
		stacks_max = 6,
		items = {
			{ itemstring = "mcl_mobitems:bone", weight = 20, amount_min = 4, amount_max=6 },
			{ itemstring = "mcl_farming:beetroot_seeds", weight = 16, amount_min = 1, amount_max=10 },
			{ itemstring = "mcl_core:gold_ingot", weight = 15, amount_min = 2, amount_max = 7 },
			{ itemstring = "mcl_bamboo:bamboo_small", weight = 15, amount_min = 1, amount_max=3 },
			{ itemstring = "mcl_core:iron_ingot", weight = 15, amount_min = 4, amount_max = 8 },
			{ itemstring = "mcl_core:diamond", weight = 3, amount_min = 2, amount_max = 7 },
			{ itemstring = "mcl_mobitems:saddle", weight = 3, },
			{ itemstring = "mcl_core:emerald", weight = 2, amount_min = 1, amount_max = 3 },
			{ itemstring = "mcl_armor:spire", amount_min = 1, amount_max = 1 },
			{ itemstring = "mcl_books:book", weight = 1, func = function(stack, pr)
				mcl_enchanting.enchant_uniform_randomly(stack, {"soul_speed", "curse_of_vanishing"}, pr)
			end },
			{ itemstring = "mcl_tools:pick_iron_enchanted", weight = 3,func = function(stack, pr) mcl_enchanting.enchant_uniform_randomly(stack, {"soul_speed", "curse_of_vanishing"}, pr) end },
			{ itemstring = "mcl_tools:shovel_iron_enchanted", weight = 3,func = function(stack, pr) mcl_enchanting.enchant_uniform_randomly(stack, {"soul_speed", "curse_of_vanishing"}, pr) end },
			{ itemstring = "mcl_tools:sword_iron_enchanted", weight = 3,func = function(stack, pr) mcl_enchanting.enchant_uniform_randomly(stack, {"soul_speed", "curse_of_vanishing"}, pr) end },
			{ itemstring = "mcl_armor:helmet_iron_enchanted", weight = 3,func = function(stack, pr) mcl_enchanting.enchant_uniform_randomly(stack, {"soul_speed", "curse_of_vanishing"}, pr) end },
			{ itemstring = "mcl_armor:chestplate_iron_enchanted", weight = 3,func = function(stack, pr) mcl_enchanting.enchant_uniform_randomly(stack, {"soul_speed", "curse_of_vanishing"}, pr) end },
			{ itemstring = "mcl_armor:leggings_iron_enchanted", weight = 3,func = function(stack, pr) mcl_enchanting.enchant_uniform_randomly(stack, {"soul_speed", "curse_of_vanishing"}, pr) end },
			{ itemstring = "mcl_armor:boots_iron_enchanted", weight = 3,func = function(stack, pr) mcl_enchanting.enchant_uniform_randomly(stack, {"soul_speed", "curse_of_vanishing"}, pr) end },
			{ itemstring = "mcl_tools:pick_diamond_enchanted", weight = 3,func = function(stack, pr) mcl_enchanting.enchant_uniform_randomly(stack, {"soul_speed", "curse_of_vanishing"}, pr) end },
			{ itemstring = "mcl_tools:shovel_diamond_enchanted", weight = 3,func = function(stack, pr) mcl_enchanting.enchant_uniform_randomly(stack, {"soul_speed", "curse_of_vanishing"}, pr) end },
			{ itemstring = "mcl_tools:sword_diamond_enchanted", weight = 3,func = function(stack, pr) mcl_enchanting.enchant_uniform_randomly(stack, {"soul_speed", "curse_of_vanishing"}, pr) end },
			{ itemstring = "mcl_armor:helmet_diamond_enchanted", weight = 3,func = function(stack, pr) mcl_enchanting.enchant_uniform_randomly(stack, {"soul_speed", "curse_of_vanishing"}, pr) end },
			{ itemstring = "mcl_armor:chestplate_diamond_enchanted", weight = 3,func = function(stack, pr) mcl_enchanting.enchant_uniform_randomly(stack, {"soul_speed", "curse_of_vanishing"}, pr) end },
			{ itemstring = "mcl_armor:leggings_diamond_enchanted", weight = 3,func = function(stack, pr) mcl_enchanting.enchant_uniform_randomly(stack, {"soul_speed", "curse_of_vanishing"}, pr) end },
			{ itemstring = "mcl_armor:boots_diamond_enchanted", weight = 3,func = function(stack, pr) mcl_enchanting.enchant_uniform_randomly(stack, {"soul_speed", "curse_of_vanishing"}, pr) end },
			{ itemstring = "mcl_core:emerald", weight = 2, amount_min = 1, amount_max = 3 },
			{ itemstring = "mcl_mobitems:copper_horse_armor", weight = 1, },
			{ itemstring = "mcl_mobitems:iron_horse_armor", weight = 1, },
			{ itemstring = "mcl_mobitems:gold_horse_armor", weight = 1, },
			{ itemstring = "mcl_mobitems:diamond_horse_armor", weight = 1, },
			{ itemstring = "mcl_core:apple_gold_enchanted", weight = 2, },
		}
	}
}

-- ---------------------------------------------------------------------
-- Detection heuristics.
-- ---------------------------------------------------------------------
-- All node names below were verified with `grep -rn "register_node"` in
-- this session (see the specific file cited on each heuristic). All
-- nodenames arguments are plain string arrays, per this project's own
-- hard-learned rule (a {name=true} dict silently matches nothing in
-- core.find_nodes_in_area -- see the matching comment in init.lua).
--
-- NOT IMPLEMENTED / deliberately skipped:
--  * pillager outpost, woodland mansion -- no distinctive block signature
--    found short of parsing .mts schematic binaries; see the loot-table
--    comments above.
--  * jungle temple tripwire signature -- this Mineclonia checkout has NO
--    tripwire/tripwire-hook node registered anywhere (grepped mods/ for
--    "tripwire", only a stray mobs_mc/villager.lua reference turned up,
--    not a node def) -- so jungle temple detection below relies on mossy
--    cobblestone density alone, which is a weaker signal than the spec's
--    "mossy cobble + tripwire" combo. Documented, not silently degraded.
--  * stronghold bulk-stone-brick fallback -- stone brick is extremely
--    common in ordinary player megabases too; only the end-portal-frame
--    signal is used, to avoid false positives.
--  * village farmland+workstation branch uses mcl_farming:soil /
--    mcl_farming:soil_wet (mods/ITEMS/mcl_farming/soil.lua:3,28) +
--    mcl_composters:composter (mods/ITEMS/mcl_composters/init.lua:224) as
--    the "workstation" signal, since composter is a real, verified,
--    village-only-ish node (grepped and confirmed registered).

-- mcl_minecarts:rail -- mods/ENTITIES/mcl_minecarts/rails.lua:43,49
-- (register_rail("mcl_minecarts:rail", ...) -> core.register_node).
local MINESHAFT_RAIL = { "mcl_minecarts:rail" }
-- mcl_core:cobweb -- mods/ITEMS/mcl_core/nodes_misc.lua:52.
local MINESHAFT_COBWEB = { "mcl_core:cobweb" }

-- mcl_mobspawners:spawner -- mods/ITEMS/mcl_mobspawners/init.lua:221.
local DUNGEON_SPAWNER = { "mcl_mobspawners:spawner" }

-- mcl_portals:end_portal_frame / end_portal_frame_eye --
-- mods/ITEMS/mcl_portals/portal_end.lua:360,387.
local STRONGHOLD_PORTAL_FRAME = { "mcl_portals:end_portal_frame", "mcl_portals:end_portal_frame_eye" }

-- mcl_core:sandstone -- mods/ITEMS/mcl_core/nodes_base.lua:538.
local DESERT_TEMPLE_SANDSTONE = { "mcl_core:sandstone" }
-- mcl_pressureplates:pressure_plate_stone_off/_on --
-- mods/ITEMS/REDSTONE/mcl_pressureplates/init.lua:118,144,151,177
-- (register_pressure_plate("stone", ...)). mcl_tnt:tnt --
-- mods/ITEMS/mcl_tnt/init.lua:53.
local DESERT_TEMPLE_TRAP = {
	"mcl_pressureplates:pressure_plate_stone_off",
	"mcl_pressureplates:pressure_plate_stone_on",
	"mcl_tnt:tnt",
}

-- mcl_core:mossycobble -- mods/ITEMS/mcl_core/nodes_base.lua:728.
local JUNGLE_TEMPLE_MOSSY = { "mcl_core:mossycobble" }

-- mcl_core:obsidian / crying_obsidian -- mods/ITEMS/mcl_core/nodes_base.lua:811,822.
-- mcl_nether:netherrack -- mods/ITEMS/mcl_nether/init.lua:98.
local RUINED_PORTAL_OBSIDIAN = { "mcl_core:obsidian" }
local RUINED_PORTAL_CRYING_OBSIDIAN = { "mcl_core:crying_obsidian" }
local RUINED_PORTAL_NETHERRACK = { "mcl_nether:netherrack" }

-- mcl_bells:bell/_ceiling/_wall -- mods/ITEMS/mcl_bells/init.lua:158,188,208.
local VILLAGE_BELL = { "mcl_bells:bell", "mcl_bells:bell_ceiling", "mcl_bells:bell_wall" }
local VILLAGE_FARMLAND = { "mcl_farming:soil", "mcl_farming:soil_wet" }
local VILLAGE_WORKSTATION = { "mcl_composters:composter" }

-- mcl_end:purpur_block/_pillar -- mods/ITEMS/mcl_end/building.lua:28,39.
local END_CITY_PURPUR = { "mcl_end:purpur_block", "mcl_end:purpur_pillar" }
-- REMOVED: this used to also short-circuit on the container's own node
-- being an ender_chest or a violet/purple shulker box, on the theory that
-- those match end_city.lua's construct_nodes list around its chests. That
-- reasoning only holds for a genuine vanilla end city; on this corpus
-- (real 2b2t player bases) ender chests and purple shulker boxes are just
-- ordinary high-tier storage a player chose to use, not evidence of a
-- generated structure -- confirmed live: it produced end_city matches by
-- the HUNDREDS on ordinary bases with no end city anywhere near them, both
-- misapplying end-city-only loot to normal storage and (via
-- mobplacement.lua's mob pass, which trusts this same detection) spawning
-- wild shulker mobs floating in stairwells, on bedrock, nowhere near
-- anything end-city-shaped. Purpur is a genuinely rare, essentially
-- structure-exclusive block; that's the only signal kept.

-- Bounding-box-clamped "is there a node of one of `names` within `radius`
-- of `pos`" check. Uses find_nodes_in_area (array-of-strings nodenames,
-- grouped=false) rather than find_node_near so the search box can be
-- clamped to the base's own bbox -- by the time structures.detect() runs
-- (see init.lua's discover_containers_for_base -> finish()), the WHOLE
-- bbox has already been emerged tile-by-tile, but nothing outside it has,
-- so letting a search radius wander past x_min/x_max/y_min/y_max/z_min/
-- z_max risks reading "ignore" from an unemerged neighbor block -- same
-- failure mode the sign-gathering code above already guards against.
local function any_node_near(pos, radius, names, bounds)
	local near_min = {
		x = math.max(bounds.x_min, pos.x - radius),
		y = math.max(bounds.y_min, pos.y - radius),
		z = math.max(bounds.z_min, pos.z - radius),
	}
	local near_max = {
		x = math.min(bounds.x_max, pos.x + radius),
		y = math.min(bounds.y_max, pos.y + radius),
		z = math.min(bounds.z_max, pos.z + radius),
	}
	local found = core.find_nodes_in_area(near_min, near_max, names, false) or {}
	if #found == 0 then return false end
	local r2 = radius * radius
	for _, p in ipairs(found) do
		local dx, dy, dz = p.x - pos.x, p.y - pos.y, p.z - pos.z
		if dx*dx + dy*dy + dz*dz <= r2 then return true end
	end
	return false
end

-- structures.detect(pos, x_min, x_max, y_min, y_max, z_min, z_max, node_name)
--
-- pos: container position ({x=,y=,z=}).
-- x_min..z_max: the base's placed bbox (same numbers discover_containers_
--   for_base already has as x_min/x_max/y_min/y_max/z_min/z_max locals) --
--   used only to clamp detection radius searches, never to widen them.
-- node_name: optional, the container's own real node name (c.node in
--   init.lua) -- lets end_city detection short-circuit on the container
--   itself matching end_city.lua's construct_nodes list, no area scan
--   needed.
--
-- Returns nil (no match) or { structure = "<name>", loot_table = <table>,
-- use = "get_loot" | "get_multi_loot" }.
--
-- Order matters: more distinctive/rare signatures are checked first so a
-- container near multiple coincidental signatures (e.g. obsidian near a
-- stronghold, or a bell a player looted into their own base) resolves to
-- the more specific match rather than the noisier one.
function structures.detect(pos, x_min, x_max, y_min, y_max, z_min, z_max, node_name)
	local bounds = { x_min = x_min, x_max = x_max, y_min = y_min, y_max = y_max, z_min = z_min, z_max = z_max }

	-- End city: purpur-block area scan only -- see the comment on
	-- END_CITY_PURPUR above for why the old container-node shortcut was
	-- removed.
	if any_node_near(pos, 12, END_CITY_PURPUR, bounds) then
		return { structure = "end_city", loot_table = END_CITY_LOOT, use = "get_multi_loot" }
	end

	-- Dungeon: a spawner within 8 blocks is about as distinctive as
	-- signatures get -- nothing else places these.
	if any_node_near(pos, 8, DUNGEON_SPAWNER, bounds) then
		return { structure = "dungeon", loot_table = DUNGEON_LOOT, use = "get_multi_loot" }
	end

	-- Mineshaft: rails within 10, or cobwebs within a tighter 6 (cobwebs
	-- alone are a weaker signal -- spiders/witch huts also have them --
	-- so a shorter radius keeps it tied to the actual container).
	if any_node_near(pos, 10, MINESHAFT_RAIL, bounds)
		or any_node_near(pos, 6, MINESHAFT_COBWEB, bounds) then
		return { structure = "mineshaft", loot_table = MINESHAFT_LOOT, use = "get_multi_loot" }
	end

	-- Stronghold: an end portal frame within 20 blocks. Strongholds are
	-- large, so the radius is generous, but the node itself is unique to
	-- strongholds (only mapgen ever places it).
	if any_node_near(pos, 20, STRONGHOLD_PORTAL_FRAME, bounds) then
		return { structure = "stronghold", loot_table = STRONGHOLD_LOOT, use = "get_multi_loot" }
	end

	-- Desert pyramid: sandstone plus a trap signature (pressure plate or
	-- TNT) within a few blocks. Sandstone alone is too common (desert
	-- biome terrain, player builds) to use by itself.
	if any_node_near(pos, 6, DESERT_TEMPLE_SANDSTONE, bounds)
		and any_node_near(pos, 6, DESERT_TEMPLE_TRAP, bounds) then
		return { structure = "desert_temple", loot_table = DESERT_PYRAMID_LOOT, use = "get_multi_loot" }
	end

	-- Ruined portal: obsidian + crying obsidian + netherrack all present
	-- nearby. Obsidian alone is the single most common 2b2t player-base
	-- material (see museumloot's own THEMES.obsidian) so it cannot be
	-- used alone; requiring all three together is a much rarer
	-- coincidence.
	if any_node_near(pos, 8, RUINED_PORTAL_OBSIDIAN, bounds)
		and any_node_near(pos, 8, RUINED_PORTAL_CRYING_OBSIDIAN, bounds)
		and any_node_near(pos, 8, RUINED_PORTAL_NETHERRACK, bounds) then
		return { structure = "ruined_portal", loot_table = RUINED_PORTAL_LOOT, use = "get_loot" }
	end

	-- Jungle temple: mossy cobblestone nearby. Weaker signal than spec's
	-- mossy-cobble+tripwire combo (see note above -- no tripwire node
	-- exists in this checkout at all), checked after ruined portal /
	-- stronghold / desert temple so it doesn't preempt more distinctive
	-- matches.
	if any_node_near(pos, 8, JUNGLE_TEMPLE_MOSSY, bounds) then
		return { structure = "jungle_temple", loot_table = JUNGLE_TEMPLE_LOOT, use = "get_loot" }
	end

	-- Village: checked last -- a bell is valuable/decorative enough that
	-- 2b2t players sometimes loot one into their own base, so this is the
	-- heuristic most likely to false-positive. A bell within 24 is the
	-- primary signal per spec; farmland + composter within a tighter 12
	-- is the secondary "workstation" signal for containers with no bell
	-- nearby. Either branch picks village_armorer for a
	-- container that looks like it's in a workstation building (composter
	-- present) and village_plains_house otherwise.
	if any_node_near(pos, 24, VILLAGE_BELL, bounds) then
		if any_node_near(pos, 12, VILLAGE_WORKSTATION, bounds) then
			return { structure = "village", loot_table = VILLAGE_ARMORER_LOOT, use = "get_loot" }
		end
		return { structure = "village", loot_table = VILLAGE_PLAINS_HOUSE_LOOT, use = "get_loot" }
	end
	if any_node_near(pos, 12, VILLAGE_FARMLAND, bounds)
		and any_node_near(pos, 12, VILLAGE_WORKSTATION, bounds) then
		return { structure = "village", loot_table = VILLAGE_ARMORER_LOOT, use = "get_loot" }
	end

	return nil
end

-- Exposed for completeness / future callers (e.g. a maintainer wiring up
-- pillager outpost or woodland mansion detection later) -- not used by
-- detect() itself for those two structures.
structures.PILLAGER_OUTPOST_LOOT = PILLAGER_OUTPOST_LOOT
structures.WOODLAND_MANSION_LOOT = WOODLAND_MANSION_LOOT

return structures
