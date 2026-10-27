local A = {}
local qnml_core = require("Clairvoyance.core")

-- ===== debug flag =====
local DEBUG = false

-- ===== caches, logging, safe accessors =====
local SIDE_QUEST_CACHE = {}
local QUEST_NAME_CACHE = {}
local QLM_TYPE = nil
local QLM_IS_END_METHOD = nil

-- SPEC 5.3.2: one prefixed line to print and, when present, log.info.
local function logmsg(...)
    local s = "[Clairvoyance]"
    for i = 1, select("#", ...) do
        s = s .. " " .. tostring((select(i, ...)))
    end
    print(s)
    if log and log.info then pcall(log.info, s) end
end

local function dlog(...)
    if DEBUG then logmsg(...) end
end

-- SPEC 5.3.3: type-definition lookup that never raises.
local function td(name)
    local ok, t = pcall(sdk.find_type_definition, name)
    if ok then return t end
    return nil
end

-- SPEC 5.3.4: the type is looked up until found; its end-state method once.
local function init_types()
    if QLM_TYPE == nil then
        QLM_TYPE = td("app.QuestLogManager")
        if QLM_TYPE ~= nil then
            QLM_IS_END_METHOD =
                QLM_TYPE:get_method("isQuestLogEnd(app.QuestDefine.ID)")
        end
    end
end

-- SPEC 5.3.5: first result only, nil on any raise.
local function safe_field(obj, name)
    if obj == nil then return nil end
    local ok, v = pcall(function() return obj:get_field(name) end)
    if ok then return v end
    return nil
end

local function safe_call(obj, name, ...)
    if obj == nil then return nil end
    local ok, v = pcall(function(...) return obj:call(name, ...) end, ...)
    if ok then return v end
    return nil
end

-- SPEC 5.3.6: a plain number, or the boxed value__ payload.
local function int_value(v)
    if type(v) == "number" then return v end
    if v == nil then return nil end
    local inner = safe_field(v, "value__")
    if type(inner) == "number" then return inner end
    return nil
end

-- ===== data tables =====
-- Character ids that are never a quest giver. Both labels resolve in game.
local GENERIC_NPC_IDS = {
    [260732951] = true,  -- ch300000, generic NPC character
    [2891076981] = true, -- ch000000_00, the player character
}

-- v7 (SPEC 14.3a): curated quest regions, from the public walkthrough
-- starting locations. Mapping rules: Borderwatch
-- Outpost -> Melve; Mountain Shrine -> Checkpoint Rest Town;
-- Moonglint Tower / excavation site / Agamen -> Volcanic Island.
-- A qid absent here renders under "Elsewhere" (SPEC 14.3b).
local QUEST_REGION = {
    [20010] = "Melve", -- Medicament Predicament (Melve)
    [20020] = "Melve", -- Ordeals of a New Recruit (Borderwatch Outpost)
    [20030] = "Melve", -- The Provisioner's Plight (Borderwatch Outpost)
    [20040] = "Melve", -- Nesting Troubles (Melve)
    [20050] = "Melve", -- Brothers Brave and Timid (Melve)
    [20060] = "Bakbattahl", -- Twixt a Rock and a Hard Place (Bakbattahl > Mercantile Quarter)
    [20070] = "Vernworth", -- Till Death Do Us Part (Vernworth > Noble Quarter)
    [20080] = "Harve", -- Scaly Invaders (Harve Village)
    [20082] = "Harve", -- Trouble on the Cape (Harve Village)
    [20090] = "Vernworth", -- A Beggar's Tale (Vernworth)
    [20100] = "Melve", -- Tolled to Rest (East of Ancient Battleground, NW Vermund)
    [20110] = "Vernworth", -- The Phantom Oxcart (easiest start West Vernworth Oxcart Station)
    [20120] = "Vernworth", -- The Heel of History (Vernworth > Slums (outside The Gracious Hand building))
    [20130] = "Vernworth", -- Saint of the Slums (Vernworth Slums)
    [20140] = "Vernworth", -- The Gift of Giving (Vernworth – Slums)
    [20150] = "Vernworth", -- House of the Blue Sunbright (Vernworth)
    [20190] = "Vernworth", -- A Noble Exchange (Vernworth > Vernworth Castle > Vernworth Hall (Masquerade))
    [20200] = "Checkpoint Rest Town", -- A Game of Wits (Mountain Shrine)
    [20220] = "Vernworth", -- The Nameless Village (Vernworth)
    [20230] = "Vernworth", -- A Place to Call Home (Vernworth > at street south of Stardrop Inn)
    [20240] = "Vernworth", -- Vocation Frustration (Vernworth Vocation Guild)
    [20250] = "Checkpoint Rest Town", -- Prey for the Pack (Checkpoint Rest Town)
    [20270] = "Volcanic Island", -- The Sotted Sage (Agamen Volcanic Island > Volcanic Island Camp)
    [20280] = "Bakbattahl", -- A Poisonous Proposal (Bakbattahl)
    [20290] = "Bakbattahl", -- Short-Sighted Ambition (Bakbattahl)
    [20310] = "Vernworth", -- A Case of Sculptor's Block (Vernworth)
    [20330] = "Bakbattahl", -- Shadowed Prayers (Bakbattahl > Flamebearer Palace)
    [20340] = "Vernworth", -- Crossing in Shadow (Vernworth)
    [20350] = "Checkpoint Rest Town", -- Hunt for the Jadeite Orb (Checkpoint Rest Town)
    [20360] = "Unmoored", -- Dreams Apart (auto-start entering Unmoored World)
    [20370] = "Unmoored", -- Halls of the First Dawn (Unmoored World, Seafloor Shrine)
    [20380] = "Unmoored", -- When Wills Collide (Unmoored World)
    [20390] = "Vernworth", -- The Regentkin's Resolve (Unmoored World > Vernworth > The Stardrop Inn)
    [20420] = "Bakbattahl", -- Civil Unrest (Unmoored World > Bakbattahl)
    [20440] = "Bakbattahl", -- A Scholarly Pursuit (Bakbattahl in Unmoored World)
    [20450] = "Sacred Arbor", -- Wandering Roots (Unmoored World > Sacred Arbor)
    [20460] = "Volcanic Island", -- The Importance of Aiding Ernesto (Unmoored World > Agamen Volcanic Island > Volcanic Island Camp)
    [20470] = "Volcanic Island", -- Shepherd of the Pawns (Unmoored World > Agamen Volcanic Island > Excavation Site)
    [20480] = "Vernworth", -- Oxcart Courier (Vernworth)
    [30010] = "Vernworth", -- The Ornate Box (Vernworth)
    [30040] = "Vernworth", -- The Stolen Throne (Vernworth/Brant group)
    [30041] = "Vernworth", -- Masked Correspondence (Vernworth Castle)
    [30042] = "Vernworth", -- A Magisterial Amenity (Vernworth > Slums > The Gracious Hand’s Vault)
    [30050] = "Vernworth", -- Every Rose Has Its Thorn (Vernworth > Noble Quarter > Rose Chateau Bordelrie)
    [30060] = "Vernworth", -- Gift of the Bow (Vernworth)
    [30070] = "Vernworth", -- A Trial of Archery (Vernworth)
    [30080] = "Sacred Arbor", -- The Ailing Arborheart (Sacred Arbor)
    [30090] = "Bakbattahl", -- Out of the Forest, Into the Forge (Bakbattahl)
    [30100] = "Melve", -- Readvent of Calamity (Melve)
    [30110] = "Melve", -- Home Is Where the Hearth Is (Melve)
    [30120] = "Vernworth", -- Dulled Steel, Cold Forge (Vernworth Castle)
    [30130] = "Bakbattahl", -- Steeled Resolve, Blazing Forge (Bakbattahl)
    [30140] = "Bakbattahl", -- Welcome to Battahl (Bakbattahl)
    [30160] = "Checkpoint Rest Town", -- The Sorcerer's Appraisal (Checkpoint Rest Town)
    [30170] = "Volcanic Island", -- Put a Spring in Thy Step (Agamen Volcanic Island – south path)
    [30180] = "Vernworth", -- A Veil of Gossamer Clouds (Vernworth Castle)
    [30200] = "Volcanic Island", -- A Candle in the Storm (Agamen Volcanic Island – Volcanic Island Camp)
    [30210] = "Checkpoint Rest Town", -- Mercy among Thieves (Checkpoint Rest Town – Battahl side of border gate)
    [30220] = "Bakbattahl", -- Off the Pilfered Path (Bakbattahl – Gaol Entrance)
    [30230] = "Vernworth", -- Tensions on the Highroad (Vernworth)
    [30240] = "Volcanic Island", -- Clash and Conclusion (Moonglint Tower)
}

-- v8 (SPEC 15.3g): item names keyed by icon number (ItemCommonParam
-- _IconNo; item 300 Beggar's Garb -> icon 2017). Public reference data:
-- 334 icons, one game item name each, no duplicates. Generated once,
-- strings emitted with %q.
-- An icon absent here reads as "Item <id>" (SPEC 15.7f).
local ITEM_NAMES_BY_ICON = {
    [10] = "Apple",
    [11] = "Ripened Apple",
    [12] = "Rotten Apple",
    [13] = "Grapes",
    [14] = "Ripened Grapes",
    [15] = "Rotten Grapes",
    [16] = "Quince",
    [17] = "Ripened Quince",
    [18] = "Rotten Quince",
    [19] = "Fig",
    [20] = "Ripened Fig",
    [21] = "Rotten Fig",
    [22] = "Raspberry",
    [23] = "Ripened Raspberry",
    [24] = "Rotten Raspberry",
    [25] = "Cranberry",
    [26] = "Ripened Cranberry",
    [27] = "Rotten Cranberry",
    [28] = "Blueberry",
    [29] = "Ripened Blueberry",
    [30] = "Rotten Blueberry",
    [31] = "Strawberry",
    [32] = "Ripened Strawberry",
    [33] = "Rotten Strawberry",
    [34] = "Scrag of Beast",
    [35] = "Aged Scrag of Beast",
    [36] = "Rotten Scrag of Beast",
    [37] = "Beast-Steak",
    [38] = "Aged Beast-Steak",
    [39] = "Rotten Beast-Steak",
    [40] = "Shorefish",
    [41] = "Aged Shorefish",
    [42] = "Rotten Shorefish",
    [43] = "Tideswimmer",
    [44] = "Aged Tideswimmer",
    [45] = "Rotten Tideswimmer",
    [46] = "Dried Fruit",
    [47] = "Fruit Roborant",
    [48] = "Fine Fruit Roborant",
    [49] = "Dried Meat",
    [50] = "Mincemeat Roborant",
    [51] = "Fine Mincemeat Roborant",
    [52] = "Dried Fish",
    [53] = "Roe Roborant",
    [54] = "Fine Roe Roborant",
    [55] = "Harspud",
    [56] = "Ripened Harspud",
    [57] = "Rotten Harspud",
    [58] = "Princess Harspud",
    [59] = "Ripened Princess Harspud",
    [60] = "Rotten Princess Harspud",
    [61] = "Dried Spud",
    [62] = "Harspud Roborant",
    [63] = "Fine Harspud Roborant",
    [64] = "Detoxifying Decoction",
    [65] = "Waking Powder",
    [66] = "Quenching Syrup",
    [67] = "Warming Salve",
    [68] = "Sobering Tonic",
    [69] = "Malleating Elixir",
    [70] = "Soothing Brew",
    [71] = "Panacea",
    [72] = "Parching Concoction",
    [73] = "Wicking Remedy",
    [74] = "Allheal Elixir",
    [76] = "Savagery Extract",
    [77] = "Stoutness Extract",
    [78] = "Eternal Wakestone",
    [79] = "Wakestone",
    [80] = "Wakestone Shard",
    [81] = "Dragon's Gaze",
    [82] = "Ferrystone",
    [83] = "Portcrystal",
    [84] = "Bunch of Flowers",
    [85] = "Lantern Oil",
    [86] = "Lantern (Fueled)",
    [87] = "Lantern (Half-Full)",
    [88] = "Lantern (Near-Empty)",
    [89] = "Lantern (No Fuel)",
    [90] = "Sealing Phial",
    [91] = "Sealing Phial (Contains Person)",
    [92] = "Harpysnare Smoke Beacon",
    [93] = "1 G",
    [94] = "Hunk of Rift Crystal",
    [95] = "Giant Hunk of Rift Crystal",
    [96] = "Preserved Medusa Head",
    [97] = "Medusa Head",
    [98] = "Withered Medusa Head",
    [99] = "Decayed Medusa Head",
    [1000] = "Modest Camping Kit",
    [1001] = "Mundane Camping Kit",
    [1002] = "Grass-Patterned Camping Kit",
    [1003] = "Sand-Patterned Camping Kit",
    [1004] = "Elite Camping Kit",
    [1005] = "Withered Branches",
    [1006] = "Art of Metamorphosis",
    [1007] = "Key of Sagacity",
    [1008] = "Finder's Token",
    [1009] = "Exquisite Dried Meat",
    [1010] = "Exquisite Dried Fish",
    [1011] = "Exquisite Dried Spud",
    [1012] = "Woodland Wordsmith's Tome",
    [1013] = "Chirurgeon's Tome",
    [1014] = "Logistician's Tome",
    [1015] = "Hawker's Tome",
    [1016] = "Forager's Tome",
    [1017] = "Aphonite's Tome",
    [1018] = "Red Dye",
    [1019] = "Green Dye",
    [1020] = "Blue Dye",
    [1021] = "Yellow Dye",
    [1022] = "Purple Dye",
    [1023] = "Blighting Arrow",
    [1024] = "Drenching Arrow",
    [1025] = "Tarring Arrow",
    [1026] = "Explosive Arrow",
    [1027] = "Unmaking Arrow",
    [1028] = "Emergent Vitality",
    [1029] = "Governing Soul",
    [1030] = "Prescribed Tranquility",
    [1031] = "Threshing Blaze",
    [1032] = "Winter's Path",
    [1033] = "Fulgurous Lord",
    [1034] = "Igneous Melody",
    [1035] = "Hiemal Euphony",
    [1036] = "Thunderous Concord",
    [1037] = "Greenwarish",
    [1038] = "Moonglow",
    [1039] = "Pitywort",
    [1040] = "Morningtide",
    [1041] = "Grandpetal",
    [1042] = "Goldthistle",
    [1043] = "Syrupwort Leaf",
    [1044] = "Copper Ore",
    [1045] = "Silver Ore",
    [1047] = "Fuligin Ore",
    [1048] = "Southron Iron",
    [1049] = "Copperstone",
    [1050] = "Whitecobble",
    [1051] = "Sunstone",
    [1052] = "Jagged Bone",
    [1053] = "Beast-Skin",
    [1054] = "Monster Fang",
    [1055] = "Monster Hide",
    [1056] = "Glymercole",
    [1057] = "Goblin Horn",
    [1058] = "Slate-Colored Horn",
    [1059] = "Choppe",
    [1060] = "Knacker Horn",
    [1061] = "Small Fang",
    [1062] = "Redwolf Fang",
    [1063] = "Pointed Fang",
    [1064] = "Sinister Fang",
    [1065] = "Saurian Scale",
    [1066] = "Asp Toxiscale",
    [1067] = "Rattler Rockscale",
    [1068] = "Darkscale",
    [1069] = "Boltscale",
    [1070] = "Harpy Pinion",
    [1071] = "Poison Pinion",
    [1072] = "Twisted Pinion",
    [1073] = "Spurious Wing",
    [1074] = "Minotaur Horn",
    [1075] = "Blackened Horn",
    [1076] = "Putrid Gold Tooth",
    [1077] = "Silver Crown",
    [1078] = "Miasmite",
    [1079] = "Astracite",
    [1080] = "Eldricite",
    [1081] = "Black Crystal",
    [1082] = "Wailing Crystal",
    [1083] = "Scrap Iron",
    [1084] = "Fell-Lord's Bone",
    [1085] = "Greenish Slime",
    [1086] = "Oily Slime",
    [1087] = "Foaming Slime",
    [1088] = "Rugged Bone",
    [1089] = "Misshapen Eye",
    [1090] = "Ogre Spur",
    [1091] = "Ogre Talon",
    [1092] = "Dappled Ore",
    [1093] = "Magick Medal",
    [1094] = "Electrum",
    [1095] = "Great Griffin Claw",
    [1096] = "Griffin Pinion",
    [1097] = "Freakish Mane",
    [1098] = "Black Freakish Mane",
    [1099] = "Cursed Dullahan Bone",
    [2000] = "Granite Medusa Bone",
    [2001] = "Dragon Scale",
    [2002] = "Rabbit Pelt",
    [2003] = "Leapworm Skin",
    [2004] = "Spider Venom Sac",
    [2005] = "Soldier's Code",
    [2006] = "Enchanter's Almanac",
    [2007] = "Paladin's Enigmata",
    [2008] = "Pilferer's Handbook",
    [2009] = "Legend's Opus",
    [2010] = "Hunter's Secret",
    [2011] = "Champion's Fable",
    [2012] = "Myrddin's Chronicle",
    [2013] = "Conjurer's Jottings",
    [2014] = "Spellbow's Paradox",
    [2015] = "Theurgist's Rite",
    [2016] = "Grandmaster's Path",
    [2017] = "Beggar's Garb",
    [2018] = "Disa's Letter",
    [2019] = "Rotten Soft-Boiled Egg",
    [2020] = "Small Jewel",
    [2021] = "Platinum Myrmecoleon Card",
    [2022] = "Seeker's Token",
    [2023] = "Myrmecoleon Card",
    [2024] = "Message from Brant",
    [2025] = "Battahli-Crested Letter",
    [2026] = "Letter to Lord Patrick",
    [2027] = "Missive to the Captain",
    [2028] = "Castle Floor Plan",
    [2029] = "Letter to Menella",
    [2030] = "On the Transference of Souls 2",
    [2031] = "Unfinished Letter",
    [2032] = "Makeshift Gaol Key",
    [2033] = "Diminished Godsway",
    [2034] = "Ornate Box",
    [2035] = "Battahl Residence Permit",
    [2036] = "Arborheart Cutting",
    [2037] = "Letter to Lord Phaesus",
    [2038] = "Exquisite Spectacles",
    [2039] = "Bribery Investigation Findings",
    [2040] = "Murder Report",
    [2041] = "Merchant's Document",
    [2042] = "Labor Requisition Orders",
    [2043] = "Sven's Ornate Box",
    [2044] = "Glimmercoal",
    [2045] = "Scalecinder",
    [2046] = "Letter of Request",
    [2047] = "Border Entry Permit",
    [2048] = "Beastren Border Entry Permit",
    [2049] = "Jasper",
    [2050] = "Onyx",
    [2051] = "Tiger Eye",
    [2052] = "Hallowed Orb",
    [2053] = "Paragon Staff",
    [2054] = "Fruit Wine",
    [2055] = "Dulled Regalia Sword",
    [2056] = "Restored Regalia Sword",
    [2057] = "Letter to Ser Lennart",
    [2058] = "Large Blue Crystal Shard",
    [2059] = "Small Blue Crystal Shard",
    [2060] = "Dulled Godsbane Blade",
    [2061] = "Wyrmslife Crystal",
    [2062] = "On the Transference of Souls 1",
    [2063] = "Newt Liqueur",
    [2064] = "On the Transference of Souls",
    [2065] = "Jadeite Orb",
    [2066] = "Imitation Jadeite Orb",
    [2067] = "Escort Orders",
    [2068] = "Moonglint Key",
    [2069] = "Makeshift Vault Key",
    [2070] = "Overseers' Lodge Key",
    [2071] = "Scrap of Cloth",
    [2072] = "Paragon Staff Replica",
    [2073] = "Gaol Key",
    [2074] = "Saurian Tail",
    [2075] = "Torn Letter",
    [2076] = "Let There Be Light",
    [2077] = "Fulminous Shield",
    [2078] = "Nation's Death Knell",
    [2079] = "Howling Blizzard",
    [2080] = "Towering Earth",
    [2081] = "Records of Treatment",
    [2082] = "Unlabeled Medicine",
    [2083] = "Let There Be Lite",
    [2084] = "Fruminous Shield",
    [2085] = "Nation's Death Knock",
    [2086] = "Hurling Blizzard",
    [2087] = "Lowering Earth",
    [2088] = "Folded Letter",
    [2089] = "Darragh's Bill of Arrest",
    [2090] = "Provisioner's Note",
    [2091] = "Mock Mended Regalia Sword",
    [2092] = "Empowered Godsbane Blade",
    [2093] = "Golden Trove Beetle",
    [2094] = "Ancient Battleground Key",
    [2095] = "Kindhearted Rift Incense",
    [2096] = "Calm Rift Incense",
    [2097] = "Simple Rift Incense",
    [2098] = "Straightforward Rift Incense",
    [2099] = "Ambivalent Rift Incense",
    [3000] = "Wokestone",
    [3001] = "Wokestone Shard",
    [3002] = "Ferristone",
    [3003] = "Partcrystal",
    [3004] = "Ceiling Phial",
    [3005] = "Unmasking Arrow",
    [3006] = "Soldier's Cord",
    [3007] = "Enchanter's Alarm",
    [3008] = "Paladin's Energizer",
    [3009] = "Pesterer's Handbook",
    [3010] = "Legend's Hocus",
    [3011] = "Hunter's Sonnet",
    [3012] = "Champion's Foible",
    [3013] = "Myrddin's Cubicle",
    [3014] = "Conjurer's Jabberings",
    [3015] = "Spellbow's Parabola",
    [3016] = "Theurgist's Rote",
    [3017] = "Grandmother's Path",
    [3018] = "Eternal Wokestone",
    [3019] = "Seeder's Token",
    [3020] = "On the Transit of Souls 1",
    [3021] = "On the Transit of Souls 2",
    [3022] = "On the Transit of Souls",
    [3023] = "Wormslife Crystal",
    [3024] = "Golden Stove Beetle",
    [3025] = "Key of Mendacity",
    [3026] = "Dragon's Gauze",
    [3027] = "Wooden Wordsmith's Tome",
    [3028] = "Surgeon's Tome",
    [3029] = "Logician's Tome",
    [3030] = "Gawker's Tome",
    [3031] = "Forayer's Tome",
    [3032] = "Aphony's Tome",
    [3033] = "Salubrious Draught",
    [3034] = "Nomad's Dried Fruit",
    [3035] = "Mighty Roborant",
    [3036] = "Exquisite Roborant",
    [3037] = "Miracle Roborant",
    [3038] = "Sunbloom",
    [3039] = "Noonbloom",
    [3040] = "Dried Flower",
    [3041] = "Hill Beech Bark",
    [3042] = "Cinnamon Bark",
    [3043] = "Makeshift Treasure Chest Key",
    [3044] = "Bandit Bill of Arrest",
    [8038] = "Explorer's Camping Kit",
}

-- Quest id -> the CharacterID of the NPC who gives the quest. Each comment is
-- the game's quest name, with the giver's name after a colon where known.
-- Quests left out on purpose have no usable giver: 20110 The Phantom Oxcart
-- and 30110 Home Is Where the Hearth Is start on their own, and the giver of
-- 20220 The Nameless Village (Brant) is not in its cast.
local GIVER_HINTS = {
    [20010] = 3287815186, -- Medicament Predicament
    [20020] = 41790483, -- Ordeals of a New Recruit
    [20030] = 527644994, -- The Provisioner's Plight
    [20040] = 240278635, -- Nesting Troubles: Lennart
    [20050] = 2984506176, -- Brothers Brave and Timid
    [20060] = 4097835434, -- 'Twixt a Rock and a Hard Place: Akakios
    [20070] = 2696396312, -- Till Death Do Us Part
    [20080] = 1770383584, -- Scaly Invaders: Fyoran
    [20082] = 1261971841, -- Trouble on the Cape: Ulrika
    [20090] = 4031770774, -- A Beggar's Tale (identified in game: 0.6 u from the quest point; 5-NPC ambiguous cast)
    [20100] = 2954976292, -- Tolled to Rest
    [20120] = 920227254, -- The Heel of History
    [20130] = 3656022968, -- Saint of the Slums: Elena
    [20140] = 1488552131, -- The Gift of Giving
    [20150] = 3743885470, -- House of the Blue Sunbright
    [20190] = 3689427708, -- A Noble Exchange
    [20200] = 3369196004, -- A Game of Wits: the Sphinx (ch253001_00, monster-series id)
    [20230] = 3202987914, -- A Place to Call Home
    [20240] = 3335726897, -- Vocation Frustration: Klaus
    [20250] = 1191862039, -- Prey for the Pack
    [20270] = 3252066890, -- The Sotted Sage
    [20280] = 2151757684, -- A Poisonous Proposal
    [20290] = 1545619405, -- Short-Sighted Ambition
    [20310] = 2884679268, -- A Case of Sculptor's Block
    [20330] = 4137867127, -- Shadowed Prayers
    [20340] = 407577432, -- Crossing in Shadow: Vera
    [20350] = 3680129867, -- Hunt for the Jadeite Orb: Offulve
    [20390] = 189868107, -- The Regentkin's Resolve: Brant
    [20420] = 4137867127, -- Civil Unrest: Menella
    [20440] = 2365554741, -- A Scholarly Pursuit: Phaesus
    [20450] = 3560980369, -- Wandering Roots: Glyndwr
    [20460] = 3059207198, -- The Importance of Aiding Ernesto: Ernesto
    [20470] = 3530434734, -- Shepherd of the Pawns: Henrique
    [20480] = 542068695, -- Oxcart Courier
    [30010] = 4207487022, -- The Ornate Box: Auriol
    [30030] = 4006438697, -- Beren's Final Lesson
    [30040] = 189868107, -- The Stolen Throne: Brant
    [30041] = 1210835050, -- Masked Correspondence
    [30042] = 4267448965, -- A Magisterial Amenity
    [30050] = 1461307325, -- Every Rose Has Its Thorn
    [30060] = 3560980369, -- Gift of the Bow
    [30070] = 3560980369, -- A Trial of Archery: Glyndwr
    [30080] = 1007143618, -- The Ailing Arborheart
    [30090] = 1363233817, -- Out of the Forest, Into the Forge: Sara
    [30100] = 240278635, -- Readvent of Calamity
    [30120] = 1424070675, -- Dulled Steel, Cold Forge
    [30140] = 2145444378, -- Welcome to Battahl
    [30150] = 678396953, -- Spellbound
    [30160] = 1603137626, -- The Sorcerer's Appraisal
    [30170] = 1468499554, -- Put a Spring in Thy Step
    [30180] = 1210835050, -- A Veil of Gossamer Clouds
    [30200] = 4137867127, -- A Candle in the Storm: Menella
    [30210] = 2097686220, -- Mercy among Thieves: Lyssandro
    [30220] = 665009116, -- Off the Pilfered Path: Hugo
    [30230] = 43671194, -- Tensions on the Highroad
    [30240] = 1874680072, -- Clash and Conclusion: Raghnall
}

-- ===== collection helpers =====
-- SPEC 5.2.1: ok, value. Method call first, then a plain function lookup.
local function managed_try_call(obj, method, ...)
    if obj == nil then return false, nil end
    local ok1, v1 = pcall(function(...) return obj:call(method, ...) end, ...)
    if ok1 and v1 ~= nil then return true, v1 end
    local ok2, v2 = pcall(function(...)
        local fn = obj[method]
        if type(fn) ~= "function" then error("not a function", 0) end
        return fn(obj, ...)
    end, ...)
    if ok2 then return true, v2 end
    if ok1 then return true, nil end
    return false, nil
end

-- Small shared helpers (kept on A: the chunk is at the local-variable cap).
A.ENUM_GET = { "GetEnumerator", "getEnumerator", "get_Enumerator" }
A.ENUM_MOVE = { "MoveNext", "moveNext", "move_next" }
A.ENUM_CUR_CALL = { "get_Current", "getCurrent" }
A.ENUM_CUR_FIELD = { "Current", "current", "_current" }
A.ENUM_CAP = 100000
A.CHAR_LOOKUPS = { "findByCharacterID", "findCharacterByCharacterID",
    "findCharacter", "getCharacter" }
A.NM_DEAD_CALLS = { "isDead", "get_IsDead" }
A.CHAR_DEAD_CALLS = { "get_IsDead", "isDead" }
A.POSITION_METHODS = { "get_UniversalPosition", "get_Position",
    "get_WorldPosition" }
A.HOLDER_CID_FIELDS = { "CharaID", "_CharaID", "CharacterID", "_CharacterID" }
A.HOLDER_CID_METHODS = { "get_CharaID", "get_CharacterID" }
A.SIDE_YES_CALLS = { "isSideQuest", "isSubQuest", "isSubQuestID",
    "isSubQuestId" }
A.SIDE_NO_CALLS = { "isMainQuest", "isMainQuestID", "isMainQuestId",
    "isStoryQuest" }
A.SIDE_ENTRY_FIELDS = { "QuestType", "QuestCategory", "QuestKind",
    "Category", "Type" }

-- Hooks type_name:method_name when both exist; a missing type or method is
-- skipped with a log line.
function A.hook_method(type_name, method_name, pre, post)
    local t = sdk.find_type_definition(type_name)
    if t == nil then
        logmsg("hook skipped: " .. type_name .. "." .. method_name)
        return
    end
    local m = t:get_method(method_name)
    if m == nil then
        logmsg("hook skipped: " .. type_name .. "." .. method_name)
        return
    end
    sdk.hook(m, pre, post)
end
A.CONTEXT_POS_FIELDS = { "Pos", "Position", "WorldPosition", "StartPos",
    "StartPosition", "QuestStartPos", "QuestStartPosition", "TargetPos",
    "TargetPosition", "_Pos", "_Position", "_StartPos", "_StartPosition",
    "_TargetPos", "_TargetPosition", "Location", "_Location", "WorldPos",
    "_WorldPos" }
A.CONTEXT_POS_METHODS = { "get_Pos", "get_Position", "get_WorldPosition",
    "get_StartPos" }

-- A non-negative integral number as an integer, else nil.
function A.count_of(v)
    if type(v) ~= "number" then return nil end
    local n = math.tointeger(v)
    if n == nil or n < 0 then return nil end
    return n
end

-- Dictionary-entry unwrap: the first truthy of value / Value / get_Value /
-- get_value, else the entry itself.
function A.unwrap_value(entry)
    local v = safe_field(entry, "value") or safe_field(entry, "Value")
        or safe_call(entry, "get_Value") or safe_call(entry, "get_value")
    if v then return v end
    return entry
end

-- Reads `size` elements of `arr` through get_element; nil when any fails.
function A.read_elements(arr, size)
    local items = {}
    for i = 0, size - 1 do
        local ok, e = managed_try_call(arr, "get_element", i)
        if not ok or e == nil then return nil end
        items[i + 1] = e
    end
    return items
end

-- SPEC 5.2.2: indexed list reads only; the enumerator step is dropped
-- (SPEC 5.1), so skip_enumerator is accepted and always in effect.
local function read_collection_items(collection, depth, skip_enumerator)
    if collection == nil or (depth or 0) > 2 then return false, nil, 0 end

    -- get_size / get_element
    local oks, rawsize = managed_try_call(collection, "get_size")
    local size = oks and A.count_of(rawsize) or nil
    if size ~= nil then
        local items = A.read_elements(collection, size)
        if items ~= nil then
            return true, items, size
        end
    end

    -- get_Count / get_Item
    local okc, rawcount = managed_try_call(collection, "get_Count")
    if not (okc and type(rawcount) == "number") then
        okc, rawcount = managed_try_call(collection, "getCount")
    end
    local numeric_count = nil
    if okc and type(rawcount) == "number" then numeric_count = rawcount end
    local count = A.count_of(numeric_count)
    if count ~= nil then
        if count == 0 then
            return true, {}, 0
        end
        local items, good = {}, true
        for i = 0, count - 1 do
            local ok, e = managed_try_call(collection, "get_Item", i)
            if not ok or e == nil then
                ok, e = managed_try_call(collection, "getItem", i)
            end
            if not ok or e == nil then good = false break end
            items[i + 1] = e
        end
        if good then
            return true, items, count
        end
    end

    -- _items backing array, sized by the logical count
    local backing = safe_field(collection, "_items")
    if backing ~= nil and backing ~= collection then
        local logical = numeric_count
        if logical == nil then
            logical = int_value(safe_field(collection, "_size"))
        end
        local n = A.count_of(logical)
        if n ~= nil then
            local items = A.read_elements(backing, n)
            if items ~= nil then
                return true, items, n
            end
        end
    end
    return false, nil, 0
end

-- SPEC 5.2.5: callback-per-entry walk over an enumerator; ok, count, available.
local function stream_enumerator(collection, unwrap_pairs, cb)
    if collection == nil then return false, 0, false end
    local en = nil
    for _, name in ipairs(A.ENUM_GET) do
        local ok, v = managed_try_call(collection, name)
        if ok and v ~= nil then en = v break end
    end
    if en == nil then return false, 0, false end
    local function dispose() pcall(function() en:call("Dispose") end) end
    local count = 0
    for _ = 1, A.ENUM_CAP do
        local advanced = nil
        for _, name in ipairs(A.ENUM_MOVE) do
            local ok, v = managed_try_call(en, name)
            if ok and type(v) == "boolean" then advanced = v break end
        end
        if advanced == nil then dispose() return false, count, true end
        if advanced == false then dispose() return true, count, true end
        local cur = nil
        for _, name in ipairs(A.ENUM_CUR_CALL) do
            local ok, v = managed_try_call(en, name)
            if ok and v ~= nil then cur = v break end
        end
        if cur == nil then
            for _, name in ipairs(A.ENUM_CUR_FIELD) do
                local v = safe_field(en, name)
                if v ~= nil then cur = v break end
            end
        end
        if cur ~= nil then
            if unwrap_pairs then cur = A.unwrap_value(cur) end
            count = count + 1
            local ok, r = pcall(cb, cur, count - 1)
            if ok and r == false then dispose() return false, count, true end
            if ok and r == "break" then dispose() return true, count, true end
        end
    end
    dispose()
    return false, count, true
end

-- SPEC 5.2.3: ok, visited. cb(item, index0); false stops as failure,
-- "break" as success; nil items are skipped.
local function visit_collection_items(items, count, unwrap_pairs, cb)
    for i = 1, count do
        local item = items[i]
        if item ~= nil then
            if unwrap_pairs then item = A.unwrap_value(item) end
            local ok, r = pcall(cb, item, i - 1)
            if not ok or r == false then return false, i - 1 end
            if r == "break" then return true, i end
        end
    end
    return true, count
end

-- SPEC 5.2.4
local function each_collection(collection, cb)
    local ok, items, count = read_collection_items(collection)
    if not ok then return false, 0 end
    return visit_collection_items(items, count, false, cb)
end

-- Records which enumeration path served the last each_dictionary_value call
-- (values-indexed / values-streamed / values-fallback / pairs-indexed /
-- pairs-streamed / pairs-fallback / none) for A.debug_probe.
local LAST_DICT_BRANCH = "none"

-- SPEC 5.2.6: the values collection first (indexed, then streamed), then
-- the dictionary's own pairs.
local function each_dictionary_value(dic, cb)
    LAST_DICT_BRANCH = "none"
    if dic == nil then return false, 0 end
    for _, mname in ipairs({ "getValues", "get_Values" }) do
        local okv, values = managed_try_call(dic, mname)
        if okv and values ~= nil then
            local rok, items, count = read_collection_items(values)
            if rok then
                LAST_DICT_BRANCH = "values-indexed"
                return visit_collection_items(items, count, false, cb)
            end
            local sok, scount, avail = stream_enumerator(values, false, cb)
            if avail then
                LAST_DICT_BRANCH = "values-streamed"
                return sok, scount
            end
        end
    end
    local rok, items, count = read_collection_items(dic)
    if rok then
        LAST_DICT_BRANCH = "pairs-indexed"
        return visit_collection_items(items, count, true, cb)
    end
    local sok, scount, avail = stream_enumerator(dic, true, cb)
    if avail then
        LAST_DICT_BRANCH = "pairs-streamed"
        return sok, scount
    end
    return false, 0
end

-- ===== vec / context / catalog scan =====
-- SPEC 5.3.7: x, y, z only for a finite, not-all-zero vector.
local function vec_xyz(v)
    if v == nil then return nil end
    local ok, x, y, z = pcall(function() return v.x, v.y, v.z end)
    if not ok then return nil end
    if type(x) ~= "number" or x ~= x or x == math.huge or x == -math.huge
        or type(y) ~= "number" or y ~= y or y == math.huge or y == -math.huge
        or type(z) ~= "number" or z ~= z or z == math.huge or z == -math.huge then
        return nil
    end
    if x == 0 and y == 0 and z == 0 then return nil end
    return x, y, z
end

local RUNTIME_CATALOG_OWNER = nil

-- SPEC 5.7.3: the first readable position among the known field and method names.
local function get_context_position(context)
    if context == nil then return nil end
    for _, name in ipairs(A.CONTEXT_POS_FIELDS) do
        local x, y, z = vec_xyz(safe_field(context, name))
        if x ~= nil then return x, y, z end
    end
    for _, name in ipairs(A.CONTEXT_POS_METHODS) do
        local x, y, z = vec_xyz(safe_call(context, name))
        if x ~= nil then return x, y, z end
    end
    return nil
end

local CATALOG_PROBE = "unscanned"
local NPC_HOLDER_PROBE = "unscanned"

-- v2: one catalog walk per session owner builds qid -> {cast, pos}.
-- The per-qid search this replaces re-walked the dictionary every miss.
-- An empty or failed walk is never committed (retry with backoff instead),
-- and a qid missing from a committed index triggers a rate-limited re-walk
-- that swaps in the new index only on success — so a catalog populated or
-- extended after our first look is still picked up.
local CATALOG_INDEX = nil   -- qid -> { cast = {int,...}|nil, pos = {x,y,z}|nil }
local CATALOG_IDS = nil     -- sorted array of qids
local CATALOG_STATS = { entries = 0, skipped = 0, cast_skipped = 0, distinct = 0 }
local CATALOG_MISSED = {}       -- qid -> CATALOG_BUILT_AT it was last found absent
local CATALOG_RETRY_AT = 0      -- backoff gate after a failed/empty walk
local CATALOG_BUILT_AT = 0      -- when the committed index was built
local CATALOG_RETRY_SECONDS = 5.0

-- SPEC 5.7.2: the index build, skip counts, commit and backoff, and the
-- probe copy.
local function run_catalog_walk(qm)
    if qm == nil then return false end
    local qcd = safe_field(qm, "QuestCatalogDict")
    if qcd == nil then return false end

    local index, ids = {}, {}
    local entries, skipped, cast_skipped = 0, 0, 0
    local scan_ok = each_dictionary_value(qcd, function(cd)
        local arr = safe_field(safe_field(cd, "ContextData"), "ContextDataArray")
        if arr == nil then return end
        -- An unreadable array (including one an indexed read aborts on)
        -- counts as skipped, not fatal; the skipped count in the readout
        -- surfaces it.
        local read_ok, items, count = read_collection_items(arr)
        if not read_ok then
            skipped = skipped + 1
            return
        end
        for i = 1, count do
            local e = items[i]
            entries = entries + 1
            local qid = int_value(safe_field(e, "_IDValue"))
            if qid ~= nil and qid > 0 and index[qid] == nil then
                local rec = {}
                local x, y, z = get_context_position(e)
                if x ~= nil then rec.pos = { x = x, y = y, z = z } end
                local cast_field = safe_field(e, "CastNPCIDs")
                if cast_field ~= nil then
                    local cl = {}
                    local ok2, citems, ccount =
                        read_collection_items(cast_field)
                    if ok2 then
                        for ci = 1, ccount do
                            local cid = int_value(citems[ci])
                            if cid ~= nil then cl[#cl + 1] = cid end
                        end
                    else
                        cast_skipped = cast_skipped + 1
                        rec.cast_failed = true
                    end
                    if #cl > 0 then rec.cast = cl end
                end
                index[qid] = rec
                ids[#ids + 1] = qid
            end
        end
    end)

    CATALOG_PROBE = LAST_DICT_BRANCH
    if not scan_ok or #ids == 0 then
        -- Keep any previous index; commit nothing from a broken/empty walk.
        CATALOG_RETRY_AT = os.clock() + CATALOG_RETRY_SECONDS
        dlog("catalog walk " .. (scan_ok and "empty" or "failed")
            .. "; retry in " .. CATALOG_RETRY_SECONDS .. "s")
        return CATALOG_INDEX ~= nil
    end

    table.sort(ids)
    CATALOG_INDEX = index
    CATALOG_IDS = ids
    CATALOG_STATS = { entries = entries, skipped = skipped,
        cast_skipped = cast_skipped, distinct = #ids }
    CATALOG_MISSED = {}
    CATALOG_BUILT_AT = os.clock()
    return true
end

-- SPEC 5.7.1: track the QuestManager owner, then build or reuse the index.
local function build_catalog_index()
    local qm = sdk.get_managed_singleton("app.QuestManager")
    if qm == nil then return false end
    local changed = qm ~= RUNTIME_CATALOG_OWNER
    if changed then
        RUNTIME_CATALOG_OWNER = qm
        CATALOG_INDEX = nil
        CATALOG_IDS = nil
        CATALOG_STATS = { entries = 0, skipped = 0, cast_skipped = 0, distinct = 0 }
        CATALOG_MISSED = {}
        CATALOG_RETRY_AT = 0
        CATALOG_BUILT_AT = 0
    end
    if CATALOG_INDEX ~= nil then return true end
    if os.clock() < CATALOG_RETRY_AT then return false end
    return run_catalog_walk(qm)
end

-- A qid absent from the committed index may have been added after the walk
-- (quest unlocked mid-session): re-walk at most once per backoff window.
local function refresh_for_missing(qid)
    if CATALOG_INDEX == nil or CATALOG_INDEX[qid] ~= nil then return end
    local gate = math.max(CATALOG_RETRY_AT,
        CATALOG_BUILT_AT + CATALOG_RETRY_SECONDS)
    if os.clock() < gate then return end
    if CATALOG_MISSED[qid] == CATALOG_BUILT_AT then return end
    local built_before = CATALOG_BUILT_AT
    run_catalog_walk(RUNTIME_CATALOG_OWNER)
    -- a successful walk replaced the index (and cleared the memo); if it
    -- still lacks the qid, remember that so we re-walk once per index.
    if CATALOG_BUILT_AT ~= built_before and CATALOG_INDEX[qid] == nil then
        CATALOG_MISSED[qid] = CATALOG_BUILT_AT
    end
end

local function catalog_ids()
    if not build_catalog_index() then return nil end
    return CATALOG_IDS
end

local function get_runtime_cast_charaids(qid)
    if not build_catalog_index() then return nil end
    refresh_for_missing(qid)
    local rec = CATALOG_INDEX[qid]
    if rec == nil then return {} end
    if rec.cast_failed then return nil end
    return rec.cast or {}
end

local function get_runtime_quest_position(qid)
    if not build_catalog_index() then return nil end
    refresh_for_missing(qid)
    local rec = CATALOG_INDEX[qid]
    if rec ~= nil and rec.pos ~= nil then
        return rec.pos.x, rec.pos.y, rec.pos.z
    end
    return nil
end

local function catalog_stats()
    local s = CATALOG_STATS
    return { entries = s.entries, skipped = s.skipped,
        cast_skipped = s.cast_skipped, distinct = s.distinct }
end

-- ===== NPC position cache =====
-- SPEC 5.8.1: position methods first, then the GameObject transform.
local function extract_position(obj)
    if obj == nil then return nil end
    for _, name in ipairs(A.POSITION_METHODS) do
        local x, y, z = vec_xyz(safe_call(obj, name))
        if x ~= nil then return x, y, z end
    end
    local go = safe_call(obj, "get_GameObject")
    local tr = safe_call(go, "get_Transform")
    return vec_xyz(safe_call(tr, "get_Position"))
end

local NPC_POS_CACHE = {}
local NPC_POS_CACHE_TIME = 0
local NPC_POS_CACHE_TTL = 60
local NPC_POS_CACHE_RETRY_AT = 0
local NPC_POS_CACHE_RETRY_INTERVAL = 5
local NPC_POS_CACHE_OWNER = nil
local NPC_POS_CACHE_LAST_ATTEMPT = 0
-- cid -> app.NPCHolder, filled by the same walk. The holder's _chara
-- reference is the live-presence signal (SPEC §10.2: nil while the NPC
-- is not spawned); holder POSITION data is never served from here.
local NPC_HOLDER_CACHE = {}

-- SPEC 5.8.2: the holder's positive character id, or nil.
local function holder_cid(holder)
    if holder == nil then return nil end
    for _, name in ipairs(A.HOLDER_CID_FIELDS) do
        local v = int_value(safe_field(holder, name))
        if v ~= nil and v > 0 then return v end
    end
    for _, name in ipairs(A.HOLDER_CID_METHODS) do
        local v = int_value(safe_call(holder, name))
        if v ~= nil and v > 0 then return v end
    end
    return nil
end

-- SPEC 5.8.4: one scan of the holder dictionary; true when it completed.
local function rebuild_npc_pos_cache()
    local now = os.time()
    NPC_POS_CACHE_LAST_ATTEMPT = now
    local nm = sdk.get_managed_singleton("app.NPCManager")
    local dic = safe_field(nm, "NPCHolderDic")
    if dic == nil then
        NPC_POS_CACHE_RETRY_AT = now + NPC_POS_CACHE_RETRY_INTERVAL
        return false
    end
    local holders = {}
    local new_cache = {}
    local walk_ok = each_dictionary_value(dic, function(entry)
        if entry == nil then return end
        local holder = A.unwrap_value(entry)
        local cid = holder_cid(holder)
        if cid == nil then return end
        holders[cid] = holder
        local x, y, z = extract_position(holder)
        if x ~= nil then new_cache[cid] = { x = x, y = y, z = z } end
    end)
    NPC_HOLDER_PROBE = LAST_DICT_BRANCH
    if not walk_ok then
        -- The enumerator can die mid-stream (the game mutates NPCHolderDic
        -- while we walk it). Entries gathered before the abort are still
        -- real positions: merge them so repeated partial scans converge on
        -- coverage instead of discarding the work each retry.
        local merged = 0
        for cid, p in pairs(new_cache) do
            NPC_POS_CACHE[cid] = p
            merged = merged + 1
        end
        for cid, h in pairs(holders) do
            NPC_HOLDER_CACHE[cid] = h
        end
        dlog(string.format(
            "NPC position scan aborted mid-stream; merged %d partial entries",
            merged))
        NPC_POS_CACHE_RETRY_AT = now + NPC_POS_CACHE_RETRY_INTERVAL
        return false
    end
    NPC_HOLDER_CACHE = holders
    NPC_POS_CACHE = new_cache
    NPC_POS_CACHE_TIME = now
    NPC_POS_CACHE_RETRY_AT = 0
    return true
end

-- SPEC 5.8.5 (and 10.2): first CharacterManager lookup whose character `read`
-- accepts. A method that returns a character without a readable result is
-- skipped. Returns read(c), the method name (for the 10.8b probe) and the
-- character, or nil when `read` finds nothing.
local function find_character(cid, read)
    local cm = sdk.get_managed_singleton("app.CharacterManager")
    if cm == nil then return nil end
    for _, name in ipairs(A.CHAR_LOOKUPS) do
        local ok, c = pcall(function() return cm:call(name, cid) end)
        if ok and c ~= nil then
            local res = read(c)
            if res ~= nil then return res, name, c end
        end
    end
    return nil
end

-- find_character reader for the extract_position tier.
local function chara_extract_pos(c)
    local x, y, z = extract_position(c)
    if x ~= nil then return { x = x, y = y, z = z } end
end

-- SPEC 5.8.6: an NPCManager change empties the position cache.
local function sync_npc_cache_owner()
    local nm = sdk.get_managed_singleton("app.NPCManager")
    local changed = nm ~= NPC_POS_CACHE_OWNER
    if changed then
        NPC_POS_CACHE_OWNER = nm
        NPC_POS_CACHE = {}
        NPC_POS_CACHE_TIME = 0
        NPC_POS_CACHE_RETRY_AT = 0
        NPC_POS_CACHE_LAST_ATTEMPT = 0
        NPC_HOLDER_CACHE = {}
    end
    return nm
end

-- SPEC 5.8.7: rescan when never scanned, stale, or a wanted cid is missing.
local function maybe_rebuild_npc_cache(cid_missed, cid)
    local now = os.time()
    local due = NPC_POS_CACHE_TIME == 0
        or now - NPC_POS_CACHE_TIME >= NPC_POS_CACHE_TTL
        or (cid_missed and NPC_POS_CACHE[cid] == nil
            and now - NPC_POS_CACHE_LAST_ATTEMPT >= NPC_POS_CACHE_RETRY_INTERVAL)
    if due and now >= NPC_POS_CACHE_RETRY_AT then
        rebuild_npc_pos_cache()
    end
end
local function maybe_refresh_npc_cache(cid_missed, cid)
    sync_npc_cache_owner()
    maybe_rebuild_npc_cache(cid_missed, cid)
end

-- SPEC 5.8.8: live character, then direct holder, then the scan cache.
local function get_character_world_pos(cid)
    if type(cid) ~= "number" then return nil, nil, nil end
    local res = find_character(cid, chara_extract_pos)
    if res ~= nil then return res.x, res.y, res.z end
    local nm = sync_npc_cache_owner()
    local dic = safe_field(nm, "NPCHolderDic")
    local holder = safe_call(dic, "get_Item", cid)
    if holder ~= nil and holder_cid(holder) == cid then
        local hx, hy, hz = extract_position(holder)
        if hx ~= nil then
            NPC_POS_CACHE[cid] = { x = hx, y = hy, z = hz }
            return hx, hy, hz
        end
    end
    maybe_rebuild_npc_cache(true, cid)
    local p = NPC_POS_CACHE[cid]
    if p ~= nil then return p.x, p.y, p.z end
    return nil, nil, nil
end

-- SPEC 12.3c: live map-space position for an objective NPC. Tier 1 is
-- the cached holder read directly (probe-verified live + map-space,
-- 2026-10-17). NO position-cache fallback: that cache is up to 60 s
-- stale and a holder-read miss would serve it as a fresh hit,
-- re-stamping the grace clock forever (review-verified). A miss serves
-- the last good value for at most OBJECTIVE_POS_GRACE seconds, then
-- nil, so a despawned NPC cannot pin a marker (SPEC 12.1).
local OBJECTIVE_POS_GRACE = 6.0
local OBJECTIVE_POS_LAST = {}   -- cid -> {x,y,z,at}
local function objective_pos(cid)
    if type(cid) ~= "number" then return nil end
    maybe_refresh_npc_cache(false, nil)
    local x, y, z
    local holder = NPC_HOLDER_CACHE[cid]
    if holder ~= nil then
        local ok, live = pcall(sdk.is_managed_object, holder)
        if ok and live then
            local ok2, hx, hy, hz = pcall(extract_position, holder)
            if ok2 and hx ~= nil then x, y, z = hx, hy, hz end
        end
    end
    -- Holder read, else bounded last-good, else nil (no cache fallback).
    local now = os.clock()
    if x ~= nil then
        OBJECTIVE_POS_LAST[cid] = { x = x, y = y, z = z, at = now }
        return x, y, z
    end
    local last = OBJECTIVE_POS_LAST[cid]
    if last ~= nil and now - last.at <= OBJECTIVE_POS_GRACE then
        return last.x, last.y, last.z
    end
    OBJECTIVE_POS_LAST[cid] = nil
    return nil
end

-- SPEC §10.2: live presence only — the spawned character's Transform, in
-- the same coordinate space as the camera. nil means "not present".
local function chara_transform_pos(c)
    local go = safe_call(c, "get_GameObject")
    local tr = safe_call(go, "get_Transform")
    local p = safe_call(tr, "get_Position")
    local x, y, z = vec_xyz(p)
    if x ~= nil then return { transform = tr, x = x, y = y, z = z } end
end

local function npc_live_pos(cid)
    if type(cid) ~= "number" then return nil end
    local res, mname = find_character(cid, chara_transform_pos)
    if res ~= nil then return res, mname end
    -- This game build has no CharacterManager id lookup (probe-verified
    -- 2026-10-17: all four method names miss). Presence comes from the
    -- holder registry's spawned-character reference instead: _chara is
    -- nil while the NPC is not spawned, and the position read is the
    -- character's own Transform. Holder position data (schedule points,
    -- universal positions) is never read here, and this function still
    -- never touches NPC_POS_CACHE or triggers a rebuild — the holder
    -- cache is filled by the tick's existing walk.
    local chara = safe_call(NPC_HOLDER_CACHE[cid], "get_chara")
    if chara == nil then return nil end
    res = chara_transform_pos(chara)
    if res ~= nil then return res, "holder_chara" end
    return nil
end

-- Debug (SPEC §10.8b): which method answers for each reader, plus the
-- holder tier's state so a miss distinguishes "NPC not spawned" from
-- "holder never cached".
local function probe_lookup(cid)
    local _, m_pos = find_character(cid, chara_extract_pos)
    local live, m_live = npc_live_pos(cid)
    local hstate
    local holder = NPC_HOLDER_CACHE[cid]
    if holder == nil then
        hstate = "holder_uncached"
    else
        local chara = safe_call(holder, "get_chara")
        hstate = (chara == nil) and "chara_nil" or "chara_set"
    end
    return m_pos, m_live, live, hstate
end

-- Debug (SPEC §10.8b stop case): stepwise dump of what the NPC holder
-- offers for a live-presence signal. Every step logs, nothing can raise
-- past its own pcall. Defined after each_dictionary_value/holder_cid so
-- those resolve as locals, not nil globals.
local function debug_probe_holder(cid, logfn)
    local nm = sdk.get_managed_singleton("app.NPCManager")
    logfn("probe2 nm=" .. tostring(nm ~= nil))
    local dic = safe_field(nm, "NPCHolderDic")
    logfn("probe2 dic=" .. tostring(dic ~= nil))
    if dic == nil then return end
    local holder = safe_call(dic, "get_Item", cid)
    logfn(string.format("probe2 cid=%d get_Item holder=%s", cid,
        tostring(holder ~= nil)))

    local function dump_holder(h, tag)
        local ok, err = pcall(function()
            local tdh = h:get_type_definition()
            logfn("probe2 " .. tag .. " type: " .. tdh:get_full_name())
            for _, f in ipairs(tdh:get_fields()) do
                local ftype = f:get_type():get_full_name()
                local line = string.format("probe2 %s field: %s : %s",
                    tag, f:get_name(), ftype)
                -- For object-ish fields, log whether the VALUE is set (a
                -- live reference that is nil when unspawned = presence
                -- signal).
                if ftype:find("app.", 1, true) == 1
                    or ftype:find("GameObject", 1, true)
                    or ftype:find("Transform", 1, true) then
                    local v = safe_field(h, f:get_name())
                    line = line .. " value_set=" .. tostring(v ~= nil)
                end
                logfn(line)
            end
            for _, m in ipairs(tdh:get_methods()) do
                local nmm = m:get_name():lower()
                if nmm:find("chara", 1, true) or nmm:find("get", 1, true) then
                    logfn(string.format("probe2 %s method: %s/%d -> %s",
                        tag, m:get_name(), m:get_num_params(),
                        tostring(m:get_return_type():get_full_name())))
                end
            end
        end)
        if not ok then logfn("probe2 dump error: " .. tostring(err)) end
    end

    if holder ~= nil then
        dump_holder(holder, "holder")
        return
    end

    -- get_Item answers nothing for a plain number key: take holders from
    -- the enumeration walk instead (the path the position cache uses).
    local dumped_first, dumped_match, seen = false, false, 0
    each_dictionary_value(dic, function(h)
        if h == nil then return end
        seen = seen + 1
        local actual = A.unwrap_value(h)
        if not dumped_first then
            dumped_first = true
            if actual ~= h then dump_holder(h, "wrapper") end
            dump_holder(actual, "walk-first")
        end
        if not dumped_match and holder_cid(actual) == cid then
            dumped_match = true
            dump_holder(actual, "walk-match")
        end
    end)
    logfn(string.format("probe2 walk: %d entries seen, match_dumped=%s",
        seen, tostring(dumped_match)))
end

-- ===== availability / alive checks =====
-- v2: specific outcomes before generic ones — isFailedQuest first, so a
-- failed quest can never read as completed (SPEC §9.2). Terminal states do
-- not revert within a session, so non-nil results are cached.
local QUEST_STATE_CHECKS = {
    { "isFailedQuest", "failed" },
    { "isCanceledQuest", "canceled" },
    { "isClearedQuest", "completed" },
    { "isEndedQuest", "completed" },
}
local QUEST_STATE_CACHE = {}

-- SPEC 5.6.1: true only when isQuestLogEnd answers exactly true.
local function quest_log_is_end(qid)
    init_types()
    local qlm = sdk.get_managed_singleton("app.QuestLogManager")
    if qlm == nil or QLM_IS_END_METHOD == nil then return false end
    local ok, v = pcall(function() return QLM_IS_END_METHOD:call(qlm, qid) end)
    return ok and v == true
end

-- SPEC 5.6.2: first QUEST_STATE_CHECKS predicate answering exactly true.
A.read_quest_state = function(q)
    local qm = sdk.get_managed_singleton("app.QuestManager")
    if qm == nil then return nil end
    for _, check in ipairs(QUEST_STATE_CHECKS) do
        local ok, v = pcall(function() return qm:call(check[1], q) end)
        if ok and v == true then return check[2] end
    end
    return nil
end
local function quest_state(qid)
    local cached = QUEST_STATE_CACHE[qid]
    if cached ~= nil then return cached end
    local st = A.read_quest_state(qid)
    -- isQuestLogEnd with no specific outcome reads as completed (§9.2).
    if st == nil and quest_log_is_end(qid) then st = "completed" end
    if st ~= nil then QUEST_STATE_CACHE[qid] = st end
    return st
end

-- SPEC 5.8.9: false only when a dead check answers exactly true.
local function is_npc_alive_and_ready(cid)
    if not cid then return true end
    local nm = sdk.get_managed_singleton("app.NPCManager")
    if nm ~= nil then
        for _, name in ipairs(A.NM_DEAD_CALLS) do
            local ok, v = pcall(function() return nm:call(name, cid) end)
            if ok and v == true then return false end
        end
    end
    local cm = sdk.get_managed_singleton("app.CharacterManager")
    if cm ~= nil then
        for _, lookup in ipairs(A.CHAR_LOOKUPS) do
            local ok, c = pcall(function() return cm:call(lookup, cid) end)
            if ok and c ~= nil then
                for _, name in ipairs(A.CHAR_DEAD_CALLS) do
                    local ok2, v = pcall(function() return c:call(name) end)
                    if ok2 and v == true then return false end
                end
                break
            end
        end
    end
    return true
end

-- Quest titles extracted from this installation of the game
-- (natives/stm/message/quest[log]/qu*.msg, English entries).
local EXTRACTED_NAMES = {
    [10030] = "Gaoled Awakening",
    [10040] = "The Hand That Guides",
    [10050] = "Tale's Beginning",
    [10060] = "In Dragon's Wake",
    [10070] = "One-Eyed Interloper",
    [10080] = "Seat of the Sovran",
    [10090] = "Monster Culling",
    [10100] = "Disa's Plot",
    [10110] = "An Unsettling Encounter",
    [10120] = "The Caged Magistrate",
    [10130] = "The Arisen's Shadow",
    [10140] = "Feast of Deception",
    [10150] = "Nation of the Lambent Flame",
    [10151] = "Flickering Shadows",
    [10160] = "Convergence",
    [10170] = "A New Godsway",
    [10180] = "The Guardian Gigantus",
    [10200] = "Legacy",
    [20010] = "Medicament Predicament",
    [20020] = "Ordeals of a New Recruit",
    [20030] = "The Provisioner's Plight",
    [20040] = "Nesting Troubles",
    [20050] = "Brothers Brave and Timid",
    [20060] = "Twixt a Rock and a Hard Place",
    [20070] = "Till Death Do Us Part",
    [20080] = "Scaly Invaders",
    [20082] = "Trouble on the Cape",
    [20090] = "A Beggar's Tale",
    [20100] = "Tolled to Rest",
    [20110] = "The Phantom Oxcart",
    [20120] = "The Heel of History",
    [20130] = "Saint of the Slums",
    [20140] = "The Gift of Giving",
    [20150] = "House of the Blue Sunbright",
    [20160] = "The Expeditious Explorer",
    [20170] = "'Ware the Corrupted Beasts",
    [20180] = "Belle of the Bar",
    [20190] = "A Noble Exchange",
    [20200] = "A Game of Wits",
    [20220] = "The Nameless Village",
    [20230] = "A Place to Call Home",
    [20240] = "Vocation Frustration",
    [20250] = "Prey for the Pack",
    [20270] = "The Sotted Sage",
    [20280] = "A Poisonous Proposal",
    [20290] = "Short-Sighted Ambition",
    [20310] = "A Case of Sculptor's Block",
    [20330] = "Shadowed Prayers",
    [20340] = "Crossing in Shadow",
    [20350] = "Hunt for the Jadeite Orb",
    [20360] = "Dreams Apart",
    [20370] = "Halls of the First Dawn",
    [20380] = "When Wills Collide",
    [20390] = "The Regentkin's Resolve",
    [20420] = "Civil Unrest",
    [20440] = "A Scholarly Pursuit",
    [20450] = "Wandering Roots",
    [20460] = "The Importance of Aiding Ernesto",
    [20470] = "Shepherd of the Pawns",
    [20480] = "Oxcart Courier",
    [30010] = "The Ornate Box",
    [30020] = "Claw Them Into Shape",
    [30030] = "Beren's Final Lesson",
    [30040] = "The Stolen Throne",
    [30041] = "Masked Correspondence",
    [30042] = "A Magisterial Amenity",
    [30050] = "Every Rose Has Its Thorn",
    [30060] = "Gift of the Bow",
    [30070] = "A Trial of Archery",
    [30080] = "The Ailing Arborheart",
    [30090] = "Out of the Forest, Into the Forge",
    [30100] = "Readvent of Calamity",
    [30110] = "Home Is Where the Hearth Is",
    [30120] = "Dulled Steel, Cold Forge",
    [30130] = "Steeled Resolve, Blazing Forge",
    [30140] = "Welcome to Battahl",
    [30150] = "Spellbound",
    [30160] = "The Sorcerer's Appraisal",
    [30170] = "Put a Spring in Thy Step",
    [30180] = "A Veil of Gossamer Clouds",
    [30200] = "A Candle in the Storm",
    [30210] = "Mercy among Thieves",
    [30220] = "Off the Pilfered Path",
    [30230] = "Tensions on the Highroad",
    [30240] = "Clash and Conclusion",
    [40010] = "Chilling Tidings",
    [40020] = "Rumbles in the North",
    [40021] = "Monster Culling in Vernworth",
    [40022] = "Disturbance at the Mountain Stronghold",
    [40023] = "The Snowstorm-Bringer",
    [40030] = "Sealed History",
    [40040] = "Seeking the Sage",
    [40041] = "Sage's Wisdom - Riddle of the Body",
    [40042] = "Sage's Wisdom - Riddle of the Soul",
    [40043] = "Sage's Wisdom - Riddle of the Will",
    [40050] = "The Castle in the Ice",
    [40060] = "Soul Searching",
    [40070] = "Where There's a Will, There's a Way",
    [40080] = "Reunion",
    [40090] = "Into Rancor",
    [50010] = "Hammer and Tongs",
    [50020] = "In for a Hare, in for a Hound",
    [50030] = "The Truant Soldier",
    [50040] = "Quilt Me Down with a Feather",
    [50050] = "No Spoils Get Left Behind",
    [50060] = "Beyond Ruin-Night",
    [50070] = "Sticks and Stones",
    [50080] = "The Stranger in the Snowfield",
    [50090] = "The Snatching-Beast",
    [50100] = "Flight in the Night",
    [50110] = "A Keepsake, for Your Sake",
    [50120] = "Village Defense",
    [50130] = "Relics of the Past",
    [50140] = "When the Culling Gets Tough",
    [50150] = "Oh, to Be in Vermund",
    [50160] = "Reaching the Far Shore",
    [50170] = "Hal's Treasure Hunt",
    [50180] = "A Howl in the Dark",
    [50190] = "A Direwolf Delicacy",
    [50200] = "A Hound and His Bone",
    [50210] = "Bout of Passage",
    [50220] = "The Obelisks of Benediction",
    [50230] = "Back to the Temple",
}

-- ===== quest name =====
-- v2 learned-name store: the game names only quests the save has seen
-- (verified in-game 2026-10-16 — the catalog carries no display text and
-- QuestLogManager has no by-qid name method). Names are learned when first
-- yielded and persisted, so a quest locked in a later session or NG+ run
-- still shows the name an earlier session saw.
local NAME_STORE_PATH = "Clairvoyance_names.json"
local PERSISTED_NAMES = {}
local NAMES_DIRTY = false
do
    local function data_file_exists(path)
        local ok, handle = pcall(io.open, path, "r")
        if not ok or handle == nil then return false end
        pcall(function() handle:close() end)
        return true
    end
    local raw = require("Clairvoyance.settings_util").load_with_legacy(
        json.load_file, NAME_STORE_PATH, "QuestNPCMapLabels_names.json",
        data_file_exists)
    if type(raw) == "table" then
        for k, v in pairs(raw) do
            local qid = tonumber(k)
            if qid ~= nil and type(v) == "string" and v ~= "" then
                PERSISTED_NAMES[qid] = v
            end
        end
    end
end

local function save_learned_names()
    if not NAMES_DIRTY then return end
    local out = {}
    for qid, name in pairs(PERSISTED_NAMES) do
        out[tostring(qid)] = name
    end
    local ok, res = pcall(json.dump_file, NAME_STORE_PATH, out)
    if ok and res ~= false then NAMES_DIRTY = false end
end

-- SPEC 5.10: the live quest name, else tostring(qid); never nil.
local function get_debug_name(qid)
    local cached = QUEST_NAME_CACHE[qid]
    if cached ~= nil then return cached end
    local name = tostring(qid)
    local qlm = sdk.get_managed_singleton("app.QuestLogManager")
    if qlm ~= nil then
        local entry = safe_call(qlm, "getQuestLog", qid)
        if entry ~= nil then
            local n = safe_field(entry, "QuestName")
            if type(n) == "string" and n ~= "" then name = n end
        end
    end
    if name ~= tostring(qid) then
        QUEST_NAME_CACHE[qid] = name
        if PERSISTED_NAMES[qid] ~= name then
            PERSISTED_NAMES[qid] = name
            NAMES_DIRTY = true
        end
    end
    return name
end

-- Budgeted learning pass: queries up to `budget` not-yet-stored quest names
-- per call, independent of which categories are shown, so names of hidden
-- (e.g. completed) quests are persisted too. Walk list = catalog ids followed
-- by acceptable/progressing ids absent from the catalog (merged per pass).
local LEARN_CURSOR = 1
local learn_list_fn = nil   -- set below once read_quest_id_list exists
local function learn_names(budget)
    local ids = catalog_ids()
    local list = {}
    local seen = {}
    if ids ~= nil then
        for _, q in ipairs(ids) do list[#list + 1] = q; seen[q] = true end
    end
    if learn_list_fn ~= nil then
        for _, q in ipairs(learn_list_fn()) do
            if not seen[q] then list[#list + 1] = q; seen[q] = true end
        end
    end
    for _ = 1, budget do
        if LEARN_CURSOR > #list then LEARN_CURSOR = 1; return end
        local q = list[LEARN_CURSOR]
        LEARN_CURSOR = LEARN_CURSOR + 1
        if PERSISTED_NAMES[q] == nil then get_debug_name(q) end
    end
end

-- ===== Boxed primitives: payload offsets =====
-- SPEC 5.12.1: payload offsets of a boxed Int32 and UInt32, read at load.
local int_value_offset, uint_value_offset
int_value_offset = sdk.find_type_definition("System.Int32")
    :get_field("m_value"):get_offset_from_base()
uint_value_offset = sdk.find_type_definition("System.UInt32")
    :get_field("m_value"):get_offset_from_base()

-- ===== GUID text -> System.Guid value =====
local guid_parse
-- SPEC 5.12.2: the Guid type is looked up once; the first three groups are
-- stored byte-reversed.
A.guid_type = sdk.find_type_definition("System.Guid")
guid_parse = function(text)
  local digits = (tostring(text):gsub("%X", ""))
  if #digits ~= 32 then
    error("malformed GUID '" .. tostring(text) .. "'")
  end
  local guid = ValueType.new(A.guid_type)
  for k = 0, 15 do
    local value = tonumber(digits:sub(2 * k + 1, 2 * k + 2), 16)
    local offset
    if k < 4 then offset = 3 - k
    elseif k < 6 then offset = 9 - k
    elseif k < 8 then offset = 13 - k
    else offset = k end
    guid:write_byte(offset, value)
  end
  return guid
end

-- SPEC 5.12.3: load-time check that the written bytes read back unchanged.
do
  local sample = "e26516a9-39b1-4e5d-a814-34aba7c7e023"
  local ok, back = pcall(function() return guid_parse(sample):call("ToString") end)
  if not ok or type(back) ~= "string" then
    log.warn("[Clairvoyance] GUID construction could not be checked, markers may not appear")
  elseif (back:gsub("%X", "")):lower() ~= (sample:gsub("%X", "")):lower() then
    log.error("[Clairvoyance] System.Guid byte layout differs from the assumed one: wrote "
      .. sample .. ", read back " .. back)
  end
end

-- ===== Map icon slot pools =====
local get_icon_pool
-- SPEC 5.12.4: the two slot pools, built once at load.
do
  local t = sdk.find_type_definition("app.ui040205")
  A.icon_pools = {
    { label = "panel", array = "MapIcon", ref = "Icon",
      add = t:get_method("addMapIconInfoList") },
    { label = "sprite", array = "MapIconSprite", ref = "IconSprite",
      add = t:get_method("addMapIconSpriteInfoList") },
  }
end
get_icon_pool = function(this)
  local pools = A.icon_pools
  local used = { 0, 0 }
  local native_refs = {}
  local infos = this.MapIconInfoList
  for i = 0, infos:get_Count() - 1 do
    local info = infos:get_Item(i)
    if info ~= nil then
      for pi, pool in ipairs(pools) do
        local widget = info[pool.ref]
        if widget ~= nil then
          used[pi] = used[pi] + 1
          native_refs[#native_refs + 1] = widget
        end
      end
    end
  end
  local best, best_used, best_cap, best_free = nil, 0, 0, nil
  for pi, pool in ipairs(pools) do
    local arr = this[pool.array]
    local cap = 0
    if arr ~= nil then cap = arr:get_Length() end
    local free = cap - used[pi]
    if best_free == nil or free > best_free then
      best, best_used, best_cap, best_free = pool, used[pi], cap, free
    end
  end
  return best, best_used, best_cap, native_refs
end

-- ===== Color channel order =====
-- SPEC 5.12.5: swap the red and blue bytes of a packed color.
local argb_to_abgr = require("Clairvoyance.style").abgr

-- ===== glue =====
local function set_debug(v) DEBUG = v end

local function debug_probe()
  return "NPCHolderDic=" .. tostring(NPC_HOLDER_PROBE)
    .. " QuestCatalogDict=" .. tostring(CATALOG_PROBE)
end

-- v5 (SPEC 12.3a): objective table state. Cleared on session reset and
-- on a QuestManager instance change; committed whole per walk.
local OBJECTIVE_TABLE = nil
local OBJECTIVE_FAILED_STREAK = 0
local function new_objective_stats()
    return { quests = 0, entries = 0, kept = 0,
        skipped = 0, failed_total = 0, index_builds = 0 }
end
local OBJECTIVE_STATS = new_objective_stats()
-- Processor index: the qid of each processor-list entry never changes
-- while a save is loaded, so the per-walk qid prefilter reads a cached
-- {i, qid} array instead of 3 managed reads per entry (measured 3-4 ms
-- for 428 entries). Entries unreadable at build stay in as RETRY SLOTS
-- (qid = nil), re-read every walk, so one transient bad read cannot
-- hide a processor until the next rebuild. Rebuilt on owner change,
-- list-count change, a qid-verify mismatch (once per walk, in the same
-- call), or every 60 s as a safety net.
-- v6 (SPEC 13.3a.1): shared state owned by neither walk. The owner key
-- is the QuestManager address; on change every registered consumer
-- reset runs and the build counter restarts.
local PROC_INDEX = nil
local PROC_INDEX_N = -1
local PROC_INDEX_AT = 0.0
local PROC_INDEX_OWNER = nil
local PROC_INDEX_BUILDS = 0
local PROC_INDEX_MAX_AGE = 60.0
local PROC_OWNER_RESETS = {}
local function register_owner_reset(fn)
    PROC_OWNER_RESETS[#PROC_OWNER_RESETS + 1] = fn
end
register_owner_reset(function()
    OBJECTIVE_TABLE = nil
    OBJECTIVE_FAILED_STREAK = 0
    OBJECTIVE_STATS = new_objective_stats()
end)

-- v6 (SPEC 13.3a): gate state. GATE_COND_CACHE[procid] = analysis
-- result (plain Lua values only, no managed objects); only analyses
-- with skipped == 0 are cached - a transient bad read is retried on
-- the next round instead of frozen for the session.
local GATE_TABLE = nil
local GATE_FAILED_STREAK = 0
local function new_gate_stats()
    return { gated = 0, acceptable = 0, refs = 0,
        skipped = 0, failed_total = 0, last_ms = 0.0 }
end
local GATE_STATS = new_gate_stats()
local GATE_LAST_AT = -math.huge
local GATE_REFRESH_INTERVAL = 30.0
local GATE_COND_CACHE = {}
local GATE_POPULATING = false   -- a round is open: bypass the interval
local GATE_ROUND_TRIED = {}     -- procid -> {analysis, sk}: failed analyses
                                -- already run this round (not cached)
local SEEN_QUEST_IDS = {}       -- raw qids from the last acceptable +
                                -- progressing list reads (seen-name set)
local function reset_gate_state()
    GATE_TABLE = nil
    GATE_FAILED_STREAK = 0
    GATE_STATS = new_gate_stats()
    GATE_LAST_AT = -math.huge
    GATE_COND_CACHE = {}
    GATE_POPULATING = false
    GATE_ROUND_TRIED = {}
    SEEN_QUEST_IDS = {}
end
register_owner_reset(reset_gate_state)

-- v7 (SPEC 14.3c): tree-walk state. Separate from the v6 gate walk in
-- every particular except the shared processor index and the shared
-- per-ProcID condition cache.
local function new_tree_stats()
    return { gated = 0, tracked = 0, refs = 0, skipped = 0,
        failed_total = 0, last_ms = 0.0, commits = 0 }
end
local TREE_GATE_TABLE = nil
local TREE_FAILED_STREAK = 0
local TREE_STATS = new_tree_stats()
local TREE_LAST_AT = -math.huge
local TREE_REFRESH_INTERVAL = 120.0
local TREE_POPULATING = false
local TREE_ROUND_TRIED = {}

local function reset_tree_state()
    TREE_GATE_TABLE = nil
    TREE_FAILED_STREAK = 0
    TREE_STATS = new_tree_stats()
    TREE_LAST_AT = -math.huge
    TREE_POPULATING = false
    TREE_ROUND_TRIED = {}
end
register_owner_reset(reset_tree_state)

-- v8 (SPEC 15.3c.5): LogicalOperatorInt values, resolved ONCE at load by
-- field name. No integer literal for the enum appears anywhere else; if
-- either is unresolved every requirement row reads as "other" (no needs:
-- fail closed, nothing wrong is marked). Load-time constant, not state:
-- LOGIC_OP[value] = "more" | "morethan", empty when either is unresolved.
local LOGIC_OP = {}
do
    local function enum_value(tdef, name)
        local v = nil
        pcall(function()
            local f = tdef:get_field(name)
            if f ~= nil then v = int_value(f:get_data(nil)) end
        end)
        return v
    end
    local lt = td("app.quest.condition.LogicalOperatorInt")
    if lt ~= nil then
        local more, morethan = enum_value(lt, "More"), enum_value(lt, "Morethan")
        if more ~= nil and morethan ~= nil then
            LOGIC_OP[morethan] = "morethan"
            LOGIC_OP[more] = "more"
        end
    end
end

-- v8 function table. adapter.lua's main chunk sits near Lua's 200-local
-- cap (scripts/check.ps1 prints the free slots: 32 on 2026-10-21, after the
-- v10 world tracker, which added none), so helpers are fields of this table
-- or do-block locals, never new chunk-level locals.
local items = {}

-- get_elements() returns a sol vector USERDATA in-game, not a Lua table
-- (probe P17c, 2026-10-19): # and 1-based [i] work, type() is "userdata".
-- Copies it into a plain Lua table; nil when the array or the copy fails.
function items.elements(arr)
    if arr == nil then return nil end
    local out = nil
    pcall(function()
        local v = arr:get_elements()
        if v == nil then return end
        local t = {}
        for i = 1, #v do t[i] = v[i] end
        out = t
    end)
    return out
end

function items.new_stats()
    -- round_* / drop_* split skip and cap counts by cadence (the drop
    -- scan runs every call, the rest per 10 s round); items.stats() sums
    return { needs = 0, ids = 0, located = 0, last_ms = 0.0, rounds = 0,
        skipped = 0, ignored = 0, capped = 0, failed_total = 0,
        needs_fresh = false,
        logic_ok = next(LOGIC_OP) ~= nil,
        round_skipped = 0, round_capped = 0, drop_skipped = 0, drop_capped = 0 }
end
function items.empty_locs() return { placed = {}, drop = {}, box = {} } end
function items.empty_loc_failed() return { placed = false, drop = false, box = false } end

-- v8 (SPEC 15.3n): quest-item state. Plain Lua values only; the need
-- table commits whole per round, each location set whole per scan.
local ITEM_NEEDS = nil           -- {[qid] = {{id, num}, ...}}; nil before any commit
local ITEM_WANTED = {}           -- {[id] = true}, derived from ITEM_NEEDS
local ITEM_COND_CACHE = {}       -- procid -> {{id, num, op}, ...} (clean reads only)
local ITEM_LOCS = items.empty_locs()
local ITEM_LOC_FAILED = items.empty_loc_failed()   -- last top-level read failed
local ITEM_NAME_CACHE = {}       -- item id -> name (readable icons only)
local ITEM_FAILED_STREAK = 0
local ITEM_STATS = items.new_stats()
local ITEM_LAST_AT = -math.huge

-- Clears both location tables and the per-cadence skip/cap counts.
function items.clear_locs()
    ITEM_LOCS = items.empty_locs()
    ITEM_LOC_FAILED = items.empty_loc_failed()
    ITEM_STATS.round_skipped, ITEM_STATS.round_capped = 0, 0
    ITEM_STATS.drop_skipped, ITEM_STATS.drop_capped = 0, 0
end

-- SPEC 15.3n: clears the committed tables and the streak, keeps the two
-- read caches, re-arms the walk for the next call; `rounds` untouched.
function items.invalidate()
    ITEM_NEEDS = nil
    ITEM_STATS.needs_fresh = false
    items.related, items.related_titles = nil, nil
    ITEM_WANTED = {}
    items.clear_locs()
    ITEM_FAILED_STREAK = 0
    ITEM_LAST_AT = -math.huge
    ITEM_STATS.last_ms = 0.0
end

local function reset_item_state()
    items.invalidate()
    ITEM_COND_CACHE = {}
    ITEM_NAME_CACHE = {}
    ITEM_STATS = items.new_stats()
end
register_owner_reset(reset_item_state)

-- needs / ids / located are derived from the committed tables on every
-- read, so the readout never shows a stale count after an invalidate.
function items.stats()
    local s = ITEM_STATS
    local needs, ids, seen = 0, 0, {}
    for _, list in pairs(ITEM_NEEDS or {}) do
        for _, nd in ipairs(list) do
            needs = needs + 1
            if not seen[nd.id] then seen[nd.id] = true; ids = ids + 1 end
        end
    end
    s.needs, s.ids = needs, ids
    s.located = #ITEM_LOCS.placed + #ITEM_LOCS.box + #ITEM_LOCS.drop
    s.skipped = s.round_skipped + s.drop_skipped
    s.capped = s.round_capped + s.drop_capped
    return s
end

-- v8 (SPEC 15.3g): item id -> name via the item's icon number. A
-- readable icon caches its result (the table's name, or "Item <id>" for
-- an icon not in the table); a failed read returns "Item <id>" UNCACHED
-- so it is retried on the next call. An icon not in the table falls
-- back to the game's own ItemCommonParam:get_Name() (in game 2026-10-21:
-- 130 chest item ids had no table name, get_Name answered all 130).
function items.name(id)
    local c = ITEM_NAME_CACHE[id]
    if c ~= nil then return c end
    local fallback = "Item " .. tostring(id)
    local im = sdk.get_managed_singleton("app.ItemManager")
    if im == nil then return fallback end
    local data = safe_call(im, "getItemData(System.Int32)", id)
    local icon = int_value(safe_field(data, "_IconNo"))
    local nm = icon and ITEM_NAMES_BY_ICON[icon]
    if nm == nil then
        local gn = safe_call(data, "get_Name")
        if type(gn) == "string" and gn:match("%S") then nm = gn
        elseif icon == nil then return fallback
        else nm = fallback end
    end
    ITEM_NAME_CACHE[id] = nm
    return nm
end

-- ===== v9 (SPEC 16.3a): journal readers =====
-- ONE chunk-level local (the main chunk had 15 free slots at this point
-- before v9, 14 after): every reader, cache, index and stat is a field.
-- Plain Lua values only, except the catalog index, which holds the
-- QuestLogResource objects of the current (address, count) key and is
-- dropped by journal.reset() on every session reset.
local journal = {}
function journal.new_stats()
    return { read = 0, failed = 0, tracked = nil,
        on_target = 0, off_target = 0, timeout = 0, canceled = 0 }
end
function journal.reset()
    journal.stats = journal.new_stats()
    journal.text = {}
    journal.text_n = 0
    journal.cat_index = nil
    journal.cat_key = nil
    journal.all_by = {}
    journal.names = {}
    journal.quest_pos_m = nil
end
journal.reset()

-- Runs fn(...) under pcall; a raise adds 1 to stats.failed and returns nil.
function journal.try(fn, ...)
    local ok, v = pcall(fn, ...)
    if ok then return v end
    journal.stats.failed = journal.stats.failed + 1
    return nil
end

-- Guid -> text, cached by the Guid's string form. nil for empty text.
-- Raises are left to the caller's journal.try.
function journal.msg(guid)
    if guid == nil then return nil end
    local key = guid:call("ToString()")
    if type(key) == "string" then
        local hit = journal.text[key]
        if hit ~= nil then return journal.str(hit) end
    end
    if journal.msg_get == nil then
        local t = td("via.gui.message")
        journal.msg_get = t ~= nil and t:get_method("get(System.Guid)") or nil
        if journal.msg_get == nil then
            journal.stats.failed = journal.stats.failed + 1
            return nil
        end
    end
    local s = journal.msg_get:call(nil, guid)
    if type(s) ~= "string" then s = "" end
    if type(key) == "string" then
        journal.text[key] = s
        journal.text_n = journal.text_n + 1
    end
    return journal.str(s)
end

function journal.tracked_qid()
    local gm = sdk.get_managed_singleton("app.GuiManager")
    if gm == nil then
        journal.stats.tracked = nil
        return nil
    end
    local q = journal.try(function() return int_value(gm:call("get_TargetQuestId")) end)
    if q ~= nil and q <= 0 then q = nil end
    journal.stats.tracked = q
    return q
end

function journal.str(s)
    if type(s) == "string" and s ~= "" then return s end
    return nil
end

-- Shared reader wrapper: body(qlm, qid) under journal.try; a non-nil result
-- counts as one read.
function journal.read_log(body, qid)
    local qlm = sdk.get_managed_singleton("app.QuestLogManager")
    if qlm == nil then return nil end
    local out = journal.try(body, qlm, qid)
    if out ~= nil then journal.stats.read = journal.stats.read + 1 end
    return out
end

function journal.now(qid)
    return journal.read_log(function(qlm, qid)
        local vi = qlm:call("getQuestLog", qid)
        if vi == nil then return nil end
        local r = { name = journal.str(vi:get_field("QuestName")),
            summary = journal.str(vi:get_field("QuestSummary")), checks = {} }
        local task = vi:call("get_Task")
        if task ~= nil then
            r.base = journal.msg(task:call("get_BaseMsg"))
            r.detail = journal.msg(task:call("get_DetailMsg"))
            r.checks = journal.try(function()
                local cl = {}
                for _, item in ipairs(items.elements(task:get_field("_CheckList")) or {}) do
                    local text = journal.msg(item:get_field("_BaseMsg"))
                    if text ~= nil then
                        cl[#cl + 1] = { text = text, done = item:call("evaluate") == true }
                    end
                end
                return cl
            end) or {}
            r.dest = journal.try(function()
                local d = (items.elements(task:call("getActiveDestinations")) or {})[1]
                if d == nil then return nil end
                -- The game's own journal "Open Map" position. getDestination
                -- is in a different space (offset +512, 0, -1024).
                if journal.quest_pos_m == nil then
                    local td = sdk.find_type_definition("app.ui060502_2")
                    journal.quest_pos_m = td ~= nil
                        and td:get_method("<moveToMap>g__getDefaultQuestPos|124_0") or nil
                end
                if journal.quest_pos_m == nil then return nil end
                local p = journal.quest_pos_m:call(nil, vi)
                if p == nil then return nil end
                return { x = p.x, y = p.y, z = p.z,
                    caption = journal.msg(d:get_field("_MsgId")) }
            end)
        end
        r.step_index = journal.try(function()
            return int_value(qlm:get_field("_QuestLogInfoDict"):call("get_Item", qid)
                :call("get_CurrentTaskIndex"))
        end)
        return r
    end, qid)
end

-- v13 (SPEC 21.8.2): the 1-based current step number of an in-progress
-- quest (get_CurrentTaskIndex + 1), or nil. Counted as a journal read.
function journal.quest_step(qid)
    return journal.read_log(function(qlm, qid)
        local idx = int_value(qlm:get_field("_QuestLogInfoDict"):call("get_Item", qid)
            :call("get_CurrentTaskIndex"))
        if idx == nil then return nil end
        return idx + 1
    end, qid)
end

function journal.all(qid)
    return journal.read_log(function(qlm, qid)
        local cat = qlm:get_field("_Catalog")
        if cat == nil then return nil end
        local key = tostring(qlm:get_address()) .. ":" .. tostring(int_value(cat:call("getCount")))
        if key ~= journal.cat_key then
            local idx = {}
            for _, res in ipairs(items.elements(cat:call("getValues")) or {}) do
                local id = int_value(res:call("get_QuestId"))
                if id ~= nil then idx[id] = res end
            end
            journal.cat_index = idx
            journal.cat_key = key
            journal.all_by = {}
        end
        -- The catalog text cannot change while the (address, count) key holds.
        local hit = journal.all_by[qid]
        if hit ~= nil then return hit end
        local res = journal.cat_index[qid]
        if res == nil then return nil end
        local failed0 = journal.stats.failed
        local r = { summary = journal.msg(res:call("get_Summary")), steps = {} }
        for i, t in ipairs(items.elements(res:call("get_TaskList")) or {}) do
            r.steps[i] = { base = journal.msg(t:call("get_BaseMsg")),
                detail = journal.msg(t:call("get_DetailMsg")) }
        end
        -- A read that counted a failure is not kept, so it counts again.
        if journal.stats.failed == failed0 then journal.all_by[qid] = r end
        return r
    end, qid)
end

function journal.npc_name(cid)
    if cid == nil then return nil end
    local hit = journal.names[cid]
    if hit ~= nil then return hit or nil end
    local nm = sdk.get_managed_singleton("app.NPCManager")
    if nm == nil then return nil end
    -- v14 (SPEC 22.7.2): a cid the dictionary does not hold is cached as a
    -- miss (no repeat native calls) but is not counted as a failure
    local absent = false
    local ok, n = pcall(function()
        local dict = nm:call("get_CharacterDataDict")
        if dict:call("ContainsKey", cid) == false then
            absent = true
            return nil
        end
        return journal.msg(dict:call("get_Item", cid)
            :get_field("<Normal>k__BackingField"):call("get_Item", 0):get_field("NameID"))
    end)
    if not ok then n = nil end
    if n == nil and not (ok and absent) then
        journal.stats.failed = journal.stats.failed + 1
    end
    journal.names[cid] = n or false
    return n
end

function journal.map_open(pos)
    local gm = sdk.get_managed_singleton("app.GuiManager")
    if gm == nil then return false end
    local ok = journal.try(function()
        gm:call("requestOpenMapMenu(via.vec3, app.AILocalAreaDefinition)",
            Vector3f.new(pos.x, pos.y, pos.z), 0)
        return true
    end)
    return ok == true
end

-- The full map's cursor position (a field read; failures are not Journal failures).
function journal.cursor_point(c)
    return { x = c.x, y = c.y, z = c.z }
end

function journal.map_cursor(ui)
    if ui == nil or not sdk.is_managed_object(ui) then return nil end
    local ok, c = pcall(ui.get_field, ui, "CursorUPos")
    if not ok or c == nil then return nil end
    local okp, p = pcall(journal.cursor_point, c)
    if not okp then return nil end
    local y = p.y
    if type(y) ~= "number" or y ~= y or y == math.huge or y == -math.huge then y = 0 end
    p.y = y
    return p
end

function journal.map_jump_apply(ui, pos)
    if ui == nil then return nil end
    return journal.try(function()
        ui:set_field("WorldScale", 0.375)
        ui:set_field("StartByQuest", true)
        ui:set_field("IsUpdateMapPos", true)
        ui:set_field("SetForceCursorTimer", true)
        ui:call("initMapPos(via.vec3)", Vector3f.new(pos.x, pos.y, pos.z))
        local c = ui:get_field("CursorUPos")
        return { x = c.x, z = c.z }
    end)
end

function journal.menu_open()
    local gm = sdk.get_managed_singleton("app.GuiManager")
    return gm ~= nil and journal.try(function() return gm:call("isPausedGUI") end) == true
end

function journal.close_menu()
    local gm = sdk.get_managed_singleton("app.GuiManager")
    if gm == nil then return end
    journal.try(function() gm:get_field("GameMenu"):call("requestEndMenu"); return true end)
end

function journal.note_jump(result)
    if result == "on_target" or result == "off_target"
        or result == "timeout" or result == "canceled" then
        journal.stats[result] = journal.stats[result] + 1
    end
end

function journal.stats_copy()
    local c = {}
    for k, v in pairs(journal.stats) do c[k] = v end
    c.cached = journal.text_n
    return c
end

-- ===== session-owner reset (cache clears only) =====
local QUEST_SESSION_OWNER = nil
-- SPEC 5.11: the eight first-version clears, then the project-owned rest.
local function reset_runtime_caches()
    SIDE_QUEST_CACHE = {}
    QUEST_NAME_CACHE = {}
    RUNTIME_CATALOG_OWNER = nil
    NPC_POS_CACHE_OWNER = nil
    NPC_POS_CACHE = {}
    NPC_POS_CACHE_TIME = 0
    NPC_POS_CACHE_RETRY_AT = 0
    NPC_POS_CACHE_LAST_ATTEMPT = 0
    CATALOG_INDEX = nil
    CATALOG_IDS = nil
    LEARN_CURSOR = 1
    CATALOG_STATS = { entries = 0, skipped = 0, cast_skipped = 0, distinct = 0 }
    CATALOG_MISSED = {}
    CATALOG_RETRY_AT = 0
    CATALOG_BUILT_AT = 0
    QUEST_STATE_CACHE = {}
    A.MASQUERADE_DOOR_LAST = nil
    NPC_HOLDER_CACHE = {}
    OBJECTIVE_TABLE = nil
    OBJECTIVE_FAILED_STREAK = 0
    OBJECTIVE_STATS = new_objective_stats()
    OBJECTIVE_POS_LAST = {}
    PROC_INDEX = nil
    PROC_INDEX_N = -1
    PROC_INDEX_AT = 0.0
    PROC_INDEX_OWNER = nil
    PROC_INDEX_BUILDS = 0
    reset_gate_state()
    reset_tree_state()
    reset_item_state()
    journal.reset()
end

-- ===== quest-list reads (acceptable / progressing parts) =====
-- SPEC 5.4: quest ids in list order, or nil when the list is unreadable.
local function read_quest_id_list(method, what)
    local qlm = sdk.get_managed_singleton("app.QuestLogManager")
    if qlm == nil then return nil end
    local list = safe_call(qlm, method)
    if list == nil then return nil end
    local ids = {}
    local ok = each_collection(list, function(item)
        local q = int_value(item)
        if q == nil then return false end
        ids[#ids + 1] = q
    end)
    if not ok then
        dlog("Failed to enumerate " .. what
            .. " quest list; retaining last complete snapshot")
        return nil
    end
    return ids
end

-- SPEC 5.5: side-quest test; a decided answer is cached, a range guess is not.
local function is_side_quest(qid)
    if type(qid) ~= "number" then return false end
    -- Sudden quests (29xxx) are dynamic events, not map-startable side
    -- quests: no titles or log text exist for them anywhere in the game
    -- files (verified by full pak extraction 2026-10-16). A constant answer
    -- needs no cache and no reflection.
    if qid >= 29000 and qid <= 29999 then return false end
    local cached = SIDE_QUEST_CACHE[qid]
    if cached ~= nil then return cached end
    local qlm = sdk.get_managed_singleton("app.QuestLogManager")
    if qlm ~= nil then
        local decided = nil
        for _, name in ipairs(A.SIDE_YES_CALLS) do
            if safe_call(qlm, name, qid) == true then decided = true break end
        end
        if decided == nil then
            for _, name in ipairs(A.SIDE_NO_CALLS) do
                if safe_call(qlm, name, qid) == true then decided = false break end
            end
        end
        if decided == nil then
            local entry = safe_call(qlm, "getQuestLog", qid)
            if entry ~= nil then
                for _, field in ipairs(A.SIDE_ENTRY_FIELDS) do
                    local v = safe_field(entry, field)
                    local text = (v == nil) and "" or tostring(v):lower()
                    if text:find("side", 1, true) or text:find("sub", 1, true) then
                        decided = true break
                    end
                    if text:find("main", 1, true) or text:find("story", 1, true) then
                        decided = false break
                    end
                end
            end
        end
        if decided ~= nil then
            SIDE_QUEST_CACHE[qid] = decided
            return decided
        end
    end
    return qid >= 20000 and qid <= 39999
end

-- the quests the objective walk and the item round both cover: side quests
-- and the focused ones (SPEC 32.6.1.2)
items.walks_quest = function(q)
    return is_side_quest(q) or (items.focus_set ~= nil and items.focus_set[q])
end

-- SPEC 12.3a: one processor-list walk per call. Records only; the pure
-- builder (injected core.objective_table) selects and orders.
local function objective_walk_failed()
    OBJECTIVE_FAILED_STREAK = OBJECTIVE_FAILED_STREAK + 1
    OBJECTIVE_STATS.failed_total = OBJECTIVE_STATS.failed_total + 1
    if OBJECTIVE_FAILED_STREAK >= 3 then
        OBJECTIVE_TABLE = { cids = {}, issued = {}, miss = {},
            issued_miss = {}, issued_streak = {} }
    end
end

-- One pass over the whole processor list, qids only. An entry whose qid
-- cannot be read right now stays in as a retry slot (qid = nil): the
-- walk re-reads it every cycle, so one transient bad read cannot hide a
-- processor until the next rebuild.
local function build_proc_index(list, n)
    local idx = {}
    for i = 0, n - 1 do
        local qid = nil
        pcall(function()
            local p = safe_call(list, "get_Item", i)
            if p == nil then return end
            local qc = safe_field(p, "<RefQuestController>k__BackingField")
            qid = int_value(safe_field(qc, "_QuestID"))
        end)
        idx[#idx + 1] = { i = i, qid = qid }
    end
    PROC_INDEX_BUILDS = PROC_INDEX_BUILDS + 1
    return idx
end

-- Owner handling is separate from rebuild handling so both walks can
-- detect an owner change BEFORE their list/count reads (a new owner
-- whose first walk fails must still clear consumer state).
local function proc_index_note_owner(owner)
    if PROC_INDEX_OWNER ~= owner then
        PROC_INDEX_OWNER = owner
        PROC_INDEX = nil
        PROC_INDEX_BUILDS = 0
        for _, fn in ipairs(PROC_OWNER_RESETS) do
            local okr, errr = pcall(fn)
            if not okr then
                dlog("owner reset raised: " .. tostring(errr))
            end
        end
    end
end

local function ensure_processor_index(list, n)
    if PROC_INDEX == nil or PROC_INDEX_N ~= n
        or os.clock() - PROC_INDEX_AT > PROC_INDEX_MAX_AGE then
        PROC_INDEX = build_proc_index(list, n)
        PROC_INDEX_N = n
        PROC_INDEX_AT = os.clock()
    end
    return PROC_INDEX
end
local function proc_index_drop() PROC_INDEX = nil end

-- SPEC 12.3a.7 compares QuestManager instances by address (an integer),
-- never by holding the managed object across ticks. An unreadable
-- address is a failed walk, not a fallback to keeping the object.
local function qm_owner_key(qm)
    local addr = nil
    pcall(function() addr = qm:get_address() end)
    return addr
end

-- Shared per-entry machinery for both processor walks. Visits every
-- index entry whose cached qid is in `wanted` plus retry slots, pcall per
-- entry: get_Item (nil = skip), qid re-read via int_value (nil = skip;
-- retry slot upgraded in place; readable-but-different = mismatch),
-- optional pre(p, qid, skip) (false = stop here, any other value is passed
-- on as ctx), then strict IsStarted == true and get_ProcessFinished ==
-- false. on_entry(p, qid, skip, ctx) runs for survivors. Returns the
-- skipped count, or nil on a mismatch (nothing read in that pass can be
-- trusted).
local function visit_verified_entries(idx, list, wanted, on_entry, pre)
    local skipped, mismatch = 0, false
    local function skip() skipped = skipped + 1 end
    for _, e in ipairs(idx) do
        if e.qid == nil or wanted[e.qid] then
            local ok = pcall(function()
                local p = safe_call(list, "get_Item", e.i)
                if p == nil then skip() return end
                local qc = safe_field(p, "<RefQuestController>k__BackingField")
                local qid = int_value(safe_field(qc, "_QuestID"))
                if qid == nil then skip() return end
                if e.qid == nil then
                    e.qid = qid   -- retry slot upgraded in place
                    if not wanted[qid] then return end
                elseif qid ~= e.qid then
                    mismatch = true
                    return
                end
                local ctx = nil
                if pre ~= nil then
                    ctx = pre(p, qid, skip)
                    if ctx == false then return end
                end
                local started = safe_field(p, "<IsStarted>k__BackingField")
                if started == nil then skip() return end
                if started ~= true then return end
                local fin = safe_call(p, "get_ProcessFinished")
                if fin == nil then skip() return end
                if fin ~= false then return end
                on_entry(p, qid, skip, ctx)
            end)
            if not ok then skip() end
            if mismatch then return nil end
        end
    end
    return skipped
end

-- Runs pass(idx) over the ensured index. A nil first result (mismatch)
-- drops the index, rebuilds once and retries in the same call; a second
-- nil drops again and calls on_fail. Returns pass's results, or nil.
local function with_index_retry(list, n, pass, on_fail)
    local r1, r2, r3 = pass(ensure_processor_index(list, n))
    if r1 == nil then
        proc_index_drop()
        r1, r2, r3 = pass(ensure_processor_index(list, n))
        if r1 == nil then
            proc_index_drop()
            on_fail()
            return nil
        end
    end
    return r1, r2, r3
end

local function refresh_objectives_body()
    local qm = sdk.get_managed_singleton("app.QuestManager")
    if qm == nil then objective_walk_failed() return end
    local owner = qm_owner_key(qm)
    if owner == nil then objective_walk_failed() return end
    proc_index_note_owner(owner)
    local list = safe_field(qm, "DistributedQuestProcessors")
    local n = safe_call(list, "get_Count")
    if type(n) ~= "number" then objective_walk_failed() return end
    ensure_processor_index(list, n)
    local prog = read_quest_id_list("getProgressingQuestIds", "progressing")
    if prog == nil then objective_walk_failed() return end
    local progressing = {}
    for _, qid in ipairs(prog) do
        if items.walks_quest(qid) then progressing[qid] = true end
    end
    if next(progressing) == nil then
        -- No side quest in progress: skip the walk, but still commit so
        -- retention/stickiness state ages out correctly.
        local t = qnml_core.objective_table({}, OBJECTIVE_TABLE, progressing)
        if type(t) ~= "table" or type(t.cids) ~= "table"
            or type(t.issued) ~= "table" then
            error("objective_table: bad result")
        end
        OBJECTIVE_TABLE = t
        OBJECTIVE_FAILED_STREAK = 0
        OBJECTIVE_STATS.quests, OBJECTIVE_STATS.entries = 0, n
        OBJECTIVE_STATS.kept, OBJECTIVE_STATS.skipped = 0, 0
        return
    end
    local kept = 0
    local function pass(cur)
        local records = {}
        kept = 0
        local skipped = visit_verified_entries(cur, list, progressing,
            function(p, qid, skip)
                local proc = safe_field(p, "Process")
                local action = safe_field(proc, "QuestAction")
                if action == nil then return end
                local tn = nil
                pcall(function()
                    tn = action:get_type_definition():get_full_name()
                end)
                if tn == nil then skip() return end
                if tn ~= "app.quest.action.NpcControl" then return end
                local cid = holder_cid(safe_field(action, "_NpcHolder"))
                if cid == nil then skip() return end
                kept = kept + 1
                records[#records + 1] = { qid = qid, cid = cid,
                    issued = (safe_field(action, "IsIssuedTask") == true) }
            end)
        if skipped == nil then return nil end
        return records, skipped
    end
    local records, skipped = with_index_retry(list, n, pass, objective_walk_failed)
    if records == nil then return end
    local t = qnml_core.objective_table(records, OBJECTIVE_TABLE, progressing)
    if type(t) ~= "table" or type(t.cids) ~= "table"
        or type(t.issued) ~= "table" then
        error("objective_table: bad result")
    end
    OBJECTIVE_TABLE = t
    OBJECTIVE_FAILED_STREAK = 0
    local quests = 0
    for _ in pairs(OBJECTIVE_TABLE.cids) do quests = quests + 1 end
    OBJECTIVE_STATS.quests = quests
    OBJECTIVE_STATS.entries = n
    OBJECTIVE_STATS.kept = kept
    OBJECTIVE_STATS.skipped = skipped
end

local function refresh_objectives()
    local ok, err = pcall(refresh_objectives_body)
    if not ok then
        objective_walk_failed()
        error(err, 0)   -- re-raise so the main file's pcall can log it once
    end
end

-- ===== v6 gate: condition analysis + liveness reads (SPEC 13.3a.4) =====
local COND_VAR = "app.quest.condition.CheckQuestVariable"
local COND_STATUS = "app.quest.condition.CheckQuestStatus"
local COND_TREE = "app.quest.condition.CheckQuestCondition"
local ITEM_SCEN = "app.quest.condition.CheckScenarioParam"
local ITEM_QUEST = "app.quest.condition.CheckQuestParam"

-- Reads one processor's ConditionLists. Total: always returns a result
-- table plus a skipped delta; unreadable pieces are skipped +
-- counted, never fatal. Stores plain Lua values only.
local function analyze_processor(p, own_qid)
    -- skipped = failed reads (block caching: retried next round)
    local res, skipped = { root = true, refs = {} }, 0
    local cls = safe_field(p, "ConditionLists")
    if cls == nil then return res, 0 end
    local outer = safe_call(cls, "get_Count")
    if type(outer) ~= "number" then return res, 1, 0 end
    if outer > 16 then outer = 16 end
    for a2 = 0, outer - 1 do
        local inner = safe_call(cls, "get_Item", a2)
        local m = inner ~= nil and safe_call(inner, "get_Count") or nil
        if type(m) ~= "number" then skipped = skipped + 1
        else
            if m > 16 then m = 16 end
            for b = 0, m - 1 do
                local c = safe_call(inner, "get_Item", b)
                if c == nil then skipped = skipped + 1
                else
                    local tn = nil
                    pcall(function()
                        tn = c:get_type_definition():get_full_name()
                    end)
                    if tn == nil then skipped = skipped + 1
                    elseif tn == COND_STATUS then
                        local prm = safe_field(c, "Param")
                        local rq = int_value(safe_field(prm, "_QuestID"))
                        if rq == -1 or rq == own_qid then res.root = false
                        elseif rq == nil then skipped = skipped + 1
                        elseif rq > 0 then
                            res.refs[#res.refs + 1] = { ref = rq, kind = "status" }
                        end
                    elseif tn == COND_VAR then
                        local prm = safe_field(c, "_Param")
                        local rq = int_value(safe_field(prm, "_QuestID"))
                        if rq == nil then skipped = skipped + 1
                        elseif rq > 0 and rq ~= own_qid then
                            -- an UNREADABLE vtype is a failed read (retried,
                            -- never cached); a readable unknown vtype is
                            -- closed by design (var_gate_open)
                            local vt = int_value(safe_field(prm, "_ValueType"))
                            if vt == nil then skipped = skipped + 1 end
                            res.refs[#res.refs + 1] = { ref = rq, kind = "var",
                                slot = { a2, b }, vtype = vt }
                        end
                    elseif tn == COND_TREE then
                        local okt = pcall(function()
                            local qcond = safe_field(c, "_Condition")
                            local arr = qcond and safe_field(qcond, "ConditionParamArray")
                            local elems = arr and arr:get_elements() or {}
                            local cap = #elems
                            if cap > 8 then cap = 8 end
                            for k = 1, cap do
                                local it = elems[k]
                                local itn = nil
                                pcall(function()
                                    itn = it:get_type_definition():get_full_name()
                                end)
                                if itn == nil then skipped = skipped + 1
                                elseif itn == ITEM_SCEN then
                                    local rq = int_value(safe_field(it, "_QuestID"))
                                    if rq == nil then skipped = skipped + 1
                                    elseif rq > 0 and rq ~= own_qid then
                                        res.refs[#res.refs + 1] = { ref = rq, kind = "status" }
                                    end
                                elseif itn == ITEM_QUEST then
                                    local rq = int_value(safe_field(it, "_QuestID"))
                                    if rq == nil then skipped = skipped + 1
                                    elseif rq == -1 or rq == own_qid then res.root = false end
                                end
                            end
                        end)
                        if not okt then skipped = skipped + 1 end
                    end
                end
            end
        end
    end
    return res, skipped
end

-- A "var" gate is OPEN only when both sides read back and compare
-- equal. Unknown vtype, any nil read, or an unreachable slot = CLOSED.
local function var_gate_open(p, slot, vtype)
    local open = false
    pcall(function()
        local cls = safe_field(p, "ConditionLists")
        local inner = safe_call(cls, "get_Item", slot[1])
        local c = safe_call(inner, "get_Item", slot[2])
        local prm = safe_field(c, "_Param")
        if c == nil or prm == nil then return end
        if vtype == 1 then
            local f = safe_field(c, "_BoolFact")
            local e = safe_field(prm, "_BoolValue")
            open = type(f) == "boolean" and type(e) == "boolean" and f == e
        elseif vtype == 2 then
            local f = int_value(safe_field(c, "_IntFact"))
            local e = int_value(safe_field(prm, "_IntValue"))
            open = f ~= nil and e ~= nil and f == e
        end
    end)
    return open
end

-- ===== v6 gate walk (SPEC 13.3a.2-6) =====
local GATE_ANALYSIS_BUDGET = 80

-- A failed walk waits the full interval too (GATE_LAST_AT is set at
-- attempt start), so it also closes any open population round.
local function gate_walk_failed(t0)
    GATE_FAILED_STREAK = GATE_FAILED_STREAK + 1
    GATE_STATS.failed_total = GATE_STATS.failed_total + 1
    GATE_POPULATING = false
    GATE_ROUND_TRIED = {}
    if t0 ~= nil then
        GATE_STATS.last_ms = (os.clock() - t0) * 1000.0
    end
    if GATE_FAILED_STREAK >= 3 then GATE_TABLE = {} end
end

-- Shared pass of the v6 gate walk and the v7 tree walk: `wanted` is the
-- qid set to visit, `round_tried` the caller's failed-analysis table
-- (passed per call; reassigned only after the pass), `ctx.analyzed` the
-- per-call analysis budget counter. Reads/writes GATE_COND_CACHE.
local function gate_pass(cur, list, wanted, round_tried, ctx)
    local records, missed, qs_memo = {}, false, {}
    local skipped = visit_verified_entries(cur, list, wanted,
        function(p, qid, skip, procid)
            local analysis = GATE_COND_CACHE[procid]
            if analysis == nil then
                local tried = round_tried[procid]
                if tried ~= nil then
                    -- failed analysis already run this round: reuse it
                    -- (no budget spent) so the round can complete
                    analysis = tried.analysis
                    for _ = 1, tried.sk do skip() end
                else
                    if ctx.analyzed >= GATE_ANALYSIS_BUDGET then
                        missed = true
                        return
                    end
                    ctx.analyzed = ctx.analyzed + 1
                    local sk
                    analysis, sk = analyze_processor(p, qid)
                    if sk == 0 then
                        GATE_COND_CACHE[procid] = analysis
                    else
                        round_tried[procid] = { analysis = analysis, sk = sk }
                        for _ = 1, sk do skip() end
                    end
                end
            end
            if analysis.root and #analysis.refs > 0 then
                for _, ref in ipairs(analysis.refs) do
                    local st = qs_memo[ref.ref]   -- one query per ref per walk
                    if st == nil then
                        st = quest_state(ref.ref) or false
                        qs_memo[ref.ref] = st
                    end
                    if st == false
                        and (ref.kind ~= "var"
                            or not var_gate_open(p, ref.slot, ref.vtype)) then
                        records[#records + 1] = { qid = qid, ref = ref.ref }
                    end
                end
            end
        end,
        -- SPEC 13.3a.5: ProcID first; a CACHED processor that is not a
        -- root with refs contributes nothing, so its IsStarted /
        -- ProcessFinished reads are skipped
        function(p, _, skip)
            local procid = int_value(safe_field(p, "ProcID"))
            if procid == nil then skip() return false end
            local an = GATE_COND_CACHE[procid]
            if an ~= nil and not (an.root and #an.refs > 0) then
                return false
            end
            return procid
        end)
    if skipped == nil then return nil end
    return records, skipped, missed
end

local function refresh_gates_body()
    local now = os.clock()
    if not GATE_POPULATING
        and now - GATE_LAST_AT < GATE_REFRESH_INTERVAL then
        return
    end
    GATE_LAST_AT = now   -- set at attempt START: a failed walk waits the
                         -- full interval too, instead of retrying at
                         -- tick rate through a loading screen
    local qm = sdk.get_managed_singleton("app.QuestManager")
    if qm == nil then gate_walk_failed(now) return end
    local owner = qm_owner_key(qm)
    if owner == nil then gate_walk_failed(now) return end
    proc_index_note_owner(owner)
    -- an owner change just reset GATE_LAST_AT; re-stamp this attempt
    GATE_LAST_AT = now
    local list = safe_field(qm, "DistributedQuestProcessors")
    local n = safe_call(list, "get_Count")
    if type(n) ~= "number" then gate_walk_failed(now) return end
    ensure_processor_index(list, n)
    local acc = read_quest_id_list("getAcceptableQuestList", "acceptable")
    if acc == nil then gate_walk_failed(now) return end
    local prog = read_quest_id_list("getProgressingQuestIds", "progressing")
    -- seen set: RAW ids from both lists (a nil progressing list just
    -- contributes nothing; it does not fail the walk)
    SEEN_QUEST_IDS = {}
    for _, q in ipairs(acc) do SEEN_QUEST_IDS[q] = true end
    for _, q in ipairs(prog or {}) do SEEN_QUEST_IDS[q] = true end
    local accset, acount = {}, 0
    for _, q in ipairs(acc) do
        if is_side_quest(q) then accset[q] = true acount = acount + 1 end
    end
    if acount == 0 then
        GATE_TABLE = {}
        GATE_FAILED_STREAK = 0
        GATE_POPULATING = false
        GATE_ROUND_TRIED = {}
        GATE_STATS.gated, GATE_STATS.acceptable = 0, 0
        GATE_STATS.refs, GATE_STATS.skipped = 0, 0
        GATE_STATS.last_ms = (os.clock() - now) * 1000.0
        return
    end
    local ctx = { analyzed = 0 }   -- analyses run by THIS call (budget)
    -- No resume cursor: every call covers ALL entries in accset plus
    -- retry slots; only ANALYSIS is budgeted.
    local function pass(cur)
        return gate_pass(cur, list, accset, GATE_ROUND_TRIED, ctx)
    end
    local records, skipped, missed = with_index_retry(list, n, pass,
        function() gate_walk_failed(now) end)
    if records == nil then return end
    if missed then
        -- Population continues next tick; a partial walk is neither a
        -- success nor a failure (streak untouched), nothing commits.
        GATE_POPULATING = true
        GATE_STATS.last_ms = (os.clock() - now) * 1000.0
        return
    end
    GATE_POPULATING = false
    GATE_ROUND_TRIED = {}
    local t = qnml_core.gate_table(records)
    if type(t) ~= "table" then error("gate_table: bad result") end
    GATE_TABLE = t
    GATE_FAILED_STREAK = 0
    local gated = 0
    for _ in pairs(GATE_TABLE) do gated = gated + 1 end
    GATE_STATS.gated = gated
    GATE_STATS.acceptable = acount
    GATE_STATS.refs = #records
    GATE_STATS.skipped = skipped
    GATE_STATS.last_ms = (os.clock() - now) * 1000.0
end

local function refresh_gates()
    local t0 = os.clock()
    local ok, err = pcall(refresh_gates_body)
    if not ok then
        gate_walk_failed(t0)
        error(err, 0)   -- re-raise so the main file's pcall can log it once
    end
end

-- ===== v7 tree walk (SPEC 14.3c) =====
-- A failed walk waits the full interval too (TREE_LAST_AT is set at
-- attempt start), so it also closes any open population round.
local function tree_walk_failed(t0)
    TREE_FAILED_STREAK = TREE_FAILED_STREAK + 1
    TREE_STATS.failed_total = TREE_STATS.failed_total + 1
    TREE_POPULATING = false
    TREE_ROUND_TRIED = {}
    if t0 ~= nil then
        TREE_STATS.last_ms = (os.clock() - t0) * 1000.0
    end
    if TREE_FAILED_STREAK >= 3 then TREE_GATE_TABLE = {} end
end

local function refresh_tree_body()
    local now = os.clock()
    if not TREE_POPULATING
        and now - TREE_LAST_AT < TREE_REFRESH_INTERVAL then
        return
    end
    TREE_LAST_AT = now
    local qm = sdk.get_managed_singleton("app.QuestManager")
    if qm == nil then tree_walk_failed(now) return end
    local owner = qm_owner_key(qm)
    if owner == nil then tree_walk_failed(now) return end
    proc_index_note_owner(owner)
    -- an owner change just reset TREE_LAST_AT; re-stamp this attempt
    TREE_LAST_AT = now
    -- Committed catalog index only: never catalog_ids(), which can walk.
    -- No catalog yet is neither a commit nor a failure; retry next call.
    local cat = CATALOG_IDS
    if cat == nil then
        TREE_LAST_AT = -math.huge
        return
    end
    local list = safe_field(qm, "DistributedQuestProcessors")
    local n = safe_call(list, "get_Count")
    if type(n) ~= "number" then tree_walk_failed(now) return end
    ensure_processor_index(list, n)
    local acc = read_quest_id_list("getAcceptableQuestList", "acceptable")
    if acc == nil then tree_walk_failed(now) return end
    local prog = read_quest_id_list("getProgressingQuestIds", "progressing")
    if prog == nil then tree_walk_failed(now) return end
    local accset, progset = {}, {}
    for _, q in ipairs(acc) do accset[q] = true end
    for _, q in ipairs(prog) do progset[q] = true end
    -- tracked = catalog side quests that are neither acceptable nor
    -- progressing nor known-ended (QUEST_STATE_CACHE hit only; a miss is
    -- tracked, quest_state is never called for this test)
    local tracked, tcount = {}, 0
    for _, q in ipairs(cat) do
        if not accset[q] and not progset[q]
            and QUEST_STATE_CACHE[q] == nil and is_side_quest(q) then
            tracked[q] = true
            tcount = tcount + 1
        end
    end
    if tcount == 0 then
        TREE_GATE_TABLE = {}
        TREE_FAILED_STREAK = 0
        TREE_POPULATING = false
        TREE_ROUND_TRIED = {}
        TREE_STATS.gated, TREE_STATS.tracked = 0, 0
        TREE_STATS.refs, TREE_STATS.skipped = 0, 0
        TREE_STATS.commits = TREE_STATS.commits + 1
        TREE_STATS.last_ms = (os.clock() - now) * 1000.0
        return
    end
    local ctx = { analyzed = 0 }   -- analyses run by THIS call (budget)
    local function pass(cur)
        return gate_pass(cur, list, tracked, TREE_ROUND_TRIED, ctx)
    end
    local records, skipped, missed = with_index_retry(list, n, pass,
        function() tree_walk_failed(now) end)
    if records == nil then return end
    if missed then
        TREE_POPULATING = true
        TREE_STATS.last_ms = (os.clock() - now) * 1000.0
        return
    end
    TREE_POPULATING = false
    TREE_ROUND_TRIED = {}
    local t = qnml_core.gate_table(records)
    if type(t) ~= "table" then error("gate_table: bad result") end
    TREE_GATE_TABLE = t
    TREE_FAILED_STREAK = 0
    local gated = 0
    for _ in pairs(t) do gated = gated + 1 end
    TREE_STATS.gated = gated
    TREE_STATS.tracked = tcount
    TREE_STATS.refs = #records
    TREE_STATS.skipped = skipped
    TREE_STATS.commits = TREE_STATS.commits + 1
    TREE_STATS.last_ms = (os.clock() - now) * 1000.0
end

local function refresh_tree_gates()
    local t0 = os.clock()
    local ok, err = pcall(refresh_tree_body)
    if not ok then
        tree_walk_failed(t0)
        error(err, 0)   -- re-raise so the main file's pcall can log it once
    end
end

-- ===== v8 quest-item round + scans (SPEC 15.3b-f) =====
-- One do-block: its locals are released at `end` (main-chunk local cap,
-- see the `items` table); only items.refresh leaves it.
do
local K = {
    COND_HAS_ITEM = "app.quest.condition.CheckHasItem",
    COND_DELIVER = "app.quest.condition.CheckDeliver",
    GM_PLACED = "app.Gm82_000",
    STORAGE_BOX_KEY = 65535,
    HELD_OWNER_CAP = 512,
    MANAGED_CAP = 4096,
    DROP_CAP = 64,
    BOX_CAP = 64,
    BOX_ITEMS_CAP = 16,
    ROUND_INTERVAL = 10.0,
}

-- Appends one CheckHasItem condition's rows to `rows`; returns the
-- skipped count (a failed read or an unreadable row counts, never fatal).
function items.read_has_item_rows(c, rows)
    local skipped = 0
    local okc = pcall(function()
        local prm = safe_field(c, "Param")
        local ia = safe_field(prm, "_ItemInfoArray")
        local elems = items.elements(ia)
        if elems == nil then
            skipped = skipped + 1
            return
        end
        for k = 1, #elems do
            local it = elems[k]
            local id = int_value(safe_field(it, "_ID"))
            local num = int_value(safe_field(it, "_Number"))
            local lv = int_value(safe_field(it, "_Logic"))
            if id == nil or num == nil or lv == nil then
                skipped = skipped + 1
            else
                rows[#rows + 1] = { id = id, num = num,
                    op = LOGIC_OP[lv] or "other" }
            end
        end
    end)
    if not okc then skipped = skipped + 1 end
    return skipped
end

-- Appends one CheckDeliver condition's single row to `rows`; same contract
-- as read_has_item_rows (skipped count; a failed read or any nil among
-- _ItemID/_Count/_Logic is one skip and no row). The param field is
-- "_Param", not "Param".
function items.read_deliver_rows(c, rows)
    local skipped = 0
    local okc = pcall(function()
        local prm = safe_field(c, "_Param")
        local id = int_value(safe_field(prm, "_ItemID"))
        local num = int_value(safe_field(prm, "_Count"))
        local lv = int_value(safe_field(prm, "_Logic"))
        if id == nil or num == nil or lv == nil then
            skipped = skipped + 1
        else
            rows[#rows + 1] = { id = id, num = num,
                op = LOGIC_OP[lv] or "other" }
        end
    end)
    if not okc then skipped = skipped + 1 end
    return skipped
end

-- Reads one processor's CheckHasItem and CheckDeliver rows. Total: always returns a row
-- list plus a skipped count; unreadable pieces are skipped + counted,
-- never fatal. The ConditionLists walk and its 16/16 caps mirror
-- analyze_processor, with ONE difference: a nil ConditionLists read is a
-- counted skip (never cached), because safe_field also returns nil on a
-- failed read and a cached empty list would hide that processor's need
-- for the whole session. Stores plain Lua values only.
local function read_item_conditions(p)
    local rows, skipped = {}, 0
    local cls = safe_field(p, "ConditionLists")
    if cls == nil then return rows, 1 end
    local outer = safe_call(cls, "get_Count")
    if type(outer) ~= "number" then return rows, 1 end
    if outer > 16 then outer = 16 end
    for a2 = 0, outer - 1 do
        local inner = safe_call(cls, "get_Item", a2)
        local m = inner ~= nil and safe_call(inner, "get_Count") or nil
        if type(m) ~= "number" then skipped = skipped + 1
        else
            if m > 16 then m = 16 end
            for b = 0, m - 1 do
                local c = safe_call(inner, "get_Item", b)
                if c == nil then skipped = skipped + 1
                else
                    local tn = nil
                    pcall(function()
                        tn = c:get_type_definition():get_full_name()
                    end)
                    if tn == nil then skipped = skipped + 1
                    elseif tn == K.COND_HAS_ITEM then
                        skipped = skipped + items.read_has_item_rows(c, rows)
                    elseif tn == K.COND_DELIVER then
                        skipped = skipped + items.read_deliver_rows(c, rows)
                    end
                end
            end
        end
    end
    return rows, skipped
end

-- SPEC 15.3d: held count over getStorageDict's owner lists (player +
-- pawns; the storage box, key 65535, is skipped). Returns held
-- {[id] = n} for the wanted ids plus a skipped count, or nil when the
-- manager, the dictionary or its _entries is unreadable (failed round).
local function read_held(ids)
    local im = sdk.get_managed_singleton("app.ItemManager")
    if im == nil then return nil end
    local dict = safe_call(im, "getStorageDict")
    if dict == nil then return nil end
    local en = safe_field(dict, "_entries")
    local entries = items.elements(en)
    if entries == nil then return nil end
    local held, skipped = {}, 0
    for i = 1, #entries do
        local ok = pcall(function()
            local e = entries[i]
            local list = safe_field(e, "value")
            if list == nil then return end          -- free slot: uncounted
            local key = int_value(safe_field(e, "key"))
            if key == nil then skipped = skipped + 1 return end
            if key == K.STORAGE_BOX_KEY then return end
            local cnt = safe_call(list, "get_Count")
            if type(cnt) ~= "number" then skipped = skipped + 1 return end
            if cnt > K.HELD_OWNER_CAP then cnt = K.HELD_OWNER_CAP end
            for k = 0, cnt - 1 do
                local okd = pcall(function()
                    local sd = safe_call(list, "get_Item", k)
                    local id = int_value(safe_field(sd, "_ItemId"))
                    local num = int_value(safe_field(sd, "_Num"))
                    if id == nil or num == nil then
                        skipped = skipped + 1
                        return
                    end
                    if ids[id] then held[id] = (held[id] or 0) + num end
                end)
                if not okd then skipped = skipped + 1 end
            end
        end)
        if not ok then skipped = skipped + 1 end
    end
    return held, skipped
end

-- Installs a need table and derives ITEM_WANTED. An empty table clears
-- all three location sets (no scan runs while nothing is needed).
local function commit_item_needs(t)
    ITEM_NEEDS = t
    ITEM_STATS.needs_fresh = true
    -- v14 (SPEC 22.10.1): the quest-related map dies with the need table;
    -- a normal round sets it again right after this call
    items.related, items.related_titles = nil, nil
    local w = {}
    for _, list in pairs(t) do
        for _, nd in ipairs(list) do w[nd.id] = true end
    end
    ITEM_WANTED = w
    if next(w) == nil then items.clear_locs() end
end

-- SPEC 15.3e failure semantics: a failed round keeps the previous table;
-- the 3rd consecutive failure commits {}.
local function item_round_failed()
    ITEM_FAILED_STREAK = ITEM_FAILED_STREAK + 1
    ITEM_STATS.failed_total = ITEM_STATS.failed_total + 1
    ITEM_STATS.needs_fresh = false
    if ITEM_FAILED_STREAK >= 3 then commit_item_needs({}) end
end

-- Map-space and transform-space positions of a gimmick (SPEC 15.3f).
-- nil pos = no record; nil live = record without an overhead dot.
local function gimmick_pos(g)
    local tr = safe_call(safe_call(g, "get_GameObject"), "get_Transform")
    if tr == nil then return nil end
    local x, y, z = vec_xyz(safe_call(tr, "get_UniversalPosition"))
    if x == nil then return nil end
    local live = nil
    local lx, ly, lz = vec_xyz(safe_call(tr, "get_Position"))
    if lx ~= nil then live = { x = lx, y = ly, z = lz } end
    return { x = x, y = y, z = z }, live
end

-- v14 (SPEC 22.11.3): read the masquerade passage leaf. The full fingerprint
-- prevents another nearby saloon door from deciding this one hint pin.
function A.read_masquerade_door_closed(gm)
    local dict = safe_field(gm, "<ManagedGimmicksByIDs>k__BackingField")
    local outer = items.elements(safe_field(dict, "_entries"))
    if outer == nil then return nil end
    local matched, matches = nil, 0
    for i = 1, #outer do
        if int_value(safe_field(outer[i], "key")) == 85 then
            local hs = safe_field(outer[i], "value")
            local inner = items.elements(safe_field(hs, "_entries"))
            if inner == nil then return nil end
            for k = 1, #inner do
                local g = safe_field(inner[k], "Value")
                if g == nil then g = safe_field(inner[k], "value") end
                if g ~= nil then
                    local ok = pcall(function()
                        local gt = g:get_type_definition()
                        if gt == nil or gt:get_full_name() ~= "app.gm05_046" then return end
                        local go = safe_call(g, "get_GameObject")
                        if safe_call(go, "get_Name") ~= "gm80_026" then return end
                        local tr = safe_call(go, "get_Transform")
                        local x, y, z = vec_xyz(safe_call(tr, "get_UniversalPosition"))
                        if x == nil then return end
                        local dx, dy, dz = x - 396.075, y - 73.5, z + 819.250
                        if dx * dx + dy * dy + dz * dz > 0.0625 then return end
                        local rok, leaves, n = read_collection_items(safe_field(g, "CompDoorList"))
                        if not rok or n ~= 1 then error("door leaf unreadable") end
                        local closed = safe_field(leaves[1], "IsClose")
                        if type(closed) ~= "boolean" then error("door state unreadable") end
                        matches = matches + 1
                        matched = closed
                    end)
                    if not ok then return nil end
                end
            end
        end
    end
    if matches ~= 1 then return nil end
    return matched
end

-- Each scan returns records, skipped, capped - or nil when its
-- top-level read fails. One pcall per gimmick; a nil pos is a skip.
local function scan_placed(gm)
    local dict = safe_field(gm, "<ManagedGimmicksByIDs>k__BackingField")
    local en = safe_field(dict, "_entries")
    local outer = items.elements(en)
    if outer == nil then return nil end
    local recs, skipped, capped, seen = {}, 0, 0, 0
    for i = 1, #outer do
        local ok = pcall(function()
            local hs = safe_field(outer[i], "value")
            if hs == nil then return end            -- free slot: uncounted
            local hen = safe_field(hs, "_entries")
            local inner = items.elements(hen)
            if inner == nil then skipped = skipped + 1 return end
            for k = 1, #inner do
                local g = safe_field(inner[k], "Value")
                if g == nil then g = safe_field(inner[k], "value") end
                if g ~= nil then                     -- nil = free slot: uncounted
                    if seen >= K.MANAGED_CAP then
                        capped = capped + 1
                    else
                        seen = seen + 1
                        local okg = pcall(function()
                            local tn = g:get_type_definition():get_full_name()
                            if tn ~= K.GM_PLACED then return end
                            local id = int_value(safe_field(g, "ItemId"))
                            if id == nil then skipped = skipped + 1 return end
                            if not ITEM_WANTED[id] then return end
                            local pos, live = gimmick_pos(g)
                            if pos == nil then skipped = skipped + 1 return end
                            recs[#recs + 1] = { id = id, pos = pos, live = live,
                                src = "placed" }
                        end)
                        if not okg then skipped = skipped + 1 end
                    end
                end
            end
        end)
        if not ok then skipped = skipped + 1 end
    end
    return recs, skipped, capped
end

-- Shared frame of the drop and box scans: reads `field` of gm as a
-- managed list, applies `cap`, and calls visit(item, recs, skip, over)
-- for each non-nil element inside a pcall (skip() counts one skip,
-- over(n) adds n to capped). Returns recs, skipped, capped; nil when the
-- list count is unreadable.
function items.scan_list(gm, field, cap, visit)
    local list = safe_field(gm, field)
    local cnt = safe_call(list, "get_Count")
    if type(cnt) ~= "number" then return nil end
    local recs, skipped, capped = {}, 0, 0
    if cnt > cap then capped = cnt - cap; cnt = cap end
    local function skip() skipped = skipped + 1 end
    local function over(n) capped = capped + n end
    for i = 0, cnt - 1 do
        local ok = pcall(function()
            local g = safe_call(list, "get_Item", i)
            if g == nil then skipped = skipped + 1 return end
            visit(g, recs, skip, over)
        end)
        if not ok then skipped = skipped + 1 end
    end
    return recs, skipped, capped
end

local function scan_drops(gm)
    return items.scan_list(gm, "<DropItemGimmicks>k__BackingField", K.DROP_CAP,
        function(g, recs, skip)
            if safe_field(g, "<IsDeleted>k__BackingField") == true then return end
            local id = int_value(safe_field(safe_field(g, "MyContext"), "_ItemId"))
            if id == nil then skip() return end
            if not ITEM_WANTED[id] then return end
            local pos, live = gimmick_pos(g)
            if pos == nil then skip() return end
            recs[#recs + 1] = { id = id, pos = pos, live = live, src = "drop" }
        end)
end

local function scan_boxes(gm)
    return items.scan_list(gm, "<TreasureBoxGimmicks>k__BackingField", K.BOX_CAP,
        function(b, recs, skip, over)
            local il = safe_field(b, "ItemList")
            local n = safe_call(il, "get_Count")
            if type(n) ~= "number" then skip() return end
            if n > K.BOX_ITEMS_CAP then
                over(n - K.BOX_ITEMS_CAP)
                n = K.BOX_ITEMS_CAP
            end
            local hit, ids = {}, {}
            for k = 0, n - 1 do
                local id = int_value(safe_field(safe_call(il, "get_Item", k), "ItemId"))
                if id == nil then skip()
                elseif ITEM_WANTED[id] and not hit[id] then
                    hit[id] = true
                    ids[#ids + 1] = id
                end
            end
            if #ids == 0 then return end
            local pos, live = gimmick_pos(b)
            if pos == nil then skip() return end
            -- records at one box share pos/live (read-only; item_markers copies)
            for _, id in ipairs(ids) do      -- one record per wanted id, at the box
                recs[#recs + 1] = { id = id, src = "box", pos = pos, live = live }
            end
        end)
end

-- Wholesale commit per scan. A top-level failure keeps the previous set
-- ONCE; a second consecutive one clears it.
local function commit_scan(which, recs)
    if recs == nil then
        if ITEM_LOC_FAILED[which] then ITEM_LOCS[which] = {} end
        ITEM_LOC_FAILED[which] = true
        return
    end
    ITEM_LOC_FAILED[which] = false
    ITEM_LOCS[which] = recs
end

-- Requirement walk (3c) + held count (3d) + need table (3e) of one round.
local function item_round_needs(now)
    local st0 = ITEM_STATS
    local qm = sdk.get_managed_singleton("app.QuestManager")
    if qm == nil then item_round_failed() return end
    local owner = qm_owner_key(qm)
    if owner == nil then item_round_failed() return end
    proc_index_note_owner(owner)
    if ITEM_STATS ~= st0 then
        -- an owner change just reset the item state: this attempt is
        -- round 1 of the new owner, and waits the interval from now
        ITEM_STATS.rounds = 1
        ITEM_LAST_AT = now
    end
    local list = safe_field(qm, "DistributedQuestProcessors")
    local n = safe_call(list, "get_Count")
    if type(n) ~= "number" then item_round_failed() return end
    ensure_processor_index(list, n)
    local prog = read_quest_id_list("getProgressingQuestIds", "progressing")
    if prog == nil then item_round_failed() return end
    local wanted = {}
    for _, q in ipairs(prog) do
        if not wanted[q] and items.walks_quest(q) then wanted[q] = true end
    end
    if next(wanted) == nil then
        commit_item_needs({})
        ITEM_FAILED_STREAK = 0
        ITEM_STATS.ignored = 0
        return
    end
    local function pass(cur)
        local records = {}
        local skipped = visit_verified_entries(cur, list, wanted,
            function(p, qid, skip, procid)
                local rows = ITEM_COND_CACHE[procid]
                if rows == nil then
                    local sk
                    rows, sk = read_item_conditions(p)
                    if sk == 0 then
                        ITEM_COND_CACHE[procid] = rows
                    else
                        for _ = 1, sk do skip() end
                    end
                end
                for _, r in ipairs(rows) do
                    records[#records + 1] = { qid = qid, id = r.id,
                        num = r.num, op = r.op }
                end
            end,
            -- SPEC 15.3c.3: ProcID first; a processor whose CACHED row
            -- list is empty contributes nothing, so its IsStarted /
            -- ProcessFinished reads are skipped
            function(p, _, skip)
                local procid = int_value(safe_field(p, "ProcID"))
                if procid == nil then skip() return false end
                local rows = ITEM_COND_CACHE[procid]
                if rows ~= nil and #rows == 0 then return false end
                return procid
            end)
        if skipped == nil then return nil end
        return records, skipped
    end
    local records, skipped = with_index_retry(list, n, pass, item_round_failed)
    if records == nil then return end
    local held, ids = {}, {}
    for _, r in ipairs(records) do
        if r.op == "more" or r.op == "morethan" then ids[r.id] = true end
    end
    if next(ids) ~= nil then
        local h, hsk = read_held(ids)
        if h == nil then item_round_failed() return end
        held = h
        skipped = skipped + hsk
    end
    -- v14: quest-related items from the same records, before the need table
    -- a raise here must not fail the need round: keep the previous map
    local okr, rel = pcall(require("Clairvoyance.npcs").related_items, records)
    if not okr then rel = items.related end
    local t, ignored = qnml_core.item_need_table(records, held)
    if type(t) ~= "table" then error("item_need_table: bad result") end
    commit_item_needs(t)
    if type(rel) == "table" then items.related = rel end
    ITEM_FAILED_STREAK = 0
    ITEM_STATS.ignored = ignored or 0
    ITEM_STATS.round_skipped = ITEM_STATS.round_skipped + skipped
end

local function refresh_items_body(mode)
    local gm = nil
    local now = os.clock()
    if now - ITEM_LAST_AT >= K.ROUND_INTERVAL then
        ITEM_LAST_AT = now       -- attempt START: a failed round waits too
        items.in_round = true
        ITEM_STATS.rounds = ITEM_STATS.rounds + 1
        ITEM_STATS.round_skipped, ITEM_STATS.round_capped = 0, 0
        item_round_needs(now)
        -- v14 (Ruling 9): the item menu asks for the need read alone
        if mode == "needs" then
            ITEM_STATS.last_ms = (os.clock() - now) * 1000.0
            return
        end
        -- scans run on the COMMITTED table, whatever this round's outcome
        if next(ITEM_WANTED) ~= nil then
            gm = sdk.get_managed_singleton("app.GimmickManager")
            local pr, psk, pcp = scan_placed(gm)
            commit_scan("placed", pr)
            local br, bsk, bcp = scan_boxes(gm)
            commit_scan("box", br)
            ITEM_STATS.round_skipped = ITEM_STATS.round_skipped + (psk or 0) + (bsk or 0)
            ITEM_STATS.round_capped = (pcp or 0) + (bcp or 0)
        end
        ITEM_STATS.last_ms = (os.clock() - now) * 1000.0
    end
    if mode == "needs" then return end
    if next(ITEM_WANTED) ~= nil then
        gm = gm or sdk.get_managed_singleton("app.GimmickManager")
        local dr, dsk, dcp = scan_drops(gm)
        commit_scan("drop", dr)
        ITEM_STATS.drop_skipped, ITEM_STATS.drop_capped = dsk or 0, dcp or 0
    end
end

function items.refresh(mode)
    items.in_round = false
    local ok, err = pcall(refresh_items_body, mode)
    if not ok then
        -- only an error inside a started round is a failed round
        if items.in_round then item_round_failed() end
        error(err, 0)   -- re-raise so the main file's pcall can log it once
    end
end
end

-- Live + persisted quest name (the a.quest_name logic minus the
-- extracted-title fallback). get_debug_name returns tostring(qid)
-- on failure, never nil; core needs nil.
local function quest_name_live_or_learned(qid)
    local n = get_debug_name(qid)
    if n == tostring(qid) then return PERSISTED_NAMES[qid] end
    return n
end

-- One pass of the debug giver audit: every side quest in the catalog with no
-- giver hint gets one log line listing its cast candidates with their
-- character labels. Returns false while the catalog is absent or empty (the
-- caller tries again later), true once the pass has run. A second return
-- value counts the quests audited.
-- cast_fn(qid) -> {cid, ...}; label_fn(cid) -> string or nil.
function A.giver_audit_step(ids, hints, is_side, cast_fn, label_fn, logfn)
    if ids == nil or #ids == 0 then return false end
    local audited = 0
    for _, qid in ipairs(ids) do
        if is_side(qid) and hints[qid] == nil then
            audited = audited + 1
            local cands = cast_fn(qid) or {}
            local parts = {}
            for _, cid in ipairs(cands) do
                parts[#parts + 1] = string.format("%d(%s)", cid,
                    label_fn(cid) or "?")
            end
            local ok, nm = pcall(quest_name_live_or_learned, qid)
            logfn(string.format("GiverAudit: [%d] %s: %d cands: %s",
                qid, (ok and nm) or EXTRACTED_NAMES[qid] or "?", #cands,
                #parts > 0 and table.concat(parts, ", ") or "-"))
        end
    end
    return true, audited
end

local MARKER_GUID_PREFIX = "51a1c0de-0000-4000-8000-"
function A.marker_guid(lowest_qid)
  return A.guid_parse(MARKER_GUID_PREFIX .. string.format("%012x", lowest_qid))
end
-- v8 (SPEC 15.3j): item markers carry their own UniqId prefix (quest
-- markers keep ...-4000-...), keyed by item id + per-id ordinal, so no
-- item marker shares a UniqId with a quest marker or another item marker
-- in one snapshot. A.map_marker_guid is the ONE place that picks the
-- prefix per marker; add_markers passes every marker through it.
-- Prefixes: quest ...-4000-, item ...-4001-, world ...-4002-, route ...-4003-,
-- pin ...-4004-, focus npc ...-4005-, focus place ...-4006-.
do
  local ITEM_GUID_PREFIX = "51a1c0de-0000-4001-8000-"
  function A.item_marker_guid(id, ord)
    return A.guid_parse(ITEM_GUID_PREFIX .. string.format("%08x%04x",
      id % 0x100000000, ord % 0x10000))
  end
  -- v10 (SPEC 17.4a): world markers (chest/treasure/token/beetle/monster/seller).
  local WORLD_GUID_PREFIX = "51a1c0de-0000-4002-8000-"
  function A.world_marker_guid(ord)
    return A.guid_parse(WORLD_GUID_PREFIX .. string.format("%012x",
      ord % 0x1000000000000))
  end
  local WORLD_MARKER_CATS = { npc_search = true }
  for _, c in ipairs(qnml_core.WORLD_CATS) do WORLD_MARKER_CATS[c] = true end
  -- v14 (SPEC 22.6.6): route stops and hint pins; 32 slots per owner
  local ROUTE_GUID_PREFIX = "51a1c0de-0000-4003-8000-"
  local PIN_GUID_PREFIX = "51a1c0de-0000-4004-8000-"
  local FOCUS_NPC_GUID_PREFIX = "51a1c0de-0000-4005-8000-"
  local FOCUS_PLACE_GUID_PREFIX = "51a1c0de-0000-4006-8000-"
  local OBJECTIVE_GUID_PREFIX = "51a1c0de-0000-4008-8000-"
  function A.map_marker_guid(m)
    local c = m.cat
    if c == "objective" then
      local ordinal = m.objective_ordinal
      if type(ordinal) ~= "number" or math.type(ordinal) ~= "integer"
          or ordinal < 1 or ordinal > 1099511627775 then return nil end
      return A.guid_parse(OBJECTIVE_GUID_PREFIX .. string.format("%012x",
        ordinal))
    end
    if c == "focus_npc" then
      return A.guid_parse(FOCUS_NPC_GUID_PREFIX .. string.format("%012x",
        m.cid % 0x1000000000000))
    end
    if c == "focus_place" then
      if type(m.key) == "string" and m.key:sub(1, 4) == "o:p:" then
        return A.guid_parse("51a1c0de-0000-4007-8000-"
          .. string.format("%012x", m.qid % 0x1000000000000))
      end
      return A.guid_parse(FOCUS_PLACE_GUID_PREFIX .. string.format("%012x",
        m.place % 0x1000000000000))
    end
    if c == "route_stop" then
      return A.guid_parse(ROUTE_GUID_PREFIX .. string.format("%012x",
        (m.cid * 32 + (m.num or m.stop)) % 0x1000000000000))
    end
    if c == "hint_pin" then
      return A.guid_parse(PIN_GUID_PREFIX .. string.format("%012x",
        (m.qid * 32 + m.i) % 0x1000000000000))
    end
    if WORLD_MARKER_CATS[c] then
      return A.world_marker_guid(m.world_ord or 0)
    end
    if c == "quest_item" then return A.item_marker_guid(m.item_id, m.item_ord) end
    return A.marker_guid(m.qids[1])
  end
end

local map_icon_info_t = nil
function A.new_map_icon_info()
  if map_icon_info_t == nil then
    map_icon_info_t = sdk.find_type_definition("app.GuiManager.MapIconInfo")
  end
  local info = map_icon_info_t:create_instance():add_ref()
  info.IsEnable = true
  info.IsNavi = false
  info.IconId = 0
  info.SortNo = 0
  info.Timing = 0
  info.Area = -1       -- app.AIAreaDefinition.None
  info.LocalArea = 0   -- kept at 0 on purpose: -1 (None) is untested in game; spec 6.3
  info.IsDispAllArea = true
  -- Data and WarpParam intentionally never set (spec 7.3).
  return info
end

local unique_id_t = nil
function A.new_unique_id(guid)
  if unique_id_t == nil then
    unique_id_t = sdk.find_type_definition("app.UniqueID")
  end
  local uid = unique_id_t:create_instance():add_ref()
  uid:setup(guid, 0)
  return uid
end

-- Presence in a live quest list proves a cached terminal state no longer
-- holds (e.g. a save reload that keeps the same QuestLogManager instance).
learn_list_fn = function()
    local out = {}
    for _, spec in ipairs({
        { "getAcceptableQuestList", "acceptable" },
        { "getProgressingQuestIds", "progressing" } }) do
        local l = read_quest_id_list(spec[1], spec[2])
        if type(l) == "table" then
            for _, q in ipairs(l) do out[#out + 1] = q end
        end
    end
    return out
end

local function clear_state_for(ids)
  if ids then
    for _, q in ipairs(ids) do QUEST_STATE_CACHE[q] = nil end
  end
  return ids
end

-- SPEC 37.5: singleton fetches are independent so one unavailable manager
-- does not suppress the other state read. Never cache managed objects.
function A.overhead_block_reason()
  local ok_gui, gui = pcall(sdk.get_managed_singleton, "app.GuiManager")
  if ok_gui and safe_call(gui, "isPausedGUI") == true then return "menu" end
  local ok_demo, demo = pcall(sdk.get_managed_singleton, "app.DemoMediator")
  if ok_demo and safe_call(demo, "get_IsPlayingDemo") == true then
    return "cutscene"
  end
  return nil
end

function A.make()
  local a = {}
  local objective_task_state = { owner = nil, focus = nil, journal = nil,
    needs = nil, focus_epoch = 0, journal_generation = 0, need_generation = 0,
    source_generation = 1 }
  local LOC_KINDS = { "placed", "box", "drop" }   -- item_locations order
  a.overhead_block_reason = A.overhead_block_reason
  function a.acceptable_ids()
    return clear_state_for(read_quest_id_list("getAcceptableQuestList", "acceptable"))
  end
  function a.progressing_ids()
    return clear_state_for(read_quest_id_list("getProgressingQuestIds", "progressing"))
  end
  function a.is_side(qid) return is_side_quest(qid) end
  function a.is_unavailable(qid) return quest_state(qid) ~= nil end
  function a.quest_state(qid) return quest_state(qid) end
  function a.catalog_ids() return catalog_ids() end
  function a.giver_hint(qid) return A.GIVER_HINTS[qid] end
  function a.is_generic(cid) return A.GENERIC_NPC_IDS[cid] == true end
  function a.cast_ids(qid) return A.get_runtime_cast_charaids(qid) end
  function a.catalog_pos(qid) return A.get_runtime_quest_position(qid) end
  function a.static_pos(qid) return nil end
  function a.quest_region(qid) return QUEST_REGION[qid] end
  function a.npc_alive(cid) return A.is_npc_alive_and_ready(cid) end
  function a.npc_pos(cid) return A.get_character_world_pos(cid) end
  function a.quest_name(qid)
    -- get_debug_name returns tostring(qid) on failure, never nil;
    -- core needs nil so its "Quest <qid>" fallback and unnamed readout work.
    -- A name learned in an earlier session backs up the live lookup.
    return quest_name_live_or_learned(qid) or EXTRACTED_NAMES[qid]
  end
  function a.seen_quest_name(qid)
    -- SPEC 13.3c: live name, else learned, else the extracted title
    -- ONLY for a qid the player has met (last-seen raw acceptable /
    -- progressing lists), else nil.
    local nm = quest_name_live_or_learned(qid)
    if nm ~= nil then return nm end
    if SEEN_QUEST_IDS[qid] then return EXTRACTED_NAMES[qid] end
    return nil
  end
  function a.refresh_gates() return refresh_gates() end
  function a.gate_qids(qid)
    if GATE_TABLE == nil then return nil end
    return GATE_TABLE[qid]
  end
  function a.gate_stats() return GATE_STATS end
  function a.invalidate_gates()
    GATE_TABLE = nil
    GATE_LAST_AT = -math.huge
    GATE_POPULATING = false
    GATE_ROUND_TRIED = {}
  end
  function a.refresh_tree_gates() return refresh_tree_gates() end
  function a.invalidate_tree_gates() reset_tree_state() end
  function a.tree_gate_qids(qid)
    if TREE_GATE_TABLE == nil then return nil end
    return TREE_GATE_TABLE[qid]
  end
  function a.tree_gate_table() return TREE_GATE_TABLE end
  function a.tree_gate_stats() return TREE_STATS end
  a.refresh_items = items.refresh
  function a.invalidate_items() items.invalidate() end
  function a.item_needs() return ITEM_NEEDS end
  -- v14 (SPEC 22.10.1): { [item_id] = { quest title, ... } }, cached until
  -- the next commit
  function a.item_related(reveal)
    if items.related_titles ~= nil and items.related_reveal ~= (reveal == true) then
      items.related_titles = nil
    end
    if items.related_titles == nil then
      items.related_reveal = reveal == true
      local out, ids = {}, {}
      for id in pairs(items.related or {}) do ids[id] = true end
      for id in pairs(items.static_related or {}) do ids[id] = true end
      for id in pairs(ids) do
        local titles, seen = {}, {}
        -- the live lists name quests with an in-progress need; the static
        -- hints-file lists follow the gate-name rule (SPEC 13.3d); a title
        -- shows once, so two unmet quests read "another quest" once
        for si, src in ipairs({ items.related or {}, items.static_related or {} }) do
          for _, q in ipairs(src[id] or {}) do
            if not seen[q] then
              seen[q] = true
              local t = si == 1 and (a.quest_name(q) or ("Quest " .. tostring(q)))
                or qnml_core.gate_name(q, a, reveal == true)
              if not seen[t] then
                seen[t] = true
                titles[#titles + 1] = t
              end
            end
          end
        end
        out[id] = titles
      end
      items.related_titles = out
    end
    return items.related_titles
  end
  -- v14: { [item_id] = { qid, ... } } from the hints file; nil clears it
  function a.set_item_quests(map)
    items.static_related = type(map) == "table" and map or nil
    items.related_titles = nil
  end
  -- SPEC 32.6.1.2: focused quests (main included) join the objective walk and
  -- the item round; nil or an empty list clears the set
  -- The memo keys on table identity, so a caller passes a new table when the
  -- content changes.
  function a.set_focus_qids(list)
    if list == items.focus_src then return end   -- the same table as last time
    items.focus_src = list
    local set
    if type(list) == "table" then
      for _, q in ipairs(list) do
        if type(q) == "number" then set = set or {}; set[q] = true end
      end
    end
    items.focus_set = set
  end
  function a.focus_set() return items.focus_set end
  -- the next refresh_items round runs at once (Ruling 9)
  function a.reset_item_throttle() ITEM_LAST_AT = -math.huge end
  -- SPEC 22.11.4.1: every side quest's step text, keys the 0-based task index
  function a.quest_steps_text()
    local out = {}
    for _, qid in ipairs(a.catalog_ids() or {}) do
      if a.is_side(qid) then
        local r = a.journal_all(qid)
        if r ~= nil then
          local steps = {}
          for i, st in ipairs(r.steps) do
            steps[tostring(i - 1)] = { base = st.base, detail = st.detail }
          end
          out[qid] = steps
        end
      end
    end
    return out
  end
  function a.item_locations()
    local out = {}
    for _, k in ipairs(LOC_KINDS) do
      for _, r in ipairs(ITEM_LOCS[k]) do out[#out + 1] = r end
    end
    return out
  end
  a.item_name = items.name
  a.item_stats = items.stats
  a.tracked_qid = journal.tracked_qid
  a.journal_now = journal.now
  a.journal_all = journal.all
  a.quest_step = journal.quest_step
  function a.masquerade_door_closed()
    local v = A.read_masquerade_door_closed(
      sdk.get_managed_singleton("app.GimmickManager"))
    if type(v) == "boolean" then A.MASQUERADE_DOOR_LAST = v end
    return A.MASQUERADE_DOOR_LAST
  end
  a.npc_name = journal.npc_name
  a.journal_stats = journal.stats_copy
  a.map_open = journal.map_open
  a.map_cursor = journal.map_cursor
  a.map_jump_apply = journal.map_jump_apply
  a.map_menu_open = journal.menu_open
  a.map_close_menu = journal.close_menu
  a.journal_note_jump = journal.note_jump
  function a.objective_cids(qid)
    local t = OBJECTIVE_TABLE
    return t ~= nil and t.cids[qid] or nil
  end
  function a.objective_issued_cids(qid)
    return qnml_core.objective_issued_cids(OBJECTIVE_TABLE, qid)
  end
  function a.objective_pos(cid) return objective_pos(cid) end
  function a.refresh_objectives() return refresh_objectives() end
  function a.objective_stats()
    OBJECTIVE_STATS.index_builds = PROC_INDEX_BUILDS
    return OBJECTIVE_STATS
  end
  function a.objective_task_snapshot(focus_qids, objective_catalog)
    local function same(x, y)
      if type(x) ~= type(y) then return false end
      if type(x) ~= "table" then return x == y end
      for k, v in pairs(x) do if not same(v, y[k]) then return false end end
      for k in pairs(y) do if x[k] == nil then return false end end
      return true
    end
    local function clone(v)
      if type(v) ~= "table" then return v end
      local out = {}
      for k, x in pairs(v) do out[k] = clone(x) end
      return out
    end
    local function list(value, cap)
      if value == nil then return {}, true, false end
      local ok, rows, n = read_collection_items(value)
      if not ok then return {}, false, false end
      if n > cap then
        local kept = {}
        for i = 1, cap do kept[i] = rows[i] end
        return kept, false, true
      end
      return rows, true, false
    end
    local function same_object(x, y)
      if x == y then return true end
      if x == nil or y == nil then return false end
      local ax, ay
      pcall(function() ax = x:get_address() end)
      pcall(function() ay = y:get_address() end)
      return type(ax) == "number" and ax ~= 0 and ax == ay
    end
    local function position(v)
      local x, y, z = vec_xyz(v)
      if x == nil then return nil end
      return { x = x, y = y, z = z }
    end
    local function place_target(row)
      if type(row) ~= "table" then return nil end
      local t = row.target
      if type(t) == "table" then
        if t.kind == "key_location" and type(t.key) == "number" and t.key > 0 then
          return { place = { kind = "key_location", key = t.key } }
        elseif t.kind == "local_area" and type(t.local_area) == "number" and t.local_area >= 0 then
          return { place = { kind = "local_area", local_area = t.local_area } }
        end
      end
      if type(row.cid) == "number" and row.cid > 0 then return { cid = row.cid } end
      if type(row.key) == "number" and row.key > 0 then
        return { place = { kind = "key_location", key = row.key } }
      end
      if type(row.local_area) == "number" and row.local_area >= 0 then
        return { place = { kind = "local_area", local_area = row.local_area } }
      end
      return nil
    end
    local function live_only_destination(qid)
      local result = { read_status = "unknown", reason = "quest_log_manager_unavailable" }
      local qlm = sdk.get_managed_singleton("app.QuestLogManager")
      if qlm == nil then return result end
      local dict = qlm and safe_field(qlm, "_QuestLogInfoDict") or nil
      local info = dict and safe_call(dict, "get_Item", qid) or nil
      local ti = info and int_value(safe_call(info, "get_CurrentTaskIndex")) or nil
      if ti == nil then ti = int_value(safe_field(info, "<CurrentTaskIndex>k__BackingField")) end
      if ti == nil then result.reason = "current_task_index_unreadable"; return result end
      local ok, task = pcall(function() return qlm:call("getCurrentTask", qid) end)
      if not ok or task == nil then result.reason = "current_task_unreadable"; return result end
      local active_ok, active = pcall(function() return task:call("getActiveDestinations") end)
      if not active_ok or active == nil then
        result.reason = "destination_active_list_unreadable"; return result
      end
      local rows, readable, truncated = list(active, 256)
      if not readable then
        result.reason = truncated and "destination_active_list_truncated"
          or "destination_active_list_unreadable"
        return result
      end
      result.read_status, result.reason, result.task_index = "ok", nil, ti
      if #rows == 0 then return result end
      local dest = rows[1]
      local cid = int_value(safe_call(dest, "get_CharaID"))
      if cid == 0 then cid = nil end
      local target = { cid = cid, pos = position(safe_call(dest, "getDestination")) }
      if cid == nil then
        local key = int_value(safe_call(dest, "get_KeyLocation"))
        local area = int_value(safe_call(dest, "get_LocalArea"))
        if key and key > 0 then target.place = { kind = "key_location", key = key }
        elseif area and area >= 0 then target.place = { kind = "local_area", local_area = area }
        else return result end
      elseif target.pos == nil then
        local x, y, z = objective_pos(cid)
        if x ~= nil then target.pos = { x = x, y = y, z = z } end
      end
      result.live_destination = { task_index = ti, target = target, eligibility = "eligible" }
      return result
    end
    local function native_target(dest, parsed)
      local dest_type = int_value(safe_call(dest, "get_DestType"))
      local cid = int_value(safe_call(dest, "get_CharaID"))
      if cid == 0 then cid = nil end
      local key = int_value(safe_call(dest, "get_KeyLocation"))
      local area = int_value(safe_call(dest, "get_LocalArea"))
      if dest_type ~= parsed.dest_type then return nil end
      local expected = place_target(parsed)
      if expected == nil then return nil end
      local place = nil
      if parsed.key and parsed.key > 0 then place = { kind = "key_location", key = parsed.key }
      elseif parsed.local_area ~= nil and parsed.local_area >= 0 then
        place = { kind = "local_area", local_area = parsed.local_area } end
      if expected.cid ~= nil and cid ~= expected.cid then return nil end
      if place and place.kind == "key_location" then
        if key ~= place.key then return nil end
      elseif place and place.kind == "local_area" and area ~= place.local_area then return nil end
      if expected.cid == nil and place == nil then
        if expected.place.kind == "key_location" and key ~= expected.place.key then return nil end
        if expected.place.kind == "local_area" and area ~= expected.place.local_area then return nil end
        place = expected.place
      end
      return { cid = cid, place = place, pos = position(safe_call(dest, "getDestination")) }
    end
    local function concierge_identity(parsed)
      local cid = type(parsed.cid) == "number" and parsed.cid > 0 and parsed.cid or nil
      local target = parsed.target
      if type(target) == "table" and target.kind == "key_location"
          and type(target.key) == "number" then
        return cid, { kind = "key_location", key = target.key }
      elseif type(target) == "table" and target.kind == "local_area"
          and type(target.local_area) == "number" then
        return cid, { kind = "local_area", local_area = target.local_area }
      elseif type(parsed.key) == "number" and parsed.key > 0 then
        return cid, { kind = "key_location", key = parsed.key }
      elseif type(parsed.local_area) == "number" and parsed.local_area >= 0 then
        return cid, { kind = "local_area", local_area = parsed.local_area }
      end
      return cid, nil
    end
    local function read_quest(qid, entry, catalog_quests)
      local result = { qid = qid, read_status = "unknown", issued_npcs = {},
        source_descriptors = type(entry.sources) == "table" and clone(entry.sources) or {},
        task_destinations = {}, guidance = {}, item_ownership = {} }
      local issued = qnml_core.objective_issued_cids(OBJECTIVE_TABLE, qid)
      for _, cid in ipairs(issued or {}) do
        local x, y, z = objective_pos(cid)
        result.issued_npcs[#result.issued_npcs + 1] = { kind = "npc", task_index = nil,
          target = { cid = cid, pos = x ~= nil and { x = x, y = y, z = z } or nil },
          evidence = { provider = "issued_npc", cid = cid }, eligibility = "eligible" }
      end
      local qlm = sdk.get_managed_singleton("app.QuestLogManager")
      if qlm == nil then result.reason = "quest_log_manager_unavailable"; return result end
      local info = safe_call(safe_field(qlm, "_QuestLogInfoDict"), "get_Item", qid)
      if info == nil then result.reason = "quest_log_info_unavailable"; return result end
      local ti = int_value(safe_call(info, "get_CurrentTaskIndex"))
      if ti == nil then ti = int_value(safe_field(info, "<CurrentTaskIndex>k__BackingField")) end
      if type(ti) ~= "number" or ti < 0 or ti ~= math.floor(ti) then
        result.reason = "current_task_index_unreadable"; return result
      end
      result.task_index = ti
      local parsed_task = type(entry.tasks) == "table" and entry.tasks[ti + 1] or nil
      if type(parsed_task) ~= "table" or parsed_task.index ~= ti then
        result.reason = "current_task_catalog_mismatch"; return result
      end
      local ok_task, task = pcall(function() return qlm:call("getCurrentTask", qid) end)
      if not ok_task or task == nil then result.reason = "current_task_unreadable"; return result end
      local active_ok, active = pcall(function() return task:call("getActiveDestinations") end)
      if not active_ok then result.reason = "destination_active_list_unreadable"; return result end
      local active_rows, active_readable, active_truncated = list(active, 256)
      if not active_readable then
        result.reason = active_truncated and "destination_active_list_truncated"
          or "destination_active_list_unreadable"
        return result
      end
      local source_value = safe_field(task, "_Destinations")
      if source_value == nil then result.reason = "destination_source_list_unreadable"; return result end
      local source, source_readable, source_truncated = list(source_value, 256)
      if not source_readable then
        result.reason = source_truncated and "destination_source_list_truncated"
          or "destination_source_list_unreadable"
        return result
      end
      local source_by_index, active_order = {}, {}
      for i, obj in ipairs(source) do source_by_index[i - 1] = obj end
      for _, obj in ipairs(active_rows) do
        local duplicate = false
        for _, old in ipairs(active_order) do if same_object(old, obj) then duplicate = true break end end
        if not duplicate then active_order[#active_order + 1] = obj end
      end
      if #active_rows == 0 and not active then
        active_order = {}
      end
      local active_source = {}
      for _, obj in ipairs(active_order) do
        local found
        for index = 0, #source - 1 do
          if same_object(obj, source_by_index[index]) then
            if found ~= nil then result.reason = "destination_source_identity_ambiguous"; return result end
            found = index
          end
        end
        if found == nil then result.reason = "destination_object_mismatch"; return result end
        active_source[found] = obj
      end
      local destinations = parsed_task.destinations
      if type(destinations) ~= "table" then result.reason = "task_destination_catalog_unreadable"; return result end
      for index = 0, #source - 1 do
        local obj, parsed = active_source[index], destinations[index + 1]
        if obj ~= nil then
          if type(parsed) ~= "table" or parsed.index ~= index then
            result.reason = "task_destination_catalog_mismatch"; return result
          end
          local target = native_target(obj, parsed)
          if target == nil then result.reason = "task_destination_target_mismatch"; return result end
          if target.cid ~= nil then
            local npc_target = clone(target); npc_target.place = nil
            result.task_destinations[#result.task_destinations + 1] = { kind = "npc", task_index = ti,
              destination_index = index, signal_index = index, target = npc_target,
              evidence = { provider = "task", task_index = ti, destination_index = index }, eligibility = "eligible" }
          end
          if target.place ~= nil then
            local place_target_value = clone(target); place_target_value.cid = nil
            result.task_destinations[#result.task_destinations + 1] = { kind = "place", task_index = ti,
              destination_index = index, signal_index = index, target = place_target_value,
              evidence = { provider = "task", task_index = ti, destination_index = index }, eligibility = "eligible" }
          end
          if target.cid == nil and target.place == nil then
            result.task_destinations[#result.task_destinations + 1] = { kind = "npc", task_index = ti,
              destination_index = index, signal_index = index, target = clone(target),
              evidence = { provider = "task", task_index = ti, destination_index = index }, eligibility = "eligible" }
          end
        end
      end
      result.read_status = "ok"

      local expected = {}
      for _, g in ipairs(entry.guidance or {}) do
        if type(g) == "table" and g.task_index == ti then expected[#expected + 1] = g end
      end
      if #expected > 0 then
        local raw_records = safe_field(info, "_ConciergeList")
        local concierge_records, records_readable = list(raw_records, 256)
        local data_ok, fallback_data = false, nil
        if #expected == 1 and expected[1].index == 0 and raw_records == nil then
          data_ok, fallback_data = pcall(function() return info:call("getCurrentTaskConciergeData") end)
        end
        for _, g in ipairs(expected) do
            local guidance_start = #result.guidance
            local out = { task_index = ti, concierge_index = g.index,
              destination_index = g.destination_index, signals = {}, delivery_refs = {} }
            local record_index_valid = type(g.index) == "number" and g.index >= 0
              and g.index == math.floor(g.index)
            for _, parsed in ipairs(type(g.destinations) == "table" and g.destinations or {}) do
              if type(parsed) == "table" and type(parsed.delivery) == "table"
                  and type(parsed.delivery.refs) == "table" then
                for _, ref in ipairs(parsed.delivery.refs) do
                  out.delivery_refs[#out.delivery_refs + 1] = clone(ref)
                end
              end
            end
            local record = record_index_valid and records_readable
              and concierge_records[g.index + 1] or nil
            if record == nil and record_index_valid and #expected == 1 and g.index == 0
                and raw_records == nil and data_ok then
              record = fallback_data
            end
            if not record_index_valid then
              out.eligibility, out.reason = "unknown", "concierge_record_index_invalid"
            elseif not records_readable and raw_records ~= nil then
              out.eligibility, out.reason = "unknown", "concierge_record_list_unreadable"
            elseif record == nil then
              out.eligibility, out.reason = "unknown", "concierge_record_missing"
            else
              local live_ti = int_value(safe_call(record, "get_TaskIndex"))
              if live_ti == nil then live_ti = int_value(safe_field(record, "_TaskIndex")) end
              local destinations_ok, destinations = pcall(function() return record:call("get_Destinations") end)
              if not destinations_ok or destinations == nil then destinations = safe_field(record, "_Destinations") end
              local live_rows, live_ok, live_truncated = list(destinations, 256)
              if live_ti == nil then
                out.eligibility, out.reason = "unknown", "concierge_task_index_unreadable"
              elseif live_ti ~= ti then
                out.eligibility, out.reason = "ineligible", "concierge_task_mismatch"
              elseif not live_ok then
                out.eligibility, out.reason = "unknown", live_truncated
                  and "concierge_destinations_truncated" or "concierge_list_unreadable"
              elseif #live_rows == 0 then
                out.eligibility, out.reason = "unknown", "concierge_no_current_destination"
              else
                local parsed_rows = type(g.destinations) == "table" and g.destinations or {}
                for index, parsed in ipairs(parsed_rows) do
                local signal_start = #out.signals
                local destination_eligibility, destination_reason = "unknown", "concierge_destination_unreadable"
                local delivery_refs = type(parsed) == "table" and type(parsed.delivery) == "table"
                  and type(parsed.delivery.refs) == "table" and clone(parsed.delivery.refs) or {}
                local native = type(parsed) == "table" and type(parsed.index) == "number"
                  and parsed.index >= 0 and parsed.index == math.floor(parsed.index)
                  and live_rows[parsed.index + 1] or nil
                if type(parsed) ~= "table" then
                  destination_reason = "concierge_catalog_destination_invalid"
                elseif native == nil then
                  destination_reason = "concierge_destination_missing"
                else
                  local status_ok, status = pcall(function() return native:call("evaluate", qid) end)
                  local register_call_ok, register = pcall(function() return native:call("evaluateRegisterCondition", qid) end)
                  local status_num = status_ok and int_value(status) or nil
                  local native_cid = int_value(safe_call(native, "get_CharaID"))
                  if native_cid == 0 then native_cid = nil end
                  local target
                  local native_key = int_value(safe_call(native, "get_KeyLocation"))
                  local native_area = int_value(safe_call(native, "get_LocalArea"))
                  local parsed_cid, parsed_place = concierge_identity(parsed)
                  local place_ok = parsed_place == nil or (parsed_place.kind == "key_location"
                    and native_key == parsed_place.key) or (parsed_place.kind == "local_area"
                    and native_area == parsed_place.local_area)
                  target = { cid = parsed_cid,
                    place = parsed_place, pos = position(safe_call(native, "getDestination")) }
                  if target.pos == nil and target.cid ~= nil then
                    local x, y, z = objective_pos(target.cid)
                    if x ~= nil then target.pos = { x = x, y = y, z = z } end
                  end
                  if parsed_cid ~= native_cid or not place_ok then
                    destination_reason = "concierge_destination_mismatch"
                  elseif not status_ok then
                    destination_reason = "concierge_status_exception"
                  elseif status_num == nil then
                    destination_reason = "concierge_status_unreadable"
                  elseif status_num ~= 0 then
                    local status_names = { [1] = "no_destination", [2] = "time", [3] = "no_navi",
                      [4] = "item_delivery", [5] = "item_delivery_key_in_junk",
                      [6] = "character_unavailable", [7] = "no_knowledge",
                      [8] = "whiteout_break_guide", [9] = "whiteout_cannot_guide",
                      [10] = "whiteout_change_camp", [11] = "field_guide_no_navi" }
                    destination_eligibility = "ineligible"
                    destination_reason = "concierge_status_" .. (status_names[status_num] or tostring(status_num))
                  elseif not register_call_ok then
                    destination_reason = "concierge_register_condition_exception"
                  elseif register ~= true then
                    if register == false then
                      destination_eligibility = "ineligible"
                      destination_reason = "concierge_register_condition_false"
                    else
                      destination_reason = "concierge_register_condition_unreadable"
                    end
                  else
                    destination_eligibility, destination_reason = "eligible", nil
                    if target.cid ~= nil then
                      local npc_target = clone(target); npc_target.place = nil
                      out.signals[#out.signals + 1] = { kind = "npc",
                        task_index = ti, concierge_index = g.index, destination_index = parsed.index,
                        signal_index = parsed.index, target = npc_target,
                        evidence = { provider = "guidance", concierge_index = g.index,
                          destination_index = parsed.index }, eligibility = "eligible" }
                    end
                    if target.place ~= nil then
                      local place_target_value = clone(target); place_target_value.cid = nil
                      out.signals[#out.signals + 1] = { kind = "place",
                        task_index = ti, concierge_index = g.index, destination_index = parsed.index,
                        signal_index = parsed.index, target = place_target_value,
                        evidence = { provider = "guidance", concierge_index = g.index,
                          destination_index = parsed.index }, eligibility = "eligible" }
                    end
                    for _, condition in ipairs(type(parsed.conditions) == "table" and parsed.conditions or {}) do
                      if condition.kind == "item" and condition.enabled and not condition.is_not then
                        result.item_ownership[#result.item_ownership + 1] = {
                          item_id = type(condition.item_id) == "number" and condition.item_id or nil,
                          proof_kind = "condition", eligibility = "unknown",
                          reason = "native_item_condition_leaf_unread", task_index = ti,
                          concierge_index = g.index, destination_index = parsed.index }
                      end
                    end
                    local delivery = parsed.delivery
                    if type(delivery) == "table" and type(delivery.refs) == "table" and #delivery.refs > 0 then
                      local resolved_delivery = clone(delivery)
                      resolved_delivery.groups = {}
                      local native_delivery_ok, native_delivery = pcall(function() return native:call("get_DeliverData") end)
                      resolved_delivery.native_readable = native_delivery_ok and native_delivery ~= nil
                      for _, ref in ipairs(delivery.refs) do
                        local owner = type(ref) == "table" and catalog_quests and catalog_quests[ref.qid] or nil
                        for _, record in ipairs(type(owner) == "table" and owner.deliveries or {}) do
                          if type(record) == "table" and record.key == ref.key then
                            resolved_delivery.groups[#resolved_delivery.groups + 1] = {
                              qid = ref.qid, ref_key = ref.key, delivery = clone(record) }
                          end
                        end
                      end
                      result.item_ownership[#result.item_ownership + 1] = {
                        proof_kind = "delivery", eligibility = "unknown",
                        reason = "delivery_group_item_join_unproven", task_index = ti,
                        concierge_index = g.index, destination_index = parsed.index,
                        delivery = resolved_delivery }
                    end
                  end
                end
                local destination_signals = {}
                for si = signal_start + 1, #out.signals do
                  destination_signals[#destination_signals + 1] = out.signals[si]
                end
                result.guidance[#result.guidance + 1] = { task_index = ti,
                  concierge_index = g.index, destination_index = type(parsed) == "table"
                    and parsed.index or index - 1, eligibility = destination_eligibility,
                  reason = destination_reason, signals = destination_signals,
                  delivery_refs = delivery_refs }
              end
              if #parsed_rows == 0 then out.eligibility, out.reason = "unknown", "concierge_no_signal"
                result.guidance[#result.guidance + 1] = out end
              end
            end
            if #result.guidance == guidance_start then result.guidance[#result.guidance + 1] = out end
        end
      end
      return result
    end
    local qlm = sdk.get_managed_singleton("app.QuestLogManager")
    if qlm ~= objective_task_state.owner then
      objective_task_state.owner = qlm
      objective_task_state.focus, objective_task_state.journal, objective_task_state.needs = nil, nil, nil
      objective_task_state.focus_epoch, objective_task_state.journal_generation,
        objective_task_state.need_generation = 0, 0, 0
    end
    local focus, focus_seen = {}, {}
    for _, qid in ipairs(type(focus_qids) == "table" and focus_qids or {}) do
      if type(qid) == "number" and qid > 0 and qid <= 2147483647
          and qid == math.floor(qid) and not focus_seen[qid] then
        focus_seen[qid] = true; focus[#focus + 1] = qid
      end
    end
    if not same(focus, objective_task_state.focus) then
      objective_task_state.focus_epoch = objective_task_state.focus_epoch + 1
      objective_task_state.focus = clone(focus)
    end
    local normalized = type(objective_catalog) == "table" and objective_catalog.version == 2
      and type(objective_catalog.quests) == "table" and objective_catalog.quests or nil
    local quests, journal_rows, need_rows = {}, {}, {}
    for _, qid in ipairs(focus) do
      local entry = normalized and normalized[qid] or nil
      local row
      if type(entry) == "table" then row = read_quest(qid, entry, normalized)
      else
        local issued = qnml_core.objective_issued_cids(OBJECTIVE_TABLE, qid)
        local issued_npcs = {}
        for _, cid in ipairs(issued or {}) do
          local x, y, z = objective_pos(cid)
          issued_npcs[#issued_npcs + 1] = { kind = "npc", target = {
            cid = cid, pos = x ~= nil and { x = x, y = y, z = z } or nil },
            evidence = { provider = "issued_npc", cid = cid }, eligibility = "eligible" }
        end
        local live = live_only_destination(qid)
        row = { qid = qid, task_index = live.task_index, read_status = live.read_status,
          reason = live.reason, source_descriptors = {}, issued_npcs = issued_npcs,
          task_destinations = {}, guidance = {}, item_ownership = {},
          live_destination = live.live_destination }
      end
      quests[#quests + 1] = row
      local journal_row = clone(row)
      journal_row.item_ownership = {}
      journal_rows[#journal_rows + 1] = journal_row
      need_rows[qid] = { status = (ITEM_NEEDS == nil or not ITEM_STATS.needs_fresh) and "unknown" or "ok",
        current = clone(ITEM_STATS.needs_fresh and ITEM_NEEDS and ITEM_NEEDS[qid] or {}),
        ownership = clone(row.item_ownership) }
    end
    if not same(journal_rows, objective_task_state.journal) then
      objective_task_state.journal_generation = objective_task_state.journal_generation + 1
      objective_task_state.journal = clone(journal_rows)
    end
    if not same(need_rows, objective_task_state.needs) then
      objective_task_state.need_generation = objective_task_state.need_generation + 1
      objective_task_state.needs = clone(need_rows)
    end
    return { catalog_version = normalized and 2 or 0,
      focus_epoch = objective_task_state.focus_epoch,
      journal_generation = objective_task_state.journal_generation,
      need_generation = objective_task_state.need_generation, quests = quests }
  end
  function a.objective_item_source_snapshots(objective_catalog, task_snapshot)
    local function copy(value)
      if type(value) ~= "table" then return value end
      local out = {}
      for k, v in pairs(value) do out[k] = copy(v) end
      return out
    end
    local generation = type(task_snapshot) == "table" and task_snapshot.need_generation
      or objective_task_state.need_generation
    generation = type(generation) == "number" and math.max(1, generation) or objective_task_state.source_generation
    local version = type(objective_catalog) == "table" and objective_catalog.version or nil
    local descriptors, signals, deliveries = {}, {}, {}
    local catalog = type(objective_catalog) == "table" and objective_catalog.version == 2
      and objective_catalog.quests or nil
    if type(catalog) == "table" then
      for qid, quest in pairs(catalog) do
        for _, source in ipairs(type(quest) == "table" and quest.sources or {}) do
          descriptors[#descriptors + 1] = { qid = qid, source = source }
        end
      end
    end
    for _, quest in ipairs(type(task_snapshot) == "table" and task_snapshot.quests or {}) do
      for _, guide in ipairs(type(quest) == "table" and quest.guidance or {}) do
        for _, signal in ipairs(type(guide) == "table" and guide.signals or {}) do
          signals[#signals + 1] = { qid = quest.qid, task_index = signal.task_index,
            concierge_index = signal.concierge_index, destination_index = signal.destination_index,
            target = signal.target, evidence = signal.evidence, eligibility = signal.eligibility }
        end
      end
      for _, owner in ipairs(type(quest) == "table" and quest.item_ownership or {}) do
        if type(owner) == "table" and owner.delivery ~= nil then
          deliveries[#deliveries + 1] = { qid = quest.qid, task_index = owner.task_index,
            concierge_index = owner.concierge_index, destination_index = owner.destination_index,
            delivery = owner.delivery, eligibility = owner.eligibility }
        end
      end
    end
    local providers = {}
    for _, name in ipairs({ "placed", "chest", "loot" }) do
      providers[#providers + 1] = { provider = name, generation = generation,
        status = "unknown", reason = "objective_source_scan_not_performed", candidates = {},
        catalog_version = version, source_descriptors = copy(descriptors),
        signal_evidence = copy(signals), guidance_delivery_refs = copy(deliveries) }
    end
    return providers
  end
  function a.reset_session_caches()
    local qlm = sdk.get_managed_singleton("app.QuestLogManager")
    if qlm ~= QUEST_SESSION_OWNER then
      QUEST_SESSION_OWNER = qlm
      reset_runtime_caches()
      objective_task_state.owner = qlm
      objective_task_state.focus, objective_task_state.journal, objective_task_state.needs = nil, nil, nil
      objective_task_state.focus_epoch, objective_task_state.journal_generation,
        objective_task_state.need_generation = 0, 0, 0
      return true
    end
    return false
  end
  return a
end

-- EXPORT BLOCK — required. Everything is declared `local`; each name the main
-- file or A.make() reads as `A.x` is explicitly exported here.
A.GIVER_HINTS = GIVER_HINTS
A.GENERIC_NPC_IDS = GENERIC_NPC_IDS
A.QUEST_REGION = QUEST_REGION
A.ITEM_NAMES_BY_ICON = ITEM_NAMES_BY_ICON
A.get_runtime_cast_charaids = get_runtime_cast_charaids
A.get_runtime_quest_position = get_runtime_quest_position
A.is_npc_alive_and_ready = is_npc_alive_and_ready
A.get_character_world_pos = get_character_world_pos
A.npc_live_pos = npc_live_pos
A.probe_lookup = probe_lookup
A.debug_probe_holder = debug_probe_holder
A.guid_parse = guid_parse
A.get_icon_pool = get_icon_pool
A.argb_to_abgr = argb_to_abgr
A.int_value_offset = int_value_offset
A.uint_value_offset = uint_value_offset
A.set_debug = set_debug
A.debug_probe = debug_probe
A.rebuild_npc_pos_cache = rebuild_npc_pos_cache
A.catalog_ids = catalog_ids
A.quest_state = quest_state
A.quest_log_is_end = quest_log_is_end
A.catalog_stats = catalog_stats
A.save_learned_names = save_learned_names
A.learn_names = learn_names
A.build_catalog_index = build_catalog_index
A.refresh_objectives = refresh_objectives
A.refresh_gates = refresh_gates
A.refresh_tree_gates = refresh_tree_gates
A.refresh_items = items.refresh

return A
