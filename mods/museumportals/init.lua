-- museumportals: portals are DISPLAYS in the museum, never transport --
-- with ONE exception, the End EXIT fountain (see below).
--
-- The museum packs three Minecraft dimensions into one world as Y-bands
-- (overworld dy=-61, End dy=-26880, Nether dy=-29072), so vanilla portal
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
if mcl_portals then
	mcl_portals.object_teleport_allowed = function() return false end
	core.log("action", "[museumportals] portal teleportation disabled (portals are displays; use /warp)")
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