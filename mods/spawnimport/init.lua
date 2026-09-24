-- spawnimport: bulk-imports a WorldTools Minecraft world capture into this
-- Mineclonia world via /worldplace. See README.md for install requirements
-- (this mod needs unsandboxed filesystem access) and usage.
--
-- This file is orchestration only: reading Anvil/NBT and resolving blocks
-- to Mineclonia nodes is entirely spawnmasons/lua_import's job (steps 1-3
-- of the pipeline, see IMPORT_SPEC.md) -- this mod just drives it, batches
-- the work across server steps, and writes the result with VoxelManip.

local modpath = core.get_modpath("spawnimport")

-- core.request_insecure_environment() MUST be called directly from the
-- mod's init.lua main scope (not from a function, not from a dofile'd
-- file) -- see doc/lua_api.md. It returns the real, unsandboxed globals
-- (the ones that existed before Luanti replaced io/os/dofile/debug for
-- this mod) if 'spawnimport' is listed in secure.trusted_mods, or
-- unconditionally if secure.enable_security=false. Either way this mod
-- needs it: it reads the WorldTools source folder by absolute path, which
-- is outside any world/mod directory Luanti would otherwise allow.
--
-- core.get_dir_list/core.decompress are NOT usable here even once trusted:
-- get_dir_list has no trusted-mod bypass of its own (checked against the
-- engine source, not assumed) and always rejects an out-of-bounds path
-- when security is enabled, trusted or not. So directory listing below
-- goes through the insecure io.popen instead; only core.decompress (which
-- operates on in-memory data, not a filesystem path) is safe to keep
-- using directly.
local insecure = core.request_insecure_environment()
if not insecure then
	error("[spawnimport] core.request_insecure_environment() returned nil -- add 'spawnimport' to " ..
		"the secure.trusted_mods setting, or set secure.enable_security=false. This mod needs real " ..
		"filesystem access to read the WorldTools source folder (outside any world/mod directory).")
end

-- Published as globals so lua_import's files (loaded below, and reloaded
-- by each other via their own sibling-loading -- see anvil.lua/palette.lua)
-- can see them without needing debug.getinfo() (unavailable in the
-- sandboxed environment) to find their own directory, and without needing
-- their own copy of the insecure-environment dance (only a mod's own
-- init.lua main scope can call request_insecure_environment() at all).
local LUA_IMPORT_PATH = core.settings:get("spawnimport_lua_import_path")
	or "/Volumes/Dara/dev/luanti/spawnmasons/lua_import/"
if LUA_IMPORT_PATH:sub(-1) ~= "/" then
	LUA_IMPORT_PATH = LUA_IMPORT_PATH .. "/"
end
_G.__spawnimport_lua_import_path = LUA_IMPORT_PATH
_G.__spawnimport_dofile = insecure.dofile
_G.__spawnimport_io = insecure.io

-- Directory listing via the real io.popen (core.get_dir_list can't read
-- arbitrary external paths regardless of trust -- see note above).
local function list_dir(path, only_dirs)
	local kind = only_dirs and "d" or "f"
	local cmd = string.format("find %q -mindepth 1 -maxdepth 1 -type %s -exec basename {} \\;", path, kind)
	local p = insecure.io.popen(cmd)
	local names = {}
	if p then
		for line in p:lines() do names[#names + 1] = line end
		p:close()
	end
	return names
end

local load_ok, anvil = pcall(insecure.dofile, LUA_IMPORT_PATH .. "anvil.lua")
if not load_ok then
	error("[spawnimport] could not load anvil.lua from '" .. LUA_IMPORT_PATH .. "' -- " ..
		"set the 'spawnimport_lua_import_path' setting if spawnmasons/lua_import isn't at the " ..
		"default location. Underlying error: " .. tostring(anvil))
end
local nbt = insecure.dofile(LUA_IMPORT_PATH .. "nbt.lua")
local palette = insecure.dofile(LUA_IMPORT_PATH .. "palette.lua")

-- items.lua is optional. Many installs won't have it (it only exists in the
-- kit since vX), so fall back to a no-op resolver rather than crashing the
-- mod load. Importing item frames won't get item translation without it,
-- but sign placement, blocks, and chests will continue to work.
local items
do
	local ok, mod_items = pcall(insecure.dofile, LUA_IMPORT_PATH .. "items.lua")
	if ok then
		items = mod_items
	else
		core.log("warning", string.format(
			"[spawnimport] optional items.lua not found at '%s' (%s) -- item-frame " ..
			"items will be translated through mcl_core:<name> fallback only. " ..
			"See lua_import/items.lua in the museum-import-kit.",
			LUA_IMPORT_PATH .. "items.lua", tostring(mod_items)))
		-- Minimal stub so the importer still functions. Anything we don't
		-- know becomes mcl_core:<name> and may or may not exist; the
		-- frame-still-places logic at the call site handles a missing
		-- registered_items[mcl_item] without crashing.
		items = {
			resolve = function(vanilla_id)
				if not vanilla_id or type(vanilla_id) ~= "string" then return nil end
				local body = vanilla_id:match("^minecraft:(.+)$")
				if not body then return nil end
				return "mcl_core:" .. body
			end,
			unknown = function() return nil end,
		}
	end
end

-- mapdata.lua (real map .dat decoding for map-art item frames) is
-- optional in the same spirit as items.lua above -- a capture with no
-- filled maps, or a kit copy that predates this file, shouldn't break
-- the rest of the import.
local mapdata
do
	local ok, mod_mapdata = pcall(insecure.dofile, LUA_IMPORT_PATH .. "mapdata.lua")
	if ok then
		mapdata = mod_mapdata
	else
		core.log("warning", "[spawnimport] optional mapdata.lua not found/failed to load (" ..
			tostring(mod_mapdata) .. ") -- filled maps in item frames will be placed blank.")
	end
end

-- ---------------------------------------------------------------------
-- Mob import (2026-09-18 round 6): vanilla entity id -> real Mineclonia
-- mob entity id. Every name on the right below was verified against a
-- real `mcl_mobs.register_mob ("mobs_mc:<name>", ...)` call in
-- mods/ENTITIES/mobs_mc/*.lua (grepped directly, not guessed -- this
-- project has lost real time to guessed mob/item names before). Mobs
-- with no real Mineclonia equivalent found (turtle, frog, panda, fox,
-- bee, goat, camel, sniffer, allay, tadpole, warden, phantom -- checked,
-- none registered anywhere in this checkout) are simply absent from this
-- table and get silently skipped at the call site, same "don't guess a
-- fallback name" policy as everywhere else in this pipeline.
-- Owner explicit 2026-09-19 round 8: "Remove the import of hostile mobs.
-- No need for them and they make the game laggy having so many named
-- mobs." Every hostile/monster-category entry (zombie family, skeleton
-- family, spider family, enderman/endermite, witch, silverfish, blaze,
-- ghast, piglin family, hoglin/zoglin, wither, ender_dragon, shulker,
-- guardian family, illager family, creeper, slime/magma_cube) removed
-- outright -- only villagers, the wandering trader, and real passive/
-- neutral wildlife remain. (strider/iron_golem/snow_golem/polar_bear/
-- wolf kept -- none of these attack a player unprovoked in Mineclonia,
-- matching this project's own museumloot/mobplacement.lua convention of
-- only ever spawning villagers/shulkers/witches, never hostile mobs.)
local MOB_ID_MAP = {
	["minecraft:villager"] = "mobs_mc:villager",
	["minecraft:wandering_trader"] = "mobs_mc:wandering_trader",
	["minecraft:strider"] = "mobs_mc:strider",
	["minecraft:iron_golem"] = "mobs_mc:iron_golem",
	["minecraft:snow_golem"] = "mobs_mc:snowman",
	["minecraft:cow"] = "mobs_mc:cow",
	["minecraft:mooshroom"] = "mobs_mc:mooshroom",
	["minecraft:pig"] = "mobs_mc:pig",
	["minecraft:sheep"] = "mobs_mc:sheep",
	["minecraft:chicken"] = "mobs_mc:chicken",
	["minecraft:rabbit"] = "mobs_mc:rabbit",
	["minecraft:wolf"] = "mobs_mc:wolf",
	["minecraft:cat"] = "mobs_mc:cat",
	["minecraft:ocelot"] = "mobs_mc:ocelot",
	["minecraft:parrot"] = "mobs_mc:parrot",
	["minecraft:horse"] = "mobs_mc:horse",
	["minecraft:donkey"] = "mobs_mc:donkey",
	["minecraft:mule"] = "mobs_mc:mule",
	["minecraft:llama"] = "mobs_mc:llama",
	["minecraft:trader_llama"] = "mobs_mc:trader_llama",
	["minecraft:skeleton_horse"] = "mobs_mc:skeleton_horse",
	["minecraft:zombie_horse"] = "mobs_mc:zombie_horse",
	["minecraft:polar_bear"] = "mobs_mc:polar_bear",
	["minecraft:axolotl"] = "mobs_mc:axolotl",
	["minecraft:dolphin"] = "mobs_mc:dolphin",
	["minecraft:squid"] = "mobs_mc:squid",
	["minecraft:glow_squid"] = "mobs_mc:glow_squid",
	["minecraft:cod"] = "mobs_mc:cod",
	["minecraft:salmon"] = "mobs_mc:salmon",
	["minecraft:pufferfish"] = "mobs_mc:pufferfish",
	["minecraft:tropical_fish"] = "mobs_mc:tropical_fish",
	["minecraft:bat"] = "mobs_mc:bat",
}

-- 2026-09-19 owner explicit (round 14): real captured villagers were
-- all getting the SAME nametag (the species description, "Villager"),
-- needed only for despawn-immunity (see the ent.can_despawn = false
-- block below) -- reads as a population of clones. A pool of common
-- first names, mixed male/female, picked deterministically per
-- villager position (see the seeding below) so a re-import assigns the
-- same name to the same villager again. Not an exhaustive 500-name
-- list (no package manager / "Faker" library available in this Lua
-- environment), but large enough that visible repeats within any one
-- base's real villager population (a few dozen at most) are unlikely.
local VILLAGER_NAME_POOL = {
	"James", "Mary", "Robert", "Patricia", "John", "Jennifer", "Michael", "Linda",
	"David", "Elizabeth", "William", "Barbara", "Richard", "Susan", "Joseph", "Jessica",
	"Thomas", "Sarah", "Charles", "Karen", "Christopher", "Nancy", "Daniel", "Lisa",
	"Matthew", "Betty", "Anthony", "Margaret", "Mark", "Sandra", "Donald", "Ashley",
	"Steven", "Kimberly", "Paul", "Emily", "Andrew", "Donna", "Joshua", "Michelle",
	"Kenneth", "Dorothy", "Kevin", "Carol", "Brian", "Amanda", "George", "Melissa",
	"Timothy", "Deborah", "Ronald", "Stephanie", "Edward", "Rebecca", "Jason", "Sharon",
	"Jeffrey", "Laura", "Ryan", "Cynthia", "Jacob", "Kathleen", "Gary", "Amy",
	"Nicholas", "Shirley", "Eric", "Angela", "Jonathan", "Helen", "Stephen", "Anna",
	"Larry", "Brenda", "Justin", "Pamela", "Scott", "Nicole", "Brandon", "Emma",
	"Benjamin", "Samantha", "Samuel", "Katherine", "Gregory", "Christine", "Alexander", "Debra",
	"Patrick", "Rachel", "Frank", "Catherine", "Raymond", "Carolyn", "Jack", "Janet",
	"Dennis", "Ruth", "Jerry", "Maria", "Tyler", "Heather", "Aaron", "Diane",
	"Jose", "Virginia", "Adam", "Julie", "Henry", "Joyce", "Nathan", "Victoria",
	"Douglas", "Olivia", "Zachary", "Kelly", "Peter", "Christina", "Kyle", "Lauren",
	"Walter", "Joan", "Ethan", "Evelyn", "Jeremy", "Judith", "Harold", "Megan",
	"Keith", "Cheryl", "Christian", "Andrea", "Roger", "Hannah", "Noah", "Martha",
	"Gerald", "Jacqueline", "Carl", "Frances", "Terry", "Gloria", "Sean", "Ann",
	"Austin", "Teresa", "Arthur", "Kathryn", "Lawrence", "Sara", "Jesse", "Janice",
	"Dylan", "Jean", "Bryan", "Alice", "Joe", "Madison", "Jordan", "Doris",
	"Billy", "Abigail", "Bruce", "Julia", "Albert", "Judy", "Willie", "Grace",
	"Gabriel", "Denise", "Logan", "Amber", "Alan", "Marilyn", "Juan", "Beverly",
	"Wayne", "Danielle", "Roy", "Theresa", "Ralph", "Sophia", "Randy", "Marie",
	"Eugene", "Diana", "Vincent", "Brittany", "Russell", "Natalie", "Elijah", "Isabella",
	"Louis", "Charlotte", "Bobby", "Rose", "Philip", "Alexis", "Johnny", "Kayla",
}

-- Simple string hash for seeding the per-base villager name shuffle
-- (see place_one_chunk's villager-naming block below) -- stable across
-- re-runs (same base name -> same seed), doesn't need to be
-- position-based since it seeds a whole-base shuffle, not a
-- per-villager pick.
local function pos_seed_for_name(str)
	local h = 0
	for i = 1, #str do
		h = (h * 31 + str:byte(i)) % 2 ^ 31
	end
	return math.floor(h)
end

-- Real vanilla profession ids (minecraft:<name>) already match the
-- profession KEY strings this project's own mobplacement.lua uses for
-- villager:set_profession() (see PROFESSION_WORKSTATIONS there,
-- confirmed against mods/ENTITIES/mobs_mc/villager.lua's own
-- villager_professions table this session) -- so no separate mapping
-- table is needed, just strip the "minecraft:" prefix. "minecraft:none"
-- and "minecraft:nitwit" both fall through to "no profession set"
-- (set_profession is simply not called), matching how mobplacement.lua's
-- own comment explains nitwit can never be usefully detected/assigned.

-- Vanilla item-frame entity `Facing` (a Direction enum ORDINAL, 0..5:
-- 0=down, 1=up, 2=north, 3=south, 4=west, 5=east -- the standard,
-- long-stable Minecraft Direction.getById() ordering; a real decoded
-- item-frame entity this session had Facing=5, consistent with this
-- ordering, but the wall orientation at that exact world position
-- wasn't independently cross-checked, so this is "consistent with,"
-- not "proven by," that one sample) -> Luanti wallmounted
-- param2. Deliberately reuses the SAME north/south/east/west VALUES as
-- palette.lua's own `FACING_TO_WALLMOUNTED` (north=4, south=5, east=3,
-- west=2) rather than the inverted `SHULKER_FACING_TO_WALLMOUNTED`
-- table -- palette.lua's own comment on `SIGN_FACING_TO_WALLMOUNTED`
-- documents a real live-verified finding that the "outward-facing
-- direction" semantic (which way a sign's text, or here a frame's
-- picture, faces the viewer) maps DIRECTLY with no inversion, unlike a
-- shulker box's "which way it opens" semantic.
--
-- 2026-09-19 owner correction (round 13, live report -- floor-mounted
-- map art appearing ceiling-attached and "floating"): the up/down (0/1)
-- values below were WRONG -- they borrowed SHULKER_FACING_TO_
-- WALLMOUNTED's up=0/down=1 convention (a shulker's "which way it
-- opens" semantic), the exact same inversion-transfer mistake round 11
-- (palette.lua's sculk_vein/glow_lichen fixes) already found and warned
-- about for OTHER nodes -- it was never actually re-derived for item
-- frames specifically. Re-derived properly this round: mcl_itemframes
-- has NO custom on_place override (confirmed by reading mods/ITEMS/
-- mcl_itemframes/init.lua), so a real frame is placed through Luanti's
-- ENGINE-DEFAULT wallmounted placement logic -- the exact same
-- mechanism mcl_torches' own on_place uses explicitly (`wdir =
-- core.dir_to_wallmounted(under-above)`, confirmed this round: floor
-- placement (attached to a block below) always yields wdir/param2 == 1,
-- ceiling placement (attached to a block above) yields 0). A frame
-- with real Facing=1 (up -- its picture faces up, meaning it's resting
-- on a floor block below it, viewed from above) is placement-wise a
-- FLOOR mount, matching the engine-default floor==1 convention -- NOT
-- the shulker-specific up==0. Swapped to match. Not yet live-verified
-- against a fresh rebuild (owner asked to hold off on re-running while
-- checking prior work) -- confirm on the next pass.
local ITEM_FRAME_FACING_TO_WALLMOUNTED = {
	[0] = 0, -- down (picture faces down -> ceiling-mounted) -> wallmounted "ceiling"
	[1] = 1, -- up (picture faces up -> floor-mounted) -> wallmounted "floor"
	[2] = 4, -- north
	[3] = 5, -- south
	[4] = 2, -- west
	[5] = 3, -- east
}

local registry = dofile(modpath .. "/registry.lua") -- inside the mod's own dir, sandboxed dofile is fine
local gap_field = dofile(modpath .. "/gap_field.lua") -- pure merge height-field solver (gap_field_test.lua covers it)
local wdl_climate = dofile(modpath .. "/wdl_climate.lua") -- WDL biome/temperature map (pure; PLAN-worldgen-merge.md)
local wgen_inputs = dofile(modpath .. "/wgen_inputs.lua")(wdl_climate) -- per-column merge targets (biome/material/tint/snow)
local wgen_write = dofile(modpath .. "/wgen_write.lua")(wdl_climate) -- column rebuild + natural vegetation regrow
local gap_fill = dofile(modpath .. "/gap_fill.lua")(gap_field, wgen_inputs) -- merge plan + audit, see that file's own header

-- core.get_mod_storage() is scoped per-calling-modname, so a different mod
-- (museumwarp) can't read this one's storage directly -- publish the
-- registry module itself (registry.list()/find_by_name() etc.) as a global
-- instead, same cross-file convention as the __spawnimport_* globals above.
-- museumwarp depends on this mod (see its mod.conf) so load order is
-- guaranteed.
_G.__spawnimport_registry = registry

anvil.list_dir = function(dir) return list_dir(dir, false) end
assert(anvil.decompress, "[spawnimport] core.decompress not wired -- is this really running inside Luanti?")

core.register_privilege("worldplace", {
	description = "Can run /worldplace to bulk-import Minecraft world captures",
	give_to_singleplayer = true,
	give_to_admin = true,
})

local STEP_BUDGET_US = (tonumber(core.settings:get("spawnimport_step_budget_ms")) or 40) * 1000
-- Debug: run ONLY the gap-fill merge (skip placing the captured chunks).
-- Lets merge tuning iterate in minutes instead of a full ~17-minute
-- import: pregen + ring solve + write only.
local GAP_ONLY = (core.settings:get("spawnimport_gap_only") or "") == "true"
-- Last finished job's gap-fill plan + job params, so /worldplace gapaudit
-- can re-run the merge audit on demand (declared here, not near
-- active_job, because Job:finish -- far above -- writes it).
local last_gap = nil
local PROGRESS_EVERY_PCT = 5

-- Y range pre-generated before placing a base (see new_job's pregen notes
-- for why pre-generation is required at all). This has to cover every Y a
-- chunk might write to, because any block written without being generated
-- first is both regenerated over and never sent to the client. Modern
-- (1.18+) chunks allocate sections across world y -64..319, so that whole
-- span is in scope regardless of where a particular base's content sits.
-- Mineclonia's overworld floor sits below the -64 that 1.18+ Minecraft
-- chunks bottom out at, and Mineclonia's own Lua levelgen fills that gap
-- (see place_one_chunk's clear_y_min). Read it from mcl_vars rather than
-- hardcoding, since it varies by mapgen (-128 or -130 in mcl_init).
local OVERWORLD_MIN_Y = (mcl_vars and mcl_vars.mg_overworld_min) or -130
local PREGEN_Y_MIN = math.min(-64, OVERWORLD_MIN_Y)
local PREGEN_Y_MAX = 319

-- 2026-09-19 (owner live report + direct empirical verification, not
-- guessed): Mineclonia's real overworld terrain generation places its
-- ENTIRE height profile (sea level, bedrock, everything) 64 blocks lower
-- than the raw vanilla Y a captured base's own blocks use -- confirmed
-- directly against a real running world (natural bedrock at y=-124..-128,
-- exactly 64 below vanilla's y=-64). The museum manifest sets every
-- overworld base's `dest_y_offset` to this value, so an imported base's
-- own real bedrock lands exactly at Mineclonia's real bedrock instead of
-- floating 64 blocks above it.
--
-- 2026-09-23 CORRECTION: bedrock alignment (-64) turns out to leave the
-- imported sea level ~3 blocks BELOW Mineclonia's actual natural ocean
-- surface. Mineclonia's water_level (v7 mapgen setting, =1) is ~3 blocks
-- higher, relative to bedrock, than Minecraft's sea level: vanilla water
-- surface y=62 maps to dest -2 at -64, but Mineclonia's ocean generates
-- at dest 1. That submerges any ocean base's structures by 2 blocks
-- (Tactical Nuke's hangar flooding). The fix is to align the SEA LEVEL
-- instead of bedrock: offset -61 puts vanilla water y=62 at dest 1 and a
-- base's sea-level floor (y=63) at dest 2 -- one block above the water.
-- Bedrock then lands at -125 instead of -128, which is underground and
-- invisible. Used below only to tell "this is an overworld import" apart
-- from a Nether/End band (whose dest_y_offset is a wildly different,
-- much larger negative number).
local OVERWORLD_Y_CORRECTION = -61

-- Owner live report 2026-09-21 (round 29, Tactical Nuke's "hangar"
-- water): real, legitimate captured ocean water sitting right next to
-- extra water that shouldn't be there, 2 blocks higher, inside a
-- notionally-dry hangar. Same class of bug as clear_y_min's own
-- extension above, just at the TOP of the clear range instead of the
-- bottom: place_one_chunk's clear ceiling used to stop at the chunk's
-- OWN captured content (sec_y_max*16+15), so any chunk whose real
-- content doesn't reach up to Mineclonia's own natural sea level (a
-- below-sea-level/partially-submerged structure -- exactly what a
-- "hangar" built at/under the source's own sea level is) left whatever
-- the destination's mandatory pregen pass deposited there -- natural
-- ocean water at Mineclonia's OWN sea level -- untouched above the real
-- capture. This is the exact "uncleared pregen leftover" mechanism
-- gap_fill.lua's own Y-range bug already established for GAP chunks
-- (see that file's GAP_Y_MAX comment); round 26's live patch for this
-- (filling the excess water with stone) treated the symptom, not this
-- root cause, and didn't survive this round's full rebuild.
--
-- Queried from the real overworld preset (mcl_levelgen.make_overworld_
-- preset, presets.lua's own `sea_level = 63` field -- confirmed by
-- direct source read, not guessed) once at module load, not per-job or
-- per-chunk -- constructing a preset does real noise/density-function
-- setup, so this is deliberately not cheap enough to redo per chunk.
local OVERWORLD_SEA_LEVEL
do
	local ok, preset = pcall(function()
		return mcl_levelgen and mcl_levelgen.make_overworld_preset(tonumber(core.get_mapgen_setting("seed")))
	end)
	OVERWORLD_SEA_LEVEL = (ok and preset and preset.sea_level) or 63
end

-- ---------------------------------------------------------------------
-- Dimension discovery -- mirrors import_tools/anvil.py's
-- find_populated_dimensions (see IMPORT_SPEC.md). Kept here rather than
-- in lua_import/anvil.lua because step 3 scoped that module to work on a
-- single already-known dimension_path; discovering *which* one is a
-- step-4 (orchestration) concern.
-- ---------------------------------------------------------------------

local function find_populated_dimensions(world_folder)
	local results = {}
	local base = world_folder .. "/dimensions/minecraft/worlds"
	local worlds = list_dir(base, true)
	if not worlds then return results end
	for _, world_name in ipairs(worlds) do
		local world_path = base .. "/" .. world_name
		local dims = list_dir(world_path, true) or {}
		for _, dim_name in ipairs(dims) do
			local region_dir = world_path .. "/" .. dim_name .. "/region"
			local files = list_dir(region_dir, false) or {}
			local has_mca = false
			for _, f in ipairs(files) do
				if f:match("%.mca$") then
					has_mca = true
					break
				end
			end
			if has_mca then
				results[#results + 1] = {
					world_name = world_name,
					dimension_name = dim_name,
					dimension_path = world_name .. "/" .. dim_name,
				}
			end
		end
	end
	return results
end

-- Reads just the 4096-byte region-file location table, not the whole
-- (potentially multi-MB) file -- used only to build the job's chunk
-- cursor cheaply at start-up. anvil.read_region_locations only ever looks
-- at bytes 1..4096 of whatever buffer it's given, so feeding it a
-- pre-trimmed header is safe (see lua_import/anvil.lua).
local function read_region_header(path)
	for attempt = 1, 3 do
		local f = insecure.io.open(path, "rb")
		if f then
			local header = f:read(4096)
			f:close()
			if header and #header == 4096 then
				return header
			end
		end
	end
	return nil
end

-- ---------------------------------------------------------------------
-- Content id cache + fallback for any resolved node this game doesn't
-- actually have registered (e.g. a best-effort/unverified mc_to_mcl.json
-- entry that turns out wrong -- see palette_report.md's confidence notes).
-- ---------------------------------------------------------------------

local content_id_cache = {}
local warned_missing = {}
local DEFAULT_NODE = palette.DEFAULT_NODE

local function content_id_for(name)
	local id = content_id_cache[name]
	if id then return id end
	if core.registered_nodes[name] then
		id = core.get_content_id(name)
	else
		if not warned_missing[name] then
			warned_missing[name] = true
			core.log("warning", "[spawnimport] node '" .. name .. "' is not registered in this game; using "
				.. DEFAULT_NODE .. " instead")
		end
		id = content_id_cache[DEFAULT_NODE] or core.get_content_id(DEFAULT_NODE)
	end
	content_id_cache[name] = id
	return id
end

local function is_liquid(name)
	local def = core.registered_nodes[name]
	return def and def.liquidtype and def.liquidtype ~= "none"
end

-- VoxelManip writes node data directly and never calls on_construct (that's
-- the whole point -- it's what makes bulk placement fast). Container nodes
-- (chests, shulker boxes, furnaces, hoppers, dispensers/droppers) rely on
-- on_construct to initialize their metadata (inventory, formspec id, even
-- -- for chests -- swapping to a different node name entirely, see
-- mcl_chests/init.lua) -- without it they're inert: right-clicking does
-- nothing or opens a broken formspec. Confirmed as the actual cause of
-- "chests/shulkers won't open" (in-client report), not a resolver or
-- placement bug.
--
-- Neither "container" group nor "has on_construct" alone works here --
-- both tried and both confirmed wrong against live data:
--   - "container" group: mcl_chests' base/placeholder node (what this
--     mod's palette resolver actually targets, e.g. "mcl_chests:chest")
--     carries no "container" group itself -- its on_construct's whole job
--     is to *swap* to a "_small" variant node that only THEN has
--     "container" in its groups (confirmed by reading mcl_chests/init.lua's
--     register_chest -- the group is on the second core.register_node
--     call, not the first). Real mcl_chests:chest nodes came out of a live
--     test placement with zero inventory, never swapped.
--   - bare "has on_construct": matched ~3185 node types (nearly every
--     node in the game -- most define on_construct for unrelated things
--     like gravel-falling checks or particle setup) and called it 59
--     MILLION times on just the smallest base in a live test.
-- (The earlier "this crashed on mcl_core:dirt/mcl_books:bookshelf" scare,
-- from when this was still container-group-scoped, turned out to be this
-- mod's own separate bug -- passing a plain {x=,y=,z=} table where
-- mcl_redstone's opaque-neighbour-connection update calls vector methods
-- like pos:add() that need a real vector object, fixed via vector.new(...)
-- in construct_list's own comment -- not a reason either check was unsafe.)
--
-- An explicit name allowlist, verified against the real registrations
-- (mcl_chests/mcl_hoppers/mcl_dispensers/mcl_furnaces init.lua files) is
-- precise where neither generic check is: mcl_chests:chest/trapped_chest/
-- ender_chest need on_construct called directly on the placeholder name
-- (to trigger their swap); shulker boxes, furnaces, hoppers, and
-- dispensers/droppers all define on_construct on their real placed name
-- already (matched via the "container" group, which IS correct for these
-- -- just not for the chest placeholders).
--
-- 2026-09-17 owner live-test: nether portals at import looked like plain
-- stone. mcl_portals:portal has no on_construct hook that fires on its
-- own (portals register themselves via the engine's
-- register_on_placenode callback in mcl_portals/init.lua's
-- register_portal_placenode -- triggered by the normal player-place-item
-- path, NOT by VoxelManip bulk writes). Without registration the portal
-- renders as a nodebox but is functionally inert AND may not animate.
-- Add mcl_portals:portal to the explicit list so the post-placement
-- on_construct sweep calls its hook.
local CHEST_PLACEHOLDERS = {
	["mcl_chests:chest"] = true,
	["mcl_chests:trapped_chest"] = true,
	["mcl_chests:ender_chest"] = true,
	["mcl_portals:portal"] = true,
}
-- Mirror of mcl_chests' formspec_shulker_box() (mods/ITEMS/mcl_chests/
-- init.lua): a shulker's inventory UI lives in NODE META "formspec",
-- written by set_shulkerbox_meta() from after_place_node() -- which never
-- fires for a VoxelManip bulk write. Owner report 2026-09-25 "Shulkers in
-- Tactical are not opening": probed every imported shulker at the base --
-- formspec_len=0, so right-click animates the lid and opens nothing.
-- Chests are unaffected (they call core.show_formspec directly in
-- on_rightclick); shulkers rely on the engine's node-meta formspec.
local function shulker_formspec(name)
	local parts = {
		"formspec_version[4]",
		"size[11.75,10.425]",
		"label[0.375,0.375;" .. core.formspec_escape(name or "") .. "]",
	}
	if mcl_formspec and mcl_formspec.get_itemslot_bg_v4 then
		parts[#parts + 1] = mcl_formspec.get_itemslot_bg_v4(0.375, 0.75, 9, 3)
	end
	parts[#parts + 1] = "list[context;main;0.375,0.75;9,3;]"
	parts[#parts + 1] = "label[0.375,4.7;Inventory]"
	if mcl_formspec and mcl_formspec.get_itemslot_bg_v4 then
		parts[#parts + 1] = mcl_formspec.get_itemslot_bg_v4(0.375, 5.1, 9, 3)
	end
	parts[#parts + 1] = "list[current_player;main;0.375,5.1;9,3;9]"
	if mcl_formspec and mcl_formspec.get_itemslot_bg_v4 then
		parts[#parts + 1] = mcl_formspec.get_itemslot_bg_v4(0.375, 9.05, 9, 1)
	end
	parts[#parts + 1] = "list[current_player;main;0.375,9.05;9,1;]"
	parts[#parts + 1] = "listring[context;main]"
	parts[#parts + 1] = "listring[current_player;main]"
	return table.concat(parts)
end

local function needs_construct(name)
	return CHEST_PLACEHOLDERS[name] or core.get_item_group(name, "container") > 0
end

-- ---------------------------------------------------------------------
-- Job: one /worldplace run, processed a bounded amount at a time from
-- core.register_globalstep so a multi-million-block import never blocks
-- the server in one call. Granularity is one source Minecraft chunk
-- (16x16xfull-height) per unit of work -- see README.md's "How placement
-- is batched" for why.
-- ---------------------------------------------------------------------

local Job = {}
Job.__index = Job

local function new_job(p)
	local self = setmetatable({}, Job)
	self.player_name = p.player_name
	self.world_folder = p.world_folder
	self.dimension_path = p.dimension_path
	self.name = p.name
	self.anchor_x = p.anchor_x
	self.anchor_z = p.anchor_z
	self.origin_x = p.origin_x
	self.origin_z = p.origin_z
	-- Added to every placed block's Y (and to the VoxelManip bounds below) --
	-- 0 for ordinary overworld imports (unchanged default), non-zero when a
	-- caller (the museum batch driver) is placing a Nether/End-sourced
	-- capture into Mineclonia's corresponding Y-band, since Mineclonia has
	-- no separate dimensions -- Nether/End are just other Y ranges in the
	-- same coordinate space (mods/CORE/mcl_init/init.lua).
	self.dest_y_offset = p.dest_y_offset or 0
	self.status = "running"
	self.started_at = os.time()

	-- Chunk-coordinate rectangle (not block coordinates) to filter the
	-- cursor list against, set by museum_survey.py's find_primary_component
	-- when a base's raw captured extent includes travel-corridor chunks
	-- far outside its actual build (confirmed against real WDL repo data --
	-- see that function's docstring). nil means "no filtering" (every
	-- /worldplace call, and any museum manifest entry that didn't need
	-- trimming).
	self.chunk_bounds = p.chunk_bounds

	self.cursor_list = {}
	-- p.region_dir lets a caller that already resolved the exact region
	-- directory (a survey pass that's already handled WorldTools-nested vs.
	-- flat-vanilla vs. DIM-1/DIM1 layouts) skip reconstruction here.
	local region_dir = p.region_dir or anvil.region_dir(self.world_folder, self.dimension_path)
	-- 2026-09-18 round 6: real entity data (item frames, villagers, other
	-- mobs -- anything that isn't a block or a block-entity) lives in a
	-- SEPARATE `entities/` directory, a sibling of `region/`, that
	-- Minecraft 1.17+ splits entity data into. Confirmed this directory
	-- genuinely exists in this corpus's real captures (checked directly:
	-- `ls ".../Tactical Nuke .../"` shows `data`, `entities`, `level.dat`,
	-- `region` as siblings) and was never read by any part of this
	-- pipeline before now -- see anvil.lua's decode_chunk_item_frames
	-- header comment for the full story. Same sibling-substitution
	-- approach as region_dir itself (not reconstructed from
	-- world_folder/dimension_path, which doesn't reliably handle this
	-- corpus's WorldTools-nested/flat-vanilla layout variance) --
	-- pcall-guarded everywhere it's used below since a capture that
	-- genuinely has no entities/ folder (or an empty one) must not fail
	-- the whole import.
	self.entities_dir = region_dir:gsub("/region$", "/entities")
	self.entities_region_cache = {}
	-- Same sibling-directory story, for real per-map pixel-color data
	-- (map_<id>.dat files -- see lua_import/mapdata.lua). Also a direct
	-- sibling of region/entities in this corpus's real capture layout.
	self.data_dir = region_dir:gsub("/region$", "/data")
	local files = anvil.list_region_files(region_dir)
	for _, fpath in ipairs(files) do
		local header = read_region_header(fpath)
		if header then
			local region_x, region_z = anvil.region_coords_from_filename(fpath)
			local locations = anvil.read_region_locations(header)
			for _, loc in ipairs(locations) do
				local include = true
				if self.chunk_bounds then
					local chunk_x = region_x * 32 + loc.local_x
					local chunk_z = region_z * 32 + loc.local_z
					include = chunk_x >= self.chunk_bounds.x_min and chunk_x <= self.chunk_bounds.x_max
						and chunk_z >= self.chunk_bounds.z_min and chunk_z <= self.chunk_bounds.z_max
				end
				if include then
					self.cursor_list[#self.cursor_list + 1] = { region_path = fpath, offset = loc.offset }
				end
			end
		else
			core.log("error", "[spawnimport] could not read region header: " .. fpath)
		end
	end
	-- Gap-fill ("merge chunk"): optional -- only runs when the caller
	-- (the museum batch driver, see museum_manifest.json's footprint_path
	-- field) provides a pre-computed per-chunk footprint
	-- (import_tools/placement_fit/source_footprint.lua's output). Missing
	-- footprint = no gap-fill for this base, not a failure -- real imports
	-- must keep working without it. The ring of chunks to fill is decided
	-- here (cheap, footprint-only); the merge FIELD is solved later, after
	-- pre-generation, when the generated map can be read (gap_fill.
	-- build_plan from Job:step on the first gap chunk).
	self.gap_fill_chunks = nil
	self.gap_real = nil
	self.gap_plan = nil
	self.gap_avoid = {}
	if p.footprint_path and self.chunk_bounds then
		local real = gap_fill.load_real_heights(p.footprint_path)
		if real then
			local t0 = core.get_us_time()
			self.gap_real = real
			self.gap_fill_chunks = gap_fill.ring_chunks(self.chunk_bounds, real)
			local elapsed_s = (core.get_us_time() - t0) / 1e6
			core.log("action", string.format(
				"[spawnimport] gap-fill: %d merge (ring) chunks in %.2fs (%s)",
				#self.gap_fill_chunks, elapsed_s, self.name))
			for _, g in ipairs(self.gap_fill_chunks) do
				self.cursor_list[#self.cursor_list + 1] = { is_gap = true, cx = g.cx, cz = g.cz }
			end
			-- Widening (gap_fill.build_plan) may pull natural chunks just
			-- outside this base into the merge domain; it must never pull
			-- ANOTHER base's chunks -- give it every other base's placed
			-- footprint as a no-go area.
			for _, e in ipairs(registry.list()) do
				if e.name ~= self.name and e.bbox then
					self.gap_avoid[#self.gap_avoid + 1] = e.bbox
				end
			end
		else
			core.log("warning", "[spawnimport] gap-fill: could not load footprint " .. tostring(p.footprint_path)
				.. ", proceeding without gap-fill for " .. tostring(self.name))
		end
	end

	self.cursor_index = 1
	self.cursor_total = #self.cursor_list

	-- Pre-generate the destination volume before writing anything into it.
	--
	-- This is required for the import to survive at all, and it is not
	-- obvious: a VoxelManip write does NOT mark the blocks it creates as
	-- "generated" (src/map.cpp's blitBackAll only raises
	-- MOD_STATE_WRITE_NEEDED; setGenerated(true) happens solely on the
	-- mapgen path, src/servermap.cpp). Two separate things then go wrong
	-- for a block that isn't flagged generated:
	--
	--   1. The emerge thread runs mapgen over it (src/emerge.cpp's
	--      getBlockOrStartGen accepts a block only if isGenerated()), so
	--      Mineclonia re-generated over each imported base the first time
	--      a player flew near it -- measured at ~80% of imported blocks
	--      destroyed.
	--   2. The server never sends it to the client at all
	--      (src/server/clientiface.cpp: "if (!block->isGenerated() &&
	--      !generate) continue"), so even the surviving data renders as
	--      empty sky.
	--
	-- Forcing generation first, then overwriting, fixes both: emerge_area
	-- sets the generated flag, VoxelManip writes overwrite generated
	-- blocks by default (blitBackAll's overwrite_generated defaults to
	-- true, and Lua's write_to_map uses that default), and MapBlock's
	-- copyFrom only copies node data -- it never clears m_generated. So
	-- the blocks stay flagged generated, keep the imported content, and
	-- are never regenerated again.
	--
	-- Suppressing mapgen instead (mapgen_limit = 0) does NOT work: it
	-- stops the overwriting but also permanently blocks delivery via (2),
	-- leaving the player in empty sky. Verified in-client, not assumed.
	--
	-- CORRECTION (round 28): the comment that used to sit here claimed
	-- this world uses mg_name = singlenode (deposits nothing but air, no
	-- native terrain to seam against). That was never true for the
	-- actual deployed/playtest config -- confirmed live via map_meta.txt:
	-- `mg_name = v7`, real terrain. Wherever this comment came from
	-- (maybe true for a much earlier scratch config), it's been wrong for
	-- this whole session, and directly explains the real, confirmed
	-- water-intrusion (Tactical Nuke) and floating-fragment (Dark Souls
	-- Castle) bugs found and live-patched in earlier rounds: gap chunks
	-- (no real captured data) are NOT air, they're whatever real v7
	-- terrain the destination naturally generates there -- ocean, hills,
	-- whatever. gap_fill.lua (round 28) sculpts synthetic terrain into
	-- gap chunks instead of leaving them to this, fixing the actual root
	-- cause rather than live-patching the symptom after each rebuild.
	self.pregen_state = "pending"
	-- Gap-fill widening needs generated terrain a few chunks BEYOND the
	-- base's own dest_bbox (the merge domain can grow up to
	-- gap_fill.MAX_EXTRA_RINGS rings into natural chunks); VoxelManip
	-- writes into never-generated blocks are regenerated over and never
	-- sent to clients, so the pregen range must cover it.
	local gap_margin = self.gap_fill_chunks
		and ((gap_fill.RING + gap_fill.MAX_EXTRA_RINGS) * 16) or 0
	self.pregen_min = {
		x = p.dest_bbox.x_min - gap_margin, y = PREGEN_Y_MIN + self.dest_y_offset,
		z = p.dest_bbox.z_min - gap_margin,
	}
	self.pregen_max = {
		x = p.dest_bbox.x_max + gap_margin, y = PREGEN_Y_MAX + self.dest_y_offset,
		z = p.dest_bbox.z_max + gap_margin,
	}

	self.current_region_path = nil
	self.current_region_data = nil

	self.placed_blocks = 0
	self.placed_chunks = 0
	self.skipped_chunks = 0
	self.last_report_pct = -1
	-- X/Z are known exactly upfront (anchor + source extent, see start_job's
	-- dest_bbox) since every *captured* chunk in the footprint gets fully
	-- cleared and rewritten now, not just chunks that had non-air content
	-- (see place_one_chunk) -- so this is the real affected area from the
	-- start, not something to reconstruct from what happened to be non-air.
	self.result_bbox = {
		x_min = p.dest_bbox.x_min, x_max = p.dest_bbox.x_max,
		z_min = p.dest_bbox.z_min, z_max = p.dest_bbox.z_max,
		y_min = nil, y_max = nil, -- informational only (registry collision is X/Z-only); filled in from actual content
	}
	self.any_content = false
	-- 64-block grid of container/sign sightings -> warp target (see
	-- Job:note_interest_point).
	self.interest = {}

	return self
end

-- Records a "someone built here" signal (a container or a sign) into a
-- coarse 64-block grid, so Job:finish can pick the densest cluster as the
-- base's warp target.
--
-- A base's geometric bbox centre is a bad warp target and in the worst
-- case a useless one: WorldTools captures include the travel corridors the
-- archiver flew in along, so the bbox can be enormously larger than the
-- build. Space Valkyria III's bbox is 10111x5951 with its actual base
-- around x~6930 z~3110 -- the centre lands ~2200 blocks away in empty
-- space, which is exactly what "I warped there and found nothing" was.
-- Containers and signs are a good proxy for where people actually built,
-- and both are already being visited here, so this is nearly free.
local INTEREST_CELL = 64
function Job:note_interest_point(x, y, z)
	local key = math.floor(x / INTEREST_CELL) .. "," .. math.floor(z / INTEREST_CELL)
	local cell = self.interest[key]
	if not cell then
		cell = { n = 0, sx = 0, sy = 0, sz = 0 }
		self.interest[key] = cell
	end
	cell.n = cell.n + 1
	cell.sx = cell.sx + x
	cell.sy = cell.sy + y
	cell.sz = cell.sz + z
end

-- Centre of the densest cell, or nil if the capture had no containers or
-- signs anywhere (a pure-terrain capture -- the caller falls back).
function Job:best_interest_point()
	local best = nil
	for _, cell in pairs(self.interest) do
		if not best or cell.n > best.n then best = cell end
	end
	if not best then return nil end
	return {
		x = math.floor(best.sx / best.n + 0.5),
		y = math.floor(best.sy / best.n + 0.5),
		z = math.floor(best.sz / best.n + 0.5),
		count = best.n,
	}
end

-- Returns the decoded entities-region chunk table for (chunk_x, chunk_z),
-- or nil if there's no entities/ directory, no matching region file, or
-- that specific chunk just has no entities recorded. Caches a whole
-- entities region file's worth of decoded chunks the first time any
-- chunk from it is requested (see Job:step()'s cache-invalidation
-- comment for why this is safe/effective given how cursor_list is
-- ordered). A failure anywhere in this path (missing file, corrupt
-- region, unsupported chunk) degrades to "no entity data for this
-- chunk" rather than aborting the import -- entities are an enhancement
-- on top of the block import, not a requirement for it to succeed.
function Job:entities_chunk_for(chunk_x, chunk_z)
	if not self.entities_dir then return nil end
	local region_x = math.floor(chunk_x / 32)
	local region_z = math.floor(chunk_z / 32)
	local region_key = region_x .. "," .. region_z
	local cached = self.entities_region_cache[region_key]
	if cached == nil then
		cached = {}
		local region_path = self.entities_dir .. "/r." .. region_x .. "." .. region_z .. ".mca"
		local ok = pcall(function()
			anvil.iter_region_chunks(region_path, function(cx, cz, ch)
				cached[cx .. "," .. cz] = ch
			end)
		end)
		if not ok then cached = false end
		self.entities_region_cache[region_key] = cached
	end
	if cached == false then return nil end
	return cached[chunk_x .. "," .. chunk_z]
end

-- Real map-art rendering (2026-09-18 round 6). Decodes the real per-pixel
-- color data for one vanilla map id (see lua_import/mapdata.lua) and
-- writes it as a real .tga texture into this world's own mcl_maps/
-- folder -- the exact same file layout mcl_maps.create_map() itself
-- produces (mods/ITEMS/mcl_maps/init.lua), just sourced from decoded
-- vanilla color bytes instead of a live voxel scan. Caches per Job so a
-- map referenced by multiple item frames (a common real pattern -- a
-- whole wall of the same map for redundancy) only gets decoded/written
-- once. Uses its own "imported_<base>_<mc id>" id namespace rather than
-- touching mcl_maps' own mod-storage `next_id` counter -- that counter
-- is scoped to the mcl_maps mod's own storage (Luanti's mod storage is
-- per-mod, spawnimport genuinely cannot read or increment it), and the
-- id is just an opaque string key for the meta field + texture filename
-- either way, so there's no need to share the numbering space.
function Job:render_map_art(stack, mc_map_id)
	if not tga_encoder then return end
	self.map_art_cache = self.map_art_cache or {}
	local cached = self.map_art_cache[mc_map_id]
	if cached == nil then
		cached = false
		local path = self.data_dir .. "/map_" .. mc_map_id .. ".dat"
		local decoded, err = mapdata.decode_file(path)
		if decoded then
			local textures_dir = core.get_worldpath() .. "/mcl_maps/"
			core.mkdir(textures_dir)
			local id = "imported_" .. self.name:gsub("%W", "_") .. "_" .. mc_map_id
			local ok_save, save_err = pcall(function()
				tga_encoder.image(decoded.pixels):save(
					textures_dir .. "mcl_maps_map_texture_" .. id .. ".tga",
					{ compression = "RLE", color_format = "A1R5G5B5" })
			end)
			if ok_save then
				cached = {
					id = id,
					x_center = self.anchor_x + (decoded.x_center - self.origin_x),
					z_center = self.anchor_z + (decoded.z_center - self.origin_z),
					scale = decoded.scale,
				}
				self.maps_rendered = (self.maps_rendered or 0) + 1
			else
				core.log("warning", string.format(
					"[spawnimport] failed writing map art texture for map_%s.dat: %s",
					tostring(mc_map_id), tostring(save_err)))
			end
		else
			core.log("warning", string.format("[spawnimport] could not decode %s: %s", path, tostring(err)))
		end
		self.map_art_cache[mc_map_id] = cached
	end
	if not cached then return end

	local meta = stack:get_meta()
	meta:set_string("mcl_maps:id", cached.id)
	-- Real Minecraft map coverage: 128x128 pixels at 2^scale blocks per
	-- pixel, centered on xCenter/zCenter. Only x/z actually matter to
	-- mcl_maps' own marker-clamp logic (mods/ITEMS/mcl_maps/init.lua's
	-- register_globalstep never reads minp.y/maxp.y at all) -- y range
	-- here is a harmless placeholder, not load-bearing.
	local half = 64 * (2 ^ cached.scale)
	meta:set_string("mcl_maps:minp", core.pos_to_string(
		{ x = cached.x_center - half, y = 0, z = cached.z_center - half }))
	meta:set_string("mcl_maps:maxp", core.pos_to_string(
		{ x = cached.x_center + half - 1, y = 255, z = cached.z_center + half - 1 }))
	meta:set_int("date", os.time())
	if tt and tt.reload_itemstack_description then
		tt.reload_itemstack_description(stack)
	end
end

function Job:place_one_chunk(entry)
	local payload = anvil.read_chunk_payload(self.current_region_data, entry.offset)
	local chunk = nbt.parse_buffer(payload)

	if not chunk.sections or not chunk.xPos or not chunk.zPos then
		error("chunk has no sections/xPos/zPos (unsupported format?)")
	end

	-- Deterministic full chunk footprint -- NOT just where non-air blocks
	-- happened to land. A captured chunk that's mostly or entirely air
	-- (e.g. sky, or a section the capturer flew through without building
	-- anything) still needs every one of those positions explicitly
	-- cleared to air below, otherwise whatever the destination world's own
	-- mapgen put there (terrain, floating islands, trees -- see the
	-- screenshot that found this bug) stays visible right through the
	-- import instead of being replaced by "nothing," which is what the
	-- source actually had there.
	local base_x = self.anchor_x + (chunk.xPos * 16 - self.origin_x)
	local base_z = self.anchor_z + (chunk.zPos * 16 - self.origin_z)
	local sec_y_min, sec_y_max = nil, nil
	for _, section in ipairs(chunk.sections) do
		if section.Y then
			if not sec_y_min or section.Y < sec_y_min then sec_y_min = section.Y end
			if not sec_y_max or section.Y > sec_y_max then sec_y_max = section.Y end
		end
	end
	self.placed_chunks = self.placed_chunks + 1
	if not sec_y_min then
		return -- chunk has a sections list but no Y-tagged entries at all; nothing to clear or place
	end

	local xmin, xmax = base_x, base_x + 15
	local zmin, zmax = base_z, base_z + 15
	-- Clear down to the destination world's own floor, not just to the
	-- bottom of the source's allocated sections. A 1.18+ capture allocates
	-- sections down to y=-64, but Mineclonia's overworld floor is lower
	-- (mcl_vars.mg_overworld_min), and that gap is generated by
	-- Mineclonia's Lua levelgen (mcl_levelgen registers on_generated, which
	-- still fires under singlenode). Left alone it puts a slab of
	-- Mineclonia deepslate/tuff/bedrock underneath every imported base,
	-- separated from it by a 64-block air gap -- confirmed in-client and
	-- then by probing the column directly. Only overworld imports extend:
	-- a Nether/End band is a fixed-height slice of the same coordinate
	-- space, so reaching below its own floor would spill into a
	-- neighbouring band.
	--
	-- 2026-09-19: now that overworld imports use dest_y_offset =
	-- OVERWORLD_Y_CORRECTION (-64, see that constant's own comment) instead
	-- of 0, a base whose own captured data genuinely reaches real vanilla
	-- bedrock (source y=-64) already lands its clear_y_min exactly on
	-- OVERWORLD_MIN_Y after the offset -- this block becomes a no-op for
	-- those, which is correct (no extension needed, there's no gap left to
	-- fill). It still matters for any chunk whose OWN capture didn't reach
	-- that deep (sec_y_min higher than real bedrock), which would otherwise
	-- leave a smaller version of the same air-gap/floating-slab bug. The
	-- comparison has to happen in DESTINATION space (OVERWORLD_MIN_Y is a
	-- real absolute Y, clear_y_min is still source-space here, added to
	-- dest_y_offset only at the very end) -- checking `dest_y_offset ==
	-- OVERWORLD_Y_CORRECTION` (not `== 0`) is what used to just mean
	-- "this is an overworld import, not a Nether/End band" back when 0 was
	-- overworld's own offset.
	local clear_y_min = sec_y_min * 16
	if self.dest_y_offset == OVERWORLD_Y_CORRECTION and OVERWORLD_MIN_Y then
		local floor_in_source_space = OVERWORLD_MIN_Y - self.dest_y_offset
		if floor_in_source_space < clear_y_min then
			clear_y_min = floor_in_source_space
		end
	end
	local clear_y_max = sec_y_max * 16 + 15
	if self.dest_y_offset == OVERWORLD_Y_CORRECTION and PREGEN_Y_MAX then
		-- 2026-09-23 (owner-directed): clear all the way to SKY LIMIT
		-- (the full pregen range), not just to sea level. Mineclonia's
		-- v7 terrain genuinely reaches high in this seed (mountains,
		-- tall trees), so a chunk whose own captured content tops out
		-- below that would otherwise leave natural terrain floating
		-- above the placed base. Clearing bedrock->sky means the placed
		-- chunk is the ONLY thing in its 16x16 column.
		if PREGEN_Y_MAX > clear_y_max then
			clear_y_max = PREGEN_Y_MAX
		end
	end
	local ymin, ymax = clear_y_min + self.dest_y_offset, clear_y_max + self.dest_y_offset

	local bx, by, bz, bn, bp2 = {}, {}, {}, {}, {}
	local n = 0
	anvil.decode_chunk_blocks(chunk, function(x, y, z, name, props)
		n = n + 1
		bx[n] = self.anchor_x + (x - self.origin_x)
		by[n] = y + self.dest_y_offset
		bz[n] = self.anchor_z + (z - self.origin_z)
		local resolution = palette.resolve_detailed(name, props)
		bn[n] = resolution.node
		bp2[n] = resolution.param2
	end)

	local vm = core.get_voxel_manip()
	local emin, emax = vm:read_from_map({ x = xmin, y = ymin, z = zmin }, { x = xmax, y = ymax, z = zmax })
	local area = VoxelArea:new({ MinEdge = emin, MaxEdge = emax })
	-- Start from what the map actually holds, and clear ONLY this chunk's
	-- own 16x16 footprint -- never the whole emerged volume.
	--
	-- read_from_map expands its area out to whole mapblocks, so emin/emax
	-- routinely cover more than this chunk: a base whose anchor isn't
	-- 16-aligned makes every chunk straddle two mapblocks per misaligned
	-- axis. write_to_map then writes that entire emerged volume back, so
	-- blanket-filling it with air erased the neighbouring chunk's
	-- already-placed blocks -- each chunk wiping the strip its neighbour
	-- had just written. Confirmed as the cause of the evenly-spaced
	-- parallel strips of terrain separated by full-height air canyons seen
	-- in-client (anchor_x=-11832 is 8 past a mapblock boundary => 8-wide
	-- strips; anchor_z=11568=16*723 is aligned, which is why the strips ran
	-- parallel along Z only and not in both axes).
	--
	-- The full-footprint clear itself is still deliberate -- see the
	-- comment on base_x above for why every position in the chunk needs
	-- explicitly setting, including the all-air ones.
	local data = vm:get_data()
	local p2data = vm:get_param2_data()
	for z = zmin, zmax do
		for y = ymin, ymax do
			local idx = area:index(xmin, y, z)
			for _ = xmin, xmax do
				data[idx] = core.CONTENT_AIR
				p2data[idx] = 0
				idx = idx + 1
			end
		end
	end
	local has_liquid = false
	local construct_list = nil
	local door_repairs = nil
	for i = 1, n do
		local idx = area:index(bx[i], by[i], bz[i])
		data[idx] = content_id_for(bn[i])
		p2data[idx] = bp2[i]
		if is_liquid(bn[i]) then has_liquid = true end
		if needs_construct(bn[i]) then
			construct_list = construct_list or {}
			-- Must be a real vector object, not a plain {x=,y=,z=} table --
			-- an on_construct that calls pos:add()/etc (as mcl_redstone's
			-- opaque-neighbour-connection update, hooked generically across
			-- many nodes not just containers, does) needs the vector
			-- metatable, and errors on a plain table without it. Confirmed
			-- as the actual crash cause (not "unsafe to call on_construct
			-- outside normal placement", which was a wrong diagnosis --
			-- every real engine-triggered on_construct call always gets a
			-- genuine vector object, this is just this mod matching that).
			construct_list[#construct_list + 1] = vector.new(bx[i], by[i], bz[i])
			self:note_interest_point(bx[i], by[i], bz[i])
		end
		local door_family, door_dir = bn[i]:match("^(mcl_doors:.-)_b_(%d)$")
		if door_family and by[i] < ymax then
			door_repairs = door_repairs or {}
			door_repairs[#door_repairs + 1] = {
				idx = area:index(bx[i], by[i] + 1, bz[i]),
				name = door_family .. "_t_" .. door_dir,
				param2 = bp2[i],
			}
		end
	end

	-- Repair door bottoms whose upper half the capture lost.
	--
	-- A Minecraft door is always two blocks, but these captures do not
	-- always contain both: Ponponheads has 6 of 10 door bottoms with plain
	-- air where 'half=upper' should be (verified by decoding the source
	-- chunks directly -- it is missing in the .mca file, not dropped by
	-- this importer, and other bases in the same batch are perfectly
	-- paired). A lone bottom renders as a half-height door, which is the
	-- "glitched block" this looked like in-client.
	--
	-- Only fills genuine air, so a real captured block above a door is
	-- never overwritten. Mineclonia pairs the halves with the same
	-- door_dir and the same param2 (mcl_doors/api_doors.lua's set_node
	-- calls), which is what this mirrors.
	if door_repairs then
		for _, d in ipairs(door_repairs) do
			if data[d.idx] == core.CONTENT_AIR then
				data[d.idx] = content_id_for(d.name)
				p2data[d.idx] = d.param2
				self.doors_repaired = (self.doors_repaired or 0) + 1
			end
		end
	end

	vm:set_data(data)
	vm:set_param2_data(p2data)
	vm:write_to_map(true) -- recalculate lighting; see README.md if imports need to go faster
	if has_liquid then vm:update_liquids() end
	vm:close()

	-- Must run after vm:close() -- on_construct may itself call
	-- core.set_node/get_meta, which need the VoxelManip's own write to have
	-- already landed in the map.
	if construct_list then
		for _, pos in ipairs(construct_list) do
			local node = core.get_node(pos)
			local def = core.registered_nodes[node.name]
			if def and def.on_construct then
				local ok, err = pcall(def.on_construct, pos)
				if not ok then
					core.log("warning", string.format(
						"[spawnimport] on_construct failed for %s at (%d,%d,%d): %s",
						node.name, pos.x, pos.y, pos.z, tostring(err)))
				end
			end
			-- Real bug found live (2026-09-18, owner: "all these shulker
			-- boxes on the ground remain completely empty" -- checked 6 in
			-- Fort Alcazar, all empty; later confirmed to reproduce in
			-- cutecurly's City too, so not base-specific). Root cause,
			-- confirmed by reading mods/ITEMS/mcl_chests/init.lua AND by a
			-- live check (a freshly-imported shulker's inventory
			-- `get_size("main")` really is 0): a shulker box's "main"
			-- inventory list is only ever sized by
			-- set_inventory_and_meta_from_stack(), which mcl_chests calls
			-- exclusively from after_place_node() -- a callback that fires
			-- for a real player/item placement but NEVER for a VoxelManip
			-- bulk write, and never for a plain core.set_node()-triggered
			-- on_construct either (confirmed: neither the big-placeholder's
			-- nor the "_small" variant's own on_construct calls
			-- inv:set_size anywhere). Chests don't have this problem --
			-- mcl_chests' chest on_construct calls inv:set_size("main", 27)
			-- unconditionally; shulker's on_construct only creates the
			-- visual entity, because a real shulker box is expected to
			-- always arrive via after_place_node with its own carried
			-- inventory to restore. Without this, museumloot's later fill
			-- pass calls inv:is_empty("main") (vacuously true for a
			-- zero-size list) and tries to fill it, but every
			-- inv:set_stack("main", i, ...) into a zero-size list silently
			-- no-ops -- no error, nothing stored, and the formspec still
			-- renders a normal-looking 27-slot shulker UI (the formspec
			-- template doesn't care about the backing list's declared
			-- size), so the emptiness wasn't visible in any rebuild log.
			local post_node = core.get_node(pos)
			if core.get_item_group(post_node.name, "shulker_box") > 0 then
				local meta = core.get_meta(pos)
				local inv = meta:get_inventory()
				if inv:get_size("main") == 0 then
					inv:set_size("main", 27)
				end
				-- and the UI itself (see shulker_formspec's header)
				if meta:get_string("formspec") == "" then
					meta:set_string("formspec",
						shulker_formspec(meta:get_string("name")))
				end
			end
		end
	end

	-- Sign text lives in the chunk's block_entities, not the block palette
	-- decode_chunk_blocks reads above -- see anvil.decode_chunk_signs.
	if mcl_signs then
		local ok_signs, signs = pcall(anvil.decode_chunk_signs, chunk)
		if ok_signs then
			for _, s in ipairs(signs) do
				-- Real vector object, not a plain table -- see the matching
				-- comment on construct_list above for why that matters.
				local pos = vector.new(
					self.anchor_x + (s.x - self.origin_x),
					s.y + self.dest_y_offset,
					self.anchor_z + (s.z - self.origin_z)
				)
				local node = core.get_node(pos)
				if core.get_item_group(node.name, "sign") >= 1 then
					core.get_meta(pos):set_string("utext", core.serialize(mcl_signs.string_to_ustring(s.text)))
					mcl_signs.update_sign(pos)
					self:note_interest_point(pos.x, pos.y, pos.z)
				end
			end
		end
	end

	-- Real entity data (item frames, mobs -- anything that was never a
	-- block or block-entity) lives in a SEPARATE entities/*.mca region
	-- file at the SAME chunk coordinates -- see anvil.lua's
	-- decode_chunk_item_frames header comment and Job:entities_chunk_for
	-- above for the full story. nil if this base has no entities/
	-- directory, or this specific chunk has no entities.
	local entities_chunk = self:entities_chunk_for(chunk.xPos, chunk.zPos)

	-- Item frames -- both post-1.14 block-entity form (checked against
	-- `chunk`, the block region's own chunk -- kept for defensiveness,
	-- though real vanilla Minecraft never actually uses this form) and
	-- entity form (checked against `entities_chunk` -- the real, only
	-- form that actually fires against genuine capture data). Results
	-- from both are merged since decode_chunk_item_frames returns the
	-- same shape either way.
	-- The chunk's block palette VoxelManip just wrote didn't include
	-- frame nodes (frames are non-solid; we clear their cell to air),
	-- so set_node the frame node here, place the held item, and let
	-- mcl_itemframes.update_entity() draw the visual. We default the
	-- wallmounted param2 to whatever the dominant orientation among
	-- this base's entity-form frames was, so a wall of map-art frames
	-- all face the same direction rather than scattering to 6 random
	-- orientations.
	if mcl_itemframes then
		local frames = {}
		local ok_f1, frames_block = pcall(anvil.decode_chunk_item_frames, chunk)
		if ok_f1 then
			for _, f in ipairs(frames_block) do frames[#frames + 1] = f end
		end
		if entities_chunk then
			local ok_f2, frames_ent = pcall(anvil.decode_chunk_item_frames, entities_chunk)
			if ok_f2 then
				for _, f in ipairs(frames_ent) do frames[#frames + 1] = f end
			end
		end
		do
			for _, f in ipairs(frames) do
				local pos = vector.new(
					self.anchor_x + (f.x - self.origin_x),
					f.y + self.dest_y_offset,
					self.anchor_z + (f.z - self.origin_z)
				)
				local node_name = f.glow and "mcl_itemframes:glow_frame" or "mcl_itemframes:frame"
				local here = core.get_node(pos)
				-- Frame nodes are non-solid (slim selection box) so the
				-- VoxelManip clear above left this cell as air, and the
				-- captured blocks nearby wouldn't have written into it
				-- (frame block-entity position is on the support face,
				-- not inside any block). We still gate on air as a
				-- safety check -- the importer is shared across all
				-- 13 GB of the corpus and we'd rather drop a frame than
				-- blow away a captured block.
				if here.name == "air" or here.name == "ignore" or core.get_item_group(here.name, "itemframe") >= 1 then
					-- Owner explicit 2026-09-19 round 7 (live report):
					-- "some of the item frames are not attached to their
					-- respective blocks and are floating in front of
					-- them" -- root cause: this used to apply a single
					-- job-wide "dominant" facing (the most common
					-- direction among all this base's entity-form
					-- frames) to EVERY frame, so any frame whose real
					-- support wall faced a different direction got the
					-- WRONG wallmounted param2 -- mcl_itemframes' node is
					-- a mesh with paramtype2="wallmounted", so a wrong
					-- param2 rotates/positions the whole mesh (and its
					-- flat selection/collision box) against the wrong
					-- axis, which is exactly what "floating in front of
					-- the block" looks like. Now uses each frame's own
					-- REAL captured Facing, converted via
					-- ITEM_FRAME_FACING_TO_WALLMOUNTED (see that table's
					-- own comment for the verified-elsewhere-in-this-
					-- project reasoning for not inverting it). Falls
					-- back to wallmounted 4 (south-facing, matches
					-- FACING_TO_WALLMOUNTED's own "north" example
					-- convention loosely) only for the block-entity-form
					-- path, which has no `facing` field at all (and, per
					-- decode_chunk_item_frames' own header comment, has
					-- never been observed to fire against real data
					-- anyway).
					local param2 = ITEM_FRAME_FACING_TO_WALLMOUNTED[f.facing] or 4
					core.set_node(pos, { name = node_name, param2 = param2 })
					local inv = core.get_meta(pos):get_inventory()
					inv:set_size("main", 1)
					if f.itemstring and f.itemstring ~= "" then
						local mcl_item = items.resolve(f.itemstring)
						if mcl_item and core.registered_items[mcl_item] then
							local stack = ItemStack(mcl_item)
							-- Vanilla itemframes store ItemRotation as
							-- 0..15; Mineclonia wants the yaw in
							-- radians on the held item's meta "rotation"
							-- field. Per-octant = pi/8.
							local yaw_rad = (f.item_rotation * math.pi / 8) % (2 * math.pi)
							stack:get_meta():set_float("rotation", yaw_rad)
							-- Captured Item Count for items sitting in
							-- frames is normally 1; anything else is
							-- almost never meaningful on a frame.
							stack:set_count(1)
							-- Real map art (2026-09-18 round 6): a filled
							-- map's actual pixel content lives in a
							-- separate data/map_<id>.dat file (real map
							-- id carried on f.map_id, decoded in
							-- anvil.decode_chunk_item_frames from the
							-- item's own tag.map or components["minecraft:
							-- map_id"] field -- see that function's own
							-- comment on the 1.20.5 NBT/components split),
							-- NOT anything items.resolve() could ever
							-- produce on its own (that only maps the bare
							-- itemstring "minecraft:filled_map" -> "mcl_
							-- maps:filled_map", a template item with no
							-- real image). See Job:render_map_art below
							-- for the decode+render+meta-tagging.
							--
							-- Real bug found and fixed 2026-09-19 (round
							-- 21, cutecurly's City -- owner live report:
							-- "the item frame shows a map item object in
							-- the frame rather than showing the map"):
							-- this unconditionally placed the filled_map
							-- stack regardless of whether render_map_art
							-- (or the f.map_id extraction before it) ever
							-- actually succeeded. A stack with no real
							-- "mcl_maps:id" meta set can't be textured --
							-- mcl_itemframes falls back to rendering the
							-- item's generic wield mesh instead (see
							-- mods/ITEMS/mcl_itemframes/init.lua's
							-- update_entity: the map-texture branch only
							-- runs when self._map_id is set). Now checks
							-- the real post-render id and, on failure,
							-- leaves the frame's inventory slot empty
							-- instead of placing a permanently-broken
							-- stack -- an empty frame can still be picked
							-- up later by the mapart-gallery-fill pass
							-- (import_tools/mapart_gallery/), a broken one
							-- can't be told apart from a working one
							-- without opening it.
							local placed_ok = true
							if mcl_item == "mcl_maps:filled_map" then
								if f.map_id and mapdata then
									self:render_map_art(stack, f.map_id)
									if stack:get_meta():get_string("mcl_maps:id") == "" then
										placed_ok = false
										self.broken_map_frames = (self.broken_map_frames or 0) + 1
									end
								else
									placed_ok = false
									self.broken_map_frames = (self.broken_map_frames or 0) + 1
								end
							end
							if placed_ok then
								inv:set_stack("main", 1, stack)
							end
						elseif not items.unknown(f.itemstring) then
							items.unknown_cache[f.itemstring] = true
							core.log("warning",
								string.format("[spawnimport] item frame contains unresolvable item %q -- frame placed empty. Add the mapping to lua_import/items.lua.",
									f.itemstring))
						end
					end
					mcl_itemframes.update_entity(pos)
					self.frames_placed = (self.frames_placed or 0) + 1
				end
			end
		end
	end

	-- Mobs (2026-09-18 round 6): villagers and other real vanilla mobs,
	-- decoded from the same entities_chunk fetched above (see anvil.lua's
	-- decode_chunk_mobs). Position and species are real, decoded data;
	-- villager/wandering_trader profession is real when the capture had
	-- one set (verified mechanism: mods/ENTITIES/mobs_mc/villager.lua's
	-- own set_profession, same one mods/museumloot/mobplacement.lua
	-- already uses). Yaw is a best-effort degrees->radians conversion of
	-- the real captured Rotation[1] -- NOT independently verified against
	-- Mineclonia's own entity-yaw axis convention (a cosmetic risk at
	-- worst: a mob facing an unexpected direction, not a functional
	-- bug). Baby/child mobs are deliberately spawned as adults --
	-- mcl_mobs only applies its child scaling/texture during its own
	-- on_activate from a full internal staticdata blob (mods/ENTITIES/
	-- mcl_mobs/api.lua), and constructing a correct one from scratch
	-- risks feeding it a malformed/partial shape; safer to skip than
	-- guess at an internal format. No duplicate-spawn guard is needed
	-- here (unlike mobplacement.lua's heuristic village detection) --
	-- this is a direct one-time replay of exactly which mobs the capture
	-- recorded, during this chunk's own single placement pass.
	if entities_chunk then
		local ok_m, mobs = pcall(anvil.decode_chunk_mobs, entities_chunk)
		if ok_m then
			for _, m in ipairs(mobs) do
				local target_id = MOB_ID_MAP[m.mc_id]
				if target_id and core.registered_entities[target_id] then
					local pos = vector.new(
						self.anchor_x + (m.x - self.origin_x),
						m.y + self.dest_y_offset,
						self.anchor_z + (m.z - self.origin_z)
					)
					-- Owner explicit 2026-09-19 round 9 (live report,
					-- real server errors): "suspiciously large amount of
					-- objects detected: 373/314/466/652 ... removing all
					-- of them." This is Luanti's own real anti-DoS
					-- safety cutoff (src/mapblock.cpp, default
					-- `max_objects_per_block` = 256) -- and it doesn't
					-- gracefully thin the crowd, it deletes EVERY object
					-- in that mapblock outright, including any
					-- legitimate villagers unlucky enough to share it.
					-- Root cause: real 2b2t bases commonly have
					-- purpose-built mob farms/grinders that
					-- intentionally concentrate hundreds of real mobs in
					-- one small room -- a real, faithful replay of the
					-- capture's exact positions reproduces that exact
					-- density. Removing hostile mobs (round 8) already
					-- eliminates the specific case in this report (mob
					-- farms are built from hostile mobs), but a dense
					-- real animal pen/breeder could trigger the same
					-- engine cutoff for passive mobs -- added a real
					-- defensive density cap here so this job can never
					-- reproduce that crash regardless of what the source
					-- data concentrates: track how many mobs this job has
					-- already placed per 16x16x16 mapblock (the same
					-- unit Luanti's own check uses) and skip spawning
					-- once a mapblock hits a small cap, well under both
					-- the engine's hard 256 limit and anything that
					-- would actually be laggy to look at.
					local MOB_DENSITY_CAP = 12
					local mb_key = math.floor(pos.x / 16) .. "," .. math.floor(pos.y / 16) .. "," .. math.floor(pos.z / 16)
					self.mapblock_mob_count = self.mapblock_mob_count or {}
					local mb_count = self.mapblock_mob_count[mb_key] or 0
					local here = core.get_node(pos)
					if mb_count < MOB_DENSITY_CAP and (here.name == "air" or here.name == "ignore") then
						local obj = core.add_entity(pos, target_id)
						if obj then
							obj:set_yaw(math.rad(m.yaw_deg or 0))
							local ent = obj:get_luaentity()
							if ent then
								if ent.set_profession and m.profession
										and m.profession ~= "minecraft:none" and m.profession ~= "minecraft:nitwit" then
									local prof = m.profession:match("^minecraft:(.+)$")
									if prof then pcall(ent.set_profession, ent, prof) end
								end
								-- Despawn immunity, same real mechanism
								-- mods/museumloot/mobplacement.lua's own
								-- make_persistent() already established
								-- and documented in detail (verified
								-- against mods/ENTITIES/mcl_mobs/
								-- spawning.lua's despawn_allowed()): most
								-- mob categories (all "monster"-category
								-- ones, i.e. most of MOB_ID_MAP's hostile
								-- entries) default `can_despawn = true`
								-- and WILL vanish on their own despawn
								-- timer without this -- an empty-string
								-- nametag does NOT count, a real non-empty
								-- one is required. These are the base's
								-- own real captured mobs (not placed loot
								-- guards), so a plain species label
								-- (registered description, or the bare
								-- mobs_mc:<name> id as a fallback) rather
								-- than mobplacement.lua's anarchy-culture
								-- flavor names.
								ent.can_despawn = false
								ent.persistent = true
								if ent.set_nametag then
									local label
									if target_id == "mobs_mc:villager" then
										-- 2026-09-19 owner explicit (round
										-- 14): "Villagers inside the city
										-- shouldn't have custom names.
										-- Maybe pull a list of 500 male and
										-- female names and pick one." Every
										-- villager previously got the SAME
										-- literal nametag ("Villager", the
										-- registered species description)
										-- -- reads as if they're all one
										-- individual repeated, not a real
										-- population.
										--
										-- Round 19 owner correction: a pure
										-- per-position hash pick (as this
										-- used to be) draws independently
										-- for each villager, so with ~200
										-- names and dozens of villagers per
										-- base, real collisions are
										-- expected by the birthday paradox
										-- -- confirmed live, 3 villagers
										-- standing near each other were all
										-- named "Jennifer". Fixed: a
										-- deterministically-shuffled
										-- per-JOB (per-base) name order,
										-- assigned sequentially as
										-- villagers are placed, so no name
										-- repeats within a base until the
										-- entire pool is exhausted (never
										-- happens in practice -- bases have
										-- at most a few dozen real captured
										-- villagers, the pool has ~200
										-- names). Still fully deterministic
										-- across re-runs: the shuffle is
										-- seeded from the job's own base
										-- name (stable), and villagers are
										-- enumerated in the same stable
										-- order every run.
										if not self.villager_name_order then
											local shuffle_pr = PcgRandom(pos_seed_for_name(self.name or "base"))
											local order = {}
											for i = 1, #VILLAGER_NAME_POOL do order[i] = VILLAGER_NAME_POOL[i] end
											for i = #order, 2, -1 do
												local j = shuffle_pr:next(1, i)
												order[i], order[j] = order[j], order[i]
											end
											self.villager_name_order = order
											self.villager_name_index = 0
										end
										self.villager_name_index = self.villager_name_index + 1
										local idx = ((self.villager_name_index - 1) % #self.villager_name_order) + 1
										label = self.villager_name_order[idx]
									else
										-- 2026-09-19 (round 25, owner request): generic
										-- wildlife nametags ("Cow", "Sheep", ...) were
										-- reading as if every animal were a named
										-- player/pet -- annoying at scale. Owner's own
										-- suggestion, confirmed correct against the
										-- installed game's despawn check (mcl_mobs/
										-- spawning.lua:66, `self.nametag ~= ""` -- a
										-- strict non-empty-string test, not a trim/
										-- whitespace check): a single space satisfies
										-- the despawn-immunity requirement above
										-- without rendering as visible text.
										label = " "
									end
									ent:set_nametag(label)
								end
							end
							self.mobs_placed = (self.mobs_placed or 0) + 1
							self.mapblock_mob_count[mb_key] = mb_count + 1
						end
					end
				end
			end
		end
	end

	self.placed_blocks = self.placed_blocks + n

	if n > 0 then
		self.any_content = true
		local b = self.result_bbox
		if not b.y_min or ymin < b.y_min then b.y_min = ymin end
		if not b.y_max or ymax > b.y_max then b.y_max = ymax end
	end
end

function Job:maybe_report_progress()
	if self.cursor_total == 0 then return end
	local pct = math.floor((self.cursor_index - 1) / self.cursor_total * 100)
	if pct >= self.last_report_pct + PROGRESS_EVERY_PCT then
		self.last_report_pct = pct
		core.chat_send_player(self.player_name, string.format(
			"[spawnimport] %s: %d%% (%d/%d chunks, %d blocks placed, %d skipped)",
			self.name, pct, self.cursor_index - 1, self.cursor_total, self.placed_blocks, self.skipped_chunks))
	end
end

function Job:finish()
	self.status = "done"
	local summary = string.format(
		"[spawnimport] %s: done. Placed %d blocks across %d chunks (%d chunk(s) skipped) in %ds.",
		self.name, self.placed_blocks, self.placed_chunks, self.skipped_chunks, os.time() - self.started_at)
	core.chat_send_player(self.player_name, summary)
	-- Also to the log: chat_send_player to a name that isn't connected goes
	-- nowhere at all (no log line), which makes a long unattended batch
	-- import effectively unobservable -- the only evidence it was still
	-- working was map.sqlite's mtime. Anything worth telling the player
	-- about a headless bulk import is worth putting in the logfile.
	core.log("action", summary)

	if self.doors_repaired and self.doors_repaired > 0 then
		core.log("action", string.format(
			"[spawnimport] %s: filled in %d missing door upper-half%s the capture didn't contain",
			self.name, self.doors_repaired, self.doors_repaired == 1 and "" or "s"))
	end

	if self.gap_fill_chunks then
		core.log("action", string.format(
			"[spawnimport] %s: gap-fill placed %d merge chunk(s) (ring %d + widened)",
			self.name, self.gap_chunks_placed or 0, #self.gap_fill_chunks))
	end

	-- Gap-fill audit: verify the merge came out right (seam exactness,
	-- walkable slopes, no raised water, no floating junk). Kept so
	-- /worldplace gapaudit can re-run it on demand.
	if self.gap_plan then
		last_gap = { job = self, plan = self.gap_plan }
		gap_fill.audit(self, self.gap_plan)
	end

	if self.frames_placed and self.frames_placed > 0 then
		core.log("action", string.format(
			"[spawnimport] %s: %d item frame(s) placed (per-frame real facing)",
			self.name, self.frames_placed))
	end

	if self.maps_rendered and self.maps_rendered > 0 then
		core.log("action", string.format(
			"[spawnimport] %s: %d map(s) rendered from real .dat color data",
			self.name, self.maps_rendered))
	end

	-- Round 29: this counter was tracked (incremented at both failure
	-- sites in place_one_chunk) but never actually logged anywhere,
	-- making "are map-art frames actually broken" unanswerable from the
	-- log alone -- found while investigating an owner live report of
	-- missing map art at Tactical Nuke.
	if self.broken_map_frames and self.broken_map_frames > 0 then
		core.log("action", string.format(
			"[spawnimport] %s: %d map item frame(s) left empty (map .dat missing/undecodable or unresolved map id)",
			self.name, self.broken_map_frames))
	end

	if self.mobs_placed and self.mobs_placed > 0 then
		core.log("action", string.format(
			"[spawnimport] %s: %d mob(s) placed from captured entity data",
			self.name, self.mobs_placed))
	end

	if not self.any_content then
		core.chat_send_player(self.player_name,
			"[spawnimport] warning: no non-air blocks were placed anywhere (every captured chunk was empty or " ..
			"failed) -- still registering the cleared footprint below so a later import won't overlap it.")
	end
	registry.add({
		name = self.name,
		source_folder = self.world_folder,
		dimension_path = self.dimension_path,
		anchor_x = self.anchor_x,
		anchor_z = self.anchor_z,
		dest_y_offset = self.dest_y_offset,
		bbox = self.result_bbox,
		block_count = self.placed_blocks,
		placed_at = os.time(),
		-- Where /warp should actually put a player: the densest cluster of
		-- containers/signs, not the bbox centre. nil for a capture with
		-- neither (museumwarp falls back to its own search).
		warp_target = self:best_interest_point(),
	})
end

-- Kicks off pre-generation and reports whether placing can proceed yet.
-- emerge_area is asynchronous, so the job simply parks until the final
-- callback lands (calls_remaining == 0).
function Job:pregen_ready()
	if self.pregen_state == "done" then
		return true
	end
	if self.pregen_state == "pending" then
		self.pregen_state = "running"
		self.pregen_started_at = core.get_us_time()
		core.log("action", string.format(
			"[spawnimport] %s: pre-generating destination volume (%d,%d,%d)-(%d,%d,%d) before placing",
			self.name, self.pregen_min.x, self.pregen_min.y, self.pregen_min.z,
			self.pregen_max.x, self.pregen_max.y, self.pregen_max.z))
		core.emerge_area(self.pregen_min, self.pregen_max, function(_blockpos, _action, calls_remaining)
			if calls_remaining == 0 then
				self.pregen_state = "done"
				core.log("action", string.format("[spawnimport] %s: pre-generation done in %.1fs",
					self.name, (core.get_us_time() - self.pregen_started_at) / 1e6))
			end
		end)
	end
	return false
end

function Job:step()
	if not self:pregen_ready() then return end
	local step_start = core.get_us_time()
	while self.cursor_index <= self.cursor_total do
		if self.status ~= "running" then return end
		if core.get_us_time() - step_start > STEP_BUDGET_US then return end

		local entry = self.cursor_list[self.cursor_index]
		self.cursor_index = self.cursor_index + 1

		-- Debug mode (spawnimport_gap_only = true): skip real chunk
		-- placement entirely and only run the gap-fill merge -- a fast
		-- iteration loop for merge tuning (pregen + ring chunks only).
		if GAP_ONLY and not entry.is_gap then
			goto continue
		end

		if entry.is_gap then
			if not self.gap_plan then
				-- First gap chunk: every captured chunk is placed by now
				-- (gap entries run last), so the merge field can be solved
				-- against the real generated map. Widened chunks (when a
				-- ramp needs more room than the ring has) join the cursor
				-- here -- nothing else writes them.
				self.gap_plan = gap_fill.build_plan(self, self.gap_real, self.gap_fill_chunks,
					{ avoid = self.gap_avoid })
				-- worldgen-merge: per-column targets (WDL biome/temperature
				-- map -> Mineclonia biome, surface material, tint, snow)
				wgen_inputs.attach_targets(self, self.gap_real, self.gap_plan)
				local queued = {}
				for _, e in ipairs(self.gap_fill_chunks) do queued[e.cx .. "_" .. e.cz] = true end
				for _, key in ipairs(self.gap_plan.chunk_order) do
					if not queued[key] then
						local cx, cz = key:match("^(.-)_(.-)$")
						self.cursor_list[#self.cursor_list + 1] = {
							is_gap = true, cx = tonumber(cx), cz = tonumber(cz),
						}
						self.cursor_total = self.cursor_total + 1
					end
				end
				-- GROW phase: engine-native vegetation on the finished
				-- surface, queued AFTER every write entry so the terrain is
				-- final before any tree is planted (PLAN-worldgen-merge.md
				-- §3.4 -- this ordering is the whole point).
				for _, key in ipairs(self.gap_plan.chunk_order) do
					local cx, cz = key:match("^(.-)_(.-)$")
					self.cursor_list[#self.cursor_list + 1] = {
						is_gap = true, is_grow = true, cx = tonumber(cx), cz = tonumber(cz),
					}
					self.cursor_total = self.cursor_total + 1
				end
			end
			local ok, err
			if entry.is_grow then
				ok, err = pcall(wgen_write.grow_chunk, self, self.gap_plan, entry)
			else
				ok, err = pcall(wgen_write.place_chunk, self, self.gap_plan, entry, content_id_for)
			end
			if ok then
				self.gap_chunks_placed = (self.gap_chunks_placed or 0) + 1
			else
				self.skipped_chunks = self.skipped_chunks + 1
				core.log("warning", string.format(
					"[spawnimport] gap-fill chunk placement failed (%d,%d): %s", entry.cx, entry.cz, tostring(err)))
			end
			self:maybe_report_progress()
			goto continue
		end

		local region_ready = entry.region_path == self.current_region_path
		if not region_ready then
			local data, err = anvil.read_file(entry.region_path)
			if data then
				self.current_region_data = data
				self.current_region_path = entry.region_path
				region_ready = true
				-- Moving to a new block region file almost always means
				-- moving to a new entities region file too (block and
				-- entities regions share the same r.X.Z coordinate grid) --
				-- drop the cache rather than let it grow unbounded across
				-- however many hundred region files a large base has.
				self.entities_region_cache = {}
			else
				core.log("error", "[spawnimport] could not read " .. entry.region_path .. ": " .. tostring(err))
			end
		end

		if region_ready then
			local ok, err = pcall(Job.place_one_chunk, self, entry)
			if not ok then
				self.skipped_chunks = self.skipped_chunks + 1
				core.log("warning", string.format("[spawnimport] chunk decode/place failed (%s offset %d): %s",
					entry.region_path, entry.offset, tostring(err)))
			end
		else
			self.skipped_chunks = self.skipped_chunks + 1
		end

		self:maybe_report_progress()
		::continue::
	end
	self:finish()
end

local active_job = nil

core.register_globalstep(function(_dtime)
	if active_job and active_job.status == "running" then
		active_job:step()
		if active_job.status ~= "running" then
			active_job = nil
		end
	end
end)

-- ---------------------------------------------------------------------
-- Chat command
-- ---------------------------------------------------------------------

local function handle_list()
	local entries = registry.list()
	if #entries == 0 then
		return true, "[spawnimport] no bases placed yet"
	end
	local lines = { "[spawnimport] placed bases:" }
	for _, e in ipairs(entries) do
		lines[#lines + 1] = string.format("  %s -- x[%d,%d] z[%d,%d], %d blocks, placed %s",
			e.name or "?", e.bbox.x_min, e.bbox.x_max, e.bbox.z_min, e.bbox.z_max,
			e.block_count or 0, os.date("%Y-%m-%d %H:%M", e.placed_at or 0))
	end
	return true, table.concat(lines, "\n")
end

local function handle_status()
	if not active_job then
		return true, "[spawnimport] no import in progress"
	end
	local j = active_job
	local pct = j.cursor_total > 0 and math.floor((j.cursor_index - 1) / j.cursor_total * 100) or 100
	return true, string.format("[spawnimport] %s: %d%% (%d/%d chunks), %d blocks placed, %d chunk(s) skipped",
		j.name, pct, j.cursor_index - 1, j.cursor_total, j.placed_blocks, j.skipped_chunks)
end

local function handle_cancel()
	if not active_job then
		return true, "[spawnimport] no import in progress"
	end
	local j = active_job
	j.status = "cancelled"
	active_job = nil
	return true, string.format(
		"[spawnimport] cancelled '%s' after %d blocks (not added to the registry since it's incomplete)",
		j.name, j.placed_blocks)
end

local function handle_gapaudit()
	if not last_gap or not last_gap.plan then
		return true, "[spawnimport] nothing to audit yet -- run an import with a footprint first"
	end
	local ok = gap_fill.audit(last_gap.job, last_gap.plan)
	return true, "[spawnimport] gap-fill audit for '" .. tostring(last_gap.job.name) .. "': "
		.. (ok and "PASS" or "FAIL") .. " (per-check numbers in the server log)"
end

-- opts (optional, used by the museum batch driver -- see museumimport.lua):
--   region_dir      -- an already-resolved absolute region directory. When
--                       given, this bypasses the WorldTools-folder check and
--                       find_populated_dimensions entirely, so it also
--                       covers source layouts /worldplace itself can't (flat
--                       vanilla `region/`, `DIM-1`/`DIM1`) -- the caller
--                       already did that layout-specific resolution during
--                       its own survey pass.
--   dest_y_offset   -- added to every placed block's Y; see new_job().
--   skip_collision  -- when true, don't consult the registry at all
--                       (used by the batch driver, which trusts its own
--                       Python-side packing pass to already guarantee
--                       non-overlap within a dimension type, and different
--                       dimension types are Y-disjoint by construction so
--                       can never really collide regardless of X/Z).
local function start_job(player_name, world_folder, x, z, name, dimension_path_override, force, opts)
	opts = opts or {}
	if active_job and active_job.status == "running" then
		return false, "[spawnimport] an import is already in progress (" .. active_job.name ..
			"); use /worldplace status or /worldplace cancel first"
	end

	local dimension_path = dimension_path_override
	local region_dir = opts.region_dir

	if not region_dir then
		local ok_check, base_list = pcall(list_dir, world_folder .. "/dimensions/minecraft/worlds", true)
		if not ok_check or not base_list or #base_list == 0 then
			return false, "[spawnimport] '" .. world_folder ..
				"' doesn't look like a WorldTools export (no dimensions/minecraft/worlds folder found)"
		end

		if not dimension_path then
			local dims = find_populated_dimensions(world_folder)
			if #dims == 0 then
				return false, "[spawnimport] no populated dimensions found under " .. world_folder
			elseif #dims > 1 then
				local names = {}
				for _, d in ipairs(dims) do names[#names + 1] = d.dimension_path end
				return false, "[spawnimport] multiple populated dimensions found: " .. table.concat(names, ", ")
					.. " -- re-run with the dimension path as a 5th argument, e.g.: /worldplace " .. world_folder
					.. " " .. x .. " " .. z .. " " .. (name or "base") .. " " .. names[1]
			else
				dimension_path = dims[1].dimension_path
			end
		end
	end

	-- opts.origin_x/origin_z/dest_bbox let a caller that already surveyed
	-- the exact footprint (the museum batch driver, from
	-- museum_survey.py's manifest) skip re-deriving it from a fresh
	-- region-header scan here -- which matters beyond just saving work:
	-- a bare header scan has no way to know about chunk_bounds trimming
	-- (see museum_survey.py's find_primary_component), so it would
	-- recompute the untrimmed extent, corridor chunks and all.
	local origin_x, origin_z, dest_bbox = opts.origin_x, opts.origin_z, opts.dest_bbox
	if not (origin_x and origin_z and dest_bbox) then
		local extent_ok, extent
		if region_dir then
			extent_ok, extent = pcall(anvil.read_region_extent_from_dir, region_dir)
		else
			extent_ok, extent = pcall(anvil.read_region_extent, world_folder, dimension_path)
		end
		if not extent_ok then
			return false, "[spawnimport] failed to read region extent: " .. tostring(extent)
		end
		if not extent then
			return false, "[spawnimport] dimension '" .. tostring(dimension_path) .. "' has no chunks"
		end
		origin_x, origin_z = extent.block_x_min, extent.block_z_min
		dest_bbox = {
			x_min = x, x_max = x + (extent.block_x_max - extent.block_x_min),
			z_min = z, z_max = z + (extent.block_z_max - extent.block_z_min),
		}
	end

	if not force and not opts.skip_collision then
		local collision = registry.find_collision(dest_bbox)
		if collision then
			local fx, fz = registry.suggest_free_spot(x, z)
			return false, string.format(
				"[spawnimport] would collide with existing base '%s' (x[%d,%d] z[%d,%d]). " ..
				"Use '/worldplace force %s %d %d%s' to override, or try anchor (%d, %d) instead.",
				collision.name or "?", collision.bbox.x_min, collision.bbox.x_max,
				collision.bbox.z_min, collision.bbox.z_max,
				world_folder, x, z, name and (" " .. name) or "", fx, fz)
		end
	end

	local job = new_job({
		player_name = player_name,
		world_folder = world_folder,
		dimension_path = dimension_path,
		region_dir = region_dir,
		dest_y_offset = opts.dest_y_offset,
		chunk_bounds = opts.chunk_bounds,
		name = name or (world_folder:match("([^/\\]+)[/\\]?$") or "base"),
		anchor_x = x,
		anchor_z = z,
		origin_x = origin_x,
		origin_z = origin_z,
		dest_bbox = dest_bbox,
		footprint_path = opts.footprint_path, -- round 28 gap-fill prototype
	})
	active_job = job

	return true, string.format(
		"[spawnimport] starting '%s' (%s): %d chunks, anchor (%d,%d) -> x[%d,%d] z[%d,%d]. " ..
		"Runs in the background -- /worldplace status to check progress.",
		job.name, tostring(dimension_path), job.cursor_total, x, z,
		dest_bbox.x_min, dest_bbox.x_max, dest_bbox.z_min, dest_bbox.z_max)
end

core.register_chatcommand("worldplace", {
	params = "<world_folder> <x> <z> [name] [dimension_path] | list | status | cancel | gapaudit"
		.. " | force <world_folder> <x> <z> [name] [dimension_path]",
	description = "Bulk-import a WorldTools Minecraft world capture into this world "
		.. "(mapped through the spawnmasons pipeline). See the kit README.md.",
	privs = { worldplace = true },
	func = function(player_name, param)
		local tokens = {}
		for tok in param:gmatch("%S+") do
			tokens[#tokens + 1] = tok
		end

		if tokens[1] == "list" then return handle_list() end
		if tokens[1] == "status" then return handle_status() end
		if tokens[1] == "cancel" then return handle_cancel() end
		if tokens[1] == "gapaudit" then return handle_gapaudit() end

		local force = false
		local idx = 1
		if tokens[1] == "force" then
			force = true
			idx = 2
		end

		local world_folder = tokens[idx]
		local x = tonumber(tokens[idx + 1])
		local z = tonumber(tokens[idx + 2])
		local name = tokens[idx + 3]
		local dimension_path_override = tokens[idx + 4]

		if not world_folder or not x or not z then
			return false, "usage: /worldplace <world_folder> <x> <z> [name] [dimension_path]  "
				.. "(or: list | status | cancel | force <world_folder> <x> <z> [name] [dimension_path])"
		end

		return start_job(player_name, world_folder, math.floor(x), math.floor(z), name, dimension_path_override, force)
	end,
})

-- ---------------------------------------------------------------------
-- Museum batch driver: walks a JSON manifest produced by
-- import_tools/museum_survey.py (one entry per surviving base+dimension,
-- already deduped/classified/packed) and places each one via the same
-- start_job/Job machinery /worldplace uses, one at a time.
--
-- Checkpointing is intentionally stateless: "already done" is just "does
-- the registry already have an entry with this manifest entry's name",
-- so killing and restarting the server mid-batch and re-running
-- `/museumimport start <manifest>` just picks back up wherever the
-- registry says it got to -- no separate progress file to go stale.
-- ---------------------------------------------------------------------

local active_batch = nil -- { manifest=, index=, limit=, started=, player_name=, manifest_path= }

local function advance_batch()
	if not active_batch then return end
	while active_batch.index <= #active_batch.manifest do
		local entry = active_batch.manifest[active_batch.index]
		active_batch.index = active_batch.index + 1

		if not registry.find_by_name(entry.display_name) then
			if active_batch.started >= active_batch.limit then
				core.chat_send_player(active_batch.player_name, string.format(
					"[museumimport] batch limit (%d new base%s) reached, stopping with %d/%d manifest entries " ..
					"considered. Re-run '/museumimport start %s %d' (or a higher limit) to continue.",
					active_batch.limit, active_batch.limit == 1 and "" or "s",
					active_batch.index - 1, #active_batch.manifest,
					active_batch.manifest_path, active_batch.limit))
				active_batch = nil
				return
			end
			active_batch.started = active_batch.started + 1
			local ok, msg = start_job(
				active_batch.player_name,
				entry.source_base_folder or entry.source_region_dir,
				entry.dest_anchor_x, entry.dest_anchor_z,
				entry.display_name,
				entry.dimension_type,
				false,
				{
					region_dir = entry.source_region_dir,
					dest_y_offset = entry.dest_y_offset or 0,
					skip_collision = true,
					origin_x = entry.origin_x,
					origin_z = entry.origin_z,
					dest_bbox = entry.dest_bbox,
					chunk_bounds = entry.chunk_bounds,
					footprint_path = entry.footprint_path, -- round 28 gap-fill prototype
				}
			)
			core.chat_send_player(active_batch.player_name, "[museumimport] " .. tostring(msg))
			if not ok then
				-- Don't let one bad manifest entry stall the whole batch --
				-- log it and move on to the next one immediately.
				core.log("error", "[museumimport] failed to start '" .. tostring(entry.display_name) .. "': " ..
					tostring(msg))
				active_batch.started = active_batch.started - 1
			else
				return -- wait for this job to finish (see the globalstep hook below) before advancing further
			end
		end
	end
	core.chat_send_player(active_batch.player_name,
		"[museumimport] batch complete: every manifest entry is now either placed or was already placed.")
	active_batch = nil
end

-- Separate globalstep (rather than editing the one above) so advance_batch
-- -- defined below that one in this file -- doesn't need forward-declaring;
-- Luanti calls every registered globalstep each tick regardless of order.
-- Picks up exactly when the earlier globalstep notices active_job finished
-- and clears it back to nil.
core.register_globalstep(function(_dtime)
	if active_batch and not (active_job and active_job.status == "running") then
		advance_batch()
	end
end)

core.register_chatcommand("museumimport", {
	params = "start <manifest_path> [limit] | status",
	description = "Batch-drive spawnimport over a JSON manifest from museum_survey.py. " ..
		"See the kit README.md.",
	privs = { worldplace = true },
	func = function(player_name, param)
		local tokens = {}
		for tok in param:gmatch("%S+") do tokens[#tokens + 1] = tok end

		if tokens[1] == "status" then
			if not active_batch then
				return true, "[museumimport] no batch in progress" ..
					(active_job and (" (but a single job, '" .. active_job.name .. "', is running)") or "")
			end
			return true, string.format("[museumimport] batch: %d/%d manifest entries considered, %d new base(s) started " ..
				"this run (limit %d)%s",
				active_batch.index - 1, #active_batch.manifest, active_batch.started, active_batch.limit,
				active_job and (" -- currently placing '" .. active_job.name .. "'") or "")
		end

		if tokens[1] ~= "start" then
			return false, "usage: /museumimport start <manifest_path> [limit] | status"
		end

		if active_batch then
			return false, "[museumimport] a batch is already in progress; use /museumimport status"
		end
		if active_job and active_job.status == "running" then
			return false, "[museumimport] an import is already in progress (" .. active_job.name ..
				"); wait for it (or /worldplace cancel) before starting a batch"
		end

		local manifest_path = tokens[2]
		local limit = tonumber(tokens[3]) or math.huge
		if not manifest_path then
			return false, "usage: /museumimport start <manifest_path> [limit] | status"
		end

		local f = insecure.io.open(manifest_path, "rb")
		if not f then
			return false, "[museumimport] could not open manifest: " .. manifest_path
		end
		local raw = f:read("*a")
		f:close()

		local manifest, err = core.parse_json(raw, nil, true)
		if not manifest then
			return false, "[museumimport] failed to parse manifest JSON: " .. tostring(err)
		end
		if type(manifest) ~= "table" or #manifest == 0 then
			return false, "[museumimport] manifest is empty or not a JSON array"
		end

		active_batch = {
			manifest = manifest,
			index = 1,
			limit = limit,
			started = 0,
			player_name = player_name,
			manifest_path = manifest_path,
		}
		core.chat_send_player(player_name, string.format(
			"[museumimport] starting batch: %d manifest entries, limit %s new base(s) this run.",
			#manifest, limit == math.huge and "unlimited" or tostring(limit)))
		advance_batch()
		return true, "[museumimport] batch started -- /museumimport status to check progress"
	end,
})

-- This world exists to look at imported builds, and clouds (even flat 2D
-- ones -- enable_3d_clouds is a client-side toggle between flat/3D
-- rendering, not an on/off switch, and has no server-side equivalent that
-- would apply automatically here) sit right at typical build height and
-- obscure them. density=0 fully hides them for every player who joins this
-- world; see doc/lua_api.md's set_clouds for the field list.
core.register_on_joinplayer(function(player)
	player:set_clouds({ density = 0 })
end)
