-- gateway_link.lua -- pair an End base's captured end gateway with a
-- main-island gateway, as if the player had killed the dragon and then
-- travelled out to build the base (owner 2026-09-28).
--
-- Mineclonia opens up to 20 gateways on a ring around the main island
-- (mcl_portals/portal_gateway.lua gateway_positions, radius 96 at
-- mg_end_min + 75). For each End base that captured a gateway, pick the
-- free slot closest to the base's direction, build Mineclonia's own
-- gateway schematic there, and record the pair in
-- <world>/museum_gateways.json. museumportals reads that file and
-- teleports between the two. Mineclonia's per-node destination meta is
-- not used: a later dragon kill can re-place a slot's schematic and
-- wipe it, while the file survives. Bases past the 20th slot get no
-- link; their gateways fall back to museumportals' "outer gateway ->
-- main island" rule.

local gateway_link = {}

local function links_path() return core.get_worldpath() .. "/museum_gateways.json" end

-- copied from Mineclonia's gateway_positions (portal_gateway.lua); the
-- table truncates toward zero, so it isn't recomputed from the angle
local SLOT_XZ = {
	{ 96, 0 }, { 91, 29 }, { 77, 56 }, { 56, 77 }, { 29, 91 },
	{ 0, 96 }, { -29, 91 }, { -56, 77 }, { -77, 56 }, { -91, 29 },
	{ -96, 0 }, { -91, -29 }, { -77, -56 }, { -56, -77 }, { -29, -91 },
	{ 0, -96 }, { 29, -91 }, { 56, -77 }, { 77, -56 }, { 91, -29 },
}

local function slot_pos(i)
	return vector.new(SLOT_XZ[i][1], mcl_vars.mg_end_min + 75, SLOT_XZ[i][2])
end

local function load_links()
	local f = io.open(links_path(), "r")
	if not f then return {} end
	local raw = f:read("*a")
	f:close()
	return core.parse_json(raw) or {}
end

local function save_links(links)
	local f = io.open(links_path(), "w")
	if not f then
		core.log("error", "[spawnimport] could not write " .. links_path())
		return
	end
	f:write(core.write_json(links, true))
	f:close()
end

-- job.gateways: captured gateway node positions (set by place_one_chunk)
function gateway_link.link(job)
	if job.dimension_type ~= "end" or not job.gateways or #job.gateways == 0 then return end
	if not (mcl_vars and mcl_structures and mcl_structures.place_schematic) then
		core.log("warning", "[spawnimport] gateway link skipped: mcl_structures not available")
		return
	end
	local links = load_links()
	local used = {}
	for _, l in ipairs(links) do
		if l.base == job.name then
			core.log("action", "[spawnimport] " .. job.name .. ": gateway already linked")
			return
		end
		used[l.slot] = true
	end

	-- the base's gateway nearest its bbox centre is the landing point
	local b = job.result_bbox or {}
	local cx = ((b.x_min or 0) + (b.x_max or 0)) / 2
	local cz = ((b.z_min or 0) + (b.z_max or 0)) / 2
	table.sort(job.gateways, function(p, q)
		return (p.x - cx) ^ 2 + (p.z - cz) ^ 2 < (q.x - cx) ^ 2 + (q.z - cz) ^ 2
	end)
	local outer = job.gateways[1]

	local want = math.atan2(outer.z, outer.x)
	local best, best_d
	for i = 1, #SLOT_XZ do
		if not used[i] then
			local a = math.atan2(SLOT_XZ[i][2], SLOT_XZ[i][1])
			local d = math.abs(math.atan2(math.sin(want - a), math.cos(want - a)))
			if not best_d or d < best_d then best, best_d = i, d end
		end
	end
	if not best then
		core.log("action", string.format(
			"[spawnimport] %s: all %d main-island gateway slots taken -- its gateway leads to the main island",
			job.name, #SLOT_XZ))
		return
	end

	local main = slot_pos(best)
	local path = core.get_modpath("mcl_structures") .. "/schematics/mcl_structures_end_gateway_portal.mts"
	core.emerge_area(vector.offset(main, -3, -3, -3), vector.offset(main, 3, 3, 3), function(_, _, remaining)
		if remaining > 0 then return end
		-- same call and offset as portal_gateway.lua spawn_gateway_portal
		mcl_structures.place_schematic(vector.add(main, vector.new(-1, -2, -1)), path, "0", nil, true)
	end)

	local outers = {}
	for _, p in ipairs(job.gateways) do outers[#outers + 1] = { x = p.x, y = p.y, z = p.z } end
	links[#links + 1] = {
		base = job.name, slot = best,
		main = { x = main.x, y = main.y, z = main.z },
		outer = outers,
	}
	save_links(links)
	core.log("action", string.format(
		"[spawnimport] %s: main-island gateway slot %d at %s <-> base gateway %s (%d captured)",
		job.name, best, core.pos_to_string(main), core.pos_to_string(outer), #outers))
end

return gateway_link
