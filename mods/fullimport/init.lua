-- Drives the full museum import and shuts the server down when done.
-- Resumable: the batch driver skips any base already in spawnimport's
-- registry, so a restart continues rather than duplicating work.
local MANIFEST = core.settings:get("museum_manifest_path")
	or (core.get_worldpath() .. "/museum_manifest.json")
local TARGET = tonumber(core.settings:get("museum_target_bases")) or 205

core.register_on_mods_loaded(function()
	core.after(1, function()
		local ok, msg = core.registered_chatcommands["museumimport"].func(
			"singleplayer", "start " .. MANIFEST .. " " .. TARGET)
		core.log("action", "[fullimport] start: " .. tostring(ok) .. " " .. tostring(msg))
	end)
end)

local done, last, started_at = false, -1, os.time()
core.register_globalstep(function()
	if done then return end
	local r = _G.__spawnimport_registry
	if not r then return end
	local n = #r.list()
	if n ~= last then
		last = n
		local el = os.time() - started_at
		core.log("action", string.format(
			"[fullimport] progress: %d/%d bases placed (%dm elapsed, ~%dm remaining)",
			n, TARGET, math.floor(el / 60),
			n > 0 and math.floor(el / n * (TARGET - n) / 60) or 0))
	end
	if n >= TARGET then
		done = true
		core.log("action", "[fullimport] ALL DONE - " .. n .. " bases placed")
		core.request_shutdown("fullimport done", false, 1)
	end
end)
