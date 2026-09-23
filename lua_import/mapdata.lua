-- Decodes a real Minecraft map .dat file (map_<id>.dat, gzip-compressed
-- NBT -- see gzip.lua's header comment) into a 128x128 pixel grid ready
-- for tga_encoder (Mineclonia's own mod for writing the .tga texture
-- files its `mcl_maps` system loads -- see mods/spawnimport/init.lua's
-- own comment on how this ties into mcl_maps).
--
-- Real file structure, confirmed directly against a real map_*.dat file
-- in this corpus (not assumed): a root TAG_Compound with `DataVersion`
-- and a `data` TAG_Compound holding `scale`, `dimension`, `xCenter`,
-- `zCenter`, `colors` (a 16384-entry TAG_Byte_Array, 128x128, row-major
-- as `colors[z*128 + x]`, z=0..127 outer/row, x=0..127 inner/column --
-- this indexing convention is the standard, long-stable Minecraft
-- MapItemSavedData layout, not something guessed), plus
-- `trackingPosition`/`unlimitedTracking`/`locked`/`banners`/`frames`
-- (not used here).

local _dofile = _G.__spawnimport_dofile or dofile
local function script_dir()
	local source = debug.getinfo(1, "S").source
	return source:match("^@(.*[/\\])") or "./"
end
local HERE = _G.__spawnimport_lua_import_path or script_dir()
local gzip = _dofile(HERE .. "gzip.lua")
local nbt = _dofile(HERE .. "nbt.lua")

local mapdata = {}

-- ---------------------------------------------------------------------
-- CAVEAT (read before trusting rendered colors): the 64-entry base-color
-- RGB table below is Minecraft's real `MapColor` palette, reconstructed
-- from memory/general modding-community knowledge -- it has NOT been
-- verified against a canonical Mojang source available anywhere in this
-- repo or dev environment (checked: no vendored NBT/anvil/map-art
-- library with this table was found locally). Everything ELSE in this
-- module (which .dat file, which pixel, which shade multiplier tier,
-- where the map gets placed) is real, decoded data -- only these exact
-- RGB triples are unverified. If rendered map art looks visibly wrong
-- (colors off, but the right SHAPES/edges), this table is the first
-- place to check against the Minecraft Wiki's "Map item format" page.
local BASE_COLOR_RGB = {
	[0]  = { 0, 0, 0 },       -- NONE (transparent -- handled specially, see rgb_for_index)
	[1]  = { 127, 178, 56 },  -- GRASS
	[2]  = { 247, 233, 163 }, -- SAND
	[3]  = { 199, 199, 199 }, -- WOOL / CLOTH
	[4]  = { 255, 0, 0 },     -- FIRE / TNT
	[5]  = { 160, 160, 255 }, -- ICE
	[6]  = { 167, 167, 167 }, -- METAL / IRON
	[7]  = { 0, 124, 0 },     -- PLANT
	[8]  = { 255, 255, 255 }, -- SNOW
	[9]  = { 164, 168, 184 }, -- CLAY
	[10] = { 151, 109, 77 },  -- DIRT
	[11] = { 112, 112, 112 }, -- STONE
	[12] = { 64, 64, 255 },   -- WATER
	[13] = { 143, 119, 72 },  -- WOOD
	[14] = { 255, 252, 245 }, -- QUARTZ
	[15] = { 216, 127, 51 },  -- COLOR_ORANGE
	[16] = { 178, 76, 216 },  -- COLOR_MAGENTA
	[17] = { 102, 153, 216 }, -- COLOR_LIGHT_BLUE
	[18] = { 229, 229, 51 },  -- COLOR_YELLOW
	[19] = { 127, 204, 25 },  -- COLOR_LIGHT_GREEN
	[20] = { 242, 127, 165 }, -- COLOR_PINK
	[21] = { 76, 76, 76 },    -- COLOR_GRAY
	[22] = { 153, 153, 153 }, -- COLOR_LIGHT_GRAY
	[23] = { 76, 127, 153 },  -- COLOR_CYAN
	[24] = { 127, 63, 178 },  -- COLOR_PURPLE
	[25] = { 51, 76, 178 },   -- COLOR_BLUE
	[26] = { 102, 76, 51 },   -- COLOR_BROWN
	[27] = { 102, 127, 51 },  -- COLOR_GREEN
	[28] = { 153, 51, 51 },   -- COLOR_RED
	[29] = { 25, 25, 25 },    -- COLOR_BLACK
	[30] = { 250, 238, 77 },  -- GOLD
	[31] = { 92, 219, 213 },  -- DIAMOND
	[32] = { 74, 128, 255 },  -- LAPIS
	[33] = { 0, 217, 58 },    -- EMERALD
	[34] = { 129, 86, 49 },   -- PODZOL
	[35] = { 112, 2, 0 },     -- NETHER
	[36] = { 209, 177, 161 }, -- TERRACOTTA_WHITE
	[37] = { 159, 82, 36 },   -- TERRACOTTA_ORANGE
	[38] = { 149, 87, 108 },  -- TERRACOTTA_MAGENTA
	[39] = { 112, 108, 138 }, -- TERRACOTTA_LIGHT_BLUE
	[40] = { 186, 133, 36 },  -- TERRACOTTA_YELLOW
	[41] = { 103, 117, 53 },  -- TERRACOTTA_LIGHT_GREEN
	[42] = { 160, 77, 78 },   -- TERRACOTTA_PINK
	[43] = { 57, 41, 35 },    -- TERRACOTTA_GRAY
	[44] = { 135, 107, 98 },  -- TERRACOTTA_LIGHT_GRAY
	[45] = { 87, 92, 92 },    -- TERRACOTTA_CYAN
	[46] = { 122, 73, 88 },   -- TERRACOTTA_PURPLE
	[47] = { 76, 62, 92 },    -- TERRACOTTA_BLUE
	[48] = { 76, 50, 35 },    -- TERRACOTTA_BROWN
	[49] = { 76, 82, 42 },    -- TERRACOTTA_GREEN
	[50] = { 142, 60, 46 },   -- TERRACOTTA_RED
	[51] = { 37, 22, 16 },    -- TERRACOTTA_BLACK
	[52] = { 189, 48, 49 },   -- CRIMSON_NYLIUM
	[53] = { 148, 63, 97 },   -- CRIMSON_STEM
	[54] = { 92, 25, 29 },    -- CRIMSON_HYPHAE
	[55] = { 22, 126, 134 },  -- WARPED_NYLIUM
	[56] = { 58, 142, 140 },  -- WARPED_STEM
	[57] = { 86, 44, 62 },    -- WARPED_HYPHAE
	[58] = { 20, 180, 133 },  -- WARPED_WART_BLOCK
	[59] = { 100, 100, 100 }, -- DEEPSLATE
	[60] = { 216, 175, 147 }, -- RAW_IRON
	[61] = { 127, 167, 150 }, -- GLOW_LICHEN
}

-- The four real shade tiers (index % 4), same long-stable constant this
-- session already trusts less than the RGB table above but is more
-- confident in (it's a simple, frequently-cited brightness-scaling
-- factor, not a per-color guess): 0=darkest ground level, 1=default/
-- flat, 2=brightest (one step up), 3=darkest (one step down/shadow).
local SHADE_MULTIPLIER = { [0] = 180, [1] = 220, [2] = 255, [3] = 135 }

-- Converts one raw NBT byte-array entry (a SIGNED Java byte, -128..127 --
-- confirmed against real decoded values in this corpus, e.g. -119) into
-- a plain {r,g,b} triple. Index 0 (and any base color with no table
-- entry) renders black -- tga_encoder's "A1R5G5B5" save mode (the same
-- one mcl_maps.create_map itself uses) expects a plain R8G8B8 3-tuple
-- per pixel with no real alpha channel (its "A1" bit is unconditionally
-- set to 1/opaque, confirmed by reading
-- encode_data_R8G8B8_as_A1R5G5B5_rle() directly -- it hardcodes
-- `32768 + ...` with no transparency branch at all), matching how
-- mcl_maps.create_map's own `cagg` pixel accumulator is always a bare
-- {r,g,b} table, never 4 elements.
local function rgb_for_index(raw)
	local index = raw
	if index < 0 then index = index + 256 end -- unsigned byte
	if index == 0 then
		return { 0, 0, 0 }
	end
	local base_id = math.floor(index / 4)
	local shade = index % 4
	local base = BASE_COLOR_RGB[base_id]
	if not base then
		return { 0, 0, 0 }
	end
	local mult = SHADE_MULTIPLIER[shade] / 255
	return {
		math.floor(base[1] * mult + 0.5),
		math.floor(base[2] * mult + 0.5),
		math.floor(base[3] * mult + 0.5),
	}
end
mapdata.rgb_for_index = rgb_for_index

-- Reads and decodes one map_<id>.dat file. Returns nil, err on failure
-- (missing file, wrong format, etc.) rather than throwing -- a base with
-- a map referencing a missing/corrupt .dat file shouldn't abort the
-- whole import.
--
-- Returns { pixels = <128x128 grid, pixels[z][x] = {r,g,b}, z,x 1..128
-- matching tga_encoder's row/col convention>, scale=, dimension=,
-- x_center=, z_center= }.
function mapdata.decode_file(path)
	local f, err = io.open(path, "rb")
	if not f then return nil, err end
	local raw = f:read("*a")
	f:close()
	if not raw or #raw == 0 then return nil, "empty file" end

	local ok, decompressed = pcall(gzip.decompress, raw)
	if not ok then return nil, "gzip decompress failed: " .. tostring(decompressed) end

	local ok2, root = pcall(nbt.parse_buffer, decompressed)
	if not ok2 then return nil, "NBT parse failed: " .. tostring(root) end

	local d = root.data
	if not d or not d.colors or #d.colors < 16384 then
		return nil, "missing or short 'data.colors' array"
	end

	-- Owner explicit 2026-09-18 round 7 (live report): map art rendered
	-- upside down -- text and images inverted, and adjacent maps in a
	-- multi-map wall gallery looked vertically swapped (a real seam
	-- mismatch, since each map's own content was itself flipped).
	-- Root cause, confirmed by reading tga_encoder/init.lua directly:
	-- it writes `self.pixels` in `ipairs()` order with NO image-
	-- descriptor orientation byte set at all (grepped for it, not
	-- present) -- TGA's default (unset) orientation is origin-at-
	-- bottom-left, meaning the FIRST row written to the file is the
	-- BOTTOM of the displayed image. `colors[z*128+x]` is row-major
	-- with z=0 the NORTHERNMOST row (real Minecraft's stable
	-- MapItemSavedData layout, not itself in question) -- so building
	-- `pixels[z+1]` directly (z=0 first) put the northernmost row into
	-- the file first, which tga_encoder's bottom-up convention then
	-- rendered at the BOTTOM of the image and the southernmost row at
	-- the TOP: north-south flipped, every map, every pixel. Reversed
	-- here (`pixels[128-z]`) so the southernmost data row is written
	-- first (renders at the bottom) and the northernmost row last
	-- (renders at the top) -- real north-up map orientation.
	--
	-- 2026-09-23: the EAST-WEST axis is flipped too. Mineclonia renders
	-- maps in item frames as an upright_sprite whose texture left edge
	-- lands on the wall's +x/-z convention per facing -- combined with
	-- the item-frame entity's dir_to_rotation, the map's west ended up on
	-- the RIGHT for wall-mounted frames. Reversed the x here
	-- (`row[128-x]`) so x=0 (Minecraft's WEST) renders on the left again.
	local pixels = {}
	for z = 0, 127 do
		local row = {}
		for x = 0, 127 do
			row[128 - x] = rgb_for_index(d.colors[z * 128 + x + 1])
		end
		pixels[128 - z] = row
	end

	return {
		pixels = pixels,
		scale = tonumber(d.scale) or 0,
		dimension = d.dimension or "minecraft:overworld",
		x_center = tonumber(d.xCenter) or 0,
		z_center = tonumber(d.zCenter) or 0,
	}
end

return mapdata
