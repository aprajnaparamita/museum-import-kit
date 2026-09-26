-- Anvil region/chunk reader, ported from spawnmasons/import_tools/anvil.py.
-- See spawnmasons/IMPORT_SPEC.md for the format this targets (1.18+
-- 'sections' chunk layout, padded bit-packing -- confirmed against real
-- capture bytes, not assumed).
--
-- Every external dependency is injected rather than hardcoded, so this
-- file works two ways with zero edits:
--   * inside a trusted Luanti server mod, where `core` is a global and
--     `anvil.decompress`/`anvil.list_dir` auto-wire to core.decompress /
--     core.get_dir_list below;
--   * standalone under plain `lua5.1` or `luajit`, where a test harness
--     sets anvil.decompress/anvil.list_dir itself (see
--     mods/spawnimport/test_harness.lua, which uses real libz via
--     lua_import/gzip.lua's LuaJIT FFI so the standalone tests exercise
--     real decompression, not a fake stub).
-- `anvil.read_file` defaults to plain io.open either way -- Luanti has no
-- sandboxed API for reading an arbitrary absolute path (this project's
-- source data lives outside any world/mod directory), so the server mod
-- that uses this module needs to run trusted/with security disabled
-- regardless; see IMPORT_SPEC.md's "Lua port" note.

-- debug.getinfo is unavailable in a sandboxed Luanti mod environment (not
-- in the whitelisted debug functions), so this is only reachable/needed
-- standalone (test harnesses) or with security disabled -- when spawnimport
-- loads this file it pre-sets _G.__spawnimport_lua_import_path, which
-- short-circuits this via `or` before script_dir() ever gets called.
local function script_dir()
	local source = debug.getinfo(1, "S").source
	return source:match("^@(.*[/\\])") or "./"
end

local _dofile = _G.__spawnimport_dofile or dofile
local nbt = _dofile((_G.__spawnimport_lua_import_path or script_dir()) .. "nbt.lua")
local legacy = _dofile((_G.__spawnimport_lua_import_path or script_dir()) .. "legacy.lua")

local anvil = {}
anvil.script_dir = script_dir

local byte = string.byte
local sub = string.sub
local bit = bit or require("bit")

local SECTOR_SIZE = 4096
local SECTION_EDGE = 16
local BLOCKS_PER_SECTION = SECTION_EDGE ^ 3 -- 4096

local AIR_NAMES = {
	["minecraft:air"] = true,
	["minecraft:cave_air"] = true,
	["minecraft:void_air"] = true,
}

-- ---------------------------------------------------------------------
-- Injectable environment
-- ---------------------------------------------------------------------

-- Retries a couple of times on failure: this project's source data lives
-- on an external/network volume that has been observed to blip on large
-- (multi-MB) reads under load (see step 3's notes in IMPORT_SPEC.md) --
-- worth a cheap retry here rather than aborting a multi-minute import over
-- a transient hiccup.
function anvil.default_read_file(path)
	local open_fn = (_G.__spawnimport_io and _G.__spawnimport_io.open) or io.open
	local last_err
	for attempt = 1, 3 do
		local f, err = open_fn(path, "rb")
		if f then
			local data = f:read("*a")
			f:close()
			if data then return data end
			last_err = "read returned no data"
		else
			last_err = err
		end
	end
	return nil, last_err
end
anvil.read_file = anvil.default_read_file

if core and core.decompress then
	anvil.decompress = function(data) return core.decompress(data, "deflate") end
end
if core and core.get_dir_list then
	anvil.list_dir = function(dir) return core.get_dir_list(dir, false) end
end

-- ---------------------------------------------------------------------
-- Region file container format
-- ---------------------------------------------------------------------

function anvil.region_coords_from_filename(path)
	local base = path:match("([^/\\]+)$") or path
	local rx, rz = base:match("^r%.(%-?%d+)%.(%-?%d+)%.mca$")
	if not rx then
		error("not a region filename: " .. tostring(base))
	end
	return tonumber(rx), tonumber(rz)
end

-- Returns an array of {local_x, local_z, offset (sectors), count (sectors)}
-- for present chunks only, from a whole region file's raw bytes.
function anvil.read_region_locations(data)
	local locations = {}
	-- 2026-09-20 (round 27, real crash hit at scale): a truncated/empty
	-- .mca file (0 bytes, confirmed live -- several files in "The 2b2t
	-- museum" WDL capture) has no location table at all. byte() returns
	-- nil past the end of the string, crashing the arithmetic below with
	-- "attempt to perform arithmetic on a nil value". A valid region
	-- file's location table is always exactly 4096 bytes (1024 entries *
	-- 4 bytes) -- treat anything shorter as "no chunks present" instead
	-- of crashing, since that's the only sane interpretation of a
	-- corrupt/truncated region file.
	if #data < 4096 then
		return locations
	end
	for i = 0, 1023 do
		local base = i * 4 + 1
		local b1, b2, b3, b4 = byte(data, base, base + 3)
		local offset = (b1 * 256 + b2) * 256 + b3
		local count = b4
		if not (offset == 0 and count == 0) then
			locations[#locations + 1] = {
				local_x = i % 32,
				local_z = math.floor(i / 32),
				offset = offset,
				count = count,
			}
		end
	end
	return locations
end

function anvil.read_chunk_payload(data, offset_sectors)
	local start = offset_sectors * SECTOR_SIZE + 1
	local b1, b2, b3, b4, comp = byte(data, start, start + 4)
	local length = ((b1 * 256 + b2) * 256 + b3) * 256 + b4
	local body_start = start + 5
	local body = sub(data, body_start, body_start + (length - 1) - 1)

	if comp >= 128 then
		error(string.format(
			"chunk stored in external .mcc file (compression byte 0x%02x) -- not implemented",
			comp))
	end
	if comp == 1 then
		error("gzip-compressed chunk -- core.decompress only supports zlib ('deflate') and zstd, not gzip")
	elseif comp == 2 then
		if not anvil.decompress then
			error("anvil.decompress is not set -- inside a mod this needs `core`; standalone, set it from a test harness")
		end
		return anvil.decompress(body)
	elseif comp == 3 then
		return body
	else
		error("unknown chunk compression type " .. tostring(comp))
	end
end

-- Yields via callback(chunk_x, chunk_z, chunk_table) for every present
-- chunk in one region file (absolute chunk coordinates).
function anvil.iter_region_chunks(region_path, callback)
	local data, err = anvil.read_file(region_path)
	if not data then
		error("could not read region file " .. region_path .. ": " .. tostring(err))
	end
	local region_x, region_z = anvil.region_coords_from_filename(region_path)
	local locations = anvil.read_region_locations(data)
	for _, loc in ipairs(locations) do
		local payload = anvil.read_chunk_payload(data, loc.offset)
		local chunk = nbt.parse_buffer(payload)
		local chunk_x = region_x * 32 + loc.local_x
		local chunk_z = region_z * 32 + loc.local_z
		callback(chunk_x, chunk_z, chunk)
	end
end

-- ---------------------------------------------------------------------
-- Bit-packed block_states.data decoding
-- ---------------------------------------------------------------------

local function bits_for_palette(n)
	if n <= 1 then return 0 end
	local bits = 0
	while (2 ^ bits) < n do
		bits = bits + 1
	end
	if bits < 4 then bits = 4 end
	return bits
end
anvil.bits_for_palette = bits_for_palette

-- longs: array of {hi=,lo=} pairs (see nbt.lua's TAG_Long_Array reader).
-- Confirmed PADDED scheme (see IMPORT_SPEC.md): each 64-bit long holds
-- floor(64/bits) values; a value never straddles a long boundary, but it
-- can straddle this function's internal hi/lo 32-bit split, which is just
-- an artifact of representing each long as two Lua numbers.
local function unpack_indices(longs, bits, count)
	local out = {}
	if bits == 0 then
		for i = 1, count do out[i] = 0 end
		return out
	end
	local mask = bit.lshift(1, bits) - 1
	local vals_per_long = math.floor(64 / bits)
	for i = 0, count - 1 do
		local long_index = math.floor(i / vals_per_long) + 1
		local slot = i % vals_per_long
		local bit_offset = slot * bits
		local pair = longs[long_index]
		local value
		if bit_offset + bits <= 32 then
			value = bit.band(bit.rshift(pair.lo, bit_offset), mask)
		elseif bit_offset >= 32 then
			value = bit.band(bit.rshift(pair.hi, bit_offset - 32), mask)
		else
			local low_bits = 32 - bit_offset
			local low_part = bit.band(bit.rshift(pair.lo, bit_offset), bit.lshift(1, low_bits) - 1)
			local high_bits = bits - low_bits
			local high_part = bit.band(pair.hi, bit.lshift(1, high_bits) - 1)
			value = low_part + bit.lshift(high_part, low_bits)
		end
		out[i + 1] = value
	end
	return out
end
anvil.unpack_indices = unpack_indices

-- Calls callback(local_x, local_y, local_z, name, properties) for every
-- non-air block in one 16x16x16 section compound (local coords 0..15).
local function decode_section_blocks(section, callback)
	local block_states = section.block_states
	if not block_states then return end
	local palette = block_states.palette
	if not palette or #palette == 0 then return end

	if #palette == 1 then
		local name = palette[1].Name or "minecraft:air"
		if AIR_NAMES[name] then return end
		local props = palette[1].Properties or {}
		for i = 0, BLOCKS_PER_SECTION - 1 do
			local y = math.floor(i / 256)
			local rem = i % 256
			local z = math.floor(rem / 16)
			local x = rem % 16
			callback(x, y, z, name, props)
		end
		return
	end

	local data = block_states.data
	if not data then
		error(string.format("section has %d-entry palette but no 'data' array", #palette))
	end
	local bits = bits_for_palette(#palette)
	local indices = unpack_indices(data, bits, BLOCKS_PER_SECTION)
	for i = 0, BLOCKS_PER_SECTION - 1 do
		local idx = indices[i + 1]
		local entry = palette[idx + 1] -- palette is 1-indexed in Lua, idx is 0-based
		if not entry then
			error(string.format("palette index %d out of range (palette size %d)", idx, #palette))
		end
		local name = entry.Name or "minecraft:air"
		if not AIR_NAMES[name] then
			local y = math.floor(i / 256)
			local rem = i % 256
			local z = math.floor(rem / 16)
			local x = rem % 16
			callback(x, y, z, name, entry.Properties or {})
		end
	end
end
anvil.decode_section_blocks = decode_section_blocks

-- Decodes a 1.18+ section's biome palette+data into a 4x4x4 grid.
-- Calls callback(x, y, z, biome_name) for each of the 64 quart-positions
-- (x,z,y each 0..3 within the section). Biome palettes are TAG_String
-- lists (unlike block_states' compound palette), packed the same way but
-- with a minimum of 1 bit per entry instead of 4.
local function decode_section_biomes(section, callback)
	local biomes = section.biomes
	if not biomes then return end
	local palette = biomes.palette
	local data = biomes.data
	if not palette or not data or #palette == 0 then return end
	local bits = 0
	while (2 ^ bits) < #palette do
		bits = bits + 1
	end
	if bits < 1 then bits = 1 end
	local indices = unpack_indices(data, bits, 64)
	for i = 0, 63 do
		local name = palette[indices[i + 1] + 1]
		if not name then
			error(string.format("biome palette index %d out of range (palette size %d)", indices[i + 1], #palette))
		end
		local y = math.floor(i / 16)
		local rem = i % 16
		local z = math.floor(rem / 4)
		local x = rem % 4
		callback(x, y, z, name)
	end
end
anvil.decode_section_biomes = decode_section_biomes

-- Calls callback(world_x, world_y, world_z, name, properties) for every
-- non-air block in a chunk table (as returned by nbt.parse_buffer via
-- iter_region_chunks). Errors clearly for pre-1.18 chunks instead of
-- misparsing them (see IMPORT_SPEC.md).
-- Legacy (pre-1.18, e.g. the 1.12 Nether captures) chunks keep
-- everything one level down under `Level` -- lift the fields the other
-- decoders read so the sign/frame/mob paths work unchanged. Idempotent.
function anvil.normalize_chunk(chunk)
	local lvl = chunk.Level
	if not lvl then return chunk end
	chunk.xPos = chunk.xPos or lvl.xPos
	chunk.zPos = chunk.zPos or lvl.zPos
	chunk.Entities = chunk.Entities or lvl.Entities
	chunk.block_entities = chunk.block_entities or lvl.TileEntities
	return chunk
end

function anvil.decode_chunk_blocks(chunk, callback)
	anvil.normalize_chunk(chunk)
	local chunk_x, chunk_z = chunk.xPos, chunk.zPos
	if not chunk_x or not chunk_z then
		error("chunk missing xPos/zPos")
	end
	if chunk.Level then
		-- 1.12 format: per-section Blocks byte array + Data nibbles,
		-- numeric ids -> names via legacy.lua (2026-09-25: the museum's
		-- only Nether captures are 1.12 WDLs and the owner asked for a
		-- Nether base in the test world)
		local base_x, base_z = chunk_x * SECTION_EDGE, chunk_z * SECTION_EDGE
		local warned = {}
		for _, section in ipairs(chunk.Level.Sections or {}) do
			local blocks = section.Blocks
			if blocks and section.Y then
				local base_y = section.Y * SECTION_EDGE
				local data = section.Data
				for i = 0, 4095 do
					local id = blocks[i + 1] or 0
					if id ~= 0 then
						if id < 0 then id = id + 256 end
						local meta = 0
						if data and #data > 0 then
							local b = data[math.floor(i / 2) + 1] or 0
							if b < 0 then b = b + 256 end
							meta = (i % 2 == 0) and (b % 16) or (math.floor(b / 16) % 16)
						end
						local name, props = legacy.block(id, meta)
						if not name then
							name = "minecraft:stone"
							if not warned[id] then
								warned[id] = true
								core.log("warning", string.format(
									"[anvil] legacy block id %d meta %d unmapped -- using stone", id, meta))
							end
						end
						local lx = i % 16
						local lz = math.floor(i / 16) % 16
						local ly = math.floor(i / 256)
						callback(base_x + lx, base_y + ly, base_z + lz, name, props)
					end
				end
			end
		end
		return
	end
	if not chunk.sections then
		error(string.format(
			"chunk has no 'sections' tag (DataVersion=%s) and no legacy 'Level' wrapper",
			tostring(chunk.DataVersion)))
	end
	local base_x = chunk_x * SECTION_EDGE
	local base_z = chunk_z * SECTION_EDGE
	for _, section in ipairs(chunk.sections) do
		local section_y = section.Y
		if section_y then
			local base_y = section_y * SECTION_EDGE
			decode_section_blocks(section, function(lx, ly, lz, name, props)
				callback(base_x + lx, base_y + ly, base_z + lz, name, props)
			end)
		end
	end
end

-- Injectable, same pattern as anvil.decompress/anvil.list_dir above --
-- core.parse_json only exists inside the real engine. Standalone contexts
-- (tests) that never set this just fall back to treating any string-typed
-- sign message as literal text, skipping JSON-string decoding only (the
-- native-NBT-compound message format below doesn't need this at all).
anvil.parse_json = (_G.core and core.parse_json) or nil

-- Extracts plain text from a Minecraft text component, which shows up in
-- two different real shapes in this repo's captures depending on
-- DataVersion (confirmed against actual chunk data, not assumed):
--   - pre-1.20.5: a TAG_String holding a JSON-encoded component, e.g.
--     '{"text":"Hello","extra":[...]}' or a bare '""'.
--   - 1.20.5+: the component stored as native NBT (TAG_Compound/TAG_List)
--     instead of a JSON string -- same shape, just already-parsed.
-- Recurses through "extra" (a list of child components, same recursive
-- shape) same as vanilla text component semantics; ignores
-- color/formatting/click-event fields since Mineclonia signs only take
-- plain text.
local function extract_text_component(value)
	if value == nil then
		return ""
	end
	if type(value) == "string" then
		local first = value:sub(1, 1)
		-- A JSON text component can be an object, an array, OR a bare JSON
		-- string -- and the bare-string form is what these captures
		-- actually use most: front_text.messages comes through as
		-- {'"Cactus"', '"Farm"', '""', '""'}, i.e. every line is
		-- JSON-encoded, and empty lines are the two-character string `""`.
		-- Only checking for { and [ meant every sign rendered with literal
		-- quote marks around it and blank lines showed as "" (seen
		-- in-client).
		if first == "{" or first == "[" or first == '"' then
			if anvil.parse_json then
				local ok, parsed = pcall(anvil.parse_json, value, nil, true)
				if ok and parsed ~= nil then
					-- Return an already-decoded string as-is rather than
					-- recursing: re-decoding would strip a second layer of
					-- quotes off a sign whose text legitimately contains
					-- them.
					if type(parsed) == "string" then
						return parsed
					end
					return extract_text_component(parsed)
				end
			end
			if first == '"' then
				-- No JSON decoder available (standalone tests), or the
				-- decoder rejected a bare top-level string. Unwrap it by
				-- hand -- still better than showing the quotes.
				if #value >= 2 and value:sub(-1) == '"' then
					local inner = value:sub(2, -2)
					inner = inner:gsub('\\"', '"'):gsub("\\\\", "\\"):gsub("\\n", "\n")
					return inner
				end
				return value
			end
			return "" -- couldn't decode and it's not literal text either
		end
		return value
	end
	if type(value) == "table" then
		-- A bare list of components (the "extra" shape, or occasionally
		-- the whole message itself).
		if value[1] ~= nil or next(value) == nil then
			local out = {}
			for _, child in ipairs(value) do
				out[#out + 1] = extract_text_component(child)
			end
			return table.concat(out)
		end
		-- A single component compound: {text=..., extra={...}, ...}.
		local out = extract_text_component(value.text)
		if value.extra then
			out = out .. extract_text_component(value.extra)
		end
		return out
	end
	return ""
end

-- Returns a list of {x=, y=, z=, text=} for every sign in a chunk's
-- block_entities (front side only -- Mineclonia's sign model, see
-- mcl_signs/init.lua's single "utext" meta field, has no concept of a
-- separate back side, a newer vanilla feature). text is the sign's lines
-- joined with "\n", trimmed of trailing empty lines. Handles both the
-- pre-1.20.5 flat Text1..Text4 fields and the modern front_text.messages
-- shape (see extract_text_component's comment for why both exist).
function anvil.decode_chunk_signs(chunk)
	anvil.normalize_chunk(chunk)
	local out = {}
	for _, be in ipairs(chunk.block_entities or {}) do
		local id = be.id
		if id == "minecraft:sign" or id == "minecraft:hanging_sign" then
			local lines = {}
			if be.front_text and be.front_text.messages then
				for i, msg in ipairs(be.front_text.messages) do
					lines[i] = extract_text_component(msg)
				end
			else
				for i = 1, 4 do
					lines[i] = extract_text_component(be["Text" .. i])
				end
			end
			while #lines > 0 and lines[#lines] == "" do
				lines[#lines] = nil
			end
			if #lines > 0 then
				out[#out + 1] = { x = be.x, y = be.y, z = be.z, text = table.concat(lines, "\n") }
			end
		end
	end
	return out
end

-- Decode mob spawners (block entities): returns a list of
--   { x=, y=, z=, mob=<raw SpawnData id string or nil> }
-- for every minecraft:mob_spawner / legacy MobSpawner tile entity.
-- The SpawnData id shape varies by era: 1.12 keeps {id="Blaze"}, modern
-- keeps {entity={id="minecraft:blaze"}} -- both are returned raw; the
-- caller normalizes. Placement note: VoxelManip-written spawners never
-- run on_construct, so mcl_mobspawners.setup_spawner must be called by
-- the importer (Mineclonia's own requirement, see
-- mods/ITEMS/mcl_mobspawners/init.lua's register_node comment).
function anvil.decode_chunk_spawners(chunk)
	anvil.normalize_chunk(chunk)
	local out = {}
	for _, be in ipairs(chunk.block_entities or {}) do
		local id = be.id
		if id == "minecraft:mob_spawner" or id == "MobSpawner" then
			local mob = nil
			local sd = be.SpawnData
			if type(sd) == "table" then
				mob = sd.id or (type(sd.entity) == "table" and sd.entity.id) or nil
			end
			out[#out + 1] = { x = be.x, y = be.y, z = be.z, mob = mob }
		end
	end
	return out
end

-- Decode item frames from both block-entity form (post-1.14 captures) and
-- entity form (older saves; also WorldTools-style captures of any era).
-- Returns a list of:
--   { x=, y=, z=, itemstring=, glow=bool, item_rotation=0..15,
--     map_id=nil|integer, pos_source="block"|"entity" }
--
-- The itemstring is the raw `minecraft:*` ID from the source. Translation
-- to a Mineclonia itemstring happens in the importer mod (see
-- mods/spawnimport/init.lua's resolve_item) because that depends on which
-- mods are loaded in the running game.
--
-- Both forms are returned in the same shape so the importer can place them
-- uniformly. For block entities, position is the air cell at the block edge
-- the frame is mounted on (frame mounts on a face, not the inside of the
-- block). For entities, the entity's `Pos` field is its centre; we floor
-- it to the block the frame fills.
--
-- Empty frames are preserved: their `itemstring` is the empty string.
--
-- 2026-09-18 round 6 (real, previously-undiscovered bug fix): the
-- entity-form loop below read `chunk.entities` (lowercase) -- but real
-- entity data, decoded from a real `entities/*.mca` region file (a
-- separate directory Minecraft 1.17+ splits entity data into, sibling to
-- `region/`), lives at the chunk root as `Entities` (capital E) --
-- confirmed directly against real capture bytes via a standalone probe
-- (`anvil.iter_region_chunks` on a real `entities/r.*.mca` file, dumping
-- `pairs(chunk)`). Since nothing in this pipeline ever read an
-- `entities/*.mca` file at all until this round, `chunk.entities` was
-- ALWAYS nil/empty regardless -- meaning the entity-form item-frame path
-- (the only one that ever fires for real vanilla Minecraft data, since
-- item frames are never actually block-entities there either) has never
-- once produced output. See mods/spawnimport/init.lua's own comment on
-- where `entities/*.mca` is now actually read from.
-- Real bug found and fixed 2026-09-19 (round 21, cutecurly's City):
-- `item.tag.map` is the PRE-1.20.5 NBT shape. Minecraft 1.20.5 replaced
-- per-item `tag` NBT with a `components` map -- confirmed directly
-- against real capture bytes for this base (its Item table has NO `tag`
-- key at all, only `components = { ["minecraft:map_id"] = 19,
-- ["minecraft:custom_data"] = { map = 19, display = {...}, ... }, ... }`
-- -- likely captured post-conversion via a version-bridging proxy mod,
-- since one of the custom_data keys is literally
-- "VV|Protocol1_20_3To1_20_5"). Every one of this base's 58 real
-- filled_map item frames silently produced `map_id = nil` because of
-- this alone -- `f.map_id and mapdata` in the importer then never even
-- calls render_map_art, and the frame ends up holding a bare, meta-less
-- "mcl_maps:filled_map" ItemStack that mcl_itemframes can't texture
-- (falls back to showing the item's generic wield mesh instead -- the
-- literal "shows a map item object rather than the map" bug report).
-- Checks BOTH shapes now, new format first (the newer/authoritative
-- one when present), falling back to the legacy `tag.map` path so
-- Fort Alcazar/Tactical Nuke's older-format captures keep working
-- unchanged.
local function extract_map_id(item)
	if item.components then
		local direct = item.components["minecraft:map_id"]
		if direct ~= nil then return tonumber(direct) end
		local custom_data = item.components["minecraft:custom_data"]
		if custom_data and custom_data.map ~= nil then
			return tonumber(custom_data.map)
		end
	end
	if item.tag and item.tag.map ~= nil then
		return tonumber(item.tag.map)
	end
	return nil
end

-- Real 2b2t/community mapart walls are very often built and NAMED by the
-- original player with the tile's own row/col baked into the map's
-- display name (confirmed directly against real capture data for
-- cutecurly's City: a real map's components.custom_data.display.Name is
-- `{"text":"Baroness (Purple) 1-3 - AndresFlames"}` -- "1-3" is that
-- tile's own row-column position in its source wall, not decorative).
-- Extracted here (best-effort regex over a trailing "N-M" or "N,M"
-- token) so importer/gallery-fix code can use it as real, author-
-- supplied ground truth for tile order instead of guessing or relying
-- on id-ordering coincidences (see mods/spawnimport/init.lua's
-- render_map_art and HANDOFF.md's round 20 write-up on the Fort Alcazar
-- ceiling grid, where no such signal was available and the fix had to
-- fall back to an unverified default orientation).
local function extract_map_display_name(item)
	if item.components then
		local custom_name = item.components["minecraft:custom_name"]
		if type(custom_name) == "string" then return custom_name end
		local custom_data = item.components["minecraft:custom_data"]
		if custom_data and custom_data.display and custom_data.display.Name then
			local ok, decoded = pcall(function()
				return custom_data.display.Name:match('"text":"(.-)"')
			end)
			if ok and decoded then return decoded end
			return custom_data.display.Name
		end
	end
	if item.tag and item.tag.display and item.tag.display.Name then
		return item.tag.display.Name
	end
	return nil
end
anvil.extract_map_display_name = extract_map_display_name

function anvil.decode_chunk_item_frames(chunk)
	anvil.normalize_chunk(chunk)
	local out = {}

	-- Post-1.14: item frames are block entities. NOTE: real vanilla
	-- Minecraft never actually stores item frames this way (they're
	-- always entities) -- this branch is kept for defensiveness/parity
	-- with the comment history, but has not been observed to fire
	-- against any real capture in this corpus.
	for _, be in ipairs(chunk.block_entities or {}) do
		local id = be.id
		if id == "minecraft:item_frame" or id == "minecraft:glow_item_frame" then
			local item = be.Item
			local itemstring, map_id, map_display_name = nil, nil, nil
			if item and type(item) == "table" then
				itemstring = item.id
				if itemstring == "minecraft:filled_map" then
					map_id = extract_map_id(item)
					map_display_name = extract_map_display_name(item)
				end
			end
			out[#out + 1] = {
				x = be.x,
				y = be.y,
				z = be.z,
				itemstring = itemstring,
				map_id = map_id,
				map_display_name = map_display_name,
				glow = id == "minecraft:glow_item_frame",
				-- Block-entity form has ItemRotation for the held item's
				-- rotation (0..15 octants). Player-time changes (tag
				-- "Invisible" etc.) are deliberately ignored.
				item_rotation = tonumber(be.ItemRotation) or 0,
				pos_source = "block",
			}
		end
	end

	-- Real form: item frames are entities, decoded from `entities/*.mca`.
	-- Their `Pos` is the entity's centre; the frame occupies a block
	-- adjacent to its support wall. `Facing` controls which face of that
	-- support block the frame is mounted on; 1..5 are walls, 0 is floor,
	-- 6+ are some bug we don't model. Item is in `.Item` like above.
	for _, ent in ipairs(chunk.Entities or {}) do
		local id = ent.id
		if id == "minecraft:item_frame" or id == "minecraft:glow_item_frame" then
			local pos = ent.Pos
			if not pos or not pos[1] or not pos[2] or not pos[3] then
				-- No position -- skip. (Defensive: missing pos on entity.)
			else
				local item = ent.Item
				local itemstring, map_id, map_display_name = nil, nil, nil
				if item and type(item) == "table" then
					itemstring = item.id
					-- Confirmed real shape against actual capture bytes:
					-- Item = { id = "minecraft:filled_map", Count = 1,
					--          tag = { map = <integer id> } } (pre-1.20.5)
					--          OR components = { ["minecraft:map_id"] =
					--          <integer id>, ... } (1.20.5+ -- see
					--          extract_map_id's own comment above, found
					--          via cutecurly's City's real capture data).
					-- This id indexes a separate per-map file,
					-- "data/map_<id>.dat" in the same WDL capture folder
					-- (gzip-compressed NBT, holds the real 128x128
					-- pixel-color byte array) -- see mapdata.lua.
					if itemstring == "minecraft:filled_map" then
						map_id = extract_map_id(item)
						map_display_name = extract_map_display_name(item)
					end
				end
				out[#out + 1] = {
					-- Floor the entity centre to get the block the frame
					-- fills. The actual mount direction depends on
					-- `Facing`, but the block that "is this frame" is
					-- the floor of pos. Good enough -- Mineclonia item
					-- frames snap to the nearest solid and render from
					-- that neighbour, so off-by-one in x/z collapses at
					-- re-paint time.
					x = math.floor(pos[1]),
					y = math.floor(pos[2]),
					z = math.floor(pos[3]),
					itemstring = itemstring,
					map_id = map_id,
					map_display_name = map_display_name,
					glow = id == "minecraft:glow_item_frame",
					item_rotation = tonumber(ent.ItemRotation) or 0,
					-- Vanilla Facing 1..5 = wall; 0 = ceiling-attached but
					-- commonly used; we don't translate it precisely to
					-- Mineclonia wallmounted here (see importer for that)
					-- but we carry it so the importer can pick a sensible
					-- default.
					facing = tonumber(ent.Facing),
					pos_source = "entity",
				}
			end
		end
	end

	return out
end

-- Decode paintings (entity form only -- paintings were never block entities).
-- Returns a list of:
--   { x=, y=, z=, motive=, facing=, direction=, pos_source="entity" }
--   `motive` is the painting's variant string (e.g. "minecraft:skeleton"),
--   the same shape the modern `variant` field uses post-1.20, with a
--   fallback to the older `Motive` field name for older captures.
--
-- Same `chunk.entities` -> `chunk.Entities` fix as decode_chunk_item_frames
-- above (round 6). NOTE: spot-checked a real painting entity in this
-- corpus and found it has NEITHER `motive`/`Motive` NOR `facing`/
-- `direction`/`Facing`/`Direction` at all (just UUID/Pos/Rotation/Motion)
-- -- an older-format capture that simply didn't preserve which piece of
-- art or which wall it was on. Not wired into spawnimport's placement
-- logic this round for exactly that reason: with no motive AND no facing,
-- there's nothing real to place (see HANDOFF.md).
function anvil.decode_chunk_paintings(chunk)
	local out = {}
	for _, ent in ipairs(chunk.Entities or {}) do
		if ent.id == "minecraft:painting" then
			local pos = ent.Pos
			if pos and pos[1] and pos[2] and pos[3] then
				out[#out + 1] = {
					x = pos[1],
					y = pos[2],
					z = pos[3],
					motive = ent.variant or ent.Motive,
					-- 1.20+ uses `facing` (the side of the block it
					-- attaches to). Pre-1.20 used `facing` too, with
					-- slightly different values; we carry both.
					facing = tonumber(ent.facing) or tonumber(ent.Facing),
					direction = tonumber(ent.direction) or tonumber(ent.Direction),
					pos_source = "entity",
				}
			end
		end
	end
	return out
end

-- Decode mob-like entities from a chunk's real Entities list (see
-- decode_chunk_item_frames' header comment for the chunk.Entities vs
-- chunk.entities story -- same underlying fix applies here). Returns
-- EVERY entity that looks mob-shaped (has a real Pos), not just
-- known-mob ones -- deciding which vanilla ids map to a real Mineclonia
-- mob and spawning it happens in the importer (mods/spawnimport/
-- init.lua), same division of responsibility decode_chunk_item_frames
-- already uses for itemstring translation, since that depends on which
-- mods are loaded in the running game. Non-mob entities (dropped items,
-- boats, minecarts, XP orbs, falling blocks, firework rockets, arrows,
-- etc.) are still returned here -- filtering those out is also the
-- importer's job, so this stays a thin, honest passthrough of what's
-- really in the capture rather than silently deciding what counts as a
-- "mob."
--
-- Returns a list of:
--   { x=, y=, z=, yaw_deg=, mc_id=, health=, profession=(villager/
--     wandering_trader only, e.g. "minecraft:farmer", or nil),
--     villager_level=, size=(slime/magma_cube only, integer or nil),
--     powered=(creeper only, bool -- best-effort, see note below),
--     baby=bool }
--
-- `yaw_deg` is the raw vanilla Rotation[1] value (Minecraft convention:
-- 0=south/+Z, increasing clockwise looking from above) -- converting to
-- Luanti's yaw convention is the importer's job, same reasoning as
-- everything else translated there.
--
-- `powered` (creeper charged state): the real NBT field name for this
-- is `powered` (byte 0/1) per the stable, long-documented Minecraft save
-- format -- NOT independently verified against a real charged-creeper
-- sample in this corpus (none happened to be found while building this),
-- flagged here rather than silently presented as confirmed.
function anvil.decode_chunk_mobs(chunk)
	anvil.normalize_chunk(chunk)
	local out = {}
	for _, ent in ipairs(chunk.Entities or {}) do
		local pos = ent.Pos
		if pos and pos[1] and pos[2] and pos[3] and ent.id then
			local rot = ent.Rotation
			out[#out + 1] = {
				x = pos[1], y = pos[2], z = pos[3],
				yaw_deg = rot and tonumber(rot[1]) or 0,
				mc_id = ent.id,
				health = tonumber(ent.Health),
				profession = ent.VillagerData and ent.VillagerData.profession,
				villager_level = ent.VillagerData and tonumber(ent.VillagerData.level),
				size = tonumber(ent.Size),
				powered = ent.powered == 1 or ent.powered == true,
				baby = (tonumber(ent.Age) or 0) < 0,
			}
		end
	end
	return out
end

-- ---------------------------------------------------------------------
-- WorldTools folder helpers
-- ---------------------------------------------------------------------

function anvil.region_dir(world_folder, dimension_path)
	return world_folder .. "/dimensions/minecraft/worlds/" .. dimension_path .. "/region"
end

function anvil.list_region_files(dir)
	if not anvil.list_dir then
		error("anvil.list_dir is not set -- inside a mod this needs `core`; standalone, set it from a test harness")
	end
	local entries = anvil.list_dir(dir)
	local files = {}
	for _, name in ipairs(entries) do
		if name:match("^r%.%-?%d+%.%-?%d+%.mca$") then
			files[#files + 1] = dir .. "/" .. name
		end
	end
	table.sort(files)
	return files
end

-- Cheap: only reads region location tables (no decompression, no NBT
-- parsing) to report which chunks exist and the resulting bounding box.
-- Returns nil if the dimension has no chunks at all. Split out from
-- read_region_extent() so a caller that already has an absolute region
-- directory (e.g. a pre-resolved WorldTools/vanilla-layout path from a
-- survey pass, see server_mod/spawnimport's region_dir_override) doesn't
-- need a world_folder/dimension_path pair reconstructed back into one.
function anvil.read_region_extent_from_dir(dir)
	local files = anvil.list_region_files(dir)
	local chunk_count = 0
	local x_min, x_max, z_min, z_max
	for _, fpath in ipairs(files) do
		local data, err = anvil.read_file(fpath)
		if not data then
			error("could not read region file " .. fpath .. ": " .. tostring(err))
		end
		local region_x, region_z = anvil.region_coords_from_filename(fpath)
		local locations = anvil.read_region_locations(data)
		for _, loc in ipairs(locations) do
			local cx = region_x * 32 + loc.local_x
			local cz = region_z * 32 + loc.local_z
			chunk_count = chunk_count + 1
			if not x_min or cx < x_min then x_min = cx end
			if not x_max or cx > x_max then x_max = cx end
			if not z_min or cz < z_min then z_min = cz end
			if not z_max or cz > z_max then z_max = cz end
		end
	end
	if chunk_count == 0 then return nil end
	return {
		chunk_count = chunk_count,
		chunk_x_min = x_min, chunk_x_max = x_max,
		chunk_z_min = z_min, chunk_z_max = z_max,
		block_x_min = x_min * 16, block_x_max = x_max * 16 + 15,
		block_z_min = z_min * 16, block_z_max = z_max * 16 + 15,
	}
end

function anvil.read_region_extent(world_folder, dimension_path)
	return anvil.read_region_extent_from_dir(anvil.region_dir(world_folder, dimension_path))
end

-- Streams every non-air block in a dimension as
-- callback(x, y, z, mineclonia_node_name) -- resolved through palette.lua
-- (auto-loaded from this file's own directory; pass `resolve` to override,
-- e.g. in tests that want raw (name, properties) instead).
function anvil.iter_blocks(world_folder, dimension_path, callback, resolve)
	if not resolve then
		if not anvil._palette then
			anvil._palette = _dofile((_G.__spawnimport_lua_import_path or script_dir()) .. "palette.lua")
		end
		resolve = anvil._palette.resolve
	end
	local dir = anvil.region_dir(world_folder, dimension_path)
	local files = anvil.list_region_files(dir)
	for _, fpath in ipairs(files) do
		anvil.iter_region_chunks(fpath, function(chunk_x, chunk_z, chunk)
			anvil.decode_chunk_blocks(chunk, function(x, y, z, name, props)
				local node = resolve(name, props)
				callback(x, y, z, node)
			end)
		end)
	end
end

return anvil
