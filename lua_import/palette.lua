-- Minecraft block name+properties -> Mineclonia node name resolver.
-- Lua port of spawnmasons/import_tools/palette.py -- see that file's
-- docstring for the full rationale of the 4-tier design (exact / family /
-- color / default). This file must stay behaviorally identical to it;
-- spawnmasons/lua_import/test_harness.lua diffs the two against real
-- capture data to catch drift.
--
-- Data (colors, exact-name table, etc.) comes from data.lua, generated
-- from mc_to_mcl.json by import_tools/gen_lua_data.py -- edit that JSON
-- and regenerate, don't hand-edit data.lua.

-- debug.getinfo is unavailable in a sandboxed Luanti mod environment; see
-- the matching comment in anvil.lua -- this is only reachable standalone
-- or with security disabled.
local function script_dir()
	local source = debug.getinfo(1, "S").source
	return source:match("^@(.*[/\\])") or "./"
end

local _dofile = _G.__spawnimport_dofile or dofile
local DATA = _dofile((_G.__spawnimport_lua_import_path or script_dir()) .. "data.lua")

local palette = {}

local COLORS = DATA.colors
local SHULKER_COLORS = DATA.shulker_colors
local WOOD_SPECIES = DATA.wood_species
local STAIR_SLAB_SUBNAME = DATA.stair_slab_subname
local WALL_SUBNAME = DATA.wall_subname
local HEAD_NAME = DATA.head_name
local EXACT = DATA.exact
local SMOOTH_STONE_SLAB = DATA.smooth_stone_slab
local SPECIAL = DATA.special

palette.DEFAULT_NODE = "mcl_core:stone"

-- ---------------------------------------------------------------------
-- Resolution result
-- ---------------------------------------------------------------------

local function Resolution(node, tier, detail, param2)
	return { node = node, tier = tier, detail = detail, param2 = param2 or 0 }
end
palette.Resolution = Resolution

-- param2 (orientation) for paramtype2="facedir" nodes -- see the matching,
-- more detailed comment in import_tools/palette.py (this must stay
-- behaviorally identical to it).
local FACING_TO_FACEDIR = { south = 0, east = 1, north = 2, west = 3 }
local AXIS_TO_LOG_PARAM2 = { y = 0, x = 12, z = 6 }

local function stair_param2(props)
	local base = FACING_TO_FACEDIR[props.facing] or 0
	if props.half == "top" then
		base = base + 20
		if base == 21 then
			base = 23
		elseif base == 23 then
			base = 21
		end
	end
	return base
end

-- param2 for paramtype2="wallmounted" and the other orientation schemes
-- (lever's 6d facedir, shulker box, hoppers) -- see the matching, more
-- detailed comment in import_tools/palette.py (must stay behaviorally
-- identical to it).
local FACING_TO_WALLMOUNTED = { north = 4, south = 5, east = 3, west = 2 }
-- mcl_signs' wall-sign on_place (mods/ITEMS/mcl_signs/init.lua's
-- sign_tpl.on_place) computes its own param2 from
-- core.dir_to_wallmounted(vector.subtract(under, above)) -- i.e. the
-- direction INTO the wall the sign is attached to, not the direction the
-- sign/text faces the viewer (which is what Minecraft's "facing" property
-- and FACING_TO_WALLMOUNTED above both represent).
--
-- 2026-09-17 owner live-verification (signs in museum-playtest at
-- ~464,66,1957 were flipped wrong): the "invert FACING_TO_WALLMOUNTED"
-- approach that produced this table was WRONG. The actual convention
-- for signs is the same as for every other wallmounted block here --
-- the dir_to_wallmounted formula applied to under-above gives the
-- same values as dir_to_wallmounted applied to facing for the four
-- compass cases (the sign on the south face of a north-wall has the
-- same param2 as a torch on the south face of a north-wall: 0).
-- The previous inversion made Lua and Python *agree with each other*,
-- which is why test_harness.lua passed -- but neither matched reality.
-- This is now a NOT live-verified fix until the next rebuild round;
-- this comment exists to prevent repeating the inversion trap.
local SIGN_FACING_TO_WALLMOUNTED = FACING_TO_WALLMOUNTED
local VINE_SIDE_TO_WALLMOUNTED = { north = 5, south = 4, east = 2, west = 3 }
-- Derived directly from Mineclonia's OWN wallmounted_to_faces() in
-- mods/ITEMS/mcl_core/nodes_glow_lichen.lua (not re-derived from the
-- signlike mesh-rotation math the way SHULKER_FACING_TO_WALLMOUNTED was --
-- glow_lichen is drawtype="nodebox", a different drawtype from sculk_vein's
-- "signlike", so that derivation does not transfer). That function maps
-- param2==4->north, 5->south, 2->east, 3->west, 0->up, else->down, i.e. the
-- inverse mapping used here. Note north/south are swapped relative to
-- SHULKER_FACING_TO_WALLMOUNTED (which has south=4,north=5) -- confirmed by
-- reading the real source, not assumed to match by analogy.
local GLOW_LICHEN_FACE_TO_WALLMOUNTED = { up = 0, down = 1, east = 2, west = 3, north = 4, south = 5 }
local LEVER_WALL_FACING_TO_FACEDIR = { north = 0, south = 2, east = 3, west = 1 }
local LEVER_FLOOR_PARAM2 = 13
local LEVER_CEILING_PARAM2 = 15
local HOPPER_FACING_TO_PARAM2 = { south = 1, east = 2, north = 3, west = 0 }
local SHULKER_FACING_TO_WALLMOUNTED = { up = 0, down = 1, east = 2, west = 3, south = 4, north = 5 }

-- ---------------------------------------------------------------------
-- Literal node validation set (tier 2)
-- ---------------------------------------------------------------------

local LITERAL_NODES = {}
for _, n in ipairs(DATA.literal_nodes) do
	LITERAL_NODES[n] = true
end

local WOOD_SPECIES_SET = {}
for _, s in ipairs(WOOD_SPECIES) do
	WOOD_SPECIES_SET[s] = true
end

-- Some wood species have a Mineclonia internal species key that differs
-- from the Minecraft block-name prefix used to detect them (found live
-- 2026-09-18, owner: "trees are still stone" -- a cherry blossom tree).
-- Minecraft's real prefix is "cherry_" (cherry_log, cherry_leaves, ...)
-- but mods/ITEMS/mcl_cherry_blossom/init.lua registers it via
-- mcl_trees.register_wood("cherry_blossom", {...}) -- confirmed by
-- reading that file directly -- so every generated node
-- (mcl_trees:tree_cherry_blossom, :leaves_cherry_blossom, etc., plus
-- stairs/slabs via the same register_wood call) uses "cherry_blossom",
-- not "cherry". WOOD_SPECIES must still list "cherry" (that's the real
-- Minecraft-side prefix every generic handler below matches against);
-- this alias only substitutes the OUTPUT suffix.
local SPECIES_MCL_KEY = { cherry = "cherry_blossom" }
local function mcl_species_key(s)
	return SPECIES_MCL_KEY[s] or s
end

-- ---------------------------------------------------------------------
-- Tier 1: exact (source-verified)
-- ---------------------------------------------------------------------

-- Ordered longest-suffix-first, same as palette.py's _COLOR_SUFFIXES.
local COLOR_SUFFIXES = {
	{ "_stained_glass_pane", function(mc) return "mcl_panes:pane_" .. COLORS[mc] end },
	{ "_glazed_terracotta", function(mc) return "mcl_colorblocks:glazed_terracotta_" .. COLORS[mc] end },
	{ "_concrete_powder", function(mc) return "mcl_colorblocks:concrete_powder_" .. COLORS[mc] end },
	{ "_stained_glass", function(mc) return "mcl_core:glass_" .. COLORS[mc] end },
	{ "_terracotta", function(mc) return "mcl_colorblocks:hardened_clay_" .. COLORS[mc] end },
	{ "_concrete", function(mc) return "mcl_colorblocks:concrete_" .. COLORS[mc] end },
	{ "_carpet", function(mc) return "mcl_wool:" .. COLORS[mc] .. "_carpet" end },
	{ "_wool", function(mc) return "mcl_wool:" .. COLORS[mc] end },
}

local function ends_with(s, suffix)
	return #s >= #suffix and s:sub(#s - #suffix + 1) == suffix
end

local function strip_suffix(s, suffix)
	return s:sub(1, #s - #suffix)
end

local function starts_with(s, prefix)
	return s:sub(1, #prefix) == prefix
end

local function resolve_slab_single(material)
	if material == "smooth_stone" then
		return SMOOTH_STONE_SLAB
	end
	if material == "petrified_oak" then
		return "mcl_stairs:slab_oak" -- documented fallback, see mc_to_mcl.json unmapped_known_gaps
	end
	local sub = STAIR_SLAB_SUBNAME[material]
	if sub then
		return "mcl_stairs:slab_" .. sub
	end
	return nil
end

local function resolve_wood_family(base)
	-- Bare `<species>_wood` and `stripped_<species>_*` variants don't start
	-- with `<species>_` (stripped_<species>_log/wood start with "stripped_",
	-- and <species>_wood is in fact caught by the species-prefix check
	-- below as rest="wood", but only because the prefix is the species --
	-- covered here for completeness, not separately). All four are real
	-- Mineclonia nodes registered per-species by mcl_trees.register_wood
	-- (mods/ITEMS/mcl_trees/api.lua lines ~408-450): tree_<s> = bark on
	-- sides, rings on top; bark_<s> = bark on all sides; stripped_<s> =
	-- stripped bark on sides, rings on top; bark_stripped_<s> = stripped
	-- bark on all sides. This matches Minecraft's four-block wood family
	-- exactly.
	for _, s in ipairs(WOOD_SPECIES) do
		local prefix = s .. "_"
		if starts_with(base, prefix) then
			local rest = base:sub(#prefix + 1)
			local mcl_s = mcl_species_key(s)
			if rest == "log" then return "mcl_trees:tree_" .. mcl_s end
			if rest == "wood" then return "mcl_trees:bark_" .. mcl_s end
			if rest == "planks" then return "mcl_trees:wood_" .. mcl_s end
			if rest == "leaves" then return "mcl_trees:leaves_" .. mcl_s end
			if rest == "sapling" then return "mcl_trees:sapling_" .. mcl_s end
			if rest == "fence" then return "mcl_fences:" .. mcl_s .. "_fence" end
			if rest == "fence_gate" then return "mcl_fences:" .. mcl_s .. "_fence_gate" end
			-- door/trapdoor handled separately (door_family_base /
			-- trapdoor_family_base) -- see palette.py's matching comment.
		end
	end
	-- stripped_<species>_log/wood: doesn't start with `<s>_` so the above
	-- prefix check misses it. Handle separately (mods/ITEMS/mcl_trees/api.lua
	-- register_wood's stripped/stripped_bark cases produce these nodes).
	if starts_with(base, "stripped_") then
		for _, s in ipairs(WOOD_SPECIES) do
			local mcl_s = mcl_species_key(s)
			if base == "stripped_" .. s .. "_log" then
				return "mcl_trees:stripped_" .. mcl_s
			end
			if base == "stripped_" .. s .. "_wood" then
				return "mcl_trees:bark_stripped_" .. mcl_s
			end
		end
	end
	return nil
end

local function door_family_base(base)
	if base == "iron_door" then return "mcl_doors:iron_door" end
	for _, s in ipairs(WOOD_SPECIES) do
		if base == s .. "_door" then return "mcl_doors:door_" .. mcl_species_key(s) end
	end
	return nil
end

local function trapdoor_family_base(base)
	if base == "iron_trapdoor" then return "mcl_doors:iron_trapdoor" end
	for _, s in ipairs(WOOD_SPECIES) do
		if base == s .. "_trapdoor" then return "mcl_doors:trapdoor_" .. mcl_species_key(s) end
	end
	return nil
end

local function resolve_head(base)
	for full, short in pairs(HEAD_NAME) do
		if base == full .. "_head" or base == full .. "_skull" then
			return "mcl_heads:" .. short
		end
		if base == full .. "_wall_head" or base == full .. "_wall_skull" then
			return "mcl_heads:" .. short .. "_wall"
		end
	end
	return nil
end

local function format_template(tpl, key, value)
	-- tpl looks like "{slab}_top" -- replace "{<key>}" with value.
	return (tpl:gsub("{" .. key .. "}", value))
end

local function tier1(base, props)
	if ends_with(base, "_slab") then
		local single = resolve_slab_single(strip_suffix(base, "_slab"))
		if single then
			local slab_type = props.type or "bottom"
			local tpl = SPECIAL.slab_type[slab_type] or "{slab}"
			local target = format_template(tpl, "slab", single)
			return Resolution(target, "exact", "slab type=" .. slab_type)
		end
	end

	if ends_with(base, "_stairs") then
		local sub = STAIR_SLAB_SUBNAME[strip_suffix(base, "_stairs")]
		if sub then
			local shape = props.shape or "straight"
			local suffix = ""
			if shape == "inner_left" or shape == "inner_right" then
				suffix = "_inner"
			elseif shape == "outer_left" or shape == "outer_right" then
				suffix = "_outer"
			end
			return Resolution("mcl_stairs:stair_" .. sub .. suffix, "exact",
				"stair material lookup, shape=" .. shape .. " facing=" .. tostring(props.facing)
				.. " half=" .. tostring(props.half),
				stair_param2(props))
		end
	end

	if ends_with(base, "_wall") and not ends_with(base, "_wall_banner") then
		-- Blackstone- and Deepslate-family walls don't follow the simple
		-- mcl_walls:<subname> pattern (mcl_blackstone/init.lua registers
		-- them as `mcl_blackstone:<subname>` where subname is wall,
		-- polishedwall, or polishedbrickwall; mcl_deepslate/deepslate.lua's
		-- register_variants registers them as `mcl_deepslate:deepslate_
		-- <variant>wall` with the variant suffix appended before "wall",
		-- not a separate subname table). Handle these specially here so the
		-- common wall_subname path stays simple.
		if base == "blackstone_wall" then
			return Resolution("mcl_blackstone:wall", "exact", "wall material lookup")
		end
		if base == "polished_blackstone_wall" then
			return Resolution("mcl_blackstone:polishedwall", "exact", "wall material lookup")
		end
		if base == "polished_blackstone_brick_wall" then
			return Resolution("mcl_blackstone:polishedbrickwall", "exact", "wall material lookup")
		end
		if base == "cobbled_deepslate_wall" then
			-- mcl_deepslate/deepslate.lua register_variants does
			-- `mcl_walls.register_wall("mcl_deepslate:"..defs.basename..name.."wall", ...)`
			-- with defs.basename = "deepslate" and name = "cobbled" -- NO underscore
			-- between them, so the result is "deepslatecobbledwall", not
			-- "deepslate_cobbledwall". Confirmed by dump of core.registered_nodes.
			return Resolution("mcl_deepslate:deepslatecobbledwall", "exact", "wall material lookup")
		end
		if base == "polished_deepslate_wall" then
			-- Same naming pattern as cobbled_deepslate_wall (see comment there) --
			-- basename+variant concatenated without an underscore separator.
			return Resolution("mcl_deepslate:deepslatepolishedwall", "exact", "wall material lookup")
		end
		if base == "deepslate_brick_wall" then
			return Resolution("mcl_deepslate:deepslatebrickswall", "exact", "wall material lookup")
		end
		if base == "deepslate_tile_wall" then
			return Resolution("mcl_deepslate:deepslatetileswall", "exact", "wall material lookup")
		end
		local sub = WALL_SUBNAME[strip_suffix(base, "_wall")]
		if sub then
			return Resolution("mcl_walls:" .. sub, "exact", "wall material lookup")
		end
	end

	local door_base = door_family_base(base)
	if door_base then
		local facing = props.facing
		local half = props.half
		local hinge = props.hinge or "left"
		local is_open = props.open == "true"
		local base_param2 = FACING_TO_FACEDIR[facing] or 0
		local door_dir = (hinge == "left") and "1" or "2"
		local param2 = base_param2
		if is_open then
			door_dir = (door_dir == "1") and "2" or "1"
			param2 = (base_param2 + 1) % 4
		end
		local half_letter = (half == "upper") and "t" or "b"
		local node = door_base .. "_" .. half_letter .. "_" .. door_dir
		return Resolution(node, "exact",
			"door facing=" .. tostring(facing) .. " half=" .. tostring(half)
			.. " hinge=" .. tostring(hinge) .. " open=" .. tostring(is_open),
			param2)
	end

	local trapdoor_base = trapdoor_family_base(base)
	if trapdoor_base then
		local node = trapdoor_base
		if props.open == "true" then node = node .. "_open" end
		return Resolution(node, "exact",
			"trapdoor facing=" .. tostring(props.facing) .. " half=" .. tostring(props.half)
			.. " open=" .. tostring(props.open),
			stair_param2(props))
	end

	if ends_with(base, "_fence_gate") then
		local s = strip_suffix(base, "_fence_gate")
		if WOOD_SPECIES_SET[s] then
			local param2 = FACING_TO_FACEDIR[props.facing] or 0
			return Resolution("mcl_fences:" .. s .. "_fence_gate", "exact",
				"fence_gate facing=" .. tostring(props.facing), param2)
		end
	end

	local wood = resolve_wood_family(base)
	if wood then
		local param2 = 0
		if starts_with(wood, "mcl_trees:tree_") then
			param2 = AXIS_TO_LOG_PARAM2[props.axis or "y"] or 0
		end
		return Resolution(wood, "exact", "wood species family, axis=" .. tostring(props.axis), param2)
	end

	local head = resolve_head(base)
	if head then
		if ends_with(head, "_wall") then
			local param2 = FACING_TO_WALLMOUNTED[props.facing] or 4
			return Resolution(head, "exact", "mob head lookup, facing=" .. tostring(props.facing), param2)
		end
		local rotation = math.floor(tonumber(props.rotation) or 0) % 16
		return Resolution(head, "exact", "mob head lookup, rotation=" .. rotation, rotation * 15)
	end

	if ends_with(base, "_wall_banner") then
		local param2 = FACING_TO_WALLMOUNTED[props.facing] or 4
		return Resolution("mcl_banners:hanging_banner", "exact",
			"wall banner facing=" .. tostring(props.facing) .. " (color/pattern lost -- entity-driven, not param2)",
			param2)
	end
	if ends_with(base, "_banner") then
		return Resolution("mcl_banners:standing_banner", "exact",
			"banner (color/rotation/pattern is entity+metadata, not the node name or param2)")
	end

	if ends_with(base, "_glazed_terracotta") then
		local color_part = strip_suffix(base, "_glazed_terracotta")
		if COLORS[color_part] then
			local param2 = FACING_TO_FACEDIR[props.facing] or 0
			return Resolution("mcl_colorblocks:glazed_terracotta_" .. COLORS[color_part], "exact",
				"glazed_terracotta facing=" .. tostring(props.facing), param2)
		end
	end

	for _, entry in ipairs(COLOR_SUFFIXES) do
		local suffix, fn = entry[1], entry[2]
		if ends_with(base, suffix) then
			local color_part = strip_suffix(base, suffix)
			if COLORS[color_part] then
				return Resolution(fn(color_part), "exact", "color family (" .. suffix .. ")")
			end
		end
	end

	if ends_with(base, "_shulker_box") then
		local color_part = strip_suffix(base, "_shulker_box")
		if SHULKER_COLORS[color_part] then
			local param2 = SHULKER_FACING_TO_WALLMOUNTED[props.facing] or 0
			-- Target the "_small" variant directly, not the placeholder
			-- "_shulker_box" node. The placeholder has no on_rightclick --
			-- it only becomes interactive when the engine's on_construct
			-- callback swaps it to "_small", and VoxelManip bulk placement
			-- never fires on_construct. Placing "_small" directly makes it
			-- openable immediately (find_or_create_entity lazily creates
			-- the visual entity on first right-click either way).
			return Resolution(
				"mcl_chests:" .. SHULKER_COLORS[color_part] .. "_shulker_box_small",
				"exact",
				"shulker box color family, facing=" .. tostring(props.facing) .. " (see mc_to_mcl.json)",
				param2)
		end
	end

	if ends_with(base, "_bed") then
		local color_part = strip_suffix(base, "_bed")
		if COLORS[color_part] then
			local bed_base = "mcl_beds:bed_" .. COLORS[color_part]
			local part = props.part or "foot"
			local tpl = SPECIAL.bed_part[part] or "{bed}_bottom"
			return Resolution(format_template(tpl, "bed", bed_base), "exact", "bed part=" .. part)
		end
	end

	if base == "furnace" then
		local lit = tostring(props.lit or "false")
		local target = SPECIAL.furnace_lit[lit] or "mcl_furnaces:furnace"
		local param2 = FACING_TO_FACEDIR[props.facing] or 0
		return Resolution(target, "exact", "furnace lit=" .. lit .. " facing=" .. tostring(props.facing), param2)
	end

	if base == "water" or base == "lava" then
		-- See the matching, more detailed comment in import_tools/palette.py
		-- (must stay behaviorally identical to it).
		local level = tonumber(props.level) or 0
		if level == 0 then
			return Resolution("mcl_core:" .. base .. "_source", "exact", base .. " level=0 (source)")
		end
		local amount = level % 8
		local param2 = 7 - amount
		return Resolution("mcl_core:" .. base .. "_flowing", "exact", base .. " level=" .. level, param2)
	end

	if base == "chest" or base == "trapped_chest" or base == "ender_chest" then
		local param2 = FACING_TO_FACEDIR[props.facing] or 0
		return Resolution(EXACT[base], "exact", base .. " facing=" .. tostring(props.facing), param2)
	end

	if base == "vine" then
		local param2 = 0
		local chosen = "none"
		for _, side in ipairs({ "north", "south", "east", "west" }) do
			if props[side] == "true" then
				chosen = side
				param2 = VINE_SIDE_TO_WALLMOUNTED[side]
				break
			end
		end
		return Resolution(EXACT[base], "exact",
			"vine sides n=" .. tostring(props.north) .. " s=" .. tostring(props.south)
			.. " e=" .. tostring(props.east) .. " w=" .. tostring(props.west)
			.. ", using '" .. chosen .. "' (best-effort: Mineclonia vine is single-direction only)",
			param2)
	end

	if base == "torch" then
		-- 2026-09-19 owner report: floor torches rendering upside-down.
		-- mcl_torches:torch is drawtype="mesh" (mods/ITEMS/mcl_torches/
		-- api.lua), a DIFFERENT drawtype from signlike/nodebox (see the
		-- sculk_vein/glow_lichen fixes above -- their derivations don't
		-- transfer here), but its own on_place computes `wdir =
		-- core.dir_to_wallmounted(under-above)` and only ever selects
		-- this floor node when wdir == 1, then places it with
		-- `core.item_place_node(fakestack, placer, pointed_thing,
		-- wdir)` -- i.e. a REAL, natively-placed floor torch always has
		-- param2 == 1, never 0. The bare EXACT mapping here had no
		-- special case at all, silently defaulting param2 to 0 -- which
		-- per drawMeshNode's generic wallmounted->facedir conversion
		-- renders the torch's mesh upside-down. Force 1, matching what
		-- real placement always produces (verified from the node's own
		-- on_place, not guessed).
		return Resolution(EXACT[base], "exact", "torch (floor, forced param2=1)", 1)
	end

	if base == "wall_torch" or base == "ladder" then
		local param2 = FACING_TO_WALLMOUNTED[props.facing] or 4
		return Resolution(EXACT[base], "exact", base .. " facing=" .. tostring(props.facing), param2)
	end

	if base == "stone_button" or (ends_with(base, "_button") and WOOD_SPECIES_SET[strip_suffix(base, "_button")]) then
		-- Generic per-species button: mods/ITEMS/REDSTONE/mcl_buttons/init.lua
		-- registers one node pair per (species,stone,polished_blackstone) via
		-- mcl_buttons.register_button(<basename>, ...) which produces
		-- "mcl_buttons:button_<basename>_off" / "_on". mcl_trees/api.lua
		-- calls this once per WOOD_SPECIES. Special-case stone_button for
		-- parity with the original flat mapping (no _species suffix on the
		-- Mineclonia side either; mcl_buttons:button_stone_off).
		-- Param2 handling: wallmounted (under-above mirror, same convention
		-- as wall_torch) for the wall face; floor/ceiling have no rotation
		-- support at all in Mineclonia, so MC's "facing" is unrepresentable
		-- there -- only "face" (which of the 3 base orientations) matters.
		local face = props.face or "wall"
		local param2
		if face == "floor" then
			param2 = 1
		elseif face == "ceiling" then
			param2 = 0
		else
			param2 = FACING_TO_WALLMOUNTED[props.facing] or 4
		end
		local target, detail
		if base == "stone_button" then
			target = "mcl_buttons:button_stone_off"
			detail = "button face=" .. face .. " facing=" .. tostring(props.facing)
		else
			local species = strip_suffix(base, "_button")
			target = "mcl_buttons:button_" .. mcl_species_key(species) .. "_off"
			detail = "button (" .. species .. ") face=" .. face .. " facing=" .. tostring(props.facing)
		end
		return Resolution(target, "exact", detail, param2)
	end

	if ends_with(base, "_pressure_plate") then
		-- Generic per-species pressure plate (mods/ITEMS/REDSTONE/
		-- mcl_pressureplates/init.lua + mcl_trees/api.lua's per-species
		-- register_pressure_plate call): produces
		-- "mcl_pressureplates:pressure_plate_<basename>_off" / "_on". Covers
		-- any wood species as well as the four hand-rolled special cases
		-- (stone / light_weighted / heavy_weighted) that were already in
		-- the exact table -- one handler for all five families. No param2
		-- distinction is needed for any of them (all plain nodes, all
		-- powered state expressed as _on/_off node name swap, same as the
		-- existing flat mapping).
		local species = strip_suffix(base, "_pressure_plate")
		local target, detail
		if WOOD_SPECIES_SET[species] then
			target = "mcl_pressureplates:pressure_plate_" .. mcl_species_key(species) .. "_off"
			detail = "pressure_plate (" .. species .. ")"
		elseif species == "stone" then
			target = "mcl_pressureplates:pressure_plate_stone_off"
			detail = "pressure_plate (stone)"
		elseif species == "light_weighted" then
			target = "mcl_pressureplates:pressure_plate_light_off"
			detail = "pressure_plate (light_weighted)"
		elseif species == "heavy_weighted" then
			target = "mcl_pressureplates:pressure_plate_heavy_off"
			detail = "pressure_plate (heavy_weighted)"
		end
		if target then
			return Resolution(target, "exact", detail, 0)
		end
	end

	if base == "lever" then
		local face = props.face or "wall"
		local param2
		if face == "floor" then
			param2 = LEVER_FLOOR_PARAM2
		elseif face == "ceiling" then
			param2 = LEVER_CEILING_PARAM2
		else
			param2 = LEVER_WALL_FACING_TO_FACEDIR[props.facing] or 0
		end
		local powered = props.powered == "true"
		local target = powered and "mcl_lever:lever_on" or "mcl_lever:lever_off"
		return Resolution(target, "exact",
			"lever face=" .. face .. " facing=" .. tostring(props.facing) .. " powered=" .. tostring(powered), param2)
	end

	if base == "hopper" then
		local facing = props.facing or "down"
		local enabled = (props.enabled or "true") == "true"
		local node, param2
		if facing == "down" then
			node = enabled and "mcl_hoppers:hopper" or "mcl_hoppers:hopper_disabled"
			param2 = 0
		else
			node = enabled and "mcl_hoppers:hopper_side" or "mcl_hoppers:hopper_side_disabled"
			param2 = HOPPER_FACING_TO_PARAM2[facing] or 0
		end
		return Resolution(node, "exact", "hopper facing=" .. facing .. " enabled=" .. tostring(enabled), param2)
	end

	if base == "dispenser" or base == "dropper" then
		local prefix = "mcl_dispensers:" .. base
		local facing = props.facing or "north"
		local node, param2
		if facing == "up" or facing == "down" then
			node = prefix .. "_" .. facing
			param2 = 0
		else
			node = prefix
			param2 = FACING_TO_FACEDIR[facing] or 0
		end
		return Resolution(node, "exact", base .. " facing=" .. facing, param2)
	end

	if base == "anvil" or base == "chipped_anvil" or base == "damaged_anvil" then
		local param2 = FACING_TO_FACEDIR[props.facing] or 0
		return Resolution(EXACT[base], "exact", base .. " facing=" .. tostring(props.facing), param2)
	end

	if base == "carved_pumpkin" or base == "jack_o_lantern" then
		local param2 = FACING_TO_FACEDIR[props.facing] or 0
		return Resolution(EXACT[base], "exact", base .. " facing=" .. tostring(props.facing), param2)
	end

	-- Found via a systematic sweep this session (2026-09-17): ran the real
	-- Lua resolver against every distinct block+properties combination in
	-- a full real base capture (Fort Alcazar) -- 114 of 473 distinct block
	-- types fell through to the tier-4 stone default, several with huge
	-- instance counts (nether_portal: 128,361; dripstone_block+
	-- pointed_dripstone: ~115,000; grass the plant: ~19,000; bamboo:
	-- ~22,000, in that one base alone). These four are the highest-impact
	-- ones, fixed directly; the remaining ~110 (mostly stone/wood texture
	-- variants -- deepslate tile, polished blackstone brick, mud brick,
	-- stripped-log/wood species variants, etc.) are lower-impact-per-block
	-- but numerous, and are a separate, larger follow-up (see
	-- SESSION_2026-09-17_TODO.md).
	if base == "nether_portal" then
		-- paramtype2="facedir" (mods/ITEMS/mcl_portals/portal_nether.lua);
		-- MC's "axis" property (x|z) has no exact facedir equivalent for a
		-- symmetric portal plane, 0/1 is a reasonable best-effort split.
		local param2 = (props.axis == "x") and 0 or 1
		return Resolution("mcl_portals:portal", "exact", "nether_portal axis=" .. tostring(props.axis), param2)
	end

	if base == "mangrove_roots" then
		-- Found live 2026-09-18 (owner report: "trees made of stone" with
		-- vines -- turned out to be a mangrove, not jungle, root system
		-- defaulting to stone; verified against the real source capture
		-- at the reported coordinate, cutecurly's City). Mangrove roots
		-- are NOT part of the generic <species>_log/leaves/planks wood
		-- family this file already handles (that family only covers
		-- log/wood/planks/leaves/sapling/fence/fence_gate) -- they're a
		-- mangrove-exclusive block registered in a wholly separate mod,
		-- mods/ITEMS/mcl_mangrove/init.lua, not mcl_trees. Waterlogged
		-- roots are a genuinely separate node name in this engine (not a
		-- param/group), confirmed by reading both register_node calls.
		local name = (props.waterlogged == "true")
			and "mcl_mangrove:water_logged_roots"
			or "mcl_mangrove:mangrove_roots"
		return Resolution(name, "exact", "mangrove_roots waterlogged=" .. tostring(props.waterlogged), 0)
	end

	if base == "bamboo" then
		-- No bare "bamboo" node in Mineclonia (mods/ITEMS/mcl_bamboo) --
		-- only staged small/big + leaf variants. "_small" is the closest
		-- single reasonable stand-in; MC's age/leaves/stage properties
		-- aren't modeled.
		return Resolution("mcl_bamboo:bamboo_small", "family", "bamboo (no exact stage match)", 0)
	end

	if base == "pointed_dripstone" then
		-- mods/ITEMS/mcl_dripstone registers separate top_*/bottom_*
		-- tip/frustum/middle/base nodes per MC's "thickness"+
		-- "vertical_direction" properties. Collapsing to a single tip
		-- node is a deliberate simplification (this project's large-
		-- dripstone-structure GENERATION is already disabled world-wide
		-- for an unrelated engine crash, see world.mt -- placing the
		-- individual captured blocks here is still worthwhile and safe,
		-- it just won't reconstruct the exact original stalactite shape).
		local vdir = props.vertical_direction or "up"
		local name = (vdir == "down") and "mcl_dripstone:dripstone_top_tip" or "mcl_dripstone:dripstone_bottom_tip"
		return Resolution(name, "family",
			"pointed_dripstone vertical_direction=" .. tostring(vdir) .. " (collapsed to a single tip shape)", 0)
	end

	if base == "shulker_box" then
		-- Bare "shulker_box" (no color prefix) is MC's original undyed
		-- shulker -- textured naturally purple, matching Mineclonia's own
		-- canonical_shulker_color = "violet" (mods/ITEMS/mcl_chests/
		-- init.lua). Target "_small" directly for the same reason as the
		-- colored variants above (see SHULKER_COLORS handling) -- the
		-- placeholder has no on_rightclick of its own.
		local param2 = SHULKER_FACING_TO_WALLMOUNTED[props.facing] or 0
		return Resolution("mcl_chests:violet_shulker_box_small", "exact",
			"undyed shulker box (-> canonical violet), facing=" .. tostring(props.facing), param2)
	end

	-- "composter" also had NO mapping (found alongside the bell gap,
	-- same investigation) -- fell through to the stone default too, which
	-- independently starves the village "farmland + composter within 12
	-- blocks" detection heuristic in structures.lua of its other half.
	-- mods/ITEMS/mcl_composters/init.lua registers one node per MC fill
	-- level (0 = "composter", 1-7 = "composter_N", 8 = "composter_ready").
	if base == "composter" then
		local level = tonumber(props.level) or 0
		local name
		if level <= 0 then
			name = "mcl_composters:composter"
		elseif level >= 8 then
			name = "mcl_composters:composter_ready"
		else
			name = "mcl_composters:composter_" .. level
		end
		return Resolution(name, "exact", "composter level=" .. tostring(props.level), 0)
	end

	-- "bell" had NO mapping at all (found live, 2026-09-17, while
	-- investigating why village-detection heuristics never fired on a
	-- real captured village with 25 real bells in its source NBT): it
	-- fell all the way through every tier to the tier-4 stone default,
	-- silently. mods/ITEMS/mcl_bells/init.lua registers three separate
	-- nodes for MC's three attachment types (bell=floor, paramtype2=
	-- "facedir"; bell_ceiling/bell_wall inherit paramtype2="wallmounted"
	-- from their shared bell_def, confirmed by reading the file directly).
	if base == "bell" then
		local attachment = props.attachment or "floor"
		if attachment == "ceiling" then
			return Resolution("mcl_bells:bell_ceiling", "exact", "bell attachment=ceiling", 0)
		elseif attachment == "single_wall" or attachment == "double_wall" then
			local param2 = FACING_TO_WALLMOUNTED[props.facing] or 4
			return Resolution("mcl_bells:bell_wall", "exact",
				"bell attachment=" .. attachment .. " facing=" .. tostring(props.facing), param2)
		else
			local param2 = FACING_TO_FACEDIR[props.facing] or 0
			return Resolution("mcl_bells:bell", "exact", "bell attachment=floor facing=" .. tostring(props.facing), param2)
		end
	end

	-- Signs exist per wood species, same as doors/fences -- Mineclonia
	-- registers mcl_signs:{standing,wall}_sign_<wood> for every tree type
	-- (mcl_trees/api.lua calls mcl_signs.register_sign). Matching only oak
	-- sent every birch/spruce/jungle/acacia/dark_oak sign to the
	-- DEFAULT_NODE fallback, i.e. it was placed as a solid stone block:
	-- 1087 of 2514 signs in the test batch, verified in-world.
	for _, wood in ipairs(WOOD_SPECIES) do
		if base == wood .. "_sign" then
			local rotation = math.floor(tonumber(props.rotation) or 0) % 16
			-- paramtype2 = degrotate: 16 Minecraft rotations over 240 steps.
			return Resolution("mcl_signs:standing_sign_" .. wood, "exact",
				"standing sign rotation=" .. rotation, rotation * 15)
		end
		if base == wood .. "_wall_sign" then
			local param2 = SIGN_FACING_TO_WALLMOUNTED[props.facing] or 4
			return Resolution("mcl_signs:wall_sign_" .. wood, "exact",
				"wall sign facing=" .. tostring(props.facing), param2)
		end
		-- Hanging signs are a 1.20 block Mineclonia has no equivalent for.
		-- The nearest honest stand-in is the same wood's standing sign --
		-- it at least renders as a readable sign rather than a stone cube.
		if base == wood .. "_hanging_sign" or base == wood .. "_wall_hanging_sign" then
			return Resolution("mcl_signs:standing_sign_" .. wood, "family",
				"hanging sign -> standing sign (no hanging sign in Mineclonia)", 0)
		end
	end

	if base == "piston" then
		local extended = tostring(props.extended or "false")
		local target = SPECIAL.piston_extended[extended] or "mcl_pistons:piston_off"
		return Resolution(target, "exact", "piston extended=" .. extended)
	end

	if base == "sticky_piston" then
		local extended = tostring(props.extended or "false")
		local target = SPECIAL.sticky_piston_extended[extended] or "mcl_pistons:piston_sticky_off"
		return Resolution(target, "exact", "sticky_piston extended=" .. extended)
	end

	if base == "piston_head" then
		local ptype = props.type or "normal"
		local target = SPECIAL.piston_head_type[ptype] or "mcl_pistons:piston_pusher"
		return Resolution(target, "exact", "piston_head type=" .. ptype)
	end

	if base == "observer" then
		local powered = tostring(props.powered or "false")
		local target = SPECIAL.observer_powered[powered] or "mcl_observers:observer_off"
		return Resolution(target, "exact", "observer powered=" .. powered)
	end

	if base == "redstone_torch" then
		-- Same bug/fix as plain "torch" above -- mcl_redstone_torch
		-- registers through the exact same mcl_torches.register_torch()
		-- floor/wall API (mods/ITEMS/REDSTONE/mcl_redstone_torch/
		-- init.lua calls it directly), so a real floor redstone torch
		-- always has param2 == 1 too. Was defaulting to 0 (no param2
		-- argument passed at all) -- same upside-down bug.
		local lit = tostring(props.lit or "true")
		local target = SPECIAL.redstone_torch_lit[lit] or "mcl_redstone_torch:redstone_torch_on"
		return Resolution(target, "exact", "redstone_torch lit=" .. lit, 1)
	end

	if base == "redstone_wall_torch" then
		-- Same fix as "wall_torch" above -- this also had no param2 at
		-- all (defaulted to 0), when it needs the same horizontal
		-- FACING_TO_WALLMOUNTED mapping wall_torch uses.
		local lit = tostring(props.lit or "true")
		local target = SPECIAL.redstone_wall_torch_lit[lit] or "mcl_redstone_torch:redstone_torch_on_wall"
		local param2 = FACING_TO_WALLMOUNTED[props.facing] or 4
		return Resolution(target, "exact", "redstone_wall_torch lit=" .. lit .. " facing=" .. tostring(props.facing), param2)
	end

	if base == "redstone_lamp" then
		local lit = tostring(props.lit or "false")
		local target = SPECIAL.redstone_lamp_lit[lit] or "mcl_redstone_lamp:lamp_off"
		return Resolution(target, "exact", "redstone_lamp lit=" .. lit)
	end

	-- Pre-flattening (legacy, pre-1.13) capture format used a separate
	-- block id for the lit state instead of a "lit" property on
	-- "redstone_lamp" -- this corpus includes very old saves (some
	-- captures date back to pre-flattening-era world downloads) where
	-- this legacy name can still show up. Found live 2026-09-18 (round
	-- 5) while chasing an unrelated report: confirmed via
	-- resolve_detailed("minecraft:lit_redstone_lamp") that this fell
	-- through to the stone default fallback exactly like "target" below
	-- did, since `base` here is just the raw name after the colon with
	-- no "lit_" stripping anywhere in this resolver.
	if base == "lit_redstone_lamp" then
		return Resolution(SPECIAL.redstone_lamp_lit["true"] or "mcl_redstone_lamp:lamp_on",
			"exact", "legacy lit_redstone_lamp")
	end

	-- Owner explicit 2026-09-18 round 5: a real block reported as "stone
	-- that appears to be on top of a wall... I'm guessing it's a lamp
	-- block of some kind." Root-caused via a direct source-coordinate
	-- lookup + resolve_detailed() call: the block was real vanilla
	-- minecraft:target (a redstone target block), which had NO entry at
	-- all in mc_to_mcl.json (not even in unmapped_known_gaps -- a
	-- genuinely new, previously-undiscovered gap) and so fell all the
	-- way to the "default" tier's stone fallback. mcl_target:target_off/
	-- target_on are real, verified registered nodes (mods/ITEMS/
	-- REDSTONE/mcl_target/init.lua). Real Minecraft's target block state
	-- is an integer "power" (0-15, redstone signal strength), not a
	-- boolean -- power > 0 means lit/on.
	if base == "target" then
		local power = tonumber(props.power or "0") or 0
		local target = (power > 0) and "mcl_target:target_on" or "mcl_target:target_off"
		return Resolution(target, "exact", "target power=" .. tostring(power))
	end

	if base == "nether_wart" then
		local age = tostring(props.age or "3")
		local target = SPECIAL.nether_wart_age[age] or "mcl_nether:nether_wart"
		return Resolution(target, "exact", "nether_wart age=" .. age)
	end

	-- Found live 2026-09-18 round 5 while chasing the same "stone" report
	-- as target/shroomlight/polished_blackstone above -- mangrove_
	-- propagule was completely unmapped and fell to the stone default.
	-- Real Minecraft models it as one node with a "hanging" bool + an
	-- "age" 0-4 (only meaningful while hanging); Mineclonia instead
	-- registers the non-hanging planted form as a single
	-- "mcl_mangrove:propagule" plus five separately-registered hanging
	-- stage nodes "mcl_mangrove:propagule_hanging_1".."_5" (mods/ITEMS/
	-- mcl_mangrove/init.lua) -- a simple age+1 offset from vanilla's 0-4
	-- to Mineclonia's 1-5.
	if base == "mangrove_propagule" then
		local hanging = tostring(props.hanging or "false") == "true"
		if not hanging then
			return Resolution("mcl_mangrove:propagule", "exact", "mangrove_propagule hanging=false")
		end
		local age = tonumber(props.age or "0") or 0
		local stage = math.max(1, math.min(5, age + 1))
		return Resolution("mcl_mangrove:propagule_hanging_" .. stage, "exact",
			"mangrove_propagule hanging=true age=" .. age)
	end

	if base == "comparator" then
		local powered = props.powered == "true"
		local mode = (props.mode == "subtract") and "sub" or "comp"
		local target = "mcl_comparators:comparator_" .. (powered and "on" or "off") .. "_" .. mode
		return Resolution(target, "exact", "comparator mode=" .. tostring(props.mode) .. " powered=" .. tostring(props.powered))
	end

	if base == "repeater" then
		local powered = props.powered == "true"
		local delay = props.delay or "1"
		if delay ~= "1" and delay ~= "2" and delay ~= "3" and delay ~= "4" then delay = "1" end
		local target = "mcl_repeaters:repeater_" .. (powered and "on" or "off") .. "_" .. delay
		return Resolution(target, "exact", "repeater delay=" .. delay .. " powered=" .. tostring(props.powered))
	end

	if base == "cocoa" then
		-- mods/ITEMS/mcl_cocoas/init.lua: cocoa_1..cocoa_3, mesh stage =
		-- i-1, matching Minecraft's age (0,1,2) offset by one.
		local age = tonumber(props.age)
		if not age then age = 2 end
		if age < 0 then age = 0 end
		if age > 2 then age = 2 end
		return Resolution("mcl_cocoas:cocoa_" .. (age + 1), "exact", "cocoa age=" .. tostring(props.age))
	end

	if starts_with(base, "potted_") then
		return Resolution("mcl_flowerpots:flower_pot", "family", "potted plant species dropped, using empty pot")
	end

	-- Owner explicit 2026-09-19 round 11 (live report): "this photo is of
	-- a skulk vein on the surface, it should not be hanging orientation
	-- ... but should be on the ground as this is on the surface of a
	-- desert sand block." Root cause: mcl_sculk:vein
	-- (mods/ITEMS/mcl_sculk/init.lua) is `drawtype = "signlike"`,
	-- `paramtype2 = "wallmounted"` -- and this project never had a
	-- special case for it at all before now (the old `mc_to_mcl.json`
	-- "exact" entry was a bare 1:1 name mapping with no property/param2
	-- handling), so every vein silently defaulted to param2=0 regardless
	-- of its real captured orientation.
	--
	-- Verified the real signlike wallmounted convention directly against
	-- Luanti's own engine source (not guessed, and NOT the same
	-- convention as the sign/item-frame "outward-facing" tables above --
	-- confirmed by reading src/client/content_mapblock.cpp's
	-- drawSignlikeNode() and working through its actual vertex rotation
	-- math): the base panel sits flush against the node's own +X face
	-- (DWM_XP/wallmounted=2, no rotation), and DWM_YP's rotateXYBy(90)
	-- moves that panel to the cell's +Y (ceiling) side, while DWM_YN's
	-- rotateXYBy(-90) moves it to -Y (floor) -- i.e. wallmounted=0 is a
	-- CEILING mount and wallmounted=1 is a FLOOR mount for this specific
	-- drawtype, the opposite of the torch-placed-on-the-floor intuition
	-- (torches use a completely separate drawTorchlikeNode() function
	-- with its own, different convention -- the two drawtypes don't
	-- share a param2 meaning just because they share the wallmounted
	-- paramtype2). Working through the X/Z rotation cases the same way
	-- gives wallmounted 2=east, 3=west, 4=south, 5=north -- this matches
	-- the existing (already in this file) SHULKER_FACING_TO_WALLMOUNTED
	-- table exactly, not the inverted FACING_TO_WALLMOUNTED one used for
	-- signs/item-frames -- convergent evidence this derivation is right,
	-- since a vein's "which face has the growth" semantic is the same
	-- kind of intrinsic-direction property a shulker's "which way it
	-- opens" is, not the "which way faces the viewer" semantic a sign's
	-- text or an item frame's picture has.
	--
	-- Real vanilla sculk_vein can have UP TO 6 simultaneous true faces;
	-- Mineclonia's version can only represent one at a time (a single
	-- wallmounted value), so this picks the first true face in a fixed
	-- priority order (down/up are the common cases -- floor and ceiling
	-- growth -- checked first) rather than trying to preserve all of
	-- them.
	if base == "sculk_vein" then
		local face_order = { "down", "up", "east", "west", "south", "north" }
		local face = nil
		for _, f in ipairs(face_order) do
			if tostring(props[f]) == "true" then face = f; break end
		end
		face = face or "down"
		local target = SHULKER_FACING_TO_WALLMOUNTED[face] or 1
		return Resolution("mcl_sculk:vein", "exact", "sculk_vein face=" .. face, target)
	end

	-- glow_lichen is the same class of bug sculk_vein just was (a
	-- multiface signlike-family block with NO special case here at all,
	-- silently defaulting to param2=0 -- which per
	-- GLOW_LICHEN_FACE_TO_WALLMOUNTED means "up", i.e. every imported
	-- glow_lichen rendered attached-to-the-ceiling-above regardless of
	-- its real orientation). Found by auditing siblings after fixing
	-- sculk_vein, not from a direct owner report.
	--
	-- Unlike sculk_vein, Mineclonia's own glow_lichen genuinely supports
	-- multiple simultaneous faces via separate combo-named nodes
	-- ("mcl_core:glow_lichen_" .. up-to-6 letters in n/w/s/e/u/d order,
	-- paramtype2="none", param2=0 -- see register_glow_lichen() and
	-- glow_lichen_params() in nodes_glow_lichen.lua), so -- unlike the
	-- single-face-only sculk_vein fix -- this preserves every true face
	-- from the source data rather than picking just one.
	if base == "glow_lichen" then
		local faces = { "north", "west", "south", "east", "up", "down" }
		local present, count = {}, 0
		for _, f in ipairs(faces) do
			if tostring(props[f]) == "true" then
				present[f] = true
				count = count + 1
			end
		end
		if count >= 2 then
			local name = "mcl_core:glow_lichen_"
			local letters = { north = "n", west = "w", south = "s", east = "e", up = "u", down = "d" }
			local detail = "glow_lichen faces="
			for _, f in ipairs(faces) do
				if present[f] then
					name = name .. letters[f]
					detail = detail .. letters[f]
				end
			end
			return Resolution(name, "exact", detail, 0)
		else
			local face = "up"
			for _, f in ipairs(faces) do
				if present[f] then face = f; break end
			end
			local target = GLOW_LICHEN_FACE_TO_WALLMOUNTED[face] or 0
			return Resolution("mcl_core:glow_lichen", "exact", "glow_lichen face=" .. face, target)
		end
	end

	if base == "sculk_sensor" or base == "sculk_shrieker" then
		-- Both blocks' register_node calls live inside `--[[ ... ]]` block
		-- comments in Mineclonia's mods/ITEMS/mcl_sculk/init.lua (the
		-- sensor+shrieker mechanic + their ABMs are unimplemented in this
		-- build). Verified by direct file inspection AND by a
		-- core.registered_nodes dump -- only mcl_sculk:sculk, :vein, and
		-- :catalyst are present. The closest visual analog among the three
		-- registered sculk blocks is mcl_sculk:catalyst (dark sculk
		-- texture + light_source=6, similar to shrieker/sensor's own
		-- light_source=1 and the dark-sculk-block look); mapping to
		-- plain sculk would lose the light entirely. This is a deliberate
		-- family-tier approximation, NOT a missing node -- see also the
		-- handoff's note on `tripwire` for the parallel "no equivalent in
		-- this build" case, which falls to the tier-4 stone default.
		return Resolution(
			"mcl_sculk:catalyst", "family",
			base .. " -> mcl_sculk:catalyst (sculk_sensor/shrieker not registered in this Mineclonia build; using closest visual analog)")
	end

	if EXACT[base] then
		return Resolution(EXACT[base], "exact", "direct lookup")
	end

	return nil
end

-- ---------------------------------------------------------------------
-- Tier 2: family fallback (for names tier 1 has never seen)
-- ---------------------------------------------------------------------

local COMMON_NAMESPACES = {
	"mcl_core", "mcl_nether", "mcl_end", "mcl_ocean", "mcl_farming",
	"mcl_chests", "mcl_doors", "mcl_fences", "mcl_walls", "mcl_flowers",
}

local function tier2(base)
	local color_part, rest = nil, base
	for c in pairs(COLORS) do
		local prefix = c .. "_"
		if starts_with(base, prefix) then
			color_part, rest = c, base:sub(#prefix + 1)
			break
		end
	end

	local candidates = {}
	if color_part then
		for _, entry in ipairs(COLOR_SUFFIXES) do
			candidates[#candidates + 1] = entry[2](color_part)
		end
	end
	for _, ns in ipairs(COMMON_NAMESPACES) do
		candidates[#candidates + 1] = ns .. ":" .. base
		if color_part then
			candidates[#candidates + 1] = ns .. ":" .. rest .. "_" .. color_part
			candidates[#candidates + 1] = ns .. ":" .. color_part .. "_" .. rest
		end
	end

	for _, node in ipairs(candidates) do
		if LITERAL_NODES[node] then
			return Resolution(node, "family", "pattern-matched against real Mineclonia node list (" .. node .. ")")
		end
	end
	return nil
end

-- ---------------------------------------------------------------------
-- Tier 3: nearest-color (Mineclonia-side texture color only, see palette.py)
-- ---------------------------------------------------------------------

local COLOR_RGB = {}
for name, hex in pairs(DATA.color_rgb_hex) do
	hex = hex:gsub("^#", "")
	COLOR_RGB[name] = {
		tonumber(hex:sub(1, 2), 16),
		tonumber(hex:sub(3, 4), 16),
		tonumber(hex:sub(5, 6), 16),
	}
end

local function split_words(base)
	local words = {}
	for w in base:gmatch("[^_]+") do words[#words + 1] = w end
	return words
end

local function tier3(base)
	if #DATA.mapart_palette == 0 then return nil end
	local found_color = nil
	local words = split_words(base)
	for _, w in ipairs(words) do
		if COLOR_RGB[w] then
			found_color = w
			break
		end
	end
	if not found_color then return nil end

	local target = COLOR_RGB[found_color]
	local best_node, best_dist = nil, nil
	for _, entry in ipairs(DATA.mapart_palette) do
		local rgb = entry.rgb
		local dist = (rgb[1] - target[1]) ^ 2 + (rgb[2] - target[2]) ^ 2 + (rgb[3] - target[3]) ^ 2
		if not best_dist or dist < best_dist then
			best_dist = dist
			best_node = entry.node
		end
	end
	return Resolution(
		best_node, "color",
		string.format("nearest Mineclonia-palette color to estimated '%s' (%d,%d,%d)",
			found_color, target[1], target[2], target[3]))
end

-- ---------------------------------------------------------------------
-- Tier 4: default
-- ---------------------------------------------------------------------

-- Resolve one Minecraft block (name, properties) to a Mineclonia node
-- name (a plain string -- unlike Python's resolve(), which returns a
-- Resolution; see palette.resolve_detailed for the tier/detail version).
-- `properties` may be nil.
function palette.resolve_detailed(name, properties)
	local base = name:match("^[^:]*:(.*)$") or name
	local props = properties or {}

	local r = tier1(base, props)
	if r then return r end
	r = tier2(base)
	if r then return r end
	r = tier3(base)
	if r then return r end
	return Resolution(palette.DEFAULT_NODE, "default", "no match at any tier for " .. tostring(name))
end

function palette.resolve(name, properties)
	return palette.resolve_detailed(name, properties).node
end

return palette
