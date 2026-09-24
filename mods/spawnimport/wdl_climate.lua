-- wdl_climate.lua -- world-download biome + climate data for the
-- worldgen-merge gap fill (see PLAN-worldgen-merge.md).
--
-- PURE module (like gap_field.lua): no `core.*` at load time, runs under
-- plain luajit as well as inside the mod. It answers three questions:
--
--   1. Which Mineclonia biome does a captured column's Minecraft biome
--      (e.g. "minecraft:plains") belong to?   -> wdl_climate.mcl_biome()
--   2. What is the temperature at this column's surface?  MC biomes
--      carry a fixed temperature that falls with altitude; the value at
--      surface height decides snow cover (temp < 0.15) and ice on water
--      (temp < 0) -- this is the "temperature map" reconstructed from
--      the capture's biome field + heights.
--   3. What surface material / grass tint does the target Mineclonia
--      biome want?  -> wdl_climate.surface_of() against
--      core.registered_biomes at call time.
--
-- The MC->Mineclonia names use Mineclonia's LEGACY biome names (the ones
-- in core.registered_biomes, verified against mcl_biomes/init.lua's
-- registration list). Where Mineclonia splits one MC biome into climate
-- variants (per-biome _ocean/_beach), the most neutral variant is used.

local climate = {}

-- Minecraft 1.18+ biome id -> Mineclonia registered biome name.
climate.MC_TO_MCL = {
	["minecraft:plains"] = "Plains",
	["minecraft:sunflower_plains"] = "SunflowerPlains",
	["minecraft:forest"] = "Forest",
	["minecraft:flower_forest"] = "FlowerForest",
	["minecraft:birch_forest"] = "BirchForest",
	["minecraft:old_growth_birch_forest"] = "BirchForestM",
	["minecraft:dark_forest"] = "RoofedForest",
	["minecraft:pale_garden"] = "PaleGarden",
	["minecraft:taiga"] = "Taiga",
	["minecraft:snowy_taiga"] = "ColdTaiga",
	["minecraft:old_growth_pine_taiga"] = "MegaTaiga",
	["minecraft:old_growth_spruce_taiga"] = "MegaSpruceTaiga",
	["minecraft:snowy_plains"] = "IcePlains",
	["minecraft:ice_spikes"] = "IcePlainsSpikes",
	["minecraft:snowy_slopes"] = "SnowySlopes",
	["minecraft:grove"] = "Grove",
	["minecraft:meadow"] = "Meadow",
	["minecraft:cherry_grove"] = "CherryGrove",
	["minecraft:frozen_peaks"] = "FrozenPeaks",
	["minecraft:jagged_peaks"] = "JaggedPeaks",
	["minecraft:stony_peaks"] = "StonyPeaks",
	["minecraft:desert"] = "Desert",
	["minecraft:badlands"] = "Mesa",
	["minecraft:wooded_badlands"] = "MesaPlateauF",
	["minecraft:eroded_badlands"] = "MesaBryce",
	["minecraft:savanna"] = "Savanna",
	["minecraft:savanna_plateau"] = "SavannaM",
	["minecraft:jungle"] = "Jungle",
	["minecraft:sparse_jungle"] = "JungleEdge",
	["minecraft:bamboo_jungle"] = "BambooJungle",
	["minecraft:swamp"] = "Swampland",
	["minecraft:mangrove_swamp"] = "MangroveSwamp",
	["minecraft:mushroom_fields"] = "MushroomIsland",
	["minecraft:beach"] = "Plains_beach",
	["minecraft:snowy_beach"] = "ColdTaiga_beach",
	["minecraft:stony_shore"] = "StoneBeach",
	["minecraft:river"] = "Plains", -- no distinct Mineclonia river biome
	["minecraft:frozen_river"] = "IcePlains",
	["minecraft:ocean"] = "Plains_ocean",
	["minecraft:deep_ocean"] = "Plains_ocean",
	["minecraft:warm_ocean"] = "Plains_ocean",
	["minecraft:lukewarm_ocean"] = "Plains_ocean",
	["minecraft:deep_lukewarm_ocean"] = "Plains_ocean",
	["minecraft:cold_ocean"] = "IcePlains_ocean",
	["minecraft:deep_cold_ocean"] = "IcePlains_ocean",
	["minecraft:frozen_ocean"] = "IcePlains_ocean",
	["minecraft:deep_frozen_ocean"] = "IcePlains_ocean",
	["minecraft:windswept_hills"] = "ExtremeHills",
	["minecraft:windswept_forest"] = "ExtremeHillsM",
	["minecraft:windswept_gravelly_hills"] = "ExtremeHills+",
	["minecraft:deep_dark"] = "DeepDark",
	["minecraft:lush_caves"] = "LushCaves",
	["minecraft:dripstone_caves"] = "DripstoneCave",
}

-- Minecraft biome temperature (climates.csv values). Missing entries
-- fall back to DEFAULT_TEMP. Used with the altitude falloff below to
-- reconstruct the temperature map at each column's surface.
local DEFAULT_TEMP = 0.8
climate.MC_TEMP = {
	["minecraft:plains"] = 0.8,
	["minecraft:sunflower_plains"] = 0.8,
	["minecraft:forest"] = 0.7,
	["minecraft:flower_forest"] = 0.7,
	["minecraft:birch_forest"] = 0.6,
	["minecraft:old_growth_birch_forest"] = 0.6,
	["minecraft:dark_forest"] = 0.7,
	["minecraft:pale_garden"] = 0.7,
	["minecraft:taiga"] = 0.25,
	["minecraft:snowy_taiga"] = -0.5,
	["minecraft:old_growth_pine_taiga"] = 0.3,
	["minecraft:old_growth_spruce_taiga"] = 0.25,
	["minecraft:snowy_plains"] = -0.2,
	["minecraft:ice_spikes"] = -0.5,
	["minecraft:snowy_slopes"] = -0.3,
	["minecraft:grove"] = -0.2,
	["minecraft:meadow"] = 0.5,
	["minecraft:cherry_grove"] = 0.5,
	["minecraft:frozen_peaks"] = -0.7,
	["minecraft:jagged_peaks"] = -0.7,
	["minecraft:stony_peaks"] = 0.3,
	["minecraft:desert"] = 2.0,
	["minecraft:badlands"] = 2.0,
	["minecraft:wooded_badlands"] = 2.0,
	["minecraft:eroded_badlands"] = 2.0,
	["minecraft:savanna"] = 2.0,
	["minecraft:savanna_plateau"] = 1.0,
	["minecraft:jungle"] = 0.95,
	["minecraft:sparse_jungle"] = 0.95,
	["minecraft:bamboo_jungle"] = 0.95,
	["minecraft:swamp"] = 0.8,
	["minecraft:mangrove_swamp"] = 0.8,
	["minecraft:mushroom_fields"] = 0.9,
	["minecraft:beach"] = 0.8,
	["minecraft:snowy_beach"] = 0.05,
	["minecraft:stony_shore"] = 0.2,
	["minecraft:river"] = 0.5,
	["minecraft:frozen_river"] = 0.0,
	["minecraft:ocean"] = 0.5,
	["minecraft:deep_ocean"] = 0.5,
	["minecraft:warm_ocean"] = 0.5,
	["minecraft:lukewarm_ocean"] = 0.5,
	["minecraft:deep_lukewarm_ocean"] = 0.5,
	["minecraft:cold_ocean"] = 0.0,
	["minecraft:deep_cold_ocean"] = 0.0,
	["minecraft:frozen_ocean"] = -0.5,
	["minecraft:deep_frozen_ocean"] = -0.5,
	["minecraft:windswept_hills"] = 0.2,
	["minecraft:windswept_forest"] = 0.2,
	["minecraft:windswept_gravelly_hills"] = 0.2,
	["minecraft:deep_dark"] = 0.5,
	["minecraft:lush_caves"] = 0.5,
	["minecraft:dripstone_caves"] = 0.5,
}

-- Vanilla altitude falloff: above sea level (MC y 64) temperature drops
-- 0.05 per 30 blocks. y_mc is a MINECRAFT-space y (the caller converts
-- dest y with dest_y_offset). Snow settles below 0.15, water freezes
-- below 0 -- the vanilla thresholds.
climate.SNOW_TEMP = 0.15
climate.FREEZE_TEMP = 0.0
local LAPSE = 0.05 / 30

function climate.temp_at_height(temp, y_mc)
	if y_mc > 64 then
		return temp - (y_mc - 64) * LAPSE
	end
	return temp
end

-- Base temperature of a captured column's MC biome name.
function climate.mc_temp(mc_biome)
	-- ---------------------------------------------------------------------
-- Organic seam-edge noise (pure). The per-column merge weight used to
-- follow the capture outline GEOMETRICALLY (a 4-neighbour BFS distance
-- has straight Voronoi edges and triangular diagonals) -- owner
-- 2026-09-25: "very square shaped snow ... highly triangular ... it
-- looks very mathematical and uniform". Value noise on the column
-- position shifts the fade edge by a few columns in smooth ~20-block
-- blobs, which is what real biome borders look like.
local function hash2(x, z)
	local n = math.sin(x * 127.1 + z * 311.7) * 43758.5453
	return n - math.floor(n)
end

function climate.noise2(x, z, scale)
	local fx, fz = x / scale, z / scale
	local ix, iz = math.floor(fx), math.floor(fz)
	local tx, tz = fx - ix, fz - iz
	tx = tx * tx * (3 - 2 * tx)
	tz = tz * tz * (3 - 2 * tz)
	local a = hash2(ix, iz)
	local b = hash2(ix + 1, iz)
	local c = hash2(ix, iz + 1)
	local d = hash2(ix + 1, iz + 1)
	local ab = a + (b - a) * tx
	local cd = c + (d - c) * tx
	return ab + (cd - ab) * tz
end

-- Seam-edge jitter in COLUMNS (added to the BFS distance before the
-- biome/material fade is evaluated).
function climate.jitter(x, z)
	return (climate.noise2(x, z, 23) - 0.5) * 16
		+ (climate.noise2(x, z, 7) - 0.5) * 6
end

-- Surface family of a captured seam column from the REAL nodes around
-- its surface. This exists because footprints carry ONE biome name per
-- 16x16 chunk (no biome_cols) and the tag is frequently wrong for the
-- columns next to it -- minecraft:snowy_plains tags over grass+birch
-- ground produced the owner's square snow fields with trees growing
-- through them. The blocks tell the truth:
--   "snow"   frozen ground / snow layer / ice -> the seam is COLD
--   "grass"  unfrozen soil                    -> the seam is TEMPERATE
--   "sand"   bare sand                        -> the seam is WARM
--   "water"  liquid top                       -> neutral (tag decides)
--   nil      stone / builds / plain dirt      -> neutral (tag decides)
function climate.surface_family(top_name, ground_name)
	local function snowish(n)
		return n ~= nil and (n:find("snow") or n:find("ice")) ~= nil
	end
	if snowish(top_name) then return "snow" end
	if top_name and top_name:find("water") then return "water" end
	local g = ground_name
	if not g or g == "" or g == "ignore" then return nil end
	if snowish(g) then return "snow" end
	-- seagrass_*/kelp_* floors are seabed with a plant name, not soil
	if g:find("seagrass") or g:find("kelp") then
		return g:find("sand") and "sand" or nil
	end
	if g:find("grass") or g:find("podzol") or g:find("mycelium") then
		return "grass"
	end
	if g:find("sand") then return "sand" end
	return nil
end

return climate.MC_TEMP[mc_biome] or DEFAULT_TEMP
end

-- Temperature at a column's surface height (dest y + offset = MC y).
function climate.temp_at(mc_biome, y_dest, dest_y_offset)
	-- ---------------------------------------------------------------------
-- Organic seam-edge noise (pure). The per-column merge weight used to
-- follow the capture outline GEOMETRICALLY (a 4-neighbour BFS distance
-- has straight Voronoi edges and triangular diagonals) -- owner
-- 2026-09-25: "very square shaped snow ... highly triangular ... it
-- looks very mathematical and uniform". Value noise on the column
-- position shifts the fade edge by a few columns in smooth ~20-block
-- blobs, which is what real biome borders look like.
local function hash2(x, z)
	local n = math.sin(x * 127.1 + z * 311.7) * 43758.5453
	return n - math.floor(n)
end

function climate.noise2(x, z, scale)
	local fx, fz = x / scale, z / scale
	local ix, iz = math.floor(fx), math.floor(fz)
	local tx, tz = fx - ix, fz - iz
	tx = tx * tx * (3 - 2 * tx)
	tz = tz * tz * (3 - 2 * tz)
	local a = hash2(ix, iz)
	local b = hash2(ix + 1, iz)
	local c = hash2(ix, iz + 1)
	local d = hash2(ix + 1, iz + 1)
	local ab = a + (b - a) * tx
	local cd = c + (d - c) * tx
	return ab + (cd - ab) * tz
end

-- Seam-edge jitter in COLUMNS (added to the BFS distance before the
-- biome/material fade is evaluated).
function climate.jitter(x, z)
	return (climate.noise2(x, z, 23) - 0.5) * 16
		+ (climate.noise2(x, z, 7) - 0.5) * 6
end

-- Surface family of a captured seam column from the REAL nodes around
-- its surface. This exists because footprints carry ONE biome name per
-- 16x16 chunk (no biome_cols) and the tag is frequently wrong for the
-- columns next to it -- minecraft:snowy_plains tags over grass+birch
-- ground produced the owner's square snow fields with trees growing
-- through them. The blocks tell the truth:
--   "snow"   frozen ground / snow layer / ice -> the seam is COLD
--   "grass"  unfrozen soil                    -> the seam is TEMPERATE
--   "sand"   bare sand                        -> the seam is WARM
--   "water"  liquid top                       -> neutral (tag decides)
--   nil      stone / builds / plain dirt      -> neutral (tag decides)
function climate.surface_family(top_name, ground_name)
	local function snowish(n)
		return n ~= nil and (n:find("snow") or n:find("ice")) ~= nil
	end
	if snowish(top_name) then return "snow" end
	if top_name and top_name:find("water") then return "water" end
	local g = ground_name
	if not g or g == "" or g == "ignore" then return nil end
	if snowish(g) then return "snow" end
	-- seagrass_*/kelp_* floors are seabed with a plant name, not soil
	if g:find("seagrass") or g:find("kelp") then
		return g:find("sand") and "sand" or nil
	end
	if g:find("grass") or g:find("podzol") or g:find("mycelium") then
		return "grass"
	end
	if g:find("sand") then return "sand" end
	return nil
end

return climate.temp_at_height(
		climate.mc_temp(mc_biome), y_dest - (dest_y_offset or 0))
end

function climate.is_snowy(mc_biome, y_dest, dest_y_offset)
	-- ---------------------------------------------------------------------
-- Organic seam-edge noise (pure). The per-column merge weight used to
-- follow the capture outline GEOMETRICALLY (a 4-neighbour BFS distance
-- has straight Voronoi edges and triangular diagonals) -- owner
-- 2026-09-25: "very square shaped snow ... highly triangular ... it
-- looks very mathematical and uniform". Value noise on the column
-- position shifts the fade edge by a few columns in smooth ~20-block
-- blobs, which is what real biome borders look like.
local function hash2(x, z)
	local n = math.sin(x * 127.1 + z * 311.7) * 43758.5453
	return n - math.floor(n)
end

function climate.noise2(x, z, scale)
	local fx, fz = x / scale, z / scale
	local ix, iz = math.floor(fx), math.floor(fz)
	local tx, tz = fx - ix, fz - iz
	tx = tx * tx * (3 - 2 * tx)
	tz = tz * tz * (3 - 2 * tz)
	local a = hash2(ix, iz)
	local b = hash2(ix + 1, iz)
	local c = hash2(ix, iz + 1)
	local d = hash2(ix + 1, iz + 1)
	local ab = a + (b - a) * tx
	local cd = c + (d - c) * tx
	return ab + (cd - ab) * tz
end

-- Seam-edge jitter in COLUMNS (added to the BFS distance before the
-- biome/material fade is evaluated).
function climate.jitter(x, z)
	return (climate.noise2(x, z, 23) - 0.5) * 16
		+ (climate.noise2(x, z, 7) - 0.5) * 6
end

-- Surface family of a captured seam column from the REAL nodes around
-- its surface. This exists because footprints carry ONE biome name per
-- 16x16 chunk (no biome_cols) and the tag is frequently wrong for the
-- columns next to it -- minecraft:snowy_plains tags over grass+birch
-- ground produced the owner's square snow fields with trees growing
-- through them. The blocks tell the truth:
--   "snow"   frozen ground / snow layer / ice -> the seam is COLD
--   "grass"  unfrozen soil                    -> the seam is TEMPERATE
--   "sand"   bare sand                        -> the seam is WARM
--   "water"  liquid top                       -> neutral (tag decides)
--   nil      stone / builds / plain dirt      -> neutral (tag decides)
function climate.surface_family(top_name, ground_name)
	local function snowish(n)
		return n ~= nil and (n:find("snow") or n:find("ice")) ~= nil
	end
	if snowish(top_name) then return "snow" end
	if top_name and top_name:find("water") then return "water" end
	local g = ground_name
	if not g or g == "" or g == "ignore" then return nil end
	if snowish(g) then return "snow" end
	-- seagrass_*/kelp_* floors are seabed with a plant name, not soil
	if g:find("seagrass") or g:find("kelp") then
		return g:find("sand") and "sand" or nil
	end
	if g:find("grass") or g:find("podzol") or g:find("mycelium") then
		return "grass"
	end
	if g:find("sand") then return "sand" end
	return nil
end

return climate.temp_at(mc_biome, y_dest, dest_y_offset) < climate.SNOW_TEMP
end

function climate.is_frozen(mc_biome, y_dest, dest_y_offset)
	-- ---------------------------------------------------------------------
-- Organic seam-edge noise (pure). The per-column merge weight used to
-- follow the capture outline GEOMETRICALLY (a 4-neighbour BFS distance
-- has straight Voronoi edges and triangular diagonals) -- owner
-- 2026-09-25: "very square shaped snow ... highly triangular ... it
-- looks very mathematical and uniform". Value noise on the column
-- position shifts the fade edge by a few columns in smooth ~20-block
-- blobs, which is what real biome borders look like.
local function hash2(x, z)
	local n = math.sin(x * 127.1 + z * 311.7) * 43758.5453
	return n - math.floor(n)
end

function climate.noise2(x, z, scale)
	local fx, fz = x / scale, z / scale
	local ix, iz = math.floor(fx), math.floor(fz)
	local tx, tz = fx - ix, fz - iz
	tx = tx * tx * (3 - 2 * tx)
	tz = tz * tz * (3 - 2 * tz)
	local a = hash2(ix, iz)
	local b = hash2(ix + 1, iz)
	local c = hash2(ix, iz + 1)
	local d = hash2(ix + 1, iz + 1)
	local ab = a + (b - a) * tx
	local cd = c + (d - c) * tx
	return ab + (cd - ab) * tz
end

-- Seam-edge jitter in COLUMNS (added to the BFS distance before the
-- biome/material fade is evaluated).
function climate.jitter(x, z)
	return (climate.noise2(x, z, 23) - 0.5) * 16
		+ (climate.noise2(x, z, 7) - 0.5) * 6
end

-- Surface family of a captured seam column from the REAL nodes around
-- its surface. This exists because footprints carry ONE biome name per
-- 16x16 chunk (no biome_cols) and the tag is frequently wrong for the
-- columns next to it -- minecraft:snowy_plains tags over grass+birch
-- ground produced the owner's square snow fields with trees growing
-- through them. The blocks tell the truth:
--   "snow"   frozen ground / snow layer / ice -> the seam is COLD
--   "grass"  unfrozen soil                    -> the seam is TEMPERATE
--   "sand"   bare sand                        -> the seam is WARM
--   "water"  liquid top                       -> neutral (tag decides)
--   nil      stone / builds / plain dirt      -> neutral (tag decides)
function climate.surface_family(top_name, ground_name)
	local function snowish(n)
		return n ~= nil and (n:find("snow") or n:find("ice")) ~= nil
	end
	if snowish(top_name) then return "snow" end
	if top_name and top_name:find("water") then return "water" end
	local g = ground_name
	if not g or g == "" or g == "ignore" then return nil end
	if snowish(g) then return "snow" end
	-- seagrass_*/kelp_* floors are seabed with a plant name, not soil
	if g:find("seagrass") or g:find("kelp") then
		return g:find("sand") and "sand" or nil
	end
	if g:find("grass") or g:find("podzol") or g:find("mycelium") then
		return "grass"
	end
	if g:find("sand") then return "sand" end
	return nil
end

return climate.temp_at(mc_biome, y_dest, dest_y_offset) < climate.FREEZE_TEMP
end

-- MC biome name -> Mineclonia biome name (nil when unmapped).
function climate.mcl_biome(mc_biome)
	return mc_biome and climate.MC_TO_MCL[mc_biome] or nil
end

-- Mineclonia's own climate axes (def.heat_point / def.humidity_point,
-- the same numbers the engine's biome picker uses). Blending on these
-- and re-resolving to the nearest registered biome is what gives a
-- NATURAL biome shift between the capture's biome and the surrounding
-- Mineclonia terrain (no chunk-edge squares).
local LAND_NAMES = {
	"Plains", "SunflowerPlains", "Forest", "FlowerForest", "BirchForest",
	"BirchForestM", "RoofedForest", "PaleGarden", "Taiga", "MegaTaiga",
	"MegaSpruceTaiga", "ColdTaiga", "IcePlains", "IcePlainsSpikes",
	"SnowySlopes", "Grove", "Meadow", "CherryGrove", "FrozenPeaks",
	"JaggedPeaks", "StonyPeaks", "Desert", "Mesa", "MesaBryce",
	"MesaPlateauF", "MesaPlateauFM", "Savanna", "SavannaM", "Jungle",
	"JungleM", "JungleEdge", "JungleEdgeM", "BambooJungle", "Swampland",
	"MangroveSwamp", "MushroomIsland", "ExtremeHills", "ExtremeHillsM",
	"ExtremeHills+", "StoneBeach",
}
climate.LAND_NAMES = LAND_NAMES

-- Candidate surface biomes for nearest-climate resolution, split by
-- wet/dry so sea floors get seabed materials and land gets land ones.
function climate.candidate_biomes(registered, is_water)
	local out = {}
	if is_water then
		for _, n in ipairs(LAND_NAMES) do
			local w = n .. "_ocean"
			if registered[w] then out[#out + 1] = w end
		end
		if #out == 0 then out[1] = "Plains_ocean" end
	else
		for _, n in ipairs(LAND_NAMES) do
			if registered[n] then out[#out + 1] = n end
		end
	end
	return out
end

-- Nearest registered biome by (heat_point, humidity_point), honouring
-- the biome's registered y_min/y_max band the way the engine's own
-- picker does. Without the band, mountain biomes with extreme climate
-- points (StonyPeaks 45/88, y_min=72) beat lowland biomes at their own
-- game (BirchForest 31/78) and merged terrain came out as treeless
-- stone peaks in the middle of birch forest (owner 2026-09-25: "there
-- are no trees on these areas"). Pass y = the column's surface height;
-- nil skips the band check.
function climate.nearest_biome(registered, names, heat, humidity, y)
	local function pick(check_y)
		local best, best_d = nil, math.huge
		for _, n in ipairs(names) do
			local def = registered[n]
			if def and def.heat_point and def.humidity_point
				and (not check_y
					or ((def.y_min or -31000) <= y
						and y <= (def.y_max or 31000) + (def.vertical_blend or 0))) then
				local dh = def.heat_point - heat
				local du = def.humidity_point - humidity
				local d = dh * dh + du * du
				-- the engine's exact rule (mg_biome.cpp
				-- BiomeGenOriginal::calcBiomeFromNoise): dist /= weight
				local wgt = def.weight
				if wgt and wgt > 0 then d = d / wgt end
				if d < best_d then best, best_d = n, d end
			end
		end
		return best
	end
	if y == nil then return pick(false) end
	return pick(true) or pick(false)
end

-- Surface stack of a Mineclonia biome def (a core.registered_biomes
-- entry) with safe fallbacks. Returns
--   { top=, depth_top=, filler=, depth_filler=, tint=, water_top= }
-- where tint is the _mcl_palette_index for grass param2 (may be nil).
-- Pass is_water=true for sea-floor columns (biome defs for _ocean
-- variants already carry sand/gravel tops; the flag only selects the
-- fallback material).
function climate.surface_of(def, is_water)
	if not def then
		return {
			top = is_water and "mcl_core:sand" or "mcl_core:dirt_with_grass",
			depth_top = 1,
			filler = is_water and "mcl_core:sand" or "mcl_core:dirt",
			depth_filler = 3,
		}
	end
	return {
		top = def.node_top or (is_water and "mcl_core:sand" or "mcl_core:dirt_with_grass"),
		depth_top = def.depth_top or 1,
		filler = def.node_filler or (is_water and "mcl_core:sand" or "mcl_core:dirt"),
		depth_filler = def.depth_filler or 3,
		tint = def._mcl_palette_index,
		water_top = def.node_water_top,
	}
end

-- ---------------------------------------------------------------------
-- Organic seam-edge noise (pure). The per-column merge weight used to
-- follow the capture outline GEOMETRICALLY (a 4-neighbour BFS distance
-- has straight Voronoi edges and triangular diagonals) -- owner
-- 2026-09-25: "very square shaped snow ... highly triangular ... it
-- looks very mathematical and uniform". Value noise on the column
-- position shifts the fade edge by a few columns in smooth ~20-block
-- blobs, which is what real biome borders look like.
local function hash2(x, z)
	local n = math.sin(x * 127.1 + z * 311.7) * 43758.5453
	return n - math.floor(n)
end

function climate.noise2(x, z, scale)
	local fx, fz = x / scale, z / scale
	local ix, iz = math.floor(fx), math.floor(fz)
	local tx, tz = fx - ix, fz - iz
	tx = tx * tx * (3 - 2 * tx)
	tz = tz * tz * (3 - 2 * tz)
	local a = hash2(ix, iz)
	local b = hash2(ix + 1, iz)
	local c = hash2(ix, iz + 1)
	local d = hash2(ix + 1, iz + 1)
	local ab = a + (b - a) * tx
	local cd = c + (d - c) * tx
	return ab + (cd - ab) * tz
end

-- Seam-edge jitter in COLUMNS (added to the BFS distance before the
-- biome/material fade is evaluated).
function climate.jitter(x, z)
	return (climate.noise2(x, z, 23) - 0.5) * 16
		+ (climate.noise2(x, z, 7) - 0.5) * 6
end

-- Surface family of a captured seam column from the REAL nodes around
-- its surface. This exists because footprints carry ONE biome name per
-- 16x16 chunk (no biome_cols) and the tag is frequently wrong for the
-- columns next to it -- minecraft:snowy_plains tags over grass+birch
-- ground produced the owner's square snow fields with trees growing
-- through them. The blocks tell the truth:
--   "snow"   frozen ground / snow layer / ice -> the seam is COLD
--   "grass"  unfrozen soil                    -> the seam is TEMPERATE
--   "sand"   bare sand                        -> the seam is WARM
--   "water"  liquid top                       -> neutral (tag decides)
--   nil      stone / builds / plain dirt      -> neutral (tag decides)
function climate.surface_family(top_name, ground_name)
	local function snowish(n)
		return n ~= nil and (n:find("snow") or n:find("ice")) ~= nil
	end
	if snowish(top_name) then return "snow" end
	if top_name and top_name:find("water") then return "water" end
	local g = ground_name
	if not g or g == "" or g == "ignore" then return nil end
	if snowish(g) then return "snow" end
	-- seagrass_*/kelp_* floors are seabed with a plant name, not soil
	if g:find("seagrass") or g:find("kelp") then
		return g:find("sand") and "sand" or nil
	end
	if g:find("grass") or g:find("podzol") or g:find("mycelium") then
		return "grass"
	end
	if g:find("sand") then return "sand" end
	return nil
end

return climate
