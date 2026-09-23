-- Minimal NBT (Named Binary Tag) reader, ported from
-- spawnmasons/import_tools/nbt.py -- see that file for the format
-- reference and spawnmasons/IMPORT_SPEC.md for what's been confirmed
-- against real capture bytes.
--
-- Pure Lua 5.1 (Luanti's minimum), no `core.*`/`minetest.*` calls anywhere
-- in this file -- it only ever receives a plain Lua string to parse. That
-- keeps it usable standalone under `luajit`/`lua5.1` for fast iteration
-- (see test_harness.lua) as well as inside a trusted server mod.
--
-- Values are returned as plain Lua types (number/string/table), same
-- shape as the Python reader: TAG_Compound -> a table keyed by tag name,
-- TAG_List -> an array table, TAG_Byte_Array/TAG_Int_Array -> an array of
-- numbers. The one deliberate divergence from nbt.py: TAG_Long_Array
-- entries are returned as {hi=<uint32>, lo=<uint32>} pairs, not a single
-- Lua number -- Lua 5.1 numbers are doubles and can't exactly represent
-- every 64-bit bit pattern, and the block_states/biomes `data` arrays this
-- project actually reads need exact bits, not an approximate value. See
-- `long_to_number` below for the few places (timestamps) where an
-- approximate single-number value is good enough.

local nbt = {}

local byte = string.byte
local sub = string.sub

local TAG_END = 0
local TAG_BYTE = 1
local TAG_SHORT = 2
local TAG_INT = 3
local TAG_LONG = 4
local TAG_FLOAT = 5
local TAG_DOUBLE = 6
local TAG_BYTE_ARRAY = 7
local TAG_STRING = 8
local TAG_LIST = 9
local TAG_COMPOUND = 10
local TAG_INT_ARRAY = 11
local TAG_LONG_ARRAY = 12

nbt.TAG_END = TAG_END
nbt.TAG_COMPOUND = TAG_COMPOUND

-- ---------------------------------------------------------------------
-- Reader
-- ---------------------------------------------------------------------

local Reader = {}
Reader.__index = Reader

function nbt.new_reader(buf)
	return setmetatable({ buf = buf, pos = 1, len = #buf }, Reader)
end

function Reader:need(n)
	if self.pos + n - 1 > self.len then
		error(string.format(
			"truncated NBT buffer: need %d bytes at pos %d, only %d remain",
			n, self.pos, self.len - self.pos + 1))
	end
end

function Reader:read_ubyte()
	self:need(1)
	local v = byte(self.buf, self.pos)
	self.pos = self.pos + 1
	return v
end

function Reader:read_byte()
	local v = self:read_ubyte()
	if v >= 128 then v = v - 256 end
	return v
end

function Reader:read_ushort()
	self:need(2)
	local b1, b2 = byte(self.buf, self.pos, self.pos + 1)
	self.pos = self.pos + 2
	return b1 * 256 + b2
end

function Reader:read_short()
	local v = self:read_ushort()
	if v >= 32768 then v = v - 65536 end
	return v
end

function Reader:read_uint32()
	self:need(4)
	local b1, b2, b3, b4 = byte(self.buf, self.pos, self.pos + 3)
	self.pos = self.pos + 4
	return ((b1 * 256 + b2) * 256 + b3) * 256 + b4
end

function Reader:read_int()
	local v = self:read_uint32()
	if v >= 2147483648 then v = v - 4294967296 end
	return v
end

-- Returns {hi=<uint32>, lo=<uint32>}, exact. Use this when you need to
-- bit-extract sub-fields (i.e. block_states/biomes `data` longs).
function Reader:read_long_hilo()
	local hi = self:read_uint32()
	local lo = self:read_uint32()
	return { hi = hi, lo = lo }
end

-- Approximate single-number value (double precision -- exact for the
-- realistic range of timestamps/counters this project's NBT actually
-- contains, not guaranteed exact for arbitrary 64-bit values).
function nbt.long_to_number(hilo)
	local hi = hilo.hi
	local signed_hi = hi >= 2147483648 and (hi - 4294967296) or hi
	return signed_hi * 4294967296 + hilo.lo
end

function Reader:read_long()
	return nbt.long_to_number(self:read_long_hilo())
end

function Reader:read_float()
	-- Not needed by anything this project reads (no chunk field used
	-- here is a TAG_Float), but implemented for completeness /
	-- robustness against unexpected tags inside compounds we skip over.
	self:need(4)
	local b1, b2, b3, b4 = byte(self.buf, self.pos, self.pos + 3)
	self.pos = self.pos + 4
	local sign = (b1 >= 128) and -1 or 1
	local exp = (b1 % 128) * 2 + math.floor(b2 / 128)
	local mant = (b2 % 128) * 65536 + b3 * 256 + b4
	if exp == 0 and mant == 0 then return 0.0 end
	return sign * (1 + mant / 8388608) * 2 ^ (exp - 127)
end

function Reader:read_double()
	self:need(8)
	local b1, b2, b3, b4, b5, b6, b7, b8 = byte(self.buf, self.pos, self.pos + 7)
	self.pos = self.pos + 8
	local sign = (b1 >= 128) and -1 or 1
	local exp = (b1 % 128) * 16 + math.floor(b2 / 16)
	local mant = ((((((b2 % 16) * 256 + b3) * 256 + b4) * 256 + b5) * 256 + b6) * 256 + b7) * 256 + b8
	if exp == 0 and mant == 0 then return 0.0 end
	return sign * (1 + mant / 4503599627370496) * 2 ^ (exp - 1023)
end

function Reader:read_bytes(n)
	self:need(n)
	local v = sub(self.buf, self.pos, self.pos + n - 1)
	self.pos = self.pos + n
	return v
end

function Reader:read_string()
	local length = self:read_ushort()
	return self:read_bytes(length)
end

function Reader:read_payload(tag_type)
	if tag_type == TAG_BYTE then
		return self:read_byte()
	elseif tag_type == TAG_SHORT then
		return self:read_short()
	elseif tag_type == TAG_INT then
		return self:read_int()
	elseif tag_type == TAG_LONG then
		return self:read_long()
	elseif tag_type == TAG_FLOAT then
		return self:read_float()
	elseif tag_type == TAG_DOUBLE then
		return self:read_double()
	elseif tag_type == TAG_BYTE_ARRAY then
		local count = self:read_int()
		local out = {}
		for i = 1, count do out[i] = self:read_byte() end
		return out
	elseif tag_type == TAG_STRING then
		return self:read_string()
	elseif tag_type == TAG_LIST then
		local elem_type = self:read_ubyte()
		local count = self:read_int()
		if count < 0 then count = 0 end
		local out = {}
		for i = 1, count do out[i] = self:read_payload(elem_type) end
		return out
	elseif tag_type == TAG_COMPOUND then
		return self:read_compound_body()
	elseif tag_type == TAG_INT_ARRAY then
		local count = self:read_int()
		local out = {}
		for i = 1, count do out[i] = self:read_int() end
		return out
	elseif tag_type == TAG_LONG_ARRAY then
		local count = self:read_int()
		local out = {}
		for i = 1, count do out[i] = self:read_long_hilo() end
		return out
	else
		error(string.format("unknown tag type %d at pos %d", tag_type, self.pos))
	end
end

function Reader:read_compound_body()
	local out = {}
	while true do
		local tag_type = self:read_ubyte()
		if tag_type == TAG_END then
			return out
		end
		local name = self:read_string()
		out[name] = self:read_payload(tag_type)
	end
end

function Reader:read_named_root()
	local tag_type = self:read_ubyte()
	if tag_type == TAG_END then
		error("empty NBT buffer (root tag is TAG_End)")
	end
	local name = self:read_string()
	local payload = self:read_payload(tag_type)
	return tag_type, name, payload
end

-- Parse a single root NBT compound from an already-decompressed buffer.
-- Returns the root compound's payload table (the root tag's own name,
-- usually "", is discarded -- callers never need it), matching
-- nbt.py's parse_buffer().
function nbt.parse_buffer(data)
	local reader = nbt.new_reader(data)
	local tag_type, _name, payload = reader:read_named_root()
	if tag_type ~= TAG_COMPOUND then
		error(string.format("expected root TAG_Compound, got tag type %d", tag_type))
	end
	return payload
end

return nbt
