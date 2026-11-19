------------------------------------------------------------
-- LegacyData - what the Legacy plugin knows before the client answers (#373)
--
-- Only what the client cannot say without parsing localized text: which
-- achievement is which class or craft milestone, and at what threshold. The
-- challenges themselves (names, completion, criteria, points) are discovered
-- live, as Blizzard's own Legacy window does (forever-api-notes.md, "Legacy
-- Challenges"), so a challenge a patch adds still shows - under Other when no
-- section here claims its category.
--
-- GRID is generated from forever-achievement-1.60.1.70959.csv (wago.tools):
-- the achievements rewarding "Earn 1 Legacy Point." in the class (15577-15585)
-- and craft (15587-15592) categories, threshold from the description. Each
-- milestone exists twice: set A (flag 0x8000000) is what the client lists on
-- the Normal realms (measured 70959); set B (0x10000000) resolves by ID but is
-- worth no points there, and is presumably Hardcore's.
--   GRID[achievementID] = { kind, class token or craft name, threshold, set }
------------------------------------------------------------

-- Shared with AltStableLegacy.lua through the core's table, as the Roster's
-- files share theirs (a file loaded without the addon's arguments, as the
-- tests load them, still finds it).
local D = {}
AltStable.LegacyData = D

D.FACTION  = 2802   -- the Legacy Track: its renown level is the points earned
D.CURRENCY = 4225   -- Legacy Points: GetTraitCurrencyForAchievement, the max
D.EXPLORE_AZEROTH = 62053   -- Explorer's one criterion; per character

-- The rows of the two grids, in the game's order.
D.CLASSES = { "DRUID", "HUNTER", "MAGE", "PALADIN", "PRIEST", "ROGUE", "SHAMAN", "WARLOCK", "WARRIOR" }
D.CLASS_NAMES = {
    DRUID = "Druid", HUNTER = "Hunter", MAGE = "Mage", PALADIN = "Paladin", PRIEST = "Priest",
    ROGUE = "Rogue", SHAMAN = "Shaman", WARLOCK = "Warlock", WARRIOR = "Warrior",
}
D.CRAFTS = { "Alchemy", "Blacksmithing", "Enchanting", "Engineering", "Leatherworking", "Tailoring" }
-- "No known <noun>", the word for one who practises it.
D.CRAFT_NOUNS = {
    Alchemy = "alchemist", Blacksmithing = "smith", Enchanting = "enchanter",
    Engineering = "engineer", Leatherworking = "leatherworker", Tailoring = "tailor",
}
D.CRAFT_ICONS = {
    Alchemy = "Interface\\Icons\\Trade_Alchemy", Blacksmithing = "Interface\\Icons\\Trade_BlackSmithing",
    Enchanting = "Interface\\Icons\\Trade_Engraving", Engineering = "Interface\\Icons\\Trade_Engineering",
    Leatherworking = "Interface\\Icons\\Trade_LeatherWorking", Tailoring = "Interface\\Icons\\Trade_Tailoring",
}
D.TIERS = { class = { 25, 45, 60 }, craft = { 150, 225, 300 } }

-- The checklist sections under the grids, by the client's category IDs
-- (measured 70959). A listed challenge in none of these, and not in GRID,
-- goes to Other.
D.SECTIONS = {
    { key = "dungeons",  label = "Dungeons",         cats = { [15593] = true } },
    { key = "raids",     label = "Raids",            cats = { [15594] = true } },
    { key = "pvp",       label = "Player vs. Player", cats = { [15597] = true, [15598] = true, [15620] = true } },
    { key = "adventure", label = "Adventure",        cats = { [15596] = true } },
    { key = "other",     label = "Other",            cats = {} },
}

D.GRID = {
    -- Set A
    [61502] = { "class", "DRUID", 25, "A" },
    [61503] = { "class", "DRUID", 45, "A" },
    [61504] = { "class", "DRUID", 60, "A" },
    [61989] = { "class", "HUNTER", 25, "A" },
    [61992] = { "class", "HUNTER", 45, "A" },
    [61993] = { "class", "HUNTER", 60, "A" },
    [61994] = { "class", "MAGE", 25, "A" },
    [61995] = { "class", "MAGE", 45, "A" },
    [61996] = { "class", "MAGE", 60, "A" },
    [61997] = { "class", "PALADIN", 25, "A" },
    [61998] = { "class", "PALADIN", 45, "A" },
    [61999] = { "class", "PALADIN", 60, "A" },
    [62000] = { "class", "PRIEST", 25, "A" },
    [62001] = { "class", "PRIEST", 45, "A" },
    [62002] = { "class", "PRIEST", 60, "A" },
    [62003] = { "class", "ROGUE", 25, "A" },
    [62004] = { "class", "ROGUE", 45, "A" },
    [62005] = { "class", "ROGUE", 60, "A" },
    [62006] = { "class", "SHAMAN", 25, "A" },
    [62007] = { "class", "SHAMAN", 45, "A" },
    [62008] = { "class", "SHAMAN", 60, "A" },
    [62009] = { "class", "WARLOCK", 25, "A" },
    [62010] = { "class", "WARLOCK", 45, "A" },
    [62011] = { "class", "WARLOCK", 60, "A" },
    [61499] = { "class", "WARRIOR", 25, "A" },
    [61500] = { "class", "WARRIOR", 45, "A" },
    [61501] = { "class", "WARRIOR", 60, "A" },
    [62012] = { "craft", "Alchemy", 150, "A" },
    [62013] = { "craft", "Alchemy", 225, "A" },
    [62014] = { "craft", "Alchemy", 300, "A" },
    [62015] = { "craft", "Blacksmithing", 150, "A" },
    [62016] = { "craft", "Blacksmithing", 225, "A" },
    [62017] = { "craft", "Blacksmithing", 300, "A" },
    [62018] = { "craft", "Enchanting", 150, "A" },
    [62019] = { "craft", "Enchanting", 225, "A" },
    [62020] = { "craft", "Enchanting", 300, "A" },
    [62021] = { "craft", "Engineering", 150, "A" },
    [62022] = { "craft", "Engineering", 225, "A" },
    [62023] = { "craft", "Engineering", 300, "A" },
    [62024] = { "craft", "Leatherworking", 150, "A" },
    [62025] = { "craft", "Leatherworking", 225, "A" },
    [62026] = { "craft", "Leatherworking", 300, "A" },
    [62028] = { "craft", "Tailoring", 150, "A" },
    [62029] = { "craft", "Tailoring", 225, "A" },
    [62030] = { "craft", "Tailoring", 300, "A" },
    -- Set B
    [63972] = { "class", "DRUID", 25, "B" },
    [63973] = { "class", "DRUID", 45, "B" },
    [63974] = { "class", "DRUID", 60, "B" },
    [63975] = { "class", "HUNTER", 25, "B" },
    [63976] = { "class", "HUNTER", 45, "B" },
    [63977] = { "class", "HUNTER", 60, "B" },
    [63978] = { "class", "MAGE", 25, "B" },
    [63979] = { "class", "MAGE", 45, "B" },
    [63980] = { "class", "MAGE", 60, "B" },
    [63981] = { "class", "PALADIN", 25, "B" },
    [63982] = { "class", "PALADIN", 45, "B" },
    [63983] = { "class", "PALADIN", 60, "B" },
    [63984] = { "class", "PRIEST", 25, "B" },
    [63985] = { "class", "PRIEST", 45, "B" },
    [63986] = { "class", "PRIEST", 60, "B" },
    [63987] = { "class", "ROGUE", 25, "B" },
    [63988] = { "class", "ROGUE", 45, "B" },
    [63989] = { "class", "ROGUE", 60, "B" },
    [63990] = { "class", "SHAMAN", 25, "B" },
    [63991] = { "class", "SHAMAN", 45, "B" },
    [63992] = { "class", "SHAMAN", 60, "B" },
    [63993] = { "class", "WARLOCK", 25, "B" },
    [63994] = { "class", "WARLOCK", 45, "B" },
    [63995] = { "class", "WARLOCK", 60, "B" },
    [63969] = { "class", "WARRIOR", 25, "B" },
    [63970] = { "class", "WARRIOR", 45, "B" },
    [63971] = { "class", "WARRIOR", 60, "B" },
    [63996] = { "craft", "Alchemy", 150, "B" },
    [63997] = { "craft", "Alchemy", 225, "B" },
    [63998] = { "craft", "Alchemy", 300, "B" },
    [63999] = { "craft", "Blacksmithing", 150, "B" },
    [64000] = { "craft", "Blacksmithing", 225, "B" },
    [64001] = { "craft", "Blacksmithing", 300, "B" },
    [64002] = { "craft", "Enchanting", 150, "B" },
    [64003] = { "craft", "Enchanting", 225, "B" },
    [64004] = { "craft", "Enchanting", 300, "B" },
    [64005] = { "craft", "Engineering", 150, "B" },
    [64006] = { "craft", "Engineering", 225, "B" },
    [64007] = { "craft", "Engineering", 300, "B" },
    [64008] = { "craft", "Leatherworking", 150, "B" },
    [64009] = { "craft", "Leatherworking", 225, "B" },
    [64010] = { "craft", "Leatherworking", 300, "B" },
    [64011] = { "craft", "Tailoring", 150, "B" },
    [64012] = { "craft", "Tailoring", 225, "B" },
    [64013] = { "craft", "Tailoring", 300, "B" },
}

