#!/usr/bin/env luajit
-- Source-side footprint + height/water extractor (round 25 fitting-
-- algorithm work). Given a real base's source region directory, produces
-- a TRUE per-chunk footprint (which chunks actually have real saved
-- data -- not a bounding rectangle, which is all `chunk_bounds` in
-- museum_manifest.json has ever recorded) plus a surface height and
-- land/water classification for each present chunk.
--
-- Why this exists: Tactical Nuke's water-intrusion bug (round 25) traced
-- back to the placement pipeline never checking real terrain compatibility
-- at all -- only an aggregate biome-name histogram, sampled sparsely, with
-- no concept of "is this specific chunk actually land or water" on either
-- the source or destination side. This is the SOURCE half of the fix: a
-- real per-chunk profile to compare against a destination profile
-- (produced separately by dest_probe worldmod, since real terrain height
-- requires the actual engine's mapgen model -- confirmed not available in
-- a standalone script, see this feature's HANDOFF.md writeup).
--
-- Reuses anvil.lua exactly as spawnimport/init.lua does (same functions,
-- same chunk-coordinate conventions) -- do not reinvent chunk decoding.
-- Standalone zlib decompress comes from gzip.lua (its windowBits=47 auto-
-- detects zlib OR gzip headers, confirmed by that file's own header
-- comment), not the missing lua_import/ffi_zlib_stub.lua referenced by
-- mods/spawnimport/test_harness.lua.
--
-- Run: luajit source_footprint.lua <source_region_dir> <output_json_path>
-- Example:
--   luajit source_footprint.lua \
--     "/Users/dara/dev/2b2tmuseum-WDL/WDL/2013/l23w35 Tactical Nuke 2023-09-02_2247 remap2 (_2309 merge)/region" \
--     /tmp/tactical_nuke_footprint.json

local function script_dir()
	local source = debug.getinfo(1, "S").source
	return source:match("^@(.*[/\\])") or "./"
end
local HERE = script_dir()
local LUA_IMPORT = HERE .. "../../lua_import/"

local gzip = dofile(LUA_IMPORT .. "gzip.lua")
local anvil = dofile(LUA_IMPORT .. "anvil.lua")

anvil.decompress = gzip.decompress
anvil.list_dir = function(dir)
	local p = io.popen(string.format("ls -1 %q 2>/dev/null", dir))
	local names = {}
	if p then
		for line in p:lines() do names[#names + 1] = line end
		p:close()
	end
	return names
end

local WATER_NAMES = {
	["minecraft:water"] = true,
	["minecraft:bubble_column"] = true, -- always sits directly on/in water
}

-- Surface biome for a chunk. World Downloader captures flatten the 3D
-- biome field to a single biome per section (verified against real data:
-- every section of a chunk carries the same palette[1]), so the surface
-- biome is just the biome of the highest section that has one.
local function chunk_surface_biome(chunk)
	if not chunk.sections then return nil end
	for i = #chunk.sections, 1, -1 do
		local s = chunk.sections[i]
		if s.biomes and s.biomes.palette and s.biomes.palette[1] then
			return s.biomes.palette[1]
		end
	end
	return nil
end

local region_dir = arg[1]
local out_path = arg[2]
if not region_dir or not out_path then
	io.stderr:write("usage: luajit source_footprint.lua <source_region_dir> <output_json_path>\n")
	os.exit(1)
end

local files = anvil.list_region_files(region_dir)
io.stderr:write(string.format("found %d region files in %s\n", #files, region_dir))

local chunks = {}     -- key "cx,cz" -> {cx=,cz=,height=,is_water=,legacy=}
local n_present, n_decoded, n_legacy_skipped, n_error = 0, 0, 0, 0

for _, fpath in ipairs(files) do
	local data, err = anvil.read_file(fpath)
	if not data then
		io.stderr:write(string.format("WARN: could not read %s: %s\n", fpath, tostring(err)))
	else
		local region_x, region_z = anvil.region_coords_from_filename(fpath)
		local locations = anvil.read_region_locations(data)
		for _, loc in ipairs(locations) do
			n_present = n_present + 1
			local cx = region_x * 32 + loc.local_x
			local cz = region_z * 32 + loc.local_z
			local payload = anvil.read_chunk_payload(data, loc.offset)
			local ok_nbt, chunk = pcall(function()
				local nbt = dofile(LUA_IMPORT .. "nbt.lua")
				return nbt.parse_buffer(payload)
			end)
			if not ok_nbt then
				n_error = n_error + 1
			else
				-- track max-y block name per LOCAL (lx,lz) column, so we
				-- can emit a full per-column top-height map ("cols") for
				-- the gap-fill border-blend work, not just a single
				-- centre-column sample. decode_chunk_blocks reports
				-- ABSOLUTE coords (base_x + lx), so subtract the chunk
				-- origin to get lx/lz in 0..15.
				local top_y = {}   -- local index lx*16+lz -> y (0..255)
				local top_name = {}
				local solid_y = {} -- highest NON-LIQUID block (ground/floor)
				local base_x = cx * 16
				local base_z = cz * 16
				local ok_decode, decode_err = pcall(anvil.decode_chunk_blocks, chunk, function(x, y, z, name)
					local lx = x - base_x
					local lz = z - base_z
					if lx < 0 or lx > 15 or lz < 0 or lz > 15 then return end
					local idx = lx * 16 + lz
					local cur = top_y[idx]
					if not cur or y > cur then
						top_y[idx] = y
						top_name[idx] = name
					end
					if not WATER_NAMES[name] then
						local cur2 = solid_y[idx]
						if not cur2 or y > cur2 then solid_y[idx] = y end
					end
				end)
				if not ok_decode then
					n_legacy_skipped = n_legacy_skipped + 1
				else
					n_decoded = n_decoded + 1
					-- summarize this chunk: median-ish single sample via
					-- the chunk CENTER column (local 7,7) if present,
					-- else average of whatever columns were found -- the
					-- center is representative enough for a per-chunk
					-- compatibility check.
					local center_idx = 7 * 16 + 7
					local height, is_water
					if top_y[center_idx] then
						height = top_y[center_idx]
						is_water = WATER_NAMES[top_name[center_idx]] or false
					else
						local sum, count, water_count = 0, 0, 0
						for idx, y in pairs(top_y) do
							sum = sum + y
							count = count + 1
							if WATER_NAMES[top_name[idx]] then water_count = water_count + 1 end
						end
						if count > 0 then
							height = math.floor(sum / count + 0.5)
							is_water = (water_count / count) > 0.5
						end
					end
					if height then
						-- full 16x16 per-column top-Y map; columns with no
						-- blocks anywhere fall back to the chunk's own
						-- summary height. solid_cols is the same but
						-- liquid-excluding (the terrain surface: ground
						-- for land, ocean floor for water) -- what the
						-- gap-fill terrain blend actually wants.
						local cols, solid_cols = {}, {}
						for idx = 0, 255 do
							cols[idx + 1] = top_y[idx] or height
							solid_cols[idx + 1] = solid_y[idx] or height
						end
						chunks[cx .. "," .. cz] = {
							cx = cx, cz = cz, height = height,
							is_water = is_water, cols = cols,
							solid_cols = solid_cols,
							biome = chunk_surface_biome(chunk),
						}
					end
				end
			end
		end
	end
end

io.stderr:write(string.format(
	"present=%d decoded=%d legacy_skipped(pre-1.18)=%d nbt_error=%d\n",
	n_present, n_decoded, n_legacy_skipped, n_error))

-- ---------------------------------------------------------------------
-- Write output JSON
-- ---------------------------------------------------------------------
local out = io.open(out_path, "w")
out:write('{\n')
out:write(string.format('  "region_dir": %q,\n', region_dir))
out:write(string.format('  "present_chunks": %d,\n', n_present))
out:write(string.format('  "decoded_chunks": %d,\n', n_decoded))
out:write(string.format('  "legacy_skipped": %d,\n', n_legacy_skipped))
out:write('  "chunks": [\n')
local first = true
local n_water, n_land = 0, 0
for _, c in pairs(chunks) do
	if not first then out:write(',\n') end
	first = false
	-- Compact per-column maps: 256 ints, local x*16+z order.
	local cols, solid_cols = {}, {}
	for i = 1, 256 do
		cols[i] = c.cols[i]
		solid_cols[i] = c.solid_cols[i]
	end
	out:write(string.format('    {"cx":%d,"cz":%d,"height":%d,"is_water":%s,"biome":%q,"cols":[%s],"solid_cols":[%s]}',
		c.cx, c.cz, c.height, c.is_water and "true" or "false", c.biome or "",
		table.concat(cols, ","), table.concat(solid_cols, ",")))
	if c.is_water then n_water = n_water + 1 else n_land = n_land + 1 end
end
out:write('\n  ],\n')
out:write(string.format('  "land_chunks": %d,\n  "water_chunks": %d\n', n_land, n_water))
out:write('}\n')
out:close()
io.stderr:write(string.format("wrote %s (%d land, %d water chunks profiled)\n", out_path, n_land, n_water))
