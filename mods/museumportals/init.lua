-- museumportals: portals are DISPLAYS in the museum, never transport.
--
-- The museum packs three Minecraft dimensions into one world as Y-bands
-- (overworld dy=-61, End dy=-26880, Nether dy=-29072), so vanilla portal
-- semantics are meaningless here: a nether portal at the nether band
-- converts coordinates 8:1 within the SAME world and lands you in the
-- overworld band, and the return trip computes a different location
-- entirely (owner 2026-09-26: "you immediately are transported to the
-- overworld ... yet oddly enough if you go back through the portal you
-- don't go back to the base"). Museum decision: portals never move
-- anyone; /warp is the transport in this world.
--
-- Every portal type gates its teleport on one function
-- (mods/ITEMS/mcl_portals/portal_nether.lua, portal_end.lua and
-- portal_gateway.lua all call mcl_portals.object_teleport_allowed first),
-- so one override disables all of them cleanly -- no copy of Mineclonia
-- teleport logic here. Worldmods load after game mods, and mod.conf
-- depends on mcl_portals, so the function exists by the time this runs.
if mcl_portals then
	mcl_portals.object_teleport_allowed = function() return false end
	core.log("action", "[museumportals] portal teleportation disabled (portals are displays; use /warp)")
else
	core.log("warning", "[museumportals] mcl_portals not found -- portal teleportation still active")
end
