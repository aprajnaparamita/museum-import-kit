-- Fitting-algorithm placement search (round 25, owner request: "a better
-- way to fit the height and biome to the world download... a fitting
-- algorithm to add them sequentially... ensuring already added bases
-- would not be overwritten").
--
-- Two-phase design (height/water can't be queried standalone -- the real
-- mapgen model needs the running engine, confirmed this round; see
-- HANDOFF.md):
--   Phase 1 (this script, standalone luajit, fast): the EXISTING biome-
--   histogram search from find_biome_placement.lua, extended to keep the
--   top-K candidates (not just the single best) and to skip any
--   candidate overlapping a placement_registry.json entry.
--   Phase 2 (a headless worldmod, zzz_dest_eval -- see that file):
--   evaluates just those K candidates for real land/water compatibility,
--   using an EXHAUSTIVE above-sea-level water scan (the proven signal
--   for the water-intrusion bug class Tactical Nuke actually hit).
--
-- This script only does phase 1 and writes /tmp/dest_eval_candidates.json
-- for phase 2 to consume. Run phase 2's worldmod separately (headless
-- server launch, single-purpose, per this project's established
-- pattern), then run pick_best.py to combine both phases' output into a
-- final recommendation and update placement_registry.json.
--
-- Run from this directory: luajit find_placement.lua <source_biomes_key> <footprint_json_path>
-- Example:
--   luajit find_placement.lua "Tactical Nuke 2023-09" /tmp/tactical_nuke_footprint.json

local LEVELGEN_DIR = os.getenv("HOME") .. "/dev/mineclonia/mods/MAPGEN/mcl_levelgen"
local SEED_STRING = "16532709774040603227"

local function script_dir()
	local source = debug.getinfo(1, "S").source
	return source:match("^@(.*[/\\])") or "./"
end
local HERE = script_dir()

local base_key = arg[1]
local footprint_path = arg[2]
if not base_key or not footprint_path then
	io.stderr:write("usage: luajit find_placement.lua <source_biomes_key> <footprint_json_path>\n")
	os.exit(1)
end

assert(io.open(LEVELGEN_DIR .. "/init.lua", "r"), "can't find mcl_levelgen at " .. LEVELGEN_DIR)
assert(io.open("init.lua", "r"),
	"run this script from inside " .. LEVELGEN_DIR .. " (cwd must be that directory)")

package.path = LEVELGEN_DIR .. "/?.lua;" .. package.path
dofile("init.lua")

local seed = mcl_levelgen.ull(0, 0)
assert(mcl_levelgen.stringtoull(seed, SEED_STRING), "bad seed string")
mcl_levelgen.assign_biome_ids({})
local level = mcl_levelgen.make_overworld_preset(seed)

local sources = dofile("/Volumes/Dara/dev/museum-import-kit/tools/source_biomes.lua")
local src = sources[base_key]
assert(src, "no biome histogram for " .. base_key .. " in tools/source_biomes.lua")
local width, height = src.width, src.height

-- ---------------------------------------------------------------------
-- Minimal standalone JSON reader (registry + footprint dims only need
-- flat/simple structures -- no need for a full JSON library dependency).
-- ---------------------------------------------------------------------
local function read_json_file(path)
	local f = assert(io.open(path, "r"))
	local text = f:read("*a")
	f:close()
	-- Reuse core.parse_json if available (it's not, standalone) --
	-- otherwise a tiny recursive-descent parser, sufficient for this
	-- project's own flat/simple JSON shapes.
	local pos = 1
	local function skip_ws() local _, e = text:find("^%s*", pos); pos = e + 1 end
	local parse_value
	local function parse_string()
		local s, e = text:find('^"(.-)"', pos)
		local raw = text:match('^"(.-)"', pos)
		pos = select(2, text:find('^"(.-)"', pos)) + 1
		return raw
	end
	local function parse_object()
		pos = pos + 1; skip_ws()
		local t = {}
		if text:sub(pos, pos) == "}" then pos = pos + 1; return t end
		while true do
			skip_ws()
			local key = parse_string()
			skip_ws()
			pos = pos + 1 -- ':'
			skip_ws()
			t[key] = parse_value()
			skip_ws()
			local c = text:sub(pos, pos)
			pos = pos + 1
			if c == "}" then return t end
		end
	end
	local function parse_array()
		pos = pos + 1; skip_ws()
		local t = {}
		if text:sub(pos, pos) == "]" then pos = pos + 1; return t end
		while true do
			skip_ws()
			t[#t+1] = parse_value()
			skip_ws()
			local c = text:sub(pos, pos)
			pos = pos + 1
			if c == "]" then return t end
		end
	end
	parse_value = function()
		skip_ws()
		local c = text:sub(pos, pos)
		if c == "{" then return parse_object()
		elseif c == "[" then return parse_array()
		elseif c == '"' then return parse_string()
		elseif text:sub(pos, pos+3) == "true" then pos = pos + 4; return true
		elseif text:sub(pos, pos+4) == "false" then pos = pos + 5; return false
		elseif text:sub(pos, pos+3) == "null" then pos = pos + 4; return nil
		else
			local s, e, num = text:find("^(-?%d+%.?%d*[eE]?[-+]?%d*)", pos)
			pos = e + 1
			return tonumber(num)
		end
	end
	return parse_value()
end

local registry = read_json_file("/Volumes/Dara/dev/museum-import-kit/import_tools/placement_fit/placement_registry.json")

-- origin_x/origin_z (the source-space block coordinate that anchor_x/z
-- maps to) live in museum_manifest.json, not source_biomes.lua -- look
-- up this base's entry there if it already has one (an already-placed
-- base being re-evaluated); a genuinely NEW base being placed for the
-- first time won't have a manifest entry yet, so this falls back to
-- requiring --origin-x/--origin-z on the command line instead.
local origin_x, origin_z
do
	local mf = io.open("/Users/dara/dev/museum-playtest/museum_manifest.json", "r")
	if mf then
		local manifest = read_json_file("/Users/dara/dev/museum-playtest/museum_manifest.json")
		for _, entry in ipairs(manifest) do
			if entry.display_name == base_key then
				origin_x, origin_z = entry.origin_x, entry.origin_z
			end
		end
	end
end
if not origin_x then
	origin_x = tonumber(arg[3]) or error("no origin_x found in manifest for " .. base_key ..
		" -- pass it as a 3rd/4th arg: luajit find_placement.lua <key> <footprint> <origin_x> <origin_z>")
	origin_z = tonumber(arg[4]) or error("origin_z required alongside origin_x")
end
io.stderr:write(string.format("origin_x=%d origin_z=%d\n", origin_x, origin_z))

local function normalize(counts)
	local total = 0
	for _, c in pairs(counts) do total = total + c end
	local frac = {}
	for name, c in pairs(counts) do frac[name] = c / total end
	return frac
end

local function score_histograms(source_frac, dest_counts, dest_total)
	local s = 0
	for name, sfrac in pairs(source_frac) do
		local dcount = dest_counts[name] or 0
		local dfrac = dest_total > 0 and (dcount / dest_total) or 0
		s = s + math.min(sfrac, dfrac)
	end
	return s
end

local SEARCH_X_MIN, SEARCH_X_MAX = -3000, 9000
local SEARCH_Z_MIN, SEARCH_Z_MAX = -3000, 9000
local COARSE_STEP = 250
local SAMPLE_STEP = 200
local Y_SAMPLE = 64
local TOP_K = 8

local function sample_candidate(anchor_x, anchor_z, w, h)
	local counts, total = {}, 0
	for x = anchor_x, anchor_x + w, SAMPLE_STEP do
		for z = anchor_z, anchor_z + h, SAMPLE_STEP do
			local name = level:index_biomes(x, Y_SAMPLE, z)
			counts[name] = (counts[name] or 0) + 1
			total = total + 1
		end
	end
	return counts, total
end

local function boxes_overlap(a, b)
	return a.x_min < b.x_max and a.x_max > b.x_min
		and a.z_min < b.z_max and a.z_max > b.z_min
end

local source_frac = normalize(src.counts)
local candidate_box_fn = function(ax, az) return { x_min = ax, x_max = ax + width, z_min = az, z_max = az + height } end

local top = {} -- array of {score, x, z}, kept sorted descending, capped at TOP_K
local function insert_top(score, x, z)
	local entry = {score = score, x = x, z = z}
	local i = #top + 1
	top[i] = entry
	while i > 1 and top[i-1].score < top[i].score do
		top[i-1], top[i] = top[i], top[i-1]
		i = i - 1
	end
	if #top > TOP_K then top[#top] = nil end
end

local n_skipped_overlap = 0
for ax = SEARCH_X_MIN, SEARCH_X_MAX - width, COARSE_STEP do
	for az = SEARCH_Z_MIN, SEARCH_Z_MAX - height, COARSE_STEP do
		local box = candidate_box_fn(ax, az)
		local overlaps = false
		for _, p in ipairs(registry.placements) do
			if boxes_overlap(box, p.dest_bbox) then overlaps = true; break end
		end
		if overlaps then
			n_skipped_overlap = n_skipped_overlap + 1
		else
			local dest_counts, dest_total = sample_candidate(ax, az, width, height)
			local sc = score_histograms(source_frac, dest_counts, dest_total)
			insert_top(sc, ax, az)
		end
	end
end

io.stderr:write(string.format("searched grid, skipped %d overlapping candidates\n", n_skipped_overlap))
io.stderr:write(string.format("top %d biome-matched candidates for %s:\n", #top, base_key))
for i, t in ipairs(top) do
	io.stderr:write(string.format("  #%d: (%d, %d) biome score %.3f\n", i, t.x, t.z, t.score))
end

local out = io.open("/tmp/dest_eval_params.json", "w")
out:write("{\n")
out:write(string.format('  "footprint_path": %q,\n', footprint_path))
out:write(string.format('  "origin_x": %d,\n', origin_x))
out:write(string.format('  "origin_z": %d,\n', origin_z))
out:write('  "sea_level": 1,\n')
out:write(string.format('  "width": %d,\n  "height": %d,\n', width, height))
out:write('  "candidates": [\n')
for i, t in ipairs(top) do
	if i > 1 then out:write(",\n") end
	out:write(string.format('    {"anchor_x": %d, "anchor_z": %d, "label": "biome_rank_%d_score_%.3f"}',
		t.x, t.z, i, t.score))
end
out:write('\n  ]\n}\n')
out:close()
print("wrote /tmp/dest_eval_params.json (phase 2 input)")
