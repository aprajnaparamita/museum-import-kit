-- resolve_check.lua -- resolve EVERY (id, meta) entry the legacy table
-- can emit through the real palette resolver, and report what it lands
-- on. Any name that falls through to the stone default is a bug class
-- (silent corruption) -- this is the tool that catches them.
--
--   luajit tools/resolve_check.lua
--
-- Also dumps each distinct resolution so eyeballing new table entries is
-- easy. Reads only; run standalone (no engine needed).

local HERE = (arg[0] or "tools/resolve_check.lua"):match("^(.*[/\\])") or "./"
package.path = HERE .. "../lua_import/?.lua;" .. package.path

-- palette.lua loads data.lua via __spawnimport_dofile / script dir
local LUA_IMPORT = HERE .. "../lua_import/"
_G.__spawnimport_dofile = dofile
_G.__spawnimport_lua_import_path = LUA_IMPORT

local palette = dofile(LUA_IMPORT .. "palette.lua")
local legacy = dofile(LUA_IMPORT .. "legacy.lua")

local DEFAULT = palette.DEFAULT_NODE
local seen = {}      -- "name|props" -> {name, props, node, tier, detail, count}
local order = {}
local fallbacks = {}
local unmapped = {}

for id = 0, 255 do
	local id_seen = false
	for meta = 0, 15 do
		local name, props = legacy.block(id, meta)
		if name then
			id_seen = true
			local r = palette.resolve_detailed(name, props)
			local key = name
			if props then
				local pk = {}
				for k, v in pairs(props) do pk[#pk + 1] = k .. "=" .. tostring(v) end
				table.sort(pk)
				key = name .. " {" .. table.concat(pk, ",") .. "}"
			end
			local e = seen[key]
			if not e then
				e = { name = name, props = props, node = r.node, tier = r.tier,
					detail = r.detail, count = 0, ids = {} }
				seen[key] = e
				order[#order + 1] = key
			end
			e.count = e.count + 1
			e.ids[id] = true
			if r.node == DEFAULT and r.tier == "default" then
				fallbacks[key] = e
			end
		end
	end
	if not id_seen and id ~= 0 then
		-- ids intentionally left out (no Mineclonia equivalent) or plain
		-- missing -- list them so nothing is forgotten silently
		unmapped[#unmapped + 1] = id
	end
end

table.sort(order)
print("=== resolutions (" .. #order .. " distinct name/props combos) ===")
for _, key in ipairs(order) do
	local e = seen[key]
	local ids = {}
	for id in pairs(e.ids) do ids[#ids + 1] = id end
	table.sort(ids)
	local idlist = {}
	for _, id in ipairs(ids) do idlist[#idlist + 1] = id end
	print(string.format("%-58s -> %-45s [%s] x%d ids{%s}",
		key, e.node, e.tier, e.count, table.concat(idlist, ",")))
end

print("\n=== STONE-FALLBACK entries (BUGS unless intended) ===")
local n = 0
for _, key in ipairs(order) do
	local e = fallbacks[key]
	if e then
		n = n + 1
		print(string.format("  %-58s ids: %s", key, e.detail))
	end
end
if n == 0 then print("  (none)") end

print("\n=== ids with NO legacy entry (warning->stone at decode) ===")
local parts, run = {}, {}
for _, id in ipairs(unmapped) do
	if run[#run] and id == run[#run] + 1 then
		run[#run + 1] = id
	else
		if #run > 0 then
			parts[#parts + 1] = (#run == 1) and tostring(run[1]) or (run[1] .. "-" .. run[#run])
		end
		run = { id }
	end
end
if #run > 0 then
	parts[#parts + 1] = (#run == 1) and tostring(run[1]) or (run[1] .. "-" .. run[#run])
end
print("  " .. table.concat(parts, ", "))

os.exit(n > 0 and 1 or 0)
