local A = {}
local qnml_core = require("Clairvoyance.core")
A.objective_need_builder = require("Clairvoyance.objective_needs")
A.access = require("Clairvoyance.access")

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
          native_refs[#native_refs + 1] = { ref = widget, pos = info.Pos, pool = pool }
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
items.observed_task_indices = {}
items.task_observation_generation = 0
items.task_observation_versions = {}
items.access = { current = {}, last_known = {}, at = {} }

function items.reset_access()
  items.access = { current = {}, last_known = {}, at = {} }
end

-- Count observed changes to the live quest-log task, including a task that
-- moves away and later returns to the same zero-based index.
function items.observe_task_index(qid, task_index)
    local previous = items.observed_task_indices[qid]
    local changed = false
    if task_index == nil then
        if previous ~= false then
            items.task_observation_generation = items.task_observation_generation + 1
            changed = true
        end
        items.observed_task_indices[qid] = false
    elseif previous ~= nil and previous ~= task_index then
        items.task_observation_generation = items.task_observation_generation + 1
        changed = true
        items.observed_task_indices[qid] = task_index
    else
        items.observed_task_indices[qid] = task_index
    end
    if changed then
        items.task_observation_versions[qid]
            = (items.task_observation_versions[qid] or 0) + 1
    end
    return items.task_observation_generation
end

function items.reset_task_observations()
    for qid in pairs(items.observed_task_indices) do
        items.task_observation_versions[qid]
            = (items.task_observation_versions[qid] or 0) + 1
    end
    items.observed_task_indices = {}
    items.task_observation_generation = items.task_observation_generation + 1
end

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
items.objective_cond_cache = {}  -- procid -> complete expression rows (including empty)
local ITEM_LOCS = items.empty_locs()
local ITEM_LOC_FAILED = items.empty_loc_failed()   -- last top-level read failed
local ITEM_NAME_CACHE = {}       -- item id -> name (readable icons only)
local ITEM_FAILED_STREAK = 0
local ITEM_STATS = items.new_stats()
local ITEM_LAST_AT = -math.huge
items.objective_group_state = { status = "unknown", complete = false,
    generation = 0, task_generation = items.task_observation_generation,
    groups = {}, records = {}, held = {}, held_carried = {}, task_index = {}, task_versions = {} }
items.objective_checklist_held_state = nil
items.objective_loot_state = { status = "unknown", complete = false,
    generation = 0, at = -math.huge, candidates = {} }

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
    items.objective_group_state = { status = "unknown", complete = false,
        generation = items.objective_group_state.generation + 1,
        groups = {}, records = {}, held = {}, held_carried = {}, task_index = {}, task_versions = {} }
    items.objective_loot_state = { status = "unknown", complete = false,
        generation = items.objective_loot_state.generation + 1,
        at = -math.huge, candidates = {} }
    items.objective_checklist_held_state = nil
    items.related, items.related_titles = nil, nil
    ITEM_WANTED = {}
    items.clear_locs()
    ITEM_FAILED_STREAK = 0
    ITEM_LAST_AT = -math.huge
    ITEM_STATS.last_ms = 0.0
end

local function reset_item_state()
    items.invalidate()
    items.reset_access()
    ITEM_COND_CACHE = {}
    items.objective_cond_cache = {}
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

-- Build the one shared index of QuestLogResource objects for this live
-- QuestLogManager/catalog pair. An unreadable catalog invalidates the old
-- index so callers cannot accidentally reuse native objects from a prior
-- catalog state.
function journal.catalog_index(qlm)
    if qlm == nil then
        journal.cat_index, journal.cat_key, journal.all_by = nil, nil, {}
        return nil
    end
    local ok, cat = pcall(function() return qlm:get_field("_Catalog") end)
    if not ok or cat == nil then
        journal.cat_index, journal.cat_key, journal.all_by = nil, nil, {}
        return nil
    end
    local key_ok, key = pcall(function()
        local address = qlm:get_address()
        local count = int_value(cat:call("getCount"))
        if address == nil or count == nil then return nil end
        return tostring(address) .. ":" .. tostring(count)
    end)
    if not key_ok or key == nil then
        journal.cat_index, journal.cat_key, journal.all_by = nil, nil, {}
        return nil
    end
    if key ~= journal.cat_key or journal.cat_index == nil then
        local values_ok, values = pcall(function() return cat:call("getValues") end)
        local rows_ok, rows = pcall(function() return items.elements(values) end)
        if not values_ok or not rows_ok or type(rows) ~= "table" then
            journal.cat_index, journal.cat_key, journal.all_by = nil, nil, {}
            return nil
        end
        local idx = {}
        for _, res in ipairs(rows) do
            local id = int_value(safe_call(res, "get_QuestId"))
            if id ~= nil then idx[id] = res end
        end
        journal.cat_index = idx
        journal.cat_key = key
        journal.all_by = {}
    end
    return journal.cat_index
end

function journal.catalog_resource(qlm, qid)
    local index = journal.catalog_index(qlm)
    return index ~= nil and index[qid] or nil
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
        local index = journal.catalog_index(qlm)
        if index == nil then return nil end
        -- The catalog text cannot change while the (address, count) key holds.
        local hit = journal.all_by[qid]
        if hit ~= nil then return hit end
        local res = index[qid]
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
    local r1, r2, r3, r4 = pass(ensure_processor_index(list, n))
    if r1 == nil then
        proc_index_drop()
        r1, r2, r3, r4 = pass(ensure_processor_index(list, n))
        if r1 == nil then
            proc_index_drop()
            on_fail()
            return nil
        end
    end
    return r1, r2, r3, r4
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
    ACCESS_SLOT_CAP = 8192,
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
    local rows, skipped, objective_rows = {}, 0, {}
    local objective_complete = true
    local cls = safe_field(p, "ConditionLists")
    if cls == nil then return rows, 1, nil, false end
    local outer = safe_call(cls, "get_Count")
    if type(outer) ~= "number" then return rows, 1, nil, false end
    if outer < 0 or outer ~= math.floor(outer) or outer > 16 then
        objective_complete = false
    end
    if outer > 16 then outer = 16 end
    for a2 = 0, outer - 1 do
        local inner = safe_call(cls, "get_Item", a2)
        local m = inner ~= nil and safe_call(inner, "get_Count") or nil
        if type(m) ~= "number" then
            skipped = skipped + 1
            objective_complete = false
        else
            if m < 0 or m ~= math.floor(m) or m > 16 then objective_complete = false end
            if m > 16 then m = 16 end
            for b = 0, m - 1 do
                local c = safe_call(inner, "get_Item", b)
                if c == nil then
                    skipped = skipped + 1
                    objective_complete = false
                else
                    local tn = nil
                    local ok_type = pcall(function()
                        tn = c:get_type_definition():get_full_name()
                    end)
                    if not ok_type or tn == nil then
                        skipped = skipped + 1
                        objective_complete = false
                    elseif tn == K.COND_HAS_ITEM or tn == K.COND_DELIVER then
                        local before = #rows
                        local missed = tn == K.COND_HAS_ITEM
                            and items.read_has_item_rows(c, rows)
                            or items.read_deliver_rows(c, rows)
                        skipped = skipped + missed
                        if missed > 0 then objective_complete = false
                        elseif #rows > before then
                            local options = {}
                            for i = before + 1, #rows do
                                local row = rows[i]
                                if row.op ~= "more" and row.op ~= "morethan" then
                                    objective_complete = false
                                else
                                    options[#options + 1] = { item_id = row.id,
                                        required = row.num, op = row.op }
                                end
                            end
                            if #options > 0 then
                                objective_rows[#objective_rows + 1] = {
                                    list_index = a2, condition_index = b,
                                    options = options }
                            end
                        end
                    end
                end
            end
        end
    end
    if skipped > 0 then objective_complete = false end
    return rows, skipped, objective_rows, objective_complete
end

-- SPEC 15.3d: owned count over getStorageDict's owner lists (player,
-- pawns and the storage box). Returns held
-- {[id] = n} for the wanted ids plus a skipped count, or nil when the
-- manager, the dictionary or its _entries is unreadable (failed round).
function items.read_held(ids)
    local im = sdk.get_managed_singleton("app.ItemManager")
    if im == nil then return nil end
    local dict = safe_call(im, "getStorageDict")
    if dict == nil then return nil end
    local en = safe_field(dict, "_entries")
    local entries = items.elements(en)
    if entries == nil then return nil end
    local held, carried, skipped, complete = {}, {}, 0, true
    for i = 1, #entries do
        local ok = pcall(function()
            local e = entries[i]
            local list = safe_field(e, "value")
            if list == nil then return end          -- free slot: uncounted
            local key = int_value(safe_field(e, "key"))
            if key == nil then skipped = skipped + 1; complete = false; return end
            local cnt = safe_call(list, "get_Count")
            if type(cnt) ~= "number" or cnt < 0 or cnt ~= math.floor(cnt) then
                skipped = skipped + 1; complete = false; return
            end
            if cnt > K.HELD_OWNER_CAP then
                complete = false
                cnt = K.HELD_OWNER_CAP
            end
            for k = 0, cnt - 1 do
                local okd = pcall(function()
                    local sd = safe_call(list, "get_Item", k)
                    local id = int_value(safe_field(sd, "_ItemId"))
                    local num = int_value(safe_field(sd, "_Num"))
                    if id == nil or num == nil then
                        skipped = skipped + 1
                        complete = false
                        return
                    end
                    if ids[id] then
                        held[id] = (held[id] or 0) + num
                        if key ~= 65535 then carried[id] = (carried[id] or 0) + num end
                    end
                end)
                if not okd then skipped = skipped + 1; complete = false end
            end
        end)
        if not ok then skipped = skipped + 1; complete = false end
    end
    return held, skipped, complete, carried
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
    items.objective_group_state = { status = "unknown", complete = false,
        generation = items.objective_group_state.generation + 1,
        groups = {}, records = {}, held = {}, held_carried = {}, task_index = {}, task_versions = {} }
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

-- Runtime loot is joined only to focused current need options. The exact
-- runtime list is bounded, cached for half a second, and replaced atomically.
function items.objective_loot_observations(wanted, generation)
    local state = items.objective_loot_state
    local ids, key = {}, ""
    if type(wanted) ~= "table" or type(generation) ~= "number" then
        state = { provider = "loot", status = "unknown", complete = false,
            generation = generation, at = os.clock(), candidates = {},
            reason = "current_need_snapshot_unavailable" }
        items.objective_loot_state = state
        return state
    end
    for id, needed in pairs(wanted) do
        if needed == true and type(id) == "number" and id > 0
            and id == math.floor(id) then ids[#ids + 1] = id end
    end
    table.sort(ids)
    local key_parts = {}
    for i, id in ipairs(ids) do key_parts[i] = tostring(id) end
    key = table.concat(key_parts, ",")
    local now = os.clock()
    if state.generation == generation and state.wanted_key == key
        and now - state.at < 0.5 then
        return state
    end
    local result = { provider = "loot", status = "unknown", complete = false,
        generation = generation, at = now, wanted_key = key, candidates = {},
        reason = "loot_scan_unavailable" }
    if #ids == 0 then
        result.status, result.complete, result.reason = "ok", true, nil
        items.objective_loot_state = result
        return result
    end
    local gm = sdk.get_managed_singleton("app.GimmickManager")
    local list = gm ~= nil and safe_field(gm, "<DropItemGimmicks>k__BackingField") or nil
    local count = safe_call(list, "get_Count")
    if type(count) ~= "number" or count < 0 or count ~= math.floor(count) then
        result.reason = "loot_rows_unreadable"
    elseif count > 64 then
        result.reason = "loot_rows_truncated"
    else
        local by_id, candidates, seen_uid = {}, {}, {}
        for _, id in ipairs(ids) do by_id[id] = true end
        local complete, reason = true, nil
        for i = 0, count - 1 do
            local drop = safe_call(list, "get_Item", i)
            if drop == nil then complete, reason = false, "loot_row_unreadable" break end
            local unique_id = safe_call(drop, "get_UniqId")
            local uid = safe_call(unique_id, "ToString()")
            local uid_a, uid_b, uid_c, uid_d, uid_e
            if type(uid) == "string" then
                uid_a, uid_b, uid_c, uid_d, uid_e = uid:match(
                    "^(%x+)%-(%x+)%-(%x+)%-(%x+)%-(%x+)_[0-9]+$")
                if uid_a == nil then
                    uid_a, uid_b, uid_c, uid_d, uid_e = uid:match(
                        "^(%x+)%-(%x+)%-(%x+)%-(%x+)%-(%x+)$")
                end
            end
            if uid_a == nil or #uid_a ~= 8 or #uid_b ~= 4 or #uid_c ~= 4
                or #uid_d ~= 4 or #uid_e ~= 12 then
                complete, reason = false, "loot_identity_unreadable" break
            end
            uid = uid:lower()
            if seen_uid[uid] then
                complete, reason = false, "loot_identity_duplicated" break
            end
            seen_uid[uid] = true
            local context = safe_field(drop, "MyContext")
            local id = int_value(safe_field(context, "_ItemId"))
            if type(id) ~= "number" or id <= 0 or id ~= math.floor(id) then
                complete, reason = false, "loot_item_id_unreadable" break
            end
            if by_id[id] then
                local deleted = safe_field(drop, "<IsDeleted>k__BackingField")
                if type(deleted) ~= "boolean" then
                    complete, reason = false, "loot_deletion_state_unreadable" break
                elseif deleted == false then
                    local amount = int_value(safe_field(context, "_Num"))
                    local pos = gimmick_pos(drop)
                    if type(amount) ~= "number" or amount <= 0 or amount ~= math.floor(amount) then
                        complete, reason = false, "loot_count_unreadable" break
                    elseif pos == nil then
                        complete, reason = false, "loot_position_unreadable" break
                    else
                        local source_id = { "source", "loot", uid }
                        candidates[#candidates + 1] = {
                            source_id = source_id,
                            provider = "loot", target = { kind = "loot", uid = uid, pos = pos },
                            outputs = { { item_id = id, count = amount } },
                            capacity_pool_id = { "capacity", "loot", uid },
                            capacity_kind = "finite", available_acquisitions = 1,
                            certainty = "guaranteed", eligibility = "eligible",
                            generation = generation,
                            evidence = { uid = uid, item_id = id, count = amount,
                                deleted = false },
                        }
                    end
                end
            end
        end
        if complete then
            result.status, result.complete, result.reason = "ok", true, nil
            result.candidates = candidates
        else
            result.reason = reason
        end
    end
    items.objective_loot_state = result
    return result
end

-- SPEC 40.22: one bounded fingerprint scan for all requested access gates.
-- Every requested result is unknown if either managed collection is partial
-- or the managed-object cap is exceeded.
function A.read_world_access_gates(gm, requested)
    local selected = A.access.requested_gate_ids(A.access.registry, requested)
    local out = {}
    if selected == nil then return out, false end
    if #selected == 0 then return out, true end
    local gates, by_bucket = {}, {}
    for _, id in ipairs(selected) do
        out[id] = { status = "unknown" }
        for _, gate in ipairs(A.access.registry.gates) do
            if gate.id == id then
                gates[#gates + 1] = gate
                by_bucket[gate.fingerprint.bucket_id] = by_bucket[gate.fingerprint.bucket_id] or {}
                by_bucket[gate.fingerprint.bucket_id][#by_bucket[gate.fingerprint.bucket_id] + 1] = gate
                break
            end
        end
    end
    if gm == nil then return out, false end
    local function bounded_entries(value)
        if value == nil then return nil end
        local expected = safe_call(value, "get_Count")
        local used = int_value(safe_field(value, "_count"))
        local free = int_value(safe_field(value, "_freeCount"))
        if type(expected) ~= "number" or expected < 0 or expected ~= math.floor(expected)
            or type(used) ~= "number" or used < 0 or used ~= math.floor(used)
            or type(free) ~= "number" or free < 0 or free ~= math.floor(free)
            or expected > K.MANAGED_CAP or used > K.ACCESS_SLOT_CAP
            or expected > used or expected + free ~= used then
            return nil
        end
        local array = safe_field(value, "_entries")
        local raw = A.read_elements(array, used)
        if raw == nil then return nil end
        local entries, occupied = {}, 0
        for index = 1, used do
            local entry = raw[index]
            if entry == nil then return nil end
            local next_index = safe_field(entry, "Next")
            if next_index == nil then next_index = safe_field(entry, "next") end
            if type(next_index) ~= "number" then return nil end
            if next_index >= -1 then
                occupied = occupied + 1
                entries[#entries + 1] = entry
            end
        end
        if occupied ~= expected then return nil end
        return entries
    end
    local complete = true
    local ok, results = pcall(function()
        local dict = safe_field(gm, "<ManagedGimmicksByIDs>k__BackingField")
        local outer = bounded_entries(dict)
        if outer == nil then error("access outer collection incomplete") end
        local matches, bad, observations, seen = {}, {}, {}, 0
        for _, gate in ipairs(gates) do matches[gate.id] = 0 end
        for _, outer_entry in ipairs(outer) do
            local bucket_id = int_value(safe_field(outer_entry, "key"))
            local hs = safe_field(outer_entry, "value")
            if type(bucket_id) ~= "number" or hs == nil then
                error("access outer entry incomplete")
            end
            local bucket_gates = by_bucket[bucket_id]
            local inner = bounded_entries(hs)
            if inner == nil then error("access inner collection incomplete") end
            for _, inner_entry in ipairs(inner) do
                local g = safe_field(inner_entry, "Value")
                if g == nil then g = safe_field(inner_entry, "value") end
                if g == nil then error("access inner entry incomplete") end
                seen = seen + 1
                if seen > K.MANAGED_CAP then error("access object cap exceeded") end
                if bucket_gates ~= nil then
                    local inspected, value = pcall(function()
                            local gt = g:get_type_definition()
                            local type_name = gt and gt:get_full_name() or nil
                            if type(type_name) ~= "string" then error("door type unreadable") end
                            local possible
                            for _, gate in ipairs(bucket_gates) do
                                if gate.fingerprint.type_name == type_name then possible = true; break end
                            end
                            if not possible then return nil end
                            local go = safe_call(g, "get_GameObject")
                            if go == nil then error("door game object unreadable") end
                            local name = safe_call(go, "get_Name")
                            if type(name) ~= "string" then error("door name unreadable") end
                            local tr = safe_call(go, "get_Transform")
                            local x, y, z = vec_xyz(safe_call(tr, "get_UniversalPosition"))
                            if x == nil then error("door position unreadable") end
                            for _, gate in ipairs(bucket_gates) do
                                local fp = gate.fingerprint
                                if fp.type_name == type_name and fp.game_object_name == name then
                                    local dx, dy, dz = x - fp.position.x, y - fp.position.y,
                                        z - fp.position.z
                                    if dx * dx + dy * dy + dz * dz <= fp.tolerance * fp.tolerance then
                                        local rok, leaves, count = read_collection_items(
                                            safe_field(g, "CompDoorList"))
                                        if not rok or count ~= fp.leaf_count then
                                            bad[gate.id] = true
                                        else
                                            local closed, locked = safe_field(leaves[1], "IsClose"),
                                                safe_field(leaves[1], "IsLock")
                                            if type(closed) ~= "boolean" or type(locked) ~= "boolean" then
                                                bad[gate.id] = true
                                            else
                                                matches[gate.id] = matches[gate.id] + 1
                                                observations[gate.id] = { status = "known",
                                                    values = { closed = closed, locked = locked } }
                                            end
                                        end
                                    end
                                end
                            end
                        return true
                    end)
                    if not inspected then error(value) end
                end
            end
        end
        for _, gate in ipairs(gates) do
            if matches[gate.id] ~= 1 or bad[gate.id] then
                observations[gate.id] = { status = "unknown" }
            end
        end
        return observations
    end)
    if not ok then
        complete = false
        return out, complete
    end
    return results, complete
end

function items.refresh_access(gm, requested)
    local selected = A.access.requested_gate_ids(A.access.registry, requested)
    if selected == nil or #selected == 0 then return {} end
    local now, stale = os.clock(), {}
    for _, id in ipairs(selected) do
        if items.access.at[id] == nil or now - items.access.at[id] >= K.ROUND_INTERVAL then
            stale[#stale + 1] = id
        end
    end
    if #stale > 0 then
        gm = gm or sdk.get_managed_singleton("app.GimmickManager")
        local current, complete = A.read_world_access_gates(gm, stale)
        for _, id in ipairs(stale) do
            local observation = current[id] or { status = "unknown" }
            items.access.current[id], items.access.at[id] = observation, now
            if complete and observation.status == "known" then
                items.access.last_known[id] = observation
            end
        end
    end
    local out = {}
    for _, id in ipairs(selected) do out[id] = items.access.current[id] end
    return out
end

function items.access_decision(target, gm, current)
    local binding, match_reason = A.access.match_binding(A.access.registry, target)
    if match_reason == "ambiguous" then
        return false, { target_kind = target and target.target_kind or "unknown",
            current_status = "unknown", used_last_known = false, allowed = false,
            reason = "ambiguous_binding" }
    end
    if binding == nil then return true end
    local observation = type(current) == "table" and current[binding.gate_id]
      or items.refresh_access(gm, { binding.gate_id })[binding.gate_id]
    local allowed, source = A.access.evaluate(binding, observation,
        items.access.last_known[binding.gate_id])
    return allowed, { gate_id = binding.gate_id, target_kind = binding.target_kind,
        current_status = type(observation) == "table" and observation.status or "unknown",
        used_last_known = source == "last_known", allowed = allowed,
        reason = source == "unknown" and (allowed and "unknown_allowed" or "unknown_denied")
          or (allowed and "predicate_matched" or "predicate_not_matched") }
end

function items.filter_access_targets(targets, gm)
    local list, requested_set, requested = type(targets) == "table" and targets or {}, {}, {}
    for _, target in ipairs(list) do
        local binding = A.access.match_binding(A.access.registry, target)
        if binding ~= nil and not requested_set[binding.gate_id] then
            requested_set[binding.gate_id] = true
            requested[#requested + 1] = binding.gate_id
        end
    end
    local current = items.refresh_access(gm, requested)
    local out, decisions = {}, {}
    for _, target in ipairs(list) do
        local allowed, decision = items.access_decision(target, gm, current)
        if allowed then out[#out + 1] = target end
        if decision ~= nil then decisions[#decisions + 1] = decision end
    end
    return out, decisions
end

function items.filter_placed_provider_snapshot(provider, gm)
    if type(provider) ~= "table" or provider.provider ~= "placed"
        or provider.status ~= "ok" then return provider end
    local copy = {}
    for key, value in pairs(provider) do copy[key] = value end
    local targets, candidate_targets = {}, {}
    for index, candidate in ipairs(provider.candidates or {}) do
        candidate_targets[index] = {}
        for _, output in ipairs(candidate.outputs or {}) do
            local target = { target_kind = "placed_item",
                type_name = "app.Gm82_000", item_id = output.item_id,
                position = candidate.target and candidate.target.pos or nil }
            targets[#targets + 1] = target
            candidate_targets[index][#candidate_targets[index] + 1] = target
        end
    end
    local filtered = items.filter_access_targets(targets, gm)
    local allowed_targets = {}
    for _, target in ipairs(filtered) do allowed_targets[target] = true end
    local candidates = {}
    for index, candidate in ipairs(provider.candidates or {}) do
        local allowed = true
        for _, target in ipairs(candidate_targets[index]) do
            if not allowed_targets[target] then allowed = false; break end
        end
        if allowed then candidates[#candidates + 1] = candidate end
    end
    copy.candidates = candidates
    return copy
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
                                src = "placed", type_name = tn }
                        end)
                        if not okg then skipped = skipped + 1 end
                    end
                end
            end
        end)
        if not ok then skipped = skipped + 1 end
    end
    local targets, target_by_record = {}, {}
    for _, rec in ipairs(recs) do
        local target = { target_kind = "placed_item", type_name = rec.type_name,
            item_id = rec.id, position = rec.pos }
        targets[#targets + 1] = target
        target_by_record[rec] = target
    end
    local filtered = items.filter_access_targets(targets, gm)
    local allowed_targets = {}
    for _, target in ipairs(filtered) do allowed_targets[target] = true end
    local kept = {}
    for _, rec in ipairs(recs) do
        if allowed_targets[target_by_record[rec]] then
            rec.type_name = nil
            kept[#kept + 1] = rec
        end
    end
    return kept, skipped, capped
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
        items.objective_group_state = { status = "ok", complete = true,
            generation = ITEM_STATS.rounds,
            task_generation = items.task_observation_generation,
            groups = {}, records = {}, held = {}, held_carried = {}, task_index = {}, task_versions = {} }
        ITEM_FAILED_STREAK = 0
        ITEM_STATS.ignored = 0
        return
    end
    local function pass(cur)
        local records, objective_records = {}, {}
        local pending_reads = {}
        local objective_complete = true
        local skipped = visit_verified_entries(cur, list, wanted,
            function(p, qid, skip, procid)
                local rows = ITEM_COND_CACHE[procid]
                local grouped = items.objective_cond_cache[procid]
                if rows == nil then
                    local sk, complete
                    local pending = pending_reads[procid]
                    if pending ~= nil then
                        rows, sk, grouped, complete = pending.rows, pending.skipped,
                            pending.groups, pending.complete
                    else
                        rows, sk, grouped, complete = read_item_conditions(p)
                    end
                    if sk == 0 then
                        ITEM_COND_CACHE[procid] = rows
                        items.objective_cond_cache[procid] = complete and grouped or false
                    else
                        for _ = 1, sk do skip() end
                        objective_complete = false
                    end
                end
                for _, r in ipairs(rows) do
                    records[#records + 1] = { qid = qid, id = r.id,
                        num = r.num, op = r.op }
                end
                if grouped == false or grouped == nil then objective_complete = false
                else
                    for _, group in ipairs(grouped) do
                        objective_records[#objective_records + 1] = {
                            qid = qid, processor_id = procid,
                            list_index = group.list_index,
                            condition_index = group.condition_index,
                            -- A progressing quest does not prove this processor
                            -- belongs to its current task. Keep the expression
                            -- unrouted until an exact structured join exists.
                            complete = true, current_work = false,
                            options = group.options }
                    end
                end
            end,
            -- ProcID first. Read static condition data once so a complete
            -- empty legacy cache can still be skipped; publish no groups
            -- until visit_verified_entries proves started and unfinished.
            function(p, qid, skip)
                local procid = int_value(safe_field(p, "ProcID"))
                if procid == nil then skip() return false end
                local grouped = items.objective_cond_cache[procid]
                if ITEM_COND_CACHE[procid] == nil then
                    local rows, missed, objective_rows, complete = read_item_conditions(p)
                    pending_reads[procid] = { rows = rows, skipped = missed,
                        groups = objective_rows, complete = complete }
                    if missed == 0 then
                        ITEM_COND_CACHE[procid] = rows
                        items.objective_cond_cache[procid] = complete and objective_rows or false
                        pending_reads[procid] = nil
                        grouped = items.objective_cond_cache[procid]
                    end
                end
                if grouped ~= nil and grouped ~= false and #grouped == 0 then return false end
                return procid
            end)
        if skipped == nil then return nil end
        return records, skipped, objective_records, objective_complete
    end
    local records, skipped, objective_records, objective_complete =
        with_index_retry(list, n, pass, item_round_failed)
    if records == nil then return end
    local held, held_carried, ids, held_complete = {}, {}, {}, true
    for _, r in ipairs(records) do
        if r.op == "more" or r.op == "morethan" then ids[r.id] = true end
    end
    for _, group in ipairs(objective_records or {}) do
        for _, option in ipairs(group.options) do ids[option.item_id] = true end
    end
    if next(ids) ~= nil then
        local h, hsk, hcomplete, hcarried = items.read_held(ids)
        if h == nil then item_round_failed() return end
        held = h
        held_carried = hcarried or {}
        skipped = skipped + hsk
        held_complete = hcomplete == true
    end
    -- v14: quest-related items from the same records, before the need table
    -- a raise here must not fail the need round: keep the previous map
    local okr, rel = pcall(require("Clairvoyance.npcs").related_items, records)
    if not okr then rel = items.related end
    local t, ignored = qnml_core.item_need_table(records, held)
    if type(t) ~= "table" then error("item_need_table: bad result") end
    local task_index, task_versions, tasks_complete = {}, {}, true
    local qlm = sdk.get_managed_singleton("app.QuestLogManager")
    local qdict = qlm ~= nil and safe_field(qlm, "_QuestLogInfoDict") or nil
    if qdict == nil then tasks_complete = false end
    if tasks_complete then
        for qid in pairs(wanted) do
            local info = safe_call(qdict, "get_Item", qid)
            local ti = info ~= nil and int_value(safe_call(info, "get_CurrentTaskIndex")) or nil
            if ti == nil and info ~= nil then
                ti = int_value(safe_field(info, "<CurrentTaskIndex>k__BackingField"))
            end
            if ti == nil or ti < 0 then tasks_complete = false
            else
                task_index[qid] = ti
                items.observe_task_index(qid, ti)
                task_versions[qid] = items.task_observation_versions[qid] or 0
            end
        end
    end
    local group_generation = ITEM_STATS.rounds
    objective_complete = objective_complete and skipped == 0 and held_complete
    local records_complete = objective_complete and tasks_complete
    items.objective_group_state = { status = records_complete and "ok" or "unknown",
        complete = records_complete, generation = group_generation,
        task_generation = items.task_observation_generation,
        groups = {}, records = records_complete and objective_records or {},
        held = records_complete and held or {},
        held_carried = records_complete and held_carried or {}, task_index = task_index,
        task_versions = task_versions }
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

-- One bounded, read-only native observation for the placed/chest providers.
-- Every collection is reconciled against its logical count.  Nil slots in the
-- context record list are intentional sparse entries; absence of a matching
-- UID after a complete pass is therefore meaningful.
function A.read_objective_source_observation(catalog)
  local out = { complete = false, persisted_complete = false,
    generation_complete = false, requested_complete = false, loaded_complete = false,
    persisted = {}, never = {}, dead = {}, disabled_tables = {}, blacklist = {},
    requested_tables = {}, loaded = {}, gate_results = {} }
  local by_identity, catalog_tables = {}, {}
  local function catalog_rows(rows, family)
    if type(rows) ~= "table" then return false end
    for _, row in ipairs(rows) do
      if type(row) ~= "table" or type(row.uid) ~= "string"
          or type(row.index) ~= "number" or type(row.table_id) ~= "string" then return false end
      by_identity[row.uid:lower() .. ":" .. tostring(row.index)] = family
      catalog_tables[row.table_id:lower()] = true
    end
    return true
  end
  if type(catalog) ~= "table" or not catalog_rows(catalog.placements, "placed")
      or not catalog_rows(catalog.chests, "chest") then return out end
  local function call(obj, method, ...)
    if obj == nil then return false, nil end
    return pcall(function(...) return obj:call(method, ...) end, ...)
  end
  local function type_name(obj)
    local ok, value = pcall(function()
      return obj:get_type_definition():get_full_name()
    end)
    if ok and type(value) == "string" then return value end
  end
  local function guid_text(value)
    local ok, text = call(value, "ToString()")
    if not ok or type(text) ~= "string" then return nil end
    text = text:lower()
    if not text:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") then
      return nil
    end
    return text
  end
  local function identity(value)
    local uid = guid_text(safe_field(value, "_RowID"))
    local index = int_value(safe_field(value, "_Index"))
    if uid == nil or type(index) ~= "number" or index ~= math.floor(index) then return nil end
    if index < 0 then return nil, uid, index end
    return uid .. ":" .. tostring(index), uid, index
  end
  local function list(value, cap, visit)
    local ok, count = call(value, "get_Count")
    if not ok or type(count) ~= "number" or count < 0 or count ~= math.floor(count)
        or count > cap then return false end
    for i = 0, count - 1 do
      local got, item = call(value, "get_Item", i)
      if not got then return false end
      if visit(item, i) == false then return false end
    end
    return true
  end
  local function entries(value, cap, visit)
    if value == nil then return false end
    local ok, expected = call(value, "get_Count")
    local used = int_value(safe_field(value, "_count"))
    local free = int_value(safe_field(value, "_freeCount"))
    local array = safe_field(value, "_entries")
    local elements
    local copied = pcall(function()
      local raw = array:get_elements()
      elements = {}
      for i = 1, #raw do elements[i] = raw[i] end
    end)
    if not ok or type(expected) ~= "number" or expected < 0 or expected ~= math.floor(expected)
        or type(used) ~= "number" or used < 0 or used ~= math.floor(used)
        or type(free) ~= "number" or free < 0 or free ~= math.floor(free)
        or used > cap or not copied or type(elements) ~= "table" or used > #elements then
      return false
    end
    local occupied = 0
    for i = 1, used do
      local entry = elements[i]
      local next_index = safe_field(entry, "Next")
      if next_index == nil then next_index = safe_field(entry, "next") end
      if type(next_index) ~= "number" then return false end
      if next_index >= -1 then
        occupied = occupied + 1
        local key = safe_field(entry, "Key")
        if key == nil then key = safe_field(entry, "key") end
        local value = safe_field(entry, "Value")
        if value == nil then value = safe_field(entry, "value") end
        if visit(key, value, entry) == false then return false end
      end
    end
    return occupied == expected and occupied + free == used
  end
  local function context_map(record, save_data)
    local map = {}
    local function add(context)
      if context == nil then return true end
      local name = type_name(context)
      if name == nil then return false end
      if map[name] == nil then map[name] = context end
      return true
    end
    if record == nil or not list(safe_field(record, "Contexts"), 128, add) then return nil end
    local saved = safe_field(save_data, "Contexts")
    if saved ~= nil and not list(saved, 128, add) then return nil end
    return map
  end
  local function persisted_scan()
    local db = safe_field(sdk.get_managed_singleton("app.ContextDBMS"), "OfflineDB")
    return list(safe_field(db, "Records"), 32768, function(info)
      if info == nil then return true end
      local map = context_map(safe_field(info, "<Record>k__BackingField"),
        safe_field(info, "SaveData"))
      if map == nil then return false end
      local key, uid, index = identity(safe_field(map["app.UniqueIDContext"], "UniqueID"))
      if key == nil then return uid ~= nil and type(index) == "number" and index < 0 end
      local family = by_identity[key]
      if family == "placed" then
        local freebit = int_value(safe_field(map["app.GimmickContext"], "_FreeBit"))
        if type(freebit) ~= "number" then return false end
        out.persisted[key] = { family = family, freebit = freebit }
      elseif family == "chest" then
        local item = map["app.GmItemContext"]
        local pick, keep, unlock = safe_field(item, "_IsPick"),
          safe_field(item, "_IsKeep"), safe_field(item, "_IsUnlock")
        if type(pick) ~= "boolean" or type(keep) ~= "boolean"
            or type(unlock) ~= "boolean" then return false end
        local state = { family = family, pick = pick, keep = keep, unlock = unlock }
        local treasure = map["app.TreasureBoxGimmickContext"]
        if treasure ~= nil then
          state.seal = safe_field(treasure, "_IsSeal")
          if type(state.seal) ~= "boolean" then return false end
        end
        out.persisted[key] = state
      end
      return true
    end)
  end
  local generation = sdk.get_managed_singleton("app.GenerateManager")
  local function uid_set(field, target)
    return entries(safe_field(generation, field), 32768, function(_, value)
      local key = identity(value)
      if key == nil then return false end
      target[key] = true
      return true
    end)
  end
  local function guid_set(field, target)
    return entries(safe_field(generation, field), 32768, function(_, value)
      local key = guid_text(value)
      if key == nil then return false end
      target[key] = true
      return true
    end)
  end
  local function requested_scan()
    return entries(safe_field(generation, "_RequestedTableInfos"), 32768,
      function(generator_id, info)
        local table_id = guid_text(safe_field(generator_id, "_TableID"))
        local extra = int_value(safe_field(generator_id, "_ExtraID"))
        local failed = safe_field(info, "_IsFailedAllRequest")
        local finished = safe_field(info, "_IsFinishAllRequestForGenerateTable")
        if table_id == nil or type(extra) ~= "number" or type(failed) ~= "boolean"
            or type(finished) ~= "boolean" then return false end
        if not catalog_tables[table_id] then return true end
        local state = out.requested_tables[table_id]
        if state == nil then
          state = { active = true, failed = false, finished = true, uids = {} }
          out.requested_tables[table_id] = state
        end
        state.failed = state.failed or failed
        state.finished = state.finished and finished
        return entries(safe_field(info, "_Requests"), 32768, function(uid_value)
          local key, uid, index = identity(uid_value)
          if key == nil then return uid ~= nil and type(index) == "number" and index < 0 end
          state.uids[key] = true
          return true
        end)
      end)
  end
  local function holder_contexts(holder)
    local map = {}
    local ok = entries(safe_field(holder, "Contexts"), 256, function(_, info)
      local context = safe_field(info, "<CurrentContext>k__BackingField")
      local name = type_name(context)
      if name == nil then return false end
      map[name] = context
      return true
    end)
    if not ok then return nil end
    ok = entries(safe_field(holder, "RestoredContexts"), 256, function(_, context)
      local name = type_name(context)
      if name == nil then return false end
      if map[name] == nil then map[name] = context end
      return true
    end)
    return ok and map or nil
  end
  local function loaded_source(object, family)
    local key = identity(safe_field(object, "<UniqId>k__BackingField"))
    if key == nil then return false end
    if by_identity[key] ~= family then return true end
    if out.loaded[key] ~= nil then return false end
    local contexts = holder_contexts(safe_field(object, "<CompContext>k__BackingField"))
    if contexts == nil then return false end
    local common = safe_field(safe_field(object, "<CompGenerateInfo>k__BackingField"), "_Container")
    common = safe_field(common, "_CommonInfo")
    local table_id = guid_text(safe_field(safe_field(common, "_CustomGeneratorID"), "_TableID"))
    local gen = contexts["app.GenerateInfoContext"]
    local state = { family = family, table_id = table_id,
      generated = safe_field(gen, "_IsGenerated"),
      disabled = safe_field(gen, "_IsDisableGenerate") }
    if table_id == nil or type(state.generated) ~= "boolean"
        or type(state.disabled) ~= "boolean" then return false end
    if family == "placed" then
      local gimmick = safe_field(object, "<GmContext>k__BackingField")
        or contexts["app.GimmickContext"]
      state.freebit = int_value(safe_field(gimmick, "_FreeBit"))
      state.broken, state.used = safe_field(object, "_IsBroken"), safe_field(object, "_IsUsed")
    else
      local item = safe_field(object, "ItemContext") or contexts["app.GmItemContext"]
      state.pick, state.keep, state.unlock = safe_field(item, "_IsPick"),
        safe_field(item, "_IsKeep"), safe_field(item, "_IsUnlock")
      local opened_ok, opened = call(object, "get_IsOpenedFreeBit")
      local unlock_ok, unlock_api = call(object, "get_IsUnlockFreeBit")
      if opened_ok then state.opened = opened end
      if unlock_ok then state.unlock_api = unlock_api end
      state.unlock_item = int_value(safe_field(object, "UnlockItem"))
      state.fake_unlock_item = int_value(safe_field(object, "FakeUnlockItem"))
      state.pawn_restrict = safe_field(object, "_IsPawnRestrict")
      local treasure = contexts["app.TreasureBoxGimmickContext"]
      if treasure ~= nil then state.seal = safe_field(treasure, "_IsSeal") end
    end
    out.loaded[key] = state
    return true
  end
  local function loaded_scan()
    local gm = sdk.get_managed_singleton("app.GimmickManager")
    return entries(safe_field(gm, "<ManagedGimmicksByIDs>k__BackingField"), 1024,
      function(_, set)
        return entries(set, 8192, function(_, object)
          local name = type_name(object)
          if name == nil then return false end
          if name == "app.Gm82_000" then return loaded_source(object, "placed") end
          if name == "app.gm80_001" then return loaded_source(object, "chest") end
          return true
        end)
      end)
  end
  local function gate_scan()
    local qm = sdk.get_managed_singleton("app.QuestManager")
    local qlm = sdk.get_managed_singleton("app.QuestLogManager")
    local method
    local ok = pcall(function()
      method = sdk.find_type_definition("app.QuestLogManager")
        :get_method("isQuestLogEnd(app.QuestDefine.ID)")
    end)
    if not ok or method == nil then return false end
    for _, spec in ipairs({ { "placed", catalog.placements }, { "chest", catalog.chests } }) do
      for _, row in ipairs(spec[2]) do
        if row.gate ~= nil then
          if type(row.gate) ~= "table" or type(row.gate.conditions) ~= "table"
              or (row.gate.check ~= 0 and row.gate.check ~= 1) then return false end
          local matched = 0
          for _, condition in ipairs(row.gate.conditions) do
            if type(condition) ~= "table" or condition.kind ~= "quest"
                or type(condition.qid) ~= "number" or type(condition.finish) ~= "boolean" then
              return false
            end
            local active_ok, active = call(qm, "checkActivated", condition.qid)
            local ended_ok, ended = pcall(function() return method:call(qlm, condition.qid) end)
            if not active_ok or type(active) ~= "boolean" or not ended_ok
                or type(ended) ~= "boolean" then return false end
            if ended == condition.finish then matched = matched + 1
            elseif row.gate.check == 0 then matched = -32768; break end
          end
          out.gate_results[spec[1] .. ":" .. row.uid:lower() .. ":" .. tostring(row.index)] =
            row.gate.check == 0 and matched == #row.gate.conditions or matched > 0
        end
      end
    end
    return true
  end
  local ok, err = pcall(function()
    out.persisted_complete = persisted_scan()
    out.generation_complete = generation ~= nil
      and uid_set("_NeverGenetateID", out.never)
      and uid_set("_NeverGenerateIDByDeadRequests", out.dead)
      and guid_set("_DisableGenerateRequests", out.disabled_tables)
      and guid_set("_GenerateBlacklistUniqueIDHashSet", out.blacklist)
    out.requested_complete = generation ~= nil and requested_scan()
    out.loaded_complete = loaded_scan() and gate_scan()
  end)
  if not ok then return out, tostring(err) end
  out.complete = out.persisted_complete and out.generation_complete
    and out.requested_complete and out.loaded_complete
  return out
end

-- Classifies the immutable places catalog against one atomic read of the
-- persisted/generation/loaded managers.  This is deliberately pure: world.lua
-- owns the static output/position catalog, while the adapter owns the native
-- observation.  A partial shared scan makes both providers unknown and a
-- family-local inconsistency clears that family's candidates.
function A.objective_source_provider_snapshots(catalog, observation, generation)
  local function envelope(provider, status, reason, candidates)
    return { provider = provider, generation = generation, status = status,
      complete = status == "ok", reason = reason, candidates = candidates or {} }
  end
  local function unknown_pair(reason)
    return { envelope("placed", "unknown", reason), envelope("chest", "unknown", reason) }
  end
  local function finite(v)
    return type(v) == "number" and v == v and v > -math.huge and v < math.huge
  end
  local function integer(v, minimum)
    return finite(v) and v == math.floor(v) and v >= minimum
  end
  local function dense(value)
    if type(value) ~= "table" then return nil end
    local n, count = #value, 0
    for k in pairs(value) do
      if not integer(k, 1) or k > n then return nil end
      count = count + 1
    end
    return count == n and value or nil
  end
  local function guid(value)
    if type(value) ~= "string" then return nil end
    local a, b, c, d, e = value:lower():match(
      "^(%x%x%x%x%x%x%x%x)%-(%x%x%x%x)%-(%x%x%x%x)%-(%x%x%x%x)%-(%x%x%x%x%x%x%x%x%x%x%x%x)$")
    if a == nil then return nil end
    return table.concat({ a, b, c, d, e }, "-")
  end
  local function copy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = copy(v) end
    return out
  end
  if not integer(generation, 1) then return unknown_pair("source_generation_invalid") end
  if type(catalog) ~= "table" or catalog.status ~= "ok" or catalog.complete ~= true
      or dense(catalog.placements) == nil or dense(catalog.chests) == nil then
    return unknown_pair("source_catalog_unavailable")
  end
  if type(observation) ~= "table" or observation.complete ~= true
      or observation.persisted_complete ~= true or observation.generation_complete ~= true
      or observation.requested_complete ~= true or observation.loaded_complete ~= true then
    return unknown_pair("source_observation_incomplete")
  end
  for _, key in ipairs({ "persisted", "never", "dead", "disabled_tables", "blacklist",
      "requested_tables", "loaded", "gate_results" }) do
    if type(observation[key]) ~= "table" then return unknown_pair("source_observation_malformed") end
  end

  local catalog_identities = {}
  for _, rows in ipairs({ catalog.placements, catalog.chests }) do
    for _, row in ipairs(rows) do
      local uid = type(row) == "table" and guid(row.uid) or nil
      local index = type(row) == "table" and row.index or nil
      if uid ~= nil and integer(index, 0) then
        local identity = uid .. ":" .. tostring(index)
        if catalog_identities[identity] then
          return unknown_pair("source_catalog_identity_duplicate")
        end
        catalog_identities[identity] = true
      end
    end
  end

  local function classify(provider, rows)
    local candidates = {}
    for _, row in ipairs(rows) do
      local uid = type(row) == "table" and guid(row.uid) or nil
      local index = type(row) == "table" and row.index or nil
      local table_id = type(row) == "table" and guid(row.table_id) or nil
      local outputs = type(row) == "table" and dense(row.outputs) or nil
      local pos = type(row) == "table" and row.pos or nil
      if uid == nil or not integer(index, 0) or table_id == nil
          or not integer(row.layer, 0) or outputs == nil or #outputs == 0
          or type(pos) ~= "table" or not finite(pos.x) or not finite(pos.y) or not finite(pos.z) then
        return envelope(provider, "unknown", provider .. "_catalog_row_malformed")
      end
      for _, output in ipairs(outputs) do
        if type(output) ~= "table" or not integer(output.item_id, 1)
            or not integer(output.count, 1) then
          return envelope(provider, "unknown", provider .. "_catalog_output_malformed")
        end
      end
      if provider == "chest" and (row.unlock_item ~= 0 or row.is_seal ~= false
          or row.fake_unlock_item ~= 0 or row.quest_override ~= false) then
        return envelope(provider, "unknown", "chest_access_domain_unmodeled")
      end
      local identity = uid .. ":" .. tostring(index)
      local gate_key = provider .. ":" .. identity
      local eligible = true
      if row.gate ~= nil then
        local gate = observation.gate_results[gate_key]
        if type(gate) ~= "boolean" then
          return envelope(provider, "unknown", provider .. "_gate_state_unreadable")
        end
        eligible = gate
      end
      if observation.never[identity] or observation.dead[identity]
          or observation.blacklist[uid] or observation.disabled_tables[table_id] then
        eligible = false
      end
      if row.layer ~= 0 then
        local request = observation.requested_tables[table_id]
        if request == nil then
          eligible = false
        elseif type(request) ~= "table" or type(request.active) ~= "boolean"
            or type(request.failed) ~= "boolean" or type(request.finished) ~= "boolean"
            or type(request.uids) ~= "table" then
          return envelope(provider, "unknown", provider .. "_subquest_request_unreadable")
        elseif request.failed or not request.active then
          eligible = false
        elseif not request.finished then
          return envelope(provider, "unknown", provider .. "_subquest_request_pending")
        elseif request.uids[identity] ~= true then
          eligible = false
        end
      end

      local persisted = observation.persisted[identity]
      if persisted ~= nil then
        if type(persisted) ~= "table" or persisted.family ~= provider then
          return envelope(provider, "unknown", provider .. "_persisted_state_unreadable")
        elseif provider == "placed" then
          if not integer(persisted.freebit, 0) then
            return envelope(provider, "unknown", "placed_persisted_state_unreadable")
          end
          if persisted.freebit & 3 ~= 0 then eligible = false end
        else
          if type(persisted.pick) ~= "boolean" or type(persisted.keep) ~= "boolean"
              or type(persisted.unlock) ~= "boolean"
              or (persisted.seal ~= nil and type(persisted.seal) ~= "boolean") then
            return envelope(provider, "unknown", "chest_persisted_state_unreadable")
          end
          if persisted.pick or persisted.seal == true then eligible = false end
        end
      end

      local loaded = observation.loaded[identity]
      if loaded ~= nil then
        if type(loaded) ~= "table" or loaded.family ~= provider
            or guid(loaded.table_id) ~= table_id
            or type(loaded.generated) ~= "boolean" or type(loaded.disabled) ~= "boolean" then
          return envelope(provider, "unknown", provider .. "_loaded_identity_unreadable")
        elseif not loaded.generated or loaded.disabled then
          eligible = false
        elseif provider == "placed" then
          if not integer(loaded.freebit, 0) or type(loaded.broken) ~= "boolean"
              or type(loaded.used) ~= "boolean" then
            return envelope(provider, "unknown", "placed_loaded_state_unreadable")
          elseif persisted ~= nil and loaded.freebit ~= persisted.freebit then
            return envelope(provider, "unknown", "placed_loaded_state_inconsistent")
          elseif loaded.freebit & 3 ~= 0 or loaded.broken or loaded.used then
            eligible = false
          end
        else
          if type(loaded.pick) ~= "boolean" or type(loaded.keep) ~= "boolean"
              or type(loaded.unlock) ~= "boolean" or type(loaded.opened) ~= "boolean"
              or type(loaded.unlock_api) ~= "boolean" or type(loaded.pawn_restrict) ~= "boolean"
              or loaded.unlock_item ~= 0 or loaded.fake_unlock_item ~= 0
              or (loaded.seal ~= nil and type(loaded.seal) ~= "boolean") then
            return envelope(provider, "unknown", "chest_loaded_state_unreadable")
          elseif loaded.opened ~= loaded.pick or loaded.unlock_api ~= loaded.unlock
              or (persisted ~= nil and (loaded.pick ~= persisted.pick
                or loaded.keep ~= persisted.keep or loaded.unlock ~= persisted.unlock
                or (persisted.seal ~= nil and loaded.seal ~= persisted.seal))) then
            return envelope(provider, "unknown", "chest_loaded_state_inconsistent")
          elseif loaded.pick or loaded.seal == true then
            eligible = false
          end
        end
      end
      if eligible and persisted == nil and loaded == nil then
        return envelope(provider, "unknown", provider .. "_current_state_unproven")
      end
      if eligible then
        candidates[#candidates + 1] = {
          source_id = { "source", provider, uid, index },
          provider = provider,
          target = { kind = provider, uid = uid, index = index, pos = copy(pos) },
          outputs = copy(outputs),
          capacity_pool_id = { "capacity", provider, uid, index },
          capacity_kind = "finite", available_acquisitions = 1,
          certainty = "guaranteed", eligibility = "eligible", generation = generation,
          evidence = { uid = uid, index = index, table_id = table_id, layer = row.layer,
            persisted = persisted ~= nil, loaded = loaded ~= nil },
        }
      end
    end
    return envelope(provider, "ok", nil, candidates)
  end
  return { classify("placed", catalog.placements), classify("chest", catalog.chests) }
end

-- Bounded atomic scan of TalkEventManager's merged catalog.  Every matching
-- ItemControlSegmentNode is retained with the complete event node/edge graph,
-- but no managed object escapes this function.
A.objective_provider_catalog_cache = {}
function A.invalidate_objective_provider_catalogs()
  A.objective_provider_catalog_cache = {}
end

function A.read_objective_talk_grant_observation(wanted)
  local out = { complete = false, wanted = {}, events = {} }
  local wanted_set = {}
  for item_id, enabled in pairs(type(wanted) == "table" and wanted or {}) do
    if enabled and type(item_id) == "number" and item_id == math.floor(item_id)
        and item_id > 0 then
      wanted_set[item_id] = true; out.wanted[#out.wanted + 1] = item_id
    end
  end
  table.sort(out.wanted)
  if #out.wanted == 0 then out.complete = true; return out end
  local function fail(reason) out.reason, out.events = reason, {}; return out end
  local function call(object, method, ...)
    if object == nil then return false, nil end
    return pcall(function(...) return object:call(method, ...) end, ...)
  end
  local function type_name(object)
    local ok, name = pcall(function()
      return object:get_type_definition():get_full_name()
    end)
    return ok and type(name) == "string" and name or nil
  end
  local function readable_boolean(ok, value)
    if ok and type(value) == "boolean" then return value end
    return nil
  end
  local function bounded_list(value, cap, prefix)
    local array_ok, elements = pcall(function() return value:get_elements() end)
    if array_ok and type(elements) == "table" then
      local keys = {}
      for key, row in pairs(elements) do
        if type(key) ~= "number" or key ~= math.floor(key) or row == nil then
          return nil, prefix .. "_unreadable"
        end
        keys[#keys + 1] = key
      end
      if #keys > cap then return nil, prefix .. "_truncated" end
      table.sort(keys)
      local rows = {}
      for index, key in ipairs(keys) do
        if key ~= index then return nil, prefix .. "_unreadable" end
        rows[#rows + 1] = elements[key]
      end
      return rows
    end
    local ok, count = call(value, "get_Count")
    count = ok and int_value(count) or nil
    if type(count) ~= "number" or count < 0 or count ~= math.floor(count) then
      return nil, prefix .. "_unreadable"
    elseif count > cap then return nil, prefix .. "_truncated" end
    local rows = {}
    for index = 0, count - 1 do
      local got, row = call(value, "get_Item", index)
      if not got or row == nil then return nil, prefix .. "_unreadable" end
      rows[#rows + 1] = row
    end
    return rows
  end
  local function bounded_entries(value, cap, prefix)
    local ok, expected = call(value, "get_Count")
    expected = ok and int_value(expected) or nil
    local used, free = int_value(safe_field(value, "_count")),
      int_value(safe_field(value, "_freeCount"))
    local array, elements = safe_field(value, "_entries"), nil
    local copied = pcall(function() elements = array:get_elements() end)
    if type(expected) ~= "number" or expected < 0 or expected ~= math.floor(expected)
        or type(used) ~= "number" or used < 0 or used ~= math.floor(used)
        or type(free) ~= "number" or free < 0 or free ~= math.floor(free)
        or used > cap or not copied or type(elements) ~= "table" or used > #elements then
      return nil, used ~= nil and used > cap and prefix .. "_truncated"
        or prefix .. "_unreadable"
    end
    local rows, occupied = {}, 0
    for index = 1, used do
      local entry = elements[index]
      local next_index = safe_field(entry, "Next")
      if next_index == nil then next_index = safe_field(entry, "next") end
      if type(next_index) ~= "number" then return nil, prefix .. "_unreadable" end
      if next_index >= -1 then
        occupied = occupied + 1
        local key = safe_field(entry, "Key")
        if key == nil then key = safe_field(entry, "key") end
        local value = safe_field(entry, "Value")
        if value == nil then value = safe_field(entry, "value") end
        rows[#rows + 1] = { key = key, value = value }
      end
    end
    if occupied ~= expected or occupied + free ~= used then
      return nil, prefix .. "_unreadable"
    end
    return rows
  end
  local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, child in pairs(value) do result[key] = copy(child) end
    return result
  end
  local manager = sdk.get_managed_singleton("app.TalkEventManager")
  local owner = manager ~= nil and tostring(manager) or nil
  local cached = A.objective_provider_catalog_cache.talk
  if cached == nil or cached.owner ~= owner then
    local catalog = safe_field(safe_field(manager, "_ResourceCatalog"),
      "<MergedCatalog>k__BackingField")
    local entries, reason = bounded_entries(catalog, 8192, "talk_grant_catalog")
    if entries == nil then return fail(reason) end
    local static_events = {}
    for _, entry in ipairs(entries) do
      local event_id = int_value(entry.key)
      local data = safe_field(entry.value, "_Item")
      if type(event_id) ~= "number" or event_id <= 0 or event_id ~= math.floor(event_id)
          or data == nil then return fail("talk_grant_event_data_unreadable") end
      local native_nodes, node_reason = bounded_list(safe_field(data, "_SegmentNodes"),
        1024, "talk_grant_nodes")
      if native_nodes == nil then return fail(node_reason) end
      local nodes, has_grant = {}, false
      for node_index, native_node in ipairs(native_nodes) do
        local kind = type_name(native_node)
        if kind == nil then return fail("talk_grant_node_type_unreadable") end
        local node_id = safe_field(native_node, "_NodeId")
        if type(node_id) ~= "string" and type(node_id) ~= "number" then node_id = nil end
        local node_name_hash = int_value(safe_field(native_node, "_NodeNameHash"))
        if node_id == nil and type(node_name_hash) ~= "number" then
          return fail("talk_grant_node_identity_unreadable")
        end
        local node = { index = node_index - 1, kind = kind,
          node_id = node_id, node_name_hash = node_name_hash,
          edges = {}, grants = {} }
        local raw_edges = safe_field(native_node, "_NextNodesCandidates")
        local native_edges = {}
        if raw_edges ~= nil then
          native_edges, reason = bounded_list(raw_edges, 128, "talk_grant_edges")
          if native_edges == nil then return fail(reason) end
        end
        for edge_index, native_edge in ipairs(native_edges) do
          local next_node_id = safe_field(native_edge, "_NextNodeId")
          if type(next_node_id) ~= "string" and type(next_node_id) ~= "number" then
            next_node_id = nil
          end
          local next_node_name_hash = int_value(safe_field(native_edge, "_NextNodeNameHash"))
          if next_node_id == nil and type(next_node_name_hash) ~= "number" then
            return fail("talk_grant_edge_identity_unreadable")
          end
          local raw_conditions = safe_field(native_edge, "_Conditions")
          local condition_count = 0
          if raw_conditions ~= nil then
            local conditions, condition_reason = bounded_list(
              safe_field(raw_conditions, "_ConditionList"), 128,
              "talk_grant_edge_conditions")
            if conditions == nil then return fail(condition_reason) end
            condition_count = #conditions
          end
          node.edges[#node.edges + 1] = { index = edge_index - 1,
            next_node_id = next_node_id, next_node_name_hash = next_node_name_hash,
            condition_count = condition_count }
        end
        if kind == "app.ItemControlSegmentNode" then
          local change = int_value(safe_field(native_node, "_ChangeType"))
          if type(change) ~= "number" then return fail("talk_grant_change_type_unreadable") end
          node.change_type = change
          local native_items, item_reason = bounded_list(safe_field(native_node, "_Items"),
            128, "talk_grant_items")
          if native_items == nil then return fail(item_reason) end
          for item_index, native_item in ipairs(native_items) do
            local item_id, count = int_value(safe_field(native_item, "_ItemId")),
              int_value(safe_field(native_item, "_Num"))
            if type(item_id) ~= "number" or item_id <= 0 or item_id ~= math.floor(item_id)
                or type(count) ~= "number" or count <= 0 or count ~= math.floor(count) then
              return fail("talk_grant_item_unreadable")
            end
            if change == 0 then
              has_grant = true
              node.grants[#node.grants + 1] = { item_index = item_index - 1,
                item_id = item_id, count = count }
            end
          end
        end
        nodes[#nodes + 1] = node
      end
      if has_grant then static_events[#static_events + 1] = {
        event_id = event_id, nodes = nodes } end
    end
    cached = { owner = owner, events = static_events }
    A.objective_provider_catalog_cache.talk = cached
  end
  local playing_rows = bounded_list(safe_field(manager, "_PlayingEventIDList"),
    256, "talk_grant_playing_events")
  local playing_set = nil
  if playing_rows ~= nil then
    playing_set = {}
    for _, value in ipairs(playing_rows) do
      local playing_id = int_value(value)
      if type(playing_id) ~= "number" or playing_id <= 0
          or playing_id ~= math.floor(playing_id) then
        playing_set = nil; break
      end
      playing_set[playing_id] = true
    end
  end
  local events = {}
  for _, event in ipairs(cached.events) do
    local relevant = false
    for _, node in ipairs(event.nodes) do
      for _, grant in ipairs(node.grants) do
        if wanted_set[grant.item_id] then relevant = true; break end
      end
      if relevant then break end
    end
    if relevant then
      local event_id = event.event_id
      local speaker_ok, raw_speaker_cid = call(
        manager, "getTalkEventInitialSpeaker", event_id)
      local speaker_cid = speaker_ok and int_value(raw_speaker_cid) or nil
      if type(speaker_cid) ~= "number" or speaker_cid <= 0
          or speaker_cid ~= math.floor(speaker_cid) then speaker_cid = nil end
      local playable_ok, playable = call(manager, "isEventPlayable", event_id)
      local history_ok, history = call(manager, "getHistory", event_id)
      local interaction_ok, interaction_disabled = false, nil
      if speaker_cid ~= nil then
        interaction_ok, interaction_disabled = call(
          manager, "isTalkEventInteractDisabled", speaker_cid)
      end
      local npc_manager = sdk.get_managed_singleton("app.NPCManager")
      local holder = speaker_cid ~= nil and safe_call(
        safe_field(npc_manager, "NPCHolderDic"), "get_Item", speaker_cid) or nil
      local character = holder ~= nil and (safe_call(holder, "get_chara")
        or safe_field(holder, "_chara") or safe_field(holder, "Chara")) or nil
      local px, py, pz
      if character ~= nil then px, py, pz = extract_position(character) end
      local playing = nil
      if playing_set ~= nil then playing = playing_set[event_id] == true end
      local interaction_enabled = nil
      if interaction_ok and type(interaction_disabled) == "boolean" then
        interaction_enabled = not interaction_disabled
      end
      events[#events + 1] = { event_id = event_id, nodes = copy(event.nodes),
        playable = readable_boolean(playable_ok, playable),
        playing_readable = playing_set ~= nil,
        playing = playing,
        speaker_cid_readable = speaker_cid ~= nil,
        speaker_cid = speaker_cid,
        speaker_present = character ~= nil,
        speaker_type = character ~= nil and type_name(character) or nil,
        speaker_position = px ~= nil and { x = px, y = py, z = pz } or nil,
        interaction_readable = interaction_ok
          and type(interaction_disabled) == "boolean",
        interaction_enabled = interaction_enabled,
        history_readable = history_ok, history_present = history_ok and history ~= nil,
        history_played = history ~= nil and safe_field(history, "Played") or nil,
        history_result = history ~= nil and int_value(safe_field(history, "ResultNum")) or nil }
    end
  end
  out.events, out.complete = events, true
  return out
end

-- Bounded atomic scan of the exact typed forgery service, item transforms and
-- raw order getters.  Mapping enablement and order semantics remain explicit
-- missing gates because their guarded live controls have not been proved.
function A.read_objective_forgery_observation(wanted)
  local out = { complete = false, wanted = {}, services = {}, mappings = {}, order = {} }
  local wanted_set = {}
  for item_id, enabled in pairs(type(wanted) == "table" and wanted or {}) do
    if enabled and type(item_id) == "number" and item_id == math.floor(item_id)
        and item_id > 0 then
      wanted_set[item_id] = true; out.wanted[#out.wanted + 1] = item_id
    end
  end
  table.sort(out.wanted)
  if #out.wanted == 0 then out.complete = true; return out end
  local function fail(reason)
    out.reason, out.services, out.mappings, out.order = reason, {}, {}, {}
    return out
  end
  local function call(object, method, ...)
    if object == nil then return false, nil end
    return pcall(function(...) return object:call(method, ...) end, ...)
  end
  local function type_name(object)
    local ok, name = pcall(function()
      return object:get_type_definition():get_full_name()
    end)
    return ok and type(name) == "string" and name or nil
  end
  local function readable_boolean(ok, value)
    if ok and type(value) == "boolean" then return value end
    return nil
  end
  local function bounded_list(value, cap, prefix)
    local array_ok, elements = pcall(function() return value:get_elements() end)
    if array_ok and type(elements) == "table" then
      local keys = {}
      for key, row in pairs(elements) do
        if type(key) ~= "number" or key ~= math.floor(key) or row == nil then
          return nil, prefix .. "_unreadable"
        end
        keys[#keys + 1] = key
      end
      if #keys > cap then return nil, prefix .. "_truncated" end
      table.sort(keys)
      local rows = {}
      for index, key in ipairs(keys) do
        if key ~= index then return nil, prefix .. "_unreadable" end
        rows[#rows + 1] = elements[key]
      end
      return rows
    end
    local ok, count = call(value, "get_Count")
    count = ok and int_value(count) or nil
    if type(count) ~= "number" or count < 0 or count ~= math.floor(count) then
      return nil, prefix .. "_unreadable"
    elseif count > cap then return nil, prefix .. "_truncated" end
    local rows = {}
    for index = 0, count - 1 do
      local got, row = call(value, "get_Item", index)
      if not got or row == nil then return nil, prefix .. "_unreadable" end
      rows[#rows + 1] = row
    end
    return rows
  end
  local function bounded_entries(value, cap, prefix)
    local ok, expected = call(value, "get_Count")
    expected = ok and int_value(expected) or nil
    local used, free = int_value(safe_field(value, "_count")),
      int_value(safe_field(value, "_freeCount"))
    local array, elements = safe_field(value, "_entries"), nil
    local copied = pcall(function() elements = array:get_elements() end)
    if type(expected) ~= "number" or expected < 0 or expected ~= math.floor(expected)
        or type(used) ~= "number" or used < 0 or used ~= math.floor(used)
        or type(free) ~= "number" or free < 0 or free ~= math.floor(free)
        or used > cap or not copied or type(elements) ~= "table" or used > #elements then
      return nil, used ~= nil and used > cap and prefix .. "_truncated"
        or prefix .. "_unreadable"
    end
    local rows, occupied = {}, 0
    for index = 1, used do
      local entry = elements[index]
      local next_index = safe_field(entry, "Next")
      if next_index == nil then next_index = safe_field(entry, "next") end
      if type(next_index) ~= "number" then return nil, prefix .. "_unreadable" end
      if next_index >= -1 then
        occupied = occupied + 1
        local key = safe_field(entry, "Key")
        if key == nil then key = safe_field(entry, "key") end
        local value = safe_field(entry, "Value")
        if value == nil then value = safe_field(entry, "value") end
        rows[#rows + 1] = { key = key, value = value }
      end
    end
    if occupied ~= expected or occupied + free ~= used then
      return nil, prefix .. "_unreadable"
    end
    return rows
  end
  local talk_manager = sdk.get_managed_singleton("app.TalkEventManager")
  local item_manager = sdk.get_managed_singleton("app.ItemManager")
  local talk_owner = talk_manager ~= nil and tostring(talk_manager) or nil
  local item_owner = item_manager ~= nil and tostring(item_manager) or nil
  local cached = A.objective_provider_catalog_cache.forgery
  if cached == nil or cached.talk_owner ~= talk_owner or cached.item_owner ~= item_owner then
    local shop_entries, reason = bounded_entries(
      safe_field(talk_manager, "_ShopTalkEventDataCatalog"), 256,
      "forgery_service_catalog")
    if shop_entries == nil then return fail(reason) end
    local static_services = {}
    for _, entry in ipairs(shop_entries) do
      local job, data = int_value(entry.key), entry.value
      local talk_event_id = int_value(safe_field(data, "_TalkEventID"))
      if type(job) ~= "number" or job < 0 or job ~= math.floor(job)
          or type(talk_event_id) ~= "number" or talk_event_id <= 0
          or talk_event_id ~= math.floor(talk_event_id) then
        return fail("forgery_service_identity_unreadable")
      end
      local rows, row_reason = bounded_list(safe_field(data, "_CharacterShopData"),
        64, "forgery_service_rows")
      if rows == nil then return fail(row_reason) end
      for service_index, service in ipairs(rows) do
        local service_type = type_name(service)
        if service_type == nil then return fail("forgery_service_type_unreadable") end
        if service_type == "app.NpcShopForgeryParam" then
          local chara_id, shop_id = int_value(safe_field(service, "_CharaID")),
            int_value(safe_field(service, "_ShopID"))
          if type(chara_id) ~= "number" or chara_id <= 0
              or chara_id ~= math.floor(chara_id)
              or type(shop_id) ~= "number" or shop_id <= 0
              or shop_id ~= math.floor(shop_id) then
            return fail("forgery_service_identity_unreadable")
          end
          local conditions, condition_reason = {}, nil
          local raw_conditions = safe_field(service, "_Conditions")
          if raw_conditions ~= nil then
            local native_conditions
            native_conditions, condition_reason = bounded_list(raw_conditions, 64,
              "forgery_service_conditions")
            if native_conditions == nil then return fail(condition_reason) end
            for _, selector in ipairs(native_conditions) do
              local process = safe_field(selector, "_Process") or safe_field(selector, "_Class")
              conditions[#conditions + 1] = type_name(process) or "unknown"
            end
          end
          static_services[#static_services + 1] = { job = job,
            talk_event_id = talk_event_id, service_index = service_index - 1,
            chara_id = chara_id, shop_id = shop_id, service_type = service_type,
            conditions = conditions, condition_truth_readable = false,
            condition_reason = "forgery_service_condition_evaluation_unproved" }
        end
      end
    end
    local item_entries
    item_entries, reason = bounded_entries(safe_field(item_manager, "_ItemDataDict"),
      8192, "forgery_mapping_catalog")
    if item_entries == nil then return fail(reason) end
    local static_mappings = {}
    for _, entry in ipairs(item_entries) do
      local item = entry.value
      local output_item_id = int_value(safe_field(item, "_FakeItemId"))
      if type(output_item_id) == "number" and output_item_id > 0 then
        local input_item_id, price = int_value(safe_field(item, "_Id")),
          int_value(safe_field(item, "_FakePrice"))
        if type(input_item_id) ~= "number" or input_item_id <= 0
            or input_item_id ~= math.floor(input_item_id)
            or output_item_id ~= math.floor(output_item_id)
            or type(price) ~= "number" or price <= 0 or price ~= math.floor(price)
            or type_name(item) ~= "app.ItemDataParam" then
          return fail("forgery_mapping_unreadable")
        end
        local enabled_ok, enabled = call(item, "get_IsEnableFake")
        local enabled_readable = enabled_ok and type(enabled) == "boolean"
        static_mappings[#static_mappings + 1] = { input_item_id = input_item_id,
          output_item_id = output_item_id, price = price,
          enabled_readable = enabled_readable,
          enabled = readable_boolean(enabled_ok, enabled),
          enabled_reason = enabled_readable and nil
            or "forgery_mapping_enablement_read_failed" }
      end
    end
    table.sort(static_mappings, function(left, right)
      if left.output_item_id ~= right.output_item_id then
        return left.output_item_id < right.output_item_id
      end
      return left.input_item_id < right.input_item_id
    end)
    cached = { talk_owner = talk_owner, item_owner = item_owner,
      services = static_services, mappings = static_mappings }
    A.objective_provider_catalog_cache.forgery = cached
  end
  local mappings = {}
  for _, mapping in ipairs(cached.mappings) do
    if wanted_set[mapping.output_item_id] then
      local live_mapping = {}
      for key, value in pairs(mapping) do live_mapping[key] = value end
      mappings[#mappings + 1] = live_mapping
    end
  end
  local services = {}
  if #mappings > 0 then
    local npc_manager = sdk.get_managed_singleton("app.NPCManager")
    for _, static_service in ipairs(cached.services) do
      local talk_event_id, chara_id = static_service.talk_event_id,
        static_service.chara_id
      local speaker_ok, raw_speaker_cid = call(
        talk_manager, "getTalkEventInitialSpeaker", talk_event_id)
      local playable_ok, playable = call(talk_manager, "isEventPlayable", talk_event_id)
      local speaker_cid = speaker_ok and int_value(raw_speaker_cid) or nil
      local speaker_cid_readable = type(speaker_cid) == "number"
        and speaker_cid > 0 and speaker_cid == math.floor(speaker_cid)
      local speaker_matches_service = speaker_cid_readable
        and speaker_cid == chara_id or false
      local holder = speaker_cid_readable and safe_call(
        safe_field(npc_manager, "NPCHolderDic"), "get_Item", speaker_cid) or nil
      local speaker = holder ~= nil and (safe_call(holder, "get_chara")
        or safe_field(holder, "_chara") or safe_field(holder, "Chara")) or nil
      local interact_ok, interactable = false, nil
      if speaker ~= nil then
        interact_ok, interactable = call(talk_manager, "canTalkEventInteract", speaker)
      end
      local character_data = speaker_matches_service
        and safe_call(npc_manager, "getNPCCharacterData", chara_id) or nil
      local blackboard = speaker_matches_service
        and safe_call(speaker, "get_AIBlackBoardController") or nil
      local available_ok, available = false, nil
      if character_data ~= nil and blackboard ~= nil then
        available_ok, available = call(talk_manager,
          "isShopTalkEventAvailableForChara", character_data, blackboard)
      end
      local disabled_ok, disabled = call(talk_manager,
        "isTalkEventInteractDisabled", chara_id)
      local px, py, pz
      if speaker ~= nil then px, py, pz = extract_position(speaker) end
      local service = {}
      for key, value in pairs(static_service) do service[key] = value end
      service.playable = readable_boolean(playable_ok, playable)
      service.speaker_present = speaker ~= nil
      service.speaker_cid_readable = speaker_cid_readable
      service.speaker_cid = speaker_cid_readable and speaker_cid or nil
      service.speaker_matches_service = speaker_matches_service
      service.character_data_readable = character_data ~= nil
      service.blackboard_readable = blackboard ~= nil
      service.availability_readable = available_ok and type(available) == "boolean"
      service.available = readable_boolean(available_ok, available)
      service.condition_truth_readable = service.availability_readable
      service.condition_truth = service.available
      if not speaker_matches_service then
        service.join_reason = "forgery_service_speaker_join_unproven"
      elseif not service.availability_readable then
        service.join_reason = "forgery_service_availability_unproven"
      else
        service.join_reason = nil
      end
      service.speaker_position = px ~= nil and { x = px, y = py, z = pz } or nil
      service.interactable = readable_boolean(interact_ok, interactable)
      service.interaction_disabled = readable_boolean(disabled_ok, disabled)
      services[#services + 1] = service
    end
  end
  if #mappings > 0 then
    local input_ids = {}
    for _, mapping in ipairs(mappings) do input_ids[mapping.input_item_id] = true end
    local held, _, held_complete = items.read_held(input_ids)
    for _, mapping in ipairs(mappings) do
      mapping.held_readable = held ~= nil and held_complete == true
      mapping.held_count = mapping.held_readable and (held[mapping.input_item_id] or 0) or nil
      mapping.held_reason = mapping.held_readable and nil
        or "forgery_input_inventory_read_incomplete"
      mapping.price_readable = false
      mapping.price_reason = "forgery_currency_reader_unproved"
    end
  end
  local order = {}
  if #mappings > 0 then
    local kept_ok, kept = call(item_manager, "get_FakeShopKeepedItem")
    local time_ok, completion_time = call(item_manager, "get_FakeShopCompleteTime")
    local kept_state_ok, kept_active = call(item_manager, "isFakeShopKeeped")
    local completed_ok, completed = call(item_manager, "isFakeShopCompleted")
    local remaining_ok, remaining = call(item_manager, "isFakeShopRemainingMinute")
    local kept_item_id, kept_item_count = int_value(safe_field(kept, "_ItemId")),
      int_value(safe_field(kept, "_Num"))
    order = { kept_readable = kept_ok and kept ~= nil
        and type(kept_item_id) == "number" and kept_item_id >= 0
        and kept_item_id == math.floor(kept_item_id)
        and type(kept_item_count) == "number" and kept_item_count >= 0
        and kept_item_count == math.floor(kept_item_count),
      kept_item_id = kept_item_id, kept_item_count = kept_item_count,
      completion_time_readable = time_ok and type(completion_time) == "number"
        and completion_time >= 0 and completion_time == math.floor(completion_time),
      completion_time = completion_time,
      kept_state_readable = kept_state_ok and type(kept_active) == "boolean",
      kept_active = readable_boolean(kept_state_ok, kept_active),
      completed_readable = completed_ok and type(completed) == "boolean",
      completed = completed,
      remaining_minutes_readable = remaining_ok and type(remaining) == "number"
        and remaining >= 0 and remaining == math.floor(remaining),
      remaining_minutes = remaining }
  end
  out.services, out.mappings, out.order, out.complete = services, mappings, order, true
  return out
end

-- Production provider envelopes over atomic native observations.  The
-- scanners below retain exact typed catalog/graph evidence, while these
-- classifiers keep publication closed at the first game-semantic gate that
-- has not yet been verified with positive and negative controls.
function A.objective_talk_grant_provider_snapshot(observation, generation)
  local function finite_integer(value, minimum)
    return type(value) == "number" and value == value and value > -math.huge
      and value < math.huge and value == math.floor(value) and value >= minimum
  end
  local function dense(value)
    if type(value) ~= "table" then return nil end
    local n, count = #value, 0
    for key in pairs(value) do
      if not finite_integer(key, 1) or key > n then return nil end
      count = count + 1
    end
    return count == n and value or nil
  end
  local function copy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for key, child in pairs(value) do out[key] = copy(child) end
    return out
  end
  local out = { provider = "talk_grant", generation = generation,
    status = "unknown", complete = false, candidates = {}, diagnostics = {} }
  if not finite_integer(generation, 1) then
    out.reason = "talk_grant_generation_invalid"; return out
  end
  if type(observation) ~= "table" then
    out.reason = "talk_grant_observation_unavailable"; return out
  end
  if observation.complete ~= true then
    out.reason = type(observation.reason) == "string" and observation.reason
      or "talk_grant_observation_incomplete"
    return out
  end
  local wanted, events = dense(observation.wanted), dense(observation.events)
  if wanted == nil or events == nil then
    out.reason = "talk_grant_observation_malformed"; return out
  end
  local wanted_set = {}
  for _, item_id in ipairs(wanted) do
    if not finite_integer(item_id, 1) then
      out.reason = "talk_grant_observation_malformed"; return out
    end
    wanted_set[item_id] = true
  end
  for _, event in ipairs(events) do
    if type(event) ~= "table" or not finite_integer(event.event_id, 1)
        or dense(event.nodes) == nil then
      out.reason = "talk_grant_observation_malformed"; return out
    end
    for _, node in ipairs(event.nodes) do
      if type(node) ~= "table" or not finite_integer(node.index, 0)
          or type(node.kind) ~= "string" or dense(node.edges) == nil
          or (node.grants ~= nil and dense(node.grants) == nil) then
        out.reason = "talk_grant_observation_malformed"; return out
      end
      if node.node_id == nil and not finite_integer(node.node_name_hash, 0) then
        out.reason = "talk_grant_observation_malformed"; return out
      end
      if node.node_id ~= nil and type(node.node_id) ~= "string"
          and not finite_integer(node.node_id, 0) then
        out.reason = "talk_grant_observation_malformed"; return out
      end
      for _, edge in ipairs(node.edges) do
        if type(edge) ~= "table" or not finite_integer(edge.index, 0)
            or not finite_integer(edge.condition_count, 0)
            or (edge.next_node_id == nil
              and not finite_integer(edge.next_node_name_hash, 0)) then
          out.reason = "talk_grant_observation_malformed"; return out
        end
      end
      for _, grant in ipairs(node.grants or {}) do
        if type(grant) ~= "table" or not finite_integer(grant.item_index, 0)
            or not finite_integer(grant.item_id, 1)
            or not finite_integer(grant.count, 1) then
          out.reason = "talk_grant_observation_malformed"; return out
        end
      end
    end
  end
  if #wanted == 0 or #events == 0 then
    out.status, out.complete, out.reason = "ok", true, nil
    return out
  end
  local function node_identity(node)
    if node.node_id ~= nil then return node.node_id end
    return node.node_name_hash
  end
  local function ref_key(prefix, value)
    if value == nil then return nil end
    return prefix .. type(value) .. ":" .. tostring(value)
  end
  local function valid_position(value)
    if type(value) ~= "table" then return false end
    local x, y, z = value.x, value.y, value.z
    local function finite_number(number)
      return type(number) == "number" and number == number
        and number > -math.huge and number < math.huge
    end
    return finite_number(x) and finite_number(y) and finite_number(z)
      and not (x == 0 and y == 0 and z == 0)
  end
  local function event_gate(event)
    if type(event.playable) ~= "boolean" then
      return "unknown", "talk_grant_playability_unreadable"
    elseif not event.playable then
      return "ineligible", "talk_grant_event_unavailable"
    elseif type(event.playing) ~= "boolean" then
      return "unknown", "talk_grant_playing_state_unreadable"
    elseif event.playing then
      return "ineligible", "talk_grant_event_playing"
    elseif not finite_integer(event.speaker_cid, 1) then
      return "unknown", "talk_grant_speaker_unreadable"
    elseif not valid_position(event.speaker_position) then
      return "unknown", "talk_grant_speaker_position_unreadable"
    elseif event.interaction_readable ~= true
        or type(event.interaction_enabled) ~= "boolean" then
      return "unknown", "talk_grant_interaction_unreadable"
    elseif not event.interaction_enabled then
      return "ineligible", "talk_grant_interaction_disabled"
    elseif event.history_readable ~= true then
      return "unknown", "talk_grant_history_unreadable"
    elseif type(event.history_present) ~= "boolean" then
      return "unknown", "talk_grant_history_state_unreadable"
    elseif event.history_present and type(event.history_played) ~= "boolean" then
      return "unknown", "talk_grant_history_state_unreadable"
    elseif event.history_present and event.history_played then
      return "ineligible", "talk_grant_history_played"
    -- ResultNum is branch evidence, not a success/cancel enum: the live catalog
    -- has currently playable, unplayed records at -1, 0 and 60.  Require the
    -- value to be readable without inventing meanings for those values.
    elseif event.history_present and (type(event.history_result) ~= "number"
        or event.history_result ~= event.history_result
        or event.history_result <= -math.huge or event.history_result >= math.huge
        or event.history_result ~= math.floor(event.history_result)) then
      return "unknown", "talk_grant_history_result_unreadable"
    end
    return "eligible", nil
  end
  for _, event in ipairs(events) do
    local by_id, by_hash, reach, reach_reason = {}, {}, {}, {}
    local transparent_kind = { ["app.RootSegmentNode"] = true,
      ["app.TalkSegmentNode"] = true }
    local graph_reason = nil
    for _, node in ipairs(event.nodes) do
      local id_key = ref_key("id:", node.node_id)
      local hash_key = ref_key("hash:", node.node_name_hash)
      if id_key ~= nil then
        by_id[id_key] = by_id[id_key] == nil and node or false
      end
      if hash_key ~= nil then
        by_hash[hash_key] = by_hash[hash_key] == nil and node or false
      end
      if node.kind == "app.RootSegmentNode" then reach[node] = 2 end
    end
    if next(reach) == nil then graph_reason = "talk_grant_root_unreadable" end
    local changed = true
    for _ = 1, #event.nodes do
      if not changed then break end
      changed = false
      for _, node in ipairs(event.nodes) do
        local state = reach[node]
        if state ~= nil then
          for _, edge in ipairs(node.edges) do
            local id_target, hash_target = nil, nil
            if edge.next_node_id ~= nil then
              id_target = by_id[ref_key("id:", edge.next_node_id)]
            end
            if edge.next_node_name_hash ~= nil then
              hash_target = by_hash[ref_key("hash:", edge.next_node_name_hash)]
            end
            local both_references = edge.next_node_id ~= nil
              and edge.next_node_name_hash ~= nil
            local identity_conflict = id_target == false or hash_target == false
              or (both_references and (id_target == nil or hash_target == nil
                or id_target ~= hash_target))
            local target = not identity_conflict and (id_target or hash_target) or nil
            if identity_conflict then
              graph_reason = "talk_grant_node_identity_conflict"
            elseif target == nil then
              graph_reason = "talk_grant_graph_target_unresolved"
            else
              local next_state, next_reason = state, reach_reason[node]
              if state == 2 and edge.condition_count > 0 then
                next_state, next_reason = 1, "talk_grant_branch_condition_unmodeled"
              elseif state == 2 and not transparent_kind[node.kind] then
                next_state, next_reason = 1, "talk_grant_intermediate_node_unmodeled"
              end
              if reach[target] == nil or next_state > reach[target] then
                reach[target], reach_reason[target] = next_state, next_reason
                changed = true
              end
            end
          end
        end
      end
    end
    local gate_eligibility, gate_reason = event_gate(event)
    for _, node in ipairs(event.nodes) do
      local outputs = {}
      for _, grant in ipairs(node.grants or {}) do
        if wanted_set[grant.item_id] then outputs[#outputs + 1] = copy(grant) end
      end
      if #outputs > 0 then
        local eligibility, reason = gate_eligibility, gate_reason
        local identity, identity_owner = node_identity(node), nil
        if node.node_id ~= nil
            and by_id[ref_key("id:", node.node_id)] == node then
          identity_owner = node
        elseif node.node_name_hash ~= nil
            and by_hash[ref_key("hash:", node.node_name_hash)] == node then
          identity, identity_owner = node.node_name_hash, node
        end
        if eligibility == "eligible" then
          if identity_owner ~= node then
            eligibility, reason = "unknown", "talk_grant_node_identity_conflict"
          elseif reach[node] == 1 then
            eligibility, reason = "unknown", reach_reason[node]
              or "talk_grant_branch_condition_unmodeled"
          elseif reach[node] ~= 2 then
            eligibility, reason = "unknown",
              graph_reason or "talk_grant_node_unreachable"
          end
        end
        local diagnostic = { event_id = event.event_id, node_id = identity,
          node_index = node.index, eligibility = eligibility, reason = reason,
          outputs = copy(outputs), speaker_cid = event.speaker_cid,
          history_present = event.history_present == true,
          history_played = event.history_played,
          history_result = event.history_result }
        out.diagnostics[#out.diagnostics + 1] = diagnostic
        if eligibility == "eligible" then
          out.candidates[#out.candidates + 1] = {
            source_id = { "source", "talk_grant", event.event_id, identity },
            provider = "talk_grant",
            target = { kind = "npc", cid = event.speaker_cid,
              pos = copy(event.speaker_position) },
            outputs = copy(outputs),
            capacity_pool_id = { "capacity", "talk_grant", event.event_id, identity },
            capacity_kind = "finite", available_acquisitions = 1,
            certainty = "guaranteed", eligibility = "eligible",
            generation = generation,
            evidence = { event_id = event.event_id, node_index = node.index,
              node_id = identity, history_present = event.history_present == true },
          }
        end
      end
    end
  end
  out.status, out.complete, out.reason = "ok", true, nil
  return out
end

function A.objective_forgery_provider_snapshot(observation, generation)
  local function finite_integer(value, minimum)
    return type(value) == "number" and value == value and value > -math.huge
      and value < math.huge and value == math.floor(value) and value >= minimum
  end
  local function dense(value)
    if type(value) ~= "table" then return nil end
    local n, count = #value, 0
    for key in pairs(value) do
      if not finite_integer(key, 1) or key > n then return nil end
      count = count + 1
    end
    return count == n and value or nil
  end
  local function copy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for key, child in pairs(value) do out[key] = copy(child) end
    return out
  end
  local out = { provider = "forgery", generation = generation,
    status = "unknown", complete = false, candidates = {},
    diagnostics = { services = {}, mappings = {}, order = {} } }
  if not finite_integer(generation, 1) then
    out.reason = "forgery_generation_invalid"; return out
  end
  if type(observation) ~= "table" then
    out.reason = "forgery_observation_unavailable"; return out
  end
  out.diagnostics.services = copy(type(observation.services) == "table"
    and observation.services or {})
  out.diagnostics.mappings = copy(type(observation.mappings) == "table"
    and observation.mappings or {})
  out.diagnostics.order = copy(type(observation.order) == "table"
    and observation.order or {})
  if observation.complete ~= true then
    out.reason = type(observation.reason) == "string" and observation.reason
      or "forgery_observation_incomplete"
    return out
  end
  local wanted, services, mappings = dense(observation.wanted),
    dense(observation.services), dense(observation.mappings)
  if wanted == nil or services == nil or mappings == nil
      or type(observation.order) ~= "table" then
    out.reason = "forgery_observation_malformed"; return out
  end
  for _, item_id in ipairs(wanted) do
    if not finite_integer(item_id, 1) then
      out.reason = "forgery_observation_malformed"; return out
    end
  end
  for _, service in ipairs(services) do
    if type(service) ~= "table" or service.service_type ~= "app.NpcShopForgeryParam"
        or not finite_integer(service.talk_event_id, 1)
        or not finite_integer(service.service_index, 0)
        or not finite_integer(service.chara_id, 1)
        or not finite_integer(service.shop_id, 1) then
      out.reason = "forgery_observation_malformed"; return out
    end
  end
  for _, mapping in ipairs(mappings) do
    if type(mapping) ~= "table" or not finite_integer(mapping.input_item_id, 1)
        or not finite_integer(mapping.output_item_id, 1)
        or not finite_integer(mapping.price, 1)
        or type(mapping.enabled_readable) ~= "boolean"
        or (mapping.enabled_readable and type(mapping.enabled) ~= "boolean") then
      out.reason = "forgery_observation_malformed"; return out
    end
  end
  if #wanted == 0 or #mappings == 0 or #services == 0 then
    out.status, out.complete, out.reason = "ok", true, nil
    return out
  end
  local any_enabled = false
  for _, mapping in ipairs(mappings) do
    if not mapping.enabled_readable then
      out.reason = "forgery_mapping_enablement_unproven"
      out.missing_evidence = { "mapping_enablement", "service_speaker_join",
        "service_availability",
        "positioned_interactable_service", "held_input_acceptance",
        "price_affordability", "busy_kept_completion_semantics" }
      return out
    end
    if mapping.enabled then any_enabled = true end
  end
  if not any_enabled then
    out.status, out.complete, out.reason = "ok", true, nil
    return out
  end
  local any_available = false
  for _, service in ipairs(services) do
    if service.speaker_matches_service ~= true then
      out.reason = "forgery_service_speaker_join_unproven"
      out.missing_evidence = { "service_speaker_join", "service_availability",
        "positioned_interactable_service", "held_input_acceptance",
        "price_affordability", "busy_kept_completion_semantics" }
      return out
    elseif service.availability_readable ~= true then
      out.reason = "forgery_service_availability_unproven"
      out.missing_evidence = { "service_availability",
        "positioned_interactable_service", "held_input_acceptance",
        "price_affordability", "busy_kept_completion_semantics" }
      return out
    end
    if service.available then any_available = true end
  end
  if not any_available then
    out.status, out.complete, out.reason = "ok", true, nil
    return out
  end
  out.reason = "forgery_positioned_interaction_semantics_unproven"
  out.missing_evidence = { "positioned_interactable_service",
    "held_input_acceptance", "price_affordability",
    "busy_kept_completion_semantics" }
  return out
end

function A.make()
  local a = {}
  local objective_task_state = { owner = nil, focus = nil, journal = nil,
    needs = nil, focus_epoch = 0, journal_generation = 0, need_generation = 0,
    source_generation = 1, source_catalog = nil, source_observation = nil,
    source_need_generation = nil,
    filtered_source_owner = nil, filtered_source_signature = nil,
    filtered_source_catalog = nil,
    talk_generation = 1, talk_observation = nil,
    talk_at = -math.huge, forgery_generation = 1, forgery_observation = nil,
    forgery_at = -math.huge, reward_observation = nil }
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
  -- Pure expression grouper used by the objective adapter scan. Kept beside
  -- the legacy item API so callers can migrate without changing item_needs().
  local function objective_copy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for key, nested in pairs(value) do out[key] = objective_copy(nested) end
    return out
  end
  local function objective_owner_matches(owner, record, task_index)
    if type(owner) ~= "table" or owner.task_index ~= task_index
        or owner.eligibility ~= "eligible" or owner.proof_kind ~= "condition" then
      return false
    end
    local options = type(record.options) == "table" and record.options or {}
    if #options ~= 1 then return false end
    local option, required = options[1], options[1].required
    if option.op == "morethan" and type(required) == "number" then
      required = required + 1
    elseif option.op ~= "more" then
      return false
    end
    return type(option.item_id) == "number" and type(required) == "number"
      and owner.item_id == option.item_id and owner.count == required
  end
  local function objective_owned_records(task_snapshot, state)
    local qrows, owned, matches, owner_uses = {}, {}, {}, {}
    for _, row in ipairs(task_snapshot.quests) do
      if type(row) == "table" and type(row.qid) == "number" then qrows[row.qid] = row end
    end
    for record_index, record in ipairs(state.records) do
      local row = qrows[record.qid]
      if type(row) == "table" and row.read_status == "ok"
          and row.task_index == state.task_index[record.qid] then
        for owner_index, owner in ipairs(type(row.item_ownership) == "table"
            and row.item_ownership or {}) do
          if objective_owner_matches(owner, record, row.task_index) then
            local owner_key = tostring(record.qid) .. ":" .. tostring(owner_index)
            local list = matches[record_index]
            if list == nil then list = {}; matches[record_index] = list end
            list[#list + 1] = owner_key
            owner_uses[owner_key] = (owner_uses[owner_key] or 0) + 1
          end
        end
      end
    end
    for record_index, record in ipairs(state.records) do
      for _, owner_key in ipairs(matches[record_index] or {}) do
        if owner_uses[owner_key] == 1 then
          local proven = objective_copy(record)
          proven.current_work = true
          owned[#owned + 1] = proven
          break
        end
      end
    end
    return owned
  end
  function a.objective_need_groups(task_snapshot)
    local state = items.objective_group_state
    local qrows, qseen = {}, {}
    if type(task_snapshot) ~= "table" or type(task_snapshot.need_generation) ~= "number"
        or type(task_snapshot.quests) ~= "table" or not ITEM_STATS.needs_fresh
        or state.complete ~= true or state.status ~= "ok" then
      return { status = "unknown", complete = false, groups = {},
        generation = type(task_snapshot) == "table" and task_snapshot.need_generation or nil,
        source_generation = state.generation, reason = "need_or_task_observation_unknown" }
    end
    for _, row in ipairs(task_snapshot.quests) do
      if type(row) == "table" and type(row.qid) == "number" then
        qrows[row.qid] = row
        qseen[row.qid] = true
      end
    end
    for qid in pairs(qseen) do
      local row = qrows[qid]
      if state.task_index[qid] ~= nil
          and ((state.task_versions and state.task_versions[qid] or 0)
            ~= (items.task_observation_versions[qid] or 0)) then
        return { status = "unknown", complete = false, groups = {},
          generation = task_snapshot.need_generation,
          source_generation = state.generation, reason = "task_observation_changed" }
      end
      if state.task_index[qid] ~= nil and (row.read_status ~= "ok"
          or row.task_index ~= state.task_index[qid]) then
        return { status = "unknown", complete = false, groups = {},
          generation = task_snapshot.need_generation,
          source_generation = state.generation, reason = "current_task_changed" }
      end
    end
    local records = objective_owned_records(task_snapshot, state)
    local groups, complete = A.objective_need_builder.build(records, state.held,
      { generation = state.generation, task_generation = state.generation,
        task_index = state.task_index })
    if not complete then
      return { status = "unknown", complete = false, groups = {},
        generation = task_snapshot.need_generation,
        source_generation = state.generation, reason = "owned_need_invalid" }
    end
    local structured_qids = {}
    for _, record in ipairs(records) do structured_qids[record.qid] = true end
    local fallback_valid = true
    if #state.records > 0 then
      for _, row in ipairs(task_snapshot.quests) do
        local ownership = type(row) == "table" and row.item_ownership or nil
        local needs = type(row) == "table" and ITEM_NEEDS and ITEM_NEEDS[row.qid] or nil
        if type(ownership) ~= "table" then fallback_valid = false; break end
        local relevant_owner = false
        if not structured_qids[row.qid] then
          for _, owner in ipairs(ownership) do
            for _, need in ipairs(type(needs) == "table" and needs or {}) do
              if owner.item_id == need.id then relevant_owner = true; break end
            end
            if relevant_owner then break end
          end
        end
        if relevant_owner then fallback_valid = false; break end
        if not structured_qids[row.qid]
            and row.read_status == "ok" and state.task_index[row.qid] == row.task_index then
          for _, need in ipairs(type(needs) == "table" and needs or {}) do
            local held = state.held[need.id] or 0
            local remaining = type(need.num) == "number" and need.num - held or nil
            if type(need.id) ~= "number" or need.id <= 0 or need.id ~= math.floor(need.id)
                or type(need.num) ~= "number" or need.num <= 0
                or need.num ~= math.floor(need.num) or type(held) ~= "number" or held < 0
                or held ~= math.floor(held) or remaining == nil or remaining <= 0 then
              fallback_valid = false; break
            end
            groups[#groups + 1] = {
              id = { "need", row.qid, "legacy", need.id }, qid = row.qid,
              task_index = row.task_index, remaining = remaining,
              options = { { item_id = need.id, accepted_count = need.num } },
              complete = true, generation = state.generation, status = "eligible",
            }
          end
        end
        if not fallback_valid then break end
      end
    end
    if not fallback_valid or (#state.records > 0 and #records == 0 and #groups == 0) then
      return { status = "unknown", complete = false, groups = {},
        generation = task_snapshot.need_generation,
        source_generation = state.generation, reason = "current_task_ownership_unproven" }
    end
    table.sort(groups, function(left, right)
      if left.qid ~= right.qid then return left.qid < right.qid end
      if left.task_index ~= right.task_index then return left.task_index < right.task_index end
      local li = left.options[1] and left.options[1].item_id or 0
      local ri = right.options[1] and right.options[1].item_id or 0
      return li < ri
    end)
    local held, held_carried = {}, {}
    for item_id, count in pairs(state.held or {}) do held[item_id] = count end
    for item_id, count in pairs(state.held_carried or {}) do held_carried[item_id] = count end
    local checklist_ids = {}
    for _, row in ipairs(task_snapshot.quests) do
      for _, owner in ipairs(type(row) == "table" and type(row.item_ownership) == "table"
          and row.item_ownership or {}) do
        if type(owner) == "table" and owner.proof_kind == "delivery"
            and type(owner.delivery) == "table" then
          local selected = type(owner.delivery.group_id) == "number"
            and owner.delivery.group_id >= 0 and owner.delivery.group_id == math.floor(owner.delivery.group_id)
            and owner.delivery.group_id or nil
          for _, ref in ipairs(type(owner.delivery.groups) == "table"
              and owner.delivery.groups or {}) do
            local delivery = type(ref) == "table" and ref.delivery or nil
            for _, group in ipairs(type(delivery) == "table"
                and type(delivery.groups) == "table" and delivery.groups or {}) do
              if type(group) == "table" and (selected == nil or group.index == selected) then
                for _, item_id in ipairs(type(group.item_ids) == "table" and group.item_ids or {}) do
                  if type(item_id) == "number" and item_id > 0
                      and item_id == math.floor(item_id) then checklist_ids[item_id] = true end
                end
              end
            end
          end
        end
      end
    end
    local checklist_list = {}
    for item_id in pairs(checklist_ids) do checklist_list[#checklist_list + 1] = item_id end
    table.sort(checklist_list)
    if #checklist_list > 0 then
      local parts = {}
      for i, item_id in ipairs(checklist_list) do parts[i] = tostring(item_id) end
      local signature = table.concat(parts, ",")
      local extra = items.objective_checklist_held_state
      if type(extra) ~= "table" or extra.generation ~= state.generation
          or extra.signature ~= signature then
        local extra_held, skipped, complete, extra_carried = items.read_held(checklist_ids)
        extra = { generation = state.generation, signature = signature,
          held = type(extra_held) == "table" and extra_held or {},
          held_carried = type(extra_carried) == "table" and extra_carried or {},
          complete = type(extra_held) == "table" and complete == true and skipped == 0 }
        items.objective_checklist_held_state = extra
      end
      if not extra.complete then
        return { status = "unknown", complete = false, groups = {},
          generation = task_snapshot.need_generation,
          source_generation = state.generation, reason = "checklist_held_unreadable" }
      end
      for item_id, count in pairs(extra.held) do held[item_id] = count end
      for item_id, count in pairs(extra.held_carried) do held_carried[item_id] = count end
    end
    return { status = "ok", complete = true, groups = groups, held = held,
      held_carried = held_carried,
      generation = task_snapshot.need_generation, source_generation = state.generation,
      task_generation = state.task_generation }
  end
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
  function a.filter_access_targets(targets)
    return items.filter_access_targets(targets)
  end
  function a.filter_placed_provider_snapshot(provider)
    return items.filter_placed_provider_snapshot(provider)
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
      if not active_ok then
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
    local function managed_type_name(object)
      local ok, name = pcall(function()
        return object:get_type_definition():get_full_name()
      end)
      if not ok then return nil, false end
      return type(name) == "string" and name or nil, true
    end
    local function native_guidance_cid(destination)
      local ok, value = pcall(function() return destination:call("get_CharaID") end)
      if not ok then return nil, false end
      local cid = int_value(value)
      -- The extractor normalizes the CharacterID enum's Invalid and player
      -- sentinels to no character; the live join must use the same identity.
      if cid == 0 or cid == 1857826560 or cid == 2891076981 then return nil, true end
      return cid, true
    end
    local function native_guidance_place(destination)
      local guidance_ok, guidance = pcall(function() return destination:get_field("_GuidancePos") end)
      if not guidance_ok then return nil, false end
      local guidance_kind, kind_readable
      if guidance ~= nil then guidance_kind, kind_readable = managed_type_name(guidance) end
      if guidance ~= nil and not kind_readable then return nil, false end
      if guidance_kind == "app.ClassSelector`1<app.GuidanceData>" then
        local process_ok
        process_ok, guidance = pcall(function() return guidance:get_field("_Process") end)
        if not process_ok then return nil, false end
      end
      local kind, readable = nil, true
      if guidance ~= nil then kind, readable = managed_type_name(guidance) end
      if not readable then return nil, false end
      if kind == "app.GuidanceKeyLocation" then
        local ok, value = pcall(function() return guidance:get_field("_KeyLocation") end)
        if not ok then return nil, false end
        local key = int_value(value)
        return type(key) == "number" and key > 0
          and { kind = "key_location", key = key } or nil, true
      elseif kind == "app.GuidanceLocalArea" then
        local ok, value = pcall(function() return guidance:get_field("LocalArea") end)
        if not ok then return nil, false end
        local local_area = int_value(value)
        return type(local_area) == "number" and local_area >= 0
          and { kind = "local_area", local_area = local_area } or nil, true
      end
      local key_ok, key_value = pcall(function() return destination:call("get_KeyLocation") end)
      if not key_ok then return nil, false end
      local key = int_value(key_value)
      if type(key) == "number" and key > 0 then
        return { kind = "key_location", key = key }, true
      end
      local area_ok, area_value = pcall(function() return destination:call("get_LocalArea") end)
      if not area_ok then return nil, false end
      local local_area = int_value(area_value)
      if type(local_area) == "number" and local_area >= 0 then
        return { kind = "local_area", local_area = local_area }, true
      end
      return nil, true
    end
    local function native_item_condition_owner(parsed_conditions, destination, qid)
      if type(parsed_conditions) ~= "table" then return nil end
      local parsed, parsed_index
      local function has_nested_item(value)
        if type(value) ~= "table" then return false end
        if value.kind == "item" then return true end
        for _, child in ipairs(value.children or {}) do
          if has_nested_item(child) then return true end
        end
        return false
      end
      for index, condition in ipairs(parsed_conditions) do
        if type(condition) == "table" and condition.kind == "item" then
          if parsed ~= nil then return nil end
          parsed, parsed_index = condition, index
        elseif has_nested_item(condition) then
          return nil
        end
      end
      if parsed == nil then return nil end
      local owner = {
        item_id = type(parsed.item_id) == "number" and parsed.item_id or nil,
        count = parsed.set_num == true and type(parsed.num) == "number" and parsed.num or 1,
        proof_kind = "condition", eligibility = "unknown",
        reason = "native_item_condition_leaf_unread" }
      if type(parsed.enabled) ~= "boolean" or type(parsed.is_not) ~= "boolean"
          or type(parsed.set_num) ~= "boolean" or type(parsed.num) ~= "number"
          or owner.item_id == nil then return owner end
      local native_rows, readable, truncated = list(safe_field(destination, "_Conditions"), 64)
      if not readable then
        owner.reason = truncated and "native_item_condition_list_truncated"
          or "native_item_condition_list_unreadable"
        return owner
      end
      if #native_rows ~= #parsed_conditions then
        owner.reason = "native_item_condition_list_mismatch"; return owner
      end
      local selector = native_rows[parsed_index]
      if managed_type_name(selector) ~= "app.ClassSelector`1<app.ConciergeConditionBase>" then
        owner.reason = "native_item_condition_selector_mismatch"; return owner
      end
      local process = safe_field(selector, "_Process")
      if managed_type_name(process) ~= "app.ConciergeConditionItem" then
        owner.reason = "native_item_condition_process_mismatch"; return owner
      end
      local item_id = int_value(safe_field(process, "_ItemID"))
      local set_num = safe_field(process, "_SetNum")
      local num = int_value(safe_field(process, "_Num"))
      local enabled = safe_field(process, "_IsEnabled")
      local is_not = safe_field(process, "_IsNot")
      if item_id ~= parsed.item_id or set_num ~= parsed.set_num or num ~= parsed.num
          or enabled ~= parsed.enabled or is_not ~= parsed.is_not then
        owner.reason = "native_item_condition_catalog_mismatch"; return owner
      end
      if not enabled then
        owner.eligibility, owner.reason = "ineligible", "native_item_condition_disabled"
        return owner
      end
      if not is_not then
        owner.eligibility, owner.reason = "ineligible", "native_item_condition_not_missing"
        return owner
      end
      local evaluate_ok, evaluated = pcall(function() return process:call("evaluate", qid) end)
      if not evaluate_ok or type(evaluated) ~= "boolean" then
        owner.reason = evaluate_ok and "native_item_condition_result_unreadable"
          or "native_item_condition_evaluate_exception"
      elseif evaluated then
        owner.eligibility, owner.reason = "eligible", nil
      else
        owner.eligibility, owner.reason = "ineligible", "native_item_condition_false"
      end
      return owner
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
      if not active_ok then
        result.reason = "destination_active_list_unreadable"; return result
      end
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
        local resource = journal.catalog_resource(qlm, qid)
        local raw_records = resource ~= nil and safe_field(resource, "_ConciergeList") or nil
        local concierge_records, records_readable = list(raw_records, 256)
        if resource == nil then records_readable = false end
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
            if not record_index_valid then
              out.eligibility, out.reason = "unknown", "concierge_record_index_invalid"
            elseif resource == nil then
              out.eligibility, out.reason = "unknown", "concierge_catalog_resource_unavailable"
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
                  local native_cid, cid_readable = native_guidance_cid(native)
                  local target
                  local native_place, place_readable = native_guidance_place(native)
                  local parsed_cid, parsed_place = concierge_identity(parsed)
                  local place_ok = parsed_place == nil and native_place == nil
                    or (type(parsed_place) == "table" and type(native_place) == "table"
                      and parsed_place.kind == native_place.kind
                      and ((parsed_place.kind == "key_location"
                          and parsed_place.key == native_place.key)
                        or (parsed_place.kind == "local_area"
                          and parsed_place.local_area == native_place.local_area)))
                  target = { cid = parsed_cid,
                    place = parsed_place, pos = position(safe_call(native, "getDestination")) }
                  if target.pos == nil and target.cid ~= nil then
                    local x, y, z = objective_pos(target.cid)
                    if x ~= nil then target.pos = { x = x, y = y, z = z } end
                  end
                  if not cid_readable or not place_readable then
                    destination_reason = "concierge_destination_identity_unreadable"
                  elseif parsed_cid ~= native_cid or not place_ok then
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
                    local condition_owner = native_item_condition_owner(parsed.conditions, native, qid)
                    if condition_owner ~= nil then
                      condition_owner.task_index = ti
                      condition_owner.concierge_index = g.index
                      condition_owner.destination_index = parsed.index
                      result.item_ownership[#result.item_ownership + 1] = condition_owner
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
      A.invalidate_objective_provider_catalogs()
      items.reset_task_observations()
      objective_task_state.owner = qlm
      objective_task_state.focus, objective_task_state.journal, objective_task_state.needs = nil, nil, nil
      objective_task_state.focus_epoch, objective_task_state.journal_generation,
        objective_task_state.need_generation = 0, 0, 0
      objective_task_state.source_catalog, objective_task_state.source_observation = nil, nil
      objective_task_state.source_need_generation = nil
      objective_task_state.filtered_source_owner = nil
      objective_task_state.filtered_source_signature = nil
      objective_task_state.filtered_source_catalog = nil
      objective_task_state.source_generation = objective_task_state.source_generation + 1
      objective_task_state.talk_observation, objective_task_state.forgery_observation = nil, nil
      objective_task_state.talk_at, objective_task_state.forgery_at = -math.huge, -math.huge
      objective_task_state.talk_generation = objective_task_state.talk_generation + 1
      objective_task_state.forgery_generation = objective_task_state.forgery_generation + 1
      if objective_task_state.reward_observation ~= nil then
        objective_task_state.reward_observation.owner = nil
        objective_task_state.reward_observation.signature = nil
        objective_task_state.reward_observation.data = nil
      end
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
      items.observe_task_index(qid,
        row.read_status == "ok" and type(row.task_index) == "number" and row.task_index or nil)
      quests[#quests + 1] = row
      local journal_row = clone(row)
      journal_row.item_ownership = {}
      journal_rows[#journal_rows + 1] = journal_row
      local objective_groups, objective_status = {}, "unknown"
      if ITEM_STATS.needs_fresh and items.objective_group_state.complete
          and (items.objective_group_state.task_versions
              and items.objective_group_state.task_versions[qid] or 0)
            == (items.task_observation_versions[qid] or 0)
          and row.read_status == "ok"
          and row.task_index == items.objective_group_state.task_index[qid] then
        objective_status = "ok"
        for _, group in ipairs(items.objective_group_state.groups) do
          if group.qid == qid and group.task_index == row.task_index then
            objective_groups[#objective_groups + 1] = clone(group)
          end
        end
      end
      need_rows[qid] = { status = (ITEM_NEEDS == nil or not ITEM_STATS.needs_fresh) and "unknown" or "ok",
        current = clone(ITEM_STATS.needs_fresh and ITEM_NEEDS and ITEM_NEEDS[qid] or {}),
        objective = { status = objective_status, groups = objective_groups },
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
  function a.objective_item_source_snapshots(objective_catalog, task_snapshot,
      source_catalog, supplied_source_observation, supplied_provider_observations)
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
    local extension = type(objective_catalog) == "table" and objective_catalog.version == 2
      and objective_catalog or nil
    local catalog = extension and extension.quests or nil
    for _, source in ipairs(type(extension) == "table" and extension.sources or {}) do
      descriptors[#descriptors + 1] = { source = source }
    end
    if type(catalog) == "table" then
      local qids = {}
      for qid in pairs(catalog) do qids[#qids + 1] = qid end
      table.sort(qids)
      for _, qid in ipairs(qids) do
        local quest = catalog[qid]
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
    local function same(x, y)
      if type(x) ~= type(y) then return false end
      if type(x) ~= "table" then return x == y end
      for k, v in pairs(x) do if not same(v, y[k]) then return false end end
      for k in pairs(y) do if x[k] == nil then return false end end
      return true
    end
    local need_snapshot = a.objective_need_groups(task_snapshot)
    local wanted = nil
    if need_snapshot.complete then
      wanted = {}
      for _, group in ipairs(need_snapshot.groups) do
        for _, option in ipairs(group.options) do wanted[option.item_id] = true end
      end
    end
    local wanted_list = {}
    if wanted ~= nil then
      for item_id in pairs(wanted) do wanted_list[#wanted_list + 1] = item_id end
      table.sort(wanted_list)
    end
    local wanted_signature = wanted ~= nil and table.concat(wanted_list, ",") or nil
    local scan_catalog = source_catalog
    local source_catalog_is_filtered = wanted ~= nil and type(source_catalog) == "table"
    if source_catalog_is_filtered then
      if objective_task_state.filtered_source_owner == source_catalog
          and objective_task_state.filtered_source_signature == wanted_signature then
        scan_catalog = objective_task_state.filtered_source_catalog
      else
        scan_catalog = {}
        for key, value in pairs(source_catalog) do
          if key ~= "placements" and key ~= "chests" then scan_catalog[key] = copy(value) end
        end
        local function matching_rows(rows)
          local out = {}
          for _, row in ipairs(type(rows) == "table" and rows or {}) do
            local matches = false
            for _, output in ipairs(type(row) == "table" and row.outputs or {}) do
              if wanted[output.item_id] then matches = true; break end
            end
            if matches then out[#out + 1] = copy(row) end
          end
          return out
        end
        scan_catalog.placements = matching_rows(source_catalog.placements)
        scan_catalog.chests = matching_rows(source_catalog.chests)
        objective_task_state.filtered_source_owner = source_catalog
        objective_task_state.filtered_source_signature = wanted_signature
        objective_task_state.filtered_source_catalog = scan_catalog
      end
    end
    local function source_catalog_matches()
      return objective_task_state.source_catalog == scan_catalog
    end
    local now = os.clock()
    local observation = supplied_source_observation
    if observation == nil and type(scan_catalog) == "table" then
      if source_catalog_matches()
          and objective_task_state.source_need_generation == generation
          and objective_task_state.source_observation ~= nil
      then
        observation = objective_task_state.source_observation
      else
        observation = A.read_objective_source_observation(scan_catalog)
      end
    end
    if not source_catalog_matches()
        or not same(objective_task_state.source_observation, observation) then
      if objective_task_state.source_catalog ~= nil
          or objective_task_state.source_observation ~= nil then
        objective_task_state.source_generation = math.min(2147483647,
          objective_task_state.source_generation + 1)
      end
      objective_task_state.source_catalog = scan_catalog
      objective_task_state.source_observation = copy(observation)
    end
    objective_task_state.source_need_generation = generation
    local providers = A.objective_source_provider_snapshots(scan_catalog, observation,
      objective_task_state.source_generation)
    for _, provider in ipairs(providers) do
      provider.catalog_version = version
      provider.source_catalog_version = type(source_catalog) == "table" and source_catalog.version or nil
      provider.source_descriptors = copy(descriptors)
      provider.signal_evidence = copy(signals)
      provider.guidance_delivery_refs = copy(deliveries)
    end
    local loot = copy(items.objective_loot_observations(wanted, generation))
    loot.catalog_version = version
    loot.source_descriptors = copy(descriptors)
    loot.signal_evidence = copy(signals)
    loot.guidance_delivery_refs = copy(deliveries)
    providers[#providers + 1] = loot
    local function provider_observation(kind)
      local state_key, generation_key, at_key, reader
      if kind == "talk_grant" then
        state_key, generation_key, at_key = "talk_observation", "talk_generation", "talk_at"
        reader = A.read_objective_talk_grant_observation
      else
        state_key, generation_key, at_key = "forgery_observation", "forgery_generation", "forgery_at"
        reader = A.read_objective_forgery_observation
      end
      local supplied = type(supplied_provider_observations) == "table"
        and supplied_provider_observations[kind] or nil
      local value = supplied
      if value == nil then
        local previous = objective_task_state[state_key]
        if wanted == nil then
          value = { complete = false, reason = "objective_need_snapshot_incomplete",
            wanted = {}, events = kind == "talk_grant" and {} or nil,
            services = kind == "forgery" and {} or nil,
            mappings = kind == "forgery" and {} or nil,
            order = kind == "forgery" and {} or nil }
        elseif previous ~= nil and same(previous.wanted, wanted_list)
            and now - objective_task_state[at_key] < 0.5 then
          value = previous
        elseif type(reader) == "function" then
          value = reader(wanted)
        else
          value = { complete = false, reason = kind .. "_observation_unavailable",
            wanted = copy(wanted_list) }
        end
      end
      if not same(objective_task_state[state_key], value) then
        if objective_task_state[state_key] ~= nil then
          objective_task_state[generation_key] = math.min(2147483647,
            objective_task_state[generation_key] + 1)
        end
        objective_task_state[state_key] = copy(value)
      end
      objective_task_state[at_key] = now
      return value, objective_task_state[generation_key]
    end
    local talk_observation, talk_generation = provider_observation("talk_grant")
    local forgery_observation, forgery_generation = provider_observation("forgery")
    local talk = A.objective_talk_grant_provider_snapshot(talk_observation, talk_generation)
    local forgery = A.objective_forgery_provider_snapshot(forgery_observation, forgery_generation)
    -- Quest reward diagnostics are joined to the live RewardDict and processor
    -- list only to explain possible outputs. The task endpoint, branch truth,
    -- and claim state are not observable here, so this provider never emits a
    -- candidate (SPEC 22.9.5). Cache this bounded join so the map path cannot
    -- walk hundreds of managed rows every frame.
    local signature_parts = { tostring(type(task_snapshot) == "table" and task_snapshot.focus_epoch or 0),
      tostring(type(task_snapshot) == "table" and task_snapshot.need_generation or 0),
      tostring(version), tostring(extension), wanted == nil and "needs:unknown" or "needs:complete" }
    for _, quest in ipairs(type(task_snapshot) == "table" and task_snapshot.quests or {}) do
      if type(quest) == "table" then
        signature_parts[#signature_parts + 1] = tostring(quest.qid) .. ":"
          .. tostring(quest.task_index) .. ":" .. tostring(quest.read_status)
      end
    end
    local wanted_ids = {}
    for item_id in pairs(wanted or {}) do wanted_ids[#wanted_ids + 1] = item_id end
    table.sort(wanted_ids)
    for _, item_id in ipairs(wanted_ids) do signature_parts[#signature_parts + 1] = tostring(item_id) end
    local reward_signature = table.concat(signature_parts, "|")
    local function same_plain(left, right)
      if type(left) ~= type(right) then return false end
      if type(left) ~= "table" then return left == right end
      for key, value in pairs(left) do if not same_plain(value, right[key]) then return false end end
      for key in pairs(right) do if left[key] == nil then return false end end
      return true
    end
    local reward_observation = objective_task_state.reward_observation
    local reward_now = os.clock()
    local reward_key_changed = reward_observation ~= nil
      and (reward_observation.owner ~= objective_task_state.owner
        or reward_observation.signature ~= reward_signature)
    local reward_refresh_due = reward_observation == nil or reward_now - reward_observation.at >= 0.5
    local reward_refresh_pending = reward_key_changed and not reward_refresh_due
    if reward_refresh_due then
      local function scan_reward_sources()
        local reward_outputs, reward_runtime, reward_rows = {}, {}, {}
        local reward_complete = true
        local function bounded_elements(array, cap)
          local ok, values = pcall(function() return array:get_elements() end)
          if not ok or values == nil then return nil end
          local count_ok, count = pcall(function() return #values end)
          if not count_ok or type(count) ~= "number" or count < 0 or count > cap then return nil end
          local out = {}
          for i = 1, count do
            local row_ok, row = pcall(function() return values[i] end)
            if not row_ok or row == nil then return nil end
            out[i] = row
          end
          return out
        end
        local qm = nil
        pcall(function() qm = sdk.get_managed_singleton("app.QuestManager") end)
        local reward_dict = safe_field(qm, "RewardDict")
        local dict_entries = bounded_elements(safe_field(reward_dict, "_entries"), 512)
        local dict_count = A.count_of(int_value(safe_call(reward_dict, "get_Count")))
        local dict_used = A.count_of(int_value(safe_field(reward_dict, "_count")))
        local dict_free = A.count_of(int_value(safe_field(reward_dict, "_freeCount")))
        if dict_entries == nil or dict_count == nil or dict_used == nil or dict_free == nil
            or dict_used > #dict_entries or dict_used > 512
            or dict_count + dict_free ~= dict_used then
          reward_complete = false
        else
          local active, free = 0, 0
          for i = 1, dict_used do
            local entry = dict_entries[i]
            local next_slot = int_value(safe_field(entry, "next") or safe_field(entry, "Next"))
            if next_slot == nil or math.tointeger(next_slot) ~= next_slot then
              reward_complete = false
            elseif next_slot < -1 then
              free = free + 1
            else
              active = active + 1
              local hash = int_value(safe_field(entry, "key") or safe_field(entry, "Key"))
              local reward = safe_field(entry, "value") or safe_field(entry, "Value")
              local rows = bounded_elements(safe_field(reward, "_ItemList"), 32)
            if type(hash) ~= "number" or math.tointeger(hash) ~= hash
                or hash < 0 or hash > 4294967295 or rows == nil
                or reward_outputs[hash] ~= nil then
                reward_complete = false
              else
                local outputs = {}
                for _, row in ipairs(rows) do
                  local item_id, count = int_value(safe_field(row, "_ItemId")),
                    int_value(safe_field(row, "_Num"))
                  if type(item_id) ~= "number" or math.tointeger(item_id) ~= item_id or item_id <= 0
                      or type(count) ~= "number" or math.tointeger(count) ~= count or count <= 0 then
                    reward_complete = false
                  else
                    outputs[#outputs + 1] = { item_id = item_id, count = count }
                  end
                end
                reward_outputs[hash] = outputs
              end
            end
          end
          if active ~= dict_count or free ~= dict_free then reward_complete = false end
        end
        local processors = bounded_elements(safe_field(qm, "DistributedQuestProcessors"), 512)
        if processors == nil then reward_complete = false else
          for _, processor in ipairs(processors) do
            local proc_id = int_value(safe_field(processor, "ProcID"))
            if proc_id ~= nil and math.tointeger(proc_id) == proc_id
                and proc_id >= 0 and proc_id <= 4294967295 and reward_runtime[proc_id] == nil then
              local process = safe_field(processor, "Process")
              local action = safe_field(process, "QuestAction")
              local action_type = nil
              pcall(function()
                local definition = action and action:get_type_definition() or nil
                action_type = definition and definition:get_full_name() or nil
              end)
              reward_runtime[proc_id] = { qid = int_value(safe_call(process, "get_QuestID")),
                action_type = action_type, executed = safe_call(process, "get_Executed"),
                canceled = safe_call(process, "get_Canceled") }
            else
              reward_complete = false
            end
          end
        end
        local focus_qids = {}
        for _, quest in ipairs(type(task_snapshot) == "table" and task_snapshot.quests or {}) do
          if type(quest) == "table" and type(quest.qid) == "number" then focus_qids[quest.qid] = true end
        end
        local reward_catalog = type(extension) == "table" and extension.quests or nil
        if type(reward_catalog) == "table" then
          for qid, quest in pairs(reward_catalog) do
            for _, diagnostic in ipairs(type(quest) == "table" and quest.reward_diagnostics or {}) do
              if type(diagnostic) == "table" then
                local identity = diagnostic.source_identity
                local proc_id = type(identity) == "table" and identity.processor_id or nil
                local runtime = type(proc_id) == "number" and reward_runtime[proc_id] or nil
                local relevant, mapped = false, {}
                for _, reward_row in ipairs(type(diagnostic.reward_rows) == "table"
                    and diagnostic.reward_rows or {}) do
                  local outputs = type(reward_row) == "table"
                    and reward_outputs[reward_row.name_hash] or nil
                  for _, output in ipairs(outputs or {}) do
                    if wanted and wanted[output.item_id] then
                      relevant = true
                      mapped[#mapped + 1] = { item_id = output.item_id, count = output.count }
                    end
                  end
                end
                if focus_qids[qid] or relevant then
                  local detail = { qid = qid, action_ordinal = identity
                    and identity.action_ordinal or nil, processor_id = proc_id,
                    processor_present = runtime ~= nil,
                    runtime_qid = runtime and runtime.qid or nil,
                    runtime_action_type = runtime and runtime.action_type or nil,
                    focused_quest = focus_qids[qid] == true,
                    outputs = mapped, branch_status = diagnostic.branch_status,
                    task_endpoint_join = copy(diagnostic.task_endpoint_join),
                    unresolved_joins = copy(diagnostic.unresolved_joins), eligibility = "unknown" }
                  if runtime ~= nil then
                    detail.runtime_executed, detail.runtime_canceled = runtime.executed, runtime.canceled
                  end
                  reward_rows[#reward_rows + 1] = detail
                end
              end
            end
          end
        end
        return { complete = reward_complete, rows = reward_rows }
      end
      local observed = scan_reward_sources()
      local observed_at = os.clock()
      local changed = reward_observation == nil or reward_observation.owner ~= objective_task_state.owner
        or reward_observation.signature ~= reward_signature
        or not same_plain(reward_observation.data, observed)
      reward_observation = { owner = objective_task_state.owner, signature = reward_signature,
        at = observed_at, generation = changed and ((reward_observation and reward_observation.generation or 0) + 1)
          or reward_observation.generation, data = observed }
      objective_task_state.reward_observation = reward_observation
    end
    local reward_data = reward_refresh_pending and { complete = false, rows = {} }
      or (reward_observation and reward_observation.data or { complete = false, rows = {} })
    providers[#providers + 1] = { provider = "reward", generation = reward_observation.generation,
      status = "unknown", complete = false,
      reason = reward_refresh_pending and "reward_snapshot_refresh_pending"
        or (not reward_data.complete and "reward_runtime_scan_incomplete")
        or (wanted == nil and "reward_current_need_set_unproven"
          or "reward_task_branch_and_claim_gates_unproven"),
      missing_evidence = { "journal_task_to_reward_endpoint", "current_branch_truth",
        "claim_state", "reward_action_to_drawable_target" },
      candidates = {}, diagnostic_rows = copy(reward_data.rows),
      reward_runtime_complete = reward_data.complete,
      focused_item_count = wanted and (function()
        local count = 0; for _ in pairs(wanted) do count = count + 1 end; return count
      end)() or 0, catalog_version = version }
    for _, provider in ipairs({ talk, forgery }) do
      provider.catalog_version = version
      provider.source_descriptors = copy(descriptors)
      provider.signal_evidence = copy(signals)
      provider.guidance_delivery_refs = copy(deliveries)
      providers[#providers + 1] = provider
    end
    providers[1] = items.filter_placed_provider_snapshot(providers[1])
    return providers
  end
  -- Pure classification for synthetic/research evidence only. The live service,
  -- mapping, target and order-state join is not proved, so this deliberately
  -- cannot satisfy core's normalized provider/candidate contract.
  function a.objective_forgery_evidence(evidence, generation)
    local used_generation = generation == nil and objective_task_state.source_generation or generation
    local out = { evidence_only = true, publication_ready = false,
      evidence_generation = used_generation, eligibility = "unknown",
      reason = "forgery_evidence_malformed" }
    local function finite(v)
      return type(v) == "number" and v == v and v > -math.huge and v < math.huge
    end
    local function integer(v, minimum)
      return finite(v) and v == math.floor(v) and v >= minimum
    end
    local function result(eligibility, reason)
      out.eligibility, out.reason = eligibility, reason
      return out
    end
    if not integer(used_generation, 1) then
      return result("unknown", "forgery_generation_invalid")
    end
    if type(evidence) ~= "table" then return out end
    local id, pos = evidence.identity, evidence.service_position
    local service, output = evidence.service_id, evidence.output_item_id
    if type(id) ~= "table" or id[1] ~= "source" or id[2] ~= "forgery"
      or not integer(service, 1) or not integer(output, 1)
      or not integer(evidence.mapping_input_item_id, 1)
      or not integer(evidence.mapping_output_item_id, 1)
      or evidence.mapping_output_item_id ~= output
      or id[3] ~= service or id[4] ~= output or id[5] ~= nil
      or evidence.service_type ~= "NpcShopForgeryParam"
      or type(pos) ~= "table" or not finite(pos.x) or not finite(pos.y) or not finite(pos.z)
      or not integer(evidence.kept_item_id, 0) or not integer(evidence.kept_item_count, 0)
      or not integer(evidence.mapping_price, 1)
      or (evidence.price ~= nil and not integer(evidence.price, 1)) then return out end
    if type(evidence.row_enabled) ~= "boolean" then
      return result("unknown", "forgery_mapping_state_unreadable")
    elseif evidence.row_enabled == false then
      return result("ineligible", "forgery_mapping_disabled")
    end
    if type(evidence.interactable) ~= "boolean" then
      return result("unknown", "forgery_interaction_state_unreadable")
    elseif evidence.interactable == false then
      return result("ineligible", "forgery_service_not_interactable")
    end
    if evidence.busy_readable ~= true then
      return result("unknown", "forgery_busy_state_unreadable")
    elseif evidence.kept_readable ~= true then
      return result("unknown", "forgery_kept_item_unreadable")
    elseif evidence.completion_time_readable ~= true then
      return result("unknown", "forgery_completion_time_unreadable")
    elseif evidence.completion_readable ~= true then
      return result("unknown", "forgery_completion_state_unreadable")
    elseif not finite(evidence.completion_time) or evidence.completion_time < 0
      or type(evidence.completed) ~= "boolean" or type(evidence.busy) ~= "boolean" then
      return out
    end
    if evidence.completed then
      if evidence.kept_item_count <= 0 then
        return result("ineligible", "forgery_order_not_ready")
      elseif evidence.kept_item_id == output then
        return result("eligible", "matching_forgery_output_ready")
      end
      return result("ineligible", "forgery_order_unrelated")
    elseif evidence.busy then
      if evidence.kept_item_count <= 0 or evidence.kept_item_id == 0 then
        return result("unknown", "forgery_pending_order_identity_unproven")
      elseif evidence.kept_item_id ~= evidence.mapping_input_item_id then
        return result("ineligible", "forgery_order_unrelated")
      end
      return result("ineligible", "forgery_order_pending")
    elseif evidence.idle ~= true or evidence.kept_item_id ~= 0
        or evidence.kept_item_count ~= 0 then
      if type(evidence.idle) ~= "boolean" then
        return result("unknown", "forgery_idle_state_unreadable")
      end
      return result("ineligible", "forgery_order_not_ready")
    end
    if evidence.price == nil or evidence.price ~= evidence.mapping_price
      or type(evidence.input_held) ~= "boolean"
      or type(evidence.price_held) ~= "boolean" then
      return result("unknown", "forgery_preorder_evidence_unreadable")
    elseif evidence.input_held == false then
      return result("ineligible", "forgery_input_not_held")
    elseif evidence.price_held == false then
      return result("ineligible", "forgery_price_unaffordable")
    end
    return result("eligible", "forgery_order_can_start")
  end
  function a.reset_session_caches()
    local qlm = sdk.get_managed_singleton("app.QuestLogManager")
    if qlm ~= QUEST_SESSION_OWNER then
      QUEST_SESSION_OWNER = qlm
      A.invalidate_objective_provider_catalogs()
      reset_runtime_caches()
      items.reset_task_observations()
      objective_task_state.owner = qlm
      objective_task_state.focus, objective_task_state.journal, objective_task_state.needs = nil, nil, nil
      objective_task_state.focus_epoch, objective_task_state.journal_generation,
        objective_task_state.need_generation = 0, 0, 0
      objective_task_state.source_catalog, objective_task_state.source_observation = nil, nil
      objective_task_state.source_need_generation = nil
      objective_task_state.filtered_source_owner = nil
      objective_task_state.filtered_source_signature = nil
      objective_task_state.filtered_source_catalog = nil
      objective_task_state.source_generation = objective_task_state.source_generation + 1
      objective_task_state.talk_observation, objective_task_state.forgery_observation = nil, nil
      objective_task_state.talk_at, objective_task_state.forgery_at = -math.huge, -math.huge
      objective_task_state.talk_generation = objective_task_state.talk_generation + 1
      objective_task_state.forgery_generation = objective_task_state.forgery_generation + 1
      if objective_task_state.reward_observation ~= nil then
        objective_task_state.reward_observation.owner = nil
        objective_task_state.reward_observation.signature = nil
        objective_task_state.reward_observation.data = nil
      end
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
