------------------------------------------------------------
-- WarbandTabs.lua - the Warband tab's model (#153): categories, rulesets,
-- user tabs, and which tabs are on screen. No frames here, so every rule the
-- view depends on is a plain function a test can call.
--
-- The view is a retail Warband Bank without deposit or withdraw: user tabs that
-- classify items by category, shown one at a time (Single) or three side by
-- side (Combined), over either the logged-in character (Personal) or every
-- character (Warband) on a chosen ruleset.
--
-- Tabs are DISPLAY FILTERS: an item claimed by two tabs shows in both, and one
-- no tab claims lands in "Other", which exists only while it has something.
-- They are local config, never synced: each account classifies what it sees
-- with its own tabs.
------------------------------------------------------------

AltStableWarbandModel = AltStableWarbandModel or {}
local M = AltStableWarbandModel

-- The six categories a tab can claim, in the order the dialog lists them.
M.CATEGORIES = { "equipment", "consumables", "tradegoods", "reagents", "recipes", "misc" }
M.CATEGORY_LABEL = {
    equipment = "Equipment", consumables = "Consumables", tradegoods = "Trade Goods",
    reagents = "Reagents", recipes = "Recipes", misc = "Miscellaneous",
}

-- Item classID -> category. Gems sit with trade goods and ammunition with
-- consumables, as a player sorts them; everything unlisted (containers,
-- quivers, quest items, keys, miscellaneous, an unknown class) is misc.
local CLASS_CATEGORY = {
    [2] = "equipment", [4] = "equipment",
    [0] = "consumables", [6] = "consumables",
    [7] = "tradegoods", [3] = "tradegoods",
    [5] = "reagents",
    [9] = "recipes",
}

function M.CategoryOf(classID)
    return CLASS_CATEGORY[classID] or "misc"
end

M.MAX_TABS = 8          -- user tabs; "Other" is not one of them
M.COMBINED = 3          -- tabs side by side in Combined

-- What a profile that has never configured a tab starts with.
function M.DefaultTabs()
    return {
        { name = "Trade Goods", icon = "Interface\\Icons\\INV_Fabric_Linen_01",
          cats = { tradegoods = true, reagents = true } },
        { name = "Consumables", icon = "Interface\\Icons\\INV_Potion_51",
          cats = { consumables = true } },
        { name = "Equipment",   icon = "Interface\\Icons\\INV_Chest_Plate06",
          cats = { equipment = true } },
        { name = "Recipes",     icon = "Interface\\Icons\\INV_Scroll_03",
          cats = { recipes = true } },
    }
end

M.OTHER_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

-- A tab the dialog may edit freely: Cancel must leave the saved one untouched,
-- and `cats` is a nested table, so a shallow copy would share it.
function M.CopyTab(tab)
    local out = { name = tab and tab.name, icon = tab and tab.icon, cats = {} }
    for k, v in pairs((tab and tab.cats) or {}) do out.cats[k] = v and true or nil end
    return out
end

function M.CopyTabs(tabs)
    local out = {}
    for i, t in ipairs(tabs or {}) do out[i] = M.CopyTab(t) end
    return out
end

------------------------------------------------------------
-- Rulesets
------------------------------------------------------------
-- Forever's realms are its rulesets, and a ruleset can have more than one realm
-- ("Classic Beta PvP" and "Classic Beta PvP 2" are both PvP). The name is all
-- there is to go on. Words, not substrings, so an "rp" inside another word does
-- not make a realm RP. A realm we cannot read is Unknown - never Normal, which
-- would put a character on a ruleset it may not be on.
M.RULESETS = { "Normal", "PvP", "RP", "Hardcore" }

function M.RulesetOf(realm)
    if type(realm) ~= "string" or not realm:find("%S") then return "Unknown" end
    local words = " " .. (realm:lower():gsub("[^%w]", " ")) .. " "
    if words:find(" hardcore ", 1, true) or words:find(" hc ", 1, true) then return "Hardcore" end
    if words:find(" rp ", 1, true) or words:find(" roleplay ", 1, true)
       or words:find(" rppvp ", 1, true) then return "RP" end
    if words:find("pvp", 1, true) then return "PvP" end
    return "Normal"
end

-- The setting is "current", "all" or a ruleset; "current" is resolved here, at
-- use, against wherever the player is now - never saved resolved. nil means no
-- filter.
function M.ResolveRuleset(setting, currentRealm)
    if setting == "all" then return nil end
    if setting == nil or setting == "current" then return M.RulesetOf(currentRealm) end
    return setting
end

------------------------------------------------------------
-- Tabs
------------------------------------------------------------

-- entries: { { cat = ..., ... }, ... }. Returns one list per tab, in tab order,
-- and the entries no tab claimed.
function M.Distribute(entries, tabs)
    local perTab, other = {}, {}
    for i = 1, #(tabs or {}) do perTab[i] = {} end
    for _, e in ipairs(entries or {}) do
        local claimed = false
        for i, t in ipairs(tabs or {}) do
            if t.cats and t.cats[e.cat] then
                local list = perTab[i]
                list[#list + 1] = e
                claimed = true
            end
        end
        if not claimed then other[#other + 1] = e end
    end
    return perTab, other
end

-- The pages the tab bar shows: each tab by index, then "other" while it has
-- anything.
function M.Pages(tabCount, hasOther)
    local pages = {}
    for i = 1, tabCount or 0 do pages[#pages + 1] = i end
    if hasOther then pages[#pages + 1] = "other" end
    return pages
end

local function IndexOf(pages, key)
    for i, k in ipairs(pages) do if k == key then return i end end
end

-- A selection that still exists is kept. "Other" vanishing falls back to the
-- last tab; an index past the end (a tab deleted elsewhere) to the last tab too.
function M.RepairSelection(sel, pages)
    if #pages == 0 then return nil end
    if IndexOf(pages, sel) then return sel end
    if type(sel) == "number" then
        local last
        for _, k in ipairs(pages) do if type(k) == "number" then last = k end end
        if last then return math.min(math.max(1, sel), last) end
    end
    local lastTab
    for _, k in ipairs(pages) do if type(k) == "number" then lastTab = k end end
    return lastTab or pages[1]
end

-- Combined: which pages are on screen. The window always holds the selected
-- page, and is clamped BACKWARD at the end so it never shows blanks: with
-- tabs 1..4, choosing 4 shows 2, 3, 4. Returns the first index and the count.
function M.CombinedWindow(pages, sel)
    local n = #pages
    if n == 0 then return 1, 0 end
    local width = math.min(M.COMBINED, n)
    local at = IndexOf(pages, sel) or 1
    local first = math.max(1, math.min(at, n - width + 1))
    return first, width
end

-- Where the selection goes when tab `deleted` is removed. "Other" stays; a later
-- tab shifts down one; the deleted one hands over to its neighbour.
function M.AfterDelete(sel, deleted, tabsLeft)
    if sel == "other" then return sel end
    if type(sel) ~= "number" then return 1 end
    if sel > deleted then return sel - 1 end
    if sel == deleted then
        if tabsLeft <= 0 then return nil end
        return math.min(deleted, tabsLeft)
    end
    return sel
end
