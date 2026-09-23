-- Mob placement for the 2b2t museum -- a NEW pass, sibling to (not part of)
-- the chest-loot pipeline in init.lua. Spawns villagers into detected
-- villages, a wild shulker or two into detected end cities, and a witch
-- into detected witch huts, then makes every spawned mob permanent (never
-- despawns).
--
-- Wired in from init.lua's run_loot_for_base, right after stage 3 (loot
-- fill) for a base -- see the `mobplacement.spawn_mobs_for_base(...)` call
-- there. Deliberately reuses the SAME container list + structure matches
-- that structures.lua already computed for loot (no second emerge/scan of
-- the base for village/end_city -- see spawn_mobs_for_base's own comment).
-- The one exception is witch-hut detection, which needs its own bbox-wide
-- node scan (witch huts have no chest at all in vanilla Mineclonia, so no
-- container ever carries a "witch_hut" structure_match to piggy-back on --
-- see WITCH_HUT_* below).
--
-- All node/entity names below were verified against
-- /Users/dara/dev/mineclonia in this session with `grep -rn "register_node"
-- / "register_mob"` -- see the per-table comments for exactly which file.
-- This project has twice lost a day to an unverified name silently matching
-- nothing (see structures.lua's own header) -- do not add a name here
-- without grepping it for real first.

local mobplacement = {}

------------------------------------------------------------------------
-- Entity names.
------------------------------------------------------------------------
-- mobs_mc:villager -- mods/ENTITIES/mobs_mc/villager.lua:6764
--   (mcl_mobs.register_mob ("mobs_mc:villager", villager)).
-- mobs_mc:witch -- mods/ENTITIES/mobs_mc/witch.lua:391.
-- mobs_mc:shulker -- mods/ENTITIES/mobs_mc/shulker.lua:849.
--
-- mobs_mc:pillager / mobs_mc:vindicator / mobs_mc:evoker (registered at
-- pillager.lua:304, villager_vindicator.lua:276, villager_evoker.lua:553
-- respectively) are NOT used here -- see the pillager-outpost/
-- woodland-mansion detection note below. Kept as a comment, not a dead
-- local, so a future maintainer who wires up detection knows the exact
-- registered names to use.
local MOB_VILLAGER = "mobs_mc:villager"
local MOB_WITCH = "mobs_mc:witch"
local MOB_SHULKER = "mobs_mc:shulker"

------------------------------------------------------------------------
-- Despawn prevention.
------------------------------------------------------------------------
-- Verified in mods/ENTITIES/mcl_mobs/spawning.lua (this session):
--
--   function mob_class:despawn_allowed ()
--       local nametag = self.nametag and self.nametag ~= ""
--       if self.can_despawn == true then
--           if not nametag and not self.tamed and not self.persistent
--               and not self._just_portaled
--               and not self.object:get_attach () then
--               return true
--           end
--       end
--       return false
--   end
--
-- (spawning.lua:65-81). So a mob is despawn-*immune* if ANY of the
-- following holds: can_despawn ~= true, a non-empty nametag, tamed,
-- persistent, _just_portaled, or attached. Two hard-won facts from that
-- same read:
--   1. An EMPTY-STRING nametag does NOT count ("self.nametag and
--      self.nametag ~= ''" -- line 66) -- confirmed in the actual despawn
--      check, not assumed from vanilla Minecraft. We therefore always set
--      a real, non-empty nametag (see NAME_POOL below), never "".
--   2. mob defaults vary: villager_base ships can_despawn=false already
--      (mobs_mc/villager.lua:47) and so does the evoker
--      (villager_evoker.lua:23) and the shulker (shulker.lua:41) -- these
--      three never despawn even with no nametag at all. Pillager,
--      vindicator and witch do NOT ship that default (_spawn_category =
--      "monster", and mcl_mobs.register_mob's own default-resolution logic
--      at mods/ENTITIES/mcl_mobs/init.lua:381-389 falls back to
--      can_despawn=true for any "monster"-category mob without an explicit
--      override) -- witch.lua:62 confirms `can_despawn = true` explicitly.
--
-- The mechanism we replicate is taken verbatim from Mineclonia's OWN
-- mapgen witch spawner, mods/MAPGEN/mcl_structures/witch_hut.lua:14-16:
--   witch = core.add_entity(...):get_luaentity()
--   witch.can_despawn = false
-- i.e. setting the instance field directly post-spawn -- not a formspec/
-- item simulation, just the field mutation itself. We do the same
-- (`ent.can_despawn = false`, `ent.persistent = true`) for every mob we
-- spawn, unconditionally, as belt-and-suspenders even for the three mob
-- types that already default to non-despawning.
--
-- For the nametag itself we mirror the OTHER real code path: the
-- on_rightclick nametag-item handler in mods/ENTITIES/mcl_mobs/init.lua,
-- which (350-351) calls `self:set_nametag(item:get_meta():get_string
-- ("name"))` -- i.e. the real interaction just calls entity:set_nametag()
-- with the tag text. set_nametag() itself (init.lua:325-334) clamps to
-- max_name_length and calls self:update_tag() to refresh the visible
-- nametag -- calling the same method (rather than poking self.nametag
-- directly) exactly mirrors what a player's nametag item does.
local function make_persistent(ent, name)
	if not ent then return end
	ent.can_despawn = false
	ent.persistent = true
	if ent.set_nametag then
		ent:set_nametag(name)
	else
		-- Defensive fallback; every mob registered via
		-- mcl_mobs.register_mob (all of ours are) has set_nametag, so
		-- this branch shouldn't be reachable in practice.
		ent.nametag = name
	end
end

------------------------------------------------------------------------
-- Nametag pool.
------------------------------------------------------------------------
-- Per the project owner: 2b2t-culture-flavored, cheeky/edgy is fine,
-- nothing hateful or targeting real identifiable people. JUDGEMENT CALL --
-- adjust freely; these are generic anarchy-server-culture in-jokes about
-- griefing/duping/queueing/lag, not about any real named player or base.
local NAME_POOL = {
	"TotemPoppin", "DupedNotSorry", "NullCoords", "VoidWalker99",
	"ObsidianHoarder", "LagMachine", "SpawnRunner", "GriefReportPending",
	"CoordsLeaked", "AFKandProud", "BedrockBreaker", "NoTotemNoProblem",
	"YeetedFromSpawn", "PearlClutcher", "CrystalPvPMain", "DefinitelyNotXray",
	"HackedLegitTho", "BanEvasion9000", "QueueSkipper", "AltArmyGeneral",
	"ChunkBanned", "ServerSideFriend", "DupeGlitchVictim", "WardenBaitUsed",
	"NetherHighway1", "TenYearBaseOwner", "UnraidableMaybe", "KillauraSuspect",
	"CactusFarmCasualty", "EndCityLooter", "StashNotFound", "CommitsAnarchy",
	"LogoutSpotCamper", "AllegedlyLegend", "GriefedTwice", "FreshSpawnNoGear",
	"OldPlayerEnergy", "TPADeclined", "InvTooFull", "GhostOfDeadServ",
}

-- 2026-09-19 round 17 owner correction: "villager names are still not
-- normal human names like Ellie, Betty, Josh, Tristan." The round-14 fix
-- (VILLAGER_NAME_POOL in mods/spawnimport/init.lua) only covers real
-- CAPTURED villagers from the source world -- a minority. The much
-- larger population comes from THIS file's own village-repopulation
-- pass (spawn_mobs_for_base below, logged as "[museummobs] ... spawned
-- N villager(s)"), which was drawing every mob -- villagers included --
-- from the anarchy-meme NAME_POOL above ("TotemPoppin" etc.), completely
-- missing what the owner actually asked for. Villagers get a separate
-- human-name pool; shulkers/witches keep the meme pool (not "people",
-- the meme names are still an intentional, owner-approved fit for them).
-- Duplicated here rather than shared as a cross-mod global with
-- spawnimport's own copy -- small, self-contained, avoids coupling this
-- file's load order to spawnimport's.
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
	"Ellie", "Josh", "Tristan", "Zoe", "Leo", "Nora", "Owen", "Ruby",
}

-- Deterministic per-mob name pick, seeded from spawn position (+ a role
-- label so a villager and a shulker that land on hashably-similar
-- coordinates don't roll the same name) -- same seeding convention as
-- init.lua's fill_inv_from_theme (position-hash -> PcgRandom), so reruns
-- of the mob pass are stable, matching this project's existing determinism
-- rule.
local function pos_seed(pos, label)
	local label_hash = 0
	if label and label ~= "" then
		for i = 1, #label do
			label_hash = label_hash + label:byte(i) * i
		end
	end
	return math.abs(pos.x * 73856093 + pos.y * 19349663 + pos.z * 83492791
		+ label_hash * 2654435761) % 2 ^ 31
end

local function pick_name(pos, label)
	local pr = PcgRandom(pos_seed(pos, label .. "#name"))
	-- "villager" and "villager_workstation" are the two labels this file's
	-- own villager-spawning calls use (see spawn_mobs_for_base below) --
	-- everything else (shulker, witch) keeps the anarchy-meme pool.
	if label == "villager" or label == "villager_workstation" then
		return VILLAGER_NAME_POOL[pr:next(1, #VILLAGER_NAME_POOL)]
	end
	return NAME_POOL[pr:next(1, #NAME_POOL)]
end

------------------------------------------------------------------------
-- Villager professions -- workstation node/group -> profession name.
------------------------------------------------------------------------
-- Copied from mods/ENTITIES/mobs_mc/villager.lua's own (file-local, not
-- exported) `villager_professions` table (lines 1019-1137), which pairs
-- each profession with a `group` field used for POI/jobsite matching
-- (villager.lua:1156-1172's get_profession()). We reproduce the same
-- group -> profession mapping here as plain find_nodes_in_area queries
-- (exact node names where the source used a concrete node name; "group:"
-- query strings -- confirmed supported by find_nodes_in_area, see
-- /Volumes/Dara/dev/luanti/doc/lua_api.md's own find_nodes_in_area entry
-- ("nodenames: e.g. {"ignore", "group:tree"}") -- where the source used a
-- group).
--
-- Underlying node names/groups individually verified this session:
--  * mcl_blast_furnace:blast_furnace(_active) -- registered via
--    mcl_furnaces.register_furnace("mcl_blast_furnace:blast_furnace", ...)
--    at mods/ITEMS/mcl_blast_furnace/init.lua:4, which internally
--    registers both the base name and name.."_active"
--    (mods/ITEMS/mcl_furnaces/init.lua:582,606).
--  * mcl_smoker:smoker(_active) -- same pattern,
--    mods/ITEMS/mcl_smoker/init.lua:4.
--  * mcl_cartography_table:cartography_table --
--    mods/ITEMS/mcl_cartography_table/init.lua:4.
--  * mcl_fletching_table:fletching_table --
--    mods/ITEMS/mcl_fletching_table/init.lua:3.
--  * mcl_stonecutter:stonecutter -- mods/ITEMS/mcl_stonecutter/init.lua:141.
--  * mcl_loom:loom -- mods/ITEMS/mcl_loom/init.lua:189.
--  * mcl_smithing_table:table -- mods/ITEMS/mcl_smithing_table/init.lua:134.
--  * mcl_grindstone:grindstone -- mods/ITEMS/mcl_grindstone/init.lua:170.
--  * group:brewing_stand -- mods/ITEMS/mcl_brewing/init.lua:434
--    (groups = {..., brewing_stand = 1, ...} on "mcl_brewing:stand_000").
--  * group:composter -- mods/ITEMS/mcl_composters/init.lua:224-243
--    (groups = {..., composter = 1, ...}).
--  * group:barrel -- mods/ITEMS/mcl_barrels/init.lua:101-130
--    (groups = {..., barrel = 1, ...} on "mcl_barrels:barrel_closed").
--  * group:cauldron -- mods/ITEMS/mcl_cauldrons/init.lua:148-158
--    (groups = {..., cauldron = 1, ...} on the base "mcl_cauldrons:
--    cauldron"; filled variants get cauldron = 1+water_level, still > 0,
--    so "group:cauldron" catches every fill state).
--  * group:lectern -- mods/ITEMS/mcl_lectern/init.lua:35
--    (groups = {..., lectern = 1, ...}; the "_with_book" variant merges
--    the same groups table, so this also covers it).
local PROFESSION_WORKSTATIONS = {
	{ profession = "armorer", names = { "mcl_blast_furnace:blast_furnace", "mcl_blast_furnace:blast_furnace_active" } },
	{ profession = "butcher", names = { "mcl_smoker:smoker", "mcl_smoker:smoker_active" } },
	{ profession = "cartographer", names = { "mcl_cartography_table:cartography_table" } },
	{ profession = "cleric", names = { "group:brewing_stand" } },
	{ profession = "farmer", names = { "group:composter" } },
	{ profession = "fisherman", names = { "group:barrel" } },
	{ profession = "fletcher", names = { "mcl_fletching_table:fletching_table" } },
	{ profession = "leatherworker", names = { "group:cauldron" } },
	{ profession = "librarian", names = { "group:lectern" } },
	{ profession = "mason", names = { "mcl_stonecutter:stonecutter" } },
	{ profession = "shepherd", names = { "mcl_loom:loom" } },
	{ profession = "toolsmith", names = { "mcl_smithing_table:table" } },
	{ profession = "weaponsmith", names = { "mcl_grindstone:grindstone" } },
	-- "nitwit" has no poi/group in villager.lua (poi = nil, group = nil) --
	-- can never be *detected* this way, deliberately not listed. A
	-- villager with no workstation found nearby is left with no profession
	-- at all ("unemployed"/generic villager), not forced into nitwit --
	-- see spawn_villagers_for_base below.
}

local PROFESSION_SEARCH_RADIUS = 8

-- Bounds-clamped node/group search, same pattern (and same reason -- don't
-- read past what's been emerged) as structures.lua's own any_node_near.
-- Returns the nearest match's squared distance, or nil.
local function nearest_of(pos, radius, names, bounds)
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
	local best
	local r2 = radius * radius
	for _, p in ipairs(found) do
		local dx, dy, dz = p.x - pos.x, p.y - pos.y, p.z - pos.z
		local d2 = dx * dx + dy * dy + dz * dz
		if d2 <= r2 and (not best or d2 < best) then best = d2 end
	end
	return best
end

local function nearest_profession(pos, bounds)
	local best_d2, best_prof
	for _, entry in ipairs(PROFESSION_WORKSTATIONS) do
		local d2 = nearest_of(pos, PROFESSION_SEARCH_RADIUS, entry.names, bounds)
		if d2 and (not best_d2 or d2 < best_d2) then
			best_d2 = d2
			best_prof = entry.profession
		end
	end
	return best_prof
end

------------------------------------------------------------------------
-- Standable-position finder.
------------------------------------------------------------------------
-- Small deterministic offset search around a candidate center for a
-- 1-wide, 2-tall open column over solid ground -- not full pathfinding,
-- just enough to avoid spawning a villager wedged in a wall. Falls back to
-- directly above the center if nothing better is found (acceptable per
-- this task's own "reasonable approximation, not full simulation" scope).
local STAND_OFFSETS = {
	{ 0, 0 }, { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 },
	{ 1, 1 }, { -1, -1 }, { 1, -1 }, { -1, 1 },
	{ 2, 0 }, { -2, 0 }, { 0, 2 }, { 0, -2 },
}
local STAND_DY = { 0, 1, -1 }

local function is_walkable(name)
	local def = core.registered_nodes[name]
	return def ~= nil and def.walkable == true
end

local function is_open(name)
	local def = core.registered_nodes[name]
	return def ~= nil and def.walkable ~= true
end

local function find_stand_pos(center, bounds)
	for _, off in ipairs(STAND_OFFSETS) do
		for _, dy in ipairs(STAND_DY) do
			local x, z = center.x + off[1], center.z + off[2]
			local y = center.y + dy
			if x >= bounds.x_min and x <= bounds.x_max
				and z >= bounds.z_min and z <= bounds.z_max
				and y - 1 >= bounds.y_min and y + 1 <= bounds.y_max then
				local below = core.get_node({ x = x, y = y - 1, z = z }).name
				local here = core.get_node({ x = x, y = y, z = z }).name
				local above = core.get_node({ x = x, y = y + 1, z = z }).name
				if is_walkable(below) and is_open(here) and is_open(above) then
					return { x = x, y = y, z = z }
				end
			end
		end
	end
	return { x = center.x, y = center.y + 1, z = center.z }
end

------------------------------------------------------------------------
-- Dedup / idempotency.
------------------------------------------------------------------------
-- Re-running the mob pass on the same base must not double-spawn. Before
-- spawning near a candidate anchor position, check both (a) positions this
-- run has already placed a same-purpose mob at, and (b) real, already-
-- existing entities of the same registered name within radius -- (b) is
-- what makes a second run of the pass (same session or after a server
-- restart) idempotent, mirroring how the loot pass's own idempotency check
-- is "is the container already non-empty" (init.lua's fill_inv_from_theme,
-- `if inv:is_empty("main") then`) rather than any separate bookkeeping.
local function has_mob_nearby(center, radius, mob_name, placed_this_run)
	for _, p in ipairs(placed_this_run) do
		if vector.distance(p, center) <= radius then return true end
	end
	local near_min = { x = center.x - radius, y = center.y - radius, z = center.z - radius }
	local near_max = { x = center.x + radius, y = center.y + radius, z = center.z + radius }
	local objs
	if core.get_objects_in_area then
		objs = core.get_objects_in_area(near_min, near_max)
	else
		objs = core.get_objects_inside_radius(center, radius)
	end
	for _, obj in ipairs(objs or {}) do
		local ent = obj.get_luaentity and obj:get_luaentity()
		if ent and ent.name == mob_name then
			return true
		end
	end
	return false
end

------------------------------------------------------------------------
-- Clustering -- collapse many matched containers into a handful of
-- anchors, at least CLUSTER_RADIUS apart, so a 50-chest village doesn't
-- get 50 villagers.
------------------------------------------------------------------------
local function cluster_positions(positions, cluster_radius, max_clusters)
	local clusters = {}
	for _, pos in ipairs(positions) do
		local is_new = true
		for _, cl in ipairs(clusters) do
			if vector.distance(cl, pos) <= cluster_radius then
				is_new = false
				break
			end
		end
		if is_new then
			if #clusters >= max_clusters then
				is_new = false -- safety cap; see spawn_villagers_for_base
			else
				clusters[#clusters + 1] = pos
			end
		end
	end
	return clusters
end

------------------------------------------------------------------------
-- Villages.
------------------------------------------------------------------------
local VILLAGE_CLUSTER_RADIUS = 16
local MAX_MOB_CLUSTERS = 60 -- safety net against a pathological bbox (shared cap for village/end-city/witch-hut clustering)

local function spawn_villagers_for_base(containers, bounds)
	local village_positions = {}
	for _, c in ipairs(containers) do
		if c.structure_match == "village" then
			village_positions[#village_positions + 1] = c.pos
		end
	end
	local clusters = cluster_positions(village_positions, VILLAGE_CLUSTER_RADIUS, MAX_MOB_CLUSTERS)

	local placed_this_run = {}
	local total = 0
	local by_profession = {}

	for _, anchor in ipairs(clusters) do
		if not has_mob_nearby(anchor, VILLAGE_CLUSTER_RADIUS, MOB_VILLAGER, placed_this_run) then
			local profession = nearest_profession(anchor, bounds)
			local count_pr = PcgRandom(pos_seed(anchor, "village_count"))
			local count = count_pr:next(1, 3)
			-- Only the first villager at a cluster claims the detected
			-- workstation (mirrors vanilla: one job site, one employed
			-- villager) -- the rest spawn unemployed/generic.
			for i = 1, count do
				local jitter_pr = PcgRandom(pos_seed(anchor, "village_jitter_" .. i))
				local jitter = {
					x = anchor.x + jitter_pr:next(-3, 3),
					y = anchor.y,
					z = anchor.z + jitter_pr:next(-3, 3),
				}
				local stand = find_stand_pos(jitter, bounds)
				local obj = core.add_entity(stand, MOB_VILLAGER)
				if obj then
					local ent = obj:get_luaentity()
					local prof_label = "unemployed"
					if i == 1 and profession and ent.set_profession then
						ent:set_profession(profession)
						prof_label = profession
					end
					make_persistent(ent, pick_name(stand, "villager"))
					placed_this_run[#placed_this_run + 1] = stand
					total = total + 1
					by_profession[prof_label] = (by_profession[prof_label] or 0) + 1
				end
			end
		end
	end

	return total, by_profession
end

------------------------------------------------------------------------
-- Villager workstation detection -- a second, independent way to find
-- villagers, sibling to spawn_villagers_for_base's bell/composter-based
-- structure detection above.
------------------------------------------------------------------------
-- Owner explicit 2026-09-18 round 4: "Perhaps you can detect the
-- villages... by doing a query for villager specific blocks like
-- fletching table within a small radius. I.e. look for a fletching
-- table, then look for surrounding similar villager blocks like brewing
-- stand, cartography table, etc... Another option might be to spawn a
-- villager anytime these type of blocks are seen. It's likely a
-- villager would be there if there is a fletching table at all. Ideally
-- we want to load them into the trading hall, but if we can't we should
-- spawn them." Implements the explicitly-authorized simpler fallback:
-- scan the whole base bbox for ANY real workstation block
-- (PROFESSION_WORKSTATIONS above -- already real, grep-verified node/
-- group names), cluster nearby hits together (several different
-- workstations near each other read as one trading hall), and spawn one
-- matching-profession villager per cluster. Deliberately does NOT try to
-- parse an enclosed room shape ("usually this is two vertical blocks") --
-- that would need real flood-fill/pathfinding against the voxel data,
-- out of scope here, same "reasonable approximation, not full
-- simulation" scope find_stand_pos above already documents; find_stand_pos
-- is reused as-is to pick a nearby open, standable spot instead.
--
-- Runs AFTER spawn_villagers_for_base (see spawn_mobs_for_base's driver
-- below) so has_mob_nearby's real-placed-entity check also sees villagers
-- that function already placed at real bell-detected villages -- this is
-- what stops a real detected village from getting a SECOND villager here
-- just because it also has a fletching table.
local WORKSTATION_CLUSTER_RADIUS = 10
local WORKSTATION_VILLAGER_CHECK_RADIUS = 14

-- Same y-tiling approach as find_cauldrons_tiled below (duplicated
-- rather than shared since this one takes an arbitrary name list and is
-- called before that function is defined in this file).
local function find_nodes_tiled(bounds, names)
	local xspan = bounds.x_max - bounds.x_min + 1
	local zspan = bounds.z_max - bounds.z_min + 1
	local max_tile_nodes = 140000000
	local y_tile = math.max(1, math.floor(max_tile_nodes / math.max(1, xspan * zspan)))
	local found = {}
	local y = bounds.y_min
	while y <= bounds.y_max do
		local y1 = math.min(bounds.y_max, y + y_tile - 1)
		local emin = { x = bounds.x_min, y = y, z = bounds.z_min }
		local emax = { x = bounds.x_max, y = y1, z = bounds.z_max }
		local hits = core.find_nodes_in_area(emin, emax, names, false) or {}
		for _, p in ipairs(hits) do found[#found + 1] = p end
		y = y1 + 1
	end
	return found
end

local function spawn_villagers_at_workstations(bounds)
	local all_names = {}
	for _, entry in ipairs(PROFESSION_WORKSTATIONS) do
		for _, n in ipairs(entry.names) do all_names[#all_names + 1] = n end
	end
	local hits = find_nodes_tiled(bounds, all_names)
	if #hits == 0 then return 0, {} end

	local clusters = cluster_positions(hits, WORKSTATION_CLUSTER_RADIUS, MAX_MOB_CLUSTERS)
	local placed_this_run = {}
	local total = 0
	local by_profession = {}
	for _, anchor in ipairs(clusters) do
		if not has_mob_nearby(anchor, WORKSTATION_VILLAGER_CHECK_RADIUS, MOB_VILLAGER, placed_this_run) then
			local profession = nearest_profession(anchor, bounds)
			local stand = find_stand_pos(anchor, bounds)
			local obj = core.add_entity(stand, MOB_VILLAGER)
			if obj then
				local ent = obj:get_luaentity()
				local prof_label = "unemployed"
				if profession and ent.set_profession then
					ent:set_profession(profession)
					prof_label = profession
				end
				make_persistent(ent, pick_name(stand, "villager_workstation"))
				placed_this_run[#placed_this_run + 1] = stand
				total = total + 1
				by_profession[prof_label] = (by_profession[prof_label] or 0) + 1
			end
		end
	end
	return total, by_profession
end

------------------------------------------------------------------------
-- End cities -- wild shulkers.
------------------------------------------------------------------------
-- JUDGEMENT CALL: real end cities have wild shulkers as part of the
-- structure (distinct from the shulker-box containers, which
-- museumloot/init.lua's loot pass already fills via structures.lua's
-- END_CITY_LOOT). Verified in mods/ENTITIES/mobs_mc/shulker.lua that the
-- shulker mob is a real registered mob ("mobs_mc:shulker", line 849) with
-- can_despawn=false already (line 41). We spawn a modest 1 shulker per
-- detected end-city cluster (not per container) -- end cities in vanilla
-- have a handful of shulkers spread across a large structure, and our
-- detection radius (structures.lua's END_CITY_PURPUR check, 12 blocks) is
-- already much smaller than a real end city, so one per cluster is a
-- reasonable population density rather than a swarm.
local END_CITY_CLUSTER_RADIUS = 14

local function spawn_shulkers_for_base(containers, bounds, dimension)
	-- Owner live-test (2026-09-17): a shulker named "BedrockBreaker"
	-- spawned into a non-End base with end_stone around it. End-city
	-- detection was matching purple-sculk-room decorations in an overworld
	-- base. Strict dimension check: shulkers are end-only mobs in real MC,
	-- and in the captured-bases dataset the only legitimate shulker
	-- placements are in actual End dimensions. Skip on overworld/nether.
	if dimension ~= "end" then
		core.log("action", string.format(
			"[museummobs] shulker spawn skipped: base dimension=%s (end-only mob)", tostring(dimension)))
		return 0
	end
	local end_city_positions = {}
	for _, c in ipairs(containers) do
		if c.structure_match == "end_city" then
			end_city_positions[#end_city_positions + 1] = c.pos
		end
	end
	local clusters = cluster_positions(end_city_positions, END_CITY_CLUSTER_RADIUS, MAX_MOB_CLUSTERS)

	local placed_this_run = {}
	local total = 0
	for _, anchor in ipairs(clusters) do
		if not has_mob_nearby(anchor, END_CITY_CLUSTER_RADIUS, MOB_SHULKER, placed_this_run) then
			local stand = find_stand_pos(anchor, bounds)
			if stand and not is_player_structure_zone(stand, bounds, containers) then
				local obj = core.add_entity(stand, MOB_SHULKER)
				if obj then
					make_persistent(obj:get_luaentity(), pick_name(stand, "shulker"))
					placed_this_run[#placed_this_run + 1] = stand
					total = total + 1
				end
			end
		end
	end
	return total
end

-- Real Mineclonia internal shulker-box color codes (mods/ITEMS/mcl_chests/
-- init.lua's `boxtypes` table -- same list already established in
-- museumloot/init.lua's SHULKER_MCL_COLORS). NOT all Minecraft color
-- names (light_blue -> lightblue, gray -> dark_grey, light_gray -> grey,
-- purple -> violet, lime -> green, green -> dark_green, and there is no
-- "silver" at all).
--
-- Bug found 2026-09-18 while investigating a recurring B1 sighting: this
-- file's own furniture-detection list below had been using the WRONG
-- Minecraft-spelled names (light_blue/lime/gray/silver) -- the exact
-- same failure mode init.lua's own comment already documents fixing
-- once for its own shulker-color list, repeated independently here. It
-- silently missed roughly a third of all possible shulker-box colors as
-- a "this is furniture" signal, weakening the player-structure guard
-- below for any player storage room that happened to use one of the
-- missed colors.
local SHULKER_MCL_COLORS = {
	"white", "orange", "magenta", "lightblue", "yellow", "green", "pink",
	"dark_grey", "grey", "cyan", "violet", "blue", "brown", "dark_green",
	"red", "black",
}

--- "Is this candidate spawn position inside a player-built structure?"
--- Two independent signals, either one is sufficient:
---   1. (Strong, when available) Is a real container from THIS base's
---      own already-scanned container list within `radius` blocks? This
---      is ground truth -- no heuristic guessing -- but only available
---      to callers that pass the base's `containers` list (currently
---      just the witch-hut guard; the shulker guard below already had
---      its own container list from a different call site before this
---      fix, see spawn_shulkers_for_base).
---   2. (Fallback heuristic, always available) Count the nearby chests/
---      beds/doors within 5 blocks; if there are 3+ such player-
---      furniture blocks AND no natural-generated block in a wider
---      10-block radius, the spot is inside a player base, not a real
---      vanilla structure. Real witch huts have very little furniture
---      nearby (just the cauldron + a few wood blocks); player bunk
---      rooms do not. This heuristic is known to have false negatives
---      (a player room built from natural-looking stone/cobble walls
---      can pass the "not enough natural blocks" check even though it's
---      clearly a player build) -- signal 1 is preferred whenever a
---      container list is available for exactly that reason.
local function is_near_real_container(pos, containers, radius)
	if not containers then return false end
	local r2 = radius * radius
	for _, c in ipairs(containers) do
		local dx, dy, dz = c.pos.x - pos.x, c.pos.y - pos.y, c.pos.z - pos.z
		if dx * dx + dy * dy + dz * dz <= r2 then return true end
	end
	return false
end

local function is_player_structure_zone(pos, bounds, containers)
	if is_near_real_container(pos, containers, 8) then return true end
	-- Look for player furniture nearby -- chests, beds, doors.
	local p1 = { x = pos.x - 5, y = pos.y - 5, z = pos.z - 5 }
	local p2 = { x = pos.x + 5, y = pos.y + 5, z = pos.z + 5 }
	local furniture_nodes = { "mcl_chests:chest", "mcl_chests:trapped_chest",
		"mcl_chests:ender_chest",
		"mcl_beds:bed_bottom_red", "mcl_beds:bed_bottom_blue", "mcl_beds:bed_bottom_white",
		"group:bed", "group:door" }
	for _, color in ipairs(SHULKER_MCL_COLORS) do
		furniture_nodes[#furniture_nodes + 1] = "mcl_chests:" .. color .. "_shulker_box_small"
	end
	local hits = core.find_nodes_in_area(p1, p2, furniture_nodes, true) or {}
	-- If 3+ nearby furniture blocks AND we can't find any structure-floor
	-- natural block (grass/dirt/stone/etc.) within 10 blocks, this is
	-- almost certainly inside a player base, not a vanilla structure.
	if #hits >= 3 then
		local p1b = { x = pos.x - 10, y = pos.y - 5, z = pos.z - 10 }
		local p2b = { x = pos.x + 10, y = pos.y + 5, z = pos.z + 10 }
		local natural = core.find_nodes_in_area(p1b, p2b,
			{ "mcl_core:dirt", "mcl_core:dirt_with_grass", "mcl_core:stone",
			  "mcl_core:cobble", "mcl_core:sand", "mcl_core:gravel" }, true) or {}
		-- 3+ furniture blocks + <6 natural-ground blocks = player base.
		if #natural < 6 then return true end
	end
	return false
end

------------------------------------------------------------------------
-- Witch huts.
------------------------------------------------------------------------
-- Not detectable via structures.lua/init.lua's per-container loop at all --
-- vanilla witch huts have NO chest (verified: mods/MAPGEN/mcl_structures/
-- witch_hut.lua has no loot table and never calls mcl_structures.
-- construct_nodes for a chest, unlike pillager_outpost.lua's
-- handle_outpost_loot), so no container in a base's scan can ever carry a
-- "witch_hut" structure_match to piggy-back on. This needs its own,
-- separate bbox-wide node scan.
--
-- Detection signature: a cauldron (group:cauldron, see the profession
-- table's own citation above) with spruce wood within a small radius.
-- NOTE: witch_hut.lua's OWN mapgen spawn code (spawn_witch(), line 8-9)
-- tries to find spruce flooring via `core.find_nodes_in_area_under_air
-- (..., {"mcl_core:sprucewood"})` -- but "mcl_core:sprucewood" does NOT
-- exist as a registered node anywhere in this mineclonia checkout (grepped
-- this session, zero hits outside witch_hut.lua itself); spruce nodes are
-- actually registered as "mcl_trees:tree_spruce" (log) and
-- "mcl_trees:wood_spruce" (planks) via mcl_trees.register_wood
-- (mods/ITEMS/mcl_trees/api.lua:399,408). This looks like real upstream
-- Mineclonia dead code left over from a pre-mcl_trees refactor -- not our
-- bug to fix, but it means we must NOT copy "mcl_core:sprucewood" into our
-- own heuristic (it would silently match nothing, the exact failure mode
-- this project has already lost a day to). We use the verified
-- "mcl_trees:wood_spruce"/"mcl_trees:tree_spruce" names instead.
--
-- Cauldron alone is too common (player brewing setups) to use by itself,
-- same reasoning as structures.lua's village-bell / ruined-portal notes --
-- requiring spruce wood nearby too cuts down false positives substantially
-- without needing to parse the .mts schematic.
--
-- Confirmed live this session: even with the spruce requirement, radius 6
-- still matched an ordinary village bunk room (beds + a chest, spruce
-- furniture, a cauldron used for dyeing) as a "witch hut", spawning a witch
-- standing among villager beds. Tightened to 3 -- real witch huts are a
-- single small room, so a genuine cauldron+spruce pair is still adjacent
-- at this radius, while the search volume (and thus the odds of an
-- unrelated ordinary room coincidentally having both) drops by roughly 8x.
-- This narrows but does not eliminate false positives; a real fix would
-- need to parse the .mts schematic for a shape/size signature, which is
-- out of scope here.
local WITCH_HUT_CAULDRON = { "group:cauldron" }
local WITCH_HUT_SPRUCE = { "mcl_trees:wood_spruce", "mcl_trees:tree_spruce" }
local WITCH_HUT_SPRUCE_RADIUS = 3
local WITCH_HUT_CLUSTER_RADIUS = 20

-- Same y-tiling approach (and same reason -- the 150M-node
-- find_nodes_in_area/VoxelManip volume cap) as init.lua's
-- discover_containers_for_base -- duplicated here rather than shared
-- because it's a handful of lines and this is the only other place in the
-- mod that needs a whole-bbox node scan.
local function find_cauldrons_tiled(bounds)
	local xspan = bounds.x_max - bounds.x_min + 1
	local zspan = bounds.z_max - bounds.z_min + 1
	local max_tile_nodes = 140000000
	local y_tile = math.max(1, math.floor(max_tile_nodes / math.max(1, xspan * zspan)))
	local found = {}
	local y = bounds.y_min
	while y <= bounds.y_max do
		local y1 = math.min(bounds.y_max, y + y_tile - 1)
		local emin = { x = bounds.x_min, y = y, z = bounds.z_min }
		local emax = { x = bounds.x_max, y = y1, z = bounds.z_max }
		local hits = core.find_nodes_in_area(emin, emax, WITCH_HUT_CAULDRON, false) or {}
		for _, p in ipairs(hits) do found[#found + 1] = p end
		y = y1 + 1
	end
	return found
end

local function spawn_witches_for_base(bounds, dimension, containers)
	-- Owner live-test (2026-09-17): 2 witches spawned in Tactical Nuke
	-- inside a player-built storage room. The cauldron+spruce radius-3
	-- heuristic still false-positives on rooms that combine a brewing
	-- cauldron with spruce wood furniture. Add a dimension check (witches
	-- are swamp-only mobs -- any base dimension other than overworld is
	-- an automatic skip) AND an is_player_structure_zone() guard on the
	-- candidate stand position.
	--
	-- 2026-09-18: this still happened again after the above (a witch
	-- nametagged "LagMachine" found in a player structure) -- this
	-- function previously had no access to the base's own container
	-- list at all, so it could only fall back to is_player_structure_zone's
	-- heuristic (which its own comment already admits has false
	-- negatives, e.g. a player room built from natural-looking stone/
	-- cobble walls). Now takes `containers` (the same list
	-- spawn_mobs_for_base already has from the loot pass) and checks
	-- real container proximity first -- ground truth instead of a
	-- second heuristic guess.
	if dimension ~= "overworld" then
		core.log("action", string.format(
			"[museummobs] witch spawn skipped: base dimension=%s (overworld-only mob)", tostring(dimension)))
		return 0
	end
	-- The base's whole bbox was already emerged tile-by-tile by
	-- discover_containers_for_base before museumloot/init.lua ever calls
	-- into this module (see spawn_mobs_for_base's own comment) -- no
	-- further core.emerge_area/core.after hop is needed here.
	local cauldrons = find_cauldrons_tiled(bounds)
	local anchors = {}
	for _, c in ipairs(cauldrons) do
		if nearest_of(c, WITCH_HUT_SPRUCE_RADIUS, WITCH_HUT_SPRUCE, bounds) then
			anchors[#anchors + 1] = c
		end
	end
	local clusters = cluster_positions(anchors, WITCH_HUT_CLUSTER_RADIUS, MAX_MOB_CLUSTERS)

	local placed_this_run = {}
	local total = 0
	for _, anchor in ipairs(clusters) do
		if not has_mob_nearby(anchor, WITCH_HUT_CLUSTER_RADIUS, MOB_WITCH, placed_this_run) then
			local stand = find_stand_pos(anchor, bounds)
			if stand and not is_player_structure_zone(stand, bounds, containers) then
				local obj = core.add_entity(stand, MOB_WITCH)
				if obj then
					make_persistent(obj:get_luaentity(), pick_name(stand, "witch"))
					placed_this_run[#placed_this_run + 1] = stand
					total = total + 1
				end
			end
		end
	end
	return total
end

------------------------------------------------------------------------
-- Pillager outposts / woodland mansions -- SKIPPED.
------------------------------------------------------------------------
-- Re-checked this session (mods/MAPGEN/mcl_levelgen/pillager_outpost.lua,
-- read in full): the iron-golem cage / parrot spawn points
-- ("mcl_levelgen:pillager_outpost_cage_1"/"_2") are levelgen NOTIFICATION
-- events fired during original structure generation (handle_outpost_mobs,
-- lines 55-69) -- not a persisted block signature. Once the structure is
-- placed and saved to a world download, nothing distinguishes a cage
-- room's blocks (cobblestone walls, dark oak accents) from an ordinary
-- player base using the same common materials; a node-radius heuristic
-- here would false-positive constantly, same conclusion (and same
-- reasoning) as the previous agent's note in structures.lua. Woodland
-- mansions have the same problem at larger scale (~50 named room
-- schematics, no single block common to all of them and absent from
-- player builds). Both are skipped for mob placement, same as they're
-- skipped for loot detection in structures.lua -- no pillager/vindicator/
-- evoker spawning is wired up by this module.

------------------------------------------------------------------------
-- Driver.
------------------------------------------------------------------------
-- containers: the same list discover_containers_for_base already produced
-- for this base (each with .pos and, where applicable, .structure_match) --
-- see museumloot/init.lua's run_loot_for_base. bounds: {x_min,x_max,
-- y_min,y_max,z_min,z_max}, the same bbox numbers already used there.
-- Synchronous: the whole bbox is already emerged/active by the time
-- run_loot_for_base reaches stage 3, so no core.emerge_area/core.after hop
-- is needed for anything in this module (node reads, find_nodes_in_area,
-- core.add_entity and core.get_objects_in_area all operate on already-
-- active map area).
--
-- Returns a summary table: { villager = N, villager_by_profession = {...},
-- shulker = N, witch = N }.
function mobplacement.spawn_mobs_for_base(base, containers, bounds)
	local summary = { villager = 0, villager_by_profession = {}, shulker = 0, witch = 0 }
	if not bounds or not bounds.x_min then
		core.log("warning", "[museummobs] " .. base.name .. " has no bbox -- skipping mob pass")
		return summary
	end

	-- Base manifest carries dimension_type (overworld/nether/end); passed
	-- through to mob spawn functions so dimension-restricted mobs (witch
	-- is overworld-only, shulker is end-only) skip cleanly instead of
	-- false-positiving on a vanilla-structure-shaped chunk of player base.
	local dimension = (base and base.dimension_type) or "overworld"

	-- 2026-09-19 owner explicit (round 18): "turn off the village-
	-- repopulation system... named existing villagers are good enough we
	-- don't need more. just the ones in the original world download and
	-- the ones which spawn naturally outside of the world download."
	-- The two calls below (village-structure detection +
	-- workstation-block detection) are what SPAWNED NEW villagers into
	-- detected villages -- disabled entirely. Real captured villagers
	-- (mods/spawnimport/init.lua's own path, logged as "[spawnimport]
	-- ... mob(s) placed from captured entity data") and any villager
	-- that spawns naturally during real gameplay afterward (ordinary
	-- Mineclonia mechanics, nothing this project controls) are both
	-- untouched by this change. Shulker/witch spawning (a few decorative
	-- mobs, not "repopulating" anything) is unaffected -- the owner's
	-- ask was specifically about villagers.
	summary.villager = 0
	summary.villager_by_profession = {}

	summary.shulker = spawn_shulkers_for_base(containers, bounds, dimension)
	summary.witch = spawn_witches_for_base(bounds, dimension, containers)

	return summary
end

return mobplacement
