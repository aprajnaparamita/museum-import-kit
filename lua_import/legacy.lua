-- legacy.lua -- Minecraft 1.12 (pre-flattening, DataVersion <= 1343)
-- numeric block id+meta -> modern block name + properties.
--
-- Why this exists (2026-09-25): the only Nether captures in the museum
-- corpus ("Base (by Hausemaster, friends, 2012)" and "Taylobase 4") are
-- 1.12-format WDLs; the importer targets 1.18+ chunk NBT and hard-errors
-- on anything else. The owner asked for a Nether base in the test world,
-- so this table decodes the legacy Sections (Blocks byte array + Data
-- nibbles) into the modern name/property vocabulary that
-- lua_import/palette.lua already resolves to Mineclonia nodes (including
-- param2 for stairs/torches/hoppers/etc -- no conversion logic is
-- duplicated here, only the id/property vocabulary).
--
-- 2026-09-26 audit: every id in this table was checked against the
-- canonical pre-flattening id list (minecraft.wiki "Java Edition
-- pre-flattening data values/Block IDs" -- 256 rows in id order, anchored
-- against tile-entity evidence from the real captures: id 52 carries a
-- minecraft:mob_spawner TE, id 63 a minecraft:sign TE, id 130 a
-- minecraft:ender_chest TE, id 213 = magma). The audit found a whole
-- class of shift mislabels beyond the earlier 152/153/154 hopper fix --
-- coal blocks imported as PACKED ICE (173), terracotta as coal blocks
-- (172), droppers as activator rails (157), cauldrons as end portal
-- frames (118), nether brick stairs as nether wart (114) etc. All fixed
-- here; the metadata semantics (repeater delay, comparator mode, button
-- face, bed head/foot, trapdoor side, cocoa age, ...) were taken from the
-- wiki's block-data tables, not memory. Known deliberate gaps remain:
-- tripwire/tripwire_hook/command blocks have no Mineclonia node at all
-- (they degrade to stone with a logged warning, exactly like the modern
-- capture path), and mob-head TYPE + skull floor rotation live in the
-- chunk's TileEntity (not decoded here -- skeleton assumed).
--
-- The table covers the common 1.12 block set; the Nether captures
-- actually use a few dozen id/meta pairs (verified by scan -- see
-- import_tools/legacy_id_audit.py) and are marked in the comments.
-- Unknown ids degrade to stone with a logged warning.

local legacy = {}

-- facing helpers: 1.12's facing codes differ per family (wiki block-data
-- tables -- do NOT assume one convention):
local H_CHEST = {[2]="north",[3]="south",[4]="west",[5]="east"}   -- chest/furnace/ladder/hopper/dispenser/dropper/wall sign/skull
local H_STAIR = {[0]="east",[1]="west",[2]="south",[3]="north"}   -- stairs
local H_TORCH = {[1]="east",[2]="west",[3]="south",[4]="north"}   -- torch/lever-ish/button wall
local H_TRAP  = {[0]="south",[1]="north",[2]="east",[3]="west"}   -- trapdoor (wiki: 0 south side, 1 north, 2 east, 3 west)
local H_DIODE = {[0]="north",[1]="east",[2]="south",[3]="west"}   -- repeater/comparator (wiki)
local H_BED   = {[0]="south",[1]="west",[2]="north",[3]="east"}   -- bed head facing (wiki)
local H_SHULK = {[0]="down",[1]="up",[2]="north",[3]="south",[4]="east",[5]="west"}
local function face(map, meta, mod) return map[(mod and (meta % mod) or meta)] end

-- wool/concrete/terracotta/carpet meta -> colour (0-15)
local COLORS = {"white","orange","magenta","light_blue","yellow","lime","pink",
	"gray","light_gray","cyan","purple","blue","brown","green","red","black"}

-- planks/log/fence meta -> species
local WOOD = {"oak","spruce","birch","jungle","acacia","dark_oak"}
local LOG1 = {"oak","spruce","birch","jungle"}
-- 1.12 red_flower (id 38) meta -> modern flower name
local FLOWER = {"poppy","blue_orchid","allium","azure_bluet","red_tulip",
	"orange_tulip","white_tulip","pink_tulip","oxeye_daisy"}
-- 1.12 double_plant (id 175) meta -> modern name
local DOUBLE_PLANT = {"sunflower","lilac","tall_grass","large_fern","rose_bush","peony"}
-- 1.12 stone slab (43/44) meta&7 -> material
local SLAB_MAT = {"stone_slab","sandstone_slab","oak_slab","cobblestone_slab",
	"brick_slab","stone_brick_slab","nether_brick_slab","quartz_slab"}

local P = {} -- [id] = { default={name=,props=}, [meta]={...} }
local function blk(id, entry) P[id] = entry end

-- stairs: facing metas 0-3 (+4 = upside-down half)
local function stairs(id, name)
	local e = { default={name=name, props={facing="east", half="bottom"}} }
	for m, f in pairs(H_STAIR) do
		e[m] = {name=name, props={facing=f, half="bottom"}}
		e[m + 4] = {name=name, props={facing=f, half="top"}}
	end
	P[id] = e
end

-- single-material slab: meta&7 ignored (one material), bit 3 = top half
local function slabmat(id, name)
	local e = {}
	for m = 0, 7 do e[m] = {name=name, props={type="bottom"}} end
	for m = 8, 15 do e[m] = {name=name, props={type="top"}} end
	e.default = e[0]
	P[id] = e
end

-- horizontal-facing block with up/down variants (hopper/dispenser/dropper style)
local function hface(id, entry)
	entry[0] = entry[0] or {name=entry.default.name, props={facing="down"}}
	entry[1] = entry[1] or {name=entry.default.name, props={facing="up"}}
	for m, f in pairs(H_CHEST) do
		entry[m] = {name=entry.default.name, props={facing=f}}
	end
	P[id] = entry
end

-- terrain basics
blk(1,  { default={name="minecraft:stone"}, [1]={name="minecraft:granite"}, [2]={name="minecraft:polished_granite"},
	[3]={name="minecraft:diorite"}, [4]={name="minecraft:polished_diorite"},
	[5]={name="minecraft:andesite"}, [6]={name="minecraft:polished_andesite"} })
blk(2,  { default={name="minecraft:grass_block"} })
blk(3,  { default={name="minecraft:dirt"}, [1]={name="minecraft:coarse_dirt"}, [2]={name="minecraft:podzol"} })
blk(4,  { default={name="minecraft:cobblestone"} })
blk(5,  { default={name="minecraft:oak_planks"} }) -- metas are species; resolved below
for m, w in ipairs(WOOD) do P[5][m - 1] = {name="minecraft:" .. w .. "_planks"} end
blk(6,  { default={name="minecraft:oak_sapling"} }) -- meta&7 species (3 = jungle ...)
for m, w in ipairs(WOOD) do P[6][m - 1] = {name="minecraft:" .. w .. "_sapling"} end
blk(7,  { default={name="minecraft:bedrock"} })
blk(8,  { default={name="minecraft:water", props={level="0"}} }) -- flowing: meta = level
for m = 0, 15 do P[8][m] = {name="minecraft:water", props={level=tostring(m)}} end
blk(9,  { default={name="minecraft:water", props={level="0"}} }) -- still
blk(10, { default={name="minecraft:lava", props={level="0"}} })  -- flowing: meta = level (seen 0-15)
for m = 0, 15 do P[10][m] = {name="minecraft:lava", props={level=tostring(m)}} end
blk(11, { default={name="minecraft:lava", props={level="0"}} })  -- still (nether seas)
blk(12, { default={name="minecraft:sand"}, [1]={name="minecraft:red_sand"} })
blk(13, { default={name="minecraft:gravel"} })
blk(14, { default={name="minecraft:gold_ore"} })
blk(15, { default={name="minecraft:iron_ore"} })
blk(16, { default={name="minecraft:coal_ore"} })
blk(17, { default={name="minecraft:oak_log"} }) -- meta&3 species (0-3), rest = axis/bark
for m = 0, 15 do P[17][m] = {name="minecraft:" .. LOG1[(m % 4) + 1] .. "_log"} end
blk(18, { default={name="minecraft:oak_leaves"} }) -- meta&3 species, 4-15 = decay flags
for m = 0, 15 do P[18][m] = {name="minecraft:" .. LOG1[(m % 4) + 1] .. "_leaves"} end
blk(19, { default={name="minecraft:sponge"}, [1]={name="minecraft:wet_sponge"} })
blk(20, { default={name="minecraft:glass"} })
blk(21, { default={name="minecraft:lapis_ore"} })
blk(22, { default={name="minecraft:lapis_block"} })
hface(23, { default={name="minecraft:dispenser", props={facing="down"}} })
blk(24, { default={name="minecraft:sandstone"}, [1]={name="minecraft:chiseled_sandstone"}, [2]={name="minecraft:smooth_sandstone"} })
blk(25, { default={name="minecraft:note_block"} })
-- 26 = red bed (all 1.12 beds are red). meta&3 head facing, 0x4 occupied, 0x8 head end
blk(26, { default={name="minecraft:red_bed", props={part="foot"}} })
for m = 0, 15 do
	P[26][m] = {name="minecraft:red_bed",
		props={part=(m >= 8) and "head" or "foot", facing=face(H_BED, m % 4)}}
end
blk(27, { default={name="minecraft:powered_rail"} }) -- metas: shape+powered (seen 0,1,8-13)
blk(28, { default={name="minecraft:detector_rail"} })
blk(29, { default={name="minecraft:sticky_piston", props={extended="false"}} })
blk(30, { default={name="minecraft:cobweb"} })
blk(31, { default={name="minecraft:short_grass"}, [0]={name="minecraft:dead_bush"}, [2]={name="minecraft:fern"} })
blk(32, { default={name="minecraft:dead_bush"} })
blk(33, { default={name="minecraft:piston", props={extended="false"}} })
-- 34 piston head / 36 piston extension: rough map to the piston pusher
-- (rare, mostly transient)
blk(34, { default={name="minecraft:piston_head", props={type="normal"}} })
blk(36, { default={name="minecraft:piston_head", props={type="normal"}} })
blk(35, { default={name="minecraft:white_wool"} })
for m, c in ipairs(COLORS) do P[35][m - 1] = {name="minecraft:" .. c .. "_wool"} end
blk(37, { default={name="minecraft:dandelion"} })
blk(38, { default={name="minecraft:poppy"} })
for m, f in ipairs(FLOWER) do P[38][m - 1] = {name="minecraft:" .. f} end
blk(39, { default={name="minecraft:brown_mushroom"} }) -- seen
blk(40, { default={name="minecraft:red_mushroom"} })   -- seen
blk(41, { default={name="minecraft:gold_block"} })
blk(42, { default={name="minecraft:iron_block"} })
-- 43 double stone slab / 44 stone slab: meta&7 = material, 0x8 = top half
blk(43, { default={name="minecraft:stone_slab", props={type="double"}} })
for m = 0, 7 do P[43][m] = {name="minecraft:" .. SLAB_MAT[m + 1], props={type="double"}} end
blk(44, { default={name="minecraft:stone_slab", props={type="bottom"}} })
for m = 0, 15 do P[44][m] = {name="minecraft:" .. SLAB_MAT[(m % 8) + 1],
	props={type=(m >= 8) and "top" or "bottom"}} end
blk(45, { default={name="minecraft:bricks"} })
blk(46, { default={name="minecraft:tnt"} })
blk(47, { default={name="minecraft:bookshelf"} }) -- seen
blk(48, { default={name="minecraft:mossy_cobblestone"} })
blk(49, { default={name="minecraft:obsidian"} }) -- seen
-- 50 torch: meta 5 = floor, 1-4 = wall facing
blk(50, { default={name="minecraft:torch"} }) -- metas 1-5 seen
for m, f in pairs(H_TORCH) do P[50][m] = {name="minecraft:wall_torch", props={facing=f}} end
blk(51, { default={name="minecraft:fire"} })     -- meta 15 seen
blk(52, { default={name="minecraft:spawner"} })  -- seen (TE minecraft:mob_spawner)
stairs(53, "minecraft:oak_stairs")
blk(54, { default={name="minecraft:chest"} })    -- metas 2,4,5 seen
for m, f in pairs(H_CHEST) do P[54][m] = {name="minecraft:chest", props={facing=f}} end
blk(55, { default={name="minecraft:redstone_wire"} }) -- power metas seen
blk(56, { default={name="minecraft:diamond_ore"} })
blk(57, { default={name="minecraft:diamond_block"} }) -- seen
blk(58, { default={name="minecraft:crafting_table"} })
blk(59, { default={name="minecraft:wheat"} }) -- crop age metas 0-7
blk(60, { default={name="minecraft:farmland"} })
blk(61, { default={name="minecraft:furnace"} })  -- meta 3 seen
for m, f in pairs(H_CHEST) do P[61][m] = {name="minecraft:furnace", props={facing=f}} end
-- 62 lit furnace (separate legacy id)
blk(62, { default={name="minecraft:furnace", props={lit="true"}} })
for m, f in pairs(H_CHEST) do P[62][m] = {name="minecraft:furnace", props={lit="true", facing=f}} end
-- 63 standing sign: meta = rotation 0-15 (rotation itself lives in the TE
-- for old formats; meta carries it in 1.8-1.12)
blk(63, { default={name="minecraft:oak_sign"} }) -- seen
for m = 0, 15 do P[63][m] = {name="minecraft:oak_sign", props={rotation=tostring(m)}} end
blk(64, { default={name="minecraft:oak_door"} })
-- 65 ladder: facing metas 2-5
blk(65, { default={name="minecraft:ladder"} }) -- metas 2-4 seen
for m, f in pairs(H_CHEST) do P[65][m] = {name="minecraft:ladder", props={facing=f}} end
blk(66, { default={name="minecraft:rail"} })     -- seen
stairs(67, "minecraft:cobblestone_stairs")       -- metas 0-7 seen
-- 68 wall sign: facing metas 2-5
blk(68, { default={name="minecraft:oak_wall_sign"} }) -- seen
for m, f in pairs(H_CHEST) do P[68][m] = {name="minecraft:oak_wall_sign", props={facing=f}} end
blk(69, { default={name="minecraft:lever"} })     -- metas 4,9 seen (face/rotation not decoded)
blk(70, { default={name="minecraft:stone_pressure_plate"} }) -- seen
blk(71, { default={name="minecraft:iron_door"} }) -- seen
blk(72, { default={name="minecraft:oak_pressure_plate"} })
blk(73, { default={name="minecraft:redstone_ore"} })
blk(74, { default={name="minecraft:redstone_ore"} }) -- lit variant (no lit node in Mineclonia)
-- 75 unlit redstone torch / 76 lit: meta 5 = floor, 1-4 = wall
blk(75, { default={name="minecraft:redstone_torch", props={lit="false"}} }) -- seen
blk(76, { default={name="minecraft:redstone_torch", props={lit="true"}} })  -- seen
for m, f in pairs(H_TORCH) do
	P[75][m] = {name="minecraft:redstone_wall_torch", props={lit="false", facing=f}}
	P[76][m] = {name="minecraft:redstone_wall_torch", props={lit="true", facing=f}}
end
-- 77 stone button: 0x1|0x2|0x4 = face (0 ceiling/down, 1-4 wall E/W/S/N, 5
-- floor/up), 0x8 = powered (wiki block-data table)
local function button(id, name)
	local e = { default={name=name, props={face="wall"}} }
	for m = 0, 7 do
		local b = m % 8
		local powered = m >= 8 and "true" or "false"
		if b == 0 then
			e[m] = {name=name, props={face="ceiling", powered=powered}}
		elseif b == 5 then
			e[m] = {name=name, props={face="floor", powered=powered}}
		else
			e[m] = {name=name, props={face="wall", facing=face(H_TORCH, b), powered=powered}}
		end
	end
	for m = 8, 15 do
		local src = e[m - 8]
		e[m] = {name=src.name, props={face=src.props.face, facing=src.props.facing, powered="true"}}
	end
	P[id] = e
end
button(77, "minecraft:stone_button") -- seen
blk(78, { default={name="minecraft:snow"} })
blk(79, { default={name="minecraft:ice"} })
blk(80, { default={name="minecraft:snow_block"} })
blk(81, { default={name="minecraft:cactus"} })
blk(82, { default={name="minecraft:clay"} })
blk(83, { default={name="minecraft:sugar_cane"} })
blk(84, { default={name="minecraft:jukebox"} })
blk(85, { default={name="minecraft:oak_fence"} }) -- meta 0 seen
for m, w in ipairs(WOOD) do P[85][m - 1] = {name="minecraft:" .. w .. "_fence"} end
-- 86 carved pumpkin: facing metas 0-3 (H_BED order)
blk(86, { default={name="minecraft:carved_pumpkin"} })
for m, f in pairs(H_BED) do P[86][m] = {name="minecraft:carved_pumpkin", props={facing=f}} end
blk(87, { default={name="minecraft:netherrack"} }) -- 28M+ seen
blk(88, { default={name="minecraft:soul_sand"} })  -- seen
blk(89, { default={name="minecraft:glowstone"} })  -- seen
blk(90, { default={name="minecraft:nether_portal"} }) -- axis metas 1,2 seen
blk(91, { default={name="minecraft:jack_o_lantern"} })
for m, f in pairs(H_BED) do P[91][m] = {name="minecraft:jack_o_lantern", props={facing=f}} end
blk(92, { default={name="minecraft:cake"} }) -- bite metas 0-6
-- 93 unpowered repeater / 94 powered: meta&3 facing (H_DIODE), meta>>2 delay-1
-- (wiki block-data table). The palette's repeater handler consumes
-- delay/powered; facing is not representable there.
local function diode(id, powered)
	local e = { default={name="minecraft:repeater", props={powered=powered, delay="1"}} }
	for m = 0, 15 do
		e[m] = {name="minecraft:repeater", props={
			powered=powered, delay=tostring((math.floor(m / 4) % 4) + 1),
			facing=face(H_DIODE, m % 4)}}
	end
	P[id] = e
end
diode(93, "false")
diode(94, "true")
-- 95 stained glass (locked block, rarely placed): colours
blk(95, { default={name="minecraft:white_stained_glass"} })
for m, c in ipairs(COLORS) do P[95][m - 1] = {name="minecraft:" .. c .. "_stained_glass"} end
-- 96 wooden (=oak) trapdoor: meta&3 side (H_TRAP), 0x4 open, 0x8 top half
blk(96, { default={name="minecraft:oak_trapdoor"} })
for m = 0, 15 do
	P[96][m] = {name="minecraft:oak_trapdoor", props={
		facing=face(H_TRAP, m % 4), open=(m >= 4 and m < 8) and "true" or "false",
		half=(m >= 8) and "top" or "bottom"}}
end
-- 97 monster egg (silverfish): meta 0-5 lookalike stone/cobble/stonebrick...
-- meta 0 keeps the infested node; 1-5 map to their non-infested lookalikes
-- (Mineclonia only registers the plain-stone infested variant).
blk(97, { default={name="minecraft:infested_stone"},
	[1]={name="minecraft:cobblestone"}, [2]={name="minecraft:stone_bricks"},
	[3]={name="minecraft:mossy_stone_bricks"}, [4]={name="minecraft:cracked_stone_bricks"},
	[5]={name="minecraft:chiseled_stone_bricks"} })
blk(98, { default={name="minecraft:stone_bricks"}, [1]={name="minecraft:mossy_stone_bricks"},
	[2]={name="minecraft:cracked_stone_bricks"}, [3]={name="minecraft:chiseled_stone_bricks"} }) -- 0,2,3 seen
-- 99/100 huge mushrooms: meta 15 = all-stem; other metas = cap/pore combos
blk(99,  { default={name="minecraft:brown_mushroom_block"}, [15]={name="minecraft:mushroom_stem"} })
blk(100, { default={name="minecraft:red_mushroom_block"},  [15]={name="minecraft:mushroom_stem"} })
blk(101, { default={name="minecraft:iron_bars"} })
blk(102, { default={name="minecraft:glass_pane"} }) -- seen
blk(103, { default={name="minecraft:melon"} })
-- 104/105 stems: age 0-6 growing, 7 = attached
blk(104, { default={name="minecraft:pumpkin_stem"}, [7]={name="minecraft:attached_pumpkin_stem"} })
blk(105, { default={name="minecraft:melon_stem"},   [7]={name="minecraft:attached_melon_stem"} })
-- 106 vines: bit per face (0x1 south ... 0x8 west); palette keeps one face
blk(106, { default={name="minecraft:vine"} })
-- 107 oak fence gate: facing metas
blk(107, { default={name="minecraft:oak_fence_gate"} })
for m, f in pairs(H_BED) do P[107][m] = {name="minecraft:oak_fence_gate", props={facing=f}} end
stairs(108, "minecraft:brick_stairs")
stairs(109, "minecraft:stone_brick_stairs")
blk(110, { default={name="minecraft:mycelium"} })
blk(111, { default={name="minecraft:lily_pad"} })
blk(112, { default={name="minecraft:nether_bricks"} })       -- 70k seen
blk(113, { default={name="minecraft:nether_brick_fence"} })  -- seen
-- 114-127 pre-2026-09-26 shift audit: these were ALL off by one or more
-- (114 was labelled nether_wart, 122 redstone_lamp, 127 quartz_slab ...)
stairs(114, "minecraft:nether_brick_stairs")
blk(115, { default={name="minecraft:nether_wart"} })         -- age metas 0-3
for m = 0, 3 do P[115][m] = {name="minecraft:nether_wart", props={age=tostring(m)}} end
blk(116, { default={name="minecraft:enchanting_table"} })    -- seen
blk(117, { default={name="minecraft:brewing_stand"} })       -- seen
blk(118, { default={name="minecraft:cauldron"} })            -- seen
blk(119, { default={name="minecraft:end_portal"} })
-- 120 end portal frame: meta&3 facing, 0x4 = eye (eye not representable)
blk(120, { default={name="minecraft:end_portal_frame"} })
for m, f in pairs(H_BED) do P[120][m] = {name="minecraft:end_portal_frame", props={facing=f}} end
blk(121, { default={name="minecraft:end_stone"} })
blk(122, { default={name="minecraft:dragon_egg"} })
-- 123 unlit / 124 lit redstone lamp (separate legacy ids)
blk(123, { default={name="minecraft:redstone_lamp", props={lit="false"}} })
blk(124, { default={name="minecraft:redstone_lamp", props={lit="true"}} })
-- 125 double wooden slab / 126 wooden slab: meta&7 species, 0x8 = top half
blk(125, { default={name="minecraft:oak_slab", props={type="double"}} })
for m, w in ipairs(WOOD) do P[125][m - 1] = {name="minecraft:" .. w .. "_slab", props={type="double"}} end
blk(126, { default={name="minecraft:oak_slab", props={type="bottom"}} })
for m = 0, 15 do
	P[126][m] = {name="minecraft:" .. WOOD[math.min(6, (m % 8) + 1)] .. "_slab",
		props={type=(m >= 8) and "top" or "bottom"}}
end
-- 127 cocoa: meta&3 pod direction, meta>>2 age (0-2)
blk(127, { default={name="minecraft:cocoa", props={age="2"}} })
for m = 0, 15 do
	P[127][m] = {name="minecraft:cocoa", props={age=tostring(math.min(2, math.floor(m / 4)))}}
end
stairs(128, "minecraft:sandstone_stairs")
blk(129, { default={name="minecraft:emerald_ore"} })
blk(130, { default={name="minecraft:ender_chest"} }) -- metas 2,4 seen (TE minecraft:ender_chest)
for m, f in pairs(H_CHEST) do P[130][m] = {name="minecraft:ender_chest", props={facing=f}} end
-- 131 tripwire hook / 132 tripwire: NO Mineclonia node exists (documented
-- known gap, same as the modern capture path) -- left unmapped on purpose.
blk(133, { default={name="minecraft:emerald_block"} })
stairs(134, "minecraft:spruce_stairs")
stairs(135, "minecraft:birch_stairs")
stairs(136, "minecraft:jungle_stairs")
-- 137/210/211 command blocks: no Mineclonia equivalent -> left unmapped
blk(138, { default={name="minecraft:beacon"} })
blk(139, { default={name="minecraft:cobblestone_wall"}, [1]={name="minecraft:mossy_cobblestone_wall"} })
blk(140, { default={name="minecraft:flower_pot"} })
blk(141, { default={name="minecraft:carrots"} }) -- age metas 0-7
blk(142, { default={name="minecraft:potatoes"} }) -- age metas 0-7
button(143, "minecraft:oak_button")
-- 144 mob head/skull: meta 1 = floor (rotation in TE), 2-5 = wall facing
-- (wiki block-data table). Head TYPE is in the TileEntity too, so all
-- heads decode as skeleton here -- see the header comment.
blk(144, { default={name="minecraft:skeleton_skull", props={rotation="0"}} })
P[144][1] = {name="minecraft:skeleton_skull", props={rotation="0"}}
for m, f in pairs(H_CHEST) do P[144][m] = {name="minecraft:skeleton_wall_skull", props={facing=f}} end
blk(145, { default={name="minecraft:anvil"} }) -- meta 5 seen (damage 0-2 = anvil/chipped/damaged)
P[145][1] = {name="minecraft:chipped_anvil"} P[145][2] = {name="minecraft:damaged_anvil"}
blk(146, { default={name="minecraft:trapped_chest"} }) -- meta 2 seen
for m, f in pairs(H_CHEST) do P[146][m] = {name="minecraft:trapped_chest", props={facing=f}} end
blk(147, { default={name="minecraft:light_weighted_pressure_plate"} })
blk(148, { default={name="minecraft:heavy_weighted_pressure_plate"} })
-- 149 unpowered / 150 powered comparator: meta&3 facing (H_DIODE), 0x4 =
-- subtract mode, 0x8 = powered (wiki block-data table)
local function comparator(id, base_powered)
	local e = { default={name="minecraft:comparator", props={powered=base_powered, mode="compare"}} }
	for m = 0, 15 do
		e[m] = {name="minecraft:comparator", props={
			powered=(base_powered == "true" or m >= 8) and "true" or "false",
			mode=(m % 8 >= 4) and "subtract" or "compare",
			facing=face(H_DIODE, m % 4)}}
	end
	P[id] = e
end
comparator(149, "false")
comparator(150, "true")
blk(151, { default={name="minecraft:daylight_detector"} }) -- power metas 0-15
blk(152, { default={name="minecraft:redstone_block"} })  -- 13 seen, meta 0
blk(153, { default={name="minecraft:nether_quartz_ore"} }) -- 16k seen, meta 0 (ore signature: never facing metas)
-- 2026-09-26 fix: 153 was labelled hopper, which made 16k quartz-ore
-- blocks import as hoppers (owner: "thousands of hoppers"). Real 1.12 ids:
-- 152 redstone_block, 153 nether_quartz_ore, 154 hopper. Hopper meta 0 =
-- facing down, 1 = up, 2-5 = the H_CHEST horizontal facings.
blk(154, { default={name="minecraft:hopper", props={facing="down"}},
	[1]={name="minecraft:hopper", props={facing="up"}} })
for m, f in pairs(H_CHEST) do P[154][m] = {name="minecraft:hopper", props={facing=f}} end
blk(155, { default={name="minecraft:quartz_block"}, [1]={name="minecraft:chiseled_quartz_block"},
	[2]={name="minecraft:quartz_pillar"} }) -- 0,2 seen
stairs(156, "minecraft:quartz_stairs")     -- metas 0,2,3 seen
-- 2026-09-26 audit: 157 is activator rail (was mislabelled dropper);
-- 158 is the dropper.
blk(157, { default={name="minecraft:activator_rail"} }) -- shape+powered metas
hface(158, { default={name="minecraft:dropper", props={facing="down"}} })
blk(159, { default={name="minecraft:white_terracotta"} })
for m, c in ipairs(COLORS) do P[159][m - 1] = {name="minecraft:" .. c .. "_terracotta"} end
blk(160, { default={name="minecraft:white_stained_glass_pane"} })
for m, c in ipairs(COLORS) do P[160][m - 1] = {name="minecraft:" .. c .. "_stained_glass_pane"} end
-- 161 acacia/dark oak leaves: meta&1 species + decay flags
blk(161, { default={name="minecraft:acacia_leaves"} })
for m = 0, 15 do
	P[161][m] = {name=(m % 2 == 1) and "minecraft:dark_oak_leaves" or "minecraft:acacia_leaves"}
end
-- 162 acacia/dark oak logs: meta&3 species + axis bits (seen 1, 9 = dark oak)
blk(162, { default={name="minecraft:acacia_log"} })
for m = 0, 15 do
	P[162][m] = {name=((m % 4) == 1) and "minecraft:dark_oak_log" or "minecraft:acacia_log"}
end
stairs(163, "minecraft:acacia_stairs")
stairs(164, "minecraft:dark_oak_stairs")
blk(165, { default={name="minecraft:slime_block"} })
blk(166, { default={name="minecraft:barrier"} })
blk(167, { default={name="minecraft:iron_trapdoor"} })
blk(168, { default={name="minecraft:prismarine"},
	[1]={name="minecraft:prismarine_bricks"}, [2]={name="minecraft:dark_prismarine"} })
blk(169, { default={name="minecraft:sea_lantern"} })
blk(170, { default={name="minecraft:hay_block"} })
blk(171, { default={name="minecraft:white_carpet"} })
for m, c in ipairs(COLORS) do P[171][m - 1] = {name="minecraft:" .. c .. "_carpet"} end
-- 2026-09-26 audit: 172 is plain terracotta (was mislabelled coal_block),
-- 173 is the coal block (was mislabelled packed_ice -- real coal blocks
-- imported as PACKED ICE before this), 174 is packed ice.
blk(172, { default={name="minecraft:terracotta"} })
blk(173, { default={name="minecraft:coal_block"} })
blk(174, { default={name="minecraft:packed_ice"} })
blk(175, { default={name="minecraft:sunflower"} }) -- double plants 0-5
for m, d in ipairs(DOUBLE_PLANT) do P[175][m - 1] = {name="minecraft:" .. d} end
-- 176/177 banners: colour 0-15 (patterns live in the TE and are lost --
-- the palette maps all banners to Mineclonia's banner node anyway)
blk(176, { default={name="minecraft:white_banner"} })
for m, c in ipairs(COLORS) do P[176][m - 1] = {name="minecraft:" .. c .. "_banner"} end
blk(177, { default={name="minecraft:white_wall_banner"} })
for m, c in ipairs(COLORS) do P[177][m - 1] = {name="minecraft:" .. c .. "_wall_banner", props={facing="south"}} end
for m, f in pairs(H_CHEST) do P[177][m] = {name="minecraft:white_wall_banner", props={facing=f}} end
blk(178, { default={name="minecraft:daylight_detector"} })
blk(179, { default={name="minecraft:red_sandstone"}, [1]={name="minecraft:chiseled_red_sandstone"},
	[2]={name="minecraft:smooth_red_sandstone"} })
stairs(180, "minecraft:red_sandstone_stairs")
blk(181, { default={name="minecraft:red_sandstone_slab", props={type="double"}} })
slabmat(182, "minecraft:red_sandstone_slab")
-- 183-187 fence gates / 188-192 fences per species
for i, w in ipairs({"spruce","birch","jungle","dark_oak","acacia"}) do
	blk(182 + i, { default={name="minecraft:" .. w .. "_fence_gate"} })
	for m, f in pairs(H_BED) do P[182 + i][m] = {name="minecraft:" .. w .. "_fence_gate", props={facing=f}} end
	blk(187 + i, { default={name="minecraft:" .. w .. "_fence"} })
end
-- 193-197 species doors (meta: facing+open in 0-3, upper half 8-15)
for i, w in ipairs({"spruce","birch","jungle","acacia","dark_oak"}) do
	blk(192 + i, { default={name="minecraft:" .. w .. "_door"} })
end
blk(198, { default={name="minecraft:end_rod"} })
blk(199, { default={name="minecraft:chorus_plant"} })
blk(200, { default={name="minecraft:chorus_flower"} })
blk(201, { default={name="minecraft:purpur_block"} })
blk(202, { default={name="minecraft:purpur_pillar"} })
stairs(203, "minecraft:purpur_stairs")
blk(204, { default={name="minecraft:purpur_slab", props={type="double"}} })
slabmat(205, "minecraft:purpur_slab")
blk(206, { default={name="minecraft:end_stone_bricks"} })
blk(207, { default={name="minecraft:beetroots"} }) -- age metas 0-3
blk(208, { default={name="minecraft:dirt_path"} })
blk(209, { default={name="minecraft:end_gateway"} })
-- 210/211 command blocks: no Mineclonia equivalent -> left unmapped
blk(212, { default={name="minecraft:ice"} }) -- frosted ice -> static ice (museum-safe)
blk(213, { default={name="minecraft:magma_block"} }) -- seen
blk(214, { default={name="minecraft:nether_wart_block"} })
blk(215, { default={name="minecraft:red_nether_bricks"} })
blk(216, { default={name="minecraft:bone_block"} })
blk(217, { default={name="minecraft:air"} }) -- structure void -> air (it is invisible scaffolding)
blk(218, { default={name="minecraft:observer", props={powered="false"}} })
-- 219-234 shulker boxes: one id per colour, meta = facing 0-5
for i, c in ipairs(COLORS) do
	blk(218 + i, { default={name="minecraft:" .. c .. "_shulker_box", props={facing="up"}} })
	for m, f in pairs(H_SHULK) do
		P[218 + i][m] = {name="minecraft:" .. c .. "_shulker_box", props={facing=f}}
	end
end
-- 235-250 glazed terracotta: one id per colour, meta = facing 0-3 (H_BED order)
for i, c in ipairs(COLORS) do
	blk(234 + i, { default={name="minecraft:" .. c .. "_glazed_terracotta", props={facing="south"}} })
	for m, f in pairs(H_BED) do
		P[234 + i][m] = {name="minecraft:" .. c .. "_glazed_terracotta", props={facing=f}}
	end
end
blk(251, { default={name="minecraft:white_concrete"} })
for m, c in ipairs(COLORS) do P[251][m - 1] = {name="minecraft:" .. c .. "_concrete"} end
blk(252, { default={name="minecraft:white_concrete_powder"} })
for m, c in ipairs(COLORS) do P[252][m - 1] = {name="minecraft:" .. c .. "_concrete_powder"} end

-- 1.12 biome ids -> modern names (the seam climate source; WDLs carry
-- one biome per chunk here). Canonical list from the wiki
-- "Biome/IDs before 1.13" (2026-09-26 audit: the previous table was
-- shifted from id 9 on -- 9 is The End, not the nether; the corpus only
-- ever used 8 (nether) which is why nobody noticed).
local BIOMES = {
	[0]="minecraft:ocean", [1]="minecraft:plains", [2]="minecraft:desert",
	[3]="minecraft:windswept_hills", [4]="minecraft:forest", [5]="minecraft:taiga",
	[6]="minecraft:swamp", [7]="minecraft:river", [8]="minecraft:nether_wastes",
	[9]="minecraft:the_end", [10]="minecraft:frozen_ocean", [11]="minecraft:frozen_river",
	[12]="minecraft:snowy_plains", [13]="minecraft:snowy_slopes",
	[14]="minecraft:mushroom_fields", [15]="minecraft:mushroom_fields",
	[16]="minecraft:beach", [17]="minecraft:desert", [18]="minecraft:forest",
	[19]="minecraft:taiga", [20]="minecraft:windswept_hills", [21]="minecraft:jungle",
	[22]="minecraft:jungle", [23]="minecraft:sparse_jungle", [24]="minecraft:deep_ocean",
	[25]="minecraft:stony_shore", [26]="minecraft:snowy_beach", [27]="minecraft:birch_forest",
	[28]="minecraft:birch_forest", [29]="minecraft:dark_forest", [30]="minecraft:snowy_taiga",
	[31]="minecraft:snowy_taiga", [32]="minecraft:old_growth_pine_taiga",
	[33]="minecraft:old_growth_pine_taiga", [34]="minecraft:windswept_forest",
	[35]="minecraft:savanna", [36]="minecraft:savanna_plateau", [37]="minecraft:badlands",
	[38]="minecraft:wooded_badlands", [39]="minecraft:badlands",
	[127]="minecraft:the_void",
	[129]="minecraft:sunflower_plains", [130]="minecraft:desert",
	[131]="minecraft:windswept_hills", [132]="minecraft:flower_forest",
	[133]="minecraft:taiga", [134]="minecraft:swamp", [140]="minecraft:ice_spikes",
	[149]="minecraft:jungle", [151]="minecraft:sparse_jungle",
	[155]="minecraft:old_growth_birch_forest", [156]="minecraft:old_growth_birch_forest",
	[157]="minecraft:dark_forest", [158]="minecraft:snowy_taiga",
	[160]="minecraft:old_growth_spruce_taiga", [161]="minecraft:old_growth_spruce_taiga",
	[162]="minecraft:windswept_forest", [163]="minecraft:savanna_plateau",
	[164]="minecraft:savanna_plateau", [165]="minecraft:badlands",
	[166]="minecraft:wooded_badlands", [167]="minecraft:badlands",
}

-- Lookup: exact meta wins, then the id default. Returns name, props.
function legacy.block(id, meta)
	local e = P[id]
	if e then
		local hit = e[meta] or e.default
		return hit.name, hit.props
	end
	return nil
end

function legacy.biome(id)
	return BIOMES[id]
end

return legacy
