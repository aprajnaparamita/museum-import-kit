-- Gap-fill (round 28 prototype -> round 30 local blend -> round 31
-- "natural Mineclonia generation at blended heights").
--
-- Round 30 sculpted synthetic stone/dirt/grass at an averaged height for
-- the single-chunk ring around the world download. Round 31 (owner's
-- "Approach A") keeps the ring chunk's NATURAL Mineclonia terrain and only
-- adjusts its surface height toward the world download, so the ring keeps
-- real blocks, biome colours, water and (mostly) trees instead of becoming
-- uniform synthetic fill.
--
-- Per ring chunk, per column:
--   1. read the natural solid surface S (the top walkable, non-leaf,
--      non-log, non-liquid block -- ground for land, the ocean floor for
--      water);
--   2. blend S toward the world-download chunk's own solid surface at any
--      edge that borders it (average, "meet half-way"), and relax the
--      interior;
--   3. clear everything above the blended surface (drops trees/plants/
--      floating terrain), then:
--        * below sea level -> water column (floor at B, water to sea
--          level),
--        * at/above sea level -> land (natural surface block at B, dirt/
--          stone under it);
--   4. re-tint the surface grass with the world-download biome at the
--      edges.
--
-- Still confined to the single 16x16 chunk, still only the "touched" ring.

local gap_fill = {}

local C = 16

-- Minecraft 1.18 biome id -> Mineclonia biome name (for the param2 tint).
-- Mineclonia registers biomes under their legacy names.
local MC_TO_MCL_BIOME = {
	["minecraft:plains"] = "Plains",
	["minecraft:sunflower_plains"] = "SunflowerPlains",
	["minecraft:forest"] = "Forest",
	["minecraft:flower_forest"] = "FlowerForest",
	["minecraft:birch_forest"] = "BirchForest",
	["minecraft:old_growth_birch_forest"] = "BirchForestM",
	["minecraft:dark_forest"] = "RoofedForest",
	["minecraft:grove"] = "Grove",
	["minecraft:meadow"] = "Meadow",
	["minecraft:snowy_slopes"] = "SnowySlopes",
	["minecraft:frozen_peaks"] = "FrozenPeaks",
	["minecraft:jagged_peaks"] = "JaggedPeaks",
	["minecraft:stony_peaks"] = "StonyPeaks",
	["minecraft:taiga"] = "Taiga",
	["minecraft:desert"] = "Desert",
	["minecraft:beach"] = "Beach",
	["minecraft:river"] = "River",
	["minecraft:ocean"] = "Ocean",
	["minecraft:deep_ocean"] = "Ocean",
	["minecraft:swamp"] = "Swampland",
}

-- Water surface level (dest space), from the v7 mapgen's `water_level`
-- setting (persisted in map_meta.txt). This is the ACTUAL ocean surface --
-- Mineclonia's v7 mapgen fills water at and below this Y, and it is NOT
-- the mcl_levelgen preset's `sea_level` (63), which is the air block one
-- above the water and does not track where v7 actually fills water. Using
-- the preset value left the blend's water 2 blocks low (round 31).
local WATER_LEVEL = tonumber(core.get_mapgen_setting("water_level")) or 1

-- Bedrock level (dest space), from Mineclonia's own mcl_vars. In v7 mode
-- this is -128..-124 (rough, 5 layers); the gap-fill column should end at
-- this same depth (bedrock + void below), NOT run solid stone all the way
-- to GAP_Y_MIN -- the owner noticed the fill extending ~60 blocks below
-- the real bedrock.
local BEDROCK_MIN = (mcl_vars and mcl_vars.mg_bedrock_overworld_min) or -128
local BEDROCK_MAX = (mcl_vars and mcl_vars.mg_bedrock_overworld_max) or (BEDROCK_MIN + 4)

-- Loads a source_footprint.lua JSON and returns
--   { ["cx_cz"] = { height=, cols=, solid_cols=, biome= } }
-- for every REAL chunk. nil on any open/parse failure. Backward-compatible
-- with older footprints (no solid_cols/biome): solid_cols falls back to
-- cols, biome to nil.
function gap_fill.load_real_heights(footprint_path)
	local f = io.open(footprint_path, "r")
	if not f then return nil end
	local raw = f:read("*a")
	f:close()
	local ok, data = pcall(core.parse_json, raw)
	if not ok or not data or not data.chunks then return nil end
	local real = {}
	for _, c in ipairs(data.chunks) do
		if c.cx and c.cz and c.height then
			local cols, solid = c.cols, c.solid_cols
			if type(cols) ~= "table" or #cols ~= 256 then
				cols = {}
				for i = 1, 256 do cols[i] = c.height end
			end
			if type(solid) ~= "table" or #solid ~= 256 then
				solid = cols
			end
			real[c.cx .. "_" .. c.cz] = {
				height = c.height, cols = cols, solid_cols = solid,
				biome = c.biome,
			}
		end
	end
	return real
end

-- For each ring (touched) gap chunk, extract the directly-adjacent world-
-- download chunk's solid-surface edge columns and biome. Returns
-- { cx=, cz=, west=, east=, north=, south=, west_biome=, ... } where each
-- direction is a 16-entry SOURCE-space solid-height table (or nil), and
-- each *_biome is the neighbour's biome name (or nil).
function gap_fill.compute_gap_heights(chunk_bounds, real)
	local gaps = {}
	for cx = chunk_bounds.x_min, chunk_bounds.x_max do
		for cz = chunk_bounds.z_min, chunk_bounds.z_max do
			if not real[cx .. "_" .. cz] then
				local touched = false
				for ox = -1, 1 do
					for oz = -1, 1 do
						if real[(cx + ox) .. "_" .. (cz + oz)] then touched = true break end
					end
					if touched then break end
				end
				if touched then
					local entry = { cx = cx, cz = cz }
					local w = real[(cx - 1) .. "_" .. cz]
					if w then
						entry.west = {}
						for lz = 0, C - 1 do entry.west[lz + 1] = w.solid_cols[(C - 1) * C + lz + 1] end
						entry.west_biome = w.biome
					end
					local e = real[(cx + 1) .. "_" .. cz]
					if e then
						entry.east = {}
						for lz = 0, C - 1 do entry.east[lz + 1] = e.solid_cols[0 * C + lz + 1] end
						entry.east_biome = e.biome
					end
					local n = real[cx .. "_" .. (cz - 1)]
					if n then
						entry.north = {}
						for lx = 0, C - 1 do entry.north[lx + 1] = n.solid_cols[lx * C + (C - 1) + 1] end
						entry.north_biome = n.biome
					end
					local s = real[cx .. "_" .. (cz + 1)]
					if s then
						entry.south = {}
						for lx = 0, C - 1 do entry.south[lx + 1] = s.solid_cols[lx * C + 0 + 1] end
						entry.south_biome = s.biome
					end
					gaps[#gaps + 1] = entry
				end
			end
		end
	end
	return gaps
end

-- Y-range matching the pregen pass (PREGEN_Y_MIN/MAX).
local GAP_Y_MIN = -130
local GAP_Y_MAX = 319

-- Is this content id "solid terrain ground" (walkable, not a leaf, log,
-- liquid or attached plant)? Name lookups are cached.
local ground_cache = {}
local function is_ground(cid)
	local cached = ground_cache[cid]
	if cached ~= nil then return cached end
	local name = core.get_name_from_content_id(cid)
	local def = core.registered_nodes[name]
	local ok = def and def.walkable
		and core.get_item_group(name, "leaves") == 0
		and core.get_item_group(name, "tree") == 0
		and core.get_item_group(name, "liquid") == 0
		and core.get_item_group(name, "attached_node") == 0
	ground_cache[cid] = ok
	return ok
end

local function biome_palette(mc_biome)
	local mcl_name = mc_biome and MC_TO_MCL_BIOME[mc_biome]
	if not mcl_name then return nil end
	local def = core.registered_biomes[mcl_name]
	if not def then return nil end
	return def._mcl_palette_index
end

-- Natural surface material classification for the fill: returns
-- surface_cid, sub_cid (the block just under the surface), deep_cid.
local function surface_material(cid)
	local name = core.get_name_from_content_id(cid)
	if name == "mcl_core:sand" or name == "mcl_core:redsand" or name == "mcl_core:gravel" then
		return cid, cid, core.get_content_id("mcl_core:stone")
	elseif name == "mcl_core:dirt" or name == "mcl_core:coarse_dirt"
		or name == "mcl_core:dirt_with_grass" or name == "mcl_core:podzol"
		or name == "mcl_core:mycelium" then
		return cid, core.get_content_id("mcl_core:dirt"), core.get_content_id("mcl_core:stone")
	elseif name == "mcl_core:stone" or name == "mcl_core:andesite"
		or name == "mcl_core:granite" or name == "mcl_core:diorite" then
		return cid, cid, cid
	end
	-- default: grass/dirt/stone
	return core.get_content_id("mcl_core:dirt_with_grass"),
		core.get_content_id("mcl_core:dirt"),
		core.get_content_id("mcl_core:stone")
end

-- Sculpts one ring chunk: keep the natural terrain, adjust its surface
-- height toward the adjacent world-download, add water below sea level, and
-- re-tint the surface biome at the edges. Confined to this 16x16 chunk.
function gap_fill.place_gap_chunk(job, entry, content_id_for)
	local base_x = job.anchor_x + (entry.cx * C - job.origin_x)
	local base_z = job.anchor_z + (entry.cz * C - job.origin_z)
	local xmin, xmax = base_x, base_x + C - 1
	local zmin, zmax = base_z, base_z + C - 1
	local ymin, ymax = GAP_Y_MIN + job.dest_y_offset, GAP_Y_MAX + job.dest_y_offset
	local dy = job.dest_y_offset
	local sea = WATER_LEVEL

	local c_air = core.CONTENT_AIR
	local c_ignore = core.CONTENT_IGNORE
	local c_stone = core.get_content_id("mcl_core:stone")
	local c_water = core.get_content_id("mcl_core:water_source")
	local c_bedrock = core.get_content_id("mcl_core:bedrock")
	local c_void = core.get_content_id("mcl_core:void")

	local vm = core.get_voxel_manip()
	local emin, emax = vm:read_from_map({ x = xmin, y = ymin, z = zmin }, { x = xmax, y = ymax, z = zmax })
	local area = VoxelArea:new({ MinEdge = emin, MaxEdge = emax })
	local data = vm:get_data()
	local p2data = vm:get_param2_data()

	-- 1. natural solid surface S + its material, per column.
	local S = {}
	local S_mat = {}
	local T = {} -- highest natural block per column (tree/plant top)
	for lz = 0, C - 1 do
		for lx = 0, C - 1 do
			local x = xmin + lx
			local z = zmin + lz
			local ground, ground_cid = nil, nil
			local top = nil
			for y = ymax, ymin, -1 do
				local cid = data[area:index(x, y, z)]
				if cid ~= c_air and cid ~= c_ignore then
					if not top then top = y end
					if is_ground(cid) then
						ground, ground_cid = y, cid
						break
					end
				end
			end
			S[lx * C + lz + 1] = ground or ymin
			S_mat[lx * C + lz + 1] = ground_cid
			T[lx * C + lz + 1] = top or (ground or ymin)
		end
	end

	-- 2. blend S -> B (dest space). Edge columns bordering a world-download
	-- chunk are pinned to the average of S and the neighbour's solid
	-- surface; everything else stays S; then relax the interior.
	local g = {}
	local function gi(lx, lz) return lz * C + lx + 1 end
	local function edge_val(lx, lz)
		local sv = S[lx * C + lz + 1]
		if lx == 0 and entry.west then
			return math.floor((sv + entry.west[lz + 1] + dy) / 2 + 0.5)
		elseif lx == C - 1 and entry.east then
			return math.floor((sv + entry.east[lz + 1] + dy) / 2 + 0.5)
		elseif lz == 0 and entry.north then
			return math.floor((sv + entry.north[lx + 1] + dy) / 2 + 0.5)
		elseif lz == C - 1 and entry.south then
			return math.floor((sv + entry.south[lx + 1] + dy) / 2 + 0.5)
		end
		return sv
	end
	for lz = 0, C - 1 do
		for lx = 0, C - 1 do
			local on_edge = (lx == 0 or lx == C - 1 or lz == 0 or lz == C - 1)
			if on_edge then
				g[gi(lx, lz)] = edge_val(lx, lz)
			else
				g[gi(lx, lz)] = S[lx * C + lz + 1]
			end
		end
	end
	for _ = 1, 30 do
		for lz = 1, C - 2 do
			for lx = 1, C - 2 do
				local i = gi(lx, lz)
				g[i] = 0.25 * (g[gi(lx - 1, lz)] + g[gi(lx + 1, lz)] + g[gi(lx, lz - 1)] + g[gi(lx, lz + 1)])
			end
		end
	end

	-- 3. apply. For each column: clear above B, then land or water.
	-- Precompute the edge biome tint per column (from the world-download
	-- neighbour, if any).
	local tint = {}
	for lz = 0, C - 1 do
		for lx = 0, C - 1 do
			local t = nil
			if lx == 0 and entry.west then t = biome_palette(entry.west_biome)
			elseif lx == C - 1 and entry.east then t = biome_palette(entry.east_biome)
			elseif lz == 0 and entry.north then t = biome_palette(entry.north_biome)
			elseif lz == C - 1 and entry.south then t = biome_palette(entry.south_biome) end
			tint[lx * C + lz + 1] = t
		end
	end

	for lz = 0, C - 1 do
		local z = zmin + lz
		for lx = 0, C - 1 do
			local x = xmin + lx
			-- B must be a whole number: the relaxation leaves floats, and a
			-- float B made the fill loop's y non-integer, which area:index
			-- truncates -- shifting the surface and the bedrock boundary by
			-- one block (the owner noticed bedrock one block off and fill
			-- extending below it).
			local B = math.floor(g[gi(lx, lz)] + 0.5)
			local S_col = S[lx * C + lz + 1]
			local T_col = T[lx * C + lz + 1]
			local surf, sub, deep = surface_material(S_mat[lx * C + lz + 1] or c_stone)

			if B < sea then
				-- Water column: open water. Clear above the floor, fill a
				-- synthetic floor, then water up to sea level.
				for y = B + 1, ymax do
					local idx = area:index(x, y, z)
					data[idx] = c_air
					p2data[idx] = 0
				end
				for y = B, ymin, -1 do
					local idx = area:index(x, y, z)
					local cid
					if y > BEDROCK_MAX then
						if y == B then cid = surf
						elseif y >= B - 3 then cid = sub
						else cid = deep end
					elseif y >= BEDROCK_MIN then
						cid = c_bedrock
					else
						cid = c_void
					end
					data[idx] = cid
					p2data[idx] = 0
				end
				for y = B + 1, sea do
					local idx = area:index(x, y, z)
					data[idx] = c_water
					p2data[idx] = 0
				end
			else
				-- Land column: SHIFT the natural surface stack + trees by
				-- (B - S) so the natural material (grass/sand/dirt) and any
				-- trees/plants are preserved -- not replaced with a flat
				-- synthetic grass column (owner report: chunks came back
				-- flat grass with no trees).
				local movable = {}
				for y = S_col - 3, T_col do
					if y >= ymin and y <= ymax then
						movable[y - S_col] = data[area:index(x, y, z)]
					end
				end
				for y = ymin, ymax do
					local idx = area:index(x, y, z)
					data[idx] = c_air
					p2data[idx] = 0
				end
				for off, cid in pairs(movable) do
					local ny = B + off
					if ny >= ymin and ny <= ymax then
						local idx = area:index(x, ny, z)
						data[idx] = cid
						p2data[idx] = 0
					end
				end
				-- fill stone/bedrock/void below the shifted surface stack
				for y = B - 4, ymin, -1 do
					local idx = area:index(x, y, z)
					local cid
					if y > BEDROCK_MAX then
						cid = deep
					elseif y >= BEDROCK_MIN then
						cid = c_bedrock
					else
						cid = c_void
					end
					data[idx] = cid
					p2data[idx] = 0
				end
			end

			-- biome tint: re-colour the surface grass with the world-
			-- download biome at this edge, if it is a biomecolor node
			local t = tint[lx * C + lz + 1]
			if t and core.get_item_group(core.get_name_from_content_id(surf), "biomecolor") > 0 then
				p2data[area:index(x, B, z)] = t
			end
		end
	end

	vm:set_data(data)
	vm:set_param2_data(p2data)
	vm:write_to_map(true)
	vm:close()
end

return gap_fill
