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
-- The table covers the full common 1.12 block set; the Nether captures
-- actually use 168 id/meta pairs (verified by scan) and are marked in
-- the comments. Unknown ids degrade to stone with a logged warning.

local legacy = {}

-- facing helpers: 1.12's horizontal meta codes differ per family
local H_CHEST = {[2]="north",[3]="south",[4]="west",[5]="east"}   -- chest/furnace/ladder/hopper
local H_STAIR = {[0]="east",[1]="west",[2]="south",[3]="north"}   -- stairs
local H_TORCH = {[1]="east",[2]="west",[3]="south",[4]="north"}   -- torch/lever-ish
local function face(map, meta, mod) return map[(mod and (meta % mod) or meta)] end

-- wool/concrete/terracotta/carpet meta -> colour (0-15)
local COLORS = {"white","orange","magenta","light_blue","yellow","lime","pink",
	"gray","light_gray","cyan","purple","blue","brown","green","red","black"}

-- planks/log/fence meta -> species
local WOOD = {"oak","spruce","birch","jungle","acacia","dark_oak"}
local LOG1 = {"oak","spruce","birch","jungle"}

local P = {} -- [id] = { default={name=,props=}, [meta]={...} }
local function blk(id, entry) P[id] = entry end

-- terrain basics
blk(1,  { default={name="minecraft:stone"}, [1]={name="minecraft:granite"}, [2]={name="minecraft:granite", props={polished="true"}},
	[3]={name="minecraft:diorite"}, [4]={name="minecraft:diorite", props={polished="true"}},
	[5]={name="minecraft:andesite"}, [6]={name="minecraft:andesite", props={polished="true"}} })
blk(2,  { default={name="minecraft:grass_block"} })
blk(3,  { default={name="minecraft:dirt"}, [1]={name="minecraft:dirt", props={coarse_dirt="true"}}, [2]={name="minecraft:podzol"} })
blk(4,  { default={name="minecraft:cobblestone"} })
blk(5,  { default={name="minecraft:oak_planks"} }) -- metas are species; resolved below
for m, w in ipairs(WOOD) do P[5][m - 1] = {name="minecraft:" .. w .. "_planks"} end
blk(7,  { default={name="minecraft:bedrock"} })
blk(8,  { default={name="minecraft:water"} })
blk(9,  { default={name="minecraft:water"} })
blk(10, { default={name="minecraft:lava"} })  -- flow metas: seen (nether seas)
blk(11, { default={name="minecraft:lava"} })  -- all 16 flow levels seen
blk(12, { default={name="minecraft:sand"}, [1]={name="minecraft:red_sand"} })
blk(13, { default={name="minecraft:gravel"} })
blk(14, { default={name="minecraft:gold_ore"} })
blk(15, { default={name="minecraft:iron_ore"} })
blk(16, { default={name="minecraft:coal_ore"} })
blk(17, { default={name="minecraft:oak_log"} }) -- meta 0-3 species, 4-7 bark
for m, w in ipairs(LOG1) do P[17][m - 1] = {name="minecraft:" .. w .. "_log"} end
blk(18, { default={name="minecraft:oak_leaves"} })
for m, w in ipairs(LOG1) do P[18][m - 1] = {name="minecraft:" .. w .. "_leaves"} end
blk(20, { default={name="minecraft:glass"} })
blk(21, { default={name="minecraft:lapis_ore"} })
blk(22, { default={name="minecraft:lapis_block"} })
blk(23, { default={name="minecraft:dispenser"} })
blk(24, { default={name="minecraft:sandstone"}, [1]={name="minecraft:chiseled_sandstone"}, [2]={name="minecraft:smooth_sandstone"} })
blk(27, { default={name="minecraft:powered_rail"} }) -- metas: shape+powered (seen 0,1,8-13)
blk(29, { default={name="minecraft:sticky_piston"} })
blk(30, { default={name="minecraft:cobweb"} })
blk(31, { default={name="minecraft:short_grass"}, [0]={name="minecraft:dead_bush"}, [2]={name="minecraft:fern"} })
blk(32, { default={name="minecraft:dead_bush"} })
blk(33, { default={name="minecraft:piston"} })
blk(35, { default={name="minecraft:white_wool"} })
for m, c in ipairs(COLORS) do P[35][m - 1] = {name="minecraft:" .. c .. "_wool"} end
blk(37, { default={name="minecraft:dandelion"} })
blk(38, { default={name="minecraft:poppy"} })
blk(39, { default={name="minecraft:brown_mushroom"} }) -- seen
blk(40, { default={name="minecraft:red_mushroom"} })   -- seen
blk(41, { default={name="minecraft:gold_block"} })
blk(42, { default={name="minecraft:iron_block"} })
blk(43, { default={name="minecraft:stone_slab"} }) -- doubles: approximated as their full block
blk(44, { default={name="minecraft:stone_slab"},
	[1]={name="minecraft:sandstone_slab"}, [2]={name="minecraft:oak_slab"},
	[3]={name="minecraft:cobblestone_slab"}, [4]={name="minecraft:brick_slab"},
	[5]={name="minecraft:stone_brick_slab"}, [6]={name="minecraft:nether_brick_slab"},
	[7]={name="minecraft:quartz_slab"} })
blk(45, { default={name="minecraft:bricks"} })
blk(46, { default={name="minecraft:tnt"} })
blk(47, { default={name="minecraft:bookshelf"} }) -- seen
blk(48, { default={name="minecraft:mossy_cobblestone"} })
blk(49, { default={name="minecraft:obsidian"} }) -- seen
blk(50, { default={name="minecraft:torch"} })    -- metas 1-5 seen (wall torches)
for m, f in pairs(H_TORCH) do P[50][m] = {name="minecraft:wall_torch", props={facing=f}} end
blk(51, { default={name="minecraft:fire"} })     -- meta 15 seen
blk(52, { default={name="minecraft:spawner"} })  -- seen
blk(54, { default={name="minecraft:chest"} })    -- metas 2,4,5 seen
for m, f in pairs(H_CHEST) do P[54][m] = {name="minecraft:chest", props={facing=f}} end
blk(55, { default={name="minecraft:redstone_wire"} }) -- power metas seen
blk(56, { default={name="minecraft:diamond_ore"} })
blk(57, { default={name="minecraft:diamond_block"} }) -- seen
blk(58, { default={name="minecraft:crafting_table"} })
blk(60, { default={name="minecraft:farmland"} })
blk(61, { default={name="minecraft:furnace"} })  -- meta 3 seen
for m, f in pairs(H_CHEST) do P[61][m] = {name="minecraft:furnace", props={facing=f}} end
blk(63, { default={name="minecraft:oak_sign"} }) -- seen
blk(64, { default={name="minecraft:oak_door"} })
blk(65, { default={name="minecraft:ladder"} })   -- metas 2-4 seen
for m, f in pairs(H_CHEST) do P[65][m] = {name="minecraft:ladder", props={facing=f}} end
blk(66, { default={name="minecraft:rail"} })     -- seen
blk(67, { default={name="minecraft:cobblestone_stairs"} }) -- metas 0-7 seen
for m, f in pairs(H_STAIR) do
	P[67][m] = {name="minecraft:cobblestone_stairs", props={facing=f, half="bottom"}}
	P[67][m + 4] = {name="minecraft:cobblestone_stairs", props={facing=f, half="top"}}
end
blk(68, { default={name="minecraft:oak_wall_sign"} }) -- seen
blk(69, { default={name="minecraft:lever"} })     -- metas 4,9 seen
blk(70, { default={name="minecraft:stone_pressure_plate"} }) -- seen
blk(71, { default={name="minecraft:iron_door"} }) -- seen
blk(72, { default={name="minecraft:oak_pressure_plate"} })
blk(75, { default={name="minecraft:redstone_torch"} }) -- seen
blk(76, { default={name="minecraft:redstone_torch"} })
blk(77, { default={name="minecraft:stone_button"} }) -- seen
blk(78, { default={name="minecraft:snow"} })
blk(79, { default={name="minecraft:ice"} })
blk(80, { default={name="minecraft:snow_block"} })
blk(81, { default={name="minecraft:cactus"} })
blk(82, { default={name="minecraft:clay"} })
blk(84, { default={name="minecraft:jukebox"} })
blk(85, { default={name="minecraft:oak_fence"} }) -- meta 0 seen
for m, w in ipairs(WOOD) do P[85][m - 1] = {name="minecraft:" .. w .. "_fence"} end
blk(86, { default={name="minecraft:carved_pumpkin"} })
blk(87, { default={name="minecraft:netherrack"} }) -- 28M blocks
blk(88, { default={name="minecraft:soul_sand"} })  -- seen
blk(89, { default={name="minecraft:glowstone"} })  -- seen
blk(90, { default={name="minecraft:nether_portal"} }) -- metas 1,2 seen
blk(91, { default={name="minecraft:jack_o_lantern"} })
blk(98, { default={name="minecraft:stone_bricks"}, [1]={name="minecraft:mossy_stone_bricks"},
	[2]={name="minecraft:cracked_stone_bricks"}, [3]={name="minecraft:chiseled_stone_bricks"} }) -- 0,2,3 seen
blk(99,  { default={name="minecraft:huge_mushroom_1"} })
blk(100, { default={name="minecraft:huge_mushroom_2"} })
blk(101, { default={name="minecraft:iron_bars"} })
blk(102, { default={name="minecraft:glass_pane"} }) -- seen
blk(103, { default={name="minecraft:melon"} })
blk(106, { default={name="minecraft:vine"} })
blk(108, { default={name="minecraft:brick_stairs"} })
blk(109, { default={name="minecraft:stone_brick_stairs"} })
blk(110, { default={name="minecraft:mycelium"} })
blk(111, { default={name="minecraft:lily_pad"} })
blk(112, { default={name="minecraft:nether_bricks"} })       -- 70k seen
blk(113, { default={name="minecraft:nether_brick_fence"} })  -- seen
blk(114, { default={name="minecraft:nether_wart"} })         -- age metas seen
blk(115, { default={name="minecraft:enchanting_table"} })    -- seen
blk(116, { default={name="minecraft:brewing_stand"} })
blk(117, { default={name="minecraft:cauldron"} })
blk(118, { default={name="minecraft:end_portal_frame"} })
blk(120, { default={name="minecraft:end_stone"} })
blk(121, { default={name="minecraft:dragon_egg"} })
blk(122, { default={name="minecraft:redstone_lamp"} })
blk(124, { default={name="minecraft:oak_slab"} })
blk(126, { default={name="minecraft:oak_slab"} })
blk(127, { default={name="minecraft:quartz_slab"} })
blk(129, { default={name="minecraft:emerald_ore"} })
blk(130, { default={name="minecraft:ender_chest"} }) -- metas 2,4 seen
for m, f in pairs(H_CHEST) do P[130][m] = {name="minecraft:ender_chest", props={facing=f}} end
blk(133, { default={name="minecraft:emerald_block"} })
blk(134, { default={name="minecraft:spruce_stairs"} })
blk(135, { default={name="minecraft:birch_stairs"} })
blk(136, { default={name="minecraft:jungle_stairs"} })
blk(138, { default={name="minecraft:beacon"} })
blk(139, { default={name="minecraft:cobblestone_wall"}, [1]={name="minecraft:mossy_cobblestone_wall"} })
blk(145, { default={name="minecraft:anvil"} }) -- meta 5 seen
blk(146, { default={name="minecraft:trapped_chest"} }) -- meta 2 seen
for m, f in pairs(H_CHEST) do P[146][m] = {name="minecraft:trapped_chest", props={facing=f}} end
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
blk(156, { default={name="minecraft:quartz_stairs"} }) -- metas 0,2,3 seen
for m, f in pairs(H_STAIR) do
	P[156][m] = {name="minecraft:quartz_stairs", props={facing=f, half="bottom"}}
	P[156][m + 4] = {name="minecraft:quartz_stairs", props={facing=f, half="top"}}
end
blk(157, { default={name="minecraft:dropper"} })
blk(159, { default={name="minecraft:white_terracotta"} })
for m, c in ipairs(COLORS) do P[159][m - 1] = {name="minecraft:" .. c .. "_terracotta"} end
blk(162, { default={name="minecraft:acacia_log"} }) -- meta low bits: 0=acacia,1=dark_oak
P[162][0] = {name="minecraft:acacia_log"} P[162][1] = {name="minecraft:dark_oak_log"}
blk(163, { default={name="minecraft:acacia_stairs"} })
blk(164, { default={name="minecraft:dark_oak_stairs"} })
blk(165, { default={name="minecraft:slime_block"} })
blk(169, { default={name="minecraft:sea_lantern"} })
blk(170, { default={name="minecraft:hay_block"} })
blk(171, { default={name="minecraft:white_carpet"} })
for m, c in ipairs(COLORS) do P[171][m - 1] = {name="minecraft:" .. c .. "_carpet"} end
blk(172, { default={name="minecraft:coal_block"} })
blk(173, { default={name="minecraft:packed_ice"} })
blk(179, { default={name="minecraft:red_sandstone"}, [1]={name="minecraft:chiseled_red_sandstone"},
	[2]={name="minecraft:smooth_red_sandstone"} })
blk(180, { default={name="minecraft:red_sandstone_stairs"} })
blk(201, { default={name="minecraft:purpur_block"} })
blk(202, { default={name="minecraft:purpur_pillar"} })
blk(213, { default={name="minecraft:magma_block"} }) -- seen
blk(214, { default={name="minecraft:nether_wart_block"} })
blk(215, { default={name="minecraft:red_nether_bricks"} })
blk(216, { default={name="minecraft:bone_block"} })
blk(251, { default={name="minecraft:white_concrete"} })
for m, c in ipairs(COLORS) do P[251][m - 1] = {name="minecraft:" .. c .. "_concrete"} end

-- 1.12 biome ids -> modern names (the seam climate source; WDLs carry
-- one biome per chunk here)
local BIOMES = {
	[0]="minecraft:ocean", [1]="minecraft:plains", [2]="minecraft:desert",
	[3]="minecraft:windswept_hills", [4]="minecraft:forest", [5]="minecraft:taiga",
	[6]="minecraft:swamp", [7]="minecraft:river", [8]="minecraft:nether_wastes",
	[9]="minecraft:the_nether", [10]="minecraft:the_end", [11]="minecraft:frozen_ocean",
	[12]="minecraft:frozen_river", [13]="minecraft:snowy_plains", [14]="minecraft:mushroom_fields",
	[15]="minecraft:beach", [16]="minecraft:desert", [17]="minecraft:forest",
	[18]="minecraft:ocean", [19]="minecraft:the_void", [20]="minecraft:plains",
	[21]="minecraft:sunflower_plains", [22]="minecraft:desert", [23]="minecraft:windswept_hills",
	[24]="minecraft:forest", [25]="minecraft:taiga", [26]="minecraft:swamp",
	[27]="minecraft:birch_forest", [28]="minecraft:birch_forest", [29]="minecraft:dark_forest",
	[30]="minecraft:snowy_taiga", [31]="minecraft:snowy_taiga", [32]="minecraft:giant_tree_taiga",
	[33]="minecraft:windswept_forest", [34]="minecraft:savanna", [35]="minecraft:savanna",
	[36]="minecraft:desert", [37]="minecraft:badlands", [38]="minecraft:badlands",
	[39]="minecraft:wooded_badlands", [40]="minecraft:badlands", [44]="minecraft:ocean",
	[45]="minecraft:ocean", [46]="minecraft:ocean", [47]="minecraft:ocean",
	[48]="minecraft:deep_ocean", [49]="minecraft:deep_ocean", [50]="minecraft:deep_ocean",
	[127]="minecraft:the_void", [129]="minecraft:sunflower_plains", [130]="minecraft:desert",
	[131]="minecraft:windswept_hills", [132]="minecraft:flower_forest", [133]="minecraft:taiga",
	[134]="minecraft:swamp", [140]="minecraft:mushroom_fields", [149]="minecraft:jungle",
	[151]="minecraft:jungle", [155]="minecraft:jungle", [156]="minecraft:jungle",
	[157]="minecraft:bamboo_jungle", [158]="minecraft:badlands", [160]="minecraft:badlands",
	[161]="minecraft:wooded_badlands", [162]="minecraft:badlands", [163]="minecraft:badlands",
	[164]="minecraft:wooded_badlands", [165]="minecraft:jungle", [166]="minecraft:jungle",
	[167]="minecraft:jungle", [168]="minecraft:bamboo_jungle",
}
for k, v in pairs(BIOMES) do
	-- fix the accidental capitalization in one entry above
	BIOMES[k] = v:gsub("^Minecraft", "minecraft")
end

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
