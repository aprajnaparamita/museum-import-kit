-- Batch fit-check evaluator (round 27, large-scale "check fit in the
-- seed" pass across all 203 bases in the master manifest, per owner
-- request). Runs against a dedicated scratch world on /Volumes/Dara,
-- never the production world.
--
-- Full exhaustive above-sea-level water scans (the validated primary
-- signal from round 25/26) aren't feasible at this scale: total bbox
-- volume across all 203 bases is ~18 BILLION nodes, with several
-- individual bases exceeding 1.6 billion each -- far past any single
-- find_nodes_in_area call's practical limit. Uses a SAMPLED version of
-- the same metric instead: a grid of columns across each base's bbox
-- (SAMPLE_STEP apart), checking each column from sea_level+1 upward for
-- the first non-air/non-ignore node and recording whether it's water.
-- This is an approximation (not exhaustive), appropriate for an
-- "initial stages, check fit" pass -- bases that come back looking
-- borderline can get a full exhaustive re-check later, the same way
-- Tactical Nuke originally did.
--
-- v2 (round 27, first version was too slow): emerging the WHOLE bbox
-- up front before sampling was the real bottleneck -- for a base the
-- size of Fort Alcazar (~200M-node bbox) it took many minutes just to
-- generate terrain for the entire area. v2 tiles each bbox into
-- TILE_SIZE x TILE_SIZE chunks (well under any practical emerge limit),
-- emerging and sampling one tile at a time -- a middle ground between
-- "emerge everything up front" (too slow for big bases) and "emerge
-- per sample point" (too much per-call scheduling overhead for bases
-- with many sample points).
--
-- Params read from /tmp/batch_eval_params.json:
--   {"bases": [{"name":, "footprint_path":, "dest_anchor_x":,
--     "dest_anchor_z":, "dest_y_offset":, "bbox_width":, "bbox_height":}]}
-- Results appended incrementally (one JSON line per base) to
-- /tmp/batch_eval_results.jsonl so a crash mid-run doesn't lose
-- earlier bases' work -- the Python driver skips any base whose name
-- already has a line in that file before building the next batch.
local SAMPLE_STEP = 64
local TILE_SIZE = 400
local sea_level = 1

local results_file = io.open("/tmp/batch_eval_results.jsonl", "a")
results_file:setvbuf("line")

local function log_progress(...)
    local f = io.open("/tmp/batch_eval_progress.txt", "a")
    f:write(string.format(...) .. "\n")
    f:close()
end

local function check_column(x, z, stats)
    stats.n_sampled = stats.n_sampled + 1
    local surf_name = nil
    for y = 60, -40, -1 do
        local node = core.get_node({x=x, y=y, z=z})
        if node.name ~= "air" and node.name ~= "ignore" then
            surf_name = node.name
            break
        end
    end
    if surf_name then
        if surf_name == "mcl_core:water_source" or surf_name == "mcl_core:water_flowing" then
            stats.n_water_surface = stats.n_water_surface + 1
        else
            stats.n_land_surface = stats.n_land_surface + 1
        end
    end
    for y = sea_level + 1, 60 do
        local node = core.get_node({x=x, y=y, z=z})
        if node.name == "mcl_core:water_source" or node.name == "mcl_core:water_flowing" then
            stats.n_above_water = stats.n_above_water + 1
            break
        end
    end
end

core.register_on_mods_loaded(function()
    core.after(2, function()
        local pf = assert(io.open("/tmp/batch_eval_params.json", "r"))
        local params = core.parse_json(pf:read("*a"))
        pf:close()

        local base_idx = 0
        local function next_base()
            base_idx = base_idx + 1
            local b = params.bases[base_idx]
            if not b then
                results_file:close()
                log_progress("BATCH DONE")
                core.request_shutdown("batch eval done", false, 1)
                return
            end

            local ok, err = pcall(function()
                local ff = assert(io.open(b.footprint_path, "r"))
                local footprint = core.parse_json(ff:read("*a"))
                ff:close()

                local x_min = b.dest_anchor_x
                local z_min = b.dest_anchor_z
                local width = b.bbox_width
                local height = b.bbox_height
                local x_max = x_min + width
                local z_max = z_min + height

                -- build the list of tiles covering this bbox
                local tiles = {}
                local tx = x_min
                while tx < x_max do
                    local tz = z_min
                    while tz < z_max do
                        tiles[#tiles+1] = {
                            x1 = tx, x2 = math.min(tx + TILE_SIZE, x_max),
                            z1 = tz, z2 = math.min(tz + TILE_SIZE, z_max),
                        }
                        tz = tz + TILE_SIZE
                    end
                    tx = tx + TILE_SIZE
                end

                local stats = {n_sampled=0, n_above_water=0, n_land_surface=0, n_water_surface=0}
                local tile_idx = 0
                local function next_tile()
                    tile_idx = tile_idx + 1
                    local t = tiles[tile_idx]
                    if not t then
                        local result = {
                            name = b.name,
                            sampled_columns = stats.n_sampled,
                            above_sea_level_water_columns = stats.n_above_water,
                            above_sea_level_water_rate = stats.n_sampled > 0 and (stats.n_above_water / stats.n_sampled) or 0,
                            land_surface_columns = stats.n_land_surface,
                            water_surface_columns = stats.n_water_surface,
                            real_footprint_land = footprint.land_chunks,
                            real_footprint_water = footprint.water_chunks,
                            bbox_width = width, bbox_height = height,
                        }
                        results_file:write(core.write_json(result) .. "\n")
                        results_file:flush()
                        log_progress("[%d/%d] %s: sampled=%d above_water=%d rate=%.3f",
                            base_idx, #params.bases, b.name, stats.n_sampled, stats.n_above_water,
                            stats.n_sampled > 0 and (stats.n_above_water/stats.n_sampled) or 0)
                        next_base()
                        return
                    end

                    local minp = {x=t.x1, y=-40, z=t.z1}
                    local maxp = {x=t.x2, y=60, z=t.z2}
                    core.emerge_area(minp, maxp, function(_, _, calls_remaining)
                        if calls_remaining > 0 then return end
                        core.after(0.1, function()
                            local ok2, err2 = pcall(function()
                                local x = math.ceil(t.x1 / SAMPLE_STEP) * SAMPLE_STEP
                                while x < t.x2 do
                                    local z = math.ceil(t.z1 / SAMPLE_STEP) * SAMPLE_STEP
                                    while z < t.z2 do
                                        check_column(x, z, stats)
                                        z = z + SAMPLE_STEP
                                    end
                                    x = x + SAMPLE_STEP
                                end
                            end)
                            if not ok2 then
                                log_progress("[%d/%d] %s: tile %d/%d ERROR %s",
                                    base_idx, #params.bases, b.name, tile_idx, #tiles, tostring(err2))
                            end
                            next_tile()
                        end)
                    end)
                end
                next_tile()
            end)
            if not ok then
                results_file:write(core.write_json({name=b.name, error=tostring(err)}) .. "\n")
                results_file:flush()
                log_progress("[%d/%d] %s: OUTER ERROR %s", base_idx, #params.bases, b.name, tostring(err))
                next_base()
            end
        end
        next_base()
    end)
end)
