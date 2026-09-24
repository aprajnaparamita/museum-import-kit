-- wgen_inputs.lua -- per-column merge TARGETS for the worldgen-merge gap
-- fill (PLAN-worldgen-merge.md phase 1, revised after the owner's
-- 2026-09-24 in-game report).
--
-- The owner's rule, quoted: "The goal here is for the edges to always
-- match the level/characteristics of the touching world download
-- blocks" with "a natural looking shift" outward into the normally
-- generated Mineclonia chunks -- no square cliffs, no square biome
-- borders (grass-then-sand chunk squares), no bare sand without desert
-- decor. Two fields implement that, both driven by the SAME per-column
-- distance `d` to the capture (multi-source BFS from the captured
-- columns):
--
--   HEIGHT: the solver's pull target is a distance-fade blend of the
--   touching captured column's LEVEL (near the seam) and the column's
--   own natural surface (far out). Combined with the slope cap (and the
--   hard seam pins which are exact), a merged column can never sit
--   unreachable from the world download block that touches it -- the
--   "raised ocean floor" pillars are gone -- while the shift spreads
--   over the 2-chunk ring like a real coastline.
--
--   BIOME: the per-column climate (Mineclonia's own heat_point /
--   humidity_point axes) fades from the touching captured column's
--   biome climate to this position's natural climate, and the target
--   Mineclonia biome is the nearest registered biome on those axes --
--   the same picker the engine uses. That gives a per-column gradual
--   biome shift (ocean -> beach -> desert/whatever inland, with the
--   decor that biome wants: cactus included) instead of a 16x16 chunk
--   square.

local function factory(wdl)
local inputs = {}

local C = 16
-- Seam-climate dominance fades over 2 chunks + 1 column (the ring
-- width); beyond it the column is fully natural.
local FADE = 33

-- Heat-point calibration against mcl_biomes' registered set: every
-- snowy-type biome sits at heat_point <= 8 (IcePlains/ColdTaiga 8,
-- SnowySlopes 6, IcePlainsSpikes -5); taiga is 22 and everything
-- temperate is 45+. SNOW_CEIL pins a frozen seam's climate into the
-- frozen set; TEMPERATE_FLOOR lifts a seam whose real blocks are
-- unfrozen ground/sand out of it, whatever its chunk tag claims.
local SNOW_CEIL = 8
local TEMPERATE_FLOOR = 24

local DIRS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }

-- Distance -> seam weights (owner spec 2026-09-24: "the minecraft
-- generated biomes could be copied into the closer of the two chunks
-- and ... a natural looking shift between the biomes"):
--   * w_level  (heights):  linear fade across the full 2-chunk ring --
--     the merged surface reaches the touching block's LEVEL exactly at
--     the seam and glides out to natural over 32 columns;
--   * w_biome  (biomes):   1.0 across the inner chunk (<=16 columns --
--     the "closer chunk" copies the seam's biome), fading to 0 across
--     the outer chunk (the shift band), natural from 33 columns out.
local function weights(d, j)
	-- j (optional): per-column noise jitter in columns, so the fade
	-- edge is organic instead of a BFS-distance isoline (straight
	-- Voronoi edges / triangular diagonals -- the owner's "very
	-- mathematical and uniform" snow, 2026-09-25). Heights pass no
	-- jitter (the slope solver wants clean targets); biome/material
	-- fades do.
	local dd = d + (j or 0)
	if dd < 1 then dd = 1 end
	local wl = (FADE - dd) / (FADE - 1)
	if wl < 0 then wl = 0 elseif wl > 1 then wl = 1 end
	-- biome weight: smoothstep over the full span. The old shape held
	-- w=1 flat for the inner chunk ("copy the seam biome into the
	-- closer chunk") -- but that plateau is exactly what turned one
	-- wrong 16x16 chunk tag into a 16-column square snow field.
	-- Smoothstep still matches the touching blocks at the seam (w~1 at
	-- d=1) while shifting outward gradually and on noisy edges.
	local t = (dd - 1) / (FADE - 1)
	if t < 0 then t = 0 elseif t > 1 then t = 1 end
	local wb = 1 - t * t * (3 - 2 * t)
	return wl, wb
end

-- MC biome name of a captured chunk's column (lx,lz in 0..15,
-- lx*16+lz local order -- the footprint's per-column order).
local function captured_mc_biome(r, lx, lz)
	if r.biome_cols then
		local b = r.biome_cols[lx * C + lz + 1]
		if b and b ~= "" then return b end
	end
	return r.biome
end

-- Multi-source BFS from the captured columns outward over the columns
-- the merge will write. Returns three "sx,sz"-keyed maps:
--   dist[skey]  -- columns to the nearest captured column (1 = touching)
--   level[skey] -- that captured column's ground level (dest y)
--   mc[skey]    -- that captured column's Minecraft biome name
-- Columns with no entry are not adjacent to the capture through the
-- domain (callers fall back to full-natural there).
function inputs.field(job, real, domain, level_at, mat_at)
	local dy = job.dest_y_offset or 0
	local function src_level(r, cx, cz, lx, lz, sx, sz)
		if level_at then
			-- smoothed seam level (same function the hard pins use) so a
			-- single misdetected capture column cannot poison the fade
			-- target of its whole neighbourhood
			return level_at(r, cx, cz, lx, lz, sx, sz)
		end
		return (r.terrain_cols[lx * C + lz + 1] or r.height) + dy
	end
	local dist, level, mc = {}, {}, {}
	-- fam: surface family of the seam source column ("snow"/"grass"/
	-- "sand"/"water"/nil, see wdl_climate.surface_family); gmat: its
	-- ground content id (the write fades the seam geology out with it)
	local fam, gmat = {}, {}
	local queue, qhead = {}, 1
	local function key(x, z) return x .. "," .. z end
	local function parse(k)
		local x, z = k:match("^(%-?%d+),(%-?%d+)$")
		return tonumber(x), tonumber(z)
	end

	for skey in pairs(domain) do
		local sx, sz = parse(skey)
		for _, d in ipairs(DIRS) do
			local nx, nz = sx + d[1], sz + d[2]
			local cx, cz = math.floor(nx / C), math.floor(nz / C)
			local r = real[cx .. "_" .. cz]
			if r then
				local lx, lz = nx - cx * C, nz - cz * C
				dist[skey] = 1
				level[skey] = src_level(r, cx, cz, lx, lz, nx, nz)
				mc[skey] = captured_mc_biome(r, lx, lz)
				if mat_at then
					local f, g = mat_at(r, cx, cz, lx, lz, nx, nz)
					if f then fam[skey] = f end
					if g then gmat[skey] = g end
				end
				queue[#queue + 1] = skey
				break
			end
		end
	end

	while qhead <= #queue do
		local skey = queue[qhead]
		qhead = qhead + 1
		local sx, sz = parse(skey)
		for _, d in ipairs(DIRS) do
			local nkey = key(sx + d[1], sz + d[2])
			if domain[nkey] and not dist[nkey] then
				dist[nkey] = dist[skey] + 1
				level[nkey] = level[skey]
				mc[nkey] = mc[skey]
				if fam[skey] then fam[nkey] = fam[skey] end
				if gmat[skey] then gmat[nkey] = gmat[skey] end
				queue[#queue + 1] = nkey
			end
		end
	end

	return { dist = dist, level = level, mc = mc, fam = fam, gmat = gmat }
end

-- re-export for callers (gap_fill) that only receive this module
inputs.surface_family = wdl.surface_family

-- Height targets for the solver: w(d)*seam_level + (1-w(d))*natural.
-- w = 1 at the seam (match the touching block), 0 from FADE columns out
-- (match the natural Mineclonia terrain). The solver's slope cap and
-- pins remain the hard constraints -- this only shapes the ramp.
function inputs.height_targets(field, natural)
	local t = {}
	for skey, s in pairs(natural) do
		local d = field.dist[skey]
		if d then
			local w = weights(d)
			t[skey] = w * field.level[skey] + (1 - w) * s
		else
			t[skey] = s
		end
	end
	return t
end

-- Mineclonia biome name for an MC biome, validated against what the game
-- actually registered (mappings drift; an unknown name must not crash an
-- import). Falls back to Plains, then nil.
local function resolve_mcl(mc)
	local name = wdl.mcl_biome(mc)
	if name and core.registered_biomes[name] then return name end
	if core.registered_biomes["Plains"] then return "Plains" end
	return nil
end

-- Attach target fields to every plan column, per COLUMN (no chunk
-- squares): a distance-fade climate blend of the touching captured
-- column's biome and this position's natural biome, resolved to the
-- nearest registered Mineclonia biome. Fields set:
--   col.tmc    target MC biome name (the seam source; may be nil)
--   col.tmcl   target Mineclonia biome name
--   col.tid    target engine biome id (decoration biomap)
--   col.tdef   the Mineclonia biome def (registered_biomes[tmcl])
--   col.tint   grass param2 palette index (or nil)
--   col.tsnow  place a snow layer on top
--   col.tdeep  water floor rule: "ocean" (def material) / "sand"
function inputs.attach_targets(job, real, plan)
	local registered = core.registered_biomes or {}
	local sea = plan.sea or 0
	local field = plan.field or { dist = {}, level = {}, mc = {} }

	for _, chunk in pairs(plan.chunks) do
		for lx = 0, C - 1 do
			for lz = 0, C - 1 do
				local col = chunk.col[lx * C + lz + 1]
				local sx, sz = chunk.cx * C + lx, chunk.cz * C + lz
				local skey = sx .. "," .. sz
				local d = field.dist[skey]
				local mc = field.mc[skey]
				local fam = field.fam and field.fam[skey]
				local _, w = 0, 0
				if d then
					-- noisy edge: biome/material fades follow an organic
					-- seam outline, not the BFS-distance isoline
					_, w = weights(d, wdl.jitter(chunk.base_x + lx,
						chunk.base_z + lz))
				end

				local y = col.B or col.S or 0
				local wet = col.B and col.B < sea

				-- the touching captured column's climate, on Mineclonia's
				-- own (heat_point, humidity_point) axes
				local seam_name, seam_def
				if mc then
					seam_name = resolve_mcl(mc)
					seam_def = seam_name and registered[seam_name] or nil
				end

				-- this position's natural climate (the engine's own
				-- noise-driven picker: biome + heat + humidity at (x,y,z))
				local nat_name, nat_heat, nat_hum
				if core.get_biome_data then
					local okc, bd = pcall(core.get_biome_data, {
						x = chunk.base_x + lx, y = y, z = chunk.base_z + lz,
					})
					if okc and bd then
						nat_heat, nat_hum = bd.heat, bd.humidity
						local nm = core.get_biome_name and core.get_biome_name(bd.biome)
						nat_name = (nm and registered[nm]) and nm or nil
					end
				end

				-- Blend climate then pick the nearest registered biome in
				-- this column's own wet/dry set. At w=1 the climate IS the
				-- seam biome's, so the pick is the seam biome (or its
				-- same-climate wet/dry sibling -- an ocean seam next to a
				-- dry column yields that biome's LAND variant: sand with
				-- desert decor, never bare seabed sand on a hill).
				-- Ground the seam climate in the touching column's REAL
				-- surface family (wdl_climate.surface_family): footprint
				-- biome tags are one name per 16x16 chunk and often lie
				-- about the columns next to them (a minecraft:snowy_
				-- plains tag over grass+birch ground gave the owner's
				-- square snow fields with trees through them). The blocks
				-- win: frozen ground -> cold seam, unfrozen soil or bare
				-- sand -> never a snowy seam. Stone/builds/water stay
				-- neutral and the tag decides.
				local seam_heat = seam_def and seam_def.heat_point or nil
				local seam_hum = seam_def and (seam_def.humidity_point or 50) or nil
				if seam_heat then
					if fam == "snow" then
						seam_heat = math.min(seam_heat, SNOW_CEIL)
					elseif fam == "grass" or fam == "sand" then
						seam_heat = math.max(seam_heat, TEMPERATE_FLOOR)
					end
				end

				local mcl, def
				local heat, hum
				if seam_heat and nat_heat then
					heat = w * seam_heat + (1 - w) * nat_heat
					hum = w * (seam_hum or 50) + (1 - w) * (nat_hum or 50)
				elseif seam_heat then
					heat, hum = seam_heat, seam_hum or 50
				elseif nat_heat then
					heat, hum = nat_heat, nat_hum or 50
				end
				if heat then
					local names = wdl.candidate_biomes(registered, wet or false)
					mcl = wdl.nearest_biome(registered, names, heat, hum, y)
					def = mcl and registered[mcl] or nil
				end
				if not mcl then
					mcl, def = seam_name or nat_name,
						(seam_name and registered[seam_name])
						or (nat_name and registered[nat_name])
				end

				col.tmc, col.tmcl, col.tid, col.tdef = mc, mcl,
					mcl and core.get_biome_id(mcl) or nil, def
				col.tint = def and def._mcl_palette_index or nil
				-- Snow layer from the RESOLVED biome only. The old extra
				-- clause ("or wdl.is_snowy(mc, y, ...)") read the raw
				-- chunk tag and blanketed snow over columns whose resolved
				-- biome was BirchForest -- snow with birch trees growing
				-- through it (owner 2026-09-25). Merged terrain must look
				-- like NATIVE Mineclonia terrain, and Mineclonia puts snow
				-- where its biome says snow; a real frozen seam still gets
				-- snow via the "snow" surface family above (the resolved
				-- biome goes cold at w~1) and the seam-material copy keeps
				-- the touching blocks' look.
				col.tsnow = (def and def._mcl_biome_type == "snowy") or false
				if col.tsnow and (fam == "grass" or fam == "sand") and w > 0.35 then
					col.tsnow = false
				end
				local grp = def and def._mcl_groups
				col.tdeep = (grp and grp.is_ocean) and "ocean" or "sand"
			end
		end
	end
	return plan
end

return inputs
end

return factory
