-- Multi-candidate destination evaluator (round 25 fitting-algorithm
-- work, v3). Evaluates a LIST of candidate anchors in ONE headless
-- launch, sequentially, calling request_shutdown only once at the very
-- end -- avoiding the real request_shutdown race bug from earlier this
-- round (combining multiple independent request_shutdown-calling
-- worldmods in one launch let the fastest one kill the process before
-- the slower ones ran; see HANDOFF.md's round 25b writeup).
--
-- Primary signal per candidate: an EXHAUSTIVE find_nodes_in_area count
-- of water strictly above the established sea level within the
-- candidate's full bbox -- proven this round to be the exact,
-- predictive signature of the water-intrusion bug class (this is
-- literally how Tactical Nuke's real bug was found and fixed). Sparse
-- per-chunk-center sampling was tried first and rejected: it could
-- easily miss a localized water cluster between sample points.
-- Secondary/contextual signal: real-chunk land/water match rate
-- (cheap, chunk-center sampling is fine here since it's not the
-- pass/fail gate, just informative).
--
-- Params read from /tmp/dest_eval_params.json:
--   {"footprint_path":, "origin_x":, "origin_z":, "dest_y_offset":,
--    "sea_level":, "candidates": [{"anchor_x":, "anchor_z":, "label":}]}
local out = io.open("/tmp/dest_eval_result.json", "w")

local function scan_column_surface(dx, dz, y_top, y_bottom)
    for y = y_top, y_bottom, -1 do
        local node = core.get_node({x=dx, y=y, z=dz})
        if node.name ~= "air" and node.name ~= "ignore" then
            return y, node.name
        end
    end
    return nil, nil
end

core.register_on_mods_loaded(function()
    core.after(2, function()
        local results = {}
        local ok, err = pcall(function()
            local pf = assert(io.open("/tmp/dest_eval_params.json", "r"))
            local params = core.parse_json(pf:read("*a"))
            pf:close()

            local ff = assert(io.open(params.footprint_path, "r"))
            local footprint = core.parse_json(ff:read("*a"))
            ff:close()

            local sea_level = params.sea_level or 1
            local width = footprint.width or 1024
            local height = footprint.height or 1024

            local idx = 0
            local function next_candidate()
                idx = idx + 1
                local cand = params.candidates[idx]
                if not cand then
                    local jf = io.open("/tmp/dest_eval_result.json", "w")
                    jf:write(core.write_json(results))
                    jf:close()
                    core.request_shutdown("dest eval all candidates done", false, 1)
                    return
                end

                local minp = {x=cand.anchor_x, y=sea_level+1, z=cand.anchor_z}
                local maxp = {x=cand.anchor_x+width, y=40, z=cand.anchor_z+height}
                core.emerge_area(minp, maxp, function(_, _, calls_remaining)
                    if calls_remaining > 0 then return end
                    core.after(2, function()
                        local ok2, err2 = pcall(function()
                            -- primary: exhaustive above-sea-level water count
                            local above_water = core.find_nodes_in_area(minp, maxp,
                                {"mcl_core:water_source", "mcl_core:water_flowing"}, false) or {}
                            local bbox_columns = width * height
                            local above_rate = #above_water / bbox_columns

                            -- secondary: real-chunk land/water match, chunk-center sample
                            local n_match, n_checked = 0, 0
                            for _, c in ipairs(footprint.chunks) do
                                local dx = cand.anchor_x + (c.cx * 16 - params.origin_x) + 8
                                local dz = cand.anchor_z + (c.cz * 16 - params.origin_z) + 8
                                local dy, dname = scan_column_surface(dx, dz, 100, -40)
                                if dy then
                                    n_checked = n_checked + 1
                                    local dest_is_water = (dname == "mcl_core:water_source" or dname == "mcl_core:water_flowing")
                                    if dest_is_water == c.is_water then n_match = n_match + 1 end
                                end
                            end

                            results[#results+1] = {
                                label = cand.label,
                                anchor_x = cand.anchor_x,
                                anchor_z = cand.anchor_z,
                                above_sea_level_water_count = #above_water,
                                above_sea_level_water_rate = above_rate,
                                real_chunk_match_pct = n_checked > 0 and (100*n_match/n_checked) or 0,
                                real_chunks_checked = n_checked,
                            }
                        end)
                        if not ok2 then
                            results[#results+1] = { label = cand.label, anchor_x = cand.anchor_x,
                                anchor_z = cand.anchor_z, error = tostring(err2) }
                        end
                        next_candidate()
                    end)
                end)
            end
            next_candidate()
        end)
        if not ok then
            local jf = io.open("/tmp/dest_eval_result.json", "w")
            jf:write(core.write_json({ error = tostring(err) }))
            jf:close()
            core.request_shutdown("dest eval error", false, 1)
        end
    end)
end)
