-- wgen_inputs.lua -- per-column merge TARGETS: biome, surface material,
-- grass tint, snow (PLAN-worldgen-merge.md phase 1). Loaded as a factory:
--     local wgen_inputs = dofile(modpath .. "/wgen_inputs.lua")(wdl_climate)
--
-- For every column the merge will write, decide what the column should
-- BE once merged:
--
--   * seam columns (adjacent to captured chunks) continue the world
--     download: the captured neighbour's Minecraft biome (per column when
--     the footprint carries `biome_cols`, per chunk otherwise) mapped to
--     the matching Mineclonia biome;
--   * columns in the ring chunk TOUCHING the capture keep that world-
--     download biome (a 1-chunk band of the capture's climate);
--   * columns further out blend to the NATURAL Mineclonia biome of their
--     own position (core.get_biome_data at the column's natural surface)
--     so the merge is invisible where it meets untouched terrain.
--
-- Everything downstream (surface stack, grass tint, snow layer, and the
-- biomemap fed to the engine decoration pass) derives from these targets.

local function factory(wdl)
local inputs = {}

local C = 16

-- Minecraft biome name of a captured chunk's column (lx,lz in 0..15,
-- lx*16+lz local order -- the footprint's per-column order).
local function captured_mc_biome(r, lx, lz)
	if r.biome_cols then
		local b = r.biome_cols[lx * C + lz + 1]
		if b and b ~= "" then return b end
	end
	return r.biome
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

-- Attach target fields to every plan column:
--   col.tmc    target MC biome name (may be nil for natural-blend cols)
--   col.tmcl   target Mineclonia biome name
--   col.tid    target engine biome id (for the decoration biomemap)
--   col.tdef   the Mineclonia biome def (registered_biomes[tmcl])
--   col.tint   grass param2 palette index (or nil)
--   col.tsnow  place a snow layer on top
--   col.tdeep  water floor rule: "ocean" (def material) / "sand"
-- Plan columns are keyed in chunk.col[lx*C+lz+1]; source chunk coords
-- come from chunk.cx/cz (same grid seam_constraints uses).
function inputs.attach_targets(job, real, plan)
	-- 1. Nearest captured column per plan column (multi-source BFS in the
	--    source-column grid; label = that captured column's MC biome).
	local dist, src = {}, {}
	local queue, qhead = {}, 1
	local function key(x, z) return x .. "," .. z end

	local captured = {} -- "sx,sz" -> mc biome name
	for ckey, r in pairs(real) do
		local cx, cz = ckey:match("^(.-)_(.-)$")
		cx, cz = tonumber(cx), tonumber(cz)
		for lx = 0, C - 1 do
			for lz = 0, C - 1 do
				captured[key(cx * C + lx, cz * C + lz)] =
					captured_mc_biome(r, lx, lz)
			end
		end
	end

	-- Seed: plan columns touching a captured column.
	for _, chunk in pairs(plan.chunks) do
		for lx = 0, C - 1 do
			for lz = 0, C - 1 do
				local sx, sz = chunk.cx * C + lx, chunk.cz * C + lz
				local skey = key(sx, sz)
				if not dist[skey] then
					for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
						local b = captured[key(sx + d[1], sz + d[2])]
						if b then
							dist[skey], src[skey] = 1, b
							queue[#queue + 1] = { sx, sz }
							break
						end
					end
				end
			end
		end
	end
	-- Propagate within the plan domain (nearest captured biome wins).
	while qhead <= #queue do
		local p = queue[qhead]
		qhead = qhead + 1
		local skey = key(p[1], p[2])
		for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
			local nk = key(p[1] + d[1], p[2] + d[2])
			if not dist[nk] and plan.by_key[nk] then
				dist[nk], src[nk] = dist[skey] + 1, src[skey]
				queue[#queue + 1] = { p[1] + d[1], p[2] + d[2] }
			end
		end
	end

	-- 2. Assign targets. "Near" (the capture's own climate band) = every
	--    column of a ring chunk that touches a captured chunk; "far" =
	--    natural blend. Both stay exact at the two boundaries by
	--    construction: the seam keeps the capture's biome, the outer edge
	--    keeps the natural one.
	for key_c, chunk in pairs(plan.chunks) do
		local near = chunk.touches_capture
		for lx = 0, C - 1 do
			for lz = 0, C - 1 do
				local col = chunk.col[lx * C + lz + 1]
				local skey = key(chunk.cx * C + lx, chunk.cz * C + lz)
				local mc, mcl, tid, def

				if near and src[skey] then
					mc = src[skey]
					mcl = resolve_mcl(mc)
					if mcl then tid = core.get_biome_id(mcl) end
				end
				if not tid then
					-- natural blend column (or unmapped capture biome):
					-- the biome the engine itself would pick here
					if core.get_biome_data then
						local okc, bd = pcall(core.get_biome_data, {
							x = chunk.base_x + lx,
							y = (col.S or col.B or 0),
							z = chunk.base_z + lz,
						})
						if okc and bd and bd.biome then
							tid = bd.biome
							local nm = core.get_biome_name and core.get_biome_name(tid)
							mcl = (nm and core.registered_biomes[nm]) and nm or mcl
						end
					end
				end
				def = mcl and core.registered_biomes[mcl] or nil

				col.tmc, col.tmcl, col.tid, col.tdef = mc, mcl, tid, def
				col.tint = def and def._mcl_palette_index or nil
				col.tsnow = def and def._mcl_biome_type == "snowy" or false
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
