-- One-shot live placement for the Tactical Nuke gallery mapart-import
-- task. Two operations:
--   1. Fill the 292 empty item frames surveyed in the room with new
--      custom mapart, per /tmp/gallery_frame_manifest.json (produced by
--      the Python matching pipeline: build_library_index.py ->
--      match_clusters.py/build_placement_plan.py -> render_and_place.py,
--      which already wrote the real .tga texture files into this
--      world's mcl_maps/ folder -- this worldmod only needs to create
--      the ItemStacks and set them into the right frame inventories).
--   2. Fix the one real captured-map wall confirmed (via decoding the
--      real .tga tiles and visually verifying the stitched image forms
--      a coherent picture) to have its left/middle columns swapped:
--      x=5763 <-> x=5762, y=1..3, z=3728.

local out = io.open("/tmp/gallery_place_result.txt", "w")
local function w(...) out:write(string.format(...) .. "\n") end

local modpath = core.get_modpath(core.get_current_modname())

core.register_on_mods_loaded(function()
	core.after(2, function()
		-- Round 29: the original hardcoded room bbox here (5650-5900,
		-- -20..40, 3650-3850) went stale after Tactical Nuke's placement
		-- position changed sometime after round 20's original survey --
		-- confirmed the real current gallery room is at x=7721-7783,
		-- y=1-7, z=-782..-740 directly against gallery_survey.txt/
		-- gallery_frame_manifest.json's own real min/max. If this whole
		-- pipeline is ever re-run against a base whose position has
		-- since moved again, re-derive this from a fresh survey rather
		-- than trusting this hardcoded value blindly.
		local minp, maxp = {x=7700, y=-10, z=-800}, {x=7800, y=20, z=-720}
		core.emerge_area(minp, maxp, function(_, _, calls_remaining)
			if calls_remaining > 0 then return end
			core.after(2, function()
				local ok, err = pcall(function()
					-- ---- Part 1: fill empty frames ----
					local f = assert(io.open(modpath .. "/frame_manifest.json", "r"))
					local manifest = core.parse_json(f:read("*a"))
					f:close()
					w("manifest entries: %d", #manifest)

					local n_placed, n_skipped_notframe, n_skipped_notempty, n_missing_texture = 0, 0, 0, 0
					for _, entry in ipairs(manifest) do
						local pos = {x=entry.x, y=entry.y, z=entry.z}
						local node = core.get_node(pos)
						if node.name ~= "mcl_itemframes:frame" and node.name ~= "mcl_itemframes:glow_frame" then
							n_skipped_notframe = n_skipped_notframe + 1
						else
							local meta = core.get_meta(pos)
							local inv = meta:get_inventory()
							local cur = inv:get_stack("main", 1)
							if not cur:is_empty() then
								n_skipped_notempty = n_skipped_notempty + 1
							else
								local stack = ItemStack("mcl_maps:filled_map")
								local smeta = stack:get_meta()
								smeta:set_string("mcl_maps:id", entry.id)
								smeta:set_string("mcl_maps:minp", core.pos_to_string(
									{x=entry.x-64, y=0, z=entry.z-64}))
								smeta:set_string("mcl_maps:maxp", core.pos_to_string(
									{x=entry.x+63, y=255, z=entry.z+63}))
								smeta:set_int("date", os.time())
								-- tt.reload_itemstack_description (called below)
								-- reads meta "name" (not "description") as the
								-- display-name override, per tt/init.lua's own
								-- logic -- confirmed by reading it directly, not
								-- guessed (it overwrites a bare "description" set
								-- here with its own auto-generated text otherwise).
								if entry.display_name and entry.display_name ~= "" then
									smeta:set_string("name", entry.display_name)
								end
								if tt and tt.reload_itemstack_description then
									tt.reload_itemstack_description(stack)
								end
								inv:set_stack("main", 1, stack)
								n_placed = n_placed + 1
							end
						end
					end
					w("placed: %d  skipped_not_frame: %d  skipped_not_empty: %d",
						n_placed, n_skipped_notframe, n_skipped_notempty)

					-- ---- Part 2: swap the real 3x3 wall's L/M columns ----
					local col_a_x, col_b_x, fixed_z = 5763, 5762, 3728
					local n_swapped = 0
					for y = 1, 3 do
						local pos_a = {x=col_a_x, y=y, z=fixed_z}
						local pos_b = {x=col_b_x, y=y, z=fixed_z}
						local inv_a = core.get_meta(pos_a):get_inventory()
						local inv_b = core.get_meta(pos_b):get_inventory()
						local stack_a = inv_a:get_stack("main", 1)
						local stack_b = inv_b:get_stack("main", 1)
						inv_a:set_stack("main", 1, stack_b)
						inv_b:set_stack("main", 1, stack_a)
						n_swapped = n_swapped + 1
					end
					w("swapped column pairs (3x3 wall fix): %d", n_swapped)
				end)
				if not ok then
					w("ERROR: %s", tostring(err))
				end
				out:close()
				core.request_shutdown("gallery place done", false, 1)
			end)
		end)
	end)
end)
