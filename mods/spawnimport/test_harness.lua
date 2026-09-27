#!/usr/bin/env luajit
-- Mock-engine test harness for the spawnimport mod. This project has no
-- running Luanti server to test against in this environment, so this
-- fakes just enough of the server Lua API (core.get_voxel_manip,
-- core.get_dir_list, core.get_mod_storage, chat commands, ...) to drive
-- the REAL init.lua/registry.lua against REAL capture data and check the
-- results -- not a substitute for playing it in-game (that's step 5), but
-- far more than a syntax check.
--
-- Scope: this only exercises spawnimport's own logic (job batching,
-- coordinate offsetting, VoxelManip usage, collision detection, chat
-- command parsing). It does NOT re-test lua_import's Anvil/NBT/palette
-- correctness -- that's already covered by lua_import/test_harness.lua
-- against the same real capture. To keep this fast, the mock limits which
-- region files get processed to a single small file (see ONLY_REGION_FILE
-- below) rather than a whole ~10,000-chunk dimension.
--
-- Run: luajit mods/spawnimport/test_harness.lua  (from the kit root)
-- Needs tools/harness_world set up first: tools/setup_harness_world.sh
-- (symlinks one real capture region/ dir into a WorldTools-style folder
-- this harness drives /worldplace against).

local function script_dir()
	local source = debug.getinfo(1, "S").source
	return source:match("^@(.*[/\\])") or "./"
end
local HERE = script_dir()
local LUA_IMPORT_PATH = HERE .. "../../lua_import/"
local WORLD_FOLDER = HERE .. "../../tools/harness_world"

-- Real zlib/gzip decompression via LuaJIT FFI (gzip.lua's windowBits=47
-- auto-detects the zlib wrapper region chunks use) -- real decompression,
-- not a fake stub.
local gzip = dofile(LUA_IMPORT_PATH .. "gzip.lua")

local failures = 0
local function check(label, cond, detail)
	if cond then
		print("  ok   " .. label)
	else
		failures = failures + 1
		print("  FAIL " .. label .. (detail and (" -- " .. detail) or ""))
	end
end

-- -----------------------------------------------------------------
-- Mock engine
-- -----------------------------------------------------------------

local function real_get_dir_list(path, is_dir)
	local kind = is_dir and "d" or "f"
	local p = io.popen(string.format("find %q -mindepth 1 -maxdepth 1 -type %s -exec basename {} \\;", path, kind))
	local names = {}
	if p then
		for line in p:lines() do names[#names + 1] = line end
		p:close()
	end
	return names
end

-- The single region file every test below runs against. The harness is
-- capture-agnostic (all expected numbers are derived from the real bytes
-- at run time -- see "capture-derived constants" below), but the capture
-- must be MODERN (1.18+ `sections` layout -- the decoder rejects pre-1.18
-- numeric-ID chunks) and the file must hold at least 2 chunks adjacent
-- along one axis (Test 5 needs a real neighbour pair to catch the
-- neighbouring-chunk-erasure regression). Default (from
-- tools/setup_harness_world.sh) is cutecurly's City r.-4660.898.mca:
-- 5 modern chunks, 4 of them contiguous along x, ~180k blocks.
local ONLY_REGION_FILE = "r.-4660.898.mca"

local chat_messages = {} -- player_name -> array of messages
local log_messages = {}

local content_id_of = {}
local content_name_of = {}
local next_content_id = 1

local fake_map = {} -- "x,y,z" -> content_id, simulating the placed world
local fake_param2_map = {} -- "x,y,z" -> param2
local generated_mapblocks = {} -- "bx,by,bz" -> true once mapgen has run there
local ungenerated_writes = 0 -- content written into a never-generated mapblock

local FakeVM = {}
FakeVM.__index = FakeVM
-- Expands the requested area out to whole 16-block mapblock boundaries,
-- exactly like the real engine does. This is not a detail the mock can
-- skip: the emerged area being WIDER than what the caller asked for is
-- what made "fill the whole emerged volume with air" destructive, since
-- write_to_map writes all of it back. The mock previously returned the
-- requested area verbatim, which is precisely why it happily passed a
-- placement bug that shredded every base into evenly-spaced strips in the
-- real engine.
local function floor_to_mapblock(v) return math.floor(v / 16) * 16 end
function FakeVM:read_from_map(p1, p2)
	self.MinEdge = { x = floor_to_mapblock(p1.x), y = floor_to_mapblock(p1.y), z = floor_to_mapblock(p1.z) }
	self.MaxEdge = {
		x = floor_to_mapblock(p2.x) + 15,
		y = floor_to_mapblock(p2.y) + 15,
		z = floor_to_mapblock(p2.z) + 15,
	}
	return self.MinEdge, self.MaxEdge
end
-- Reads back whatever's already in fake_map/fake_param2_map (simulating
-- pre-existing destination-world content, e.g. native mapgen terrain) --
-- NOT just a blank slate. Without this, the mock could never have caught
-- the "leftover mapgen terrain" bug (place_one_chunk previously only wrote
-- where the source had non-air content, and never explicitly cleared
-- everything else in a chunk's footprint to air).
function FakeVM:get_data()
	local w = self.MaxEdge.x - self.MinEdge.x + 1
	local h = self.MaxEdge.y - self.MinEdge.y + 1
	local d = self.MaxEdge.z - self.MinEdge.z + 1
	local data = {}
	for z = self.MinEdge.z, self.MaxEdge.z do
		for y = self.MinEdge.y, self.MaxEdge.y do
			for x = self.MinEdge.x, self.MaxEdge.x do
				local idx = 1 + (x - self.MinEdge.x) + (y - self.MinEdge.y) * w + (z - self.MinEdge.z) * w * h
				data[idx] = fake_map[x .. "," .. y .. "," .. z] or 0
			end
		end
	end
	return data
end
function FakeVM:get_param2_data()
	local w = self.MaxEdge.x - self.MinEdge.x + 1
	local h = self.MaxEdge.y - self.MinEdge.y + 1
	local d = self.MaxEdge.z - self.MinEdge.z + 1
	local data = {}
	for z = self.MinEdge.z, self.MaxEdge.z do
		for y = self.MinEdge.y, self.MaxEdge.y do
			for x = self.MinEdge.x, self.MaxEdge.x do
				local idx = 1 + (x - self.MinEdge.x) + (y - self.MinEdge.y) * w + (z - self.MinEdge.z) * w * h
				data[idx] = fake_param2_map[x .. "," .. y .. "," .. z] or 0
			end
		end
	end
	return data
end
function FakeVM:set_data(data) self.pending = data end
function FakeVM:set_param2_data(data) self.pending_p2 = data end
function FakeVM:write_to_map(_light)
	local w = self.MaxEdge.x - self.MinEdge.x + 1
	local h = self.MaxEdge.y - self.MinEdge.y + 1
	for z = self.MinEdge.z, self.MaxEdge.z do
		for y = self.MinEdge.y, self.MaxEdge.y do
			for x = self.MinEdge.x, self.MaxEdge.x do
				local idx = 1 + (x - self.MinEdge.x) + (y - self.MinEdge.y) * w + (z - self.MinEdge.z) * w * h
				local cid = self.pending[idx]
				local key = x .. "," .. y .. "," .. z
				if cid and cid ~= 0 then
					if not generated_mapblocks[math.floor(x / 16) .. "," .. math.floor(y / 16)
						.. "," .. math.floor(z / 16)] then
						ungenerated_writes = ungenerated_writes + 1
					end
					fake_map[key] = cid
					fake_param2_map[key] = self.pending_p2 and self.pending_p2[idx] or 0
				else
					-- explicitly cleared to air -- must actually remove any
					-- previous entry, not just skip adding a new one (this is
					-- exactly the "leftover terrain" bug class this test
					-- exists to catch, just in the mock instead of the mod)
					fake_map[key] = nil
					fake_param2_map[key] = nil
				end
			end
		end
	end
end
function FakeVM:update_liquids() end
function FakeVM:close() end

_G.VoxelArea = {}
VoxelArea.__index = VoxelArea
function VoxelArea:new(o)
	local a = setmetatable({}, VoxelArea)
	a.MinEdge, a.MaxEdge = o.MinEdge, o.MaxEdge
	a.ystride = o.MaxEdge.x - o.MinEdge.x + 1
	a.zstride = a.ystride * (o.MaxEdge.y - o.MinEdge.y + 1)
	return a
end
function VoxelArea:index(x, y, z)
	return 1 + (x - self.MinEdge.x) + (y - self.MinEdge.y) * self.ystride + (z - self.MinEdge.z) * self.zstride
end
function VoxelArea:getVolume()
	return (self.MaxEdge.x - self.MinEdge.x + 1) * (self.MaxEdge.y - self.MinEdge.y + 1)
		* (self.MaxEdge.z - self.MinEdge.z + 1)
end

local function simple_serialize(v)
	local t = type(v)
	if t == "string" then return string.format("%q", v) end
	if t == "number" or t == "boolean" then return tostring(v) end
	if t == "table" then
		local parts = {}
		local seen = {}
		for i, item in ipairs(v) do
			parts[#parts + 1] = simple_serialize(item)
			seen[i] = true
		end
		for k, val in pairs(v) do
			if not (type(k) == "number" and seen[k]) then
				parts[#parts + 1] = "[" .. simple_serialize(k) .. "]=" .. simple_serialize(val)
			end
		end
		return "{" .. table.concat(parts, ",") .. "}"
	end
	return "nil"
end
local function simple_deserialize(s)
	local loader = loadstring or load
	local chunk = loader("return " .. s)
	if not chunk then return nil end
	return chunk()
end

-- Minimal recursive-descent JSON decoder -- just enough to read the flat
-- array-of-objects manifests museum_survey.py produces (strings, numbers,
-- booleans, null, nested objects/arrays); not a general-purpose parser
-- (no unicode escapes), mocking core.parse_json for /museumimport's tests.
local function simple_json_decode(s)
	local i = 1
	local function skip_ws()
		local _, e = s:find("^%s*", i)
		i = e + 1
	end
	local parse_value
	local function parse_string()
		assert(s:sub(i, i) == '"')
		i = i + 1
		local start = i
		local parts = {}
		while s:sub(i, i) ~= '"' do
			if s:sub(i, i) == "\\" then
				parts[#parts + 1] = s:sub(start, i - 1)
				local esc = s:sub(i + 1, i + 1)
				local map = { n = "\n", t = "\t", r = "\r", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
				parts[#parts + 1] = map[esc] or esc
				i = i + 2
				start = i
			else
				i = i + 1
			end
		end
		parts[#parts + 1] = s:sub(start, i - 1)
		i = i + 1
		return table.concat(parts)
	end
	local function parse_number()
		local start = i
		local _, e = s:find("^-?%d+%.?%d*[eE]?[+-]?%d*", i)
		i = e + 1
		return tonumber(s:sub(start, e))
	end
	local function parse_array()
		i = i + 1
		local out = {}
		skip_ws()
		if s:sub(i, i) == "]" then i = i + 1; return out end
		while true do
			skip_ws()
			out[#out + 1] = parse_value()
			skip_ws()
			if s:sub(i, i) == "," then i = i + 1 else break end
		end
		skip_ws()
		assert(s:sub(i, i) == "]")
		i = i + 1
		return out
	end
	local function parse_object()
		i = i + 1
		local out = {}
		skip_ws()
		if s:sub(i, i) == "}" then i = i + 1; return out end
		while true do
			skip_ws()
			local key = parse_string()
			skip_ws()
			assert(s:sub(i, i) == ":")
			i = i + 1
			skip_ws()
			out[key] = parse_value()
			skip_ws()
			if s:sub(i, i) == "," then i = i + 1 else break end
		end
		skip_ws()
		assert(s:sub(i, i) == "}")
		i = i + 1
		return out
	end
	parse_value = function()
		skip_ws()
		local c = s:sub(i, i)
		if c == '"' then return parse_string() end
		if c == "{" then return parse_object() end
		if c == "[" then return parse_array() end
		if s:sub(i, i + 3) == "true" then i = i + 4; return true end
		if s:sub(i, i + 4) == "false" then i = i + 5; return false end
		if s:sub(i, i + 3) == "null" then i = i + 4; return nil end
		return parse_number()
	end
	local ok, result = pcall(parse_value)
	if not ok then return nil, tostring(result) end
	return result
end

local storage_data = {}
local FakeStorage = {}
FakeStorage.__index = FakeStorage
function FakeStorage:get_string(key) return storage_data[key] or "" end
function FakeStorage:set_string(key, value) storage_data[key] = value end

local privileges = {}
local captured_globalsteps = {}
local registered_chatcommands = {}

local mock_registered_nodes = setmetatable({}, { __index = function() return {} end }) -- treat every node as registered

-- Real Luanti provides `vector` as a global builtin (with method-style
-- vector:add()/etc via a metatable) -- standalone LuaJIT has no such
-- thing, so init.lua's vector.new(...) calls (see its own comment on why
-- those matter -- a real crash, not theoretical) need a stand-in here.
_G.vector = {
	new = function(x, y, z) return setmetatable({ x = x, y = y, z = z }, { __index = { add = function(self, other) return _G.vector.new(self.x + other.x, self.y + other.y, self.z + other.z) end } }) end,
}

_G.core = {
	get_modpath = function(_name) return HERE:gsub("/$", "") end,
	-- Standalone LuaJIT has no sandboxing at all, so the real global
	-- dofile/io are already "insecure" -- this just needs to satisfy
	-- init.lua's contract (called once, at its main scope) and hand back
	-- something with the two fields init.lua actually reads. io.popen is
	-- wrapped so init.lua's `find`-based directory listing still gets
	-- scoped down to ONLY_REGION_FILE for a fast test, same as
	-- get_dir_list below did before init.lua switched to io.popen-based
	-- listing (real Luanti mods can't use get_dir_list on an external
	-- path even when trusted -- see init.lua's comment on why).
	request_insecure_environment = function()
		return {
			dofile = dofile,
			io = {
				popen = function(cmd)
					if cmd:match('/region"') then
						return io.popen(string.format("echo %s", ONLY_REGION_FILE))
					end
					return io.popen(cmd)
				end,
				open = io.open,
			},
		}
	end,
	settings = {
		get = function(_self, key)
			if key == "spawnimport_lua_import_path" then return LUA_IMPORT_PATH end
			return nil
		end,
	},
	decompress = gzip.decompress,
	get_dir_list = function(path, is_dir)
		local names = real_get_dir_list(path, is_dir)
		if not is_dir and path:match("/region$") then
			local limited = {}
			for _, n in ipairs(names) do
				if n == ONLY_REGION_FILE then limited[#limited + 1] = n end
			end
			return limited
		end
		return names
	end,
	register_privilege = function(name, def) privileges[name] = def end,
	-- Luanti calls every registered globalstep each tick, not just the
	-- last one -- init.lua registers two (job stepping, batch advancing),
	-- so the mock needs to too (see run_job_to_completion below).
	register_globalstep = function(fn) captured_globalsteps[#captured_globalsteps + 1] = fn end,
	register_chatcommand = function(name, def) registered_chatcommands[name] = def end,
	register_on_joinplayer = function(_fn) end,
	get_us_time = function() return os.clock() * 1000000 end,
	log = function(level, msg)
		log_messages[#log_messages + 1] = { level = level, msg = msg }
		print("  [log:" .. level .. "] " .. msg)
	end,
	chat_send_player = function(player_name, msg)
		chat_messages[player_name] = chat_messages[player_name] or {}
		table.insert(chat_messages[player_name], msg)
		print("  [chat->" .. player_name .. "] " .. msg)
	end,
	registered_nodes = mock_registered_nodes,
	registered_biomes = {}, -- wgen_inputs resolves targets here; empty = fallback materials, fine for the mock
	-- worldgen-merge API surface (PLAN-worldgen-merge.md §2.3): biome ids
	-- and the engine decoration pass. The mock's pass plants trunk-only
	-- "trees" (tree-group blocks, self-supporting so the floating-veg
	-- audit stays green) at the INPUT heightmap heights -- this is the
	-- whole contract: vegetation lands at the MERGED surface, not at the
	-- natural one.
	get_biome_id = function(_name) return 1 end,
	get_biome_name = function(_id) return nil end,
	generate_decorations_with_inputs = function(vm, p1, p2, H, Bm)
		decor_passes = (decor_passes or 0) + 1
		decor_heightmap = H
		for lz = 0, 15 do
			for lx = 0, 15 do
				local h = H[16 * lz + lx + 1]
				if h and h < 32767 and h > 1 and (lx * 3 + lz * 5) % 7 == 0 then
					for t = 1, 3 do
						fake_map[(p1.x + lx) .. "," .. (h + t) .. "," .. (p1.z + lz)]
							= content_id_of["mcl_core:jungletree"] or core.get_content_id("mcl_core:jungletree")
					end
				end
			end
		end
		return true
	end,
	get_name_from_content_id = function(id)
		return content_name_of[id] or (id == 0 and "air" or "unknown:" .. tostring(id))
	end,
	get_mapgen_setting = function(name)
		-- gap_fill.lua reads water_level at load; mock value = a v7 overworld's
		if name == "water_level" then return "1" end
		return nil
	end,
	get_item_group = function(name, group)
		local def = mock_registered_nodes[name]
		return (def and def.groups and def.groups[group]) or 0
	end,
	CONTENT_AIR = 0, -- next_content_id starts at 1, so this never collides with a real node id below
	get_content_id = function(name)
		local id = content_id_of[name]
		if not id then
			id = next_content_id
			next_content_id = next_content_id + 1
			content_id_of[name] = id
			content_name_of[id] = name
		end
		return id
	end,
	-- Models the engine invariant this mod depends on: a mapblock is only
	-- "generated" once mapgen has run over it, and a VoxelManip write does
	-- NOT generate one. Content written into a block that was never
	-- generated is (a) regenerated over by the emerge thread and (b) never
	-- sent to the client at all -- so it silently vanishes. Tracking the
	-- flag here lets the harness catch a regression that drops the
	-- pre-generation pass, which in the real engine only shows up as
	-- "the base is missing" after a client flies near it.
	emerge_area = function(minp, maxp, callback)
		for bz = math.floor(minp.z / 16), math.floor(maxp.z / 16) do
			for by = math.floor(minp.y / 16), math.floor(maxp.y / 16) do
				for bx = math.floor(minp.x / 16), math.floor(maxp.x / 16) do
					generated_mapblocks[bx .. "," .. by .. "," .. bz] = true
				end
			end
		end
		if callback then callback({ x = 0, y = 0, z = 0 }, 0, 0) end
	end,
	get_voxel_manip = function() return setmetatable({}, FakeVM) end,
	get_mod_storage = function() return setmetatable({}, FakeStorage) end,
	serialize = simple_serialize,
	deserialize = simple_deserialize,
	parse_json = function(str, _nullvalue, _return_error) return simple_json_decode(str) end,
}

-- -----------------------------------------------------------------
-- Load the real mod
-- -----------------------------------------------------------------

dofile(HERE .. "init.lua")

check("chatcommand registered", registered_chatcommands.worldplace ~= nil)
check("museumimport chatcommand registered", registered_chatcommands.museumimport ~= nil)
check("globalstep registered", #captured_globalsteps > 0)
check("worldplace privilege registered", privileges.worldplace ~= nil)

local function run_command(param)
	return registered_chatcommands.worldplace.func("tester", param)
end

local function run_museumimport_command(param)
	return registered_chatcommands.museumimport.func("tester", param)
end

local function run_job_to_completion(max_ticks)
	for _ = 1, max_ticks do
		for _, fn in ipairs(captured_globalsteps) do
			fn(0.1)
		end
	end
end

-- -----------------------------------------------------------------
-- Capture-derived constants
-- -----------------------------------------------------------------
-- Every "expected" number below comes from the REAL capture bytes the
-- mock serves, not from hardcoded values -- the harness was previously
-- unrunnable because its constants were tuned to a since-lost test
-- capture (and that capture was pre-1.18 legacy format this decoder
-- can't even read). Probing the real data once here keeps the tests
-- honest about WHAT they check without pinning them to one dataset.
local anvil_probe = dofile(LUA_IMPORT_PATH .. "anvil.lua")
local nbt_probe = dofile(LUA_IMPORT_PATH .. "nbt.lua")
anvil_probe.decompress = gzip.decompress
anvil_probe.list_dir = function(_dir) return { ONLY_REGION_FILE } end -- same scoping the mock enforces
local PROBE_DIR = WORLD_FOLDER .. "/dimensions/minecraft/worlds/2b2t/2b2t_1/region"
local probe_file = PROBE_DIR .. "/" .. ONLY_REGION_FILE
local probe_data = assert(anvil_probe.read_file(probe_file), "harness_world not set up? run tools/setup_harness_world.sh")
local probe_locs = anvil_probe.read_region_locations(probe_data)
local prx, prz = anvil_probe.region_coords_from_filename(probe_file)

local CHUNKS = {} -- {cx=,cz=} for every chunk in the scoped region file, sorted
local MIN_CX, MAX_CX, MIN_CZ, MAX_CZ = nil, nil, nil, nil
local SRC_TOP = nil -- highest source y with any block anywhere
for _, loc in ipairs(probe_locs) do
	local cx, cz = prx * 32 + loc.local_x, prz * 32 + loc.local_z
	CHUNKS[#CHUNKS + 1] = { cx = cx, cz = cz }
	MIN_CX = not MIN_CX and cx or math.min(MIN_CX, cx)
	MAX_CX = not MAX_CX and cx or math.max(MAX_CX, cx)
	MIN_CZ = not MIN_CZ and cz or math.min(MIN_CZ, cz)
	MAX_CZ = not MAX_CZ and cz or math.max(MAX_CZ, cz)
	local chunk = nbt_probe.parse_buffer(anvil_probe.read_chunk_payload(probe_data, loc.offset))
	pcall(anvil_probe.decode_chunk_blocks, chunk, function(_x, y, _z, _name)
		if not SRC_TOP or y > SRC_TOP then SRC_TOP = y end
	end)
end
table.sort(CHUNKS, function(a, b) return a.cx == b.cx and a.cz < b.cz or a.cx < b.cx end)
SRC_TOP = SRC_TOP or 300
-- Region-file-local block origin (what /worldplace's extent scan computes
-- for this same single-file scope -- the museum manifest path passes the
-- same numbers explicitly).
local ORIGIN_X, ORIGIN_Z = MIN_CX * 16, MIN_CZ * 16
-- Count adjacent chunk pairs (sharing a full edge) -- Test 5's regression
-- check is meaningless without at least one.
local ADJACENT_PAIRS = 0
for _, a in ipairs(CHUNKS) do
	for _, b in ipairs(CHUNKS) do
		if (a.cx == b.cx and math.abs(a.cz - b.cz) == 1) or (a.cz == b.cz and math.abs(a.cx - b.cx) == 1) then
			ADJACENT_PAIRS = ADJACENT_PAIRS + 1
		end
	end
end
ADJACENT_PAIRS = ADJACENT_PAIRS / 2

-- -----------------------------------------------------------------
-- Test 1: a real import against the (mock-limited) capture
-- -----------------------------------------------------------------

print("")
print("=== Test 1: /worldplace start + run to completion ===")

-- Regression test for the "leftover native terrain" bug: seed a fake
-- pre-existing block (as if the destination world's own mapgen put
-- something there) at a position inside the min-cx chunk's footprint once
-- anchored at (5000,6000), at a y the capture is guaranteed not to fill
-- (above every real source block), so the ONLY thing that could leave it
-- there is a clear that doesn't cover the chunk's full 16x16 column.
local PRETEND_TERRAIN_POS = string.format("5005,%d,6005", math.min(SRC_TOP + 5, 317))
fake_map[PRETEND_TERRAIN_POS] = 999999 -- an id no real resolved node will ever use
fake_param2_map[PRETEND_TERRAIN_POS] = 0

local ok1, msg1 = run_command(WORLD_FOLDER .. " 5000 6000 testbase1")
check("start accepted", ok1 == true, tostring(msg1))
print("  -> " .. tostring(msg1))

run_job_to_completion(50)

local last_msgs = chat_messages["tester"] or {}
local finished, finished_msg = false, nil
for _, m in ipairs(last_msgs) do
	if m:match("^%[spawnimport%] testbase1: done%.") then
		finished, finished_msg = true, m
	end
end
check("job reported done", finished)
-- A regression that breaks every single chunk (e.g. a mock missing some
-- core.* function place_one_chunk now calls) would otherwise pass silently
-- here: place_one_chunk's own pcall turns any per-chunk error into a
-- logged-and-skipped chunk, not a hard test failure -- confirmed the hard
-- way (a missing core.get_item_group mock silently zeroed out this exact
-- test's placed-block count while every other check still read "ok").
check("no chunks were skipped", finished_msg and finished_msg:match("%(0 chunk%(s%) skipped") ~= nil,
	tostring(finished_msg))

-- Every chunk in the scoped region file decodes to tens of thousands of
-- real blocks (confirmed above in the probe), so total placed blocks
-- should be a large, specific, non-zero number, and every fake_map
-- entry's content id should resolve back to a real node name string.
local placed_count = 0
local bad_entries = 0
for _key, cid in pairs(fake_map) do
	placed_count = placed_count + 1
	local name = content_name_of[cid]
	if type(name) ~= "string" or name == "" then bad_entries = bad_entries + 1 end
end
check("blocks actually landed in the fake map", placed_count > 10000, tostring(placed_count))
check("every placed content id maps back to a real node name", bad_entries == 0, tostring(bad_entries))

-- Spot check the offset math directly: the min-cx chunk's source min-x
-- plane should land exactly at anchor x=5000 after offsetting -- i.e. a
-- source block at (ORIGIN_X, y, z) should appear at (5000, y, z).
local anchor_hits = 0
for key, _cid in pairs(fake_map) do
	local x = tonumber(key:match("^(-?%d+),"))
	if x == 5000 then anchor_hits = anchor_hits + 1 end
end
check("at least one block landed exactly on the anchor's min-x plane (x=5000)", anchor_hits > 0, tostring(anchor_hits))

-- (the "no wiped-neighbour strips" regression needs chunks that are actually
-- adjacent along a *misaligned* axis -- see Test 5 at the end of this
-- file, which sets up that geometry deliberately.)

-- param2 (orientation) actually flows all the way through VoxelManip's
-- set_param2_data/write_to_map, not just through the resolver -- this
-- mini_capture has oriented logs/furnaces even though it's mostly terrain,
-- so some non-zero param2 should have landed in the fake map.
local nonzero_param2 = 0
for _key, p2 in pairs(fake_param2_map) do
	if p2 ~= 0 then nonzero_param2 = nonzero_param2 + 1 end
end
check("at least one non-zero param2 landed in the fake map", nonzero_param2 > 0, tostring(nonzero_param2))

check("pre-existing 'native terrain' at an air position got cleared, not left in place",
	fake_map[PRETEND_TERRAIN_POS] == nil, tostring(fake_map[PRETEND_TERRAIN_POS]))

-- Every block of content must land in a mapblock that was generated
-- first. Skipping that is invisible in isolation -- the write "succeeds"
-- and reads back fine on the server -- but in the real engine the emerge
-- thread later regenerates over it AND the server never sends it to the
-- client, which is how an entire imported base renders as empty sky.
check("all content was written into pre-generated mapblocks", ungenerated_writes == 0,
	tostring(ungenerated_writes) .. " node writes into never-generated mapblocks")

-- -----------------------------------------------------------------
-- Test 2: registry collision detection
-- -----------------------------------------------------------------

print("")
print("=== Test 2: registry collision detection ===")

local ok2, msg2 = run_command(WORLD_FOLDER .. " 5000 6000 testbase2")
check("overlapping placement refused", ok2 == false, tostring(msg2))
check("collision message names the existing base", type(msg2) == "string" and msg2:match("testbase1") ~= nil, tostring(msg2))

local ok3, msg3 = run_command("force " .. WORLD_FOLDER .. " 5000 6000 testbase3")
check("force accepted despite overlap", ok3 == true, tostring(msg3))
run_job_to_completion(50)

-- -----------------------------------------------------------------
-- Test 3: list / status / cancel
-- -----------------------------------------------------------------

print("")
print("=== Test 3: list / status / cancel ===")

local ok4, msg4 = run_command("list")
check("list succeeds", ok4 == true)
check("list mentions both placed bases", msg4:match("testbase1") and msg4:match("testbase3") ~= nil, msg4)

local ok5, msg5 = run_command("status")
check("status with no active job", ok5 == true and msg5:match("no import in progress") ~= nil, tostring(msg5))

local ok6, msg6 = run_command(WORLD_FOLDER .. " 50000 60000 testbase4")
check("far-away placement accepted (no collision)", ok6 == true, tostring(msg6))
local ok7, msg7 = run_command("cancel")
check("cancel succeeds", ok7 == true, tostring(msg7))
local ok8, msg8 = run_command("status")
check("status after cancel shows no job", ok8 == true and msg8:match("no import in progress") ~= nil, tostring(msg8))

local ok9, msg9 = run_command("list")
check("cancelled job did not get added to the registry", not msg9:match("testbase4"), msg9)

-- -----------------------------------------------------------------
-- Test 4: /museumimport batch driver -- region_dir/dest_y_offset overrides
-- and checkpointed resume
-- -----------------------------------------------------------------

print("")
print("=== Test 4: /museumimport batch driver ===")

local REGION_DIR = WORLD_FOLDER .. "/dimensions/minecraft/worlds/2b2t/2b2t_1/region"
local MUSEUM_ANCHOR_X = 70000
local MUSEUM_ANCHOR_X2 = 90000
local Y_OFFSET = 1000
-- ORIGIN_X/ORIGIN_Z, MIN/MAX_CX/CZ come from the capture probe above.
local EXT_W = (MAX_CX - MIN_CX) * 16 + 15
local EXT_D = (MAX_CZ - MIN_CZ) * 16 + 15
-- museumtest2 trims with chunk_bounds to just the first two chunks (sorted
-- order) -- exercises museum_survey.py's corridor-trimming path end to
-- end (fewer chunks in = fewer blocks placed).
local SUB_MAX_CX = CHUNKS[2] and CHUNKS[2].cx or CHUNKS[1].cx
local manifest = {
	{
		display_name = "museumtest1",
		source_region_dir = REGION_DIR,
		source_base_folder = WORLD_FOLDER,
		dimension_type = "nether",
		dest_anchor_x = MUSEUM_ANCHOR_X,
		dest_anchor_z = 80000,
		dest_y_offset = Y_OFFSET,
		origin_x = ORIGIN_X,
		origin_z = ORIGIN_Z,
		dest_bbox = { x_min = MUSEUM_ANCHOR_X, x_max = MUSEUM_ANCHOR_X + EXT_W, z_min = 80000, z_max = 80000 + EXT_D },
	},
	{
		-- Same source, but chunk_bounds trims to the first two chunks only.
		display_name = "museumtest2",
		source_region_dir = REGION_DIR,
		source_base_folder = WORLD_FOLDER,
		dimension_type = "overworld",
		dest_anchor_x = MUSEUM_ANCHOR_X2,
		dest_anchor_z = 80000,
		dest_y_offset = 0,
		origin_x = ORIGIN_X,
		origin_z = ORIGIN_Z,
		dest_bbox = {
			x_min = MUSEUM_ANCHOR_X2, x_max = MUSEUM_ANCHOR_X2 + (SUB_MAX_CX - MIN_CX) * 16 + 15,
			z_min = 80000, z_max = 80000 + EXT_D,
		},
		chunk_bounds = { x_min = CHUNKS[1].cx, x_max = SUB_MAX_CX, z_min = MIN_CZ, z_max = MAX_CZ },
	},
}
-- Minimal JSON encoder, mirroring simple_json_decode above -- just enough
-- for this flat array-of-flat-objects manifest fixture.
local function simple_json_encode(v)
	local t = type(v)
	if t == "string" then return string.format("%q", v) end
	if t == "number" or t == "boolean" then return tostring(v) end
	if t == "table" then
		if #v > 0 then
			local parts = {}
			for _, item in ipairs(v) do parts[#parts + 1] = simple_json_encode(item) end
			return "[" .. table.concat(parts, ",") .. "]"
		end
		local parts = {}
		for k, val in pairs(v) do
			parts[#parts + 1] = string.format("%q", k) .. ":" .. simple_json_encode(val)
		end
		return "{" .. table.concat(parts, ",") .. "}"
	end
	return "null"
end

local manifest_path = os.tmpname()
local mf = io.open(manifest_path, "w")
mf:write(simple_json_encode(manifest))
mf:close()

local okm1, msgm1 = run_museumimport_command("start " .. manifest_path .. " 5")
check("museumimport start accepted", okm1 == true, tostring(msgm1))
run_job_to_completion(50)

local museum_msgs = chat_messages["tester"] or {}
local museum1_finished, museum1_msg = false, nil
local museum2_finished, museum2_msg = false, nil
for _, m in ipairs(museum_msgs) do
	if m:match("^%[spawnimport%] museumtest1: done%.") then museum1_finished, museum1_msg = true, m end
	if m:match("^%[spawnimport%] museumtest2: done%.") then museum2_finished, museum2_msg = true, m end
end
check("museumimport-driven job (museumtest1) reported done", museum1_finished)
check("museumimport-driven job (museumtest2, chunk_bounds) reported done", museum2_finished)
check("museumtest1: no chunks were skipped", museum1_msg and museum1_msg:match("%(0 chunk%(s%) skipped") ~= nil,
	tostring(museum1_msg))
check("museumtest2: no chunks were skipped", museum2_msg and museum2_msg:match("%(0 chunk%(s%) skipped") ~= nil,
	tostring(museum2_msg))

local reg_entries = simple_deserialize(storage_data["placed_bases"])
local reg_entry, reg_entry2 = nil, nil
for _, e in ipairs(reg_entries) do
	if e.name == "museumtest1" then reg_entry = e end
	if e.name == "museumtest2" then reg_entry2 = e end
end
check("museumimport entry landed in the registry", reg_entry ~= nil)
check("registry entry recorded the dest_y_offset", reg_entry and reg_entry.dest_y_offset == Y_OFFSET,
	reg_entry and tostring(reg_entry.dest_y_offset))

-- chunk_bounds correctness: museumtest2 only covers the first two of the
-- region file's chunks, so its block count should be noticeably less than
-- museumtest1's (which places the same source unfiltered) -- not just
-- "less than N/N", an exact ratio isn't asserted since per-chunk block
-- counts vary, but it should land somewhere well under the unfiltered
-- placement's count.
check("museumtest2 landed in the registry", reg_entry2 ~= nil)
check("chunk_bounds trimmed the placed block count (2 chunks, not all)",
	reg_entry2 and reg_entry2.block_count > 0 and reg_entry2.block_count < reg_entry.block_count,
	reg_entry2 and string.format("museumtest2=%d museumtest1(unfiltered)=%d", reg_entry2.block_count, reg_entry.block_count))

-- Precise Y-shift check: same source region as testbase1 (offset 0), same
-- data, different anchor X/Z and a +1000 Y offset -- so for every distinct
-- min-Y seen at testbase1's anchor plane there should be a matching entry
-- at museumtest1's anchor plane exactly 1000 higher, and vice versa.
local y0_min, y1_min = nil, nil
for key in pairs(fake_map) do
	local x, y = key:match("^(-?%d+),(-?%d+),")
	x, y = tonumber(x), tonumber(y)
	if x == 5000 and (not y0_min or y < y0_min) then y0_min = y end
	if x == MUSEUM_ANCHOR_X and (not y1_min or y < y1_min) then y1_min = y end
end
check("dest_y_offset shifted placed blocks by exactly +1000",
	y0_min and y1_min and (y1_min - y0_min == Y_OFFSET),
	string.format("y0_min=%s y1_min=%s", tostring(y0_min), tostring(y1_min)))

-- Checkpointed resume: re-running the same manifest should find
-- museumtest1 already in the registry (by name) and skip it -- no new job,
-- no duplicate registry entry, batch reports complete immediately.
local before_count = #simple_deserialize(storage_data["placed_bases"])
local okm2, msgm2 = run_museumimport_command("start " .. manifest_path .. " 5")
check("museumimport re-run accepted", okm2 == true, tostring(msgm2))
run_job_to_completion(5)
local after_count = #simple_deserialize(storage_data["placed_bases"])
check("resume did not duplicate the already-placed entry", before_count == after_count,
	string.format("before=%d after=%d", before_count, after_count))

os.remove(manifest_path)

-- -----------------------------------------------------------------
-- Test 5: no wiped-neighbour strips (neighbouring-chunk erasure)
-- -----------------------------------------------------------------
-- read_from_map expands its area out to whole 16-block mapblocks, so when
-- a base's anchor isn't 16-aligned every chunk straddles two mapblocks on
-- that axis and the emerged volume is twice as wide as the chunk.
-- write_to_map writes all of it back, so place_one_chunk filling the whole
-- emerged volume with air erased the strip its neighbour had already
-- placed -- shredding every base into strips of terrain separated by
-- full-height air canyons (found in-client, not by this harness, which is
-- why this test now exists).
--
-- The check is per-chunk column retention: whatever the anchor's
-- alignment and the capture's chunk geometry, a placed chunk must keep
-- real content across essentially all 16 of its columns on BOTH axes. A
-- volume-clear regression wipes whole column ranges (8 columns for a
-- half-mapblock misalignment, up to 15 otherwise) off every chunk that
-- has a neighbour on the misaligned axis, so any chunk losing >2 columns
-- it should have filled is the regression. (The older variant of this
-- test histogrammed z-residues over the run; that only catches the wipe
-- when every chunk in the run is aligned the same way and has a
-- successor -- the per-chunk check is strictly stronger.)
--
-- The anchor is deliberately misaligned on both axes (9000 = 16*562 + 8,
-- 7005 = 16*437 + 13) so the chunks really do straddle mapblocks and
-- really would erase each other. An aligned anchor can't trigger the bug
-- at all -- confirmed earlier by running the pre-fix code against one and
-- watching it pass.
local STRIPE_X, STRIPE_Z = 9000, 7005
check("capture has an adjacent chunk pair (else Test 5 can't catch erasure)", ADJACENT_PAIRS >= 1,
	tostring(ADJACENT_PAIRS))
local oks, msgs = run_command(WORLD_FOLDER .. " " .. STRIPE_X .. " " .. STRIPE_Z .. " stripetest")
check("stripe-test placement accepted", oks == true, tostring(msgs))
run_job_to_completion(50)

-- Per-chunk column occupancy, one pass over the fake map. Scoped to this
-- base's own footprint so earlier tests' bases can't muddy the counts.
local xcols, zcols = {}, {} -- "cx,cz" -> set of column offsets with content
local span_x = (MAX_CX - MIN_CX) * 16 + 15
local span_z = (MAX_CZ - MIN_CZ) * 16 + 15
for key in pairs(fake_map) do
	local x, _y, z = key:match("^(-?%d+),(-?%d+),(-?%d+)$")
	x, z = tonumber(x), tonumber(z)
	local dx = x and (x - STRIPE_X)
	local dz = z and (z - STRIPE_Z)
	if dx and dx >= 0 and dx <= span_x and dz >= 0 and dz <= span_z then
		local k = (MIN_CX + math.floor(dx / 16)) .. "," .. (MIN_CZ + math.floor(dz / 16))
		local lx, lz = dx % 16, dz % 16
		local xs, zs = xcols[k], zcols[k]
		if not xs then xs, zs = {}, {} xcols[k], zcols[k] = xs, zs end
		xs[lx], zs[lz] = true, true
	end
end
local min_xcols, min_zcols, worst = 16, 16, ""
for _, c in ipairs(CHUNKS) do
	local k = c.cx .. "," .. c.cz
	local nx, nz = 0, 0
	for _ in pairs(xcols[k] or {}) do nx = nx + 1 end
	for _ in pairs(zcols[k] or {}) do nz = nz + 1 end
	if math.min(nx, nz) < math.min(min_xcols, min_zcols) then
		worst = string.format("chunk (%d,%d): %d/16 x-columns, %d/16 z-columns", c.cx, c.cz, nx, nz)
	end
	if nx < min_xcols then min_xcols = nx end
	if nz < min_zcols then min_zcols = nz end
end
check("every chunk kept content in >=14/16 of its x-columns (no wiped-neighbour strips)",
	min_xcols >= 14, string.format("min=%d/16 (%s)", min_xcols, worst))
check("every chunk kept content in >=14/16 of its z-columns (no half-chunk erasure)",
	min_zcols >= 14, string.format("min=%d/16 (%s)", min_zcols, worst))

-- -----------------------------------------------------------------
-- Test 6: gap-fill "merge chunk" end to end (synthetic terrain)
-- -----------------------------------------------------------------
-- Drives the REAL gap_fill.lua/gap_field.lua through the mock engine with
-- synthetic generated terrain and a synthetic capture footprint, and
-- asserts the merge behaviours the owner asked for by name:
--   * seam columns line up with the capture's ground EXACTLY (the old
--     "meet half-way" blend left half the difference as a cliff at the
--     chunk border);
--   * every merged slope is walkable (<= 1 block/column);
--   * generated WATER in a raised column is replaced by AIR (it must not
--     ride up with the chunk);
--   * floating masses (islands/platforms) do NOT count as ground and do
--     not survive above the merged surface;
--   * trees/vegetation DO ride along with the shifted surface;
--   * gap_fill.audit passes.
print("")
print("=== Test 6: gap-fill merge chunk end to end ===")

mock_registered_nodes["mcl_core:water_source"] = { groups = { liquid = 1 } }
mock_registered_nodes["mcl_core:jungletree"] = { groups = { tree = 1 } }
mock_registered_nodes["mcl_core:jungleleaves"] = { groups = { leaves = 1 } }
mock_registered_nodes["mcl_ocean:kelp"] = { groups = { plant = 1 } }

local GAP_X, GAP_Z = 30000, 30000 -- far from every earlier test base
local NAT_TOP = 10                 -- synthetic generated ground level
local TARGET = 20                  -- the capture's ground level (dy = 0)
local CHUNK_SET = {}
for _, c in ipairs(CHUNKS) do CHUNK_SET[c.cx .. "," .. c.cz] = true end
local TERRAIN_TEST = {
	["mcl_core:stone"] = true, ["mcl_core:dirt"] = true,
	["mcl_core:dirt_with_grass"] = true, ["mcl_core:sand"] = true,
}

-- Synthetic generated terrain around the whole test area: stone below,
-- dirt, grass at NAT_TOP. Two deliberate features:
--   * a WATER POOL (sand floor + water to y=NAT_TOP) in the chunk under
--     (MIN_CX, MIN_CZ+1) -- raised to TARGET, its water must become air;
--   * a FLOATING ISLAND (2 blocks of stone at y=55..56) over the chunk
--     under (MIN_CX+2, MIN_CZ+1) -- must not count as ground, must not
--     survive;
--   * a TREE (trunk + leaves) in the chunk under (MIN_CX+1, MIN_CZ+1) --
--     must ride along with the shifted surface.
local function seed_column(x, z, top, surf, sub)
	for y = -20, top do
		local name
		if y == top then name = surf
		elseif y >= top - 2 then name = sub
		else name = "mcl_core:stone" end
		fake_map[x .. "," .. y .. "," .. z] = content_id_of[name] or core.get_content_id(name)
	end
end
local function gap_dest(cx, cz)
	return GAP_X + (cx * 16 - ORIGIN_X), GAP_Z + (cz * 16 - ORIGIN_Z)
end
for cz = MIN_CZ - 3, MIN_CZ + 3 do
	for cx = MIN_CX - 3, MAX_CX + 3 do
		local bx, bz = gap_dest(cx, cz)
		for lz = 0, 15 do
			for lx = 0, 15 do
				seed_column(bx + lx, bz + lz, NAT_TOP, "mcl_core:dirt_with_grass", "mcl_core:dirt")
			end
		end
	end
end
do
	local bx, bz = gap_dest(MIN_CX, MIN_CZ + 1)
	for lz = 0, 7 do
		for lx = 0, 7 do
			local x, z = bx + lx, bz + lz
			seed_column(x, z, 7, "mcl_core:sand", "mcl_core:sand")
			for y = 8, NAT_TOP do
				fake_map[x .. "," .. y .. "," .. z] = core.get_content_id("mcl_core:water_source")
			end
		end
	end
end
do
	local bx, bz = gap_dest(MIN_CX + 2, MIN_CZ + 1)
	for lz = 0, 3 do
		for lx = 0, 3 do
			local x, z = bx + lx, bz + lz
			fake_map[x .. ",55," .. z] = core.get_content_id("mcl_core:stone")
			fake_map[x .. ",56," .. z] = core.get_content_id("mcl_core:stone")
		end
	end
end
local TREE_TRUNK_X, TREE_TRUNK_Z
do
	local bx, bz = gap_dest(MIN_CX + 1, MIN_CZ + 1)
	TREE_TRUNK_X, TREE_TRUNK_Z = bx + 5, bz + 5
	fake_map[TREE_TRUNK_X .. ",11," .. TREE_TRUNK_Z] = core.get_content_id("mcl_core:jungletree")
	fake_map[TREE_TRUNK_X .. ",12," .. TREE_TRUNK_Z] = core.get_content_id("mcl_core:jungletree")
	fake_map[TREE_TRUNK_X .. ",13," .. TREE_TRUNK_Z] = core.get_content_id("mcl_core:jungletree")
	fake_map[(TREE_TRUNK_X + 1) .. ",12," .. TREE_TRUNK_Z] = core.get_content_id("mcl_core:jungleleaves")
	fake_map[(TREE_TRUNK_X + 1) .. ",13," .. TREE_TRUNK_Z] = core.get_content_id("mcl_core:jungleleaves")
end

-- Synthetic footprint: every captured chunk is flat ground at TARGET.
local fp_path = os.tmpname()
do
	local chunks = {}
	for _, c in ipairs(CHUNKS) do
		local cols = {}
		for i = 1, 256 do cols[i] = TARGET end
		chunks[#chunks + 1] = {
			cx = c.cx, cz = c.cz, height = TARGET, is_water = false,
			biome = "minecraft:plains",
			cols = cols, solid_cols = cols, terrain_cols = cols,
		}
	end
	local f = io.open(fp_path, "w")
	f:write(simple_json_encode({ chunks = chunks }))
	f:close()
end

local gap_manifest = {
	{
		display_name = "gaptest",
		source_region_dir = REGION_DIR,
		source_base_folder = WORLD_FOLDER,
		dimension_type = "overworld",
		dest_anchor_x = GAP_X,
		dest_anchor_z = GAP_Z,
		dest_y_offset = 0,
		origin_x = ORIGIN_X,
		origin_z = ORIGIN_Z,
		dest_bbox = { x_min = GAP_X, x_max = GAP_X + EXT_W, z_min = GAP_Z, z_max = GAP_Z + EXT_D },
		chunk_bounds = {
			x_min = MIN_CX - 1, x_max = MAX_CX + 1,
			z_min = MIN_CZ - 1, z_max = MIN_CZ + 1,
		},
		footprint_path = fp_path,
	},
}
local gap_manifest_path = os.tmpname()
do
	local f = io.open(gap_manifest_path, "w")
	f:write(simple_json_encode(gap_manifest))
	f:close()
end

local ok_gap, msg_gap = run_museumimport_command("start " .. gap_manifest_path .. " 5")
check("gaptest import accepted", ok_gap == true, tostring(msg_gap))
run_job_to_completion(120)
local gap_msgs = chat_messages["tester"] or {}
local gap_finished = false
for _, m in ipairs(gap_msgs) do
	if m:match("^%[spawnimport%] gaptest: done%.") then gap_finished = true end
end
check("gaptest job reported done", gap_finished)

-- Measure the merged surfaces and scan for the bug classes. Scope: the
-- chunk_bounds area MINUS the captured chunks themselves (the placed
-- base has its own water/stone/towers -- only the merge chunks count).
local W0x = GAP_X + ((MIN_CX - 1) * 16 - ORIGIN_X)
local W0z = GAP_Z + ((MIN_CZ - 1) * 16 - ORIGIN_Z)
local W1x = GAP_X + ((MAX_CX + 1) * 16 + 15 - ORIGIN_X)
local W1z = GAP_Z + ((MIN_CZ + 1) * 16 + 15 - ORIGIN_Z)
local surface, water_found, island_found, tree_found = {}, 0, 0, 0
local old_tree_left, grown_trees = 0, 0
for key, cid in pairs(fake_map) do
	local x, y, z = key:match("^(%-?%d+),(%-?%d+),(%-?%d+)$")
	x, y, z = tonumber(x), tonumber(y), tonumber(z)
	if x and x >= W0x and x <= W1x and z >= W0z and z <= W1z then
		local cx = math.floor((x - GAP_X + ORIGIN_X) / 16)
		local cz = math.floor((z - GAP_Z + ORIGIN_Z) / 16)
		if not CHUNK_SET[cx .. "," .. cz] then
			local name = content_name_of[cid]
			if name == "mcl_core:water_source" then water_found = water_found + 1 end
			if name == "mcl_core:stone" and y > 40 then island_found = island_found + 1 end
			local is_veg_name = (name == "mcl_core:jungletree"
				or name == "mcl_core:jungleleaves" or name == "mcl_ocean:kelp")
			if name == "mcl_core:jungletree" or name == "mcl_core:jungleleaves" then
				-- worldgen-merge semantics: vegetation is NEVER carried
				-- along (that was the smear bug) -- it is cleared and
				-- regrown by the engine decor pass at the MERGED surface.
				-- Trees at natural-height columns are legitimate regrow,
				-- so check the OLD tree's exact coordinates instead.
				if (x == TREE_TRUNK_X and z == TREE_TRUNK_Z and y >= 11 and y <= 13)
					or (x == TREE_TRUNK_X + 1 and z == TREE_TRUNK_Z and y >= 12 and y <= 13) then
					old_tree_left = old_tree_left + 1
				end
				if y > 15 then
					tree_found = tree_found + 1
					-- every grown tree block must stand on solid ground or
					-- on another tree block (trunk column of the mock's
					-- 3-block trees) -- no floating trunks, no smears
					local below = fake_map[x .. "," .. (y - 1) .. "," .. z]
					local below_name = below and content_name_of[below]
					if below_name and below_name ~= "mcl_core:water_source"
						and not (below_name == "mcl_core:jungleleaves")
						and below_name ~= "mcl_ocean:kelp" then
						grown_trees = grown_trees + 1
					end
				end
			end
			-- Surface = topmost solid ground block, same semantics as the
			-- mod's audit (NOT a narrow name whitelist): seam columns take
			-- the captured neighbour's own surface material, which can be
			-- any real capture block name.
			if not is_veg_name and name ~= "mcl_core:water_source" then
				local skey = x .. "," .. z
				if not surface[skey] or y > surface[skey] then surface[skey] = y end
			end
		end
	end
end
check("no generated water survived the merge (raised water -> air)", water_found == 0,
	tostring(water_found))
check("floating island is gone (and never counted as ground)", island_found == 0,
	tostring(island_found))
check("old tree was cleared, NOT carried along (no smearing)", old_tree_left == 0,
	tostring(old_tree_left))
check("trees regrown by the engine decor pass at merged heights", tree_found >= 5,
	tostring(tree_found))
check("regrown trees stand on the merged surface (no floating trunks)",
	grown_trees == tree_found, string.format("%d/%d", grown_trees, tree_found))

-- Seam exactness: every merged column orthogonally adjacent to a
-- captured chunk must sit at exactly TARGET.
local seam_bad, seam_n = 0, 0
for skey, s in pairs(surface) do
	local x, z = skey:match("^(%-?%d+),(%-?%d+)$")
	x, z = tonumber(x), tonumber(z)
	local lx, lz = (x - GAP_X) % 16, (z - GAP_Z) % 16
	-- is this column on the edge of its chunk facing a captured chunk?
	local cx = math.floor((x - GAP_X + ORIGIN_X) / 16)
	local cz = math.floor((z - GAP_Z + ORIGIN_Z) / 16)
	local faced = false
	if lz == 0 and CHUNK_SET[cx .. "," .. (cz - 1)] then faced = true end
	if lz == 15 and CHUNK_SET[cx .. "," .. (cz + 1)] then faced = true end
	if lx == 0 and CHUNK_SET[(cx - 1) .. "," .. cz] then faced = true end
	if lx == 15 and CHUNK_SET[(cx + 1) .. "," .. cz] then faced = true end
	if faced then
		seam_n = seam_n + 1
		if s ~= TARGET then seam_bad = seam_bad + 1 end
	end
end
check("seam columns match the capture's ground exactly", seam_bad == 0 and seam_n > 0,
	string.format("%d/%d wrong", seam_bad, seam_n))

-- Walkability: every adjacent merged-surface pair within the written
-- area is at most 1 block apart (integer rounding included).
local slope_bad, slope_worst = 0, 0
for skey, s in pairs(surface) do
	local x, z = skey:match("^(%-?%d+),(%-?%d+)$")
	x, z = tonumber(x), tonumber(z)
	for _, d in ipairs({ { 1, 0 }, { 0, 1 } }) do
		local nkey = (x + d[1]) .. "," .. (z + d[2])
		local ns = surface[nkey]
		if ns then
			local diff = math.abs(s - ns)
			if diff > 2 then
				slope_bad = slope_bad + 1
				if diff > slope_worst then slope_worst = diff end
			end
		end
	end
end
check("merged slopes are walkable (<= 1 block/column + rounding)", slope_bad == 0,
	string.format("%d bad, worst %.0f", slope_bad, slope_worst))

-- The built-in audit must agree (its numbers go to the log).
local audit_line, audit_failed = nil, false
for _, m in ipairs(log_messages) do
	if m.msg:match("%[gap%-fill%] audit gaptest:") then audit_line = m.msg end
	if m.msg:match("audit FAILED") then audit_failed = true end
end
check("gap_fill.audit ran", audit_line ~= nil)
check("gap_fill.audit reported zero seam mismatches and zero spilled water",
	audit_line and audit_line:match("seam mismatches 0") and audit_line:match("spilled base water blocks 0"),
	tostring(audit_line))
check("gap_fill.audit did not fail", not audit_failed)

os.remove(fp_path)
os.remove(gap_manifest_path)

-- -----------------------------------------------------------------
-- Tests 6b/6c: the NETHER and END merges (wgen_blend3d.lua, 2026-09-27).
-- Not a height field: a 3-D blend between the capture (mirrored across
-- the seam) and the generated terrain, weight 1 at the seam -> 0 at the
-- ring's outer edge. Asserted by name:
--   * the seam is exact (blend3d.audit: 0 seam voxel mismatches);
--   * columns at the ring's outer edge (weight 0) are byte-for-byte the
--     generated terrain -- invisible against untouched chunks;
--   * the bedrock floor/roof rows are never written (nether);
--   * lava never rises above the lava sea (nether);
--   * generated decoration survives where the geometry is unchanged;
--   * the End keeps Mineclonia's own islands at the outer edge (no more
--     "clear everything to void") and writes no liquid.
-- Wrapped in functions: the harness main chunk is at LuaJIT's
-- 200-locals limit.
-- -----------------------------------------------------------------

-- Euclidean column distance from (x, z) to the nearest captured chunk of
-- a test placed at (gx, gz) -- the same measure wgen_blend3d uses.
local function capture_dist(x, z, gx, gz)
	local best = math.huge
	for _, c in ipairs(CHUNKS) do
		local x0 = gx + (c.cx * 16 - ORIGIN_X)
		local z0 = gz + (c.cz * 16 - ORIGIN_Z)
		local dx = (x < x0 and x0 - x) or (x > x0 + 15 and x - x0 - 15) or 0
		local dz = (z < z0 and z0 - z) or (z > z0 + 15 and z - z0 - 15) or 0
		local d = math.sqrt(dx * dx + dz * dz)
		if d < best then best = d end
	end
	return best
end

local function run_band_job(name, dim, gx, gz, dy, fp_path)
	local manifest = {
		{
			display_name = name,
			source_region_dir = REGION_DIR,
			source_base_folder = WORLD_FOLDER,
			dimension_type = dim,
			dest_anchor_x = gx,
			dest_anchor_z = gz,
			dest_y_offset = dy,
			origin_x = ORIGIN_X,
			origin_z = ORIGIN_Z,
			dest_bbox = { x_min = gx, x_max = gx + EXT_W, z_min = gz, z_max = gz + EXT_D },
			chunk_bounds = {
				x_min = MIN_CX - 1, x_max = MAX_CX + 1,
				z_min = MIN_CZ - 1, z_max = MIN_CZ + 1,
			},
			footprint_path = fp_path,
		},
	}
	local mpath = os.tmpname()
	local f = io.open(mpath, "w")
	f:write(simple_json_encode(manifest))
	f:close()
	local ok, msg = run_museumimport_command("start " .. mpath .. " 5")
	check(name .. " import accepted", ok == true, tostring(msg))
	run_job_to_completion(400)
	local finished = false
	for _, m in ipairs(chat_messages["tester"] or {}) do
		if m:match("^%[spawnimport%] " .. name .. ": done%.") then finished = true end
	end
	check(name .. " job reported done", finished)
	local band_seen = false
	for _, m in ipairs(log_messages) do
		if m.msg:find(name .. ": " .. dim .. " band", 1, true) then band_seen = true end
	end
	-- the job itself must know its band (2026-09-27: dimension_type never
	-- reached the job and the nether roof seal silently never ran)
	check(name .. " job carries dimension_type '" .. dim .. "'", band_seen)
	local audit_line, failed = nil, false
	for _, m in ipairs(log_messages) do
		if m.msg:match("%[gap%-fill%] audit " .. name .. ":") then audit_line = m.msg end
		if m.msg:match("audit FAILED") and m.msg:match(name) then failed = true end
	end
	check(name .. " 3-D blend audit ran", audit_line ~= nil and audit_line:match("3%-D blend") ~= nil,
		tostring(audit_line))
	check(name .. " seam exact (0 seam voxel mismatches)", not failed, tostring(audit_line))
	os.remove(mpath)
end

local function write_footprint(level, biome)
	local path = os.tmpname()
	local chunks = {}
	for _, c in ipairs(CHUNKS) do
		local cols = {}
		for i = 1, 256 do cols[i] = level end
		chunks[#chunks + 1] = {
			cx = c.cx, cz = c.cz, height = level, is_water = false, biome = biome,
			cols = cols, solid_cols = cols, terrain_cols = cols,
		}
	end
	local f = io.open(path, "w")
	f:write(simple_json_encode({ chunks = chunks }))
	f:close()
	return path
end

local function test_6b()
print("")
print("=== Test 6b: nether 3-D blend (bedrock rows, lava sea, outer edge) ===")

mock_registered_nodes["mcl_nether:netherrack"] = {}
mock_registered_nodes["mcl_nether:soul_sand"] = {}
mock_registered_nodes["mcl_nether:nether_lava_source"] = { liquidtype = "source", groups = { liquid = 1 } }
mock_registered_nodes["mcl_core:bedrock"] = {}
mock_registered_nodes["mcl_crimson:crimson_roots"] = { walkable = false }

local NDY = -29067            -- Mineclonia's v7 nether band (mg_nether_min)
local NGX, NGZ = GAP_X, GAP_Z + 6000
-- generated nether: bedrock 0..4, netherrack to a soul-sand floor at 20,
-- lava sea 21..31, open cavern, netherrack ceiling 100..123, bedrock
-- roof 124..128; crimson roots on the floor of every 7th column
local function nat(x, y, z)
	if y <= 4 or y >= 124 then return "mcl_core:bedrock" end
	if y < 20 or y >= 100 then return "mcl_nether:netherrack" end
	if y == 20 then return "mcl_nether:soul_sand" end
	if y <= 31 then return "mcl_nether:nether_lava_source" end
	return nil
end
local cid = function(n) return content_id_of[n] or core.get_content_id(n) end
local x0 = NGX + ((MIN_CX - 3) * 16 - ORIGIN_X)
local z0 = NGZ + ((MIN_CZ - 3) * 16 - ORIGIN_Z)
local x1 = NGX + ((MAX_CX + 3) * 16 + 15 - ORIGIN_X)
local z1 = NGZ + ((MAX_CZ + 3) * 16 + 15 - ORIGIN_Z)
local roots = {}
for x = x0, x1 do
	for z = z0, z1 do
		for y = 0, 128 do
			local n = nat(x, y, z)
			if n then fake_map[x .. "," .. (y + NDY) .. "," .. z] = cid(n) end
		end
		-- decoration ABOVE the lava sea: a roots patch on a netherrack
		-- ledge at 40 (every 7th column), so a far-from-seam roots node
		-- sits where the geometry is unchanged
		if (x + z) % 7 == 0 then
			fake_map[x .. "," .. (40 + NDY) .. "," .. z] = cid("mcl_nether:netherrack")
			fake_map[x .. "," .. (41 + NDY) .. "," .. z] = cid("mcl_crimson:crimson_roots")
			roots[#roots + 1] = { x, z }
		end
	end
end

local fp = write_footprint(60, "minecraft:nether_wastes")
run_band_job("nephertest", "nether", NGX, NGZ, NDY, fp)
os.remove(fp)

local merge_cols, bedrock_bad, lava_hi, outer_cols, outer_bad = 0, 0, nil, 0, 0
local changed_cols = 0
for x = x0, x1 do
	for z = z0, z1 do
		local cx = math.floor((x - NGX + ORIGIN_X) / 16)
		local cz = math.floor((z - NGZ + ORIGIN_Z) / 16)
		if not CHUNK_SET[cx .. "," .. cz] then
			merge_cols = merge_cols + 1
			local d = capture_dist(x, z, NGX, NGZ)
			local col_changed = false
			for y = 0, 128 do
				local got = content_name_of[fake_map[x .. "," .. (y + NDY) .. "," .. z]]
				local want = nat(x, y, z)
				if y == 40 and (x + z) % 7 == 0 then want = "mcl_nether:netherrack" end
				if y == 41 and (x + z) % 7 == 0 then want = "mcl_crimson:crimson_roots" end
				if (y <= 4 or y >= 124) and got ~= "mcl_core:bedrock" then bedrock_bad = bedrock_bad + 1 end
				if got == "mcl_nether:nether_lava_source" and (not lava_hi or y > lava_hi) then lava_hi = y end
				if got ~= want then col_changed = true end
				if d >= 33 and got ~= want then outer_bad = outer_bad + 1 end
			end
			if d >= 33 then outer_cols = outer_cols + 1 end
			if col_changed then changed_cols = changed_cols + 1 end
		end
	end
end
check("nether merge rewrote columns near the seam", changed_cols > 0,
	string.format("%d/%d merge columns changed", changed_cols, merge_cols))
check("bedrock floor (0..4) and roof (124..128) rows untouched", bedrock_bad == 0, tostring(bedrock_bad))
check("lava never above the lava sea (source 31)", lava_hi == nil or lava_hi <= 31, tostring(lava_hi))
check("ring outer edge (weight 0) is exactly the generated terrain",
	outer_cols > 0 and outer_bad == 0, string.format("%d bad voxels over %d columns", outer_bad, outer_cols))
-- decoration rule: where the ledge under a roots node is still there
-- and the space above it still open (geometry unchanged), and the
-- generated side dominates (weight < 0.5 -- d >= 24 even with jitter),
-- the roots must survive. (Nearer the seam the capture's higher ground
-- legitimately rises over the ledge and buries it.)
local roots_far, roots_far_kept = 0, 0
local open_ = function(n) return n == nil or n == "mcl_crimson:crimson_roots" end
for _, r in ipairs(roots) do
	local cx = math.floor((r[1] - NGX + ORIGIN_X) / 16)
	local cz = math.floor((r[2] - NGZ + ORIGIN_Z) / 16)
	local at = function(y) return content_name_of[fake_map[r[1] .. "," .. (y + NDY) .. "," .. r[2]]] end
	if not CHUNK_SET[cx .. "," .. cz] and capture_dist(r[1], r[2], NGX, NGZ) >= 24
		and at(40) == "mcl_nether:netherrack" and open_(at(41)) and at(42) == nil then
		roots_far = roots_far + 1
		if at(41) == "mcl_crimson:crimson_roots" then roots_far_kept = roots_far_kept + 1 end
	end
end
check("generated decoration survives where the geometry is unchanged",
	roots_far > 0 and roots_far_kept == roots_far, string.format("%d/%d", roots_far_kept, roots_far))
end
test_6b()

local function test_6c()
print("")
print("=== Test 6c: End 3-D blend (islands meet, outer edge natural) ===")

mock_registered_nodes["mcl_end:end_stone"] = {}

local EDY = -27073               -- Mineclonia's v7 End band (mg_end_min)
local EGX, EGZ = GAP_X, GAP_Z + 12000
-- generated End: Mineclonia's thin island sheets at source 64..67 on a
-- checkerboard of chunks, void elsewhere
local x0 = EGX + ((MIN_CX - 3) * 16 - ORIGIN_X)
local z0 = EGZ + ((MIN_CZ - 3) * 16 - ORIGIN_Z)
local x1 = EGX + ((MAX_CX + 3) * 16 + 15 - ORIGIN_X)
local z1 = EGZ + ((MAX_CZ + 3) * 16 + 15 - ORIGIN_Z)
local function sheet(x, z)
	local cx = math.floor((x - EGX + ORIGIN_X) / 16)
	local cz = math.floor((z - EGZ + ORIGIN_Z) / 16)
	return (cx + cz) % 2 == 0
end
local c_es = content_id_of["mcl_end:end_stone"] or core.get_content_id("mcl_end:end_stone")
for x = x0, x1 do
	for z = z0, z1 do
		if sheet(x, z) then
			for y = 64, 67 do fake_map[x .. "," .. (y + EDY) .. "," .. z] = c_es end
		end
	end
end

local fp = write_footprint(60, "minecraft:the_end")
run_band_job("endtest", "end", EGX, EGZ, EDY, fp)
os.remove(fp)
-- End captures sit END_ISLAND_LIFT (14) above the band key so vanilla
-- island tops (~58) meet Mineclonia's (~72) -- see new_job
local lifted = false
for _, m in ipairs(log_messages) do
	if m.msg:find("endtest: end band, dest_y_offset " .. (EDY + 14), 1, true) then lifted = true end
end
check("End job places at band + 14 (island-top lift)", lifted)

local outer_cols, outer_bad, liquid, below_band = 0, 0, 0, 0
for x = x0, x1 do
	for z = z0, z1 do
		local cx = math.floor((x - EGX + ORIGIN_X) / 16)
		local cz = math.floor((z - EGZ + ORIGIN_Z) / 16)
		if not CHUNK_SET[cx .. "," .. cz] then
			local d = capture_dist(x, z, EGX, EGZ)
			for y = -8, 255 do
				local got = content_name_of[fake_map[x .. "," .. (y + EDY) .. "," .. z]]
				if got and (got:find("water") or got:find("lava")) then liquid = liquid + 1 end
				if y < 0 and got then below_band = below_band + 1 end
				if d >= 33 then
					local want = (sheet(x, z) and y >= 64 and y <= 67) and "mcl_end:end_stone" or nil
					if got ~= want then outer_bad = outer_bad + 1 end
				end
			end
			if d >= 33 then outer_cols = outer_cols + 1 end
		end
	end
end
check("End ring outer edge keeps Mineclonia's own islands exactly",
	outer_cols > 0 and outer_bad == 0, string.format("%d bad voxels over %d columns", outer_bad, outer_cols))
check("End merge writes no liquid", liquid == 0, tostring(liquid))
check("End merge never writes below the band", below_band == 0, tostring(below_band))
end
test_6c()

-- -----------------------------------------------------------------

print("")
if failures == 0 then
	print("ALL CHECKS PASSED")
	os.exit(0)
else
	print(failures .. " CHECK(S) FAILED")
	os.exit(1)
end
