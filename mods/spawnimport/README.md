# spawnimport

A server-side Mineclonia mod that bulk-imports a WorldTools Minecraft world
capture into the running world with one chat command:

```
/worldplace <world_folder> <x> <z> [name] [dimension_path]
```

It reads the raw Anvil region files directly (via
`spawnmasons/lua_import/{nbt,anvil,palette}.lua` -- steps 1-3 of this
project's pipeline, see `../../IMPORT_SPEC.md`), maps every block to its
Mineclonia equivalent, and writes the result with `VoxelManip` in small
batches spread across server steps so a multi-million-block import never
freezes the server. See `../../IMPORT_SPEC.md` and
`../../import_tools/palette_report.md` for how the block mapping was
built and how well it covers the example capture (99.99% exact by block
count).

## Install

1. Copy or symlink this directory (`spawnmasons/server_mod/spawnimport/`)
   into your server's `mods/` folder, or a world's `worldmods/` folder:
   ```
   ln -s /Volumes/Dara/dev/luanti/spawnmasons/server_mod/spawnimport /path/to/your/world/worldmods/spawnimport
   ```
2. **This mod needs unsandboxed filesystem access.** It reads the source
   WorldTools export by absolute path, which lives outside any world/mod
   directory Luanti would normally allow a mod to touch -- there's no way
   around this given what the mod does, so pick one:
   - Add `spawnimport` to `secure.trusted_mods` in `minetest.conf`, or
   - Run the server with `secure.enable_security = false`.

   Either is reasonable for a self-administered creative/museum server;
   neither is something to do on a server you don't fully control.
3. Give the operator the `worldplace` privilege (granted automatically in
   singleplayer; on a real server: `/grant <name> worldplace`, or add it to
   an admin's default privs).
4. By default the mod loads `spawnmasons/lua_import/` from
   `/Volumes/Dara/dev/luanti/spawnmasons/lua_import/` (this project's
   current location). If you've moved the project, set:
   ```
   spawnimport_lua_import_path = /new/path/to/spawnmasons/lua_import/
   ```
   in `minetest.conf`.
5. Optional tuning, also in `minetest.conf`:
   ```
   spawnimport_step_budget_ms = 40
   ```
   How many milliseconds of work `/worldplace` does per server step (default
   40ms). Lower it if imports cause noticeable lag; raise it to import
   faster on a beefier/idle server.

## Commands

- `/worldplace <world_folder> <x> <z> [name] [dimension_path]` -- start an
  import. `name` defaults to the world folder's directory name; only needed
  explicitly if you want a nicer label in `/worldplace list`, or if you're
  placing the same source folder twice.
  `dimension_path` (e.g. `2b2t/2b2t_1`) is only needed if the source folder
  has *more than one* populated dimension -- the mod will tell you the
  available options and ask you to pick if so.
- `/worldplace list` -- show every base placed so far (name, bounds, block
  count, when).
- `/worldplace status` -- progress of the currently running import, if any.
- `/worldplace cancel` -- stop the current import. Blocks already placed
  stay in the world; the (incomplete) base is **not** added to the
  registry, so a later `/worldplace` at the same or an overlapping spot
  won't be refused as a collision.
- `/worldplace force <world_folder> <x> <z> [name] [dimension_path]` --
  same as the plain form, but skips the overlap check against previously
  placed bases.

Only one import runs at a time; starting a new one while another is in
progress is refused (finish or `/worldplace cancel` the current one first).

## Anchor & offset convention

The capture's block-coordinate bounding box (from
`anvil.read_region_extent`) gets its **minimum x/z corner** placed exactly
at `<x> <z>`; every other block keeps its position *relative to that
corner*, so the capture's shape is preserved exactly, just translated. `y`
is never touched -- Minecraft's Y maps 1:1 to Luanti's (see
`IMPORT_SPEC.md`; Luanti's height limit is far larger than Minecraft's).

Concretely, for the example capture (`block_x_min=826352`,
`block_z_min=438144`, from `IMPORT_SPEC.md`): running

```
/worldplace /Volumes/Dara/dev/luanti/spawnmasons 5000 6000 lodge
```

places the source block that was originally at `(826352, y, 438144)` at
destination `(5000, y, 6000)`, and a source block at
`(826400, y, 438200)` (48 east, 56 south of that corner) lands at
`(5048, y, 6056)` -- same offset, carried through unchanged. The reported
destination bounding box in the start-up message (`x[...] z[...]`) is
exactly what gets checked against previously placed bases for overlap.

## How placement is batched

Each server step, the job decodes and places whole source Minecraft chunks
(16x16 columns, full height) one at a time, for up to
`spawnimport_step_budget_ms` of wall-clock time, then yields back to the
engine until the next step -- never one blocking call for the whole
import. Each chunk is written with its own scoped `VoxelManip`
(`read_from_map` sized to just that chunk's placed footprint,
`write_to_map(true)` to recalculate lighting, `update_liquids()` if it
placed any water/lava), so lighting comes out correct without a separate
pass. If imports need to go faster than they're going, the biggest lever
is `write_to_map(false)` + a single `core.fix_light()` at the end instead
of per-chunk lighting -- not done by default because getting lighting
right the first time matters more than raw speed for something people are
going to walk into and explore.

A chunk that fails to decode or place (a corrupt region entry, an
unexpected format) is logged and skipped, not fatal to the whole import --
`/worldplace status` and the final summary both report how many chunks
were skipped.

## Placement registry

Every completed import is recorded (name, source folder, dimension, anchor,
placed bounding box, block count, timestamp) in this mod's own storage
(`core.get_mod_storage()` -- persisted automatically by the engine, not a
separate file). `/worldplace` checks new placements' bounding boxes (X/Z
only -- see the code comment in `registry.lua` for why Y isn't part of the
check) against every existing entry before starting, refuses on overlap
unless `force` is given, and suggests a guaranteed-free spot (past the
edge of everything placed so far) when it does.

## Known limitations

- If the server crashes or is killed mid-import, the partially-placed
  blocks stay in the world but nothing gets added to the registry (same as
  `/worldplace cancel`) -- a later import could end up overlapping it. Not
  auto-detected; if this happens, check the world before re-running.
- No quoted-path support in the command parser -- `world_folder` can't
  contain spaces.
- A resolved node that isn't actually registered in the running game (see
  `palette_report.md`'s handful of best-effort/unverified `mc_to_mcl.json`
  entries) silently falls back to `mcl_core:stone` and logs a warning once
  per node name -- check the server log after a first import for any such
  warnings and fix the mapping in `mc_to_mcl.json` if something looks
  wrong in-world.
