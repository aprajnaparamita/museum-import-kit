# Feature spec: warp browser UI + forgiving `/warp` matching

Implement in the **`museumwarp`** mod. Self-contained: no changes to the
importer, no re-import needed, works against any already-populated world.

---

## 1. Context you need

**What this is.** A Luanti/Mineclonia world containing ~200 historic 2b2t
Minecraft bases imported from world downloads, packed side by side. Each
base is registered by the `spawnimport` mod; `museumwarp` provides `/warp`
to teleport between them.

**Where the code is.**
- `museumwarp/init.lua` — the mod you are changing
- `spawnimport/registry.lua` — the data source (read-only for you)

`museumwarp` reads the registry through the global
`_G.__spawnimport_registry` (published by `spawnimport`, which is a hard
dependency in `mod.conf`). `core.get_mod_storage()` is scoped per-mod, so
this global is the *only* way to read it — do not try to open the other
mod's storage.

**Registry entry shape** (`registry.list()` returns an array of these):

```lua
{
  name = "Acheron_2021-06-07-1774328116892",   -- raw folder name
  bbox = { x_min=, x_max=, z_min=, z_max=, y_min=, y_max= },
  anchor_x =, anchor_z =, dest_y_offset =,     -- 0 overworld, -27073 End
  block_count = 398954947,
  placed_at = 1786505889,                       -- os.time() of import
  source_folder =, dimension_path =,
  warp_target = { x=, y=, z= },                 -- densest containers/signs
}
```

**Test world:** `~/dev/museum-world-rescue` (189 bases, browsable).
**Server binary:** `~/dev/museum-testrig/bin/luanti`.

**How to run headlessly** — you cannot click a GUI, so drive it in code.
A working rig is already set up and verified (entirely on the internal
disk; the external drive it was built on is failing, do not depend on it):

```bash
cat > /tmp/t.conf <<CONF
secure.enable_security = false
server_announce = false
max_users = 1
port = 30011
spawnimport_lua_import_path = $HOME/dev/museum-world-rescue/lua_import/
CONF

# put a throwaway mod in ~/dev/museum-world-rescue/worldmods/<name>/ that
# calls your code from core.register_on_mods_loaded + core.after, logs with
# core.log, then core.request_shutdown("done", false, 1). Remove it after.

~/dev/museum-testrig/bin/luanti --server --config /tmp/t.conf \
  --world ~/dev/museum-world-rescue --gameid mineclonia \
  --logfile /tmp/t.log < /dev/null

grep "\[yourtag\]" /tmp/t.log
```

Chat commands are callable directly:
`core.registered_chatcommands["warp"].func("singleplayer", "list")`.

**The mod you edit** is `~/dev/museum-world-rescue/worldmods/museumwarp/`.
When done, copy the result to `~/dev/museum-import-kit/mods/museumwarp/`
so the deployable kit stays in sync.

**Use `core.log("action", ...)`, not `core.chat_send_player`.** Chat sent
to a player who isn't connected goes nowhere and is never written to the
log — this has cost real debugging time on this project.

---

## 2. Name parsing (do this first, everything else builds on it)

Folder names are inconsistent. Real examples:

```
Acheron_2021-06-07-1774328116892
Acacia_-_City_of_Melons_2017-01-29-1774300104200
Adrian_Castle_2018-q4-1774286573906
Algul_Siento_2015-1774233437695
AnimeTown2018
Rapture_I_2017_01_07
Space Valkyria III (End)
Endhaven 2024-11-24 (est. 2022-03-13) (End)
Fort Alcazar 2024-04-22 (Th3_L1nk download)
2b2t Doomer14yearsold and PentaKing base-1751895161293(1)
The Citadel Aug 1st 2024-Mewlificent
cutecurly's City
```

Write `parse_name(raw)` returning `{ pretty =, year =, suffix = }`:

- **Strip the upload id**: a trailing `-<10 or more digits>`, optionally
  followed by `(<n>)`. Most names have one; some have none.
- **Extract just the year** (`2021`, not the full date) -- the first
  standalone 4-digit 19xx/20xx. It is only a UI column, so best-effort is
  fine: `nil` when absent, and no need to disentangle
  `2024-11-24 (est. 2022-03-13)` beyond taking the first year found.
  **Dates play no part in matching or sorting.**
- **Keep meaningful parentheticals** as `suffix`: `(End)` matters,
  `(Th3_L1nk download)` is credit. Drop `(1)`.
- **Underscores to spaces**, collapse repeats, trim. `Acacia_-_City_of_Melons`
  → `Acacia - City of Melons`.
- **Never return an empty `pretty`** — fall back to the raw name.

Pure function, no engine calls, so it is directly unit-testable.

---

## 3. `/warp <query>` matching

**Current behaviour:** exact match wins; otherwise substring match — one
hit teleports, zero errors, **more than one refuses and lists candidates**.
The refusal is what we are removing: `/warp A` should just go somewhere.

**New behaviour** — first non-empty tier wins:

1. Exact match on `pretty` (case-insensitive)
2. Exact match on raw `name` (case-insensitive)
3. **Prefix** matches on `pretty`
4. Substring matches on `pretty`
5. Substring matches on raw `name` (so pasting a full folder name works)

Within the winning tier, rank **alphanumerically by `pretty`
(case-insensitive)** and teleport to the first one -- not by length.

So `/warp A` goes to **Acacia - City of Melons**, because it sorts first
among the A-prefixed bases. Not `Asgard`, which is merely the shortest.

Always report what was chosen and what it passed over:

```
[warp] Acacia - City of Melons (2017) -- 15 other matches for "a", try /warp
```

A plain case-insensitive `string.lower()` comparison is acceptable.
Natural-numeric ordering (so `24's farm` sorts as twenty-four) is a
nice-to-have, not a requirement.

Unchanged: `/warp list [page]` keeps working, now showing `pretty` names.

---

## 4. The browser UI

Server-side formspec. **No client-side mod, no player install** — it ships
in the world's `worldmods/` and renders in the stock client.

**Entry points** (all optional, same underlying list):

1. **`/warp` with no arguments** opens it. Currently returns a usage error.
2. **Inventory tab** via `mcl_inventory.register_survival_inventory_tab()`
   (`mcl_inventory/survival.lua:6` — read its def shape first).
   **⚠ This world runs `creative_mode = true`**, so the survival inventory
   may never appear. Verify in creative; if it doesn't show, either also
   register a creative tab or drop this entry point. Do not assume.
3. **A "Museum Compass" item** opening the list on right-click, for a spawn
   chest. Lowest priority of the three.

**Layout** (`formspec_version[7]`, `textlist` scrolls 205 entries fine — no
pagination needed):

```
Search: [____________]   Sort: [Name|Year|Size ▾]
┌──────────────────────────────────────┐
│ Acheron                  2021   399M │
│ Adrian Castle            2018    35M │
│ …                                    │
└──────────────────────────────────────┘
<selected>: 398,954,947 blocks · imported <date> · End
                      [ Warp ]  [ Close ]
```

**Behaviours:**
- Search filters as a case-insensitive substring of `pretty`; empty shows all
- Sort by name, year (undated last), or `block_count`
- Double-clicking a row warps immediately (`textlist` sends `DCL:<idx>`)
- Warp reuses the **existing** `target_pos()` — do not reimplement the
  standing-spot search, it handles `mcl_core:void` and Y-bands correctly
- Mark End-band entries (`dest_y_offset ~= 0`) visibly
- Preserve search/sort/selection when the form reopens after a warp

Handle input in `core.register_on_player_receive_fields`, namespaced
formname (`museumwarp:browser`), and **ignore fields from other formnames**.

---

## 5. Acceptance criteria

- [ ] `/warp Acheron` still teleports exactly as before
- [ ] `/warp <ambiguous>` teleports instead of refusing, and says what else matched
- [ ] `/warp <nonexistent>` still errors helpfully
- [ ] `/warp list` works, showing cleaned names
- [ ] `/warp` with no args opens the browser
- [ ] Browser lists all bases, search and all three sorts work
- [ ] Warping from the browser lands in the build, same as `/warp <name>`
- [ ] `parse_name` unit tests cover every real example in section 2
- [ ] No errors in the server log on load or during use
- [ ] Works on a world with 189 entries *and* one with 0 (fresh world — do
      not crash or show a broken form)

---

## 6. Out of scope

- Anything touching `spawnimport` or requiring a re-import
- Per-base screenshots or map previews
- Changing what the importer writes to the registry
- Biome/appearance work
