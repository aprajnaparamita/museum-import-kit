-- Post-import chest loot for the 2b2t museum.
--
-- Per FEATURE-loot.md, the original three-stage pipeline is
--   1. classify every container (structure match or sign gather)
--   2. (LLM) bundled DeepSeek queries -> themed JSON
--   3. apply: deterministic per-position, idempotent
--
-- Stage 2 in the spec explicitly flags the API call as a "judgement call"
-- and asks the user to confirm before any sign text is sent to a third
-- party. No API was set up; instead, this mod replaces stage 2 with a
-- *deterministic local keyword classifier* -- a few dozen hand-written
-- rules that map the words on a labelled chest to a theme. Sign text is
-- never sent off-host. The trade-off: classification is coarser than an
-- LLM's (catches "diamond" / "gold" / "shulker" etc. reliably; misses
-- freeform descriptions like "a couple totems and obsidian"). For 2b2t,
-- the labelled-chest corpus is mostly keyword-names, so this is a decent
-- substitute. An LLM stage can be slotted in later if the user provides
-- an API key -- the contract between stage 1 and stage 3 (a theme string
-- per container) doesn't change.

local modpath = core.get_modpath("museumloot")
local registry = _G.__spawnimport_registry
assert(registry, "[museumloot] spawnimport registry not exposed -- is spawnimport loaded and is it newer than this commit?")

-- New detection stage (runs before the sign-keyword classify() below): if
-- a container sits inside a real Mineclonia-mapgen structure, use that
-- structure's own hand-copied loot table instead of a THEMES lookup. See
-- structures.lua's own header comment for the full rationale + citations.
local structures = dofile(modpath .. "/structures.lua")

-- New mob-placement stage (runs after stage 3 loot-fill below, per base):
-- spawns villagers/illagers/shulkers near detected structures and makes
-- them permanent. Entirely separate concern from loot -- see
-- mobplacement.lua's own header for the full rationale + citations. Kept
-- as its own dofile-able module (same style as structures.lua) rather than
-- inlined here so the two passes stay independently readable/testable.
local mobplacement = dofile(modpath .. "/mobplacement.lua")

-- Curated PvP kit shulker boxes (Oysterity-style: a single pre-filled
-- shulker item placed inside a container, not a themed pile of loose
-- items). See pvpkits.lua's own header for the full rationale.
local pvpkits = dofile(modpath .. "/pvpkits.lua")

-- Cross-tick state. Must be declared at file scope so write/read in
-- later globalsteps survives strict-mode warnings ("Undeclared global
-- variable ..."). Luanti logs the warning but does NOT actually
-- discard the write; however declaring it once here is cleaner and
-- avoids the warning spam.
_G.__spawnimport_kicked = false
_G.__museumloot_stage = "starting"

-- ---------------------------------------------------------------------
-- Theme tables (loot_definitions for mcl_loot.get_loot).
-- ---------------------------------------------------------------------
-- Each theme is a list of stacks_min/stacks_max and a weighted items[]
-- table. mcl_loot.get_loot's "weight"/"amount_min"/"amount_max" are the
-- knobs; PcgRandom picks a stack count, then an item by weight, then a
-- count per item.
--
-- Generosity is biased toward anarchy-survival kit-up speed per
-- FEATURE-loot.md section 6: diamond/netherite gear, full Protection IV,
-- obsidian in near-full stacks, totems/elytra where thematically apt,
-- golden apples common, enchanted rare. A reading: a player who finds
-- one of these stashes should be PvP-ready after 4-6 chests, not 30.
--
-- Note: mcl_tools / mcl_mobitems spellings vary by item; check
-- /Users/dara/mineclonia/mods/ITEMS/* registration names if a stack
-- stack fails to form (the failure mode is "stack:to_table() empty,
-- inventory slot left as air").

local function item(name, amount_min, amount_max, weight, func)
	weight = weight or 1
	return { itemstring = name, amount_min = amount_min, amount_max = amount_max, weight = weight, func = func }
end

-- A "_enchanted" itemstring alone (e.g. "mcl_armor:helmet_diamond_enchanted")
-- is just a reskinned item with an empty enchantment list -- glowing/
-- differently colored but no actual effect, confirmed live this session
-- (tooltip showed no enchantment at all). Real Mineclonia loot tables
-- (see mods/MAPGEN/mcl_structures/end_city.lua) always pair the
-- "_enchanted" itemstring with a func that calls the real enchant API;
-- this mirrors that exact pattern.
--
-- Owner live-test (chest at ~448.6,70.8,1944.0 on 2026-09-17) showed
-- even when the "_enchanted" itemstring WAS used, real captures would
-- have 5-7 valid-for-this-item enchants (Sharpness V + Looting III +
-- Unbreaking III + Mending + Fire Aspect, etc.) -- one enchant per
-- item was too sparse. This helper layers MULTIPLE valid enchantments
-- (3-5 randomly, each at max-valid level) to match the dense-enchant
-- look of real 2b2t/Oysterity gear, and applies a custom-name pool so
-- items look "named" rather than pristine.
local _CUSTOM_NAME_POOL = {
	-- Generic PvP names owner has seen in real captures. Picked uniformly.
	"Anarchy", "Bedrock", "Chaos", "Tux's", "FISHY", "vivixyes", "Tuxanian",
	"Omega", "Meta", "Bane", "Shadow", "Crystal", "Dragon", "Nether",
	"Wither", "Apex", "Chaotic", "Fury", "Phantom", "Eternal",
}
-- Owner explicit 2026-09-18 (round 4): "I see a lot of items in chests
-- with Curse of Vanishing, nobody would use or save these, it's not
-- something that should be put on them." Verified real (the only real
-- "curse_*" enchant registered here -- curse_of_binding does NOT exist
-- in this Mineclonia checkout, grepped, not guessed).
local EXCLUDED_ENCHANTS = { "curse_of_vanishing" }
local function _add_random_enchant(stack, pr, exclude)
	local ench = mcl_enchanting.get_random_enchantment(stack, true, false, exclude, pr)
	if not ench then return nil end
	local max_lvl = mcl_enchanting.enchantments[ench].max_level or 1
	mcl_enchanting.enchant(stack, ench, max_lvl)
	return ench
end
-- 2026-09-19 owner explicit (round 19): "all potions should be the MAX
-- LEVEL these are swiftness, they should be swiftness II." Real
-- Mineclonia potion levels (I/II) are stored as ItemStack META, not a
-- separate itemstring -- confirmed in mods/ITEMS/mcl_potions/potions.lua
-- (`itemstack:get_meta():get_int("mcl_potions:potion_potent")`, read
-- back via `level_from_details`: `level = details.level + details.
-- level_scaling * potency`, so potency=1 -> level 2 for any effect with
-- `uses_factor = true` -- confirmed true for both `swiftness` and
-- `poison` in mods/ITEMS/mcl_potions/functions.lua; harming/healing use
-- a separate `custom_effect(player, potency+1, ...)` path that responds
-- to the same meta field the same way). Setting potency=1 is the max
-- real level for every one of these -- vanilla Minecraft has no Level
-- III potion.
-- 2026-09-19 round 20 correction: round 19's belief that count=1 "already
-- IS the max possible" for these was wrong -- pvpkits.lua already
-- established (round 4, reconfirmed live) that ItemStack:set_count()
-- does NOT clamp to a stack_max=1 potion's registered max, so a real
-- 64-stack is possible and round-trips correctly. The owner's round-20
-- question ("maybe all of them can't stack since in the kits
-- invisibility+ and strength II are never stacked") is answered by
-- pvpkits.lua's own history: invisibility+/strength were NEVER a
-- technical exception -- invisibility+ was explicitly reverted from 64
-- to 1 by the owner in round 5 ("I believe Invisibility + can also not
-- be stacked to 64, just one per slot"), a deliberate per-item choice,
-- and strength was simply never requested at 64 to begin with (round 4's
-- own quote: "potions of swiftness 2 stack of 64, invisibility, totems.
-- strength ii" -- only swiftness gets the "stack of 64" qualifier).
-- None of harming/healing/swiftness/poison_lingering (the four items in
-- this theme) have any such owner exception on record, and the original
-- round-19 request was explicit ("ALWAYS should be stacked to the MAX
-- AMOUNT possible") -- so this now also forces count=64, matching
-- swiftness's own kit precedent exactly. See also the
-- merge_and_quantize_loot fix below -- without it, this count would be
-- silently re-split back down to 1-count stacks by the post-roll
-- quantize pass, which reads the item's REGISTERED stack_max (1), not
-- this bypass.
local function max_potent(stack, pr)
	stack:get_meta():set_int("mcl_potions:potion_potent", 1)
	stack:set_count(64)
end

local function enchanted(stack, pr)
	-- Apply 3-5 valid enchantments at max level. Each call excludes every
	-- previous pick (plus EXCLUDED_ENCHANTS) so no duplicates and no
	-- curses. Limit 5 so we don't blow past the Mineclonia per-item cap
	-- or produce impossible enchant combos (e.g. Silk Touch + Fortune on
	-- the same pickaxe).
	--
	-- Real bug found and fixed 2026-09-18 while adding the curse
	-- exclusion above: `mcl_enchanting.get_random_enchantment`'s
	-- `exclude` param is checked via `table.indexof(exclude,
	-- enchantment)` (mods/ITEMS/mcl_enchanting/engine.lua) -- that
	-- function scans an ARRAY's positional values, not a dict's keys.
	-- The previous version of this function built `exclude` as
	-- `exclude[k] = true` (a dict keyed by enchant name) -- `#exclude`
	-- on a table with no integer keys is always 0, so `table.indexof`
	-- never found a match and duplicate-enchant exclusion silently
	-- never worked at all, this whole time. Now built as a real array.
	local count = pr:next(3, 5)
	local exclude = {}
	for _, e in ipairs(EXCLUDED_ENCHANTS) do exclude[#exclude + 1] = e end
	for _ = 1, count do
		local picked = _add_random_enchant(stack, pr, exclude)
		if not picked then break end
		exclude[#exclude + 1] = picked
	end
	-- Real captured 2b2t gear is almost always renamed. ~70% of enchanted
	-- rolls here get a custom name so the chest doesn't look pristine.
	if pr:next(1, 10) <= 7 then
		local n = _CUSTOM_NAME_POOL[pr:next(1, #_CUSTOM_NAME_POOL)]
		stack:get_meta():set_string("name", n .. " " .. stack:get_name():match("([^:_]+)$"))
	end
end

-- Real "god book" enchant combo (project owner, 2026-09-18, transcribed
-- from a live Oysterity Luanti Mineclonia server capture -- the exact
-- same reference already used in pvpkits.lua's kit_books), filtered to
-- enchants actually registered here (no thorns/protection, see
-- mods/ITEMS/mcl_enchanting/enchantments.lua). Owner: "ALWAYS use these
-- enchants on 85% of books and increase the number in all chests" --
-- real reference tooltip had Silk Touch, Unbreaking III, Power V,
-- Lure III, Efficiency V, Luck of the Sea III, Thorns III, Sharpness V,
-- Fire Aspect II, Mending, Protection IV, Quick Charge III, Punch II.
local REAL_BOOK_ENCHANTS = {
	silk_touch = 1, unbreaking = 3, power = 5, lure = 3,
	efficiency = 5, luck_of_the_sea = 3, sharpness = 5,
	fire_aspect = 2, mending = 1, quick_charge = 3, punch = 2,
}
local function real_book_enchants(stack, pr)
	if pr:next(1, 100) <= 85 then
		mcl_enchanting.set_enchantments(stack, REAL_BOOK_ENCHANTS)
		stack:get_meta():set_string("name", "God Book")
		if tt and tt.reload_itemstack_description then
			tt.reload_itemstack_description(stack)
		end
	else
		-- The remaining 15%: still a real book, just the generic
		-- randomized enchant roll instead of the exact reference combo,
		-- so not literally every single book in the world is identical.
		enchanted(stack, pr)
	end
end

-- 2026-09-19 owner explicit (round 14, live screenshots): themed gear
-- chests read as "one of every piece type, mostly unenchanted, mixed
-- with raw ingots/blocks" -- a real anarchy-server stash instead reads
-- as "someone specifically hoarded ONE weapon type" (a sword chest, a
-- pickaxe chest) or a matching armor set, NEVER mixed with raw
-- material (that belongs in a materials/valuables chest -- see
-- `valuables` above, which now holds every ingot/block this removes),
-- and "no gold weapons or tools ever" (gold tools are famously
-- terrible -- nobody would keep or store them). Real reference
-- (owner): "it might have pvp related things... BUT very very rarely
-- maybe 3%", and "the loading process should add the same kind of item
-- sequentially" (grouped by type, not interleaved). This replaces the
-- flat weighted-pool roll `gear_diamond`/`gear_netherite`/`gear_iron`/
-- `gear_gold` used to have (their own `items` lists below are now just
-- the dominant/support pools this reads from, not rolled directly via
-- mcl_loot).
local GEAR_ARCHETYPES = {
	diamond = {
		weapons = { "mcl_tools:sword_diamond", "mcl_tools:pick_diamond", "mcl_tools:axe_diamond", "mcl_tools:shovel_diamond" },
		armor = { "mcl_armor:helmet_diamond", "mcl_armor:chestplate_diamond", "mcl_armor:leggings_diamond", "mcl_armor:boots_diamond" },
		support = { "mcl_bows:crossbow", "mcl_bows:arrow" },
		enchant_chance = 90,
	},
	netherite = {
		weapons = { "mcl_tools:sword_netherite", "mcl_tools:pick_netherite", "mcl_tools:axe_netherite", "mcl_tools:shovel_netherite", "mcl_tools:mace" },
		armor = { "mcl_armor:helmet_netherite", "mcl_armor:chestplate_netherite", "mcl_armor:leggings_netherite", "mcl_armor:boots_netherite" },
		support = { "mcl_armor:elytra", "mcl_nether:netherite_upgrade_template", "mcl_armor:wayfinder" },
		enchant_chance = 90,
	},
	iron = {
		-- Owner: "iron is trash, most players barely use it" -- much
		-- lower enchant chance than diamond/netherite, matching iron's
		-- low real-world value on an anarchy server.
		weapons = { "mcl_tools:sword_iron", "mcl_tools:pick_iron", "mcl_tools:axe_iron", "mcl_tools:shovel_iron" },
		armor = { "mcl_armor:helmet_iron", "mcl_armor:chestplate_iron", "mcl_armor:leggings_iron", "mcl_armor:boots_iron" },
		support = { "mcl_buckets:bucket_water", "mcl_buckets:bucket_empty" },
		enchant_chance = 35,
	},
	gold = {
		-- Owner explicit: no gold weapons/tools ever. Owner explicit
		-- (round 15): helmet/boots are the one exception to "gold armor
		-- is trash" -- wearing either keeps piglins neutral in the
		-- Nether, a real reason to actually keep them, unlike
		-- chestplate/leggings (no such use, left out entirely). Only
		-- appears rarely (~3%, see GEAR_GOLD_RARE_CHANCE) and always
		-- fully enchanted when it does -- see the `material == "gold"`
		-- special case in build_dominant_gear_items below.
		weapons = {},
		armor = { "mcl_armor:helmet_gold", "mcl_armor:boots_gold" },
		-- `support` is unused for gold -- build_dominant_gear_items
		-- hardcodes enchanted golden apples directly for it now (round
		-- 19: plain apple_gold was never allowed to appear at all).
		support = {},
		enchant_chance = 100,
	},
}
local GEAR_GOLD_RARE_CHANCE = 3

-- theme_key -> GEAR_ARCHETYPES key, used by fill_inv_from_theme to
-- route these 4 themes to build_dominant_gear_items instead of a flat
-- mcl_loot roll.
-- Round 21: gear_iron kept here (harmless -- dead unless something
-- routes a container to theme_key "gear_iron", which nothing does
-- anymore, see THEME_RULES and FALLBACK_POOL above) rather than deleted,
-- in case a future round wants a controlled way to bring back a rare
-- iron-gear chest deliberately instead of by an unintended nonzero
-- weight.
local GEAR_THEME_MATERIAL = {
	gear_diamond = "diamond",
	gear_netherite = "netherite",
	gear_iron = "iron",
	gear_gold = "gold",
}

-- Owner: "pvp related things such as full stacks of pearls or cobwebs
-- or fireworks." Real, verified names -- one category chosen per roll.
local GEAR_PVP_EXTRAS = {
	{ item = "mcl_throwing:ender_pearl", count = 64 },
	{ item = "mcl_core:cobweb", count = 64 },
	{ item = "mcl_fireworks:rocket_1", count = 64 },
}

local function gear_piece(base_item, enchant_chance, pr)
	if pr:next(1, 100) <= enchant_chance then
		local ench_name = base_item .. "_enchanted"
		if core.registered_items[ench_name] then
			local stack = ItemStack(ench_name)
			enchanted(stack, pr)
			return stack
		end
	end
	return ItemStack(base_item)
end

local function build_dominant_gear_items(material, inv_size, pr)
	local arch = GEAR_ARCHETYPES[material]
	local items = {}

	-- Gold is a special case, not the usual dominant-weapon/armor-chest
	-- flow: no gold weapons ever, and gold armor is trash EXCEPT
	-- helmet/boots (Nether piglin-neutral use) which are rare (~3%) and
	-- always fully enchanted when present -- see GEAR_ARCHETYPES.gold's
	-- own comment. The rest of the container is just enchanted golden
	-- apples.
	--
	-- 2026-09-19 owner correction (round 19): this was picking randomly
	-- between plain and enchanted apple_gold (arch.support had both) and
	-- never setting a count, so every gold container filled with 27
	-- individual count=1 stacks, mostly plain -- exactly the "garbage"
	-- shulker the owner reported (real screenshot). Owner: "ALL apples
	-- in chests should be enchanted golden apples NOT golden apples and
	-- ALL WITHOUT EXCEPTION should be stacks of 64." Fixed: always the
	-- enchanted item, always a real 64-stack.
	if material == "gold" then
		for i = 1, inv_size do
			items[i] = ItemStack("mcl_core:apple_gold_enchanted 64")
		end
		if pr:next(1, 100) <= GEAR_GOLD_RARE_CHANCE then
			local piece = arch.armor[pr:next(1, #arch.armor)]
			items[1] = gear_piece(piece, arch.enchant_chance, pr)
		end
		table.sort(items, function(a, b) return a:get_name() < b:get_name() end)
		return items
	end

	-- "Mostly weapons chests are a specific weapon" -- 70% weapon chest
	-- (one dominant type filling most of the container), 30% armor chest
	-- (a matching set, repeated) -- unless this material has no weapons
	-- at all (gold), which is always an armor chest.
	local is_weapon_chest = (#arch.weapons > 0) and (pr:next(1, 100) <= 70)
	if is_weapon_chest then
		-- Round 24 (owner explicit, live report: "lots and lots of
		-- pickaxes (this ones is important)"): the dominant weapon type
		-- used to be picked uniformly among 4-5 types (1/4 or 1/5 odds
		-- for pickaxe) -- weighted here instead, pickaxe gets double
		-- odds relative to everything else, matching what an anarchy
		-- server player would actually stockpile most (mining/griefing
		-- tool, not just a weapon).
		local weighted_weapons, weapon_weights, total_weight = {}, {}, 0
		for _, w in ipairs(arch.weapons) do
			local wt = w:find("pick_") and 2 or 1
			weighted_weapons[#weighted_weapons + 1] = w
			weapon_weights[#weapon_weights + 1] = wt
			total_weight = total_weight + wt
		end
		local roll, acc, dominant = pr:next(1, total_weight), 0, weighted_weapons[1]
		for i, w in ipairs(weighted_weapons) do
			acc = acc + weapon_weights[i]
			if roll <= acc then dominant = w; break end
		end
		local dominant_count = math.max(1, math.floor(inv_size * 0.85))
		for _ = 1, dominant_count do
			items[#items + 1] = gear_piece(dominant, arch.enchant_chance, pr)
		end
		-- A small trickle of support pieces or an alternate weapon type
		-- from the SAME tier -- never raw materials, those are gone.
		for _ = dominant_count + 1, inv_size do
			if #arch.support > 0 and pr:next(1, 100) <= 50 then
				items[#items + 1] = ItemStack(arch.support[pr:next(1, #arch.support)])
			else
				items[#items + 1] = gear_piece(arch.weapons[pr:next(1, #arch.weapons)], arch.enchant_chance, pr)
			end
		end
	else
		-- Armor chest: full matching sets, repeated to fill the
		-- container.
		local sets = math.max(1, math.floor(inv_size / #arch.armor))
		for _, piece in ipairs(arch.armor) do
			for _ = 1, sets do
				items[#items + 1] = gear_piece(piece, arch.enchant_chance, pr)
			end
		end
		for _ = #items + 1, inv_size do
			if #arch.support > 0 then
				items[#items + 1] = ItemStack(arch.support[pr:next(1, #arch.support)])
			end
		end
	end

	-- Round 24 (owner explicit): "enchanted full shears" -- shears aren't
	-- material-tiered (one real item, "mcl_tools:shears", confirmed
	-- against mods/ITEMS/mcl_tools/init.lua -- no separate "_enchanted"
	-- itemstring exists for it the way sword/pick/axe/etc. have, so
	-- gear_piece's own "_enchanted" itemstring lookup would never find
	-- one and silently always return it plain). Uses the same real
	-- enchanted() helper this file already applies to weapons/armor
	-- directly instead, which enchants via meta and works on any tool
	-- mcl_enchanting considers valid -- not material/theme-specific, so
	-- applied here once for diamond/netherite/iron chests only (not
	-- gold, which returns early above and never reaches this point).
	if #items >= 3 and pr:next(1, 100) <= 20 then
		local shears = ItemStack("mcl_tools:shears")
		enchanted(shears, pr)
		items[#items] = shears
		if pr:next(1, 100) <= 40 then
			local shears2 = ItemStack("mcl_tools:shears")
			enchanted(shears2, pr)
			items[#items - 1] = shears2
		end
	end

	-- "It might have pvp related things... BUT very very rarely maybe
	-- 3% of the time." One roll per container; replaces the last two
	-- slots with one real full-stack extra category.
	if #items >= 2 and pr:next(1, 100) <= 3 then
		local extra = GEAR_PVP_EXTRAS[pr:next(1, #GEAR_PVP_EXTRAS)]
		if core.registered_items[extra.item] then
			items[#items] = ItemStack(extra.item .. " " .. extra.count)
			items[#items - 1] = ItemStack(extra.item .. " " .. extra.count)
		end
	end

	-- "The loading process should add the same kind of item
	-- sequentially... sword, sword, sword, sword, mace, mace, mace,
	-- mace." Group same-type items together.
	table.sort(items, function(a, b) return a:get_name() < b:get_name() end)
	return items
end

THEMES = {
	default_stash = {
		description = "mixed PvP kit -- the catch-all when sign text says nothing useful",
		{ stacks_min = 6, stacks_max = 10, items = {
			item("mcl_core:diamond", 4, 12, 3),
			item("mcl_core:diamond", 12, 24, 2),
			item("mcl_core:diamondblock", 1, 2, 2),
			item("mcl_tools:pick_diamond", 1, 1, 1),
			item("mcl_tools:pick_diamond_enchanted", 1, 1, 4, enchanted),
			item("mcl_tools:sword_diamond", 1, 1, 1),
			item("mcl_tools:sword_diamond_enchanted", 1, 1, 4, enchanted),
			-- 2026-09-19 owner correction (round 13): "unenchanted diamond
			-- is very very rare and usually thrown away or enchanted" --
			-- these weights were STILL the pre-round-5 ratio (plain 4x
			-- more likely than enchanted), inconsistent with gear_diamond
			-- below, which was already flipped 2026-09-18 for the exact
			-- same owner feedback ("loot... is also not enchanted often,
			-- it mostly should be enchanted"). Flipped to match.
			item("mcl_armor:helmet_diamond", 1, 1, 1),
			item("mcl_armor:helmet_diamond_enchanted", 1, 1, 4, enchanted),
			item("mcl_armor:chestplate_diamond", 1, 1, 1),
			item("mcl_armor:chestplate_diamond_enchanted", 1, 1, 4, enchanted),
			item("mcl_armor:leggings_diamond", 1, 1, 1),
			item("mcl_armor:leggings_diamond_enchanted", 1, 1, 4, enchanted),
			item("mcl_armor:boots_diamond", 1, 1, 1),
			item("mcl_armor:boots_diamond_enchanted", 1, 1, 4, enchanted),
			item("mcl_core:gold_ingot", 6, 16, 2),
			-- 2026-09-19 owner explicit (round 19): "ALL apples in chests
			-- should be enchanted golden apples NOT golden apples and ALL
			-- WITHOUT EXCEPTION should be stacks of 64. remove all code
			-- which places plain apples, or golden apples or anything but
			-- stacks of 64 enchanted golden apples." Both entries below
			-- (plain apple_gold and plain apple) replaced with one
			-- fixed-64-stack enchanted entry.
			item("mcl_core:apple_gold_enchanted", 64, 64, 1, enchanted),
			item("mcl_core:obsidian", 16, 32, 2),
			item("mcl_throwing:ender_pearl", 4, 8, 1),
			item("mcl_tnt:tnt", 8, 16, 1),
			item("mcl_mobitems:cooked_beef", 8, 16, 1),
			item("mcl_fireworks:rocket_1", 4, 8, 1),
			-- 2026-09-19 owner explicit (round 13): "you really need to
			-- look at a much larger list of blocks and items... much much
			-- much more variety." Real, verified (grepped) everyday
			-- items/blocks at modest weight, supplementing the
			-- valuable-gear-focused list above rather than replacing it.
			item("mcl_farming:bread", 3, 6, 2),
			item("mcl_farming:cookie", 4, 12, 1),
			item("mcl_farming:pumpkin_pie", 1, 3, 1),
			item("mcl_core:sandstone", 8, 24, 1),
			item("mcl_core:brick_block", 8, 24, 1),
			item("mcl_nether:quartz_block", 4, 16, 1),
			item("mcl_wool:white", 4, 16, 1),
			item("mcl_wool:red", 4, 16, 1),
			item("mcl_wool:blue", 4, 16, 1),
			item("mcl_dyes:cyan", 4, 16, 1),
			item("mcl_dyes:lime", 4, 16, 1),
			item("mcl_flowers:poppy", 4, 16, 1),
			item("mcl_flowers:dandelion", 4, 16, 1),
			item("mcl_farming:wheat_seeds", 8, 24, 1),
		} },
	},

	-- 2026-09-19 round 14: gear_diamond/gear_netherite/gear_iron/
	-- gear_gold no longer roll from an `items` list here at all --
	-- fill_inv_from_theme routes them to build_dominant_gear_items()
	-- (see GEAR_ARCHETYPES/GEAR_THEME_MATERIAL above THEMES) instead,
	-- per the owner's "one dominant weapon type, no raw materials mixed
	-- in, no gold weapons ever" redesign. `description` is kept for
	-- classify()'s keyword-matching docs/logging; `items` is gone
	-- entirely rather than left as unused, misleading dead content.
	gear_diamond = { description = "diamond/netherite gear, multiple pieces -- 'diamond', 'gear', 'best', 'anarchy'" },
	gear_netherite = { description = "netherite gear -- very rare on 2b2t (overworld only), usually small" },
	gear_iron = { description = "iron tools + iron gear, the workhorse tier" },
	gear_gold = { description = "gold -- golden apples, golden armor (never gold weapons/tools)" },

	shulker_box = {
		description = "full shulker boxes -- curated, thematically coherent",
		{ stacks_min = 3, stacks_max = 5, items = {
			-- Mix of colored shulker boxes; mostly white (uncolored)
			item("mcl_chests:white_shulker_box", 1, 1, 4),
			item("mcl_chests:orange_shulker_box", 1, 1, 1),
			item("mcl_chests:magenta_shulker_box", 1, 1, 1),
			item("mcl_chests:lightblue_shulker_box", 1, 1, 1),
			item("mcl_chests:yellow_shulker_box", 1, 1, 1),
			item("mcl_chests:green_shulker_box", 1, 1, 1),
			item("mcl_chests:pink_shulker_box", 1, 1, 1),
			item("mcl_chests:dark_grey_shulker_box", 1, 1, 1),
			item("mcl_chests:cyan_shulker_box", 1, 1, 1),
			item("mcl_chests:violet_shulker_box", 1, 1, 1),
			item("mcl_chests:blue_shulker_box", 1, 1, 1),
			item("mcl_chests:brown_shulker_box", 1, 1, 1),
			item("mcl_chests:green_shulker_box", 1, 1, 1),
			item("mcl_chests:red_shulker_box", 1, 1, 1),
			item("mcl_chests:black_shulker_box", 1, 1, 1),
			item("mcl_mobitems:shulker_shell", 1, 2, 2),
		} },
	},

	obsidian = {
		description = "obsidian in stacks (the 2b2t staple)",
		{ stacks_min = 3, stacks_max = 5, items = {
			item("mcl_core:obsidian", 32, 64, 4),
			item("mcl_core:obsidian", 8, 16, 2),
			item("mcl_core:crying_obsidian", 4, 8, 1),
			item("mcl_throwing:ender_pearl", 4, 8, 2),
			item("mcl_throwing:ender_pearl", 16, 32, 1),
		} },
	},

	potions = {
		description = "splash potions of harming/healing/speed",
		{ stacks_min = 4, stacks_max = 6, items = {
			-- 2026-09-19 owner explicit (round 19): "all potions should
			-- be the MAX LEVEL" -- see max_potent's own comment for the
			-- real mechanism (ItemStack meta, not a separate item).
			-- Stack size is NOT a bug here -- potions (splash included)
			-- have a real stack_max of 1 in this build (mods/ITEMS/
			-- mcl_potions/potions.lua: `pdef.stack_max = def.stack_max
			-- or 1`, never overridden for these), so count=1 per slot
			-- already IS "the max amount possible" for this item type.
			item("mcl_potions:harming_splash", 1, 1, 4, max_potent),
			item("mcl_potions:healing_splash", 1, 1, 2, max_potent),
			item("mcl_potions:swiftness_splash", 1, 1, 2, max_potent),
			item("mcl_potions:poison_lingering", 1, 1, 1, max_potent),
			item("mcl_potions:glass_bottle", 4, 8, 1),
			item("mcl_potions:fermented_spider_eye", 2, 4, 1),
			item("mcl_mobitems:blaze_powder", 4, 8, 1),
			item("mcl_mobitems:ghast_tear", 1, 2, 1),
		} },
	},

	food = {
		description = "ready-to-eat food -- ingredients moved to `gardening`",
		{ stacks_min = 6, stacks_max = 9, items = {
			-- Round 21 (owner explicit, live report): "normally a person
			-- will not store seeds with the finished ready to eat
			-- food... Wheat is not normally stored ehre either as this is
			-- more of a material which goes into food... A food chest
			-- would have cooked potatoes and golden carrots - food ready
			-- to eat." Raw wheat/carrot/potato/beetroot/seeds all moved
			-- out to the new `gardening` theme below (this theme's own
			-- round-18 comment about the bare-node-vs-craftitem bug still
			-- applies to gardening's items, just relocated). Golden
			-- carrot and baked potato added -- the owner's exact example
			-- of what a real "ready to eat" food chest should contain,
			-- and a real, previously-missing gap ("one of the most
			-- commonly used food sources").
			item("mcl_farming:potato_item_baked", 16, 32, 3),
			item("mcl_farming:carrot_item_gold", 16, 32, 3),
			item("mcl_farming:bread", 8, 16, 2),
			item("mcl_mobitems:cooked_beef", 16, 32, 2),
			item("mcl_mobitems:cooked_chicken", 16, 32, 1),
			item("mcl_fishing:salmon_cooked", 16, 32, 1),
			item("mcl_fishing:fish_cooked", 16, 32, 1),
			item("mcl_mobitems:cooked_porkchop", 16, 32, 1),
			item("mcl_mobitems:cooked_mutton", 16, 32, 1),
			item("mcl_farming:melon_item", 16, 32, 1),
			-- 2026-09-19 owner explicit (round 19): plain apple removed,
			-- see default_stash's matching comment above -- enchanted
			-- golden apple, fixed 64-stack, everywhere.
			item("mcl_core:apple_gold_enchanted", 64, 64, 1, enchanted),
			item("mcl_farming:sweet_berry", 8, 16, 1),
			-- 2026-09-19 owner explicit (round 19): "bucket of fish,
			-- bucket of axolotl and bucket of cod are not food types,
			-- these are usually kept in landscaping sets." Moved to the
			-- new `landscaping` theme below.
		} },
	},

	-- Round 21 (owner explicit): raw/growing crop produce -- "a gardening
	-- chest would have regular potatoes and carrots" -- and wheat, which
	-- the owner explicitly called "more of a material which goes into
	-- food" than food itself. Bare-node-vs-craftitem names verified the
	-- same way `food` already had to learn the hard way (round 18): the
	-- real harvested items all carry an explicit "_item" suffix, not the
	-- growable plant-node name.
	gardening = {
		description = "raw/growing produce -- carrots, potatoes, wheat, seeds",
		{ stacks_min = 5, stacks_max = 8, items = {
			item("mcl_farming:wheat_item", 16, 32, 3),
			item("mcl_farming:carrot_item", 16, 32, 3),
			item("mcl_farming:potato_item", 16, 32, 3),
			item("mcl_farming:beetroot_item", 16, 32, 2),
			item("mcl_farming:wheat_seeds", 16, 32, 2),
			item("mcl_farming:beetroot_seeds", 16, 32, 1),
			item("mcl_farming:melon_seeds", 16, 32, 1),
			item("mcl_farming:pumpkin_seeds", 16, 32, 1),
		} },
	},

	-- 2026-09-19 owner explicit (round 19): "these are usually kept in
	-- landscaping sets" (re: fish/axolotl/cod buckets) plus "there
	-- should be more chest types." New theme for decorative/aquascaping
	-- items a builder would keep together, distinct from `food`.
	landscaping = {
		description = "aquascaping/decorative -- mob buckets, kept separate from food",
		{ stacks_min = 3, stacks_max = 5, items = {
			item("mcl_buckets:bucket_tropical_fish", 1, 1, 1),
			item("mcl_buckets:bucket_axolotl", 1, 1, 1),
			item("mcl_buckets:bucket_cod", 1, 1, 1),
			item("mcl_buckets:bucket_salmon", 1, 1, 1),
			item("mcl_buckets:bucket_pufferfish", 1, 1, 1),
			item("mcl_core:cactus", 8, 16, 1),
			item("mcl_core:reeds", 16, 32, 1),
			item("mcl_flowers:tallgrass", 8, 16, 1),
			item("mcl_core:vine", 8, 16, 1),
		} },
	},

	tnt = {
		description = "TNT and explosives -- 'tnt', 'boom', 'creeper'",
		{ stacks_min = 4, stacks_max = 6, items = {
			item("mcl_tnt:tnt", 16, 32, 4),
			item("mcl_tnt:tnt", 32, 64, 2),
			item("mcl_mobitems:gunpowder", 16, 32, 2),
			item("mcl_fire:flint_and_steel", 1, 1, 2),
			item("mcl_fire:fire_charge", 8, 16, 1),
			item("mcl_heads:creeper", 1, 1, 1),
		} },
	},

	enchantment = {
		description = "books, experience, anvil-bound treasure -- 'books', 'enchant', 'xp'",
		{ stacks_min = 6, stacks_max = 9, items = {
			-- Owner explicit 2026-09-18: "ALWAYS use these enchants on 85%
			-- of books and increase the number in all chests" -- switched
			-- from the generic random-enchant helper to real_book_enchants
			-- (85% real reference "god book" combo, 15% still-random
			-- fallback), and weight/count bumped so books show up more
			-- and in bigger piles, not a single copy.
			item("mcl_enchanting:book_enchanted", 2, 5, 8, real_book_enchants),
			item("mcl_books:book", 2, 6, 1),
			item("mcl_experience:bottle", 8, 16, 2),
			item("mcl_experience:bottle", 16, 32, 1),
			item("mcl_mobitems:blaze_rod", 4, 8, 1),
			item("mcl_core:diamond", 4, 8, 1),
			item("mcl_core:obsidian", 8, 16, 1),
		} },
	},

	building = {
		description = "bulk building blocks -- 'block', 'build', 'mat', 'material'",
		{ stacks_min = 4, stacks_max = 6, items = {
			item("mcl_core:stone", 64, 64, 2),
			item("mcl_core:cobble", 64, 64, 2),
			item("mcl_core:dirt", 64, 64, 1),
			item("mcl_trees:tree_oak", 32, 64, 1),
			item("mcl_trees:wood_oak", 64, 64, 1),
			item("mcl_colorblocks:concrete_white", 64, 64, 1),
			item("mcl_colorblocks:concrete_black", 64, 64, 1),
			item("mcl_colorblocks:concrete_red", 64, 64, 1),
			item("mcl_colorblocks:concrete_blue", 64, 64, 1),
		} },
	},

	-- Plain raw-material dump -- what a survival player would actually stack
	-- up while mining/building, not a curated decorative set. Distinct from
	-- "building" above (concrete/colored blocks): this is unglamorous bulk
	-- stone/dirt/sand/netherrack, the kind of chest that exists because
	-- someone needed somewhere to put 4 stacks of cobblestone.
	materials = {
		description = "plain raw materials -- stone/cobble/netherrack/sand/gravel, no decoration",
		{ stacks_min = 3, stacks_max = 6, items = {
			item("mcl_core:stone", 64, 64, 3),
			item("mcl_core:cobble", 64, 64, 3),
			item("mcl_core:dirt", 64, 64, 2),
			item("mcl_core:gravel", 64, 64, 2),
			item("mcl_core:sand", 64, 64, 2),
			item("mcl_core:glass", 32, 64, 2),
			item("mcl_nether:netherrack", 64, 64, 2),
			item("mcl_nether:nether_wart_block", 16, 32, 1),
			item("mcl_trees:tree_oak", 32, 64, 2),
			item("mcl_trees:wood_oak", 64, 64, 1),
			item("mcl_core:coal_lump", 16, 32, 1),
			item("mcl_core:iron_ingot", 4, 8, 1),
			item("mcl_buckets:bucket_water", 1, 2, 1),
			item("mcl_buckets:bucket_lava", 1, 1, 1),
			item("mcl_buckets:bucket_empty", 1, 3, 1),
		} },
	},

	-- Emerald/lapis/netherite-scrap treasure mix -- valuable but not full
	-- gear sets, distinct from the "curated PvP kit" reading of
	-- default_stash/gear_diamond. This is the "found some good stuff" chest.
	valuables = {
		description = "emerald/lapis/netherite/gold mix -- valuable, not a full gear set",
		{ stacks_min = 4, stacks_max = 7, items = {
			item("mcl_core:emerald", 4, 12, 3),
			item("mcl_core:emeraldblock", 1, 2, 1),
			item("mcl_core:lapis", 8, 24, 3),
			item("mcl_core:lapisblock", 1, 2, 1),
			item("mcl_nether:netherite_scrap", 1, 3, 2),
			item("mcl_nether:netherite_ingot", 1, 1, 1),
			item("mcl_core:gold_ingot", 8, 16, 2),
			item("mcl_core:diamond", 2, 6, 2),
			item("mcl_core:coal_lump", 8, 16, 1),
			-- 2026-09-19 owner explicit (round 19): plain apple_gold
			-- removed, see default_stash's matching comment above.
			item("mcl_core:apple_gold_enchanted", 64, 64, 1, enchanted),
			-- 2026-09-19 owner explicit (round 14): "in netherite weapons
			-- chests they rarely if ever have netherite... these would go
			-- in a minerals chest -- never stored with the weapons.
			-- similarly diamond armor does not have diamonds in it. gold
			-- armor does not have gold ingots, blocks." Raw
			-- ingot/block forms removed from gear_diamond/gear_netherite/
			-- gear_iron/gear_gold below -- this is their real home now.
			item("mcl_core:diamondblock", 1, 2, 1),
			item("mcl_nether:netheriteblock", 1, 1, 1),
			item("mcl_core:ironblock", 1, 3, 1),
			item("mcl_core:iron_ingot", 8, 16, 2),
			item("mcl_core:goldblock", 1, 3, 1),
		} },
	},

	-- The "junk drawer" chest -- ordinary mob/farming drops, no gear, no
	-- valuables. In a real survival world most containers are NOT curated
	-- loot; per the project owner's own description, this should be rare
	-- (see RANDOM_ITEMS_CHANCE below) but common enough that not every
	-- chest reads as deliberately stocked.
	random_items = {
		description = "mob/farming drops AND random collected-block clutter -- what a player actually picks up",
		{ stacks_min = 3, stacks_max = 6, items = {
			item("mcl_mobitems:spider_eye", 1, 4, 3),
			item("mcl_mobitems:bone", 2, 8, 3),
			item("mcl_mobitems:string", 2, 8, 3),
			item("mcl_mobitems:gunpowder", 1, 4, 2),
			item("mcl_mobitems:rotten_flesh", 2, 6, 2),
			item("mcl_mobitems:feather", 2, 6, 2),
			item("mcl_ocean:kelp", 2, 8, 2),
			item("mcl_nether:nether_wart_item", 1, 4, 1),
			item("mcl_trees:sapling_oak", 1, 3, 1),
			item("mcl_trees:sapling_spruce", 1, 3, 1),
			item("mcl_trees:sapling_birch", 1, 3, 1),
			item("mcl_core:stick", 4, 16, 2),
			item("mcl_farming:wheat_seeds", 2, 6, 1),
			-- Owner explicit 2026-09-18: "a few [chests] being full of
			-- random items as well of things users randomly pick up. like
			-- beds, doors, wool blocks, torches, spider eyes, string,
			-- bones, bone blocks, colored terracotta. it really should
			-- represent most of the block palette used in the game that
			-- is collectable by players." Names verified against real
			-- registrations (mods/ITEMS/mcl_beds/mcl_doors/mcl_torches/
			-- mcl_core/mcl_colorblocks), not guessed.
			item("mcl_torches:torch", 8, 32, 2),
			item("mcl_doors:door_oak", 1, 3, 1),
			item("mcl_doors:door_spruce", 1, 3, 1),
			item("mcl_beds:bed_red", 1, 2, 1),
			item("mcl_beds:bed_blue", 1, 2, 1),
			item("mcl_beds:bed_white", 1, 2, 1),
			item("mcl_wool:white", 8, 32, 2),
			item("mcl_wool:red", 8, 32, 1),
			item("mcl_wool:blue", 8, 32, 1),
			item("mcl_wool:black", 8, 32, 1),
			item("mcl_core:bone_block", 4, 16, 1),
			item("mcl_colorblocks:hardened_clay_white", 8, 24, 1),
			item("mcl_colorblocks:hardened_clay_orange", 8, 24, 1),
			item("mcl_colorblocks:hardened_clay_red", 8, 24, 1),
			item("mcl_colorblocks:hardened_clay_blue", 8, 24, 1),
		} },
	},

	trophy = {
		description = "rarity trophies -- 'skull', 'head', 'trophy', 'rare'",
		{ stacks_min = 3, stacks_max = 5, items = {
			item("mcl_heads:skeleton", 1, 1, 3),
			item("mcl_heads:wither_skeleton", 1, 1, 2),
			item("mcl_heads:zombie", 1, 1, 2),
			item("mcl_heads:creeper", 1, 1, 2),
			item("mcl_heads:dragon", 1, 1, 1),
			item("mcl_mobitems:nether_star", 1, 1, 1),
			item("mcl_totems:totem", 1, 1, 1),
			item("mcl_armor:elytra", 1, 1, 1),
			item("mcl_end:dragon_egg", 1, 1, 1),
		} },
	},

	redstone = {
		description = "redstone engineering -- 'redstone', 'piston', 'redstone'",
		{ stacks_min = 4, stacks_max = 6, items = {
			item("mcl_redstone:redstone", 32, 64, 3),
			item("mcl_redstone_torch:redstoneblock", 4, 8, 2),
			item("mcl_core:stick", 32, 64, 1),
			item("mcl_core:iron_ingot", 8, 16, 1),
			item("mcl_repeaters:repeater_off_1", 4, 8, 1),
			item("mcl_comparators:comparator_off_comp", 4, 8, 1),
			item("mcl_pistons:piston_off", 4, 8, 1),
			item("mcl_hoppers:hopper", 4, 8, 1),
			-- Owner explicit 2026-09-18 round 5: "Redstone and Utilities:
			-- redstone dust, repeaters, comparators, pistons, hoppers,
			-- torches, and crafting tables." Torch/crafting table added.
			item("mcl_torches:torch", 16, 32, 2),
			item("mcl_crafting_table:crafting_table", 1, 2, 1),
		} },
	},

	ender = {
		description = "ender stuff -- 'ender', 'pearls', 'eyes'",
		{ stacks_min = 4, stacks_max = 6, items = {
			item("mcl_throwing:ender_pearl", 8, 16, 4),
			item("mcl_throwing:ender_pearl", 16, 32, 2),
			item("mcl_throwing:ender_pearl", 32, 64, 1),
			item("mcl_end:ender_eye", 2, 4, 2),
			item("mcl_core:obsidian", 8, 16, 1),
			item("mcl_mobitems:blaze_powder", 4, 8, 1),
		} },
	},

	misc = {
		description = "low-tier misc -- bottom of a 1000-container dump",
		{ stacks_min = 4, stacks_max = 6, items = {
			item("mcl_core:stick", 32, 64, 2),
			item("mcl_mobitems:string", 16, 32, 1),
			item("mcl_mobitems:bone", 16, 32, 1),
			item("mcl_mobitems:feather", 16, 32, 1),
			item("mcl_bows:arrow", 32, 64, 1),
			item("mcl_mobitems:leather", 8, 16, 1),
			-- Owner explicit 2026-09-18 round 5: "Mob Drops and Farming:
			-- Gunpowder, string, bones, spider eyes, feathers..."
			item("mcl_mobitems:gunpowder", 16, 32, 1),
			item("mcl_mobitems:spider_eye", 8, 16, 1),
		} },
	},
}

-- ---------------------------------------------------------------------
-- Theme classifier -- replaces stage 2 of the spec.
-- ---------------------------------------------------------------------
-- Maps nearby sign text to one of the THEMES above. Order of rules
-- matters: more specific keys first. Compound "diamond gear" looks at
-- "diamond" first and gets gear_diamond, which is what we want; "iron
-- gear" similarly. "stuff" alone falls through to misc.
--
-- Sign text on 2b2t is in English (mostly) and lowercase only when
-- players are clean; all comparisons normalise.

local THEME_RULES = {
	-- Checked before the plain "kit" rule below: "kits"/"kit room" contain
	-- the substring "kit" too, and THEME_RULES matching is first-hit-wins,
	-- so the plural/room form must come first or it'd never be reachable.
	{ key = "pvp_kit_closet", match = { "kits", "kit room", "loadouts", "kit closet" } },
	{ key = "pvp_kit",       match = { "kit", "loadout", "pvp kit" } },
	-- "anarchy"/"best"/"meta"/"pro" were dropped: real 2b2t sign text uses
	-- these words constantly for reasons that have nothing to do with
	-- what's actually in the chest ("anarchy" as a base-name word, "pro"
	-- as part of a player name, etc.) -- confirmed live this session,
	-- they were routing a large fraction of ALL labeled containers into
	-- gear_diamond regardless of real content, which is most of why
	-- "diamond armor and not much else" dominated even after the
	-- fallback-pool rework. "diamond" alone is a real, deliberate signal.
	{ key = "gear_diamond",  match = { "diamond" } },
	{ key = "gear_netherite", match = { "netherite", "debris" } },
	-- Round 21 (owner explicit, live report, escalating: "i thought we
	-- removed this? this was requested and marked off at least 3 times"):
	-- a sign-matched "iron"/"pickaxe" chest used to route here, but
	-- gear_iron itself is being eliminated below (see GEAR_THEME_MATERIAL
	-- and the weighted pool) -- redirect to gear_netherite instead of
	-- leaving a dangling match to a theme nothing should ever reach.
	{ key = "gear_netherite", match = { "iron", "pickaxe" } },
	{ key = "gear_gold",     match = { "gold", "gapple", "golden" } },
	{ key = "shulker_box",   match = { "shulker", "ender chest" } },
	{ key = "obsidian",      match = { "obsidian", "crying", "obby" } },
	{ key = "tnt",           match = { "tnt", "boom", "creeper", "explosiv" } },
	{ key = "potions",       match = { "potions", "potion", "splash", "harming", "healing" } },
	-- 2026-09-19 owner explicit (round 19): fish/axolotl/cod buckets
	-- "are usually kept in landscaping sets" -- new theme, checked
	-- before "food" (whose "eat"/"food" keywords don't overlap with
	-- these anyway, but landscaping's own words are more specific and
	-- should win any edge-case collision).
	{ key = "landscaping",   match = { "landscap", "aquascap", "aquarium", "decor" } },
	{ key = "gardening",     match = { "garden", "farm", "crop", "seed" } },
	{ key = "food",          match = { "food", "foods", "bread", "carrot", "eat" } },
	{ key = "enchantment",   match = { "enchant", "books", "xp", "experience", "anvil", "bottle o" } },
	{ key = "building",      match = { "blocks", "build", "mat", "stone", "wood" } },
	{ key = "trophy",        match = { "trophy", "skull", "head", "rare", "totem", "elytra" } },
	{ key = "redstone",      match = { "redstone", "piston", "hopper", "repeater" } },
	{ key = "ender",         match = { "ender", "pearls", "pearl", "eye of ender" } },
	{ key = "valuables",     match = { "emerald", "lapis", "valuable", "treasure", "loot" } },
	{ key = "default_stash", match = {} }, -- always fallback
}

-- Most containers have no sign text at all (FEATURE-loot.md's own finding:
-- 2b2t stashes are emptied and re-signed inconsistently). Without this
-- roll, every single one of those fell through to "default_stash" --
-- curated PvP-kit-adjacent loot in literally every unlabeled chest, which
-- reads as obviously artificial rather than like a real survival world.
-- Roll a weighted pick among the "no strong signal" pool instead; keyword
-- matches above are untouched and always win when a sign actually says
-- something. Seeded from position so reruns are deterministic, same as
-- fill_inv_from_theme's own seeding.
-- Deliberately spread across the full gear spectrum, not just "junk vs.
-- curated PvP kit" -- per the project owner's own description, a real
-- survival world's chests are a big mix: some empty-feeling junk, some
-- plain materials, some food, some a handful of valuables, some actual
-- weapon/armor gear, only a minority as generous as default_stash's full
-- kit. Weights are a starting point, easy to retune from played
-- experience.
-- Reweighted 2026-09-18 (owner, direct and emphatic feedback): "These
-- were some of the best Minecraft players in all of history and had
-- access to the highest levels of everything, far beyond even Oysterity
-- truly and factually... mostly players don't keep iron armor, very
-- rarely. mostly they don't keep much gold... Unenchanted diamond is
-- mostly trash at this level as well... There should be more random
-- items and everything should be more likely to be much more full."
-- This is specifically about THESE chests (real base loot) -- "for
-- chests outside of these builds perhaps it's ok to use normal loot
-- tables but not for these chests" -- so this pool (and structures.lua's
-- separate vanilla-structure loot tables) stay untouched on purpose.
local FALLBACK_POOL = {
	{ key = "random_items", weight = 10 },
	{ key = "materials", weight = 10 },
	{ key = "food", weight = 8 },
	{ key = "gardening", weight = 5 },
	{ key = "potions", weight = 6 },
	{ key = "valuables", weight = 20 },
	-- Owner explicit 2026-09-18 round 5: "Redstone and Utilities" and
	-- "Mob Drops and Farming" are core chest categories real survival
	-- chests should have. Both themes (redstone/misc) already existed
	-- with real content but were only reachable via an explicit sign
	-- match (THEME_RULES) -- never in this general unlabeled-container
	-- roll -- so they essentially never appeared in practice. Added here
	-- at a modest weight alongside the other bulk-loot categories.
	{ key = "redstone", weight = 8 },
	{ key = "misc", weight = 8 },
	-- Round 21 (owner explicit, escalating live report -- the 4th time
	-- this was reported): "it should never have iron anything" means
	-- never, not rare -- a nonzero weight here (previously cut to 2, from
	-- an earlier round's "cut hard again") still produced real iron gear
	-- chests the owner kept finding. gear_iron is fully removed from this
	-- pool now, not just deprioritized -- see GEAR_THEME_MATERIAL's own
	-- comment for the rest of the elimination (the THEME_RULES sign-match
	-- above no longer routes here either).
	{ key = "gear_gold", weight = 2 },
	{ key = "gear_netherite", weight = 14 },
	-- Kit shulkers are "pretty common" per the project owner, but this is
	-- the UNLABELED-container roll -- most kits should come from actual
	-- "kit"/"loadout" signs (see THEME_RULES above); this just means an
	-- unlabeled chest occasionally turns out to hold one anyway.
	{ key = "pvp_kit", weight = 14 },
	-- Genuinely empty -- still real (per the project owner: "some should
	-- be empty, some should be totally full"), but cut down -- most
	-- chests in a real top-tier stash should read as stocked.
	{ key = "empty", weight = 4 },
	{ key = "default_stash", weight = 20 },
}
local FALLBACK_TOTAL = 0
for _, e in ipairs(FALLBACK_POOL) do FALLBACK_TOTAL = FALLBACK_TOTAL + e.weight end

local function classify(text_blob, pos)
	text_blob = (text_blob or ""):lower()
	for _, rule in ipairs(THEME_RULES) do
		for _, kw in ipairs(rule.match) do
			if text_blob:find(kw, 1, true) then return rule.key end
		end
	end
	if pos then
		local pr = PcgRandom(math.abs(pos.x * 65599 + pos.y * 8161 + pos.z * 19661 + 104729) % 2 ^ 31)
		local roll = pr:next(1, FALLBACK_TOTAL)
		local acc = 0
		for _, e in ipairs(FALLBACK_POOL) do
			acc = acc + e.weight
			if roll <= acc then return e.key end
		end
	end
	return "default_stash"
end

-- ---------------------------------------------------------------------
-- Stage 1 -- gather every container in this base, with nearby sign text.
-- ---------------------------------------------------------------------
-- Reads the destination world via a single VoxelManip over the placed
-- base's bbox, then walks the slice to find container nodes. For each
-- container, finds signs within SIGN_RADIUS blocks (default 6, per spec).
--
-- Returns a list of container records:
--   { pos={x,y,z}, kind="chest"|"barrel"|"shulker_box"|..., theme_key=...,
--     nearby_signs={"...", "..."}, has_text=true|false }

local SIGN_RADIUS = 6

-- Mineclonia's *internal* shulker-box color codes (mods/ITEMS/mcl_chests/
-- init.lua's `boxtypes` table) -- these do NOT all match Minecraft's color
-- names (light_blue -> lightblue, gray -> dark_grey, light_gray -> grey,
-- purple -> violet, lime -> green, green -> dark_green). Using the
-- Minecraft-spelled names here silently missed 6 of 16 colors.
local SHULKER_MCL_COLORS = {
	"white", "orange", "magenta", "lightblue", "yellow", "green", "pink",
	"dark_grey", "grey", "cyan", "violet", "blue", "brown", "dark_green",
	"red", "black",
}

-- All containers we know how to fill. Names should match the Mineclonia
-- node names as registered by mcl_chests / mcl_chests / etc. Filled
-- containers use the standard "main" 1D list (27 slots for chest/barrel).
-- "chest"/"trapped_chest"/"ender_chest" are placeholder names: spawnimport's
-- needs_construct repair pass (see mods/spawnimport/init.lua) calls
-- on_construct on every one of these right after placement, which swaps
-- each to "_small" (single) or "_left"/"_right" (the two halves of a
-- double chest) via mcl_chests' own on_construct -- see mcl_chests/init.lua
-- register_chest(). By the time this mod scans, essentially none of the
-- placed containers are still named the bare placeholder; matching only
-- that name (as an earlier version of this file did) silently missed
-- nearly every chest/trapped_chest/ender_chest in a base.
local CHEST_BASENAMES = { "chest", "trapped_chest", "ender_chest" }
local CONTAINER_KINDS = {
	["mcl_barrels:barrel_closed"] = "barrel",
}
for _, base in ipairs(CHEST_BASENAMES) do
	for _, suffix in ipairs({ "_small", "_left", "_right" }) do
		CONTAINER_KINDS["mcl_chests:" .. base .. suffix] = base
	end
end
for _, color in ipairs(SHULKER_MCL_COLORS) do
	CONTAINER_KINDS["mcl_chests:" .. color .. "_shulker_box_small"] = "shulker_box"
end

-- The placeholder "_shulker_box" (non-"_small") nodes that a VoxelManip
-- import leaves behind -- see lua_import/palette.lua's fix. These have no
-- on_rightclick at all (only the engine's on_construct callback, which
-- VoxelManip never fires, swaps them to "_small"). Repaired in place
-- before the container scan below, so old imports self-heal on the next
-- loot pass without needing a separate migration step.
local SHULKER_BIG_TO_SMALL = {}
for _, color in ipairs(SHULKER_MCL_COLORS) do
	SHULKER_BIG_TO_SMALL["mcl_chests:" .. color .. "_shulker_box"] = "mcl_chests:" .. color .. "_shulker_box_small"
end

-- The shulker dialog is a node-meta formspec ("list[context;main;...]")
-- that mcl_chests sets in after_place_node or its formspec LBM. Neither
-- fires for a VoxelManip import + core.swap_node, so imported shulkers end
-- up with NO formspec -- right-click animates them open but the dialog
-- never shows, and further right-clicks do nothing (owner report). This
-- replicates mcl_chests/init.lua's formspec_shulker_box, INCLUDING the
-- slot-background grid (mcl_formspec.get_itemslot_bg_v4) -- an earlier
-- minimal version without those backgrounds opened the inventory but the
-- 9x3 slot grid did not render (owner report: "items load but the grid
-- does not").
local function shulker_formspec()
	local bg = (mcl_formspec and mcl_formspec.get_itemslot_bg_v4) or function() return "" end
	return table.concat({
		"formspec_version[4]",
		"size[11.75,10.425]",
		bg(0.375, 0.75, 9, 3),
		"list[context;main;0.375,0.75;9,3;]",
		bg(0.375, 5.1, 9, 3),
		"list[current_player;main;0.375,5.1;9,3;9]",
		bg(0.375, 9.05, 9, 1),
		"list[current_player;main;0.375,9.05;9,1;]",
		"listring[context;main]",
		"listring[current_player;main]",
	})
end

local SIGN_KINDS = {
	["mcl_signs:standing_sign_oak"] = true,
	["mcl_signs:wall_sign_oak"] = true,
	["mcl_signs:standing_sign_spruce"] = true,
	["mcl_signs:wall_sign_spruce"] = true,
	["mcl_signs:standing_sign_birch"] = true,
	["mcl_signs:wall_sign_birch"] = true,
	["mcl_signs:standing_sign_jungle"] = true,
	["mcl_signs:wall_sign_jungle"] = true,
	["mcl_signs:standing_sign_acacia"] = true,
	["mcl_signs:wall_sign_acacia"] = true,
	["mcl_signs:standing_sign_dark_oak"] = true,
	["mcl_signs:wall_sign_dark_oak"] = true,
	["mcl_signs:standing_sign_mangrove"] = true,
	["mcl_signs:wall_sign_mangrove"] = true,
	["mcl_signs:standing_sign_cherry"] = true,
	["mcl_signs:wall_sign_cherry"] = true,
	["mcl_signs:standing_sign_pale_oak"] = true,
	["mcl_signs:wall_sign_pale_oak"] = true,
	["mcl_signs:standing_sign_bamboo"] = true,
	["mcl_signs:wall_sign_bamboo"] = true,
	["mcl_signs:standing_sign_crimson"] = true,
	["mcl_signs:wall_sign_crimson"] = true,
	["mcl_signs:standing_sign_warped"] = true,
	["mcl_signs:wall_sign_warped"] = true,
}

-- Array form for find_nodes_in_area (see the note above SHULKER_BIG_TO_SMALL
-- / container_names in discover_containers_for_base -- nodenames must be a
-- plain array, not a {name=true} lookup table).
local SIGN_NAMES = {}
for name in pairs(SIGN_KINDS) do SIGN_NAMES[#SIGN_NAMES + 1] = name end

local function read_sign_text(pos)
	local meta = core.get_meta(pos)
	local raw = meta:get_string("utext")
	if not raw or raw == "" then return "" end
	-- mineclonia signs store the text as a serialised ustring; we want
	-- to round-trip it to plain text for the keyword scan.
	if mcl_signs and mcl_signs.ustring_to_string then
		local ok, decoded = pcall(mcl_signs.ustring_to_string, core.deserialize(raw))
		if ok and type(decoded) == "string" then return decoded end
	end
	-- Fallback: try to extract text via core's formspec un-escape.
	return (raw:gsub("\27", "\n"))
end

-- Async: emerges each Y-tile before scanning it, then calls done_cb(containers).
--
-- core.get_node/core.find_nodes_in_area only see already-*active* map
-- blocks -- anything not currently loaded reads back as "ignore" (or, on a
-- fresh boot, sometimes "air" before any load has ever touched it),
-- regardless of what's actually saved on disk. A base placed minutes
-- earlier -- or in an earlier server run entirely, which is museumloot's
-- normal "run this as a standalone pass" use case -- is not active by the
-- time this scans it: nothing keeps a headless server's blocks loaded with
-- no player nearby (confirmed live: core.find_nodes_in_area over a base
-- known to contain 547 real chests returned zero, every time, until the
-- bbox was explicitly emerged first). core.emerge_area loads/generates the
-- requested volume and calls back once done; the callback fires on the
-- Emerge thread, so a core.after(0, ...) hop back onto the main step is
-- required before core.get_node/find_nodes_in_area reflect it (confirmed:
-- querying directly inside the emerge callback still read "ignore").
-- Only generic/catch-all themes roll for a novelty chest -- a narrowly
-- thematic one (gear_netherite, potions, food, redstone...) staying
-- on-theme reads as deliberate; a random flower chest in the middle of
-- an armory would not.
--
-- Hoisted up here from its original spot (just above THEMES, much
-- further down this file) 2026-09-19 (round 22, real crash found and
-- fixed): the double-chest pairing pass inside discover_containers_for_
-- base (below) needs to check this table when deciding force_novelty,
-- but that pass is DEFINED at this point in the file -- a Lua closure
-- only captures locals already in scope at its own definition site, not
-- ones declared later in the same chunk, even though by the time the
-- closure actually RUNS the whole file has finished loading. Left it
-- also referenced from THEMES' own novelty-roll branch further down,
-- unchanged -- this is the single source of truth for both.
local NOVELTY_ELIGIBLE_THEMES = {
	default_stash = true, random_items = true, materials = true,
	misc = true, valuables = true,
}

local function discover_containers_for_base(base, done_cb)
	-- Pull the destination-bbox metadata from the registry. We expect
	-- all container nodes within this bbox to be placed by spawnimport
	-- (no other mods are placing blocks in our bases).
	local placed = registry.find_by_name(base.name) or base
	local bbox = placed.bbox
	if not bbox or not bbox.x_min then
		core.log("warning", "[museumloot] base " .. base.name .. " has no bbox -- skipping loot pass")
		done_cb({})
		return
	end
	-- Trust the registry's placed bbox.y_min/y_max as-is: spawnimport
	-- fills these from the base's *actual placed* content, already
	-- including dest_y_offset. Clamping to an overworld-shaped band
	-- (e.g. -64..320) here would silently exclude every container in a
	-- Nether/End base, whose placed Y range sits in a completely
	-- different band (mcl_vars.mg_nether_*/mg_end_*) by design -- see
	-- mcl_worlds.pos_to_dimension. Only fall back to a wide default
	-- when the registry genuinely has no y bounds recorded.
	local MAX_Y = core.MAX_MAP_GENERATION_LIMIT or 31007
	local y_min = bbox.y_min or -MAX_Y
	local y_max = bbox.y_max or MAX_Y
	local x_min, x_max = bbox.x_min, bbox.x_max
	local z_min, z_max = bbox.z_min, bbox.z_max

	-- Both VoxelManip and core.find_nodes_in_area enforce a hard
	-- 150M-node volume limit per call. A 1024*465*800 base (like
	-- cutecurly) blows past that. Tile by Y: pick a Y-tile height
	-- that keeps each (x*z*y) under 140M.
	local xspan = x_max - x_min + 1
	local zspan = z_max - z_min + 1
	local max_tile_nodes = 140000000
	local y_tile = math.max(1, math.floor(max_tile_nodes / math.max(1, xspan * zspan)))
	core.log("action", string.format(
		"[museumloot] %s: bbox %dx%dx%d, y-tile=%d",
		base.name, xspan, (y_max - y_min + 1), zspan, y_tile))

	-- core.find_nodes_in_area's `nodenames` argument must be a plain
	-- array of strings ({"name1","name2"}), NOT a {name=value} lookup
	-- table -- passing a dict makes the engine see an empty nodenames
	-- list and match nothing, silently. This was the actual reason no
	-- containers were ever found in any base (independent of, and more
	-- fundamental than, the shulker "_small" naming bug below). Also:
	-- grouped=true returns {nodename = {positions...}}, not a flat
	-- array, so a plain ipairs() over that return value (as if
	-- grouped=false) silently visits nothing either. Use grouped=false
	-- and the array form throughout.
	local container_names = {}
	for name in pairs(CONTAINER_KINDS) do container_names[#container_names + 1] = name end
	local shulker_big_names = {}
	for name in pairs(SHULKER_BIG_TO_SMALL) do shulker_big_names[#shulker_big_names + 1] = name end

	-- Precompute the tile list up front (same math as before), then walk
	-- it asynchronously: emerge each tile, hop to the main step, repair +
	-- scan it, move to the next.
	local tiles = {}
	do
		local y = y_min
		while y <= y_max do
			local y1 = math.min(y_max, y + y_tile - 1)
			tiles[#tiles + 1] = { y = y, y1 = y1 }
			y = y1 + 1
		end
	end

	local containers = {}
	local shulkers_repaired = 0

	local function finish()
		if shulkers_repaired > 0 then
			core.log("action", string.format(
				"[museumloot] %s: repaired %d shulker box(es) stuck as non-interactive placeholders",
				base.name, shulkers_repaired))
		end

		if #containers == 0 then done_cb({}); return end

		-- For each container, gather sign text within SIGN_RADIUS. The
		-- whole bbox was just emerged tile-by-tile above, so no further
		-- emerge is needed here.
		for _, c in ipairs(containers) do
			local near_min = {
				x = math.max(x_min, c.pos.x - SIGN_RADIUS),
				y = math.max(y_min, c.pos.y - SIGN_RADIUS),
				z = math.max(z_min, c.pos.z - SIGN_RADIUS),
			}
			local near_max = {
				x = math.min(x_max, c.pos.x + SIGN_RADIUS),
				y = math.min(y_max, c.pos.y + SIGN_RADIUS),
				z = math.min(z_max, c.pos.z + SIGN_RADIUS),
			}
			local near_signs = core.find_nodes_in_area(near_min, near_max, SIGN_NAMES, false) or {}
			local blob = {}
			local r2 = SIGN_RADIUS * SIGN_RADIUS
			for _, sp in ipairs(near_signs) do
				local dx, dy, dz = sp.x - c.pos.x, sp.y - c.pos.y, sp.z - c.pos.z
				if dx*dx + dy*dy + dz*dz <= r2 then
					local text = read_sign_text(sp)
					if text and text ~= "" then
						blob[#blob + 1] = text
					end
				end
			end
			c.nearby_signs = blob
			c.nearby_signs_blob = table.concat(blob, " | ")

			-- Stage 1a (new): structure detection runs before the
			-- sign-keyword classifier. If the container sits inside a
			-- real Mineclonia-mapgen structure, skip classify() entirely
			-- and use that structure's own loot table -- see
			-- structures.lua for the detection heuristics and the
			-- hand-copied tables themselves.
			local match = structures.detect(c.pos, x_min, x_max, y_min, y_max, z_min, z_max, c.node)
			if match then
				c.theme_key = nil
				c.structure_match = match.structure
				c.structure_loot = match.loot_table
				c.structure_loot_use = match.use
			else
				c.structure_match = nil
				c.structure_loot = nil
				c.structure_loot_use = nil
				c.theme_key = classify(c.nearby_signs_blob, c.pos)

				-- Owner explicit 2026-09-18 (round 3): "75% of shulker boxes
				-- should be Kits" -- bumped from the earlier round-2 50%.
				-- A real vanilla-structure shulker (handled above, match ~=
				-- nil) is left alone; a "kit"/"loadout"-signed shulker
				-- already classified via THEME_RULES is left alone too
				-- (don't second-guess an explicit sign). Every other
				-- shulker box gets its own coin flip, seeded independently
				-- of the classify() roll above so it doesn't correlate
				-- with it.
				if c.kind == "shulker_box"
						and c.theme_key ~= "pvp_kit"
						and c.theme_key ~= "pvp_kit_closet" then
					local kit_pr = PcgRandom(math.abs(c.pos.x * 92821
						+ c.pos.y * 68917
						+ c.pos.z * 50331653
						+ 726484729) % 2 ^ 31)
					if kit_pr:next(1, 100) <= 75 then
						c.theme_key = (kit_pr:next(1, 100) <= 15)
							and "pvp_kit_closet" or "pvp_kit"
					end
				end
			end
		end

		-- Double chests: mcl_chests registers the two halves of a double
		-- chest as separate nodes with separate meta inventories, but the
		-- game visually merges them into one 54-slot formspec when a
		-- player opens either half. Classifying each half independently
		-- (as the loop above does) reads as broken once opened -- two
		-- unrelated loot types spliced into what looks like one chest.
		-- Confirmed live this session. Unify: a real "_left"/"_right"
		-- pair gets the SAME classification (the "_left" half's roll
		-- wins, picked arbitrarily but deterministically).
		--
		-- 2026-09-19 owner correction: this was still producing a
		-- double chest with kits on top and armor on bottom -- traced to
		-- the match condition above using a loose "within 2 blocks"
		-- radius (`dx*dx+dy*dy+dz*dz <= 4`) instead of real double-chest
		-- adjacency, and never checking that both halves are the same
		-- chest base type. In a dense storage room (a "wall of chests,"
		-- common in these bases) that radius can reach a same-column/
		-- different-row chest_right 2 blocks away that ISN'T this
		-- chest_left's actual visual partner, "claiming" it (the `break`
		-- stops at the first match in range) and leaving the TRUE
		-- partner unpaired -- exactly the top/bottom mismatch reported.
		-- Also, "left"/"right" is relative to the chest's OWN facing
		-- (param2), not a fixed compass direction -- a simple distance
		-- check can't get this right in general. Real fix: use
		-- mcl_util.get_double_container_neighbor_pos(pos, param2, side),
		-- the exact same function mcl_chests' own trapped-chest-swap
		-- code (mods/ITEMS/mcl_chests/init.lua) uses to find a real
		-- double chest's other half, instead of guessing geometrically.
		--
		-- 2026-09-19 owner correction (round 19, still seeing L/R
		-- mismatches after the round-16 "fix" above): the `side`
		-- argument was backwards. Confirmed against mcl_chests' own real
		-- caller (its trapped-chest-swap code converts `pos` itself to
		-- "..._left" and THEN calls this function with side="left" to
		-- find where the RIGHT partner goes) -- `side` names the
		-- CURRENT node's own role, and the function returns the OTHER
		-- side's position. This was calling side="right" on a node that
		-- IS "_left", asking "where would a right-flavored version of ME
		-- sit" instead of "where is MY right partner" -- for param2=3 that
		-- computed z-1, when a live-checked real pair's right half was
		-- actually at z+1 (confirmed directly against real placed data,
		-- not guessed). Fixed: pass "left" (a's own real role).
		local function chest_base(node) return node and (node:match("^(.-)_left$") or node:match("^(.-)_right$")) end
		for _, a in ipairs(containers) do
			if a.node and a.node:match("_left$") and not a._paired and a.param2 then
				local want = mcl_util.get_double_container_neighbor_pos(a.pos, a.param2, "left")
				if want then
					for _, b in ipairs(containers) do
						if b ~= a and not b._paired and b.node and b.node:match("_right$")
								and chest_base(a.node) == chest_base(b.node)
								and b.pos.x == want.x and b.pos.y == want.y and b.pos.z == want.z then
							-- Round 24 (owner live report): "two stacks of
							-- spider eyes both less than 64... usually
							-- players will stack items together" -- syncing
							-- theme_key alone isn't enough. Each half still
							-- rolls and merge_and_quantize_loot()s its OWN
							-- 27 slots independently, so the SAME item can
							-- legitimately land as a separate stack on each
							-- side -- correct per-half, but reads as
							-- "duplicate small stacks" once the game merges
							-- both halves into one 54-slot view. `pair_other`
							-- lets the fill pass (below) combine both
							-- halves' rolls into one 54-slot pool before
							-- merging, so the same item that lands on both
							-- sides becomes one real stack (split across
							-- the 54 slots by quantity, not duplicated).
							a.pair_other = b
							b.pair_other = a
							b.theme_key = a.theme_key
							b.structure_match = a.structure_match
							b.structure_loot = a.structure_loot
							b.structure_loot_use = a.structure_loot_use
							-- Round 21: decide the novelty roll ONCE for the
							-- pair (seeded off the "_left" half's own
							-- position, same formula fill_inv_from_theme
							-- itself would use) and force both halves to
							-- agree -- see force_novelty's own comment at
							-- its point of use for what this fixes.
							if NOVELTY_ELIGIBLE_THEMES[a.theme_key] then
								local novelty_pr = PcgRandom(math.abs(a.pos.x * 73856093
									+ a.pos.y * 19349663
									+ a.pos.z * 83492791
									+ (a.theme_key ~= "" and string.find(a.theme_key, "%w") * 2654435761 or 0)
								) % 2^31)
								local decided = novelty_pr:next(1, 100) <= 8
								a.force_novelty = decided
								b.force_novelty = decided
							end
							a._paired = true
							b._paired = true
							break
						end
					end
				end
			end
		end

		done_cb(containers)
	end

	local i = 0
	local function next_tile()
		i = i + 1
		local t = tiles[i]
		if not t then finish(); return end
		local emin = { x = x_min, y = t.y, z = z_min }
		local emax = { x = x_max, y = t.y1, z = z_max }
		core.emerge_area(emin, emax, function(_, _, calls_remaining)
			if calls_remaining > 0 then return end
			core.after(0, function()
				-- Repair pass: any surviving big-variant shulker placeholder
				-- in this tile gets swapped to "_small" in place (preserving
				-- param2, i.e. facing) before the container scan below, so
				-- it's both found by find_nodes_in_area(container_names) and
				-- openable in-game. core.swap_node deliberately skips
				-- on_construct/on_destruct -- we don't want either (no
				-- inventory to lose yet, no drop-as-item behavior);
				-- find_or_create_entity in mcl_chests lazily creates the
				-- visual entity on first right-click regardless.
				local big_positions = core.find_nodes_in_area(emin, emax, shulker_big_names, false) or {}
				for _, pos in ipairs(big_positions) do
					local node = core.get_node(pos)
					local small_name = SHULKER_BIG_TO_SMALL[node.name]
					if small_name then
						core.swap_node(pos, { name = small_name, param2 = node.param2 })
					end
				end

				-- Formspec fix for every shulker box (both the big->small
				-- swaps above and the "_small" boxes the current palette
				-- places directly). A VoxelManip import never runs
				-- mcl_chests' after_place_node / formspec LBM, so these
				-- have no meta formspec and right-click animates them open
				-- with no dialog. Set it + ensure the 27-slot inventory.
				local shulker_positions = core.find_nodes_in_area(emin, emax, { "group:shulker_box" }, false) or {}
				for _, pos in ipairs(shulker_positions) do
					local smeta = core.get_meta(pos)
					if smeta:get_string("formspec") == "" then
						local sinv = smeta:get_inventory()
						if sinv:get_size("main") == 0 then
							sinv:set_size("main", 27)
						end
						smeta:set_string("formspec", shulker_formspec())
						shulkers_repaired = shulkers_repaired + 1
					end
				end

				local positions = core.find_nodes_in_area(emin, emax, container_names, false) or {}
				for _, pos in ipairs(positions) do
					local node = core.get_node(pos)
					containers[#containers + 1] = {
						pos = { x = pos.x, y = pos.y, z = pos.z },
						node = node.name,
						kind = CONTAINER_KINDS[node.name],
						param2 = node.param2,
					}
				end
				next_tile()
			end)
		end)
	end
	next_tile()
end

-- ---------------------------------------------------------------------
-- Stage 3 -- apply: deterministically fill containers with loot.
-- ---------------------------------------------------------------------
-- Seeded PcgRandom from container position hash. Re-running the pass on
-- the same world yields identical contents. The pass is also idempotent:
-- containers already holding items are skipped.

-- 2026-09-19 owner explicit, live screenshots: chests were reading as
-- "9 stacks of coal: 2, 3, 5, 7... nobody would keep small sets like
-- that" -- mcl_loot.get_multi_loot() rolls each "stack" independently
-- with no awareness of what earlier rolls in the same container already
-- picked (see mods/CORE/mcl_loot/init.lua's get_loot/get_multi_loot,
-- read above), so the same item name could easily get rolled 3-4 times
-- across different calls, each its own small amount_min..amount_max
-- count, landing in separate slots instead of one real stack. Real
-- fix: after accumulating every roll for a container, merge same-item
-- stacks into one real total, then re-split that total into full
-- (stack_max-sized) slots -- one item type reads as "one big stack (or
-- a few full 64-stacks if there's a lot of it)," matching how a real
-- player actually keeps a chest, not "the same item scattered across
-- several near-empty slots." Keys off ItemStack:to_string() with the
-- count zeroed out, so this only merges stacks that are ACTUALLY
-- identical (same enchantments/custom name/wear) -- two differently
-- enchanted swords from two different rolls correctly stay separate,
-- they're not the same item.
-- Splash/lingering potions register stack_max=1 (mods/ITEMS/mcl_potions/
-- potions.lua), but ItemStack:set_count() doesn't clamp to it (confirmed
-- live, pvpkits.lua's make_potion_splash("swiftness", 64, ...) round-
-- trips correctly) -- max_potent() above relies on this to build real
-- 64-count potion stacks. Without this override, re-splitting by the
-- REGISTERED max here would silently shatter a func-forced 64-count
-- stack back into 64 separate 1-count slots, undoing max_potent entirely.
local function effective_stack_max(proto)
	local max = proto:get_stack_max()
	if max <= 1 and proto:get_name():find("^mcl_potions:") then
		return 64
	end
	if max < 1 then max = 1 end
	return max
end

local function merge_and_quantize_loot(items)
	local totals, order = {}, {}
	for _, stack in ipairs(items) do
		if stack and not stack:is_empty() then
			local proto = ItemStack(stack)
			local count = proto:get_count()
			proto:set_count(1)
			local key = proto:to_string()
			if not totals[key] then
				totals[key] = { proto = proto, sum = 0 }
				order[#order + 1] = key
			end
			totals[key].sum = totals[key].sum + count
		end
	end
	local merged = {}
	for _, key in ipairs(order) do
		local t = totals[key]
		local max = effective_stack_max(t.proto)
		local remaining = t.sum
		while remaining > 0 do
			local take = math.min(remaining, max)
			local out = ItemStack(t.proto)
			out:set_count(take)
			merged[#merged + 1] = out
			remaining = remaining - take
		end
	end
	return merged
end

-- 2026-09-19 owner explicit: "please open the block palette for
-- mineclonia and place in a MUCH larger set of possible blocks... a
-- chest full of flowers, all the types... all the rainbow colors of
-- dye... a chest full of seeds." Real registered names only (grepped
-- directly out of mods/ITEMS/mcl_flowers/register.lua's
-- register_simple_flower() calls, mcl_dyes/init.lua's mcl_dyes.colors
-- keys, and mcl_farming's *_seeds/*_item craftitem registrations --
-- never guessed, per this project's own standing rule). Same
-- repeated-full-stacks-of-a-category pattern as pvpkits.lua's
-- kit_mineral.
local NOVELTY_ITEM_SETS = {
	flowers = {
		"mcl_flowers:poppy", "mcl_flowers:dandelion", "mcl_flowers:oxeye_daisy",
		"mcl_flowers:tulip_orange", "mcl_flowers:tulip_pink", "mcl_flowers:tulip_red",
		"mcl_flowers:tulip_white", "mcl_flowers:allium", "mcl_flowers:azure_bluet",
		"mcl_flowers:blue_orchid", "mcl_flowers:wither_rose",
		"mcl_flowers:lily_of_the_valley", "mcl_flowers:cornflower",
	},
	dyes = {
		"mcl_dyes:white", "mcl_dyes:silver", "mcl_dyes:grey", "mcl_dyes:black",
		"mcl_dyes:purple", "mcl_dyes:blue", "mcl_dyes:light_blue", "mcl_dyes:cyan",
		"mcl_dyes:green", "mcl_dyes:lime", "mcl_dyes:yellow", "mcl_dyes:brown",
		"mcl_dyes:orange", "mcl_dyes:red", "mcl_dyes:magenta", "mcl_dyes:pink",
	},
	seeds = {
		"mcl_farming:wheat_seeds", "mcl_farming:melon_seeds",
		"mcl_farming:pumpkin_seeds", "mcl_farming:beetroot_seeds",
		"mcl_farming:carrot_item", "mcl_farming:potato_item",
	},
	wool = {
		"mcl_wool:white", "mcl_wool:silver", "mcl_wool:grey", "mcl_wool:black",
		"mcl_wool:purple", "mcl_wool:blue", "mcl_wool:light_blue", "mcl_wool:cyan",
		"mcl_wool:green", "mcl_wool:lime", "mcl_wool:yellow", "mcl_wool:brown",
		"mcl_wool:orange", "mcl_wool:red", "mcl_wool:magenta", "mcl_wool:pink",
	},
	concrete = {
		"mcl_colorblocks:concrete_white", "mcl_colorblocks:concrete_silver",
		"mcl_colorblocks:concrete_grey", "mcl_colorblocks:concrete_black",
		"mcl_colorblocks:concrete_purple", "mcl_colorblocks:concrete_blue",
		"mcl_colorblocks:concrete_light_blue", "mcl_colorblocks:concrete_cyan",
		"mcl_colorblocks:concrete_green", "mcl_colorblocks:concrete_lime",
		"mcl_colorblocks:concrete_yellow", "mcl_colorblocks:concrete_brown",
		"mcl_colorblocks:concrete_orange", "mcl_colorblocks:concrete_red",
		"mcl_colorblocks:concrete_magenta", "mcl_colorblocks:concrete_pink",
	},
	-- 2026-09-19 owner explicit (round 19): "there should be more chest
	-- types. for example a chest with every type of log at 64 stacks."
	-- Real 8 wood species this project's own data.lua already uses
	-- (lua_import/data.lua's wood_species list, the same set palette.lua
	-- generates every per-species door/stair/sign/button name from) --
	-- registered via mods/ITEMS/mcl_trees/api.lua's
	-- register_wood(name, ...) -> "mcl_trees:tree_"..name, confirmed
	-- directly for "dark_oak" (used verbatim elsewhere in that same
	-- file) and already relied on for "oak" by this project's own
	-- existing `materials`/`building` themes.
	logs = {
		"mcl_trees:tree_oak", "mcl_trees:tree_spruce", "mcl_trees:tree_birch",
		"mcl_trees:tree_jungle", "mcl_trees:tree_acacia", "mcl_trees:tree_dark_oak",
		-- "cherry", not "cherry_blossom", is data.lua's own
		-- wood_species entry, but the REAL registered node uses the
		-- mod's own internal key instead (mods/ITEMS/mcl_cherry_
		-- blossom/init.lua: `mcl_trees.register_wood("cherry_blossom",
		-- ...)`) -- caught live via direct core.registered_nodes check,
		-- not guessed a second time.
		"mcl_trees:tree_mangrove", "mcl_trees:tree_cherry_blossom",
	},
	-- Round 24 (owner explicit): "a lot lot more variety of block chests
	-- which spawn. for example a chest of every type of stairs. a chest
	-- of every type of wall block. a chest of every nether block in full
	-- stacks." All three lists below verified directly against real
	-- `core.register_node(...)` calls in the actual mod source (mods/
	-- ITEMS/mcl_stairs, mcl_walls, mcl_nether, mcl_blackstone) -- not
	-- guessed, per this project's own standing rule (violated and caught
	-- twice already this session for wood-species names alone).
	--
	-- Wood-species stairs deliberately left out of `stairs` -- the real
	-- node name pattern (`mcl_stairs:stair_<name>`, confirmed from mods/
	-- ITEMS/mcl_stairs/api.lua) is verified, but whether each `<name>`
	-- matches data.lua's own wood_species keys exactly (the exact class
	-- of mistake already caught once this session, for "cherry" vs the
	-- real "cherry_blossom") wasn't independently re-verified against a
	-- live `core.registered_nodes` check this round -- only the
	-- stone-family stairs below were. Stone-family names all confirmed
	-- via direct grep of mods/ITEMS/mcl_core/nodes_stairs.lua's real
	-- `mcl_stairs.register_stair_and_slab("<name>", ...)` calls.
	stairs = {
		"mcl_stairs:stair_stone_rough", "mcl_stairs:stair_andesite",
		"mcl_stairs:stair_granite", "mcl_stairs:stair_diorite",
		"mcl_stairs:stair_cobble", "mcl_stairs:stair_mossycobble",
		"mcl_stairs:stair_brick_block", "mcl_stairs:stair_sandstone",
		"mcl_stairs:stair_redsandstone", "mcl_stairs:stair_stonebrick",
	},
	-- Verified via direct grep of mods/ITEMS/mcl_walls/register.lua's
	-- real `mcl_walls.register_wall_def("mcl_walls:<name>", ...)` calls
	-- -- all 15 real registered wall types, none guessed.
	walls = {
		"mcl_walls:andesite", "mcl_walls:brick", "mcl_walls:cobble",
		"mcl_walls:diorite", "mcl_walls:endbricks", "mcl_walls:granite",
		"mcl_walls:mossycobble", "mcl_walls:mudbrick", "mcl_walls:netherbrick",
		"mcl_walls:prismarine", "mcl_walls:rednetherbrick",
		"mcl_walls:redsandstone", "mcl_walls:sandstone",
		"mcl_walls:stonebrick", "mcl_walls:stonebrickmossy",
	},
	-- Verified via direct grep of mods/ITEMS/mcl_nether/init.lua and
	-- mcl_blackstone/init.lua's real `core.register_node("mcl_nether:
	-- <name>", ...)`/`"mcl_blackstone:<name>"` calls. "soul_fire" left
	-- out -- it's fire, not a solid stackable block, unlike everything
	-- else here.
	nether = {
		"mcl_nether:glowstone", "mcl_nether:quartz_ore", "mcl_nether:ancient_debris",
		"mcl_nether:netheriteblock", "mcl_nether:netherrack", "mcl_nether:magma",
		"mcl_nether:soul_sand", "mcl_nether:nether_brick", "mcl_nether:red_nether_brick",
		"mcl_nether:chiseled_nether_brick", "mcl_nether:cracked_nether_brick",
		"mcl_nether:nether_wart_block", "mcl_nether:quartz_block",
		"mcl_nether:quartz_chiseled", "mcl_nether:quartz_pillar", "mcl_nether:quartz_smooth",
		"mcl_blackstone:basalt", "mcl_blackstone:basalt_polished", "mcl_blackstone:basalt_smooth",
		"mcl_blackstone:blackstone", "mcl_blackstone:blackstone_polished",
		"mcl_blackstone:blackstone_brick_polished", "mcl_blackstone:blackstone_brick_polished_cracked",
		"mcl_blackstone:blackstone_chiseled_polished", "mcl_blackstone:blackstone_gilded",
		"mcl_blackstone:nether_gold", "mcl_blackstone:quartz_brick", "mcl_blackstone:soul_soil",
	},
}
local NOVELTY_KEYS = { "flowers", "dyes", "seeds", "wool", "concrete", "logs", "stairs", "walls", "nether" }
-- NOVELTY_ELIGIBLE_THEMES moved up above discover_containers_for_base
-- (round 22) -- see its own comment there for why.
local function build_novelty_items(inv_size, pr)
	local pool = NOVELTY_ITEM_SETS[NOVELTY_KEYS[pr:next(1, #NOVELTY_KEYS)]]
	local items = {}
	for i = 1, inv_size do
		items[i] = ItemStack(pool[((i - 1) % #pool) + 1] .. " 64")
	end
	return items
end

-- theme_key/structure_loot are mutually exclusive per container (see the
-- structures.detect() call site in discover_containers_for_base): when a
-- container matched a vanilla structure, structure_loot is the hand-copied
-- Mineclonia loot table from structures.lua and structure_loot_use says
-- whether it's a single pool ("get_loot") or an array of pools
-- ("get_multi_loot") -- see that file's per-table comments. Otherwise we
-- fall back to the existing THEMES[theme_key] path, unchanged.
local function fill_inv_from_theme(pos, kind, theme_key, nearby_signs_blob, structure_loot, structure_loot_use, structure_match, force_novelty, pair_pos)
	-- Use a position-seeded RNG so reruns are deterministic. The extra
	-- term folds in either the theme_key or the structure name so two
	-- containers at hashably-similar positions with different
	-- classifications don't roll identically.
	local seed_label = structure_loot and structure_match or theme_key
	local pr = PcgRandom(math.abs(pos.x * 73856093
		+ pos.y * 19349663
		+ pos.z * 83492791
		+ (seed_label and seed_label ~= "" and string.find(seed_label, "%w") * 2654435761 or 0)
	) % 2^31)

	if theme_key == "empty" then
		-- Deliberately leave it empty. is_empty("main") stays true, which
		-- also means a later re-run (or a manual restock) can still fill
		-- it -- "empty" isn't a permanent marker, just this roll's result.
		return
	end

	-- Owner explicit 2026-09-18 round 5 (a live playtest of the round-4
	-- deploy): "NONE of the chests are full and this was one the CORE
	-- requirements... Boxes should be FULL most of the Time with their
	-- equivalent item set, only say 20% would not be real stacks." The
	-- round-3/4 "staged jackpot" (55%/55%/35% chance of ONE extra
	-- get_multi_loot roll each) was still not reliably reaching a truly
	-- full container -- each roll only adds a theme's own small
	-- stacks_min/stacks_max batch (see e.g. gear_gold's own `stacks_min =
	-- 5, stacks_max = 8`), so even three extra rolls often landed well
	-- short of 27 real slots. Needed inv_size up front now so every
	-- branch below can target it directly instead of guessing.
	local inv_size = core.get_meta(pos):get_inventory():get_size("main")
	if inv_size <= 0 then inv_size = 27 end
	local own_inv_size = inv_size
	-- Round 24: for a paired double chest, roll against the COMBINED
	-- 54-slot pool (both halves together) instead of this half's own 27
	-- -- see pair_other's own comment (double-chest pairing pass above)
	-- for why: rolling each half independently let the same item land as
	-- a separate small stack on each side, reading as "duplicate stacks"
	-- once the game shows both halves merged. The split back into each
	-- half's real 27 slots happens at the very end, after merge_and_
	-- quantize_loot has already turned the combined pool into real
	-- stacks.
	if pair_pos then
		local other_size = core.get_meta(pair_pos):get_inventory():get_size("main")
		if other_size <= 0 then other_size = 27 end
		inv_size = own_inv_size + other_size
	end

	local all_items
	if theme_key == "pvp_kit" then
		if kind == "shulker_box" then
			-- Owner explicit 2026-09-18 round 4: "all of these shulker
			-- boxes on the ground contain other kits... I would expect
			-- most of these to be kits as in HAVING the contents of a
			-- kit. I.e. the same contents as a kit found in a chest."
			-- A ground shulker box IS the kit now -- its own 27 slots get
			-- the kit's raw contents directly (already a full, non-sparse
			-- set thanks to fill_to_27) instead of nesting 1-3 separate
			-- kit-shulker items inside it. The rarer "shulker full of
			-- OTHER kit shulkers" look is exactly what pvp_kit_closet
			-- (below) already is, and the 85/15 pvp_kit/pvp_kit_closet
			-- split above already routes some ground shulkers there.
			all_items = pvpkits.build_random_kit_items(pos, pr)
		else
			-- Non-shulker containers (chest/barrel) holding kit shulkers
			-- as loot. Owner explicit 2026-09-18 round 5: "At tactical
			-- base I found a shulker with shulkers in it, but it's not
			-- FULL it should be 100% full." Now always fills every slot
			-- (build_closet(pos, pr, inv_size)) instead of the old
			-- 5-9-item default.
			all_items = pvpkits.build_closet(pos, pr, inv_size)
		end
	elseif theme_key == "pvp_kit_closet" then
		-- "A base might have an entire double chest full of them" --
		-- owner explicit round 5: this must be 100% full, never partial.
		all_items = pvpkits.build_closet(pos, pr, inv_size)
	elseif GEAR_THEME_MATERIAL[theme_key] then
		-- 2026-09-19 round 14: dominant-weapon-type gear chest, see
		-- build_dominant_gear_items's own header comment above THEMES.
		all_items = build_dominant_gear_items(GEAR_THEME_MATERIAL[theme_key], inv_size, pr)
	elseif structure_loot then
		if structure_loot_use == "get_loot" then
			all_items = mcl_loot.get_loot(structure_loot, pr)
		else
			all_items = mcl_loot.get_multi_loot(structure_loot, pr)
		end
	elseif NOVELTY_ELIGIBLE_THEMES[theme_key] and
			(force_novelty ~= nil and force_novelty or (force_novelty == nil and pr:next(1, 100) <= 8)) then
		-- Owner explicit 2026-09-19: sometimes a whole chest should be
		-- one novelty category (all flowers, all dye colors, all
		-- seeds), each a real full 64-stack.
		--
		-- Round 21 (owner live report, real double-chest L/R content
		-- verified this round): this roll used to run independently per
		-- HALF of a double chest (each half has its own position-seeded
		-- `pr`, so the SAME synced theme_key could still roll novelty on
		-- one side and not the other -- confirmed live: a real pair had
		-- all-concrete on one side and mob-drop misc items on the
		-- other). `force_novelty` (nil = no override, decided once per
		-- pair and passed down by the double-chest pairing pass below)
		-- makes both halves agree.
		all_items = build_novelty_items(inv_size, pr)
	else
		-- Owner explicit round 5: "Boxes should be FULL most of the
		-- Time with their equivalent item set... only say 20% would not
		-- be real stacks." Owner explicit round 7 (live report, "a HUGE
		-- NUMBER of chests have very very little in them averaging 2-5
		-- items"): bumped the full-chance to 90% and the partial case to
		-- 3 rolls total. Owner explicit round 13 (2026-09-19, live
		-- screenshots): even after that fix, chests still read as "many
		-- separate small stacks of the same item (2, 3, 5, 7...)" --
		-- get_multi_loot rolls each stack independently with no memory
		-- of earlier rolls in the same container, so the same item
		-- picked 3-4 times across different rolls landed in 3-4
		-- separate near-empty slots instead of merging into one real
		-- stack. Now rolls repeatedly (checking the MERGED count, not
		-- the raw roll count, against inv_size) and always finishes with
		-- merge_and_quantize_loot() -- one real total per item, re-split
		-- into full stack_max-sized slots. A "full" container keeps
		-- rolling (guard raised 12->24, since merging shrinks the
		-- apparent count relative to before and needs more raw rolls to
		-- reach the same number of real distinct-item slots) until the
		-- merged result actually fills inv_size or the guard trips; the
		-- 10% "partial" case stays at a fixed 3 rolls (still merged, so
		-- even a partial chest no longer has scattered duplicate small
		-- stacks, just fewer distinct items).
		local theme = THEMES[theme_key] or THEMES.default_stash
		local want_full = pr:next(1, 100) <= 90
		local raw_items = {}
		local max_rolls = want_full and 24 or 3
		for _ = 1, max_rolls do
			local extra = mcl_loot.get_multi_loot(theme, pr)
			for _, it in ipairs(extra) do raw_items[#raw_items + 1] = it end
			if want_full and #merge_and_quantize_loot(raw_items) >= inv_size then break end
		end
		all_items = merge_and_quantize_loot(raw_items)
	end

	-- Some shulker boxes want only one item, others want 4-5. We don't
	-- pre-sort by kind here -- the shuffle of get_multi_loot's picks is
	-- already deterministic per (pos, theme).

	-- Round 21 (owner live report): "these bottles are still not
	-- swiftness ii" -- the max_potent() upgrade only ever ran inside the
	-- dedicated `potions` THEME (harming/healing/swiftness/poison_
	-- lingering, see its own item() calls above). Real structure loot
	-- (dungeon/mineshaft/end_city chests, routed above via `structure_
	-- loot` straight into mcl_loot.get_loot/get_multi_loot) and PVP kit
	-- filler potions never went through it at all -- a dungeon chest's
	-- native vanilla-style swiftness splash never got upgraded. Applied
	-- here instead, universally, on every finished all_items list
	-- regardless of which branch above produced it -- one choke point
	-- everything funnels through before hitting the real inventory.
	for _, stack in ipairs(all_items) do
		if stack and not stack:is_empty() then
			local name = stack:get_name()
			if name:find("^mcl_potions:") and (name:find("_splash$") or name:find("_lingering$")) then
				stack:get_meta():set_int("mcl_potions:potion_potent", 1)
				stack:set_count(64)
				-- Round 24 (owner live report, again: "splash potions of
				-- swiftness are still swiftness 1 instead of swiftness 2"):
				-- the underlying meta WAS already being set correctly here
				-- (confirmed) -- the actual bug is that the tooltip text
				-- itself is only computed once, at item-creation time, and
				-- cached in a SEPARATE meta field ("description") --
				-- mcl_potions.filter_potion_description (mods/ITEMS/mcl_
				-- potions/potions.lua) is what appends the roman-numeral
				-- level, but it only ever runs when tt.reload_itemstack_
				-- description() is explicitly called, which this loop never
				-- did. The potion WAS functionally Level II the whole time
				-- (a real, thrown potion would have applied the level-2
				-- effect correctly) -- this was purely a stale tooltip.
				if tt and tt.reload_itemstack_description then
					tt.reload_itemstack_description(stack)
				end
			end
		end
	end

	-- Apply to inventory. Mineclonia containers name their list "main"
	-- and have set_size("main", 27).
	local inv = core.get_meta(pos):get_inventory()
	if inv:is_empty("main") then -- idempotent: don't refill
		-- Per the project owner: a real survival chest usually reads as
		-- "someone put these here in some order" -- items packed from
		-- slot 1 onward -- not shuffled across the whole grid. Only a
		-- minority should look genuinely jumbled. 20/80 split, rolled on
		-- the same seeded pr so it's deterministic per position (a
		-- dedicated draw here, taken after the item-selection rolls
		-- above, so it doesn't perturb them).
		local shuffled = pr:next(1, 100) <= 20
		if not pair_pos then
			if shuffled then
				mcl_loot.fill_inventory(inv, "main", all_items, pr)
			else
				local size = inv:get_size("main")
				for i = 1, math.min(#all_items, size) do
					inv:set_stack("main", i, all_items[i])
				end
			end
		else
			-- Round 24: split the combined-pool result back across both
			-- real halves -- first own_inv_size items to this half,
			-- the rest to the paired position. Whichever real stacks
			-- merge_and_quantize_loot produced for a duplicated item now
			-- land as consecutive entries in ONE list, so they end up
			-- next to each other (same half, or the split boundary) --
			-- the "duplicate 3 small stacks scattered across both sides"
			-- symptom this round's fix specifically targets can't happen
			-- anymore, since there is now only ever one real stack per
			-- distinct item for the whole combined 54.
			local items_own, items_other = {}, {}
			for i = 1, #all_items do
				if i <= own_inv_size then items_own[#items_own + 1] = all_items[i]
				else items_other[#items_other + 1] = all_items[i] end
			end
			local inv_other = core.get_meta(pair_pos):get_inventory()
			if shuffled then
				mcl_loot.fill_inventory(inv, "main", items_own, pr)
				mcl_loot.fill_inventory(inv_other, "main", items_other, pr)
			else
				for i = 1, math.min(#items_own, inv:get_size("main")) do
					inv:set_stack("main", i, items_own[i])
				end
				for i = 1, math.min(#items_other, inv_other:get_size("main")) do
					inv_other:set_stack("main", i, items_other[i])
				end
			end
		end
	end
end

-- ---------------------------------------------------------------------
-- Driver
-- ---------------------------------------------------------------------
-- 1. After a short delay, start spawnimport via /museumimport.
-- 2. Poll registry; once stable for STABLE_FOR seconds, run loot pass.
-- 3. After all bases done, request shutdown.

local MANIFEST_PATH = core.settings:get("museum_manifest_path")
	or (core.get_worldpath() .. "/museum_manifest.json")
local TARGET_BASES = tonumber(core.settings:get("museum_target_bases"))
	or tonumber(core.settings:get("museumloot_target_bases")) or 3
local STABLE_FOR = tonumber(core.settings:get("museumloot_stable_seconds")) or 20

-- Track per-base state so we don't re-loot a base if the server is
-- restarted and the registry is loaded from disk.
local looted = {}
local function already_looted(name)
	if looted[name] then return true end
	for _, n in ipairs(looted._list or {}) do
		if n == name then return true end
	end
	return false
end

local function mark_looted(name)
	looted[name] = true
	looted._list = looted._list or {}
	looted._list[#looted._list + 1] = name
end

local function looted_signature(name)
	-- Deterministic per-base signature -- if it changes (e.g. a player
	-- trashed a chest in-game), we re-loot that base. For now: just the
	-- placed_chunks count, derived from the registry block_count. Cheap
	-- and stable.
	local rec = registry.find_by_name(name)
	if not rec then return nil end
	return rec.block_count
end

-- Async: calls done_cb() once this base is fully looted (or confirmed to
-- have no containers) and marked as such.
local function run_loot_for_base(base, done_cb)
	core.log("action", string.format("[museumloot] %s: stage 1 -- classifying containers", base.name))
	discover_containers_for_base(base, function(containers)
		core.log("action", string.format("[museumloot] %s: %d containers found", base.name, #containers))
		if #containers == 0 then
			mark_looted(base.name)
			done_cb()
			return
		end
		-- Histogram of themes AND structure matches for the run log, kept
		-- as two separate tallies so a run's log output still tells you
		-- what happened for both stage-1a (structure) and stage-1
		-- (sign-keyword) classified containers.
		local by_theme = {}
		local by_structure = {}
		for _, c in ipairs(containers) do
			if c.structure_match then
				by_structure[c.structure_match] = (by_structure[c.structure_match] or 0) + 1
			else
				by_theme[c.theme_key] = (by_theme[c.theme_key] or 0) + 1
			end
		end
		local summary = {}
		for theme, ct in pairs(by_theme) do
			summary[#summary + 1] = string.format("%s=%d", theme, ct)
		end
		local structure_summary = {}
		for structure, ct in pairs(by_structure) do
			structure_summary[#structure_summary + 1] = string.format("structure:%s=%d", structure, ct)
		end
		core.log("action", string.format("[museumloot] %s: theme histogram: %s", base.name, table.concat(summary, " ")))
		core.log("action", string.format("[museumloot] %s: structure histogram: %s", base.name, table.concat(structure_summary, " ")))

		-- Stage 3.
		for _, c in ipairs(containers) do
			-- Round 24: a paired "_right" half is fully handled by its
			-- "_left" partner's own call below (pair_pos), which splits
			-- the combined-pool result across both real inventories --
			-- calling this again for the right half would just try
			-- (harmlessly, since inv:is_empty("main") is already false
			-- by then, but wastefully) to re-roll it independently.
			local is_paired_right = c.node and c.node:match("_right$") and c.pair_other
			if not is_paired_right then
				fill_inv_from_theme(c.pos, c.kind, c.theme_key, c.nearby_signs_blob,
					c.structure_loot, c.structure_loot_use, c.structure_match, c.force_novelty,
					c.pair_other and c.pair_other.pos)
			end
		end
		core.log("action", string.format("[museumloot] %s: stage 3 done -- %d containers filled", base.name, #containers))

		-- Stage 4 (new, separate pass) -- mob placement. Reuses the same
		-- containers list (with structure_match already resolved above)
		-- and the same placed-bbox lookup discover_containers_for_base
		-- itself used, so no second emerge/scan of the base is needed --
		-- see mobplacement.lua's driver comment. Logged with its own
		-- "[museummobs]" prefix so it stays clearly separable from the
		-- loot pass above in the run log.
		local mob_bbox = (registry.find_by_name(base.name) or base).bbox
		local mob_summary = mobplacement.spawn_mobs_for_base(base, containers, mob_bbox)
		local prof_parts = {}
		for prof, ct in pairs(mob_summary.villager_by_profession) do
			prof_parts[#prof_parts + 1] = string.format("%s=%d", prof, ct)
		end
		core.log("action", string.format(
			"[museummobs] %s: spawned %d villager(s) [%s], %d shulker(s), %d witch(es)",
			base.name, mob_summary.villager, table.concat(prof_parts, " "),
			mob_summary.shulker, mob_summary.witch))

		mark_looted(base.name)
		done_cb()
	end)
end

local last_size = -1
local last_change_at = core.get_us_time()

-- Schedule a single kick on startup. register_on_mods_loaded fires after
-- every mod's been loaded; we use core.after(...) for an additional
-- delay so the spawnimport chat-command registration has fully settled.
core.register_on_mods_loaded(function()
	core.after(2, function()
		if _G.__spawnimport_kicked then return end
		_G.__spawnimport_kicked = true
		if core.registered_chatcommands and core.registered_chatcommands.museumimport then
			core.log("action", "[museumloot] kicking off museumimport on " .. MANIFEST_PATH)
			local ok, msg = core.registered_chatcommands.museumimport.func(
				"singleplayer", "start " .. MANIFEST_PATH .. " " .. TARGET_BASES)
			core.log("action", "[museumloot] museumimport says: " .. tostring(ok) .. " " .. tostring(msg))
		else
			core.log("error", "[museumloot] museumimport chatcommand not registered -- was spawnimport loaded and load_mod_spawnimport=true in world.mt?")
			core.request_shutdown("museumloot: no museumimport cmd", false, 1)
		end
	end)
end)

-- discover_containers_for_base/run_loot_for_base are async (they emerge
-- map area before scanning it), so at most one base loots at a time --
-- this guard keeps both the globalstep driver and a manual "/museumloot
-- run" from kicking off a second base's async chain while one is in
-- flight.
local looting_in_progress = false

local function loot_all_pending(entries, on_all_done)
	if looting_in_progress then return end
	local pending = {}
	for _, base in ipairs(entries) do
		if not already_looted(base.name) then pending[#pending + 1] = base end
	end
	if #pending == 0 then
		if on_all_done then on_all_done() end
		return
	end
	looting_in_progress = true
	local i = 0
	local function next_base()
		i = i + 1
		local base = pending[i]
		if not base then
			looting_in_progress = false
			if on_all_done then on_all_done() end
			return
		end
		run_loot_for_base(base, next_base)
	end
	next_base()
end

core.register_globalstep(function()
	-- 1. Poll registry.
	local entries = registry.list()
	local n = #entries

	if n ~= last_size then
		last_size = n
		last_change_at = core.get_us_time()
	end
	-- Wait until imports have either been stable for STABLE_FOR seconds
	-- OR we've placed all TARGET_BASES. Critical: don't kick off a
	-- loot run while spawnimport is still placing blocks -- mid-place
	-- reads see partial state and produce partial loot.
	local stable_for_us = STABLE_FOR * 1e6
	local stable_now = n > 0 and (core.get_us_time() - last_change_at) > stable_for_us
	local all_done = n >= TARGET_BASES
	if not (stable_now or all_done) then
		return
	end

	-- 2. Loot pass for any base not yet looted (one at a time; see
	-- loot_all_pending). A base can take several minutes of
	-- single-threaded VoxelManip walks; that's fine in a headless run
	-- with max_users=1.
	loot_all_pending(entries, function()
		-- 3. Shutdown when complete.
		local all = true
		for _, b in ipairs(entries) do
			if not already_looted(b.name) then all = false; break end
		end
		if all and #entries >= TARGET_BASES then
			core.log("action", string.format("[museumloot] ALL DONE - looted %d base(s), shutting down", #entries))
			core.request_shutdown("museumloot done", false, 0)
		end
	end)
end)

-- Register the /museumloot chat command for manual runs / inspection.
core.register_chatcommand("museumloot", {
	params = "[run | status]",
	description = "Run or inspect the post-import chest-loot pass",
	func = function(_, params)
		params = (params or "status"):lower()
		if params == "run" then
			local entries = registry.list()
			loot_all_pending(entries)
			return true, string.format("loot pass started for pending base(s) out of %d total", #entries)
		else
			local entries = registry.list()
			local looted_count = 0
			for _, b in ipairs(entries) do if already_looted(b.name) then looted_count = looted_count + 1 end end
			return true, string.format("placed=%d looted=%d/%d target=%d",
				#entries, looted_count, #entries, TARGET_BASES)
		end
	end
})
