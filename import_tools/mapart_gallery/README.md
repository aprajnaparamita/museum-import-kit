# Mapart gallery import pipeline (round 20)

Fills empty item-frame galleries with mapart matched from
`~/dev/museum-maparts/output/final/` and sized to the physical frame
grid. See HANDOFF.md's round 20 writeup for the full story, caveats,
and the real bug found/fixed in the existing captured-map walls at
Tactical Nuke and Fort Alcazar.

The single source is `~/dev/museum-maparts/output/final/` -- the
curated set of 20 pieces / 121 `<base_id>_<row>_<col>.png` tiles.
No other source directory is scanned: `~/dev/museum-maparts/output/{mapartindex,wiki}/`
exist on disk but are intentionally excluded.

Run order (all scripts hardcode `/tmp` intermediate files and the
deployed world path `~/Library/Application Support/minetest/worlds/2b2t
Museum TEST` -- written for this one round's run, not a polished CLI;
adjust paths before reusing for another gallery/base):

1. A Lua worldmod survey against the target room's bounding box dumps
   every item frame's position/param2/fill-state to `/tmp/gallery_survey.txt`
   (see HANDOFF.md for the exact snippet -- not checked in separately).
2. Cluster the survey into rectangular frame-groups (3D BFS keyed on
   `param2` as a hard constraint, Chebyshev distance <=2 to tolerate
   alcove/recess stepping) -- produces `/tmp/gallery_clusters.json`.
3. `build_library_index.py` -- scans `final/`, groups
   `<base_id>_<row>_<col>.png` tiles by base_id, keeps only complete
   grids, writes `/tmp/mapart_library.json`.
4. `build_placement_plan.py` -- matches each empty cluster to a
   library piece of the exact same (rows,cols), falling back to a
   transposed piece (rotated 90 deg) only when exact supply runs out;
   prefers unused pieces, then falls back to reuse. Uses the
   `FACING` table (derived from `core.wallmounted_to_dir`'s real
   0=up/1=down/2=+x/3=-x/4=+z/5=-z convention plus a viewer
   right-hand-rule, both independently verified against a real
   already-filled wall -- see HANDOFF.md) to map cluster (row,col) to
   real frame positions.
5. `render_and_place.py` -- resizes/rotates each matched tile,
   encodes it with `tga_write.py` (a validated Python port of
   `mods/CORE/tga_encoder/init.lua`'s A1R5G5B5 RLE format -- round-trip
   self-tested against `tga_read.py`, itself validated by decoding real
   game-written textures), writes the .tga directly into the
   deployed world's `mcl_maps/` folder, and produces
   `/tmp/gallery_frame_manifest.json` (frame position -> texture id).
6. `place_frames_worldmod.lua` -- one-shot worldmod: reads that
   manifest, creates `mcl_maps:filled_map` ItemStacks with the right
   meta, and sets them into each frame's inventory. Must be removed
   from `worldmods/` after running (it is NOT idempotent -- it also
   unconditionally re-applies the column swap fix on every run).

`tga_read.py`/`tga_write.py` are also generally useful any time this
project needs to inspect or author a real Mineclonia map texture
outside the game engine.
