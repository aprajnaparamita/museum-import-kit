-- Placement registry: tracks every base this mod has placed in the
-- current world, so multiple imports over time don't silently overlap.
-- Stored in this mod's own StorageRef (core.get_mod_storage()) as a
-- serialized Lua table -- automatically persisted by the engine, no
-- manual file I/O needed (unlike reading the source WorldTools folder,
-- which does need it -- see README.md).

local registry = {}

local storage = core.get_mod_storage()
local STORAGE_KEY = "placed_bases"

-- Each entry: { name=, source_folder=, dimension_path=,
--   anchor_x=, anchor_z=, bbox={x_min=,x_max=,z_min=,z_max=},
--   block_count=, placed_at=<os.time()> }

function registry.load()
	local raw = storage:get_string(STORAGE_KEY)
	if not raw or raw == "" then
		return {}
	end
	local ok, entries = pcall(core.deserialize, raw)
	if not ok or type(entries) ~= "table" then
		core.log("error", "[spawnimport] registry storage is corrupt, treating as empty: " .. tostring(entries))
		return {}
	end
	return entries
end

function registry.save(entries)
	storage:set_string(STORAGE_KEY, core.serialize(entries))
end

function registry.add(entry)
	local entries = registry.load()
	entries[#entries + 1] = entry
	registry.save(entries)
end

-- AABB overlap. X/Z always matter; Y only matters once both sides actually
-- have a known Y range -- see README.md's "Anchor & offset convention" for
-- why Y was originally left out entirely (every base in that single-world
-- import is full-height overworld, so Y always overlaps regardless -- X/Z
-- alone was already a correct and sufficient check there). It stops being
-- sufficient once imports can land in different Y-bands (Nether/End, see
-- the museum batch driver) that can freely share X/Z without actually
-- touching in-world, so Y is now checked too when both bboxes carry one;
-- an absent y_min/y_max (either a legacy registry entry, or an in-flight
-- job's dest_bbox before any content has been placed) falls back to the
-- old X/Z-only behavior, which is always safe (never under-reports a
-- collision, only potentially over-reports one).
local function overlaps(a, b)
	if a.x_max < b.x_min or a.x_min > b.x_max or a.z_max < b.z_min or a.z_min > b.z_max then
		return false
	end
	if a.y_min and a.y_max and b.y_min and b.y_max then
		return not (a.y_max < b.y_min or a.y_min > b.y_max)
	end
	return true
end
registry.overlaps = overlaps

-- Merges fields into an existing entry (by name). Used to attach a warp
-- target after a base is placed, and to backfill bases imported before
-- warp targets existed.
function registry.update_by_name(name, fields)
	local entries = registry.load()
	for _, entry in ipairs(entries) do
		if entry.name == name then
			for k, v in pairs(fields) do
				entry[k] = v
			end
			registry.save(entries)
			return true
		end
	end
	return false
end

function registry.find_by_name(name)
	for _, entry in ipairs(registry.load()) do
		if entry.name == name then
			return entry
		end
	end
	return nil
end

-- Returns nil if no collision, or the colliding entry if `bbox` overlaps
-- an existing placed base.
function registry.find_collision(bbox)
	for _, entry in ipairs(registry.load()) do
		if overlaps(bbox, entry.bbox) then
			return entry
		end
	end
	return nil
end

-- A simple, always-safe (if not space-optimal) free-spot suggestion:
-- past the max X edge of everything placed so far, at the requested Z.
-- Good enough for "here's somewhere that definitely won't collide" --
-- not a bin-packing solver.
function registry.suggest_free_spot(requested_x, requested_z, margin)
	margin = margin or 32
	local entries = registry.load()
	if #entries == 0 then
		return requested_x, requested_z
	end
	local max_x = nil
	for _, entry in ipairs(entries) do
		if not max_x or entry.bbox.x_max > max_x then
			max_x = entry.bbox.x_max
		end
	end
	return max_x + margin, requested_z
end

function registry.list()
	return registry.load()
end

return registry
