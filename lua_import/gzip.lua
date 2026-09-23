-- Gzip decompressor for Minecraft's per-entity ".dat" files (map data,
-- player data, level.dat -- anything NOT a region-file chunk).
--
-- Why this exists separately from anvil.lua's zlib handling: region-file
-- chunks are zlib-WRAPPED deflate (RFC1950, a 2-byte header + deflate
-- stream + 4-byte Adler32 trailer) -- exactly what `core.decompress(data,
-- "deflate")` expects (confirmed by reading Luanti's own C++
-- decompressZlib(), which calls plain zlib `inflateInit()` -- the
-- zlib-wrapped-only initializer, not raw-deflate- or gzip-aware).
-- Minecraft's standalone .dat files (map_<id>.dat, players/*.dat,
-- level.dat) use a DIFFERENT wrapper: gzip (RFC1952, magic bytes 0x1f
-- 0x8b, verified against a real map_*.dat file in this corpus). Luanti's
-- `core.decompress` has no gzip mode at all (only "deflate" and "zstd"
-- per lua_api.md), so region-chunk decompression can't be reused here.
--
-- Since this whole pipeline already requires security disabled (see
-- anvil.lua's own header comment -- reading arbitrary absolute paths off
-- the host filesystem already needs that), LuaJIT's `ffi` library is
-- available the same way it already is for the standalone test harness
-- (lua_import/ffi_zlib_stub.lua uses the identical ffi.load("z")
-- approach for the one-shot zlib `uncompress()` call) -- this module
-- just uses zlib's STREAMING inflate API instead, initialized with
-- windowBits=47 (32 + MAX_WBITS), which tells zlib to auto-detect either
-- a zlib OR a gzip header, so the same code path works for both without
-- needing to hand-parse/strip the gzip header ourselves.

local ok, ffi = pcall(require, "ffi")
if not ok then
	error("gzip.lua requires LuaJIT (for the ffi library)")
end

-- Guarded: this file may be dofile'd several times in one process (the
-- standalone harness loads it directly AND lua_import/mapdata.lua loads
-- it again), and ffi.cdef refuses to redefine a type twice.
if not pcall(ffi.typeof, "z_stream") then
ffi.cdef [[
typedef struct z_stream_s {
	const uint8_t  *next_in;
	unsigned int    avail_in;
	unsigned long   total_in;
	uint8_t        *next_out;
	unsigned int    avail_out;
	unsigned long   total_out;
	const char     *msg;
	void           *state;
	void *(*zalloc)(void *, unsigned int, unsigned int);
	void  (*zfree)(void *, void *);
	void           *opaque;
	int             data_type;
	unsigned long   adler;
	unsigned long   reserved;
} z_stream;

int inflateInit2_(z_stream *strm, int windowBits, const char *version, int stream_size);
int inflate(z_stream *strm, int flush);
int inflateEnd(z_stream *strm);
const char *zlibVersion(void);
]]
end

local z = ffi.load("z")

local Z_OK = 0
local Z_STREAM_END = 1
local Z_FINISH = 4
local Z_NO_FLUSH = 0
local WINDOW_BITS_AUTO = 47 -- 32 + MAX_WBITS(15): auto-detect zlib or gzip header

local gzip = {}

-- Decompresses a gzip- OR zlib-wrapped buffer. Grows the output buffer
-- and re-runs inflate() in a loop (rather than guessing one big-enough
-- size up front) since map .dat files vary in size and this should never
-- need operator-supplied tuning.
function gzip.decompress(data)
	local strm = ffi.new("z_stream")
	local version = z.zlibVersion()
	local ret = z.inflateInit2_(strm, WINDOW_BITS_AUTO, version, ffi.sizeof("z_stream"))
	if ret ~= Z_OK then
		error("gzip.decompress: inflateInit2_ failed with code " .. tostring(ret))
	end

	local src = ffi.new("uint8_t[?]", #data)
	ffi.copy(src, data, #data)
	strm.next_in = src
	strm.avail_in = #data

	local chunks = {}
	local bufsize = 65536
	local buf = ffi.new("uint8_t[?]", bufsize)
	local status
	repeat
		strm.next_out = buf
		strm.avail_out = bufsize
		status = z.inflate(strm, Z_NO_FLUSH)
		if status ~= Z_OK and status ~= Z_STREAM_END then
			z.inflateEnd(strm)
			error("gzip.decompress: inflate failed with code " .. tostring(status)
				.. (strm.msg ~= nil and (" (" .. ffi.string(strm.msg) .. ")") or ""))
		end
		local produced = bufsize - strm.avail_out
		if produced > 0 then
			chunks[#chunks + 1] = ffi.string(buf, produced)
		end
	until status == Z_STREAM_END or (strm.avail_in == 0 and produced == 0)

	z.inflateEnd(strm)
	return table.concat(chunks)
end

return gzip
