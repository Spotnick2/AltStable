-- Tools/QuestData/overrides.lua - hand-kept fixes on top of QuestieDB (#374)
--
-- SPDX-License-Identifier: GPL-3.0-or-later
-- Every line says why. The in-game per-zone check feeds this file: a zone that cannot reach
-- 100% for a character, or a quest that is not there, is fixed here, then the generator runs.

return {
    -- Level caps QuestieDB lacks (requiredMaxLevel). Past the cap, an undone quest is "missed".
    maxLevel = {
        [98895] = 39, -- Darkspear Islands Clash, the 30-39 bracket (Codex review, plan r5)
        [98897] = 49, -- Darkspear Islands Clash, the 40-49 bracket
    },

    -- Quests left out entirely (not in the game on Forever, though QuestieDB lists them).
    exclude = {
    },

    -- Instance area IDs that are raids. QuestieDB's dungeon table mixes dungeons, raids and
    -- battlegrounds; everything in it not listed here or in battlegrounds is a dungeon.
    raids = {
        [1977] = true, -- Zul'Gurub
        [2159] = true, -- Onyxia's Lair
        [2677] = true, -- Blackwing Lair
        [2717] = true, -- Molten Core
        [3428] = true, -- Temple of Ahn'Qiraj
        [3429] = true, -- Ruins of Ahn'Qiraj
        [3456] = true, -- Naxxramas
        [3606] = true, -- Hyjal Summit
    },

    -- Battleground area IDs (their quests go to the Battlegrounds group with sort -25).
    battlegrounds = {
        [2597] = true, -- Alterac Valley
        [3277] = true, -- Warsong Gulch
        [3358] = true, -- Arathi Basin
        [16606] = true, -- Darkspear Islands: a PvP instance like the two above (AreaTable map 2997,
                         -- instance type PvP in the 70888 Map table; Codex on #394)
    },

    -- Instances QuestieDB lists as dungeons that are places in a zone, and their continent.
    asZone = {
        [2257] = "EK", -- Deeprun Tram (its own continent 369 in the client), shown in Eastern Kingdoms
    },

    -- Areas whose quests are profession quests (their own row in Professions).
    professionAreas = {
        [16941] = true, -- Craftsman's Writs: QuestieDB has no skill or repeatable flag for them
    },

    -- Areas whose quests count only once done ("unsure"): QuestieDB can't say who can take
    -- them, or whether they can be done again. Zoneless quests (0) are always unsure.
    unsureAreas = {
        [16941] = true, -- Craftsman's Writs
    },

    -- Profile differences checked and accepted, so the report shows only new ones. These quests
    -- have a class-dependent follow-up (nextQuestInChain): harmless, since a follow-up can only
    -- be done after the quest, so the closure rule never fires wrongly.
    knownDifferences = {
        [8315] = "nextQuestInChain", -- The Calling (AQ)
        [8977] = "nextQuestInChain", -- dungeon set quests (Dungeon Set 1 / 2 chains)
        [8978] = "nextQuestInChain",
        [8997] = "nextQuestInChain",
        [8998] = "nextQuestInChain",
        [9015] = "nextQuestInChain",
    },

    -- Zone names the client's AreaTable lacks or spells differently (area ID -> English name).
    names = {
        [16941] = "Craftsman's Writs", -- the client's area is "Crafting" (CraftingQuestNameOnly)
    },
}
