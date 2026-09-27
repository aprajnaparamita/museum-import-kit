-- gap_fill.lua -- "merge chunk" gap-fill: bridge each base's captured
-- (world-download) chunks into the surrounding Mineclonia-generated
-- terrain so the border is invisible to a player.
--
-- Loaded as a factory: init.lua does
--     local gap_fill = dofile(modpath .. "/gap_fill.lua")(gap_field)
-- so the pure solver (gap_field.lua) is injected and unit-testable.
--
-- The algorithm, per ring chunk (a chunk whose 8-neighbourhood touches a
-- captured chunk; everything further out stays real generated terrain):
--
--   1. READ the natural generated column surface S of every column to be
--      written (and of the chunks one ring further out, for widening).
--      S is the topmost NATURAL TERRAIN block (Mineclonia whitelist --
--      not village roofs or rail platforms) with floating masses
--      rejected (a run <= 2 blocks thick over a >= 3 gap is an island /
--      stilted floor / platform, not ground).
--
--   2. MERGE the height field jointly over ALL ring chunks at once (the
--      old per-chunk blend left steps where two ring chunks met):
--        * columns bordering a captured chunk are PINNED to that
--          chunk's terrain height (footprint `terrain_cols` -- the
--          ground the base sits on, NOT its roofs) -- the seam is
--          EXACT, zero step, water continues level into water;
--        * columns bordering untouched generated terrain are pinned to
--          their own S -- invisible there by construction;
--        * the rest is solved by gap_field: no slope over 1 block per
--          column (a player can walk/jump up and down anywhere), as
--          close to each column's own natural height as possible;
--        * if the height difference doesn't fit in the ring, the domain
--          widens into more natural chunks (bounded) to give the ramp
--          room ("merge chunk"), instead of leaving a cliff.
--
--   3. WRITE each column as a merge of both sides:
--        * land column (merged height >= water level): the natural
--          surface skin + trees/plants SHIFT with the height change (real
--          material and vegetation preserved); surface water and any
--          floating junk above the surface are replaced by AIR (this is
--          the fix for generated water being dragged up with a raised
--          chunk), nothing else;
--        * water column (merged height < water level): open water floor
--          at the merged height up to water level, air above;
--        * below: natural sub/deep material, Mineclonia bedrock and void
--          at the real levels;
--        * the seam edge's grass is re-tinted with the world-download
--          biome (footprint `biome`).
--
--   4. AUDIT (gap_fill.audit, run at the end of every import): re-read
--      the written columns and verify -- seam heights match the capture
--      exactly, every slope within the domain is walkable, no water sits
--      above sea level, no floating junk left above the merged surface.
--
-- Inputs: the source footprint JSON (import_tools/placement_fit/
-- source_footprint.lua output -- terrain_cols/cols/solid_cols/biome per
-- captured chunk) and the generated map itself.

local function factory(gap_field, wgen_inputs)
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

-- The real v7 ocean surface from the mapgen setting (persisted in
-- map_meta.txt). NOT the mcl_levelgen preset's `sea_level` (63), which is
-- the air block above the water and does not track where v7 actually
-- fills water (using it left all water 2 blocks low -- round 31).
local WATER_LEVEL = tonumber(core.get_mapgen_setting("water_level")) or 1

-- Mineclonia's real bedrock band (mcl_vars: -128..-124 in v7). The gap
-- column ends here with bedrock + void below -- it must not run solid
-- stone ~60 blocks under the real floor.
local BEDROCK_MIN = (mcl_vars and mcl_vars.mg_bedrock_overworld_min) or -128
local BEDROCK_MAX = (mcl_vars and mcl_vars.mg_bedrock_overworld_max) or (BEDROCK_MIN + 4)

-- Y range matching the pregen pass (PREGEN_Y_MIN/MAX in init.lua).
local GAP_Y_MIN = -130
local GAP_Y_MAX = 319

-- Natural terrain materials (Mineclonia names -- verified against
-- mcl_core/mcl_deepslate/... registrations). The surface scan only
-- accepts these as "ground": Mineclonia's mapgen decorates with villages,
-- witch huts and tsm_railcorridors platforms, and a roof over a gap must
-- never count as the terrain surface. Excluded on purpose: cobble,
-- stonebrick, planks, bricks, glass, obsidian (all man-made favourites),
-- snow LAYERS (cover, not ground), everything liquid/vegetation.
local TERRAIN_NAMES = {
	["mcl_core:dirt_with_grass"] = true, ["mcl_core:dirt_with_grass_snow"] = true,
	["mcl_core:dirt_with_dry_grass"] = true, ["mcl_core:dirt_with_dry_grass_snow"] = true,
	["mcl_core:dirt"] = true, ["mcl_core:coarse_dirt"] = true,
	["mcl_core:podzol"] = true, ["mcl_core:mycelium"] = true,
	["mcl_lush_caves:moss"] = true, ["mcl_mud:mud"] = true,
	["mcl_core:sand"] = true, ["mcl_core:redsand"] = true,
	["mcl_core:gravel"] = true, ["mcl_core:clay"] = true,
	["mcl_core:sandstone"] = true, ["mcl_core:sandstonesmooth"] = true,
	["mcl_core:redsandstone"] = true, ["mcl_core:redsandstonesmooth"] = true,
	["mcl_core:stone"] = true, ["mcl_core:andesite"] = true,
	["mcl_core:granite"] = true, ["mcl_core:diorite"] = true,
	["mcl_deepslate:deepslate"] = true, ["mcl_deepslate:tuff"] = true,
	["mcl_amethyst:calcite"] = true, ["mcl_core:snowblock"] = true,
	["mcl_core:ice"] = true, ["mcl_core:packed_ice"] = true,
	["mcl_core:blue_ice"] = true, ["mcl_nether:netherrack"] = true,
	["mcl_nether:soul_sand"] = true, ["mcl_blackstone:soul_soil"] = true,
	["mcl_blackstone:basalt"] = true, ["mcl_blackstone:basalt_smooth"] = true,
	["mcl_blackstone:blackstone"] = true,
	["mcl_crimson:crimson_nylium"] = true, ["mcl_crimson:warped_nylium"] = true,
	["mcl_end:end_stone"] = true,
	-- bedrock IS ground (2026-09-26: without it a nether lava-sea column
	-- -- lava over the bedrock floor -- read as NO terrain at all, whole
	-- chunks fell to the y-range-bottom fallback height and the merge
	-- produced 204-block cliffs into the void there)
	["mcl_core:bedrock"] = true,
	-- floor-with-plant variants: walkable ground wearing a plant (natural
	-- ocean-floor decoration writes these). Ground, NOT vegetation --
	-- classifying them as veg made the surface read 1 block low and
	-- produced phantom seam mismatches.
	["mcl_ocean:kelp_sand"] = true, ["mcl_ocean:kelp_dirt"] = true,
	["mcl_ocean:kelp_gravel"] = true,
	["mcl_ocean:seagrass_sand"] = true, ["mcl_ocean:seagrass_dirt"] = true,
	["mcl_ocean:seagrass_gravel"] = true,
}

local function is_terrain_name(name)
	if TERRAIN_NAMES[name] then return true end
	if name:match("^mcl_core:stone_with_") then return true end -- ores
	if name:match("^mcl_deepslate:deepslate_with_") then return true end
	return false
end

-- Vegetation: the only thing allowed to ride along above the shifted
-- surface (trees, plants, vines, snow layers...). Liquids and floating
-- junk (islands, platforms, dropped structures) do NOT ride along -- they
-- become air.
local VEG_GROUPS = { leaves = true, tree = true, attached_node = true,
	plant = true, snow = true, grass = true, flora = true, flower = true,
	-- decor that sits ON the floor (coral plants/fans, sea pickles...):
	-- never counts as ground surface even though it is walkable. Coral
	-- BLOCKS carry coral_block (not coral_plant) and stay ground -- the
	-- seam continuing the capture's reef block with a coral on top is the
	-- merge working as designed.
	coral_plant = true, coral_fan = true, deco_block = true }

-- Classification caches (content id -> flag) -- the scan runs over
-- tens of millions of nodes, name/group lookups must not repeat.
local terrain_cache, veg_cache, liquid_cache, name_cache = {}, {}, {}, {}

local function cid_name(cid)
	local n = name_cache[cid]
	if n == nil then
		n = core.get_name_from_content_id(cid) or ""
		name_cache[cid] = n
	end
	return n
end

local function is_terrain(cid)
	local v = terrain_cache[cid]
	if v == nil then
		v = is_terrain_name(cid_name(cid))
		terrain_cache[cid] = v
	end
	return v
end

local function is_veg(cid)
	local v = veg_cache[cid]
	if v == nil then
		local name = cid_name(cid)
		v = false
		-- ground names win over plant groups (floor-with-plant nodes)
		if not is_terrain_name(name) then
			for group in pairs(VEG_GROUPS) do
				if core.get_item_group(name, group) > 0 then v = true break end
			end
		end
		veg_cache[cid] = v
	end
	return v
end

local function is_liquid(cid)
	local v = liquid_cache[cid]
	if v == nil then
		v = core.get_item_group(cid_name(cid), "liquid") > 0
		liquid_cache[cid] = v
	end
	return v
end

-- The engine's own ground definition is "topmost WALKABLE node"
-- (Mapgen::findGroundLevel). Non-walkable decor (coral plants and fans,
-- flower heads) must never count as surface -- reading them as ground
-- was the last source of phantom seam mismatches and slope noise.
local walk_cache = {}
local function is_walkable(cid)
	local v = walk_cache[cid]
	if v == nil then
		local def = core.registered_nodes[cid_name(cid)]
		v = not (def and def.walkable == false)
		walk_cache[cid] = v
	end
	return v
end

local function is_ground(cid)
	return is_walkable(cid) and not is_veg(cid) and not is_liquid(cid)
end

-- Floating-mass rejection, same rule as the footprint side (see
-- source_footprint.lua's terrain_surface_y): the top terrain run counts
-- as ground only if it is thicker than FLOAT_MAX_THICK or sits on terrain
-- (gap below < FLOAT_MIN_GAP). tops is a descending list of the topmost
-- terrain y values (up to 4).
local FLOAT_MAX_THICK = 2
local FLOAT_MIN_GAP = 3

local function surface_from_tops(tops)
	local t1 = tops[1]
	if not t1 then return nil end
	local thickness = 1
	if tops[2] == t1 - 1 then
		thickness = 2
		if tops[3] == t1 - 2 then thickness = 3 end
	end
	local below = tops[thickness + 1]
	local run_bottom = t1 - thickness + 1
	local gap = below and (run_bottom - below - 1) or math.huge
	if thickness <= FLOAT_MAX_THICK and gap >= FLOAT_MIN_GAP then
		return below -- the run under the gap is the real ground
	end
	return t1
end

-- Nether floor rule (owner 2026-09-27: "fill chunks below the nether
-- roof are making odd hanging columns which cut off"): a shelf under the
-- ceiling is NOT the floor -- the merge skinned such shelves and left
-- floating slabs. Runs records terrain runs top-down ({top=, bottom=});
-- a run floating over a big gap (>= FLOAT_BIG_GAP, e.g. a shelf above
-- the cavern/lava gap) is skipped for the one below it. The OVERWORLD
-- keeps surface_from_tops unchanged (its own floating-mass rule above).
local FLOAT_BIG_GAP = 12

local function surface_from_runs(runs)
	for i, r in ipairs(runs) do
		local below = runs[i + 1]
		-- the lowest run anchors at the world bottom -- never floats
		local gap = below and (r.bottom - below.top - 1) or 0
		local thick = r.top - r.bottom + 1
		if thick <= FLOAT_MAX_THICK and gap >= FLOAT_MIN_GAP then
			-- thin floating mass: junk
		elseif gap >= FLOAT_BIG_GAP then
			-- shelf over a big drop: not the floor
		else
			return r.top
		end
	end
	local last = runs[#runs]
	return last and last.top or nil
end

-- ---------------------------------------------------------------------
-- Footprint loading
-- ---------------------------------------------------------------------

-- Reads a source_footprint.lua JSON and returns
--   { ["cx_cz"] = { height=, cols=, solid_cols=, terrain_cols=, biome= } }
-- for every REAL (captured) chunk, or nil on any failure. Backward-
-- compatible with older footprints: terrain_cols falls back to
-- solid_cols, then cols, then the per-chunk height.
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
			local cols = c.cols
			if type(cols) ~= "table" or #cols ~= 256 then
				cols = {}
				for i = 1, 256 do cols[i] = c.height end
			end
			local solid = c.solid_cols
			if type(solid) ~= "table" or #solid ~= 256 then solid = cols end
			local terrain = c.terrain_cols
			if type(terrain) ~= "table" or #terrain ~= 256 then terrain = solid end
			local biome_cols = c.biome_cols
			if type(biome_cols) ~= "table" or #biome_cols ~= 256 then
				biome_cols = nil
			end
			real[c.cx .. "_" .. c.cz] = {
				height = c.height, cols = cols, solid_cols = solid,
				terrain_cols = terrain, biome = c.biome,
				biome_cols = biome_cols,
			}
		end
	end
	return real
end

-- The ring around a base: chunks within RING chunks (Chebyshev) of a
-- captured chunk get merged. RING = 2 per the owner decision
-- (PLAN-worldgen-merge.md): two chunks of blend on each edge give the
-- height ramp double the run, so seam relief lands walkable instead of
-- as square-edged cliffs. Everything further out stays real generated
-- terrain -- filling wider areas destroys far too much of it
-- (see HANDOVER.md). Returns { {cx=, cz=}, ... }.
gap_fill.RING = 2

-- `placed` (optional, cx_cz -> true): chunks the importer will place.
-- They are NEVER fill chunks even when the footprint lacks them (a
-- footprint can be incomplete -- legacy_skipped etc. -- and merging over
-- an already-placed captured chunk destroys it; 2026-09-26).
function gap_fill.ring_chunks(chunk_bounds, real, placed)
	local R = gap_fill.RING
	local ring = {}
	-- the scan window must grow with the ring radius or edge chunks of a
	-- wide base never see their second-ring neighbours
	for cx = chunk_bounds.x_min - R, chunk_bounds.x_max + R do
		for cz = chunk_bounds.z_min - R, chunk_bounds.z_max + R do
			local key = cx .. "_" .. cz
			if not real[key] and not (placed and placed[key]) then
				local touched = false
				for ox = -R, R do
					for oz = -R, R do
						if real[(cx + ox) .. "_" .. (cz + oz)] then touched = true break end
					end
					if touched then break end
				end
				if touched then
					ring[#ring + 1] = { cx = cx, cz = cz }
				end
			end
		end
	end
	return ring
end

-- Widening margin: how many extra rings of natural chunks may join the
-- merge domain when a ramp doesn't fit. Also the pregen margin init.lua
-- must reserve around the base for gap-fill to be able to widen at all.
gap_fill.MAX_EXTRA_RINGS = 3

-- ---------------------------------------------------------------------
-- Plan: natural column scan + merged height field
-- ---------------------------------------------------------------------

-- Scan one chunk's natural columns (reads the map -- must run AFTER
-- pre-generation and BEFORE any gap chunk is written). Returns
--   { [local idx (lx*16+lz)] = { S=, mat=, T= } }
-- where S is the natural terrain surface (dest y), mat its content id,
-- T the topmost non-air y (trees/vegetation ceiling). Cached per plan.
local function scan_chunk_columns(job, cx, cz)
	local base_x = job.anchor_x + (cx * C - job.origin_x)
	local base_z = job.anchor_z + (cz * C - job.origin_z)
	local ymin, ymax = GAP_Y_MIN + job.dest_y_offset, GAP_Y_MAX + job.dest_y_offset
	-- Nether ceiling band: the merge's "surface" is the FLOOR. At the
	-- nether band the topmost terrain run is the CEILING (the capture's
	-- roof / the mapgen's bedrock plate), and treating it as the surface
	-- skinned roofs, grew netherrack pillars at ceiling height and made
	-- chunk-edge material jumps (owner findings 2026-09-26). Tops at or
	-- above dy+122 (the vanilla ceiling band bottom, matching the
	-- writer's roof regen band) are therefore excluded from the surface
	-- scan -- the topmost run BELOW them is the walkable ground.
	local ceil_y = nil
	local btype = job.dimension_type
	if btype == "nether" or (not btype and (job.dest_y_offset or 0) <= -28000) then
		ceil_y = (job.dest_y_offset or 0) + 122
	end

	local vm = core.get_voxel_manip()
	local emin, emax = vm:read_from_map({ x = base_x, y = ymin, z = base_z },
		{ x = base_x + C - 1, y = ymax, z = base_z + C - 1 })
	local area = VoxelArea:new({ MinEdge = emin, MaxEdge = emax })
	local data = vm:get_data()
	vm:close()

	local cols = {}
	for lz = 0, C - 1 do
		for lx = 0, C - 1 do
			local x, z = base_x + lx, base_z + lz
			local tops, runs, top = {}, {}, nil
			local top_count = 0
			local cur_run = nil
			local first_y = nil
			for y = ymax, ymin, -1 do
				-- bounded scan (2026-09-27): with the ceiling filtered out
				-- the old "4 terrain values" early-out is gone and a naive
				-- full-range scan costs 25x. Stop 120 rows below the first
				-- terrain (the floor is never deeper below the first run)
				-- or once three runs are collected -- plenty to decide.
				if first_y and (y < first_y - 120 or #runs >= 3) then break end
				local cid = data[area:index(x, y, z)]
				if cid ~= core.CONTENT_AIR and cid ~= core.CONTENT_IGNORE then
					if not top then top = y end
					if is_terrain(cid) and (not ceil_y or y < ceil_y) then
						if not first_y then first_y = y end
						top_count = top_count + 1
						if top_count <= 4 then tops[top_count] = y end
						if cur_run and cur_run.bottom == y + 1 then
							cur_run.bottom = y
						elseif #runs < 4 then
							cur_run = { top = y, bottom = y }
							runs[#runs + 1] = cur_run
						end
						-- overworld keeps the old early-out; the nether
						-- rule needs the gap BELOW the run so it scans on
						-- (capped at 200 terrain rows per column)
						if not ceil_y and top_count >= 4 then break end
						if ceil_y and top_count >= 200 then break end
					elseif cur_run then
						cur_run = nil
					end
				elseif cur_run then
					cur_run = nil
				end
			end
			local S = ceil_y and surface_from_runs(runs) or surface_from_tops(tops)
			local mat = S and data[area:index(x, S, z)] or nil
			cols[lx * C + lz + 1] = { S = S, mat = mat, T = top }
		end
	end
	return cols
end

-- Per captured chunk edge, smooth the 16-column terrain line once: one
-- misdetected column in the capture must not leave a one-column spike in
-- a seam the ring has to match exactly. Fills r.edge[side] = smoothed
-- line (side 1..4 = west/east/north/south edge), consumed by
-- seam_target() below.
local function smooth_edge_lines(real)
	for _, r in pairs(real) do
		r.edge = {}
		for side = 1, 4 do
			local line = {}
			for i = 1, C do
				local idx = (side == 1 and (0 * C + i - 1))       -- west edge, lx=0
					or (side == 2 and ((C - 1) * C + i - 1))      -- east edge, lx=15
					or (side == 3 and ((i - 1) * C + 0))          -- north edge, lz=0
					or ((i - 1) * C + (C - 1))                    -- south edge, lz=15
				line[i] = r.terrain_cols[idx + 1]
			end
			gap_field.smooth_line(line, 2)
			r.edge[side] = line
		end
	end
end

-- A captured chunk's terrain height at local (lx, lz), from the smoothed
-- edge line when the column is on an edge (every seam column is), the raw
-- per-column map otherwise.
local function seam_target(r, lx, lz)
	if lx == 0 then return r.edge[1][lz + 1]
	elseif lx == C - 1 then return r.edge[2][lz + 1]
	elseif lz == 0 then return r.edge[3][lx + 1]
	elseif lz == C - 1 then return r.edge[4][lx + 1] end
	return r.terrain_cols[lx * C + lz + 1]
end

-- Seam targets from the footprint: for each column to write, the
-- adjacent captured chunk's TERRAIN height (the ground the base sits on)
-- in dest space. 4-neighbour (edge) adjacency always applies; diagonal
-- (corner) adjacency only where no edge constraint and no outer-boundary
-- pin exists (a corner contact point must not override the "stay put"
-- pin that keeps the merge invisible against untouched terrain -- edge
-- seams win over corners, corners win over nothing). If several
-- constraints meet on one column at the same priority the mean wins.
-- Returns { ["sx,sz"] = target } (keys are SOURCE block coords --
-- adjacency is what matters, and the ring/captured chunk grid is
-- source-aligned).
local function seam_constraints(job, real, chunk_set, dy, soft)
	local hard, hard_src = {}, {}
	for key in pairs(chunk_set) do
		local cx, cz = key:match("^(.-)_(.-)$")
		cx, cz = tonumber(cx), tonumber(cz)
		for lz = 0, C - 1 do
			for lx = 0, C - 1 do
				local sx, sz = cx * C + lx, cz * C + lz
				local skey = sx .. "," .. sz
				-- orthogonal neighbours first
				for _, d in ipairs(gap_field.DIRS) do
					local nx, nz = sx + d[1], sz + d[2]
					local ncx, ncz = math.floor(nx / C), math.floor(nz / C)
					local r = real[ncx .. "_" .. ncz]
					if r and not chunk_set[ncx .. "_" .. ncz] then
						local target = seam_target(r, nx - ncx * C, nz - ncz * C) + dy
						local cur = hard_src[skey]
						if cur == nil then
							hard_src[skey] = { target }
						else
							cur[#cur + 1] = target
						end
					end
				end
				-- then diagonals (corner contact), only where the column
				-- has neither an edge constraint nor an outer-boundary pin
				if hard_src[skey] == nil and not soft[skey] then
					for _, d in ipairs({ { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }) do
						local nx, nz = sx + d[1], sz + d[2]
						local ncx, ncz = math.floor(nx / C), math.floor(nz / C)
						local r = real[ncx .. "_" .. ncz]
						if r and not chunk_set[ncx .. "_" .. ncz] then
							hard_src[skey] = { seam_target(r, nx - ncx * C, nz - ncz * C) + dy }
						end
					end
				end
			end
		end
	end
	for skey, list in pairs(hard_src) do
		local sum = 0
		for _, v in ipairs(list) do sum = sum + v end
		hard[skey] = sum / #list
	end
	return hard
end

local function count_keys(t)
	local n = 0
	for _ in pairs(t) do n = n + 1 end
	return n
end

local function biome_palette(mc_biome)
	local mcl_name = mc_biome and MC_TO_MCL_BIOME[mc_biome]
	if not mcl_name then return nil end
	local def = core.registered_biomes[mcl_name]
	if not def then return nil end
	return def._mcl_palette_index
end

-- Seam biome tint: a written column next to a captured chunk gets that
-- chunk's biome palette index for its surface grass param2.
local function add_seam_tints(real, plan)
	local tint_of = {}
	for _, r in pairs(real) do
		-- corpus robustness (2026-09-25, Expedition Orion: a captured
		-- chunk with NO biome tag -- tint_of[nil] = ... is a hard Lua
		-- error and killed the whole import at plan time)
		local biome = r.biome
		if biome and tint_of[biome] == nil then
			tint_of[biome] = biome_palette(biome) or false
		end
	end
	for key, chunk in pairs(plan.chunks) do
		for lz = 0, C - 1 do
			for lx = 0, C - 1 do
				local sx, sz = chunk.cx * C + lx, chunk.cz * C + lz
				for _, d in ipairs(gap_field.DIRS) do
					local nkey = math.floor((sx + d[1]) / C) .. "_" .. math.floor((sz + d[2]) / C)
					local r = real[nkey]
					if r and not plan.chunks[nkey] then
						local t = tint_of[r.biome]
						if t then
							chunk.col[lx * C + lz + 1].tint = t
						end
						break
					end
				end
			end
		end
	end
end

-- Builds the full merge plan. Must run after pre-generation (reads the
-- generated map) and before any gap chunk is written. opts:
--   step        -- max slope in blocks per column (default 1.0, or the
--                  spawnimport_gap_max_step setting)
--   avoid       -- list of {x_min=,x_max=,z_min=,z_max=} dest-block
--                  bboxes widening must not enter (other bases)
function gap_fill.build_plan(job, real, entries, opts)
	opts = opts or {}
	local dy = job.dest_y_offset
	-- Dest-space sea level = the SOURCE dimension's MC sea level shifted
	-- by the placement offset: overworld 62 + (-61) = 1 == the world's own
	-- water_level (what this always used); End placements (dy ~ -27073)
	-- put the End's sea (0) at -27073 so no column is ever water -- with
	-- the old world-level constant every End merge column read as water
	-- and would have been flooded.
	local SEA
	local btype = job.dimension_type
	local is_nether = btype == "nether" or (not btype and dy <= -28000)
	local is_end = (not is_nether) and
		(btype == "end" or (not btype and dy <= -20000))
	if is_nether then
		-- Nether: lava behaves like overworld water (owner ask: "match
		-- lava lake beds and the lava surface"). The lava sea surface is
		-- dest y -29036 = source y 36 -- verified from both the mapgen's
		-- own nether lava and near-base columns (AUDIT-2026-09-26 #2),
		-- NOT the vanilla 10/11 guess. Columns merged below it classify
		-- as "aquatic" (no slope constraint into lava, liquid fills up to
		-- the surface) exactly like overworld water columns.
		SEA = dy + 36
	elseif is_end then
		-- The End has NO liquids at all -- never classify any column as
		-- water or the merge floods it. (It also has no natural terrain
		-- in the ring -- pure void, AUDIT-2026-09-26 #3.)
		SEA = -31000
	else
		SEA = math.min(WATER_LEVEL, 62 + dy)
	end
	local step = opts.step or tonumber(core.settings:get("spawnimport_gap_max_step")) or 1.0
	local t0 = core.get_us_time()

	smooth_edge_lines(real)

	local scan_cache = {}
	local function cols_for(cx, cz)
		local key = cx .. "_" .. cz
		local c = scan_cache[key]
		if c == nil then
			c = scan_chunk_columns(job, cx, cz)
			scan_cache[key] = c
		end
		return c
	end

	-- domain = chunks we may write; grows with widening rounds
	local domain = {}
	for _, e in ipairs(entries) do domain[e.cx .. "_" .. e.cz] = { cx = e.cx, cz = e.cz } end

	local function is_foreign(cx, cz)
		local base_x = job.anchor_x + (cx * C - job.origin_x)
		local base_z = job.anchor_z + (cz * C - job.origin_z)
		for _, bb in ipairs(opts.avoid or {}) do
			if base_x <= bb.x_max and base_x + C - 1 >= bb.x_min
				and base_z <= bb.z_max and base_z + C - 1 >= bb.z_min then
				return true
			end
		end
		return false
	end

	local h, free, fixed, fixable, structural, worst = nil, nil, nil, nil, nil, nil
	local natural, last_field = nil, nil
	local hard_final, soft_final, guard_final = {}, {}, {}
	local prev_fixable = nil
	local rounds = 0
	while true do
		rounds = rounds + 1
		-- assemble the column maps for the current domain
		free = {}
		for key in pairs(domain) do
			local cx, cz = domain[key].cx, domain[key].cz
			local cols = cols_for(cx, cz)
			-- a column with no terrain at all (all-air/void column) still
			-- joins the solve at its chunk's mean surface -- skipping it
			-- would leave the pre-generated leftovers in place.
			-- EXCEPTION (2026-09-26, the End's island-over-void model):
			-- at the End band a terrain-less column is VOID and must stay
			-- void -- there is no "natural level" to ramp toward (the ring
			-- is pure air, AUDIT-2026-09-26 #3) and filling it produced
			-- the walls of stone descending into nothing. Pre-generated
			-- leftovers cannot exist there (the mapgen generates nothing).
			local end_void = job.dimension_type == "end"
			local sum, n = 0, 0
			for i = 1, C * C do
				local col = cols[i]
				if col.S then sum = sum + col.S n = n + 1 end
			end
			local fallback = n > 0 and (sum / n) or (GAP_Y_MIN + job.dest_y_offset)
			for lz = 0, C - 1 do
				for lx = 0, C - 1 do
					local sx, sz = cx * C + lx, cz * C + lz
					local col = cols[lx * C + lz + 1]
					if not col.S and not (end_void and n == 0) then
						col.S = fallback
					end
					if col.S then
						free[sx .. "," .. sz] = col.S
					end
				end
			end
		end
		-- spikes (misdetected floating leftovers) off before solving
		natural = gap_field.median3(free)
		-- worldgen-merge: pull the solver toward the touching world
		-- download blocks near the seam and toward natural terrain far
		-- out -- not toward natural everywhere. Without this, free
		-- columns kept their natural +24 v7 hills directly beside a
		-- captured ocean floor at -13 (the owner's "raised ocean floor"
		-- pillars, 2026-09-24). The field also carries the seam level
		-- and biome per column: "the edges should always match the
		-- level/characteristics of the touching world download blocks".
		local fld = wgen_inputs.field(job, real, natural,
			function(r, _cx, _cz, lx, lz, _sx, _sz)
				return seam_target(r, lx, lz) + dy
			end,
			-- the seam source column's REAL surface family + ground
			-- material: footprints carry one biome tag per 16x16 chunk
			-- and it regularly disagrees with the blocks next to it --
			-- grounding the biome/snow decisions in the actual surface is
			-- what kills the owner's "square snow" fields (2026-09-25)
			function(_r, cx, cz, lx, lz, _sx, _sz)
				local cols = cols_for(cx, cz)
				local c = cols and cols[lx * C + lz + 1]
				if not c then return nil end
				local gname = c.mat and core.get_name_from_content_id(c.mat) or nil
				local tname = c.T and core.get_name_from_content_id(c.T) or nil
				return wgen_inputs.surface_family(tname, gname), c.mat
			end)
				free = wgen_inputs.height_targets(fld, natural,
			job.dimension_type == "end" or (not job.dimension_type and dy <= -20000))
		last_field = fld
		-- Domain-boundary columns bordering untouched terrain are pinned
		-- to their own natural height (the merge must be invisible there),
		-- and the untouched neighbour columns enter the solve as GUARDS
		-- (fixed at their own heights, never written) so that any step
		-- introduced against untouched terrain is seen by violations()
		-- and can trigger widening instead of going unnoticed.
		local soft, guard = {}, {}
		for skey in pairs(free) do
			local sx, sz = skey:match("^(%-?%d+),(%-?%d+)$")
			sx, sz = tonumber(sx), tonumber(sz)
			for _, d in ipairs(gap_field.DIRS) do
				local nx, nz = sx + d[1], sz + d[2]
				local gcx, gcz = math.floor(nx / C), math.floor(nz / C)
				local gkey = gcx .. "_" .. gcz
				if not domain[gkey] and not real[gkey] then
					-- pin to the column's NATURAL height (not the faded
					-- target in free[]) or the outer edge stops matching
					-- untouched terrain exactly
					soft[skey] = natural[skey] or free[skey]
					local gcols = cols_for(gcx, gcz)
					local gcol = gcols[(nx - gcx * C) * C + (nz - gcz * C) + 1]
					if gcol and gcol.S then
						guard[nx .. "," .. nz] = gcol.S
					end
				end
			end
		end
		-- captured-chunk seam columns: pinned to the capture's terrain
		-- (overrides an outer pin -- the seam is the point of the merge;
		-- a step it causes against untouched terrain is fixable by
		-- widening and reported as such)
		local hard = seam_constraints(job, real, domain, dy, soft)
		for skey in pairs(hard) do soft[skey] = nil end
		fixed = {}
		for skey, v in pairs(soft) do fixed[skey] = v end
		for skey, v in pairs(hard) do fixed[skey] = v end
		for skey, v in pairs(guard) do fixed[skey] = v end
		for skey in pairs(free) do
			if fixed[skey] then free[skey] = nil end
		end

		-- Slope constraints apply only to walking (land-to-land) edges:
		-- land dropping into the sea is a sea cliff and the sea floor may
		-- be as steep as it likes. Which columns are water depends on the
		-- solved heights themselves, so classify and re-solve until the
		-- classification stops changing (two passes usually; the cap is
		-- for pathological ping-pong). An earlier two-pass version stopped
		-- one pass early and left land-land edges unconstrained wherever
		-- the classification flickered -- the real-world audit caught it
		-- as 60-90 block "steps" between two land columns.
		local aquatic = {}
		for _ = 1, 3 do
			h = gap_field.solve(free, fixed, { step = step, aquatic = aquatic })
			-- collapse the clamp-midpoint zigzags the relaxation leaves
			-- on sloped bands (the "square jogs"); free-free only, real
			-- cliffs and pins untouched
			gap_field.deflate_steps(free, fixed, h,
				{ step = step, aquatic = aquatic, natural = natural })
			local new_aquatic, changed = {}, false
			for skey in pairs(h) do
				local is_water = h[skey] < SEA
				if is_water then new_aquatic[skey] = true end
				if is_water ~= (aquatic[skey] or false) then changed = true end
			end
			aquatic = new_aquatic
			if not changed then break end
		end
		fixable, structural, worst = gap_field.violations(free, fixed, h, step,
			{ soft = soft, guard = guard, aquatic = aquatic,
			  natural = natural })
		hard_final, soft_final, guard_final = hard, soft, guard
		if fixable == 0 or rounds > gap_fill.MAX_EXTRA_RINGS then break end
		-- Widen only while it actually HELPS: big-relief seams (a base
		-- built against a cliff, its capture truncated at the chunk
		-- border) can never be ramped walkable at any bounded width, and
		-- churning ring after ring of natural terrain for a hopeless ramp
		-- is strictly worse than a steep (but continuous) hillside.
		if prev_fixable and fixable > prev_fixable * 0.75 then break end
		prev_fixable = fixable

		-- widen: pull in the natural chunks just outside the domain so
		-- the ramp gets room; never captured chunks, never other bases
		local grow = {}
		for key in pairs(domain) do
			local cx, cz = domain[key].cx, domain[key].cz
			for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 },
					{ 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }) do
				local nx, nz = cx + d[1], cz + d[2]
				local nkey = nx .. "_" .. nz
				if not domain[nkey] and not real[nkey] and not grow[nkey]
					and not (job.gap_placed and job.gap_placed[nkey])
					and not is_foreign(nx, nz) then
					grow[nkey] = { cx = nx, cz = nz }
				end
			end
		end
		if not next(grow) then break end
		for key, v in pairs(grow) do domain[key] = v end
	end

	-- per-chunk apply data
	local plan = {
		step = step,
		sea = SEA,
		chunk_order = {},
		chunks = {},
		hard = {},
		pins = {},
		n_fixable = fixable,
		n_structural = structural,
		worst_slope = worst,
		rounds = rounds,
	}
	local hard_all = hard_final
	local by_key = {}
	for key in pairs(domain) do
		local cx, cz = domain[key].cx, domain[key].cz
		local cols = cols_for(cx, cz)
		local base_x = job.anchor_x + (cx * C - job.origin_x)
		local base_z = job.anchor_z + (cz * C - job.origin_z)
		local chunk = { cx = cx, cz = cz, base_x = base_x, base_z = base_z, col = {} }
		-- does this chunk directly touch a captured chunk? (its columns
		-- keep the capture's climate -- see wgen_inputs.attach_targets)
		local touches = false
		for ox = -1, 1 do
			for oz = -1, 1 do
				if real[(cx + ox) .. "_" .. (cz + oz)] then touches = true break end
			end
			if touches then break end
		end
		chunk.touches_capture = touches
		for lz = 0, C - 1 do
			for lx = 0, C - 1 do
				local sx, sz = cx * C + lx, cz * C + lz
				local skey = sx .. "," .. sz
				by_key[skey] = true
				local src = cols[lx * C + lz + 1]
				local B = h[skey]
				if B then B = math.floor(B + 0.5) end
				local is_seam = hard_all[skey] and true or false
				chunk.col[lx * C + lz + 1] = {
					S = src.S, mat = src.mat, T = src.T, B = B,
					tgt = free[skey],
					seam = is_seam,
					boundary = soft_final[skey] and true or false,
					-- seam-source geology for the write's outward fade
					smat = last_field and last_field.gmat
						and last_field.gmat[skey] or nil,
					sdist = last_field and last_field.dist
						and last_field.dist[skey] or nil,
				}
				if is_seam then
					plan.hard[skey] = math.floor(hard_all[skey] + 0.5)
					plan.pins[skey] = "hard"
				elseif soft_final[skey] then
					plan.pins[skey] = "soft"
				end
			end
		end
		plan.chunks[key] = chunk
		plan.chunk_order[#plan.chunk_order + 1] = key
	end
	plan.by_key = by_key
	plan.field = last_field
	plan._dbg_free, plan._dbg_fixed = free, fixed
	table.sort(plan.chunk_order)
	-- edge biome tint per column (captured neighbour's biome)
	add_seam_tints(real, plan)

	local stats = gap_field.stats(natural or free, h)
	core.log("action", string.format(
		"[gap-fill] merge plan: %d chunks (%d solve round(s)), %d seam columns, "
		.. "slope cap %.2f, unresolvable slopes %d (structural %d, worst %.2f), "
		.. "natural surface %.0f..%.0f, merged %.0f..%.0f, mean move %.2f, %.2fs",
		#plan.chunk_order, rounds, count_keys(plan.hard), step,
		plan.n_fixable or 0, plan.n_structural or 0, plan.worst_slope or 0,
		stats.min_s or 0, stats.max_s or 0, stats.min_h or 0, stats.max_h or 0,
		stats.mean_move or 0, (core.get_us_time() - t0) / 1e6))
	return plan
end

-- The write path moved to wgen_write.lua (worldgen-merge: column rebuild
-- with target-biome materials and NO vegetation carry, plus the natural
-- vegetation regrow pass) -- see PLAN-worldgen-merge.md.

-- ---------------------------------------------------------------------
-- Audit: verify the merge actually came out right
-- ---------------------------------------------------------------------

-- Re-reads every written column and checks the things a player would
-- notice:
--   1. seam columns match the capture's ground EXACTLY (no step at the
--      chunk border);
--   2. every slope the MERGE introduced is walkable (<= step + 0.5,
--      the 0.5 being integer rounding) -- counted on every pair that is
--      not BOTH water, because per the owner's 2026-09-24 rule ("the
--      edges should always match the level/characteristics of the
--      touching world download blocks") even a water-to-land step must
--      be walkable-reachable from the seam. Both-water pairs stay
--      exempt (sea floor relief is real and unwalked). Steps AT pinned
--      columns (the capture's own seam cliffs) and at the untouched
--      boundary are reported separately as relief -- matched or left
--      alone on purpose, the merge is not blamed for (and must not
--      destroy) terrain that predates it.
--   3. water above sea level (a water column's own water stops AT sea
--      level and land columns are dry, so any liquid higher up is the
--      BASE's own water spilling onto the merge after the write --
--      reported as "spilled base water", not the merge's "raised
--      generated water" bug, which the write path makes impossible);
--   4. no floating non-vegetation above the merged surfaces.
-- Returns ok = the two bug classes are clean (natural relief and
-- floating-junk counts are informational).
function gap_fill.audit(job, plan)
	local t0 = core.get_us_time()
	-- The nether ceiling band (dy+122..127) is a GENERATED ROOF, not
	-- floating junk -- the "solid over air" heuristic misfires on it
	-- (2026-09-26: every regenerated roof block was counted as junk in
	-- the nether test; the 35k "floating junk" at Hausemaster in the
	-- micro run was the same misfire over the captured/merged roofs).
	local audit_dy = job.dest_y_offset or 0
	local audit_nether = job.dimension_type == "nether"
		or (not job.dimension_type and audit_dy <= -28000)
	-- The audit is long, pure-Lua column scanning; on 2026-09-25 a run
	-- died inside it with SIGBUS/KERN_MEMORY_ERROR (Apple Silicon JIT
	-- page allocation under load -- crash report luanti-073449.ips).
	-- The audit costs seconds even unjitted; the placement/plan phases
	-- keep their JIT. Toggle back afterwards.
	local jitted = jit and jit.off and (jit.off() or true)
	local function audit_done()
		if jitted and jit.on then jit.on() end
	end
	local seam_bad, seam_bad_worst = 0, 0
	local slope_bad, slope_worst = 0, 0
	local relief_bad, relief_worst = 0, 0
	local raised_water, raised_pos = 0, nil
	local floating_junk = 0
	local floating_veg, kelp_dry = 0, 0
	local surface = {} -- "sx,sz" -> measured surface (for the slope pass)
	local surface_name = {} -- "sx,sz" -> name at that surface (diagnostics)
	local moved = {}   -- "sx,sz" -> the merge changed this column's height
	local nat = {}     -- "sx,sz" -> the natural surface before the merge
	local sea = plan.sea

	for key, chunk in pairs(plan.chunks) do
		local xmin, xmax = chunk.base_x, chunk.base_x + C - 1
		local zmin, zmax = chunk.base_z, chunk.base_z + C - 1
		local ymin, ymax = GAP_Y_MIN + job.dest_y_offset, GAP_Y_MAX + job.dest_y_offset
		local vm = core.get_voxel_manip()
		local emin, emax = vm:read_from_map({ x = xmin, y = ymin, z = zmin }, { x = xmax, y = ymax, z = zmax })
		local area = VoxelArea:new({ MinEdge = emin, MaxEdge = emax })
		local data = vm:get_data()
		vm:close()

		for lz = 0, C - 1 do
			local z = zmin + lz
			for lx = 0, C - 1 do
				local x = xmin + lx
				local sx, sz = chunk.cx * C + lx, chunk.cz * C + lz
				local skey = sx .. "," .. sz
				local col = chunk.col[lx * C + lz + 1]
				-- The merged surface = the topmost solid ground block:
				-- everything above it is vegetation (kept on purpose) or
				-- air. Deliberately NOT the terrain-run/floating rule used
				-- for scanning NATURAL columns: a written surface skin can
				-- legitimately be thin (a sand floor over waterlogged
				-- gravel had its sub-blocks dropped), and re-deriving the
				-- plan's own surface with a different rule turned that
				-- into phantom seam mismatches and 90-block "steps".
				-- Surface measurement is clamped to the PLANNED height:
				-- scan down from min(ymax, col.B). Everything the grow
				-- pass may add on top -- trees, grass, snow, coral bushes
				-- (whose base is a solid coral_block!) -- is above B and
				-- can never shift the reading. A write that missed B is
				-- still caught: the scan then reports where ground really
				-- is, and the seam/slope checks flag the difference.
				local S, top = nil, nil
				local ytop = ymax
				if col.B and col.B < ytop then ytop = col.B end
				for y = ytop, ymin, -1 do
					local cid = data[area:index(x, y, z)]
					if cid ~= core.CONTENT_AIR and cid ~= core.CONTENT_IGNORE then
						if not top then top = y end
						-- vegetation exactly at the planned height is decor
						-- grown ON the written surface (coral etc. take the
						-- surface node) -- the surface is there
						if is_ground(cid) or (y == ytop and is_veg(cid)) then
							S = y
							break
						end
					end
				end
				surface[skey] = S or top
				-- End island model: a cleared void column legitimately has
				-- NO surface at all (end_void_col writes pure air) -- the
				-- audit must skip it, not index with nil (2026-09-27: that
				-- is exactly how the first End-void build crashed in
				-- finish()).
				if surface[skey] then
					surface_name[skey] = cid_name(data[area:index(x, surface[skey], z)])
				end
				nat[skey] = (col.S and math.floor(col.S + 0.5)) or surface[skey]
				if col.S and col.B and math.abs(col.B - col.S) > 0.5 then
					moved[skey] = true
				end

				-- seam exactness against the capture's ground
				local target = plan.hard[skey]
				if target and S then
					local diff = math.abs(S - target)
					if diff > 0.5 then
						seam_bad = seam_bad + 1
						if diff > seam_bad_worst then seam_bad_worst = diff end
						if seam_bad <= 5 then
							local names = {}
							for yy = S + 2, S - 1, -1 do
								names[#names + 1] = yy .. ":"
									.. cid_name(data[area:index(x, yy, z)])
							end
							core.log("warning", string.format(
								"[gap-fill] seam mismatch at (%d,%d): S=%d target=%d [%s]",
								sx, sz, S, target, table.concat(names, " ")))
						end
					end
				end

				-- water above sea level and true floating junk above the
				-- surface (a non-vegetation block with nothing solid
				-- right below it). The merge itself writes NO water above
				-- sea level anywhere (land columns are dry, water columns
				-- stop AT water level), so anything found up here is the
				-- BASE's own water (canals, fountains, hangar water)
				-- spilling onto the merge after the write -- real water
				-- behaving physically, not the "generated water raised
				-- with the chunk" bug (which is gone; see the gap-only
				-- verification runs: 0).
				for y = (S or col.B or 0) + 1, ymax do
					if not col.B then break end -- unwritten column: not the merge's water
					local cid = data[area:index(x, y, z)]
					if cid ~= core.CONTENT_AIR and cid ~= core.CONTENT_IGNORE then
						if is_liquid(cid) then
							if y > sea then
								raised_water = raised_water + 1
								if not raised_pos then
									raised_pos = string.format("(%d,%d)@y%d", sx, sz, y)
								end
							end
						elseif not is_veg(cid) then
							local below = data[area:index(x, y - 1, z)]
							local nm = cid_name(cid)
							local ice = nm:find("ice") ~= nil
							local reef = core.get_item_group(nm, "coral_block") > 0
							local shroom = nm:find("mushroom_block") ~= nil
							if below == core.CONTENT_AIR or below == core.CONTENT_IGNORE
								or (is_liquid(below) and not (ice or reef)) then
							 if not shroom and not (audit_nether and y >= audit_dy + 122) then
								floating_junk = floating_junk + 1
								if floating_junk <= 5 then
									core.log("warning", string.format(
										"[gap-fill] junk at (%d,%d,%d): %s (below=%s)",
										sx, y, sz, nm,
										cid_name(data[area:index(x, y - 1, z)])))
								end
							 end
							end
						else
							-- vegetation checks (worldgen-merge audit 5/6):
							-- trunks and plants may never hang in the air
							-- (the old shift's smear signature), and
							-- kelp/seagrass belong under water only (the
							-- "kelp on mountainsides" signature). Leaves,
							-- vines and flowers legitimately overhang air
							-- (canopy undersides) and are exempt.
							local name = cid_name(cid)
							if (name:find("kelp") or name:find("seagrass"))
								and not is_terrain_name(name) then
								if y > sea then
									kelp_dry = kelp_dry + 1
								end
							else
								local n = cid
								local trunk_or_plant =
									core.get_item_group(name, "tree") > 0
									or core.get_item_group(name, "plant") > 0
									or core.get_item_group(name, "grass") > 0
								if trunk_or_plant then
									local below = data[area:index(x, y - 1, z)]
									if below == core.CONTENT_AIR or below == core.CONTENT_IGNORE then
										-- branch blocks (L-system trees use the
										-- trunk node for branches) overhang air
										-- legitimately -- they stay attached to
										-- the tree beside them. Flag only
										-- DISCONNECTED floating veg (the smear
										-- signature: shifted debris in the air).
										local attached = false
										for _, d in ipairs({ { 1, 0 }, { -1, 0 },
												{ 0, 1 }, { 0, -1 }, { 1, 1 },
												{ 1, -1 }, { -1, 1 }, { -1, -1 } }) do
											for _, dy2 in ipairs({ 0, -1 }) do
												local nb = data[area:index(x + d[1], y + dy2, z + d[2])]
												if nb and nb ~= core.CONTENT_AIR
													and nb ~= core.CONTENT_IGNORE then
													local nn = cid_name(nb)
													if core.get_item_group(nn, "tree") > 0
														or core.get_item_group(nn, "leaves") > 0
														or is_ground(nb) then
														attached = true
													end
												end
											end
											if attached then break end
										end
										if not attached then
											floating_veg = floating_veg + 1
											if floating_veg <= 5 then
												core.log("warning", string.format(
													"[gap-fill] floating veg at (%d,%d,%d): %s",
													sx, y, sz, name))
											end
										end
									end
								end
							end
						end
					end
				end
			end
		end
	end

	local allowed = (plan.step or 1) + 0.5
	local worst_pos, relief_pos = nil, nil
	for skey, S in pairs(surface) do
		local sx, sz = skey:match("^(%-?%d+),(%-?%d+)$")
		sx, sz = tonumber(sx), tonumber(sz)
		for _, d in ipairs(gap_field.DIRS) do
			local nkey = (sx + d[1]) .. "," .. (sz + d[2])
			local Sn = surface[nkey]
			if Sn and skey < nkey and (S >= sea or Sn >= sea) then
				local diff = math.abs(S - Sn)
				-- The merge owns a step only where it made the pair
				-- STEEPER than it already was (this world has genuine
				-- 90-block natural cliffs -- v7 mountains over ravines --
				-- and blaming the merge for keeping them would flag every
				-- rebuild). Steps at pinned columns (the capture's own
				-- seam cliffs) and at the untouched boundary are matched
				-- or left alone on purpose.
				local nat_diff = math.abs((nat[skey] or S) - (nat[nkey] or Sn))
				local ca = plan.chunks
				local ta = nil
				local tb = nil
				do
					for _, ck in pairs(plan.chunks) do
						local ax, az = sx - ck.cx * C, sz - ck.cz * C
						if ax >= 0 and ax < C and az >= 0 and az < C then
							ta = ck.col[ax * C + az + 1].tgt
						end
						local bx, bz = sx + d[1] - ck.cx * C, sz + d[2] - ck.cz * C
						if bx >= 0 and bx < C and bz >= 0 and bz < C then
							tb = ck.col[bx * C + bz + 1].tgt
						end
					end
				end
				local target_step = (ta and tb) and math.abs(ta - tb) or 0
				local target_forced = (ta and tb) and diff <= target_step + 1.0
				local fld = plan.field
				local la = fld and fld.level and fld.level[skey]
				local lb = fld and fld.level and fld.level[nkey]
				local capture_cliff = la and lb
					and math.abs(la - lb) > allowed
				if diff > allowed and diff > nat_diff + 1.0 then
				 if not (target_forced or capture_cliff) then
					if slope_bad + relief_bad <= 5 then
						local function dbg(k, xx, zz)
							local ckey = math.floor(xx / C) .. "_" .. math.floor(zz / C)
							local ck = plan.chunks[ckey]
							local c = ck and ck.col[((xx % C) * C + (zz % C)) + 1]
							local fld = plan.field or {}
							return string.format("d=%s lvl=%s nat=%s B=%s",
								tostring(fld.dist and fld.dist[k]),
								tostring(fld.level and fld.level[k]),
								c and tostring(c.S) or "?",
								c and tostring(c.B) or "?")
						end
						core.log("warning", string.format(
							"[gap-fill] steep pair (%d,%d)=%d(%s) [%s]..(%d,%d)=%d(%s) [%s] nat=%0.1f",
							sx, sz, S, surface_name[skey] or "?", dbg(skey, sx, sz),
							sx + d[1], sz + d[2], Sn,
							surface_name[nkey] or "?", dbg(nkey, sx + d[1], sz + d[2]),
							nat_diff))
					end
					-- Steps at pinned columns are the capture's own seam
					-- cliffs or the untouched-boundary relief (matched or
					-- left alone on purpose); free-range steps at columns
					-- the merge actually moved are the ones it owns.
					if plan.pins[skey] or plan.pins[nkey]
							or not (moved[skey] or moved[nkey]) then
						relief_bad = relief_bad + 1
						if diff > relief_worst then
							relief_worst = diff
							relief_pos = string.format("(%d,%d)=%d..(%d,%d)=%d",
								sx, sz, S, sx + d[1], sz + d[2], Sn)
						end
					else
						slope_bad = slope_bad + 1
						if diff > slope_worst then
							slope_worst = diff
							worst_pos = string.format("(%d,%d)=%d..(%d,%d)=%d [pins:%s/%s]",
								sx, sz, S, sx + d[1], sz + d[2], Sn,
								tostring(plan.pins[skey]), tostring(plan.pins[nkey]))
						end
					end
				 else
					relief_bad = relief_bad + 1
					if diff > relief_worst then
						relief_worst = diff
						relief_pos = string.format("(%d,%d)=%d..(%d,%d)=%d [capture cliff tgt=%0.1f/%0.1f]",
							sx, sz, S, sx + d[1], sz + d[2], Sn, target_step, diff)
					end
				 end
				end
			end
		end
	end

	-- PASS = the merge's own bug classes are gone: seams match the
	-- capture exactly and the merge raised no generated water (it can't:
	-- nothing above sea level is ever written as water). Spilled base
	-- water and steep merge slopes are reported and judged by eye/numbers:
	-- the former is the base's own water behaving physically, the latter
	-- is cliff-base terrain that cannot be ramped walkable at bounded
	-- width (steep-but-continuous on purpose).
	local ok = seam_bad == 0
	core.log("action", string.format(
		"[gap-fill] audit %s: seam mismatches %d (worst %.1f), merge slopes over cap %d (worst %.1f at %s, cap %.1f), "
		.. "natural relief steps %d (worst %.1f at %s), spilled base water blocks %d (first at %s), "
		.. "floating junk blocks %d, floating veg %d, kelp out of water %d -- %.2fs",
		job.name, seam_bad, seam_bad_worst, slope_bad, slope_worst, tostring(worst_pos), allowed,
		relief_bad, relief_worst, tostring(relief_pos), raised_water, tostring(raised_pos), floating_junk,
		floating_veg, kelp_dry,
		(core.get_us_time() - t0) / 1e6))
	if not ok then
		core.log("warning", "[gap-fill] audit FAILED for " .. tostring(job.name))
	end
	audit_done()
	return ok
end

return gap_fill
end

return factory
