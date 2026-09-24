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

-- Slope constraints between two solved columns. Both-underwater edges
-- are exempt (sea floor relief is invisible and real); water-to-LAND
-- edges ARE constrained.
--
-- History: this used to exempt every edge touching water ("the sea
-- floor can be as steep as it likes"). That exemption applied right at
-- the seam too -- free columns kept their natural +24 v7 hills DIRECTLY
-- BESIDE a captured ocean floor at -13: the owner's "raised ocean
-- floor / large square cliffs" (2026-09-24, probes P1/P3). The seam is
-- exactly where the constraint matters most: the goal is that merged
-- columns are always walkable-reachable from the touching world
-- download block. The old "drag whole coastlines to the sea floor /
-- runaway widening" concern is handled by the distance-faded height
-- TARGETS (wgen_inputs.height_target) plus the bounded, only-while-it-
-- helps widening loop -- not by dropping the constraint.
local function edge_ok(a, b, aquatic)
	if not aquatic then return true end
	return not (aquatic[a] and aquatic[b])
end

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
-- opts.aquatic: set of keys whose edges are NOT slope-constrained (see
-- edge_ok above).
-- opts.natural: "x,z" -> the column's own natural surface height. An
--   edge the MERGE did not make steeper than it already was (|h diff| <=
--   |natural diff| + 0.5) is natural relief and is never counted
--   fixable -- otherwise the widening loop chases thousands of natural
--   v7 cliffs it can never fix, concludes "widening doesn't help", and
--   stops early while genuine seam ramps still need room (owner report
--   2026-09-24: a 42-block step left at the seam-transition).
--
-- Returns L, U maps ("x,z" -> number). L > U marks a locally infeasible
-- pinch (the pins demand more than the slope cap allows) -- the caller's
-- violations()/widening loop deals with it.
function field.bounds(free, fixed, opts)
	local step = (opts and opts.step) or 1.0
	local aquatic = opts and opts.aquatic
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
			if L[nkey] and edge_ok(key, nkey, aquatic) then
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
--          iters (default 120 -- cleanup ceiling after the bounds init),
--          aquatic (optional set -- see edge_ok; edges into water are
--                 not slope-constrained)
-- Returns "x,z" -> height for every key in free|fixed.
--
-- Pipeline: pre-solve the global ramp shape with field.bounds() (exact),
-- then run cheap local sweeps of "pull a little toward s, clamp into the
-- slope band" to remove jumps in the natural surface, early-exiting as
-- soon as every constrained edge is within the cap (or the sweeps stop
-- improving things -- natural cliffs settle at small residual steps that
-- only more global smoothing would eat, and that is not worth minutes of
-- server time; violations() classifies those as natural relief anyway).
-- Earlier versions skipped the bounds pre-solve and relied on the sweeps
-- alone; they converged to smooth-but-slightly-OVER-the-cap harmonics
-- that were stable fixed points (unit tests caught it: slopes hovered
-- ~5% over).
function field.solve(free, fixed, opts)
	local step = (opts and opts.step) or 1.0
	local beta = (opts and opts.beta) or 0.15
	local omega = (opts and opts.omega) or 0.8
	local iters = (opts and opts.iters) or 120
	local aquatic = opts and opts.aquatic
	local L, U = field.bounds(free, fixed, { step = step, aquatic = aquatic })
	local h = {}
	for key, v in pairs(fixed) do h[key] = v end
	for key, s in pairs(free) do
		local v = s
		if v < L[key] then v = L[key] elseif v > U[key] then v = U[key] end
		if v < L[key] or v > U[key] then v = (L[key] + U[key]) / 2 end -- L > U pinch
		h[key] = v
	end

	local done = 0
	local prev_worst = math.huge
	while done < iters do
		local batch = math.min(10, iters - done)
		for _ = 1, batch do
			for key, s in pairs(free) do
				local x, z = parse_key(key)
				local v = h[key] + beta * (s - h[key])
				local n, lo, hi = 0, math.huge, -math.huge
				for _, d in ipairs(DIRS) do
					local nkey = field.key(x + d[1], z + d[2])
					local hv = h[nkey]
					if hv and edge_ok(key, nkey, aquatic) then
						n = n + 1
						if hv < lo then lo = hv end
						if hv > hi then hi = hv end
					end
				end
				if n > 0 then
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
		done = done + batch
		-- Early exit: all constrained edges within the cap, or no real
		-- progress any more (natural-cliff stall). The stall metric must
		-- watch FREE-FREE edges only: pin-pinch columns between seam pins
		-- 85 blocks apart can never converge (their bounds box is empty),
		-- and letting those dominate `worst` fired this exit prematurely
		-- while ordinary ramp edges were still violating -- which left
		-- 2-block staircases all over the merge (the owner's "square
		-- cliffs"). Free-free edges are the only degrees of freedom the
		-- iteration can still move.
		local worst = 0
		for key in pairs(free) do
			local x, z = parse_key(key)
			for _, d in ipairs(DIRS) do
				local nkey = field.key(x + d[1], z + d[2])
				if free[nkey] and h[nkey] and key < nkey and edge_ok(key, nkey, aquatic) then
					local diff = math.abs(h[key] - h[nkey])
					if diff > worst then worst = diff end
				end
			end
		end
		if worst <= step + 1e-6 then break end
		if prev_worst - worst < 1e-4 then break end
		prev_worst = worst
	end
	return h
end

-- Slope check over every edge between solved columns. Returns
--   n_fixable, n_structural, worst
--
-- "fixable" violations are ones the merge introduced and widening can
-- still absorb: any edge between a solved (free) column and a PINNED one
-- (a seam target, an outer "stay put" pin, or a guard on untouched
-- terrain) and hard-pin/guard pairs (the ramp can grow outward past a
-- seam pin). Those are exactly the seam-ramp-too-steep cases.
--
-- "structural" violations are deliberately left alone:
--   * cliffs that already exist in the capture between two seam pins
--     (matched exactly for continuity, never smoothed away),
--   * natural relief of the generated terrain itself (free-free, or
--     outer-pin-to-guard) -- that cliff was there before the merge, the
--     merge must not widen away real terrain to erase it. The cleanup
--     sweeps in solve() still terrace such cliffs down to small steps
--     where the column budget allows, which is all "move up/down more
--     easily" can mean without destroying natural terrain.
--
-- kinds (optional): { soft = {key=true}, guard = {key=true},
--                     aquatic = {key=true} } --
-- `fixed` columns not in soft are hard pins (world-download seam
-- targets), `guard` columns are fixed values OUTSIDE the write domain
-- (untouched natural terrain, never written), `aquatic` columns continue
-- as water (below the sea) and their edges are natural sea relief.
function field.violations(free, fixed, h, step, kinds)
	step = step or 1.0
	local eps = 1e-6
	local soft = (kinds and kinds.soft) or {}
	local guard = (kinds and kinds.guard) or {}
	local aquatic = (kinds and kinds.aquatic) or {}
	local function kind(k)
		if aquatic[k] then return "W" end -- water column: no walking there
		if free[k] then return "F" end
		if guard[k] then return "G" end
		if soft[k] then return "S" end
		return "H"
	end
	local function is_fixable(a, b)
		-- both-underwater edges are sea floor relief: real coastlines do
		-- that and nobody walks there. Water-to-LAND edges are fixable
		-- (and now constrained) -- the seam must stay walkable.
		if a == "W" and b == "W" then return false end
		-- free vs any pin: the merge ramp, widen for room
		if (a == "F" and b ~= "F") or (b == "F" and a ~= "F") then return true end
		-- a seam pin against untouched terrain: grow the ramp outward
		if (a == "H" and (b == "S" or b == "G")) or (b == "H" and (a == "S" or a == "G")) then
			return true
		end
		return false
	end
	local natural = (kinds and kinds.natural) or {}
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
						local nk = natural[key]
						local nnv = natural[nkey]
						local natural_relief = nk and nnv
							and diff <= math.abs(nk - nnv) + 0.5
						if not natural_relief and is_fixable(kind(key), kind(nkey)) then
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

-- Post-solve polish: collapse residual 2-block zigzags on FREE-FREE
-- edges. The bounded clamp in solve() lands on midpoint fixed points
-- along a sloped band (a column squeezed between two neighbours one
-- step away settles between them and the neighbours then split around
-- it) -- invisible in the pin-pinch worst-case but it leaves "square"
-- 2-step jogs across hillsides (owner, 2026-09-24: "large square
-- cliffs"). A few Gauss-Seidel passes of "split the excess" converge to
-- <= step wherever a feasible layout exists, WITHOUT touching:
--   * pinned columns (fixed),
--   * edges whose natural relief is already steeper (natural table --
--     the merge must not destroy real cliffs),
--   * both-aquatic edges (sea floor relief),
--   * pin-pinch columns (L > U: no room exists; violations() reports).
-- opts: step, aquatic (set), natural ("x,z" -> natural height),
--       L, U (bounds maps from bounds() -- optional, keeps polish inside
--       the pin-implied envelope).
function field.deflate_steps(free, fixed, h, opts)
	local step = (opts and opts.step) or 1.0
	local eps = 1e-6
	local aquatic = opts and opts.aquatic
	local natural = (opts and opts.natural) or {}
	local L = opts and opts.L
	local U = opts and opts.U
	for _ = 1, 32 do
		local worst = 0
		for key in pairs(free) do
			local x, z = parse_key(key)
			for _, d in ipairs(DIRS) do
				local nkey = field.key(x + d[1], z + d[2])
				if free[nkey] and h[nkey] and key < nkey
						and edge_ok(key, nkey, aquatic) then
					local diff = h[key] - h[nkey]
					local ad = math.abs(diff)
					if ad > step + eps then
						local nk, nv = natural[key], natural[nkey]
						local ndiff = nk and nv and math.abs(nk - nv)
						local natural_relief = ndiff and ndiff > step
							and ad <= ndiff + 1.0
						if not natural_relief then
							local excess = (ad - step) / 2
							local s = diff > 0 and 1 or -1
							local a = h[key] - s * excess
							local b = h[nkey] + s * excess
							if L and U and L[key] <= U[key] then
								a = math.max(L[key], math.min(U[key], a))
							end
							if L and U and L[nkey] <= U[nkey] then
								b = math.max(L[nkey], math.min(U[nkey], b))
							end
							h[key], h[nkey] = a, b
							if ad > worst then worst = ad end
						end
					end
				end
			end
		end
		if worst <= step + eps then break end
	end
	return h
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

-- 2-D diagnostics for logs/audit: min/max of the solved and natural
-- heights plus the mean |h - s| over free columns (how much natural
-- terrain got moved).
function field.stats(free, h)
	local min_h, max_h, min_s, max_s, moved, n = math.huge, -math.huge, math.huge, -math.huge, 0, 0
	for key, s in pairs(free) do
		local v = h[key]
		if v then
			if v < min_h then min_h = v end
			if v > max_h then max_h = v end
			if s < min_s then min_s = s end
			if s > max_s then max_s = s end
			moved = moved + math.abs(v - s)
			n = n + 1
		end
	end
	if n == 0 then return { n = 0 } end
	return { n = n, min_h = min_h, max_h = max_h, min_s = min_s, max_s = max_s, mean_move = moved / n }
end

return field
