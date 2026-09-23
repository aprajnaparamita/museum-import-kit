# Feature spec: believable loot for imported containers

**Not implemented — for review.**

Fill the empty containers across the imported bases with loot that suits
where each one sits, is generous enough to be worth hunting for, and is
deterministic and re-runnable.

Target deployment is an **anarchy server that resets regularly**. Exploring
old bases for gear is the draw, and players need to be able to kit up and
PvP quickly. So err toward **buff**: this is not survival balance.

---

## 1. The finding that shapes this

**The captures contain no container contents.** Verified across 9 bases:

| base | containers | with `Items` |
|---|---|---|
| iTristan's stash | 2,659 | **0** |
| Epsilon | 1,579 | **0** |
| Island base | 449 | **0** |
| Kerak | 343 | **0** |
| Medina | 255 | **0** |
| Rhodes | 249 | **0** |
| BroBase | 210 | **0** |
| jared2013 & VADemon | 188 | **0** |
| James Rustles | 23 | **0** |
| **total** | **5,955** | **0** |

World-downloaders only record an inventory if the archiver opened that
chest, and 2b2t stashes are emptied long before anyone downloads them. So
contents must be **inferred**, not restored.

**But sign text survives.** 2b2t players label their storage, and the
importer already writes sign text into the world. That is the only real
signal about what a given chest held, and it drives the design below.

## 2. Pipeline

Three stages. Stage 2 is the only one that talks to an external API, and
stage 1 deliberately removes as much work from it as possible.

```
  stage 1  classify every container
             ├─ matches a known structure  ──► Mineclonia loot table   (no API)
             └─ otherwise ──► collect nearby sign text ──┐
                                                          ▼
  stage 2  batched DeepSeek queries: sign text + container ids ──► JSON replies
                                                          │
                                                          ▼
  stage 3  read the JSON, validate every item name, fill the containers
```

Stages are separate executables/passes with files between them, so each can
be re-run without redoing the others. API calls are slow and cost money —
never repeat them because a later stage crashed.

## 3. Stage 1 — classify

**Containers in scope:** chests, trapped chests, barrels, shulker boxes,
ender chests (skip — no shared inventory), and **minecart chests**. Note
minecart chests are *entities*, not nodes, so `find_nodes_in_area` will not
see them; enumerate with `core.get_objects_in_area` or the luaentity list.
Furnaces / hoppers / dispensers: optional, low value.

**Structure matching — these bypass the API entirely** and use Mineclonia's
own tables (`mcl_loot.get_loot` / `get_multi_loot` / `fill_inventory`):

| structure | detect by | table source |
|---|---|---|
| mineshaft | rails within ~10, cobweb + wooden supports | `mcl_levelgen/mineshaft.lua`, `tsm_railcorridors/gameconfig.lua` |
| dungeon | mob spawner within ~8 | `mcl_dungeons/init.lua` |
| village | bell within ~24, or farmland + workstations | `mcl_villages/schemgen.lua` |
| desert/jungle temple | sandstone/mossy-cobble signature, TNT, tripwire | `mcl_levelgen/jungle_temple.lua` |
| ruined portal | obsidian + crying obsidian + netherrack cluster | `mcl_levelgen/ruined_portal.lua` |
| stronghold | end portal frame, bulk stone brick | `mcl_levelgen/stronghold.lua` |
| woodland mansion / outpost / shipwreck | as per their files | `mcl_levelgen/*.lua` |

Several of those tables are file-local (`local schematic_loot_tables = ...`).
If not reachable, copy verbatim with a comment citing file and line — do
not paraphrase from memory.

**Everything else** goes to stage 2, carrying:
- a stable container id (world position)
- all sign text within ~6 blocks, in distance order
- container type, and how many containers are in its cluster
- the base's display name (context: a 2011 dirt hut differs from a 2022 megabase)

Write one JSON file per base: `stage1/<base>.json`.

## 4. Stage 2 — LLM pass

**Batch aggressively.** One request per ~50 containers, not per container.
Tens of thousands of containers exist; per-container calls would be
thousands of requests and hours of latency.

**Cache by content hash.** Key on a hash of (sign text + type + cluster
size). Identical inputs — very common, most chests have no signs at all —
reuse a cached reply and never hit the API twice. Expect the cache to
collapse the request count enormously.

**Containers with no nearby signs should not be sent at all.** There is
nothing to infer from; give them the generic base-loot table from stage 1's
fallback. Only send containers where sign text actually exists.

**Reply schema** — constrain it tightly and validate on read:

```json
{"containers": [
  {"id": "-11629,7,11762",
   "theme": "diamond_gear",
   "confidence": 0.9,
   "items": [{"name": "mcl_core:diamond", "min": 8, "max": 24},
             {"name": "mcl_tools:pick_diamond", "min": 1, "max": 1}]}
]}
```

**Never trust the model's item names.** It will invent plausible-looking
ones. Validate every name against `core.registered_items` dumped from the
running game, and supply that list in the prompt. Anything unknown is
dropped and logged, and if a container loses more than half its items to
validation, fall back to a themed table. This exact class of failure has
already cost this project twice (1,087 signs became stone; `brewing_stand`
pointed at a node that never existed).

**Prefer themes over raw item lists.** Having the model return a *theme*
("armour", "obsidian", "potions", "diamond gear") that maps to a
hand-written table is far more robust than trusting item-level output, and
still captures the intent of the sign. Consider making `items` advisory and
`theme` authoritative.

**Practical notes.** API key from an env var, never in the repo. Log the
prompt and reply for every batch so results are auditable. Sign text is
player-written 2b2t content and includes slurs — you are sending it to a
third-party API; that is a judgement call to flag, and the model may refuse
or moderate some batches, so handle partial replies.

## 5. Stage 3 — apply

- Deterministic: seed `PseudoRandom` from the container's position, so the
  same chest yields the same contents on every run.
- Idempotent: skip containers that already hold items, so the pass can
  resume after a crash.
- Report a histogram of themes actually applied, and every rejected item
  name.

## 6. Generosity

Aim: a player who finds a stash can kit up for PvP in a few chests.

- diamond/netherite gear, frequently enchanted (Protection IV, Sharpness V,
  Mending); full sets rather than single pieces
- golden apples common, enchanted golden apples uncommon rather than rare
- obsidian in near-full stacks — the 2b2t staple
- ender chests, shulker boxes, totems, elytra where thematically apt
- bulk building blocks and ores so bases feel lived-in, not just jackpots
- keep perhaps 3–5% genuinely empty so searching has texture

**Scale with cluster size, don't multiply.** iTristan's stash has **2,659
containers**; a flat 5% jackpot rate is 130 jackpot chests. Cap the top
tier at roughly `min(5% of cluster, 8 + sqrt(cluster_size))` and let the
overflow be bulk.

## 7. Verification

- every itemstring resolves against the running game — fail loudly
- run twice on a copy: contents identical (determinism)
- re-run: nothing added to already-filled containers (idempotency)
- theme histogram for a large stash matches intent
- spot-check in-client: a village chest should read as a village chest
- report containers/second and total runtime

## 8. Performance

One base alone has 2,659 containers; the sampled nine averaged ~660 each,
so expect **tens of thousands** corpus-wide. Dominant cost is loading each
base's volume, not loot generation: tile the bounding box, read once, and
pull containers *and* structure markers *and* signs from that single read.
Avoid per-container VoxelManip reads.

## 9. Open questions

1. Is `theme`-only output (with hand-written tables) acceptable, or do you
   want the model choosing individual items?
2. Sign text goes to a third-party API — any constraint on that?
3. Run after the vast.ai import on that box, or locally afterwards?
4. Minecart chests: worth the extra entity-handling code, or skip?
