-- museumwarp: Minecraft-style /warp <name> for every base spawnimport has
-- placed in this world. Reads spawnimport's placement registry directly
-- (published as _G.__spawnimport_registry -- see that mod's init.lua;
-- core.get_mod_storage() is scoped per-modname, so this mod can't read
-- spawnimport's storage on its own) rather than the museum_survey.py
-- manifest, so a warp only ever exists for a base that's actually been
-- placed, not just planned.

local registry = _G.__spawnimport_registry
if not registry then
	error("[museumwarp] _G.__spawnimport_registry is nil -- spawnimport must be listed before " ..
		"museumwarp in this world's load order (see museumwarp/mod.conf's 'depends')")
end

-- Mirrors mods/CORE/mcl_init/init.lua's Y-bands (see
-- server_mod/spawnimport's museum_survey.py comment for the same
-- constants) -- used only to guess a safe fallback teleport height for a
-- base that somehow placed zero content (bbox.y_min/y_max nil).
--
-- 2026-09-19: overworld's key/values shifted from 0/100 to -64/36 --
-- see spawnimport/init.lua's OVERWORLD_Y_CORRECTION comment for the full
-- derivation (owner live report + direct empirical verification that
-- Mineclonia's real overworld terrain sits 64 blocks below vanilla's own
-- Y everywhere, so the manifest now places overworld bases at
-- dest_y_offset=-64 instead of 0). Every one of these per-band tables
-- keys off the exact dest_y_offset value, so all of them need the same
-- key/value shift, not just this one.
local Y_BAND_FALLBACK = {
	[-64] = 36,          -- overworld: comfortably above typical terrain
	[-29067] = -28990,   -- nether: mid-band
	[-27073] = -27000,   -- end: mid-band
}

-- b.y_max is the tallest content *anywhere in the whole base* (every
-- captured chunk gets cleared/rewritten across its full section range --
-- see spawnimport's place_one_chunk -- so this is almost always ~319
-- regardless of how tall that particular base's real content actually is).
-- Landing a player at "somewhere near y_max" over an arbitrary X/Z is
-- landing them a very long way above the ground, not "near the base" --
-- confirmed as the actual cause of "warped in but saw nothing recognizable"
-- (in-client report), not a placement/data bug. Scan down from a safe
-- ceiling at the *specific* target X/Z instead, so the player lands right
-- above whatever is actually there.
-- 2026-09-19: overworld's keys/values shifted from 0/[300,-64] to
-- -64/[236,-128] -- same band HEIGHT (364), just 64 lower, matching the
-- real placement shift (see Y_BAND_FALLBACK's own comment above).
local SCAN_TOP = { [-64] = 236, [-29067] = -28950, [-27073] = -26810 }
local SCAN_BOTTOM = { [-64] = -128, [-29067] = -29060, [-27073] = -27080 }

-- The exact geometric bbox-center column often has nothing there at all --
-- confirmed directly against real placed data across the 14-base test
-- batch: 6 of 14 bases came back with "topmost=nil" (zero content anywhere
-- in the full height scan) at their exact center. Real WorldTools captures
-- are patchy, not solid rectangles (built areas connected by unbuilt gaps
-- the archiver simply never walked through), so a geometric center is not
-- reliably "near the base" the way it would be for a solid shape. Search
-- outward for the closest column that actually has something before
-- falling back to guessing.
--
-- Per-band search radius is sized so radius*2 x radius*2 x band-height
-- stays safely under find_nodes_in_area/VoxelManip's shared 150,000,000
-- voxel limit (confirmed against real numbers, not just estimated) --
-- overworld's SCAN_TOP-SCAN_BOTTOM band is the tallest (364) so gets the
-- smallest radius of the three.
-- 2026-09-19: overworld's key shifted from 0 to -64 (see above); the
-- radius value itself is unchanged -- it depends on band HEIGHT for the
-- voxel-cap math below, not on where the band sits, and the height is
-- unchanged (364, just shifted 64 lower).
local SEARCH_RADIUS = { [-64] = 280, [-29067] = 400, [-27073] = 250 }
local SEARCH_STRIDE = 4 -- columns are ~solid-or-not in clusters at building scale, no need to check every single one

local function find_nearest_content(x, z, top, bottom, radius)
	local vm = core.get_voxel_manip()
	local minp = { x = x - radius, y = bottom, z = z - radius }
	local maxp = { x = x + radius, y = top, z = z + radius }
	local emin, emax = vm:read_from_map(minp, maxp)
	local area = VoxelArea:new({ MinEdge = emin, MaxEdge = emax })
	local data = vm:get_data()
	local best, best_dist2 = nil, nil
	for zz = minp.z, maxp.z, SEARCH_STRIDE do
		for xx = minp.x, maxp.x, SEARCH_STRIDE do
			local dist2 = (xx - x) ^ 2 + (zz - z) ^ 2
			if not best_dist2 or dist2 < best_dist2 then
				for yy = top, bottom, -1 do
					local name = core.get_name_from_content_id(data[area:index(xx, yy, zz)])
					if name ~= "air" and name ~= "ignore" then
						best, best_dist2 = { x = xx, y = yy + 2, z = zz }, dist2
						break
					end
				end
			end
		end
	end
	return best
end

-- Finds a spot to stand on at the given column: the first empty pair of
-- nodes with something solid underneath, searching outward from `near_y`.
-- "Empty" includes mcl_core:void, which is what unwritten space in this
-- world is filled with (airlike, non-walkable, non-pointable) -- treating
-- it as solid ground would land the player inside it.
local function standing_spot(x, z, near_y, band)
	local top = SCAN_TOP[band] or 300
	local bottom = SCAN_BOTTOM[band] or -64
	local function empty(n) return n == "air" or n == "mcl_core:void" or n == "ignore" end
	core.get_voxel_manip():read_from_map(
		{ x = x - 1, y = math.max(bottom, near_y - 48), z = z - 1 },
		{ x = x + 1, y = math.min(top, near_y + 48), z = z + 1 })
	for d = 0, 48 do
		for _, y in ipairs(d == 0 and { near_y } or { near_y + d, near_y - d }) do
			if y > bottom and y < top then
				local at = core.get_node({ x = x, y = y, z = z }).name
				local above = core.get_node({ x = x, y = y + 1, z = z }).name
				local below = core.get_node({ x = x, y = y - 1, z = z }).name
				if empty(at) and empty(above) and not empty(below) then
					return y
				end
			end
		end
	end
	return nil
end

local function target_pos(entry)
	local b = entry.bbox
	local band = entry.dest_y_offset or 0
	local top = SCAN_TOP[band] or 300
	local bottom = SCAN_BOTTOM[band] or -64

	-- Preferred: the densest cluster of containers/signs recorded at import
	-- time (spawnimport's Job:best_interest_point). The bbox centre is a
	-- poor target and sometimes a useless one -- WorldTools captures
	-- include the travel corridors flown in along, so for a sparse base the
	-- centre can sit thousands of blocks from anything built. Space
	-- Valkyria III's centre is ~2200 blocks from its actual base.
	local wt = entry.warp_target
	if wt and wt.x and wt.z then
		local y = standing_spot(wt.x, wt.z, wt.y or 64, band)
		return { x = wt.x, y = (y or (wt.y or 64)) + 1, z = wt.z }
	end

	local x = math.floor((b.x_min + b.x_max) / 2)
	local z = math.floor((b.z_min + b.z_max) / 2)
	local found = find_nearest_content(x, z, top, bottom, SEARCH_RADIUS[band] or 200)
	if found then
		return found
	end

	-- Nothing within the whole search radius either (a genuinely sparse
	-- base, or one whose real content sits further from center than that)
	-- -- fall back to the old behaviour rather than stranding the player
	-- with no teleport at all.
	local y = (b.y_max and b.y_max + 3) or (Y_BAND_FALLBACK[band] or 100)
	return { x = x, y = y, z = z }
end

local function find_matches(query)
	local q = query:lower()
	local exact, substring = nil, {}
	for _, entry in ipairs(registry.list()) do
		local name = entry.name or ""
		if name:lower() == q then
			exact = entry
		elseif name:lower():find(q, 1, true) then
			substring[#substring + 1] = entry
		end
	end
	return exact, substring
end

core.register_chatcommand("warp", {
	params = "<name> | list [page]",
	description = "Teleport to an imported 2b2t museum base by name (substring match). " ..
		"'/warp list' shows every available warp.",
	func = function(player_name, param)
		param = param:match("^%s*(.-)%s*$") or ""

		local list_arg = param:match("^list%s*(.*)$")
		if param == "list" or list_arg then
			local entries = registry.list()
			if #entries == 0 then
				return true, "[warp] no bases have been placed in this world yet"
			end
			table.sort(entries, function(a, b) return (a.name or "") < (b.name or "") end)
			local per_page = 20
			local page = tonumber(list_arg) or 1
			local pages = math.ceil(#entries / per_page)
			page = math.max(1, math.min(page, pages))
			local lines = { string.format("[warp] %d warps, page %d/%d:", #entries, page, pages) }
			for i = (page - 1) * per_page + 1, math.min(page * per_page, #entries) do
				lines[#lines + 1] = "  " .. entries[i].name
			end
			if pages > 1 then
				lines[#lines + 1] = "(more: /warp list " .. (page + 1 <= pages and (page + 1) or 1) .. ")"
			end
			return true, table.concat(lines, "\n")
		end

		if param == "" then
			return false, "usage: /warp <name> | list [page]"
		end

		local exact, substring = find_matches(param)
		local entry = exact
		if not entry then
			if #substring == 1 then
				entry = substring[1]
			elseif #substring == 0 then
				return false, "[warp] no base matching '" .. param .. "' -- try /warp list"
			else
				table.sort(substring, function(a, b) return (a.name or "") < (b.name or "") end)
				local names = {}
				for i = 1, math.min(#substring, 15) do names[#names + 1] = substring[i].name end
				return false, string.format(
					"[warp] %d bases match '%s', be more specific:\n  %s%s",
					#substring, param, table.concat(names, "\n  "),
					#substring > 15 and "\n  ..." or "")
			end
		end

		local player = core.get_player_by_name(player_name)
		if not player then
			return false, "[warp] player not found (not connected?)"
		end
		player:set_pos(target_pos(entry))
		return true, "[warp] teleported to '" .. entry.name .. "'"
	end,
})

-- Spawn platform.
--
-- This world has mapgen switched off entirely (map_meta.txt:
-- mg_name = singlenode, mapgen_limit = 0). That is not a cosmetic choice:
-- a VoxelManip write never marks its blocks generated (src/map.cpp's
-- blitBackAll only raises MOD_STATE_WRITE_NEEDED; only the mapgen path
-- calls setGenerated(true), src/servermap.cpp), and the emerge thread runs
-- mapgen over any block that isn't flagged generated (src/emerge.cpp's
-- getBlockOrStartGen). So with mapgen enabled, Mineclonia re-generated
-- over each imported base the first time a player flew near it --
-- measured at ~80% of imported blocks destroyed, which is what "the bases
-- are missing / the End islands are all Luanti-generated" actually was.
--
-- Consequence: there is no terrain at the static spawnpoint either, so a
-- joining player would fall through empty space forever. Give spawn
-- something to stand on. Built with a VoxelManip because with mapgen off
-- the blocks at spawn don't exist yet, and core.set_node can't create
-- them.
local SPAWN = { x = 0, y = 150, z = 0 }
local PLATFORM_R = 4
core.register_on_mods_loaded(function()
	core.after(0, function()
		local floor_y = SPAWN.y - 2
		local minp = { x = SPAWN.x - PLATFORM_R, y = floor_y, z = SPAWN.z - PLATFORM_R }
		local maxp = { x = SPAWN.x + PLATFORM_R, y = floor_y, z = SPAWN.z + PLATFORM_R }
		local vm = core.get_voxel_manip()
		local emin, emax = vm:read_from_map(minp, maxp)
		local area = VoxelArea:new({ MinEdge = emin, MaxEdge = emax })
		-- Only touch the platform's own positions, never the whole emerged
		-- volume -- see place_one_chunk in spawnimport for what blanket
		-- writes to an emerged area do to neighbouring content.
		local data = vm:get_data()
		local stone = core.get_content_id("mcl_core:stonebrick")
		local already = true
		for z = minp.z, maxp.z do
			for x = minp.x, maxp.x do
				local idx = area:index(x, floor_y, z)
				if data[idx] ~= stone then
					already = false
					data[idx] = stone
				end
			end
		end
		if not already then
			vm:set_data(data)
			vm:write_to_map(true)
			core.log("action", "[museumwarp] built spawn platform at " .. core.pos_to_string(SPAWN))
		end
		vm:close()
	end)
end)

-- This world is for freely exploring imported builds -- flying/noclip
-- should always be available, not conditional on whatever normally grants
-- them (builtin/game/auth.lua auto-grants singleplayer full privileges on
-- a brand new auth record, but that path apparently didn't fire for this
-- world -- possibly because it was set up by hand rather than through the
-- "new world" menu flow, unlike Spawnmasons Preview, which has the full
-- set. Fixed once already via a direct auth.sqlite edit; granting it here
-- too so it can never silently regress again for this or any future
-- player in this world).
local MUSEUM_PRIVS = { noclip = true, fly = true, fast = true, teleport = true, give = true, settime = true }
core.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	local privs = core.get_player_privs(name)
	local changed = false
	for priv, want in pairs(MUSEUM_PRIVS) do
		if want and not privs[priv] then
			privs[priv] = true
			changed = true
		end
	end
	if changed then
		core.set_player_privs(name, privs)
	end
end)
