-- prof.lua -- per-phase profiling counters (PLAN-fast-build.md, Phase 0.3).
--
-- Enabled with `spawnimport_profile = true`. Every finished base then logs:
--
--   [prof] <base>: decode_nbt= resolve= post_blocks= vm_read= vm_fill=
--     vm_write= liquids= meta= entities= scan= solve= w_read= w_cols=
--     w_write= g_read= g_deco= g_restore= g_write= audit= gc=
--     heap_peak_mb= rss_peak_mb=
--
-- (seconds per phase; phases beyond the fixed set -- e.g. blend_plan,
-- blend_write for the nether/End 3-D blend -- are appended sorted.)
-- plus:
--
--   [prof-heap] <base>: <phase>=<MB at that phase's boundary> ...
--   [prof-census] <base>: <root>: tables= strs= str_mb= | ...
--
-- `gc=` is the time spent inside every collectgarbage call, so the
-- per-chunk full collections (A10's target) can be judged. The census
-- (after a full collection, at each base boundary) is meant to name the
-- ~3 GB block that PLAN-fast-build 2.5 could not attribute.
--
-- Design notes:
-- * Disabled (the default) the counters are no-ops that return constants,
--   so hot loops stay JIT-friendly and nothing measures itself.
-- * Enabled, `now()`/`since()` use core.get_us_time(); rss is sampled only
--   at GC points and dumps (reading /proc is not free).
-- * The census attributes a shared sub-table to the FIRST root that reaches
--   it (pass roots in suspect order: plan, job, last_gap, registry, ...).

local prof = {}

-- raw global, before any wrapping; also used when disabled
local raw_gc = collectgarbage

local enabled = false
do
	local ok, v = pcall(function() return core.settings:get("spawnimport_profile") end)
	enabled = ok and v == "true"
end

if not enabled then
	function prof.on() return false end
	function prof.now() return 0 end
	function prof.since() return 0 end
	function prof.add() end
	function prof.get() return 0 end
	function prof.gc(...) return raw_gc(...) end
	function prof.begin_job() end
	function prof.dump() end
	function prof.census() return "" end
	return prof
end

-- ------------------------------------------------------------------ live

local acc = {}       -- phase -> microseconds
local heap_at = {}   -- phase -> MB when the phase last recorded
local peak_heap_mb = 0
local rss_peak_mb = 0
local job_name = "-"

local GC_PHASE = "gc"

local function now_us()
	if core.get_us_time then return core.get_us_time() end
	return math.floor(os.clock() * 1e6)
end

local function heap_mb()
	-- "count" does NOT traverse the heap; it is cheap enough per add
	return raw_gc("count") / 1024
end

local function rss_mb()
	-- Linux only (build boxes / VPS); 0 on macOS and in a sandbox without io
	local ok, r = pcall(function()
		local f = io.open("/proc/self/status", "r")
		if not f then return 0 end
		local body = f:read("*a") or ""
		f:close()
		local kb = tonumber(body:match("VmRSS:%s*(%d+)"))
		return kb and kb / 1024 or 0
	end)
	return (ok and type(r) == "number") and r or 0
end

local function note_peaks()
	local h = heap_mb()
	if h > peak_heap_mb then peak_heap_mb = h end
	local r = rss_mb()
	if r > rss_peak_mb then rss_peak_mb = r end
end

function prof.on() return true end

function prof.now() return now_us() end

function prof.since(t) return now_us() - t end

function prof.add(phase, us)
	acc[phase] = (acc[phase] or 0) + us
	local h = heap_mb()
	heap_at[phase] = h
	if h > peak_heap_mb then peak_heap_mb = h end
end

function prof.get(phase) return acc[phase] or 0 end

function prof.gc(...)
	local t = now_us()
	local r = raw_gc(...)
	acc[GC_PHASE] = (acc[GC_PHASE] or 0) + (now_us() - t)
	note_peaks()
	return r
end

function prof.begin_job(name)
	acc, heap_at = {}, {}
	peak_heap_mb, rss_peak_mb = 0, 0
	job_name = name or "-"
end

-- Fixed order = the [prof] line in PLAN-fast-build 0.3; anything else in
-- acc is appended sorted so runs can be diffed mechanically.
local FIXED = {
	"decode_nbt", "resolve", "post_blocks", "vm_read", "vm_fill",
	"vm_write", "liquids", "meta", "entities",
	"scan", "solve",
	"w_read", "w_cols", "w_write",
	"g_read", "g_deco", "g_restore", "g_write",
	"audit", GC_PHASE,
}

local function ordered_phases()
	local out, seen = {}, {}
	for _, ph in ipairs(FIXED) do
		seen[ph] = true
		out[#out + 1] = ph
	end
	local extras = {}
	for ph in pairs(acc) do
		if not seen[ph] then extras[#extras + 1] = ph end
	end
	table.sort(extras)
	for _, ph in ipairs(extras) do out[#out + 1] = ph end
	return out, extras
end

function prof.dump(name)
	local label = name or job_name
	local phases = ordered_phases()
	local parts = {}
	for _, ph in ipairs(phases) do
		parts[#parts + 1] = string.format("%s=%.2f", ph, (acc[ph] or 0) / 1e6)
	end
	note_peaks()
	parts[#parts + 1] = string.format("heap_peak_mb=%.1f", peak_heap_mb)
	parts[#parts + 1] = string.format("rss_peak_mb=%.1f", rss_peak_mb)
	core.log("action", "[prof] " .. tostring(label) .. ": " .. table.concat(parts, " "))

	-- heap at each phase boundary (the server agent's "lua heap" lines)
	local hp = {}
	for _, ph in ipairs(phases) do
		if heap_at[ph] then
			hp[#hp + 1] = string.format("%s=%.0f", ph, heap_at[ph])
		end
	end
	if #hp > 0 then
		core.log("action", "[prof-heap] " .. tostring(label) .. ": " .. table.concat(hp, " "))
	end
end

-- roots: array of { name = <string>, t = <table or nil> }. Shared sub-tables
-- are counted for the first root that reaches them.
function prof.census(roots)
	local seen = {}
	local out = {}
	for _, r in ipairs(roots) do
		local tables, strs, bytes = 0, 0, 0
		local t = r.t
		if type(t) == "table" and not seen[t] then
			seen[t] = true
			local stack = { t }
			while #stack > 0 do
				local v = stack[#stack]
				stack[#stack] = nil
				tables = tables + 1
				for k, val in pairs(v) do
					if type(k) == "string" then
						strs, bytes = strs + 1, bytes + #k
					elseif type(k) == "table" and not seen[k] then
						seen[k] = true
						stack[#stack + 1] = k
					end
					if type(val) == "string" then
						strs, bytes = strs + 1, bytes + #val
					elseif type(val) == "table" and not seen[val] then
						seen[val] = true
						stack[#stack + 1] = val
					end
				end
			end
		end
		out[#out + 1] = string.format("%s: tables=%d strs=%d str_mb=%.1f",
			r.name, tables, strs, bytes / 1048576)
	end
	return table.concat(out, " | ")
end

return prof
