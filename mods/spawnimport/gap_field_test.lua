#!/usr/bin/env luajit
-- Unit tests for gap_field.lua -- the merged height-field solver.
-- Pure-module tests: no engine, no mock needed.
--
-- Run: luajit mods/spawnimport/gap_field_test.lua   (from the kit root)

local function script_dir()
	local source = debug.getinfo(1, "S").source
	return source:match("^@(.*[/\\])") or "./"
end
local field = dofile(script_dir() .. "gap_field.lua")

local failures = 0
local function check(label, cond, detail)
	if cond then
		print("  ok   " .. label)
	else
		failures = failures + 1
		print("  FAIL " .. label .. (detail and (" -- " .. detail) or ""))
	end
end

-- Build a 1-D strip of free columns x=1..n at natural height `s`,
-- pinned at x=0 and x=n+1. Also mirrored into 2-D (z=0..0) -- the solver
-- is 2-D, a one-cell-wide strip is the simplest real case.
local function strip(n, s, left, right, free_s)
	local free, fixed = {}, {}
	for x = 1, n do
		free[field.key(x, 0)] = (type(free_s) == "function" and free_s(x)) or free_s or s
	end
	fixed[field.key(0, 0)] = left
	fixed[field.key(n + 1, 0)] = right
	return free, fixed
end

print("=== flat merge stays flat ===")
do
	local free, fixed = strip(15, 10, 10, 10)
	local h = field.solve(free, fixed)
	local flat = true
	for k in pairs(free) do
		if math.abs(h[k] - 10) > 0.01 then flat = false end
	end
	check("every column at its natural height", flat)
	local nf = field.violations(free, fixed, h)
	check("zero slope violations", nf == 0, tostring(nf))
end

print("=== seam-exact match + walkable ramp that fits ===")
do
	-- seam target 16 up, 15 free columns of room at step 1:
	-- the ONLY feasible profile is a perfect 45-degree ramp.
	local free, fixed = strip(15, 0, 0, 16)
	local h = field.solve(free, fixed)
	local ok_ramp = true
	for x = 1, 15 do
		if math.abs(h[field.key(x, 0)] - x) > 0.02 then ok_ramp = false end
	end
	check("ramp is exactly 1 block/column (h(x)=x)", ok_ramp)
	check("seam column meets the target exactly", math.abs(h[field.key(16, 0)] - 16) < 1e-9)
	check("outer column stays at natural height", math.abs(h[field.key(0, 0)] - 0) < 1e-9)
	local nf, ns, worst = field.violations(free, fixed, h)
	check("zero violations when the ramp fits", nf == 0 and ns == 0,
		string.format("fixable=%d structural=%d worst=%.2f", nf, ns, worst))
end

print("=== infeasible ramp is REPORTED (widening trigger) ===")
do
	-- 25 blocks up with only 15 columns of room: cannot be walkable.
	-- The solver must clamp as best it can AND violations() must find the
	-- remaining steep edges so gap_fill.plan knows to widen the domain.
	local free, fixed = strip(15, 0, 0, 25)
	local h = field.solve(free, fixed)
	local nf, _ns, worst = field.violations(free, fixed, h)
	check("violations detected", nf >= 1, string.format("fixable=%d worst=%.2f", nf, worst))
	-- the cap is 1 block/column; the un-absorbable shortfall must show up
	-- as at least one edge that is clearly over the cap (how the leftover
	-- is distributed over the edges is the solver's business, only its
	-- REPORTING is the contract).
	check("worst slope clearly over the cap", worst > 1.5, string.format("worst=%.2f", worst))
end

print("=== widening the domain makes it feasible ===")
do
	-- Same 25-block seam target, but 40 columns of room (the widened
	-- case gap_fill.plan produces by pulling in another ring of chunks).
	local free, fixed = strip(40, 0, 0, 25)
	local h = field.solve(free, fixed)
	local nf, ns, worst = field.violations(free, fixed, h)
	check("zero violations with enough room", nf == 0 and ns == 0,
		string.format("fixable=%d structural=%d worst=%.2f", nf, ns, worst))
	local mono = true
	for x = 1, 39 do
		if h[field.key(x + 1, 0)] < h[field.key(x, 0)] - 0.02 then mono = false end
	end
	check("ramp is monotone toward the seam", mono)
	check("seam exact", math.abs(h[field.key(41, 0)] - 25) < 1e-9)
end

print("=== natural terrain disturbed as little as possible ===")
do
	-- Seam 4 up, plenty of room: the ramp should NOT drag the far half of
	-- the chunk up with it -- mean |h - s| over free columns stays small.
	local free, fixed = strip(30, 0, 0, 4)
	local h = field.solve(free, fixed)
	local st = field.stats(free, h)
	check("mean move < 1 block", st.mean_move < 1.0, string.format("mean=%.3f", st.mean_move))
	check("far columns stay near natural height", h[field.key(1, 0)] < 1.5,
		string.format("h(1)=%.2f", h[field.key(1, 0)]))
end

print("=== 2-D: corner seam, no diagonal shortcuts ===")
do
	-- A seam line along x at z=16 (target 8), natural 0 elsewhere.
	-- Every solved column must still respect the slope cap.
	local free, fixed = {}, {}
	for x = 1, 16 do
		for z = 1, 15 do
			free[field.key(x, z)] = 0
		end
		fixed[field.key(x, 16)] = 8
		fixed[field.key(x, 0)] = 0
	end
	local h = field.solve(free, fixed)
	local nf, ns, worst = field.violations(free, fixed, h)
	check("2-D merge is walkable end to end", nf == 0 and ns == 0,
		string.format("fixable=%d structural=%d worst=%.2f", nf, ns, worst))
	local seam_ok = true
	for x = 1, 16 do
		if math.abs(h[field.key(x, 16)] - 8) > 1e-9 then seam_ok = false end
	end
	check("seam line matched exactly", seam_ok)
end

print("=== structural (cliff-in-the-capture) violations are classified ===")
do
	-- Two ADJACENT pinned columns with a cliff between them (the capture's
	-- own terrain has a step at the seam): nothing widening can do, so it
	-- must classify as structural, not fixable.
	local free = {}
	local fixed = { [field.key(1, 0)] = 0, [field.key(2, 0)] = 10 }
	local h = field.solve(free, fixed)
	local nf, ns = field.violations(free, fixed, h)
	check("not counted as fixable", nf == 0, tostring(nf))
	check("counted as structural", ns >= 1, tostring(ns))
end

print("=== median3 kills isolated spikes (floating-block leftovers) ===")
do
	local s = {}
	for x = 1, 5 do
		for z = 1, 5 do
			s[field.key(x, z)] = 10
		end
	end
	s[field.key(3, 3)] = 100 -- one floating block that fooled the column scan
	local out = field.median3(s)
	check("spike removed", math.abs(out[field.key(3, 3)] - 10) < 1e-9,
		string.format("got %.1f", out[field.key(3, 3)]))
	check("neighbours untouched", math.abs(out[field.key(2, 3)] - 10) < 1e-9)

	-- A real cliff (half the window high) survives.
	local s2 = {}
	for x = 1, 5 do
		for z = 1, 5 do
			s2[field.key(x, z)] = x <= 2 and 30 or 10
		end
	end
	local out2 = field.median3(s2)
	check("cliff side heights survive", out2[field.key(1, 3)] == 30 and out2[field.key(5, 3)] == 10,
		string.format("h1=%.1f h5=%.1f", out2[field.key(1, 3)], out2[field.key(5, 3)]))
end

print("=== smooth_line rounds a single bad seam target ===")
do
	local line = { 10, 10, 10, 40, 10, 10, 10 } -- one misdetected footprint column
	field.smooth_line(line, 3)
	check("spike smoothed out", line[4] < 20, string.format("got %.2f", line[4]))
	check("flat parts stay flat", math.abs(line[1] - 10) < 1 and math.abs(line[7] - 10) < 1)
end

print("=== natural surface jumps get smoothed to walkable ===")
do
	-- The bounds pre-solve can't help here: s itself jumps 20 blocks
	-- between adjacent columns (a natural cliff in the ring chunk). The
	-- cleanup sweeps must still deliver slope <= 1 everywhere there is
	-- room (60 columns for a 20-block jump).
	local free, fixed = {}, {}
	for x = 1, 60 do
		free[field.key(x, 0)] = x <= 30 and 0 or 20
	end
	fixed[field.key(0, 0)] = 0
	fixed[field.key(61, 0)] = 20
	local h = field.solve(free, fixed)
	local nf, ns, worst = field.violations(free, fixed, h)
	check("cliff terraced into a walkable slope", nf == 0 and ns == 0,
		string.format("fixable=%d structural=%d worst=%.2f", nf, ns, worst))
	check("plateau heights preserved away from the cliff",
		math.abs(h[field.key(5, 0)]) < 0.5 and math.abs(h[field.key(55, 0)] - 20) < 0.5,
		string.format("h5=%.2f h55=%.2f", h[field.key(5, 0)], h[field.key(55, 0)]))
end

print("=== frontier reports the columns outside the domain ===")
do
	local free = { [field.key(1, 1)] = 0 }
	local fixed = {}
	local fr = field.frontier(free, fixed)
	check("4 orthogonal neighbours found", fr[field.key(0, 1)] and fr[field.key(2, 1)]
		and fr[field.key(1, 0)] and fr[field.key(1, 2)])
	check("diagonals are not frontier", not fr[field.key(0, 0)])
	check("domain itself is not frontier", not fr[field.key(1, 1)])
end

print("")
if failures == 0 then
	print("ALL GAP_FIELD TESTS PASSED")
else
	print(failures .. " GAP_FIELD CHECK(S) FAILED")
	os.exit(1)
end
