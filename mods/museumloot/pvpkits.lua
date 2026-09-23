-- Curated PvP kit shulker boxes, per the project owner's real examples
-- from Oysterity (the largest Luanti Mineclonia anarchy server). A "kit"
-- here is not a themed pile of loose items like THEMES in init.lua --
-- it's a single shulker-box ITEM, pre-filled via itemstack meta the same
-- way a real player-packed kit shulker works, placed as ONE item inside a
-- container. See build_kit_stack() for how the meta blob is constructed
-- (mirrors mcl_chests' own get_shulker_stack()/
-- set_inventory_and_meta_from_stack() round trip, read directly from
-- mods/ITEMS/mcl_chests/init.lua -- the "compressed" meta key holds
-- core.encode_base64(core.compress(core.serialize(<27-slot array of
-- stack strings>), "zstd")), and "name" holds the display name shown in
-- the formspec title/tooltip).
--
-- Enchantment roster note (verified against mods/ITEMS/mcl_enchanting/
-- enchantments.lua this session): this Mineclonia checkout has NO
-- "protection", "feather_falling", "thorns", or "aqua_affinity"
-- enchantments -- these exist in vanilla Minecraft and apparently in
-- Oysterity's version, but simply aren't implemented here. Kit designs
-- below substitute the closest real mechanic (e.g. the nether kit carries
-- real fire_resistance potions instead of a fictional "fire protection"
-- enchant) rather than inventing enchant names that would silently do
-- nothing -- this project has already lost real time twice to exactly
-- that failure mode with item names, don't repeat it with enchant names.
--
-- Real max levels (verified, so callers below don't have to re-derive
-- them): sharpness/smite/efficiency/power/impaling/bane_of_arthropods = 5;
-- unbreaking/depth_strider/looting/loyalty/luck_of_the_sea/lure/
-- respiration/riptide/soul_speed/fortune = 3; fire_aspect/frost_walker/
-- punch = 2; mending/silk_touch/channeling/infinity/curse_of_vanishing/
-- flame/multishot = 1; breach = 4; wind_burst = 3; knockback = 2.
--
-- Correction (2026-09-18, found while verifying a fresh rebuild): armor
-- trims ARE real and implemented here after all (mods/ITEMS/mcl_armor/
-- trims.lua + mcl_smithing_table -- mcl_armor.trim(itemstack, overlay,
-- trim_material) applies one programmatically, no GUI needed; "wayfinder"
-- is a real registered trim, mcl_armor:wayfinder). An earlier pass this
-- session claimed the opposite ("no armor trim system") without checking
-- trims.lua -- exactly the guessing failure mode this file's own header
-- warns about. Not wired into any kit below yet (real follow-up, not
-- guessed at) -- the enchant-filtering logic above is unaffected since
-- protection/feather_falling/thorns/aqua_affinity are still genuinely
-- unregistered (re-confirmed, that part was correct).
--
-- 2026-09-18, round 2 (owner live-playtest of the above): "kits should
-- always be exactly the same, everything in them is the same high
-- quality gear" plus a long list of specifics -- see HANDOFF.md's
-- "2026-09-18 owner live-playtest findings, round 2" section A for the
-- full writeup this rewrite is based on. Universal rules applied to
-- every kit below except kit_mineral (a deliberate pure-blocks
-- exception, see its own comment):
--   1. Netherite armor everywhere, no diamond, no exceptions.
--   2. Every kit gets the same base "Tux Kit" loadout (see
--      add_tux_gear()) with only a weapon slot or two swapped per theme.
--   3. Every kit gets add_universal_essentials(): see its own comment
--      below (rewritten 2026-09-18 round 4) -- apples/bottles/totems/
--      rockets now come as nested full mini-kit shulkers, not loose
--      stacks, per a real "Tuxerian kit" reference the owner provided.
--
-- 2026-09-18, round 4 (owner live-playtest, images #38-#42 plus a real
-- Oysterity "Tuxerian kit" reference screenshot -- see HANDOFF.md's round
-- 4 section for the full writeup): the single biggest change is that
-- add_universal_essentials() no longer puts loose Enchanted Golden Apple/
-- Bottle o' Enchanting/Totem/Firework stacks directly in a kit's own 27
-- slots -- in the real reference, EVERY one of those is instead a full
-- 27-slot mini-kit shulker of just that item (see MINI_KITS below),
-- nested inside the big kit, "so killed players can pull a shulker in a
-- fight, grab everything inside... then go back out." Also new this
-- round: kits are fixed/deterministic sets (never a bare single apple --
-- always the full mini-kit shulker instead), never more than one
-- obsidian stack ("these are anchors"), exactly one water-bucket-16 and
-- one lava-bucket-16 stack per kit (never two of either, and lava is now
-- universal, not nether-only), and no kit may contain items that are
-- just mob/biome/location drops (wither skull, zombie head, rotten
-- flesh, bone were removed from kit_undead for exactly this reason --
-- "a kit should NEVER have items as drops from their location, biome or
-- target," only gear/consumables useful for fighting there or PvPing
-- there).

local pvpkits = {}

-- Deterministic per-container naming, same seeding convention as
-- fill_inv_from_theme's own PcgRandom usage elsewhere in this mod.
-- Generic base-name-flavored words (not real player/base names) --
-- combined with a role word and a roman-numeral suffix to read like a
-- real packed kit ("Tux Kit II", "Imperion Loadout").
local NAME_PREFIXES = {
	"Tux", "Imperion", "Stonemason", "Vanta", "Obelisk", "Ashfall",
	"Grimhold", "Nullpoint", "Wraithborn", "Ironclad", "Duskwatch",
	"Blackspire", "Frostbane", "Cindergate", "Hollowmere", "Redwake",
	"Sable", "Highreach", "Thornwood", "Voidkeep",
}
local ROMAN = { "", "II", "III", "IV", "V" }

local function kit_display_name(pos, role, pr)
	local prefix = NAME_PREFIXES[pr:next(1, #NAME_PREFIXES)]
	local numeral = ROMAN[pr:next(1, #ROMAN)]
	local label = prefix .. " " .. role
	if numeral ~= "" then label = label .. " " .. numeral end
	return label
end

-- `custom_name` uses the exact same real mechanism as an anvil rename
-- (verified against mods/ITEMS/mcl_anvils/init.lua: meta:set_string("name",
-- ...) then tt.reload_itemstack_description) -- real 2b2t/Oysterity kit
-- items are visibly custom-named ("FISHY 4", "Tux's CubeSlayer™"), not
-- just enchanted, and this project's own build_kit_stack() already uses
-- the identical pattern for the shulker box itself.
local function make_item(name, count, enchants, custom_name)
	local s = ItemStack(name)
	s:set_count(count or 1)
	if enchants then
		mcl_enchanting.set_enchantments(s, enchants)
	end
	if custom_name then
		s:get_meta():set_string("name", custom_name)
	end
	if tt and tt.reload_itemstack_description then
		tt.reload_itemstack_description(s)
	end
	return s
end

-- Builds a splash potion with an explicit tier, matching how mcl_potions
-- actually stores it (verified against mods/ITEMS/mcl_potions/potions.lua
-- and splash.lua this session): there is no separate "swiftness_2"
-- itemstring -- the level lives in itemstack meta. "potent" is the
-- Roman-numeral tier (1 = level II, since the engine stores potency as
-- level-1); "plus" is the extended-duration "+" variant. Splash potions
-- don't stack (stack_max defaults to 1 and neither fire_resistance,
-- invisibility, nor swiftness override it) -- "stacked if possible" per
-- the project owner isn't possible here, so these fill one slot each.
local function make_potion_splash(name, count, opts)
	opts = opts or {}
	local s = ItemStack("mcl_potions:" .. name .. "_splash")
	s:set_count(count or 1)
	local meta = s:get_meta()
	if opts.potent then meta:set_int("mcl_potions:potion_potent", opts.potent) end
	if opts.plus then meta:set_int("mcl_potions:potion_plus", opts.plus) end
	if tt and tt.reload_itemstack_description then
		tt.reload_itemstack_description(s)
	end
	return s
end

-- Shared full loadout, reused by every kit below except kit_mineral.
-- `opts.skip` is a set of role strings ("sword", "mace", "axe", "pick")
-- to leave out so a themed kit can swap its own weapon into that slot
-- instead (e.g. kit_aquatic replaces the sword with a trident). Always
-- appends exactly 9 items when nothing is skipped: helmet, chestplate,
-- leggings, boots, sword, mace, axe, pickaxe, elytra.
local function add_tux_gear(items, opts)
	opts = opts or {}
	local skip = opts.skip or {}
	items[#items + 1] = make_item("mcl_armor:helmet_netherite", 1,
		{ mending = 1, unbreaking = 3, respiration = 3 },
		"Tuxanian HeadProtector\226\132\162")
	items[#items + 1] = make_item("mcl_armor:chestplate_netherite", 1,
		{ mending = 1, unbreaking = 3 },
		"Tuxanian Chestplate\226\132\162")
	items[#items + 1] = make_item("mcl_armor:leggings_netherite", 1,
		{ mending = 1, unbreaking = 3 },
		"Tuxanian Leggings\226\132\162")
	items[#items + 1] = make_item("mcl_armor:boots_netherite", 1,
		{ depth_strider = 3, unbreaking = 3, mending = 1, soul_speed = 3 },
		"TuxanianBoots\226\132\162")
	if not skip.sword then
		items[#items + 1] = make_item("mcl_tools:sword_netherite", 1,
			{ looting = 3, fire_aspect = 2, mending = 1, sharpness = 5, unbreaking = 3, knockback = 2 },
			"FISHY 4")
	end
	if not skip.mace then
		items[#items + 1] = make_item("mcl_tools:mace", 1,
			{ unbreaking = 3, mending = 1, breach = 4, fire_aspect = 2, wind_burst = 1 },
			"Tux's CubeSlayer\226\132\162M")
	end
	if not skip.axe then
		items[#items + 1] = make_item("mcl_tools:axe_netherite", 1,
			{ silk_touch = 1, unbreaking = 3, mending = 1, sharpness = 5, efficiency = 5 },
			"Netherite Axe")
	end
	if not skip.pick then
		items[#items + 1] = make_item("mcl_tools:pick_netherite", 1,
			{ mending = 1, efficiency = 5, silk_touch = 1, unbreaking = 3 },
			"vivixyes pickaxe")
	end
	items[#items + 1] = make_item("mcl_armor:elytra", 1, { mending = 1, unbreaking = 3 })
	return items
end

-- Builds a filled shulker-box ITEM (not a placed node) from a flat list
-- of ItemStacks/strings, up to 27. `color` is one of mcl_chests' internal
-- shulker color codes (see museumloot/init.lua's SHULKER_MCL_COLORS).
local function build_kit_stack(color, name, items)
	local slots = {}
	for i = 1, 27 do
		local it = items[i]
		if it then
			-- Bug found live (2026-09-17): used Lua's generic tostring()
			-- here instead of ItemStack:to_string() -- tostring() on the
			-- userdata does NOT reliably produce the real serialized
			-- itemstring, so every slot decoded back into "Unknown Item"
			-- once the kit shulker was opened. get_shulker_stack() in
			-- mods/ITEMS/mcl_chests/init.lua (the real reference this
			-- mirrors) always calls stack:to_string() explicitly -- do
			-- the same.
			slots[i] = (type(it) == "string") and it or it:to_string()
		else
			slots[i] = ""
		end
	end
	local boxitem = ItemStack("mcl_chests:" .. color .. "_shulker_box")
	local bmeta = boxitem:get_meta()
	bmeta:set_string("name", name)
	bmeta:set_string("compressed", core.encode_base64(core.compress(core.serialize(slots), "zstd")))
	if tt and tt.reload_itemstack_description then
		tt.reload_itemstack_description(boxitem)
	end
	return boxitem
end
pvpkits.build_kit_stack = build_kit_stack

-- ---------------------------------------------------------------------
-- Mini "glitch" kits -- single-item full-stack shulkers, the kind that
-- end up NESTED inside a big kit per the "shulker inside a shulker"
-- duplication-glitch aesthetic the project owner asked to recreate. Real
-- 2b2t/anarchy-server duping bugs did exactly this (a shulker box ending
-- up inside another one that should never have accepted it) -- since
-- these are built directly via itemstack meta rather than a real
-- inventory-put interaction, the normal "no shulkers inside shulkers"
-- restriction (mcl_chests' allow_metadata_inventory_put) never gets a
-- chance to block it.
-- ---------------------------------------------------------------------

-- Colors match the project owner's real reference exactly (2026-09-18):
-- Bottles o' Enchanting = green, Totems = yellow, Fireworks = red. A
-- fourth single-item flavor (golden apples, "Dgabs" in the owner's own
-- shorthand) was described separately ("sometimes it's only Dgabs in
-- stacks of 64") -- given its own color since none of the three real
-- examples used orange.
-- Owner explicit 2026-09-18 round 5: "totems can't be stacked to 64,
-- they glitch if there is more than one so the Totems shulker box
-- should be just one totem per slot." A real, specific engine/gameplay
-- report (not the general stack_max cosmetic question already settled
-- for potions) -- totems get their own `count = 1` override, unlike the
-- other three which stay at 64 per the real Tuxerian-kit reference
-- screenshots (which explicitly showed 64-stacks of bottles/rockets/
-- apples, just not totems).
local MINI_KITS = {
	{ color = "yellow", role = "Totems", item = "mcl_totems:totem", count = 1 },
	{ color = "green", role = "Experience", item = "mcl_experience:bottle" },
	{ color = "red", role = "Rockets", item = "mcl_fireworks:rocket_1" },
	{ color = "orange", role = "Dgabs", item = "mcl_core:apple_gold_enchanted" },
}

-- New 2026-09-18 round 4: "Some kits should be entire shulkers full of
-- Invisibility+. This should be pretty common." Not one of the fixed
-- MINI_KITS above (those four are the fixed universal-essentials set
-- every kit gets, see add_universal_essentials below) -- this one is a
-- common but not-guaranteed pick, both as a standalone shulker (BIG_KITS,
-- higher weight) and as a maybe_nest() option (NESTABLE_MINI_KITS).
-- Uses `build_item` instead of `item` since a potion needs
-- make_potion_splash's meta-tier handling, not plain make_item.
--
-- Owner explicit round 5: "I believe Invisibility + can also not be
-- stacked to 64, just one per slot in a shulker" -- count dropped from
-- 64 to 1 per slot, same reasoning as the Totems fix above (a specific
-- reported gameplay concern, not just the general potion stack_max
-- question already confirmed technically possible for swiftness).
local INVIS_MINI_KIT = {
	color = "dark_grey", role = "Invisibility",
	build_item = function() return make_potion_splash("invisibility", 1, { plus = 1 }) end,
}

local NESTABLE_MINI_KITS = {}
for _, d in ipairs(MINI_KITS) do NESTABLE_MINI_KITS[#NESTABLE_MINI_KITS + 1] = d end
NESTABLE_MINI_KITS[#NESTABLE_MINI_KITS + 1] = INVIS_MINI_KIT

local function build_mini_kit_of(def, pos, pr)
	local items = {}
	for i = 1, 27 do
		items[i] = def.build_item and def.build_item() or make_item(def.item, def.count or 64)
	end
	return build_kit_stack(def.color, kit_display_name(pos, def.role, pr), items), items
end

local function build_mini_kit(pos, pr)
	return build_mini_kit_of(NESTABLE_MINI_KITS[pr:next(1, #NESTABLE_MINI_KITS)], pos, pr)
end

-- Universal essentials, every kit except kit_mineral (owner explicit
-- 2026-09-18 round 2, redesigned round 4). Per a real Oysterity
-- "Tuxerian kit" reference (owner screenshots): apples/bottles/totems/
-- rockets are NEVER loose stacks in a real kit -- each is a full 27-slot
-- mini-kit shulker of just that one item, nested inside the big kit ("no
-- Enchanted golden apples by themselves, just the shulker. no rockets,
-- just a shulker full of them"). The remaining loose items are the ones
-- the owner explicitly called out as staying loose, each exactly once
-- ("there would be NO NEED for 2 stacks of water buckets, just one stack
-- of lava 16 and one stack of water buckets 16 -- ever"; "you would not
-- have more than one stack of obsidian... these are anchors"). Lava is
-- now universal (round 4: "a stack of 16 bucket of lava is useful in all
-- kits, not just in the nether"), not just kit_nether's own addition.
-- Always appends exactly 8 items: 4 nested mini-kit shulkers + end
-- crystal x64 + obsidian x64 + water bucket x16 + lava bucket x16.
local function add_universal_essentials(items, pos, pr)
	for _, def in ipairs(MINI_KITS) do
		items[#items + 1] = build_mini_kit_of(def, pos, pr)
	end
	items[#items + 1] = make_item("mcl_end:crystal", 64)
	items[#items + 1] = make_item("mcl_core:obsidian", 64)
	items[#items + 1] = make_item("mcl_buckets:bucket_water", 16)
	items[#items + 1] = make_item("mcl_buckets:bucket_lava", 16)
	return items
end

-- Chance that one filler slot in a "big" kit gets replaced by a nested
-- mini-kit instead of a plain item stack. Per the project owner: "only
-- maybe 5% of shulkers would be like this, but a base might have an
-- entire double chest full of them" -- the low per-kit chance here is the
-- "5%"; build_closet() below is the "whole double chest" case.
local NEST_CHANCE_PERCENT = 5

-- ---------------------------------------------------------------------
-- Big kit templates. Each returns a filled shulker ItemStack given a
-- seeded PcgRandom. All builders share the same shape: a full loadout
-- (armor + weapon + a couple of tools) plus bulk consumables filling the
-- remaining slots, matching the density seen in the real Oysterity
-- examples (a kit reads as "everything you need," not a sparse chest).
-- ---------------------------------------------------------------------

-- NOTE (round 5): no longer called by any of the four big-kit builders
-- below (kit_standard/kit_undead/kit_nether/kit_aquatic) -- owner
-- explicit 2026-09-18 round 5: "there should be no random filler pool
-- for Kits, kits are always the same... Kits do not vary in what they
-- contain." A 5%-per-instance chance of an extra nested mini-kit is
-- exactly that kind of variance, so it's been dropped from the fixed
-- archetypes' own build path. Left defined (dead code for now, not
-- deleted) since it's a real, previously-requested mechanic in its own
-- right (a "shulker inside a shulker" dupe-glitch look) that a future
-- ask might want reattached to something else -- e.g. a dedicated rare
-- top-level pick, not spliced into an otherwise-fixed kit.
local function maybe_nest(items, pos, pr)
	if pr:next(1, 100) <= NEST_CHANCE_PERCENT then
		-- Replace a random EMPTY filler slot (never slot 1-5, keep the
		-- gear visible/first) with a nested mini-kit.
		--
		-- Bug found live 2026-09-18 round 4 (a real rebuild, not just
		-- code review): this used to pick `pr:next(6, 27)` and overwrite
		-- that index unconditionally, regardless of whether something
		-- was already there. Every kit builder pushes add_tux_gear +
		-- add_universal_essentials + its own flavor items into indices
		-- 1..N *before* calling this, so a slot in 6..27 very often
		-- already holds one of the now-guaranteed essentials (a Totems/
		-- Experience/Rockets/Dgabs mini-kit shulker, the single obsidian/
		-- end crystal/water bucket/lava bucket stack). A random hit on
		-- one of those silently destroyed it -- confirmed live via a
		-- decompressed-shulker scan of a real rebuild (roughly 1% of
		-- sampled kits were missing one of the four fixed mini-kit roles
		-- or had obsidian/lava16 count 0). Now only ever picks among
		-- slots that are genuinely still nil, so it can never clobber
		-- something add_universal_essentials or a kit's own flavor items
		-- already placed.
		local empty_slots = {}
		for i = 6, 27 do
			if items[i] == nil then empty_slots[#empty_slots + 1] = i end
		end
		if #empty_slots > 0 then
			local slot = empty_slots[pr:next(1, #empty_slots)]
			items[slot] = build_mini_kit(pos, pr)
		end
	end
	return items
end

--- Pad a kit's items list to a full 27 slots. Owner explicit feedback
--- (2026-09-17): "A kit should never be empty, every slot should be
--- filled." Filler is weighted toward universally-useful PvP supplies
--- (gold apples, totems, ender pearls, experience bottles, splash
--- potions, cobwebs) -- the things you'd realistically want on hand if
--- you grabbed the kit and went straight to PvP.
---
--- IMPORTANT (2026-09-18, root cause of a real bug found this session):
--- this function only fills genuinely-nil array slots. If a caller has
--- already pushed more than 27 items onto the list before calling this
--- (easy to do by accident once several helpers are chained together --
--- exactly what happened to kit_nether, which silently lost its
--- end_crystal/obsidian entries this way), the overflow items past #27
--- are NOT an error and are NOT reported here -- they just never make it
--- into build_kit_stack's 1..27 read and vanish. Every kit builder below
--- has been re-counted by hand to stay at or under 27 total; if you add
--- another item to one, recount before assuming fill_to_27 will catch it.
-- Owner explicit 2026-09-18 (round 3): "[the nether kit] has arrows
-- which are trash and should never be in one unless it has a power 5
-- bow or similarly enchanted crossbow" -- true of every kit below, none
-- of which carry a bow/crossbow at all (add_tux_gear is
-- sword/mace/axe/pick), so plain arrows are dropped from the filler
-- pool entirely rather than gated behind a bow check that would never
-- pass. "Good alternatives... invisibility + 8 minute potions, strength
-- 2 potions or swiftness II" added in their place, using the same
-- meta-tier mechanism as make_potion_splash (verified: potions don't
-- stack here, stack_max 1 for all three, so these fill one slot each
-- like the rest of KIT_FILLER's single-count entries).
-- Owner explicit 2026-09-18 round 4: "splash potion of swiftness 2
-- should be a stack of 64 as requested in all kits" (count bumped from 1
-- -- confirmed live this round that ItemStack:set_count() does NOT clamp
-- to a registered stack_max, so a stack_max=1 potion really does
-- round-trip correctly at count 64). Also round 4: "a stack of cobwebs
-- which are used to slow opponents in pvp" -- added to the filler pool
-- so it shows up in "some" kits (probabilistic), not forced into every
-- one.
--
-- IMPORTANT (round 4, found by live-verifying a rebuild -- a real bug,
-- not just a doc update): apple_gold_enchanted/totem/experience:bottle/
-- fireworks:rocket_1/bucket_water/obsidian/end:crystal used to be listed
-- here too, but add_universal_essentials now already guarantees exactly
-- one of each (apples/bottles/totems/rockets as nested mini-kit
-- shulkers, water bucket x16/obsidian x64/end crystal x64 as loose
-- singles) in EVERY kit -- leaving them in this random-pad pool let
-- fill_to_27 re-roll a SECOND (or third) copy into other filler slots,
-- directly violating the owner's explicit rules ("you would not have
-- more than one stack of obsidian... these are anchors", "no need for 2
-- stacks of water buckets... ever", "no Enchanted golden apples by
-- themselves, just the shulker"). Confirmed live: a sampled rebuild had
-- kits with 2-4 obsidian stacks and 2-3 water bucket stacks before this
-- fix. All seven removed from this pool; only items with no
-- "guaranteed exactly once" essential-slot conflict remain.
local KIT_FILLER = {
	{ item = "mcl_throwing:ender_pearl",       count = 16 },
	{ item = "mcl_potions:healing_splash",     count = 32 },
	{ item = "mcl_core:cobweb",                count = 64 },
	{ build = function() return make_potion_splash("invisibility", 1, { plus = 1 }) end },
	{ build = function() return make_potion_splash("strength", 1, { potent = 1 }) end },
	{ build = function() return make_potion_splash("swiftness", 64, { potent = 1 }) end },
}
-- Owner explicit 2026-09-18 round 5: "there should be no random filler
-- pool for Kits, kits are always the same. A kit set always has the
-- exact same parts... Kits do not vary in what they contain." Filler
-- selection used to be a `pr:next(1, #KIT_FILLER)` random pick per empty
-- slot -- two different instances of the SAME kit archetype could get a
-- different filler mix. Now walks KIT_FILLER in a fixed, repeating
-- order instead of rolling for it, so a given archetype's remaining
-- slots are always filled with the exact same items in the exact same
-- order every time (the `pr` param stays for signature/call-site
-- compatibility and because `build` closures for the splash potions
-- still need a PcgRandom, not because filler selection itself is random
-- anymore).
local function fill_to_27(items, pr)
	-- Items is a sparse list -- #items may be < 27, with possibly some
	-- nil gaps from maybe_nest. Walk to the next empty slot from index
	-- #items+1 and fill until we hit 27 or run out of useful fillers.
	local i = 1
	local filler_idx = 1
	while i <= 27 do
		if items[i] ~= nil then
			i = i + 1
		else
			local f = KIT_FILLER[filler_idx]
			items[i] = f.build and f.build() or make_item(f.item, f.count)
			filler_idx = (filler_idx % #KIT_FILLER) + 1
		end
	end
	return items
end

-- The project owner's real reference kit ("Tux Kit II", a live Oysterity
-- capture) -- verbatim item names/enchants transcribed from in-game
-- tooltips via add_tux_gear(), filtered down to only the enchants this
-- Mineclonia checkout actually has registered (see file header). This is
-- the base loadout every other kit below is now built from too.
-- Total: 9 (tux gear) + 8 (universal, round 4) + 1 (pearls) = 18, leaving
-- room for maybe_nest/fill_to_27. Owner explicit 2026-09-18: plain arrows
-- dropped (see KIT_FILLER's own comment -- no kit here carries a bow/
-- crossbow, so arrows were pure dead weight). Round 4: the old loose
-- "3x totem" loop was removed -- totems now come from the Totems
-- mini-kit shulker nested in add_universal_essentials, so a separate
-- loose stack would just be a duplicate.
local function kit_standard(pos, pr)
	local items = {}
	add_tux_gear(items)
	add_universal_essentials(items, pos, pr)
	items[#items + 1] = make_item("mcl_throwing:ender_pearl", 64)
	items = fill_to_27(items, pr)
	return build_kit_stack("violet", kit_display_name(pos, "Kit", pr), items), items
end

-- Total: 9 (tux gear, sword swapped) + 8 (universal, round 4)
-- + 3 (undead flavor, round 4) = 20.
local function kit_undead(pos, pr)
	-- Same "Tux Kit" chassis as every other kit (owner explicit
	-- 2026-09-18: "ALL kit items should be netherite... without
	-- exception, nobody makes them with diamond" -- this used to be
	-- diamond-tier, now netherite like the rest), but the sword carries
	-- Smite instead of Sharpness -- the project owner's own example of a
	-- per-purpose enchant swap ("gear set for undead/zombies would have
	-- Smite instead of Sharpness").
	local items = {}
	add_tux_gear(items, { skip = { sword = true } })
	items[#items + 1] = make_item("mcl_tools:sword_netherite", 1,
		{ smite = 5, unbreaking = 3, mending = 1, looting = 3 }, "Undead Slayer")
	add_universal_essentials(items, pos, pr)
	-- Owner explicit 2026-09-18 round 4: "it had wither sculls, rotten
	-- flesh, bones and a zombie head.. These are not useful in fighting.
	-- A kit should NEVER have items as drops from their location, biome
	-- or target... So all of these should be replaced with other things
	-- potions of swiftness 2 stack of 64, invisibility, totems. strength
	-- ii." (Totems already come from add_universal_essentials' Totems
	-- mini-kit above, so only the three potions need adding here.)
	items[#items + 1] = make_potion_splash("swiftness", 64, { potent = 1 })
	items[#items + 1] = make_potion_splash("invisibility", 1, { plus = 1 })
	items[#items + 1] = make_potion_splash("strength", 1, { potent = 1 })
	items = fill_to_27(items, pr)
	return build_kit_stack("black", kit_display_name(pos, "Undead Kit", pr), items), items
end

-- Total: 9 (tux gear) + 8 (universal, round 4) + 1 (flint&steel)
-- + 4 (fire res.) + 2 (invis/swiftness, round 4) + 1 (gold boots) = 25.
local function kit_nether(pos, pr)
	-- Owner explicit 2026-09-18: this is a kit for PvP *in* the Nether,
	-- not a pile of things *from* the Nether -- "no netherite kit should
	-- have glowstone stacks or quartz, these would be building
	-- materials not a pvp kit... no need for netherite except in the
	-- HIGHLY OP gear." Dropped the loose netherite_ingot/scrap and the
	-- quartz_block/glowstone entirely; add_tux_gear already keeps the
	-- equipped armor/weapons netherite.
	--
	-- "Fire resistance" means the potion effect, not an enchant -- no
	-- fire-protection-family enchant exists in this checkout (see file
	-- header). Soul Speed is real and boots-only, already in
	-- add_tux_gear.
	local items = {}
	add_tux_gear(items)
	add_universal_essentials(items, pos, pr)
	items[#items + 1] = make_item("mcl_fire:flint_and_steel", 1,
		{ unbreaking = 3, mending = 1 })
	-- Owner explicit 2026-09-18: "fire resistence potions (stacks if
	-- possible), potions of invisibility + (8 minutes), potions of
	-- swiftness II." Round 4: swiftness is now a real 64-count stack
	-- (ItemStack:set_count() doesn't clamp to stack_max, confirmed live
	-- this round), so one stack does the job of the old two separate
	-- ones -- "no need for 2 [identical] stacks... just one." Invisibility
	-- still fills one slot per potion (no count requested for it).
	for _ = 1, 4 do items[#items + 1] = make_item("mcl_potions:fire_resistance_splash", 1) end
	for _ = 1, 2 do items[#items + 1] = make_potion_splash("invisibility", 1, { plus = 1 }) end
	items[#items + 1] = make_potion_splash("swiftness", 64, { potent = 1 })
	-- Lava bucket x16 moved into add_universal_essentials (round 4: "a
	-- stack of 16 bucket of lava is useful in all kits, not just in the
	-- nether") -- no longer added here separately to avoid a duplicate.
	--
	-- Owner explicit 2026-09-18 round 4: "The Duskwatch Nether Kit has a
	-- golden sword but normally it would be a wearable piece of armor,
	-- usually boots which are gold. This is because piglins won't attack
	-- if you're wearing a piece of golden armor. A golden sword is
	-- useless as it does not give this effect and it breaks very
	-- quickly." Swapped for gold boots -- gold tools/armor still have the
	-- best enchantability of any material here, so a heavily-enchanted
	-- pair is still a real flex piece, just one that's actually useful
	-- for the kit's own purpose (Nether/piglin PvP) instead of a dead
	-- weapon slot.
	items[#items + 1] = make_item("mcl_armor:boots_gold", 1,
		{ unbreaking = 3, mending = 1, soul_speed = 3 },
		"Piglin's Golden Ticket")
	items = fill_to_27(items, pr)
	return build_kit_stack("red", kit_display_name(pos, "Nether Kit", pr), items), items
end

-- Total: 8 (tux gear, sword skipped) + 1 (trident) + 8 (universal, round 4)
-- + 2 (aquatic flavor, round 4) = 19.
local function kit_aquatic(pos, pr)
	-- Owner explicit 2026-09-18: "everything including an elytra at
	-- LEAST 2 stacks of enchanted golden apples 64 but also a trident
	-- with ALL applicable top enchants. ALL kit items should be
	-- netherite in all kits without exception... there is no need for
	-- kelp... look at Tux kit and add ALL items but replace a few, so
	-- for example a max enchanted trident instead of shears." (This kit
	-- never had shears in this codebase; read as "swap one weapon slot
	-- for a max trident," which is what skipping the sword below does.)
	--
	-- Riptide is deliberately left off the trident: verified against
	-- mods/ITEMS/mcl_enchanting/enchantments.lua this session --
	-- `riptide` lists `incompatible = {channeling=true, loyalty=true}`.
	-- "ALL applicable top enchants" on one trident together therefore
	-- means loyalty + impaling + channeling (all mutually compatible),
	-- not riptide too -- putting all four on would be internally
	-- contradictory, not just "extra OP."
	local items = {}
	add_tux_gear(items, { skip = { sword = true } })
	items[#items + 1] = make_item("mcl_tridents:trident", 1,
		{ loyalty = 3, impaling = 5, channeling = 1, unbreaking = 3, mending = 1 },
		"Poseidon's Wrath")
	add_universal_essentials(items, pos, pr)
	items[#items + 1] = make_item("mcl_fishing:fishing_rod", 1,
		{ luck_of_the_sea = 3, lure = 3, unbreaking = 3, mending = 1 })
	-- Owner explicit 2026-09-18 (round 3): "there should NEVER be a
	-- bucket of axolotl in a kit. water buckets should ALWAYS be a stack
	-- of 16." Axolotl bucket dropped entirely. Round 4: the loose water
	-- bucket line here was removed -- add_universal_essentials now
	-- already provides exactly one water-bucket-16 stack per kit ("no
	-- need for 2 stacks of water buckets... ever"), so a second one here
	-- would just be a duplicate.
	items[#items + 1] = make_item("mcl_potions:water_breathing_splash", 4)
	items = fill_to_27(items, pr)
	return build_kit_stack("blue", kit_display_name(pos, "Aquatic Kit", pr), items), items
end

-- No armor/weapons at all -- a pure "hard-to-find blocks, full stacks"
-- kit, per the project owner's original description. Deliberately NOT
-- built from add_tux_gear()/add_universal_essentials() -- this is the
-- one kit archetype that's supposed to be materials-only, not a combat
-- loadout.
--
-- Owner feedback 2026-09-18: the live shulker was mostly empty despite
-- fill_to_27 looking correctly wired up on inspection -- root cause not
-- confirmed (flagged in HANDOFF.md as needing a live re-check). Rather
-- than depend on fill_to_27 (and whatever was actually going wrong with
-- it) for this kit, every one of the 27 slots is now built directly here
-- from repeated copies of the same 8 block types -- matching the real
-- reference screenshot (multiple slots of diamond/gold/lapis/etc, not
-- one-of-each) and sidestepping the mystery entirely.
local MINERAL_BLOCKS = {
	"mcl_core:diamondblock", "mcl_core:emeraldblock",
	"mcl_nether:netheriteblock", "mcl_core:goldblock",
	"mcl_core:lapisblock", "mcl_core:coalblock",
	"mcl_nether:quartz_block", "mcl_core:ironblock",
}
local function kit_mineral(pos, pr)
	local items = {}
	for i = 1, 27 do
		items[i] = make_item(MINERAL_BLOCKS[((i - 1) % #MINERAL_BLOCKS) + 1], 64)
	end
	return build_kit_stack("cyan", kit_display_name(pos, "Mineral Kit", pr), items), items
end

local function kit_restock(pos, pr)
	-- 2026-09-19 owner correction: the previous version put each
	-- enchanted golden apple and each splash potion of healing in its
	-- own count=1 slot (9 near-empty slots each), and included splash
	-- potions of healing at all -- a restock kit should NEVER carry
	-- those (per the owner: "no restock should ever be splash potions
	-- of healing"). Real reference is "9 full stacks of each kind":
	-- apples and rockets both stack to 64 with no stack_max override in
	-- their own core.register_craftitem calls (verified the same way
	-- mcl_core:diamond -- a known-64-stack item -- also omits
	-- stack_max, confirming 64 is this build's real default, not
	-- guessed), so all three item types here fill exactly 9x64 = 27
	-- slots with no need for fill_to_27 padding or the dead
	-- crystal/obsidian entries that fill_to_27 was silently truncating
	-- away before (removed rather than left as misleading dead code).
	local items = {}
	for _ = 1, 9 do items[#items + 1] = make_item("mcl_core:apple_gold_enchanted", 64) end
	for _ = 1, 9 do items[#items + 1] = make_item("mcl_experience:bottle", 64) end
	for _ = 1, 9 do items[#items + 1] = make_item("mcl_fireworks:rocket_1", 64) end
	return build_kit_stack("pink", kit_display_name(pos, "Restock", pr), items), items
end

-- New archetype, owner explicit 2026-09-18: "There should be shulker
-- boxes with mixes of OP books... ALL of these are the same book in
-- here... notice how ALL slots are filled." Real reference tooltip (an
-- Oysterity "Experience" shulker screenshot): Silk Touch, Unbreaking III,
-- Power V, Lure III, Efficiency V, Luck of the Sea III, Thorns III,
-- Sharpness V, Fire Aspect II, Mending, Protection IV, Quick Charge III,
-- Punch II -- filtered to only enchants actually registered here (no
-- thorns/protection, see file header). Every enchant here is normally
-- tied to a specific tool/weapon/bow type, but an enchanted BOOK doesn't
-- need item-type compatibility (mcl_enchanting.set_enchantments just
-- serializes whatever meta it's given; a book is meant to store any
-- combination for later application).
local BOOK_ENCHANTS = {
	silk_touch = 1, unbreaking = 3, power = 5, lure = 3,
	efficiency = 5, luck_of_the_sea = 3, sharpness = 5,
	fire_aspect = 2, mending = 1, quick_charge = 3, punch = 2,
}
local function kit_books(pos, pr)
	local items = {}
	for i = 1, 27 do
		items[i] = make_item("mcl_enchanting:book_enchanted", 1, BOOK_ENCHANTS, "God Book")
	end
	return build_kit_stack("magenta", kit_display_name(pos, "Books", pr), items), items
end

-- Weighted pool for a single random kit pick. The single-item mega-stack
-- flavors (MINI_KITS) get their own low-weight slots here too -- per the
-- project owner (2026-09-18): "sometimes a shulker has only Dgabs
-- (Enchanted Golden Apples) in stacks of 64. Sometimes it's only totems."
-- That's a shulker whose ENTIRE contents are one of these, not just the
-- 5% maybe_nest() chance of one turning up nested inside a bigger kit.
local BIG_KITS = {
	{ build = kit_standard, weight = 4 },
	{ build = kit_undead, weight = 2 },
	{ build = kit_nether, weight = 2 },
	{ build = kit_aquatic, weight = 2 },
	{ build = kit_mineral, weight = 2 },
	{ build = kit_restock, weight = 3 },
	{ build = kit_books, weight = 2 },
}
for _, def in ipairs(MINI_KITS) do
	BIG_KITS[#BIG_KITS + 1] = {
		build = function(pos, pr) return build_mini_kit_of(def, pos, pr) end,
		weight = 1,
	}
end
-- Owner explicit 2026-09-18 round 4: "Some kits should be entire
-- shulkers full of Invisibility+. This should be pretty common." --
-- weighted above the fixed MINI_KITS entries (which are already
-- guaranteed inside every big kit via add_universal_essentials, so their
-- weight here is just "also sometimes standalone").
BIG_KITS[#BIG_KITS + 1] = {
	build = function(pos, pr) return build_mini_kit_of(INVIS_MINI_KIT, pos, pr) end,
	weight = 3,
}
local BIG_KITS_TOTAL = 0
for _, e in ipairs(BIG_KITS) do BIG_KITS_TOTAL = BIG_KITS_TOTAL + e.weight end

-- Returns one filled kit shulker ItemStack, plus (as a second return
-- value) the raw <=27-length items array that was sealed inside it --
-- every kit builder above now returns both. The second value lets a
-- caller fill a REAL placed shulker box's own inventory directly with a
-- kit's contents instead of nesting the wrapped stack inside it -- see
-- build_random_kit_items below.
function pvpkits.build_random_kit(pos, pr)
	local roll = pr:next(1, BIG_KITS_TOTAL)
	local acc = 0
	for _, e in ipairs(BIG_KITS) do
		acc = acc + e.weight
		if roll <= acc then return e.build(pos, pr) end
	end
	return kit_standard(pos, pr)
end

-- Owner explicit 2026-09-18 round 4: "all of these shulker boxes on the
-- ground contain other kits... I would expect most of these to be kits
-- as in HAVING the contents of a kit. I.e. the same contents as a kit
-- found in a chest... chests would have these more often and usually it
-- would be a FULL chest, not partial." A ground-placed shulker box that
-- rolls the pvp_kit theme should, most of the time, BE the kit (its own
-- 27 slots directly hold the kit's items) rather than contain 1-3 nested
-- kit-shulker items -- that nested-shulkers-of-kits "closet" look is
-- reserved for the rarer explicit closet case. Returns just the raw
-- items array (never a wrapped shulker stack) for init.lua's
-- fill_inv_from_theme to set directly onto a real shulker's inventory.
function pvpkits.build_random_kit_items(pos, pr)
	local _, items = pvpkits.build_random_kit(pos, pr)
	return items
end

-- "A base might have an entire double chest full of them" -- a closet of
-- several DIFFERENT kit shulkers, one per returned stack, for a large
-- container (double chest) to be filled with via fill_inv_from_theme.
function pvpkits.build_closet(pos, pr, count)
	count = count or pr:next(5, 9)
	local out = {}
	for i = 1, count do
		out[i] = pvpkits.build_random_kit(pos, pr)
	end
	return out
end

return pvpkits
