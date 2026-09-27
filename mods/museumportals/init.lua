-- museumportals: portals are DISPLAYS in the museum, never transport --
-- with ONE exception, the End EXIT fountain (see below).
--
-- The museum packs three Minecraft dimensions into one world as Y-bands
-- (overworld dy=-61, End dy=-27073, Nether dy=-29067), so vanilla portal
-- semantics are meaningless here: a nether portal at the nether band
-- converts coordinates 8:1 within the SAME world and lands you in the
-- overworld band, and the return trip computes a different location
-- entirely (owner 2026-09-26: "you immediately are transported to the
-- overworld ... yet oddly enough if you go back through the portal you
-- don't go back to the base"). End ENTRY portals would likewise teleport
-- to mcl_vars.mg_end_platform_pos -- a fixed mapgen position that is
-- meaningless in the packed world -- and drop an obsidian platform
-- there. So every portal type is gated off at mcl_portals'
-- object_teleport_allowed (all three portal types check it).
--
-- The one exception (owner 2026-09-27: "after beating the dragon i could
-- stand in the end portal and it wouldn't warp me"): the End EXIT
-- fountain. Vanilla's exit semantics -- "End portals in the End lead
-- back to your spawn point in the Overworld" -- are exactly right for
-- the museum (you finished the End, you go home). Implemented directly
-- here instead of calling mcl_portals.end_teleport: that function
-- branches on mcl_worlds.pos_to_dimension, which does not know the
-- museum's Y-band layout and would take the ENTRY branch instead.
local museum_mcl_teleport_allowed
if mcl_portals then
	-- Mineclonia's own check, kept for the gateways it still runs (below)
	museum_mcl_teleport_allowed = mcl_portals.object_teleport_allowed
	mcl_portals.object_teleport_allowed = function() return false end
	core.log("action", "[museumportals] portal teleportation disabled except End gateways (portals are displays; use /warp)")
else
	core.log("warning", "[museumportals] mcl_portals not found -- portal teleportation still active")
end

-- End exit fountain: standing in an end-portal block anywhere in the End
-- band respawns the player at their spawn point (vanilla exit).
local END_BAND_TOP = -26500     -- the End band's dest y range
local END_BAND_BOTTOM = -27100
local last_exit = {}
core.register_globalstep(function()
	for _, player in ipairs(core.get_connected_players()) do
		local name = player:get_player_name()
		local p = player:get_pos()
		if p and p.y >= END_BAND_BOTTOM and p.y <= END_BAND_TOP then
			if core.get_node(p).name == "mcl_portals:portal_end" then
				local t = core.get_us_time()
				if not last_exit[name] or t - last_exit[name] > 5 * 1000000 then
					last_exit[name] = t
					core.chat_send_player(name, "[museum] the exit portal returns you to your spawn point")
					player:respawn()
				end
			end
		end
	end
end)
-- Stranded shulkers (owner 2026-09-27: "there are floating shulkers that
-- are alive here"). Mineclonia's v7 End places end_boat / end_shipwreck
-- structures and spawns their shulkers as ENTITIES at mapgen time
-- (mcl_structures/end_city.lua spawn_shulkers). spawnimport then clears
-- captured chunks and reshapes the merge ring, which removes the ship's
-- NODES but not the entities. An unattached shulker only tries short
-- random teleports (+-8, shulker.lua attempt_teleport), so in open void
-- it floats forever. Remove a shulker in the End band once it has been
-- unable to attach for ~10 s of its own AI steps. A shulker on any
-- surface is untouched, including the museum's own (mobplacement.lua).
local shulker = core.registered_entities["mobs_mc:shulker"]
if shulker and shulker.ai_step and shulker.attachment_valid then
	local orig_ai_step = shulker.ai_step
	shulker.ai_step = function(self, dtime)
		orig_ai_step(self, dtime)
		local p = self.object and self.object:get_pos()
		if not p or p.y < END_BAND_BOTTOM or p.y > END_BAND_TOP then return end
		if self:attachment_valid(self._face, mcl_util.get_nodepos(p), p) then
			self._museum_stranded = nil
			return
		end
		-- Mineclonia only teleports within +-8; with no solid node that
		-- close it can never re-attach, so don't leave it hanging in view
		-- for the full 10 s (owner 2026-09-28 screenshot: a group was still
		-- floating 14 s after the player arrived)
		if not self._museum_stranded
			and not core.find_node_near(mcl_util.get_nodepos(p), 8, { "group:opaque" }) then
			self._museum_stranded = 10
		end
		self._museum_stranded = (self._museum_stranded or 0) + (dtime or 0.05)
		if self._museum_stranded > 10 and not self.removed then
			-- safe_remove defers obj:remove() to the next step (removing
			-- mid-step crashes the rest of mcl_mobs' on_step)
			core.log("action", "[museumportals] removing stranded shulker at " .. core.pos_to_string(vector.round(p)))
			self:safe_remove()
		end
	end
else
	core.log("warning", "[museumportals] mobs_mc:shulker not found -- stranded-shulker cleanup disabled")
end

-- End gateways (owner 2026-09-28). spawnimport's gateway_link.lua pairs
-- each End base's captured gateway with a main-island gateway slot, as if
-- the player had killed the dragon and then built the base, and records
-- the pairs in <world>/museum_gateways.json. Here:
--   * a linked gateway teleports to its partner (both directions);
--   * an unlinked gateway more than 200 blocks from the origin (a base
--     past the 20 main-island slots) returns to the main island, which
--     is vanilla's behaviour for outer gateways;
--   * every other gateway runs Mineclonia's own code, like normal play:
--     the dragon-kill gateways on the main island (their first use builds
--     a return gateway ~1100 blocks out) and those return gateways, which
--     carry Mineclonia's destination meta.
-- Mineclonia's dragon-kill spawner opens slots in order; it skips the
-- slots bases already hold, so every kill still opens a new gateway.
if core.registered_nodes["mcl_portals:portal_gateway"] and mcl_vars and mcl_vars.mg_end_exit_portal_pos then
	local exit = mcl_vars.mg_end_exit_portal_pos
	local partner = {}
	do
		local f = io.open(core.get_worldpath() .. "/museum_gateways.json", "r")
		local links = f and core.parse_json(f:read("*a")) or {}
		if f then f:close() end
		for _, l in ipairs(links) do
			if l.main and l.outer and l.outer[1] then
				partner[core.pos_to_string(l.main)] = { pos = vector.new(l.outer[1]), main = false }
				for _, o in ipairs(l.outer) do
					partner[core.pos_to_string(o)] = { pos = vector.new(l.main), main = true }
				end
			end
		end
	end
	local function mcl_dest(pos)
		return core.get_meta(pos):get_string("mcl_portals:gateway_destination") ~= ""
	end
	local function on_main(pos)
		return math.abs(pos.x - exit.x) <= 200 and math.abs(pos.z - exit.z) <= 200
	end
	-- Mineclonia handles a gateway that no base owns and that is either on
	-- the main island or one of its own (has a destination)
	local function mcl_owns(pos)
		return not partner[core.pos_to_string(pos)] and (on_main(pos) or mcl_dest(pos))
	end
	if museum_mcl_teleport_allowed then
		mcl_portals.object_teleport_allowed = function(obj)
			local p = obj and obj:get_pos()
			if not p or p.y < END_BAND_BOTTOM or p.y > END_BAND_TOP then return false end
			local g = core.find_node_near(p, 2, { "mcl_portals:portal_gateway" }, true)
			if g and mcl_owns(g) then return museum_mcl_teleport_allowed(obj) end
			return false
		end
	end
	-- dragon kills: skip slots a base already holds
	if mcl_portals.spawn_gateway_portal and mcl_portals.storage then
		local slot_taken = {}
		do
			local f = io.open(core.get_worldpath() .. "/museum_gateways.json", "r")
			local links = f and core.parse_json(f:read("*a")) or {}
			if f then f:close() end
			for _, l in ipairs(links) do if l.slot then slot_taken[l.slot] = true end end
		end
		local mcl_spawn = mcl_portals.spawn_gateway_portal
		mcl_portals.spawn_gateway_portal = function()
			local st = mcl_portals.storage
			for _ = 1, 20 do
				local nxt = st:get_int("gateway_last_id") + 1
				if nxt > 20 then return end
				if not slot_taken[nxt] then return mcl_spawn() end
				st:set_int("gateway_last_id", nxt) -- held by a base: skip it
			end
		end
	end
	local busy = {}
	-- land on the top walkable block near `target` (Mineclonia's own
	-- find_destination_pos box: +-5 horizontally, 40 down, 10 up)
	local function send(player, target, msg)
		local name = player:get_player_name()
		if busy[name] then return end
		busy[name] = true
		local minp, maxp = vector.offset(target, -5, -40, -5), vector.offset(target, 5, 10, 5)
		core.emerge_area(minp, maxp, function(_, _, remaining)
			if remaining > 0 then return end
			local dest
			for y = maxp.y, minp.y, -1 do
				for x = maxp.x, minp.x, -1 do
					for z = maxp.z, minp.z, -1 do
						local nn = core.get_node(vector.new(x, y, z)).name
						local def = core.registered_nodes[nn]
						if not dest and def and def.walkable and nn ~= "mcl_portals:portal_gateway"
							and nn ~= "mcl_core:bedrock" then
							dest = vector.new(x, y + 1.5, z)
						end
					end
				end
				if dest then break end
			end
			if player:is_player() then
				player:set_pos(dest or vector.offset(target, 0, 3.5, 0))
				core.chat_send_player(name, "[museum] " .. msg)
			end
			core.after(5, function() busy[name] = nil end)
		end)
	end
	local exit_landing = vector.new(exit.x + 12, exit.y, exit.z)
	core.register_abm({
		label = "Museum End gateways",
		nodenames = { "mcl_portals:portal_gateway" },
		interval = 1,
		chance = 1,
		action = function(pos)
			if pos.y < END_BAND_BOTTOM or pos.y > END_BAND_TOP then return end
			local link = partner[core.pos_to_string(pos)]
			local mcl = not link and mcl_owns(pos)
			-- 2 blocks: the gateway is a solid node and Mineclonia's own ABM
			-- only catches objects within 1 of its centre, which a player
			-- beside or under it never is (owner 2026-09-28: the return
			-- gateway at (1150,-26998,0) did nothing, standing or pearl)
			for obj in core.objects_inside_radius(pos, 2) do
				local ent = obj:get_luaentity()
				if ent and ent.name == "mcl_throwing:ender_pearl" and ent._thrower then
					local thrower = ent._thrower
					if type(thrower) == "string" then thrower = core.get_player_by_name(thrower) end
					obj:remove()
					obj = thrower
				end
				if obj and obj.is_player and obj:is_player() then
					local name = obj:get_player_name()
					if mcl then
						-- Mineclonia's gateway: its own pairing and landing
						if not busy[name] and mcl_portals.gateway_teleport then
							busy[name] = true
							mcl_portals.gateway_teleport(pos, obj)
							core.after(5, function() busy[name] = nil end)
						end
					elseif link and not link.main then
						send(obj, link.pos, "the gateway takes you out to the base")
					else
						-- to the main island: beside the exit portal, not
						-- onto the slot's gateway floating in the void
						send(obj, exit_landing, "the gateway returns you to the main End island")
					end
				end
			end
		end,
	})
end

-- Hanging banners with no facing (owner 2026-09-28: "mineclonia style end
-- city banners seem to stick out like a flag rather than flat against the
-- wall"). mcl_banners takes the banner entity's yaw from node meta
-- rotation_level, which only its on_place sets; banners placed by
-- Mineclonia's own end-ship schematic (and imports before spawnimport set
-- it) have none, so they all face one way. Derive it from the node's
-- wallmounted param2 exactly as mcl_banners' on_place does and turn the
-- entity. A banner that already has rotation_level is never touched.
if core.registered_nodes["mcl_banners:hanging_banner"] then
	local function fix_yaw(pos, rot)
		local bpos = vector.add(pos, vector.new(0, -0.64, 0))
		for obj in core.objects_inside_radius(bpos, 0.5) do
			local ent = obj:get_luaentity()
			if ent and ent.name == "mcl_banners:hanging_banner" then
				obj:set_yaw(rot * math.pi / 8 + math.pi)
			end
		end
	end
	core.register_lbm({
		label = "Museum: face hanging banners flat against their wall",
		name = "museumportals:hanging_banner_facing",
		nodenames = { "mcl_banners:hanging_banner" },
		run_at_every_load = true,
		action = function(pos, node)
			local meta = core.get_meta(pos)
			if meta:get_string("rotation_level") ~= "" then return end
			local pdir = vector.multiply(core.wallmounted_to_dir(node.param2 % 8), -1)
			local rot = 0
			if pdir.x > 0 then rot = 4 elseif pdir.z > 0 then rot = 8 elseif pdir.x < 0 then rot = 12 end
			meta:set_int("rotation_level", rot)
			-- mcl_banners' own respawn LBM may run after this one
			core.after(0.5, fix_yaw, pos, rot)
		end,
	})
end
