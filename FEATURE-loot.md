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

**But sign text and item-frame contents survive.** 2b2t players label
their storage *and* decorate chests with item frames showing what's
inside, and the importer already writes both into the world. Together
they are the only real signal about what a given chest held, and they
drive the design below.

## 2. Pipeline

Three stages. Stage 2 is the only one that talks to an external API, and
stage 1 deliberately removes as much work from it as possible.

```
  stage 1  classify every container
             ├─ matches a known structure  ──► Mineclonia loot table   (no API)
             └─ otherwise ──► collect nearby sign text + item frames ──┐
                                                          ▼
  stage 2  per-container Jev decision calls (state = signals, question = choice over 256) ──► probability distributions (cached, concurrent)
                                                          │
                                                          ▼
  stage 3  argmax each distribution, map through the 256-entry vocab, fill the containers
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
- item-frame contents near the container (entities, not nodes — see below)
- container type, and how many containers are in its cluster
- the base's display name (context: a 2011 dirt hut differs from a 2022 megabase)

**Item frames are another signal, distinct from signs.** A frame mounted
on a chest showing a diamond sword is far stronger evidence than any
sign text, because it points at *one specific chest* and shows the
*actual item*. Like minecart chests, item frames are entities, so
`find_nodes_in_area` will not see them — enumerate with
`core.get_objects_in_area` (or the luaentity list). Only frames that
still hold an itemstack are useful; empty frames are noise. Bucket them
per container by distance:

| bucket | radius | weight | rationale |
|---|---|---|---|
| attached | 0 — the frame's anchor node **is** this chest | **strong** | a frame mounted on the chest face (or its top/bottom) is almost certainly showing what's inside |
| near | ≤ 3 blocks | medium | could be decoration, but a cluster of matching frames on a wall of chests is a clear label |
| ambient | > 3 blocks | ignore | too noisy; treat as scenery |

For each attached or near frame, record the itemstring + count of its
visible stack, plus the facing direction if attached (a frame on top
of a chest is weaker evidence than one on its front face — the front
faces the player who placed it). Multiple matching frames in the near
bucket reinforce each other: a row of "diamond sword" frames on a row
of chests is a labelled rack, not coincidence.

Write one JSON file per base: `stage1/<base>.json`.

## 4. Stage 2 — Decisions API pass

**Jev is not a chat model.** It does not generate text. Per its API
reference, it answers typed questions about a *state* (a string, object,
or array) and returns calibrated probabilities — `noul` for yes/no,
`choice` for picking from options you define, `score` for a position
on an ordered rubric. There is no prompt-as-prose / reply-as-prose
loop; there is nothing to parse. The only call shape is
`POST /api/alpha/decisions` with three pieces:

- `model`: `"jev-1.13"` (or whatever the current Openrouter alias is)
- `state`: the container's signals — sign text within ~6 blocks, the
  attached + near item-frame buckets, container type, cluster size
- `question`: a typed question object. We use **`choice`**, with the
  256 vocabulary entries as the options

So the framing of stage 2 is no longer "send a batch of containers and
parse a JSON reply." It is "for each container with at least one
signal, ask Jev which of these 256 bundles fits best, get back a
probability distribution, take the argmax."

**Why Jev, and why over a chat model.** Three reasons:

1. The model cannot invent items. The `choice` question type only
   returns probabilities over the options we hand it. The "1,087 signs
   became stone" / "`brewing_stand` pointed at a node that never
   existed" failures cannot recur from the model's output — only from
   the vocabulary itself, which is reviewable as one file.
2. Calibrated confidence comes for free. Every reply carries the full
   distribution, so we know when the model is unsure (top two options
   close) versus committed. A chat model would have to be coaxed into
   returning calibrated probabilities, and would lie to do so.
3. There is no prose in or out, so the moderation surface is much
   smaller. Sign text still ships, but Jev is not "reading" it the way
   a chat model would.

**One decision per container.** The Decisions API answers one question
about one state per call, so we cannot batch containers the way a chat
model would. Tens of thousands of containers means tens of thousands
of API calls. Three things keep that tractable:

- Most containers have no signals — they go straight to the generic
  base-loot fallback without an API call.
- Cache by content hash. Key on (sign text + item-frame buckets +
  type + cluster size). Identical inputs collapse to one call, and
  many chests share identical signals.
- Fire calls concurrently. The Openrouter rate limit is the
  throughput ceiling; tune worker count to land just under it. Start
  at ~20 in-flight and watch the rate-limit headers.

**Reply shape** — one entry per container, accumulated as calls return:

```json
{"containers": [
  {"id": "-11629,7,11762",
   "selection": 42,
   "confidence": 0.87,
   "probabilities": {"42": 0.87, "17": 0.04, "103": 0.03}}
]}
```

`selection` is `argmax(probabilities)`. `confidence` is the top
probability (confirm the exact field name against the API reference).
We log the full distribution, not just the argmax — it lets us audit
decisions after the fact, spot contested containers, and re-argmax if
the vocabulary file later gains or loses entries (rare, but cheap to
support).

**Validation is structural.** Because `choice` only returns
probabilities over the options we provided, out-of-range values
*cannot* come from the model. The only failure modes are transport
(timeouts, 5xx), shape mismatch (an option in our vocab that Jev
refused to score, or a malformed reply), and rate limiting — all of
which fall back to the generic base-loot table and are logged. There
is no per-item rejection, no fuzzy matching, no fallback ladder.

**The 256-entry vocabulary** is the loot design surface, exactly as
before. Its file format:

```json
{
  "0":   {"name": "diamond_gear_stash",   "items": [...]},
  "1":   {"name": "obsidian_bulk",        "items": [...]},
  ...
  "255": {"name": "..."}
}
```

The vocabulary's `name` fields are what we ship as the `options` list
in each `choice` question — Jev picks by name, and we map the name
back to its integer index (or, equivalently, we ship the indices
directly as the options and pick by index). Either works; pick one and
stick with it so the runner stays simple.

**Practical notes.**

- API key from `OPENROUTER_API_KEY` env var; never in the repo.
- Log every request and reply. The full probability distribution is
  256 floats — log it verbatim. It is small enough to be the audit
  log.
- The Openrouter-specific headers (app name, site URL, etc.) are
  optional and only affect leaderboard ranking. Skip them in the
  runner.
- Retry with exponential backoff on 429/5xx; do not retry on 4xx
  other than 408/429.
- Concurrency: start at ~20 in-flight requests and tune up. Watch
  the rate-limit headers Jev/Openrouter returns and back off if 429s
  start showing.
- Sign text is still player-written 2b2t content and may include
  slurs. The moderation story for the Decisions API may differ from
  chat models — flag this in the runner's docs and decide whether to
  filter or strip sign text before sending.
- Pricing for Jev is per-decision, not per-token, even though the
  model shares a per-token list price with the smaller-context
  alternative. Get a real per-decision number from the Openrouter
  dashboard before sizing the run — the "tens of thousands" estimate
  is now tens of thousands of decisions.

## 5. Stage 3 — apply

- Resolve each container's `selection` index to its 256-entry bundle.
  The bundle is a hand-written loot table (items + counts + weights),
  applied with the same `mcl_loot` / `fill_inventory` primitives used
  for the structure-matched containers in stage 1.
- Deterministic: seed `PseudoRandom` from the container's position, so
  the same chest yields the same contents on every run.
- Idempotent: skip containers that already hold items, so the pass can
  resume after a crash.
- Report a histogram of selections actually applied, and any selections
  rejected (out-of-range, missing from the vocabulary file).

## 6. Generosity

Aim: a player who finds a stash can kit up for PvP in a few chests.

The 256-entry vocabulary is where this lives — every bundle should be
drawn from the same palette, and the vocabulary builder should be told
that the corpus, taken together, must hit these targets:

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
- selection histogram (which of the 256 bundles were chosen) matches
  intent for a large stash
- spot-check in-client: a village chest should read as a village chest
- report containers/second and total runtime

## 8. Performance

One base alone has 2,659 containers; the sampled nine averaged ~660 each,
so expect **tens of thousands** corpus-wide. Two cost axes, in order:

1. **Volume read.** Dominant cost on the local side: tile the bounding
   box, read once, and pull containers *and* structure markers *and*
   signs *and* item-frame entities from that single read. Avoid
   per-container VoxelManip reads.
2. **API calls.** "Tens of thousands" of containers is now tens of
   thousands of Jev decisions, not tens of thousands of batched chat
   completions. Cache hits (identical signals) and signal-free
   containers (skipped) keep the live call count well below the
   container count; concurrency is the throughput lever, not
   batching.

## 9. Open questions

1. Vocabulary shape — 256 entries is the working assumption, but the
   final size is owned by the separate vocab-building process. Confirm
   256 is the target before the runner is implemented, and decide
   whether the vocabulary file ships in the repo or is downloaded at
   run time.
2. Sign text + item-frame contents go to a third-party API
   (Openrouter). The moderation story for the Decisions API may differ
   from chat models; flag in the runner's docs and decide whether to
   filter or strip sign text before sending.
3. Jev API specifics — confirm against the API reference before
   implementation: exact request field names, exact response field
   names (especially the calibrated-confidence field), and whether
   `choice` returns the distribution as `{option: probability}` or
   some other shape.
4. Pricing model — Jev is per-decision, not per-token. Get a real
   per-decision number from the Openrouter dashboard before sizing
   the run.
5. Concurrency ceiling — what's the practical rate limit for Jev on
   our Openrouter tier? Sets the worker pool size and total wall-
   clock for the corpus.
6. Run after the vast.ai import on that box, or locally afterwards?
7. Minecart chests: worth the extra entity-handling code, or skip?
