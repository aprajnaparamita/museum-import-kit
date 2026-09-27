-- wgen_blend3d.lua -- the merge for the NETHER and END bands: a 3-D
-- blend between the world download and Mineclonia's own terrain.
-- Loaded as a factory:
--     local blend3d = dofile(modpath .. "/wgen_blend3d.lua")(wdl_climate, gap_fill.is_terrain_name)
--
-- Why not the overworld merge (gap_fill + wgen_write): that model is a
-- height field -- ONE surface per column, fill below, air above. The
-- nether has a floor, shelves and a roof in every column and the End is
-- floating island blobs; every attempt to force them into one surface
-- per column produced roofs at two levels, floors with holes, floating
-- slabs and islands joined by pillars (owner walks 2026-09-26/27: "we
-- need to always match the chunk edges on all sides now, since nether is
-- 3d and doesn't have a natural sky or ocean height ... End islands are
-- contiguous blobs and should seem to merge into one another").
--
-- Precondition: the capture sits in Mineclonia's OWN band (dest_y_offset
-- = mcl_vars.mg_nether_min / mg_end_min, v7: -29067 / -27073). Then the
-- capture's bedrock floor, lava sea (y 31) and roof coincide with the
-- generated nether's. End captures are then lifted 14 more (new_job,
-- spawnimport_end_island_lift) so vanilla island tops (~58) meet
-- Mineclonia's (~72); job.dest_y_offset is the lifted value.
--
-- The blend, per merge column q (in the RING around captured chunks):
--   * two vertical profiles over the band:
--       C -- the capture's terrain, sampled at q MIRRORED across the
--            seam into the nearest captured chunk (mirroring continues
--            the capture's shapes instead of stretching the seam column
--            into long streaks). Terrain blocks only -- builds are never
--            extrapolated.
--       N -- Mineclonia's generated terrain at q itself.
--   * each profile becomes a 1-D signed distance along y (negative
--     inside solid), and the two are mixed with a weight w that is 1 at
--     the seam and 0 at the ring's outer edge (smoothstep, value-noise
--     jitter mid-ring only). Solid where the mix is < 0.
--   * so: the seam column IS the capture's column and the outer edge IS
--     untouched Mineclonia terrain (exact on every side, no step
--     anywhere); in between, surfaces move smoothly from one level to
--     the other, shelves thin out and pinch off, caverns continue and
--     two islands at similar heights fuse into one blob.
--   * End: the capture's islands erode from the bottom faster than from
--     the top (flat tops, tapering undersides -- how End islands look).
--   * materials come from whichever side dominates at that voxel (ores,
--     soul sand, glowstone survive); the nether's lava sea fills carved
--     space below y 31; the bedrock floor/roof rows are never written.
--   * natural decoration (fungi, roots, chorus...) survives wherever the
--     geometry around it did not change.

local function factory(wdl, is_terrain_name)
local blend3d = {}

local C = 16
blend3d.RING = 2
-- weight reaches 0 at column distance D: a column next to a chunk
-- outside the ring is >= RING*16+1 columns from any captured column
local D = blend3d.RING * C + 1

-- Per band (source-space rows): the written range, the rows read around
-- it for the distance fields, the air-side distance cap and the End's
-- top-erosion factor.
local BANDS = {
	nether = {
		-- bedrock floor src 0..4 and Mineclonia's roof src 124..128 are
		-- identical on both sides and never written; 123 is the capture's
		-- lowest roof row
		lo = 5, hi = 123, margin = 16,
		cap_solid = 16, cap_air = 16, alpha_top = 1,
		lava_y = 31,
		default = "mcl_nether:netherrack",
		lava = "mcl_nether:nether_lava_source",
	},
	["end"] = {
		lo = 0, hi = 255, margin = 8,
		-- small air cap: void is "far" from everything; a thick island
		-- carries further into the ring than a thin one
		cap_solid = 16, cap_air = 8, alpha_top = 2,
		default = "mcl_end:end_stone",
	},
}

-- Natural nether/End terrain beyond gap_fill's whitelist (names checked
-- against Mineclonia's register_node calls, 2026-09-27).
local EXTRA_TERRAIN = {
	["mcl_nether:glowstone"] = true, ["mcl_nether:quartz_ore"] = true,
	["mcl_nether:ancient_debris"] = true, ["mcl_nether:magma"] = true,
	["mcl_blackstone:nether_gold"] = true,
	["mcl_crimson:warped_wart_block"] = true,
	["mcl_nether:nether_wart_block"] = true,
}

function blend3d.band(job)
	local b = job.dimension_type
	if b == "nether" or b == "end" then return b end
	if b == "overworld" then return nil end
	local dy = job.dest_y_offset or 0
	if dy <= -28000 then return "nether" end
	if dy <= -20000 then return "end" end
	return nil
end

-- content-id classification caches
local cache_name, cache_cterrain, cache_nsolid, cache_liquid = {}, {}, {}, {}
local function cname(c)
	local n = cache_name[c]
	if n == nil then
		n = core.get_name_from_content_id(c) or ""
		cache_name[c] = n
	end
	return n
end
local function is_liquid(c)
	local v = cache_liquid[c]
	if v == nil then
		local def = core.registered_nodes[cname(c)]
		v = def ~= nil and ((def.liquidtype ~= nil and def.liquidtype ~= "none")
			or (def.groups ~= nil and (def.groups.liquid or 0) > 0))
		cache_liquid[c] = v
	end
	return v
end
-- capture side: natural terrain only (a build never extrapolates)
local function capture_solid(c)
	local v = cache_cterrain[c]
	if v == nil then
		local n = cname(c)
		v = EXTRA_TERRAIN[n] == true or is_terrain_name(n)
		cache_cterrain[c] = v
	end
	return v
end
-- natural side: anything walkable (generated structures included --
-- a fortress wall is part of the terrain the merge must meet)
local function natural_solid(c)
	local v = cache_nsolid[c]
	if v == nil then
		local n = cname(c)
		if c == core.CONTENT_AIR or c == core.CONTENT_IGNORE or n == "air" then
			v = false
		else
			local def = core.registered_nodes[n]
			v = def ~= nil and def.walkable ~= false and not is_liquid(c)
		end
		cache_nsolid[c] = v
	end
	return v
end

-- 1-D signed distance of a solid/air profile (1..H): negative inside
-- solid. alpha > 1 makes depth-below-the-TOP count alpha times over, so
-- blending erodes solid runs from the bottom first.
local function signed_distance(solid, H, out, cap_solid, cap_air, alpha)
	local i = 1
	while i <= H do
		local s = solid[i]
		local j = i
		while j < H and solid[j + 1] == s do j = j + 1 end
		-- run i..j; the opposite state lies at i-1 / j+1 when inside 1..H
		for k = i, j do
			local down = (i > 1) and (k - i + 1) or 1e9
			local up = (j < H) and (j - k + 1) or 1e9
			if s then
				local depth = math.min(alpha * up, down)
				out[k] = -math.min(depth, cap_solid)
			else
				out[k] = math.min(up, down, cap_air)
			end
		end
		i = j + 1
	end
end

-- ---------------------------------------------------------------------
-- Plan: the merge domain + per-column weight and mirror source
-- ---------------------------------------------------------------------
function blend3d.build_plan(job, real, ring)
	local band = blend3d.band(job)
	local captured = {}
	for key in pairs(real or {}) do captured[key] = true end
	for key in pairs(job.gap_placed or {}) do captured[key] = true end

	local function chunk_box(cx, cz)
		local x0 = job.anchor_x + (cx * C - job.origin_x)
		local z0 = job.anchor_z + (cz * C - job.origin_z)
		return x0, x0 + C - 1, z0, z0 + C - 1
	end

	local plan = { band = band, chunks = {}, chunk_order = {}, blend3d = true }
	local R = blend3d.RING + 1
	for _, e in ipairs(ring) do
		local key = e.cx .. "_" .. e.cz
		if not captured[key] and not plan.chunks[key] then
			local bx0, _, bz0 = chunk_box(e.cx, e.cz)
			local near = {}
			for ox = -R, R do
				for oz = -R, R do
					local ncx, ncz = e.cx + ox, e.cz + oz
					if captured[ncx .. "_" .. ncz] then
						local x0, x1, z0, z1 = chunk_box(ncx, ncz)
						near[#near + 1] = { x0, x1, z0, z1 }
					end
				end
			end
			local col = {}
			local any = false
			-- read box: the chunk + every mirror source it samples
			local rx0, rx1, rz0, rz1 = bx0, bx0 + C - 1, bz0, bz0 + C - 1
			for lx = 0, C - 1 do
				for lz = 0, C - 1 do
					local x, z = bx0 + lx, bz0 + lz
					local best_d2, mx, mz = math.huge, nil, nil
					for _, b in ipairs(near) do
						local ddx = (x < b[1] and b[1] - x) or (x > b[2] and x - b[2]) or 0
						local ddz = (z < b[3] and b[3] - z) or (z > b[4] and z - b[4]) or 0
						local d2 = ddx * ddx + ddz * ddz
						if d2 < best_d2 then
							best_d2 = d2
							-- reflect across the seam PLANE (between the
							-- edge column and its neighbour): distance k
							-- outside maps to k-1 inside, so the column
							-- next to the seam samples the edge column
							-- itself; clamp into the chunk
							if x > b[2] then mx = b[2] - (x - b[2] - 1)
							elseif x < b[1] then mx = b[1] + (b[1] - x - 1)
							else mx = x end
							if z > b[4] then mz = b[4] - (z - b[4] - 1)
							elseif z < b[3] then mz = b[3] + (b[3] - z - 1)
							else mz = z end
							mx = math.max(b[1], math.min(b[2], mx))
							mz = math.max(b[3], math.min(b[4], mz))
						end
					end
					local d = math.sqrt(best_d2)
					local w = 0
					if mx and d < D then
						local t = (D - d) / (D - 1)
						if t > 1 then t = 1 end
						-- organic edge: value noise shifts the fade mid-ring
						-- only (t*(1-t) = 0 at both ends keeps them exact)
						t = t + (wdl.noise2(x, z, 13) * 2 - 1) * 0.6 * t * (1 - t)
						if t < 0 then t = 0 elseif t > 1 then t = 1 end
						w = t * t * (3 - 2 * t)
					end
					if w > 0 then
						any = true
						if mx < rx0 then rx0 = mx elseif mx > rx1 then rx1 = mx end
						if mz < rz0 then rz0 = mz elseif mz > rz1 then rz1 = mz end
					end
					col[lx * C + lz + 1] = { w = w, d = d, mx = mx, mz = mz }
				end
			end
			if any then
				plan.chunks[key] = { cx = e.cx, cz = e.cz, base_x = bx0, base_z = bz0, col = col,
					read = { rx0, rx1, rz0, rz1 } }
				plan.chunk_order[#plan.chunk_order + 1] = key
			end
		end
	end
	core.log("action", string.format(
		"[spawnimport] blend3d (%s): %d merge chunk(s) for %s",
		tostring(band), #plan.chunk_order, tostring(job.name)))
	return plan
end

-- ---------------------------------------------------------------------
-- Write: one merge chunk
-- ---------------------------------------------------------------------
local cids = {}
local function cid(name)
	local v = cids[name]
	if v == nil then
		local ok, id = pcall(core.get_content_id, name)
		v = ok and id or core.CONTENT_AIR
		cids[name] = v
	end
	return v
end

function blend3d.place_chunk(job, plan, entry)
	local key = entry.cx .. "_" .. entry.cz
	local chunk = plan.chunks[key]
	if not chunk then return end
	local B = BANDS[plan.band]
	local dy = job.dest_y_offset or 0
	local ylo, yhi = B.lo + dy, B.hi + dy
	local rlo, rhi = ylo - B.margin, yhi + B.margin
	local H = rhi - rlo + 1
	local off = ylo - rlo -- profile index of y = ylo is off + 1

	-- read-only view: the chunk plus every mirror source it samples
	local x0, z0 = chunk.base_x, chunk.base_z
	local rb = chunk.read
	local rvm = core.get_voxel_manip()
	local re1, re2 = rvm:read_from_map({ x = rb[1], y = rlo, z = rb[3] },
		{ x = rb[2], y = rhi, z = rb[4] })
	local rarea = VoxelArea:new({ MinEdge = re1, MaxEdge = re2 })
	local rdata = rvm:get_data()
	local rp2 = rvm:get_param2_data()

	local vm = core.get_voxel_manip()
	local e1, e2 = vm:read_from_map({ x = x0, y = ylo, z = z0 },
		{ x = x0 + C - 1, y = yhi, z = z0 + C - 1 })
	local area = VoxelArea:new({ MinEdge = e1, MaxEdge = e2 })
	local data = vm:get_data()
	local p2data = vm:get_param2_data()

	local c_air = core.CONTENT_AIR
	local c_default = cid(B.default)
	local c_lava = B.lava and cid(B.lava) or nil
	local lava_y = B.lava_y and (B.lava_y + dy) or nil
	local ystride = rarea.ystride

	local nS, cS, nC, cC, nP, cP = {}, {}, {}, {}, {}, {}
	local nD, cD, rS = {}, {}, {}
	local changed = 0

	for lx = 0, C - 1 do
		for lz = 0, C - 1 do
			local col = chunk.col[lx * C + lz + 1]
			local w = col.w
			if w > 0 then
				local x, z = x0 + lx, z0 + lz
				-- profiles, bottom-up
				local ni = rarea:index(x, rlo, z)
				local ci = rarea:index(col.mx, rlo, col.mz)
				for i = 1, H do
					local nc, cc = rdata[ni], rdata[ci]
					nC[i], cC[i] = nc, cc
					nP[i], cP[i] = rp2[ni], rp2[ci]
					nS[i] = natural_solid(nc)
					cS[i] = capture_solid(cc)
					ni = ni + ystride
					ci = ci + ystride
				end
				signed_distance(nS, H, nD, B.cap_solid, B.cap_air, 1)
				signed_distance(cS, H, cD, B.cap_solid, B.cap_air, B.alpha_top)
				local cap_dom = w >= 0.5
				for i = 1, H do
					if i <= off or i > off + (yhi - ylo + 1) then
						rS[i] = nS[i] -- outside the written range: unchanged
					else
						local s = w * cD[i] + (1 - w) * nD[i]
						if s < 0 then rS[i] = true
						elseif s > 0 then rS[i] = false
						else rS[i] = cap_dom and cS[i] or nS[i] end
					end
				end
				for y = ylo, yhi do
					local i = off + 1 + (y - ylo)
					local c, p2
					if rS[i] then
						if cap_dom and cS[i] then c, p2 = cC[i], cP[i]
						elseif (not cap_dom) and nS[i] then c, p2 = nC[i], nP[i]
						elseif cS[i] then c, p2 = cC[i], cP[i]
						elseif nS[i] then c, p2 = nC[i], nP[i]
						else
							-- new solid on both sides' air: the nearest solid
							-- material in the dominant column, else the other
							local S1, K1, S2, K2 = nS, nC, cS, cC
							if cap_dom then S1, K1, S2, K2 = cS, cC, nS, nC end
							for r = 1, 16 do
								if i - r >= 1 and S1[i - r] then c = K1[i - r] break end
								if i + r <= H and S1[i + r] then c = K1[i + r] break end
							end
							if not c then
								for r = 1, 16 do
									if i - r >= 1 and S2[i - r] then c = K2[i - r] break end
									if i + r <= H and S2[i + r] then c = K2[i + r] break end
								end
							end
							c = c or c_default
							p2 = 0
						end
					else
						-- open space: liquid, natural decoration or air
						local dom_c = cap_dom and cC[i] or nC[i]
						local dom_solid = cap_dom and cS[i] or nS[i]
						if lava_y and y <= lava_y and (is_liquid(dom_c) or dom_solid) then
							c, p2 = is_liquid(dom_c) and dom_c or c_lava, 0
						elseif (not cap_dom) and not nS[i] and nC[i] ~= c_air
							and not is_liquid(nC[i])
							and rS[i - 1] == nS[i - 1] and rS[i + 1] == nS[i + 1] then
							c, p2 = nC[i], nP[i] -- fungus/roots/chorus kept
						else
							c, p2 = c_air, 0
						end
					end
					local idx = area:index(x, y, z)
					if data[idx] ~= c then changed = changed + 1 end
					data[idx] = c
					p2data[idx] = p2
				end
			end
		end
	end

	vm:set_data(data)
	vm:set_param2_data(p2data)
	-- write_to_map(true) recomputes lighting (set_lighting/calc_lighting
	-- are mapgen-VoxelManip only and just warn here)
	vm:write_to_map(true)
	vm:update_liquids()
	plan.changed = (plan.changed or 0) + changed
end

-- ---------------------------------------------------------------------
-- Audit: the seam must be exact -- every merge column edge-adjacent to a
-- captured column carries the capture's own terrain solid/air pattern
-- over the whole written range.
-- ---------------------------------------------------------------------
function blend3d.audit(job, plan)
	local B = BANDS[plan.band]
	local dy = job.dest_y_offset or 0
	local ylo, yhi = B.lo + dy, B.hi + dy
	local seam_cols, seam_bad, cols = 0, 0, 0
	for _, key in ipairs(plan.chunk_order) do
		local chunk = plan.chunks[key]
		local x0, z0 = chunk.base_x, chunk.base_z
		local vm = core.get_voxel_manip()
		local e1, e2 = vm:read_from_map({ x = x0 - 1, y = ylo, z = z0 - 1 },
			{ x = x0 + C, y = yhi, z = z0 + C })
		local area = VoxelArea:new({ MinEdge = e1, MaxEdge = e2 })
		local data = vm:get_data()
		for lx = 0, C - 1 do
			for lz = 0, C - 1 do
				local col = chunk.col[lx * C + lz + 1]
				if col.w > 0 then cols = cols + 1 end
				if col.d == 1 and col.mx then
					seam_cols = seam_cols + 1
					local x, z = x0 + lx, z0 + lz
					for y = ylo, yhi do
						local a = natural_solid(data[area:index(x, y, z)])
						local b = capture_solid(data[area:index(col.mx, y, col.mz)])
						if a ~= b then seam_bad = seam_bad + 1 end
					end
				end
			end
		end
	end
	local ok = seam_bad == 0
	core.log("action", string.format(
		"[gap-fill] audit %s: 3-D blend (%s) -- %d merge chunk(s), %d blended column(s), "
		.. "%d node(s) changed; seam columns %d, seam voxel mismatches %d -- %s",
		tostring(job.name), tostring(plan.band), #plan.chunk_order, cols,
		plan.changed or 0, seam_cols, seam_bad, ok and "PASS" or "FAIL"))
	if not ok then
		core.log("warning", "[gap-fill] audit FAILED for " .. tostring(job.name))
	end
	return ok
end

return blend3d
end

return factory
