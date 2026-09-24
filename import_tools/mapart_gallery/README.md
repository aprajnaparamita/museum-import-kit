# Mapart gallery import pipeline (round 20)

Fills empty item-frame galleries with mapart matched from
`~/dev/museum-maparts/output/final/` and sized to the physical frame
grid. See HANDOFF.md's round 20 writeup for the full story, caveats,
and the real bug found/fixed in the existing captured-map walls at
Tactical Nuke and Fort Alcazar.

## Dithering new pieces

`dither_to_maparts.py` is a faithful Python port of
[rebane2001/mapartcraft](https://github.com/rebane2001/mapartcraft)'s
palette + Floyd-Steinberg error-diffusion dithering, so any image on
disk can be turned into a 128x128 mapart tile without visiting the
browser tool. It writes tiles to the local `./dithered/` directory in
the same `<base_id>_<row>_<col>.png` format as the corpus sources.

The `./dithered/` dir is **a staging area, not an auto-scanned source**
— the library index scans only `~/dev/museum-maparts/output/final/`.
To promote a dithered piece into the gallery pipeline, move (or
symlink) the tile(s) into `~/dev/museum-maparts/output/final/` with the
same `<base_id>_<row>_<col>.png` naming.

```bash
# promote one piece into the live library
mv dithered/cat_mob_1_1.png ~/dev/museum-maparts/output/final/
# or symlink it (lets dither_to_maparts.py regenerate it on a re-run)
ln -sf "$(pwd)/dithered/cat_mob_1_1.png" \
       ~/dev/museum-maparts/output/final/cat_mob_1_1.png
```

After promotion, the next `build_library_index.py` run sees it
automatically (no code change needed).

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
3. `dither_to_maparts.py` -- (optional, pre-step) drop source images
   into the local `dithered/` directory. See "Generating new maparts"
   below. Tiles land in `dithered/` only; promote them into
   `~/dev/museum-maparts/output/final/` to actually feed the pipeline.
4. `build_library_index.py` -- scans `final/`, groups
   `<base_id>_<row>_<col>.png` tiles by base_id, keeps only complete
   grids, writes `/tmp/mapart_library.json`.
5. `build_placement_plan.py` -- matches each empty cluster to a
   library piece of the exact same (rows,cols), falling back to a
   transposed piece (rotated 90 deg) only when exact supply runs out;
   prefers unused pieces, then falls back to reuse. Uses the
   `FACING` table (derived from `core.wallmounted_to_dir`'s real
   0=up/1=down/2=+x/3=-x/4=+z/5=-z convention plus a viewer
   right-hand-rule, both independently verified against a real
   already-filled wall -- see HANDOFF.md) to map cluster (row,col) to
   real frame positions.
6. `render_and_place.py` -- resizes/rotates each matched tile,
   encodes it with `tga_write.py` (a validated Python port of
   `mods/CORE/tga_encoder/init.lua`'s A1R5G5B5 RLE format -- round-trip
   self-tested against `tga_read.py`, itself validated by decoding real
   game-written textures), writes the .tga directly into the
   deployed world's `mcl_maps/` folder, and produces
   `/tmp/gallery_frame_manifest.json` (frame position -> texture id).
7. `place_frames_worldmod.lua` -- one-shot worldmod: reads that
   manifest, creates `mcl_maps:filled_map` ItemStacks with the right
   meta, and sets them into each frame's inventory. Must be removed
   from `worldmods/` after running (it is NOT idempotent -- it also
   unconditionally re-applies the column swap fix on every run).

`tga_read.py`/`tga_write.py` are also generally useful any time this
project needs to inspect or author a real Mineclonia map texture
outside the game engine.

## Generating new maparts (`dither_to_maparts.py`)

Mapartcraft is browser-only, so the *interesting parts* of its pipeline
(palette + dithering + map-tile chunking) are ported to Python here.
The script reads mapartcraft's actual `coloursJSON.json` directly so the
palette stays bit-identical to what the React worker uses.

```bash
# one image, auto-derived base_id, write into the default ./dithered/
python3 dither_to_maparts.py photo.jpg

# explicit base_id + custom tile grid (here: 3 maps wide x 2 maps tall)
python3 dither_to_maparts.py photo.jpg --id meme_42 --tiles 3x2

# batch every image in a directory, one base_id per file
python3 dither_to_maparts.py ~/dev/museum-maparts/images/ --batch

# don't resize -- the input is already 128-aligned (e.g. a render)
python3 dither_to_maparts.py tiles/masterpiece.png --no-resize
```

Defaults are tuned for typical "drop a meme into a gallery frame" use:

- **Mode**: map.dat staircasing ON (3 tones per colour set: dark /
  normal / light) -- this is the standard "staircased" mapart look and
  matches what most people use on `rebane2001.com` by default.
- **Preset**: "Everything" -- all 61 colour sets, default block per set.
- **Dither**: Floyd-Steinberg (the JS worker's default).
- **Resize**: `contain` (letterbox into the tile grid; full image fits,
  background is grass-coloured). Use `--fit cover` for a fill-and-crop
  look.
- **Naming**: `<base_id>_<row>_<col>.png` per 128x128 chunk, matching
  the existing `~/dev/museum-maparts/output/{final,mapartindex,wiki}/`
  convention. The next `build_library_index.py` run picks them up
  automatically.

The colour palette lives in `~/dev/mapartcraft/.../coloursJSON.json`.
Pass `--colours <path>` to use a fork or modified palette. Each tile
takes ~120 ms to dither on a modern Mac, so a 3x2 (6-tile) artwork is
~0.7 s and the whole 276-image corpus is ~30 s at 1 tile each.

Override the colour set selection with `--tones` (e.g.
`--tones unobtainable` to add the unobtainable tones on top of the
standard three -- the "MapDat staircasing ON unobtainable" mapartcraft
mode).
