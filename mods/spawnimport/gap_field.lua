-- gap_field.lua -- merged height-field solver for gap-fill.
--
-- PURE module: no `core.*`, no VoxelManip, no Mineclonia names -- runs
-- standalone under luajit (see gap_field_test.lua) as well as inside the
-- spawnimport mod. It solves exactly one problem:
--
--     Given a set of columns to be WRITTEN ("free", each with its natural
--     generated surface height s) and a set of FIXED columns ("pinned":
--     world-download seam targets and untouched natural boundaries),
--     find a height for every free column that
--       (1) meets the pinned columns exactly where pinned,
--       (2) has no slope steeper than `step` blocks per column on any
--           edge between solved columns -- so a player can walk up/down,
--       (3) stays as close to each column's own natural height s as
--           possible -- so real Mineclonia terrain is disturbed as little
--           as possible.
--
-- This is the "merge chunk" core: at a base's border the ring chunk's
-- surface must line up EXACTLY with the world-download terrain at the
-- seam (no step at all -- the old "meet half-way" blend left half the
-- height difference as a cliff at the chunk border), slope gently and
-- invisibly through the chunk, and land on untouched natural terrain at
-- the far edge. When the height difference is too large for the room
-- available, `violations()` reports the unsatisfiable edges and the
-- caller widens the domain into more natural chunks (see gap_fill.plan).
--
-- Columns are keyed "x,z" (absolute block coords); neighbours are the 4
-- orthogonal "x+-1,z" / "x,z+-1" keys.

local field = {}

local DIRS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
field.DIRS = DIRS

function field.key(x, z) return x .. "," .. z end

local function parse_key(k)
	local x, z = k:match("^(-?%d+),(-?%d+)$")
	return tonumber(x), tonumber(z)
end
field.parse_key = parse_key

local function median_of(list)
	table.sort(list)
	local n = #list
	if n == 0 then return nil end
	if n % 2 == 1 then return list[(n + 1) / 2] end
	return (list[n / 2] + list[n / 2 + 1]) / 2
end

-- 3x3 median filter over a "x,z" -> number map. Kills isolated one-column
-- spikes (a misdetected surface -- a floating block that slipped past the
-- floating test, a thin roof the name whitelist missed) without touching
-- genuinely wide features (a cliff affects half of a window, not one
-- cell). Values only change for keys in `s`; missing neighbours are
-- simply not part of the window.
function field.median3(s)
	local out = {}
	for k, v in pairs(s) do
		local x, z = parse_key(k)
		local window = {}
		for dx = -1, 1 do
			for dz = -1, 1 do
				local nv = s[field.key(x + dx, z + dz)]
				if nv then window[#window + 1] = nv end
			end
		end
		out[k] = median_of(window) or v
	end
	return out
end

-- Smooth a 1-D line of target values (in place: returns the new array).
-- Used on world-download seam lines: a single misdetected column in the
-- capture footprint must not leave a one-column spike in the seam the
-- ring has to match exactly.
function field.smooth_line(line, passes)
	for _ = 1, passes or 2 do
		local orig = {}
		for i = 1, #line do orig[i] = line[i] end
		for i = 2, #line - 1 do
			line[i] = (orig[i - 1] + orig[i] + orig[i + 1]) / 3
		end
	end
	return line
end

-- Pin-implied bounds: with slope <= step, a column at graph distance d
-- from a pinned column of height v MUST lie in [v - step*d, v + step*d].
-- Intersecting over all pins gives the tightest possible box [L, U] per
-- column -- and clamp(s, L, U) is already the exact minimal-move answer
-- for smooth natural terrain (the "taut string" shape), so the relaxation
-- in solve() only has to clean up local jumps in s. Computing L/U as a
-- max-plus / min-plus wavefront (queue-propagated) is what makes solve()
-- converge in a few dozen sweeps instead of thousands: the slow global
-- ramp modes are pre-solved here.
--
-- Returns L, U maps ("x,z" -> number). L > U marks a locally infeasible
-- pinch (the pins demand more than the slope cap allows) -- the caller's
-- violations()/widening loop deals with it.
function field.bounds(free, fixed, step)
	step = step or 1.0
	local L, U = {}, {}
	for key in pairs(free) do
		L[key] = -math.huge
		U[key] = math.huge
	end
	for key, v in pairs(fixed) do
		L[key] = v
		U[key] = v
	end
	local queue, queued = {}, {}
	for key in pairs(fixed) do
		queue[#queue + 1] = key
		queued[key] = true
	end
	local head = 1
	while head <= #queue do
		local key = queue[head]
		head = head + 1
		queued[key] = nil
		local x, z = parse_key(key)
		for _, d in ipairs(DIRS) do
			local nkey = field.key(x + d[1], z + d[2])
			if L[nkey] then
				local changed = false
				if L[key] - step > L[nkey] then
					L[nkey] = L[key] - step
					changed = true
				end
				if U[key] + step < U[nkey] then
					U[nkey] = U[key] + step
					changed = true
				end
				if changed and not queued[nkey] then
					queue[#queue + 1] = nkey
					queued[nkey] = true
				end
			end
		end
	end
	return L, U
end

-- Solve for the free-column heights.
--   free : "x,z" -> natural surface height s of a column to write
--   fixed: "x,z" -> imposed height (seam target / untouched boundary)
--   opts : step (default 1.0 -- max slope per column, walkable 45 deg),
--          beta (default 0.15 -- per-sweep pull toward the natural s),
--          omega (default 0.8 -- damped update, kills the period-2 cycle
--                 a full step has around taut ramps),
--          iters (default 60 -- cleanup sweeps after the bounds init)
-- Returns "x,z" -> height for every key in free|fixed.
--
-- Pipeline: pre-solve the global ramp shape with field.bounds() (exact),
-- then run cheap local sweeps of "pull a little toward s, clamp into the
-- slope band" to remove jumps in the natural surface. Earlier versions
-- skipped the bounds pre-solve and relied on the sweeps alone; they
-- converged to smooth-but-slightly-OVER-the-cap harmonics that were
-- stable fixed points (unit tests caught it: slopes hovered ~5% over).
function field.solve(free, fixed, opts)
	local step = (opts and opts.step) or 1.0
	local beta = (opts and opts.beta) or 0.15
	local omega = (opts and opts.omega) or 0.8
	local iters = (opts and opts.iters) or 60
	local L, U = field.bounds(free, fixed, step)
	local h = {}
	for key, v in pairs(fixed) do h[key] = v end
	for key, s in pairs(free) do
		local v = s
		if v < L[key] then v = L[key] elseif v > U[key] then v = U[key] end
		if v < L[key] or v > U[key] then v = (L[key] + U[key]) / 2 end -- L > U pinch
		h[key] = v
	end

	for _ = 1, iters do
		for key, s in pairs(free) do
			local x, z = parse_key(key)
			local v = h[key] + beta * (s - h[key])
			local n, lo, hi = 0, math.huge, -math.huge
			for _, d in ipairs(DIRS) do
				local hv = h[field.key(x + d[1], z + d[2])]
				if hv then
					n = n + 1
					if hv < lo then lo = hv end
					if hv > hi then hi = hv end
				end
			end
			if n > 0 then
				-- slope band intersected with the pin-implied bounds;
				-- empty when the neighbourhood is locally infeasible
				-- (land in the middle and let violations() report it)
				local lower, upper = hi - step, lo + step
				if L[key] > lower then lower = L[key] end
				if U[key] < upper then upper = U[key] end
				if lower > upper then
					lower = (lower + upper) / 2
					upper = lower
				end
				if v < lower then v = lower elseif v > upper then v = upper end
				v = h[key] + omega * (v - h[key])
			end
			h[key] = v
		end
	end
	return h
end

-- Slope check over every edge between solved columns. Returns
--   n_fixable, n_structural, worst
-- where "fixable" edges involve at least one free column (widening the
-- domain can give them room) and "structural" edges are fixed-to-fixed
-- (e.g. two world-download seam columns whose own terrain has a cliff --
-- matched exactly for continuity, deliberately not smoothed away).
function field.violations(free, fixed, h, step)
	step = step or 1.0
	local eps = 1e-6
	local n_fixable, n_structural, worst = 0, 0, 0
	local seen = {}
	for key in pairs(h) do
		if not seen[key] then
			local x, z = parse_key(key)
			for _, d in ipairs(DIRS) do
				local nkey = field.key(x + d[1], z + d[2])
				local hv = h[nkey]
				if hv and not seen[key .. "|" .. nkey] and not seen[nkey .. "|" .. key] then
					seen[key .. "|" .. nkey] = true
					local diff = math.abs(h[key] - hv)
					if diff > step + eps then
						if diff > worst then worst = diff end
						if free[key] or free[nkey] then
							n_fixable = n_fixable + 1
						else
							n_structural = n_structural + 1
						end
					end
				end
			end
		end
	end
	return n_fixable, n_structural, worst
end

-- The columns orthogonally adjacent to the solved domain but not IN it
-- -- "guard" candidates for widening. Returns a set of "x,z" -> true.
function field.frontier(free, fixed)
	local out = {}
	local in_domain = {}
	for key in pairs(free) do in_domain[key] = true end
	for key in pairs(fixed) do in_domain[key] = true end
	for key in pairs(in_domain) do
		local x, z = parse_key(key)
		for _, d in ipairs(DIRS) do
			local nkey = field.key(x + d[1], z + d[2])
			if not in_domain[nkey] then out[nkey] = true end
		end
	end
	return out
end

-- Widening support: which of the FIXED columns are "soft pins" (natural
-- boundary columns pinned to their own s -- they can become free when the
-- domain widens) versus "hard pins" (world-download seam targets). The
-- caller tags them; this just splits them back out.
function field.split_pins(fixed, soft)
	local keep, release = {}, {}
	for key, v in pairs(fixed) do
		if soft[key] then release[key] = v else keep[key] = v end
	end
	return keep, release
end

-- 2-D diagnostics for logs/audit: min/max of the solved heights and the
-- mean |h - s| over free columns (how much natural terrain got moved).
function field.stats(free, h)
	local min_h, max_h, moved, n = math.huge, -math.huge, 0, 0
	for key, s in pairs(free) do
		local v = h[key]
		if v then
			if v < min_h then min_h = v end
			if v > max_h then max_h = v end
			moved = moved + math.abs(v - s)
			n = n + 1
		end
	end
	if n == 0 then return { n = 0 } end
	return { n = n, min_h = min_h, max_h = max_h, mean_move = moved / n }
end

return field
