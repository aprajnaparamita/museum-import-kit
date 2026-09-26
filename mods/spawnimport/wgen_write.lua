-- wgen_write.lua -- worldgen-merge WRITE phase (PLAN-worldgen-merge.md
-- §3.3) and GROW phase (§3.4). Loaded as a factory:
--     local wgen_write = dofile(modpath .. "/wgen_write.lua")(wdl_climate)
--
-- WRITE (write.place_chunk) -- one gap chunk, column REBUILD:
--   * everything above the merged surface becomes AIR -- no vegetation is
--     ever carried along (this is what killed "smeared trees" and "kelp
--     on mountainsides": the old shift moved sea-floor plants up with the
--     column). Structures intersecting merged columns are cleared with
--     the same rule (owner decision: clear).
--   * the surface skin is REBUILT from the target biome's rules (top +
--     filler depths) -- seam columns prefer the neighbouring CAPTURED
--     column's own top/filler materials so exposed seam faces continue
--     the capture's geology.
--   * the shift gap (raised columns) fills with stone -- cliffs read as
--     stone under a soil skin, like natural terrain.
--   * water columns: floor at the merged height, water up to water_level
--     (frozen biomes put their ice node on top), air above.
--   * snow layer on land where the temperature map says snow.
--   * below the rebuilt zone the natural underground (caves, ores) is
--     left byte-for-byte untouched.
--
-- GROW (write.grow_chunk) -- one gap chunk, AFTER every write is done:
--   engine-native decoration placement on the finished surface via
--   core.generate_decorations_with_inputs (the shim built into this rig's
--   Luanti), fed the merged heights + target biome ids per column --
--   Mineclonia's own trees/plants/kelp land naturally at the right
--   heights for the right biomes. Columns outside the merge domain that
--   fall inside the working area are restored afterwards, so nothing is
--   ever written to captured chunks or untouched terrain (canopies may
--   overhang between merge columns only).

local function factory(wdl)
local write = {}

local C = 16
local GAP_Y_MIN = -130
local GAP_Y_MAX = 319

-- Supersentinel: placeDeco skips heightmap decorations whose y falls
-- outside y_min..y_max / nmin..nmax -- 32767 always does.
local SKIP_Y = 32767

local ids = {}
local function cid(name)
	local v = ids[name]
	if v == nil then
		local ok, id = pcall(core.get_content_id, name)
		v = ok and id or core.CONTENT_AIR
		ids[name] = v
	end
	return v
end

local names = {}
local function cname(c)
	local n = names[c]
	if n == nil then
		n = core.get_name_from_content_id(c) or ""
		names[c] = n
	end
	return n
end

local function is_liquid(c)
	return core.get_item_group(cname(c), "liquid") > 0
end

-- A captured neighbour's surface material pair (top, filler) for seam
-- face continuity: read the captured column at its ground height (the
-- seam target) and one block below, accepting anything solid-looking
-- (non-air, non-liquid); fall back to nils and let the caller use the
-- biome's own materials.
local function seam_materials(data, area, x, y, z, ymin, ymax)
	local function is_veg(c)
		local name = cname(c)
		-- floor-with-plant ocean nodes are ground, not vegetation
		if name:find("^mcl_ocean:kelp_") or name:find("^mcl_ocean:seagrass_") then
			return false
		end
		for _, g in ipairs({ "leaves", "tree", "attached_node", "plant",
				"snow", "grass", "flora", "flower",
				"coral_plant", "coral_fan", "deco_block" }) do
			if core.get_item_group(name, g) > 0 then return true end
		end
		return false
	end
	local function solid_at(yy)
		if yy < ymin or yy > ymax then return nil end
		local c = data[area:index(x, yy, z)]
		if c == core.CONTENT_AIR or c == core.CONTENT_IGNORE or is_liquid(c)
			or is_veg(c) then
			return nil
		end
		local def = core.registered_nodes[cname(c)]
		if def and def.walkable == false then
			return nil -- decor (coral plants, fans): not ground
		end
		return c
	end
	local top = solid_at(y) or solid_at(y + 1) or solid_at(y - 1) or solid_at(y + 2)
	local filler = top and (solid_at(y - 1) or solid_at(y - 2))
	return top, filler
end

-- Materials the outward geology fade may scatter from the seam: natural
-- ground only -- never build blocks (stone bricks next to a castle would
-- read as debris) and never floor-with-plant nodes (seagrass on land).
-- Cached per name.
local ground_cache = {}
local function is_natural_ground(name)
	local v = ground_cache[name]
	if v == nil then
		if name:find("seagrass") or name:find("kelp") or name:find("coral")
			or name:find("brick") or name:find("plank") or name:find("wool")
			or name:find("glass") or name:find("quartz") or name:find("concrete")
			or name:find("terracotta") or name:find("mushroom")
			or name:find("leaves") or name:find("tree") then
			v = false
		else
			v = (name:find("stone") or name:find("cobble") or name:find("gravel")
				or name:find("sand") or name:find("dirt") or name:find("snow")
				or name:find("ice") or name:find("clay") or name:find("andesite")
				or name:find("diorite") or name:find("granite") or name:find("calcite")
				or name:find("tuff") or name:find("deepslate") or name:find("basalt")
				or name:find("moss") or name:find("mycelium") or name:find("podzol"))
				and true or false
		end
		ground_cache[name] = v
	end
	return v
end

-- Geology fade width (columns) from the seam: the exact seam row copies
-- the captured neighbour's own materials (below); the next few columns
-- keep a NOISY fraction of the seam source's ground material, so rock /
-- sand geology dies out in ragged scree instead of ending in a straight
-- line against the biome's own soil (owner: "square snow area connecting
-- to rock ... should be more natural looking", 2026-09-25).
local SCREE_FADE = 7

-- ---------------------------------------------------------------------
-- WRITE: rebuild one merge chunk
-- ---------------------------------------------------------------------
function write.place_chunk(job, plan, entry, _content_id_for)
	local chunk = plan.chunks[entry.cx .. "_" .. entry.cz]
	if not chunk then return end
	local base_x, base_z = chunk.base_x, chunk.base_z
	local sea = plan.sea
	local dy = job.dest_y_offset or 0

	local ymin, ymax = GAP_Y_MIN + dy, GAP_Y_MAX + dy
	-- one-column border so seam columns can read the captured neighbour
	local xmin, xmax = base_x - 1, base_x + C
	local zmin, zmax = base_z - 1, base_z + C

	local c_air = core.CONTENT_AIR
	local c_ignore = core.CONTENT_IGNORE
	local c_water = cid("mcl_core:water_source")
	local c_snow = cid("mcl_core:snow")
	local c_stone = cid("mcl_core:stone")

	local vm = core.get_voxel_manip()
	local emin, emax = vm:read_from_map({ x = xmin, y = ymin, z = zmin },
		{ x = xmax, y = ymax, z = zmax })
	local area = VoxelArea:new({ MinEdge = emin, MaxEdge = emax })
	local data = vm:get_data()
	local p2data = vm:get_param2_data()

	for lz = 0, C - 1 do
		local z = base_z + lz
		for lx = 0, C - 1 do
			local x = base_x + lx
			local col = chunk.col[lx * C + lz + 1]
			local B = col.B
			if B then
				local is_water = B < sea

				-- materials: seam columns continue the captured column's
				-- own top/filler where readable, else the target biome's.
				local top, filler, depth_top, depth_filler
				local def = col.tdef
				local surf = def or {}
				if col.seam and job.gap_real then
					-- find the actual captured neighbour column and read
					-- its surface materials at the seam target height
					local sx, sz = chunk.cx * C + lx, chunk.cz * C + lz
					for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
						local nx, nz = sx + d[1], sz + d[2]
						local nkey = math.floor(nx / C) .. "_" .. math.floor(nz / C)
						if job.gap_real[nkey] and not plan.chunks[nkey] then
							local t, f = seam_materials(data, area,
								job.anchor_x + (nx - job.origin_x),
								plan.hard[sx .. "," .. sz] or B,
								job.anchor_z + (nz - job.origin_z),
								ymin, ymax)
							top = t
							filler = f or t
							if top then break end
						end
					end
				end
				-- water columns INCLUDED (2026-09-25 owner report: "the
				-- ocean floor has a hard transition between minecraft
				-- ocean floor and mineclonia gravel" -- the floor geology
				-- must continue outward like the land's does)
				if not top and col.smat and col.sdist
					and col.sdist > 1 and col.sdist <= SCREE_FADE
					and is_natural_ground(cname(col.smat)) then
					local p = 1 - (col.sdist - 1) / SCREE_FADE
					if wdl.noise2(x, z, 6) < p * 0.9 then
						top = col.smat
						filler = col.smat
					end
				end
				top = top or cid(surf.node_top
					or (is_water and "mcl_core:sand" or "mcl_core:dirt_with_grass"))
				filler = filler or cid(surf.node_filler
					or (is_water and "mcl_core:sand" or "mcl_core:dirt"))
				depth_top = surf.depth_top or 1
				depth_filler = surf.depth_filler or 3

				local skin_lo = B - depth_top - depth_filler + 1
				-- rewrite zone: down to the lower of the skin and the OLD
				-- ground (raise fill); below that natural underground is
				-- untouched (caves/ores preserved).
				local rewrite_lo = math.min(skin_lo, (col.S or B)) - 1

				-- clear/rebuild the rewritten zone
				for y = ymax, rewrite_lo + 1, -1 do
					local idx = area:index(x, y, z)
					local c
					if y > B then
						if is_water and y <= sea then
							c = (y == sea and surf.node_water_top)
								and cid(surf.node_water_top) or c_water
						else
							c = c_air
						end
					elseif y > B - depth_top then
						c = top
					elseif y > B - depth_top - depth_filler then
						c = filler
					else
						-- raise-fill gap: stone under the soil skin
						c = c_stone
					end
					data[idx] = c
					p2data[idx] = 0
				end

				-- snow layer from the temperature map (land only)
				if col.tsnow and not is_water and B + 1 <= ymax then
					local idx = area:index(x, B + 1, z)
					data[idx] = c_snow
					p2data[idx] = 0
				end

				-- grass tint on the surface
				if col.tint then
					local name = cname(top)
					if core.get_item_group(name, "biomecolor") > 0 then
						p2data[area:index(x, B, z)] = col.tint
					end
				end
			end
		end
	end

	vm:set_data(data)
	vm:set_param2_data(p2data)
	vm:write_to_map(true)
	vm:close()
end

-- ---------------------------------------------------------------------
-- GROW: engine-native vegetation pass on one finished merge chunk
-- ---------------------------------------------------------------------
function write.grow_chunk(job, plan, entry)
	local chunk = plan.chunks[entry.cx .. "_" .. entry.cz]
	if not chunk then return end
	local base_x, base_z = chunk.base_x, chunk.base_z
	local dy = job.dest_y_offset or 0

	-- surface band only -- trees are <= ~30 tall; no need for the whole
	-- column stack in the working area.
	local ymin_col, ymax_col = GAP_Y_MIN + dy, GAP_Y_MAX + dy
	local bmin, bmax = nil, nil
	for i = 1, C * C do
		local b = chunk.col[i].B
		if b then
			if not bmin or b < bmin then bmin = b end
			if not bmax or b > bmax then bmax = b end
		end
	end
	local ymin, ymax = ymin_col, ymax_col
	if bmin then ymin = math.max(ymin_col, bmin - 6) end
	if bmax then ymax = math.min(ymax_col, bmax + 34) end

	local MARGIN = 8 -- canopy room around the anchor square
	local xmin, xmax = base_x - MARGIN, base_x + C - 1 + MARGIN
	local zmin, zmax = base_z - MARGIN, base_z + C - 1 + MARGIN

	local vm = core.get_voxel_manip()
	local emin, emax = vm:read_from_map({ x = xmin, y = ymin, z = zmin },
		{ x = xmax, y = ymax, z = zmax })
	local area = VoxelArea:new({ MinEdge = emin, MaxEdge = emax })
	local snapshot = vm:get_data()

	-- per-column inputs for the engine decoration pass (anchor square =
	-- this chunk's 16x16; mapindex order matches the engine's
	-- carea_size * dz + dx).
	local H, Bm = {}, {}
	for lz = 0, C - 1 do
		for lx = 0, C - 1 do
			local col = chunk.col[lx * C + lz + 1]
			local i = C * lz + lx + 1
			local b = col.B
			if b and b >= ymin and b <= ymax then
				H[i] = b
			else
				H[i] = SKIP_Y
			end
			Bm[i] = col.tid or 0
		end
	end

	local p1 = { x = base_x, y = ymin, z = base_z }
	local p2 = { x = base_x + C - 1, y = ymax, z = base_z + C - 1 }

	if core.generate_decorations_with_inputs then
		core.generate_decorations_with_inputs(vm, p1, p2, H, Bm)
	elseif core.generate_decorations then
		-- backend C (stock engine): fresh heights via vm scan, no biome
		-- filter -- degraded species mix but structurally correct.
		core.generate_decorations(vm, p1, p2, false)
	end

	-- Restore every column that is NOT part of the merge domain: captured
	-- chunks and untouched terrain must never change (canopies overhang
	-- between merge columns only).
	local data = vm:get_data()
	for z = emin.z, emax.z do
		for x = emin.x, emax.x do
			local sx = x - job.anchor_x + job.origin_x
			local sz = z - job.anchor_z + job.origin_z
			if not plan.by_key[sx .. "," .. sz] then
				for y = emin.y, emax.y do
					local idx = area:index(x, y, z)
					if data[idx] ~= snapshot[idx] then
						data[idx] = snapshot[idx]
					end
				end
			end
		end
	end
	vm:set_data(data)
	vm:write_to_map(true)
	vm:close()
end

return write
end

return factory
