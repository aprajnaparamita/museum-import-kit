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

-- Dimension-aware fallback materials (2026-09-26 audit): the old default
-- was overworld dirt_with_grass/dirt (sand under water) for every band --
-- grass skins over the nether lava sea, grass/stone columns into the End
-- void (AUDIT-2026-09-26.md #3/#4). job.dimension_type is authoritative;
-- the dest_y_offset fallback keeps synthetic test jobs working.
local function band(job)
	local b = job.dimension_type
	if b == "nether" or b == "end" or b == "overworld" then return b end
	local dy = job.dest_y_offset or 0
	if dy <= -28000 then return "nether" end
	if dy <= -20000 then return "end" end
	return "overworld"
end

local function default_top(job, is_water)
	local b = band(job)
	if b == "nether" then return "mcl_nether:netherrack" end
	if b == "end" then return "mcl_end:end_stone" end
	return is_water and "mcl_core:sand" or "mcl_core:dirt_with_grass"
end

local function default_filler(job, is_water)
	local b = band(job)
	if b == "nether" then return "mcl_nether:netherrack" end
	if b == "end" then return "mcl_end:end_stone" end
	return is_water and "mcl_core:sand" or "mcl_core:dirt"
end

-- underground "raise fill" material (under the soil skin, down to the old
-- ground): stone overworld, end_stone in the End (the P5 "253-block stone
-- column descending into the void" was this falling back to
-- mcl_core:stone at the End band), netherrack in the Nether.
local function default_stone(job)
	local b = band(job)
	if b == "nether" then return "mcl_nether:netherrack" end
	if b == "end" then return "mcl_end:end_stone" end
	return "mcl_core:stone"
end

-- the column liquid: water overworld, lava in the Nether (matches the
-- mapgen's own nether lava, mcl_nether:nether_lava_source -- see
-- AUDIT-2026-09-26 #2)
local function default_liquid(job)
	if band(job) == "nether" then return "mcl_nether:nether_lava_source" end
	return "mcl_core:water_source"
end

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
	local c_liquid = cid(default_liquid(job))
	local c_snow = cid("mcl_core:snow")
	local c_stone = cid(default_stone(job))
	local c_bedrock = cid("mcl_core:bedrock")
	local c_netherrack = cid("mcl_nether:netherrack")

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
				top = top or cid(surf.node_top or default_top(job, is_water))
				filler = filler or cid(surf.node_filler or default_filler(job, is_water))
				depth_top = surf.depth_top or 1
				depth_filler = surf.depth_filler or 3

				local skin_lo = B - depth_top - depth_filler + 1
				-- rewrite zone: down to the lower of the skin and the OLD
				-- ground (raise fill); below that natural underground is
				-- untouched (caves/ores preserved).
				local rewrite_lo = math.min(skin_lo, (col.S or B)) - 1

				-- End island model (2026-09-26 owner findings): a raised
				-- merge column continues the ISLAND -- a slab at the
				-- merged level, at most ISLAND_SLAB deep -- instead of
				-- pouring a pillar down to Mineclonia's own island layer
				-- ~175 blocks below (the capture sits at y -26825, the
				-- mapgen's islands at -27000; the pillars + the air gap
				-- between layers were the "large gap"). When the slab
				-- floats clear of the natural island, everything below it
				-- is cleared to void too -- no second island layer under
				-- the base. Columns merged at their natural level (no
				-- raise) keep the natural island as their ground.
				local ISLAND_SLAB = 52 -- ~= the captured island's thickness at Endhaven
				local island_slab_lo = nil
				local end_void_col = false
				if band(job) == "end" then
					-- End island model: INSIDE the capture's footprint the
					-- island continues at one level (slab at the merged
					-- level, void below -- never join Mineclonia's own
					-- islands 124 blocks down, owner 2026-09-27); OUTSIDE
					-- it the museum's End is clean void (generated islands
					-- and their structures are cleared entirely).
					local bx = job.chunk_bounds
					local inside = bx and chunk.cx >= bx.x_min and chunk.cx <= bx.x_max
						and chunk.cz >= bx.z_min and chunk.cz <= bx.z_max
					if inside then
						island_slab_lo = B - ISLAND_SLAB
					else
						end_void_col = true
					end
					rewrite_lo = GAP_Y_MIN + dy
				end

				-- Nether ceiling band (2026-09-26, owner: "do the fill and
				-- then re-generate the nether roof"): the capture's roof
				-- profile is bedrock at dy+127/126 over netherrack (source
				-- columns verified, AUDIT-2026-09-26 #1). The merge only
				-- rewrites BELOW the band and then regenerates the roof
				-- over this fill chunk, so captured and merged chunks share
				-- one continuous ceiling at the seam.
				local roof_lo, roof_hi = dy + 122, dy + 127
				-- ALWAYS seal the ceiling at the nether band, and clear the
				-- mapgen's own ceiling remnants ABOVE it (owner 2026-09-27:
				-- "portions of the bedrock not closing the gap" -- columns
				-- with a high merged surface skipped the regen and left the
				-- mapgen ceiling at a different level; "we want this to
				-- match and be seamless"). One roof at the capture's
				-- profile, matching the captured chunks' columns exactly.
				local do_roof = band(job) == "nether"
				-- the zone just above the band is cleared too (the mapgen's
				-- own ceiling at dy+132/133), so the regen band is the ONLY
				-- roof, at one level everywhere. Bounded at roof_hi+8: the
				-- mapgen ceiling never sits higher than that, and scanning
				-- the full y-range per column cost 25x (2026-09-27 harness
				-- timeout).
				local rewrite_hi = ymax
				if do_roof then rewrite_hi = roof_hi + 8 end

				-- clear/rebuild the rewritten zone
				for y = rewrite_hi, rewrite_lo + 1, -1 do
					local idx = area:index(x, y, z)
					local c
					if end_void_col then
						c = c_air
					elseif y > B then
						if is_water and y <= sea then
							-- liquid column: fill to the sea/lava surface.
							-- The sand-top rule is overworld water only --
							-- nether lava beds keep the fill material (seam
							-- copy matches real lake beds at the edges).
							c = c_liquid
							if y == sea and band(job) ~= "nether" and surf.node_water_top then
								c = cid(surf.node_water_top)
							end
						else
							c = c_air
						end
					elseif y > B - depth_top then
						c = top
					elseif y > B - depth_top - depth_filler then
						c = filler
					else
						-- raise-fill gap: stone under the soil skin (End
						-- island model caps it at island_slab_lo -- air
						-- below, so the island floats over void instead of
						-- pouring down to the mapgen's island layer)
						if island_slab_lo and y <= island_slab_lo then
							c = c_air
						else
							c = c_stone
						end
					end
					data[idx] = c
					p2data[idx] = 0
				end

				if do_roof then
					for y = roof_lo, roof_hi do
						local idx = area:index(x, y, z)
						-- solid bedrock plate on top, bedrock/netherrack
						-- mix below it (vanilla-shaped roof)
						local c
						if y >= roof_hi - 1 or wdl.noise2(x + y * 3, z, 7) < 0.35 then
							c = c_bedrock
						else
							c = c_netherrack
						end
						data[idx] = c
						p2data[idx] = 0
					end
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
