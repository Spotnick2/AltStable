------------------------------------------------------------
-- AltStableProfessions - who knows which recipe, across every alt (#14)
--
-- What the client can tell us, measured on 1.60.1.70124 (forever-api-notes.md,
-- Professions) - and the design follows it rather than the other way round:
--
--   * A profession's recipes are readable ONLY while its window is open, and
--     after the window closes the client still answers for the profession it
--     last showed. So a scan runs strictly between TRADE_SKILL_SHOW and
--     TRADE_SKILL_CLOSE, re-checks everything when it actually runs, and never
--     opens a window itself.
--   * GetAllRecipeIDs() lists learned AND unlearned recipes; recipe IDs are
--     spell IDs and match Wowhead's, which is what RecipeData.lua is keyed by.
--   * GetAllProfessionTradeSkillLines() lists every line whether the character
--     has it or not. Ownership comes from GetProfessions() instead.
--
-- What we store is only ever claimed as far as it was seen:
--   AltStableProfessionsDB[guid] = {
--     stamp = owner's time, strictly increasing (so two snapshots never share one),
--     profs = { [skillLine] = { rank, max, known = { [spellID] = true },
--                               full = time of the last COMPLETE scan, or nil } },
--     wish  = { [spellID] = true } or nil: the recipes it wants (#271), starred
--             on the account that plays it, cleared as it learns them
--   }
--   no entry for a guid        -> never scanned: nothing is claimed about it
--   profs[line], known empty   -> owned, window never opened ("not scanned")
--   profs[line], full = nil    -> partial: only NEW_RECIPE_LEARNED seen
--   profs = {}                 -> scanned, has no professions
-- A snapshot is written by the client playing the character and adopted by
-- everyone else as sent; a stamp that only ever goes up per character is what
-- orders them - also for our own alts played on another PC.
--
-- Craft cooldowns go on the CORE record as cd_<Profession>@<label>, the field
-- the grid's profession tooltip and the login toast already read, so the core
-- syncs and clears them like any other field.
--
-- Reagents the open window disagrees with (#348), account-wide and never synced:
--   AltStableProfessionsReagents[spellID] = { reagents = { item, count, ... },
--                                            at = time(), build = "70959" }
-- An entry exists only while the window's amounts differ from RecipeData's.
------------------------------------------------------------

AltStableProfessionsDB = AltStableProfessionsDB or {}
AltStableProfessionsReagents = AltStableProfessionsReagents or {}

local ADDON_ID     = "professions"
local BLOB_VERSION = "v1"
local TRAINER      = 6
-- An answer that says a profession is gone is believed only when a second read
-- at least this long after the first still says so (see RefreshOwnership).
local LOSS_CONFIRM = 5

-- The twelve lines Forever gives recipes to (Camping reached even Fishing and
-- First Aid), by the grid column's label. The label, the core's skill field and
-- the icon are taken FROM the column (Columns.lua), not repeated here: the
-- cd_<label>@ prefix only shows up in the grid when it matches the column's
-- label exactly.
local LINES = {
    { line = 171, label = "Alchemy" },       { line = 164, label = "Blacksmithing" },
    { line = 333, label = "Enchanting" },    { line = 202, label = "Engineering" },
    { line = 165, label = "Leatherworking" },{ line = 197, label = "Tailoring" },
    { line = 186, label = "Mining" },        { line = 182, label = "Herbalism" },
    { line = 393, label = "Skinning" },      { line = 185, label = "Cooking" },
    { line = 129, label = "First Aid" },     { line = 356, label = "Fishing" },
}

local PROFESSIONS, BY_LINE = {}, {}
local function BuildProfessions()
    local columns = {}
    for _, col in ipairs(AltStable.Columns or {}) do
        if col.type == "profSkill" then columns[col.label] = col end
    end
    for i, l in ipairs(LINES) do
        local col = columns[l.label]
        PROFESSIONS[i] = { line = l.line, label = l.label,
                           field = col and col.field, icon = col and col.profIcon
                                   or "Interface\\Icons\\INV_Misc_QuestionMark" }
        BY_LINE[l.line] = PROFESSIONS[i]
    end
end
BuildProfessions()

-- The core's skill field, for alts this plugin has never scanned: they still
-- show up as "has it, not scanned" rather than not at all.
local function CoreSkill(char, line)
    local p = BY_LINE[line]
    if not p or not p.field or type(char) ~= "table" then return nil end
    local v = tonumber(char[p.field])
    return (v and v > 0) and v or nil
end

local AT = { isActive = false, search = "", filter = "all", onlyDrops = false, onlyFavor = false,
             rowsPool = {}, cards = {} }

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff[AltStable Professions]|r " .. msg)
end

local function TS() return C_TradeSkillUI or {} end

local function Try(fn, ...)
    if type(fn) ~= "function" then return false, "absent" end
    return pcall(fn, ...)
end

------------------------------------------------------------
-- Recipe data (RecipeData.lua, generated from Wowhead)
------------------------------------------------------------

local function Data() return (AltStableRecipeData and AltStableRecipeData.recipes) or {} end

-- The indexes over RecipeData, built together in one walk the first time any
-- is asked for: per-line recipes with a known requirement (the tab asks for a
-- line's catalogue on every redraw), recipe item -> recipes, crafted item ->
-- recipes (the tooltips).
local lineIndex, byTeach, byOutput
local function BuildIndexes()
    if lineIndex then return end
    lineIndex, byTeach, byOutput = {}, {}, {}
    for id, r in pairs(Data()) do
        if r.learn then
            for _, s in ipairs(r.skill or {}) do
                lineIndex[s] = lineIndex[s] or {}
                table.insert(lineIndex[s], id)
            end
        end
        for _, item in ipairs(r.items or {}) do
            byTeach[item] = byTeach[item] or {}
            table.insert(byTeach[item], id)
        end
        if r.makes then
            byOutput[r.makes] = byOutput[r.makes] or {}
            table.insert(byOutput[r.makes], id)
        end
    end
end

local function LineRecipes(line)
    BuildIndexes()
    return lineIndex[line] or {}
end

------------------------------------------------------------
-- Reagents: the profession window's where it disagrees (#348), else RecipeData's
--
-- RecipeData's reagents come from the client's SpellReagents table, but the
-- server decides what a craft takes. At 70938 five Tailoring recipes went up by
-- a cloth in the table, and a change on the server alone would never reach it.
-- So the open window is read too, and where it differs, it wins.
------------------------------------------------------------

local function Overrides()
    if type(AltStableProfessionsReagents) ~= "table" then AltStableProfessionsReagents = {} end
    return AltStableProfessionsReagents
end

-- One craft's reagents, flat { item, count, ... }, and true when they are the
-- window's rather than the generated data's. nil when neither has any.
local function Reagents(id)
    local o = Overrides()[id]
    if type(o) == "table" and type(o.reagents) == "table" and o.reagents[1] then return o.reagents, true end
    local r = Data()[id]
    if r and type(r.reagents) == "table" and r.reagents[1] then return r.reagents, false end
    return nil
end

-- The window's reagents for one recipe, flat, from GetRecipeSchematic. Measured
-- on 70959 (Elixir of Lion's Strength): one slot per reagent, reagentType 1
-- (Basic), required = true, one item each, quantityRequired the count. Only
-- required Basic slots are what one craft takes. nil when the answer cannot be
-- read that way: a slot of alternatives or a currency has no place in a flat
-- list, and an empty answer is not trusted to mean "takes nothing".
local BASIC_REAGENT = 1
local function SchematicReagents(id)
    local ok, s = Try(TS().GetRecipeSchematic, id, false)
    if not ok or type(s) ~= "table" or type(s.reagentSlotSchematics) ~= "table" then return nil end
    local out = {}
    for _, slot in ipairs(s.reagentSlotSchematics) do
        if type(slot) ~= "table" then return nil end
        if slot.reagentType == BASIC_REAGENT and slot.required == true then
            local items, n = slot.reagents, tonumber(slot.quantityRequired)
            if type(items) ~= "table" or #items ~= 1 or type(items[1]) ~= "table" then return nil end
            local item = tonumber(items[1].itemID)
            if not item or not n or n <= 0 then return nil end
            out[#out + 1] = item
            out[#out + 1] = n
        end
    end
    return out[1] and out or nil
end

-- Same items in the same amounts, in any order (the window's order need not be
-- the table's).
local function SameReagents(a, b)
    local function tally(t)
        local m = {}
        if type(t) == "table" then
            for i = 1, #t - 1, 2 do m[t[i]] = (m[t[i]] or 0) + t[i + 1] end
        end
        return m
    end
    local ma, mb = tally(a), tally(b)
    for k, v in pairs(ma) do if mb[k] ~= v then return false end end
    for k in pairs(mb) do if ma[k] == nil then return false end end
    return true
end

-- seen = { [spellID] = flat reagents } from one window. Keeps an entry for each
-- recipe the window disagrees on and drops one it agrees on again (RecipeData
-- regenerated, or the server changed back). Returns true if anything changed.
local function ApplyWindowReagents(seen)
    local store, data, changed = Overrides(), Data(), false
    local okb, _, build = pcall(GetBuildInfo)
    build = okb and build or nil
    for id, w in pairs(seen) do
        local r = data[id]
        if SameReagents(w, r and r.reagents) then
            if store[id] ~= nil then store[id] = nil; changed = true end
        else
            local held = store[id]
            if not (type(held) == "table" and SameReagents(held.reagents, w)) then
                store[id] = { reagents = w, at = time(), build = build }
                changed = true
            end
        end
    end
    return changed
end

------------------------------------------------------------
-- The store
------------------------------------------------------------

local function Entry(guid)
    AltStableProfessionsDB[guid] = AltStableProfessionsDB[guid] or { profs = {} }
    local e = AltStableProfessionsDB[guid]
    e.profs = e.profs or {}
    return e
end

-- Strictly increasing per character: two changes in one second would otherwise
-- produce two different snapshots under one stamp, and peers holding one each
-- could never tell which is newer.
local function Bump(e)
    e.stamp = math.max(time(), (e.stamp or 0) + 1)
end

-- Every change to a character's snapshot or cooldowns ends here, and each can
-- change the sheet's Cooldowns view (#543, #545): a profession gained or lost
-- adds or drops a row, a recipe learned changes a cell, a cooldown a column.
-- RefreshSheet does nothing while the sheet isn't built.
local function Changed(guid)
    if AltStable.TouchCharacter then AltStable.TouchCharacter(guid) end
    if AT.isActive and AT.RequestRefresh then AT.RequestRefresh() end
    if AltStable.RefreshSheet then AltStable.RefreshSheet() end
end

local function setsEqual(a, b)
    for k in pairs(a or {}) do if not (b and b[k]) then return false end end
    for k in pairs(b or {}) do if not (a and a[k]) then return false end end
    return true
end

------------------------------------------------------------
-- The wishlist (#271): the recipes an alt wants, on its own snapshot, so it
-- syncs with the alt. Only the account that plays the alt writes it
-- (scannedHere): every other client adopts that account's snapshots whole, so
-- a star set there would be overwritten, and the core does not send another
-- account's characters anyway.
------------------------------------------------------------

local function KnowsAnywhere(e, id)
    for _, p in pairs(e.profs or {}) do
        if type(p) == "table" and p.known and p.known[id] then return true end
    end
    return false
end

-- Wants it and does not know it yet: a snapshot from before the alt learned it
-- (or from a client that does not clear) never shows a star on a known recipe.
local function Wants(guid, id)
    local e = AltStableProfessionsDB[guid]
    return type(e) == "table" and type(e.wish) == "table" and e.wish[id] == true
        and not KnowsAnywhere(e, id) or false
end

-- A snapshot of our own to write to: never one the plugin has not made yet,
-- since an entry is a claim about the alt's professions (an empty one says
-- "has none").
local function CanWish(guid)
    local c = AltStableDB and AltStableDB[guid]
    local e = AltStableProfessionsDB[guid]
    return type(c) == "table" and c.scannedHere and type(e) == "table" and e.stamp and true or false
end

-- Drops the stars of recipes the alt knows now. Whether any went.
local function ClearLearnedWishes(e)
    if type(e.wish) ~= "table" then e.wish = nil; return false end
    local changed = false
    for id in pairs(e.wish) do
        if KnowsAnywhere(e, id) then e.wish[id] = nil; changed = true end
    end
    if not next(e.wish) then e.wish = nil end
    return changed
end

-- Star (on) or unstar a recipe for an alt. Whether anything changed.
local function SetWish(guid, id, on)
    id = tonumber(id)
    if not id or not CanWish(guid) then return false end
    local e = AltStableProfessionsDB[guid]
    on = on and true or nil
    if on and KnowsAnywhere(e, id) then return false end
    if type(e.wish) ~= "table" then e.wish = nil end
    if (e.wish and e.wish[id] or nil) == on then return false end
    e.wish = e.wish or {}
    e.wish[id] = on
    if not next(e.wish) then e.wish = nil end
    Bump(e)
    -- Only the character being played is touched: lastUpdate is its Last
    -- Online, and an alt starred from another one has not been online. That
    -- one is marked changed instead (#422), so the next delta carries it.
    if guid == (UnitGUID and UnitGUID("player")) then
        Changed(guid)
    else
        if AltStable.MarkChanged then AltStable.MarkChanged(guid) end
        if AT.isActive and AT.RequestRefresh then AT.RequestRefresh() end
    end
    return true
end

------------------------------------------------------------
-- Cooldowns: cd_<Profession>@<label> on the core record
------------------------------------------------------------

-- The label a recipe's cooldown is filed under: the text before the first
-- ":", so "Transmute: Arcanite" and every other transmute share "Transmute" -
-- one cooldown in game, one field here. Stripping the colon matters beyond
-- tidiness: the core sends every field as a "key:value" line, and a colon in
-- the key cut it in the wrong place on every peer (review of #132).
local function CooldownLabel(name)
    if type(name) ~= "string" or name == "" then return nil end
    local label = name:match("^([^:]+):") or name
    label = label:gsub("[:\n|]", ""):gsub("^%s+", ""):gsub("%s+$", "")
    return label ~= "" and label or nil
end

-- Cooldowns that belong to an ITEM, not a recipe (#460): the Salt Shaker turns
-- Deeprock Salt into Refined Deeprock Salt every 2 days 23 hours, and is used
-- from the bags, so the profession window never lists it. Filed under the
-- profession that can use it, so the sheet, the sync and the toast read it like
-- any cd_<Profession>@<label> field.
local ITEM_COOLDOWNS = {
    -- learn: the skill the item asks ("Requires Leatherworking (250)", Wowhead
    -- Forever item 15846, 2026-11-27), for the Cooldowns view (#545).
    { item = 15846, spell = 19566, prof = "Leatherworking", line = 165, label = "Salt Shaker", learn = 250 },
}
local ITEM_LABELS, ITEM_SPELLS = {}, {}   -- [prof][label] = true; [spellID] = true
for _, ic in ipairs(ITEM_COOLDOWNS) do
    ITEM_LABELS[ic.prof] = ITEM_LABELS[ic.prof] or {}
    ITEM_LABELS[ic.prof][ic.label] = true
    ITEM_SPELLS[ic.spell] = true
end

-- cds = { [label] = seconds remaining } for the learned recipes whose cooldown
-- is RUNNING; knownLabels = every label a learned recipe files under. A ready
-- cooldown may come back as nil or as 0 (Retail returns nil; Forever is not
-- measured), so "known but not running" is what means ready. Returns true if
-- anything changed.
--   * a running cooldown is written as an absolute expiry; a shift under 60 s
--     is timing jitter between two reads and is not a change;
--   * one that has come back up keeps a past expiry, so the grid says "Ready!";
--   * a label no learned recipe files under any more takes its field with it.
--   * a catalogued one (RecipeData's `cd`, #545) learned and ready with no field
--     yet is written as 0: seen ready, so the Cooldowns view can say Available
--     for one never cast. 0 is ready everywhere, and the login toast skips it
--     (it wants a positive expiry), so nothing toasts for it.
local function ApplyCooldowns(char, label, cds, knownLabels, catalogued)
    if type(char) ~= "table" then return false end
    local prefix, now, changed = "cd_" .. label .. "@", time(), false
    -- First, so a running one (cds) overwrites it just below: a 0 is a past
    -- expiry there, like any other. `catalogued` holds learned labels only
    -- (Candidate fills it beside knownLabels).
    for name in pairs(catalogued or {}) do
        local key = prefix .. name
        if char[key] == nil then
            char[key] = 0; changed = true
        end
    end
    for name, left in pairs(cds) do
        if left and left > 0 then
            local key = prefix .. name
            local held = tonumber(char[key])
            local expiry = now + left
            if not held or held <= now or math.abs(held - expiry) > 60 then
                char[key] = expiry; changed = true
            end
        end
    end
    local items = ITEM_LABELS[label]
    for key, v in pairs(char) do
        if type(key) == "string" and key:sub(1, #prefix) == prefix then
            local name = key:sub(#prefix + 1)
            if items and items[name] then
                -- An item's cooldown (#460): no recipe files under it, and the
                -- window can't say whether it runs. Left whole: not removed,
                -- not set ready. ReadItemCooldowns keeps it.
            elseif not knownLabels[name] then
                char[key] = nil; changed = true
            elseif not (cds[name] and cds[name] > 0) and (tonumber(v) or 0) > now then
                char[key] = now; changed = true    -- ready again: a transition, never jitter
            end
        end
    end
    return changed
end

local function ClearCooldowns(char, label)
    if type(char) ~= "table" then return false end
    local prefix, changed = "cd_" .. label .. "@", false
    for key in pairs(char) do
        if type(key) == "string" and key:sub(1, #prefix) == prefix then char[key] = nil; changed = true end
    end
    return changed
end

------------------------------------------------------------
-- Item cooldowns (#460): the Salt Shaker
------------------------------------------------------------

-- Who can use it, by Owners' rule: this plugin's own snapshot decides once it
-- has one (a confirmed loss must not bring the field back from a stale core
-- rank); the core's skill field only stands in before that.
-- Its skill in that line, or nil when it doesn't own it (#545: the Shaker
-- needs Leatherworking 250).
local function LineRank(guid, char, line)
    local e = AltStableProfessionsDB and AltStableProfessionsDB[guid]
    local p = type(e) == "table" and e.profs and e.profs[line]
    if p then return tonumber(p.rank) or 0 end
    if type(e) == "table" and e.stamp then return nil end
    return CoreSkill(char, line)
end

local function PlainTime(v)
    local n = AltStable.API.PlainNumber(v)
    return (n and n >= 0) and n or nil
end

-- The three readers the 71037 dump declares, in order; unmeasured on Forever
-- which of them answers for an item, so the first that gives two plain
-- numbers wins. Start is on the GetTime() clock; 0, 0 is "not running".
local ITEM_CD_READERS = {
    function(id)
        local c = rawget(_G, "C_Container")
        local f = type(c) == "table" and c.GetItemCooldown
        if type(f) == "function" then return f(id) end
    end,
    function(id)
        local c = rawget(_G, "C_Item")
        local f = type(c) == "table" and c.GetItemCooldown
        if type(f) == "function" then return f(id) end
    end,
    function(id)
        local c = rawget(_G, "C_Spell")
        local f = type(c) == "table" and c.GetItemCooldown
        local info = type(f) == "function" and f(id)
        if type(info) == "table" then return info.startTime, info.duration end
    end,
}

local function ItemCooldown(id)
    for _, read in ipairs(ITEM_CD_READERS) do
        local ok, s, d = pcall(read, id)
        if ok then
            s, d = PlainTime(s), PlainTime(d)
            if s and d then return s, d end
        end
    end
    return nil
end

-- The played character's item cooldowns, on the recipe cooldowns' rules (a
-- running one is an absolute expiry, a shift under 60 s is not a change, a
-- ready one keeps a past expiry). Additionally:
--   * first seen and not running: written as now, so the grid says Ready and
--     the login toast can say it once;
--   * an expiry already past is kept as it is (the toast's de-duplication keys
--     on it);
--   * the item not in the bags (sold, banked): a running cooldown stays, one
--     that is over goes, so nothing lists a Shaker that is gone.
-- A read that fails, a secret, or a count that can't be read changes nothing.
local function ReadItemCooldowns()
    local guid = UnitGUID and UnitGUID("player")
    local char = guid and AltStableDB and AltStableDB[guid]
    if type(char) ~= "table" then return false end
    local now, changed = time(), false
    for _, ic in ipairs(ITEM_COOLDOWNS) do
        local key = "cd_" .. ic.prof .. "@" .. ic.label
        local rank = LineRank(guid, char, ic.line)
        if rank and rank < (ic.learn or 0) then
            -- An owner who can't use it yet (the Shaker under Leatherworking
            -- 250, Codex review of #546): carrying one records nothing, and a
            -- record held from before goes.
            if char[key] ~= nil then char[key] = nil; changed = true end
        elseif rank then
            local held = tonumber(char[key])
            local okc, count = pcall(AltStable.API.GetItemCount, ic.item)
            count = okc and AltStable.API.PlainNumber(count) or nil
            if count and count > 0 then
                local s, d = ItemCooldown(ic.item)
                if s then
                    local left = (s > 0 and d > 0) and (s + d - (GetTime() or 0)) or 0
                    if left > 0 then
                        local expiry = math.floor(now + left + 0.5)
                        if not held or held <= now or math.abs(held - expiry) > 60 then
                            char[key] = expiry; changed = true
                        end
                    elseif not held or held > now then
                        char[key] = now; changed = true
                    end
                end
            elseif count and held and held <= now then
                char[key] = nil; changed = true
            end
        end
    end
    if changed then
        -- Changed redraws the sheet too: its Leatherworking tooltip is built
        -- when the row renders, and this read comes a frame after the event, so
        -- nothing else would redraw it (Codex review of #464).
        Changed(guid)
    end
    return changed
end

-- Bag cooldown events and the Shaker's own cast come in bursts: one read on
-- the next frame for all of them.
local itemReadPending = false
local function QueueItemRead()
    if itemReadPending then return end
    itemReadPending = true
    C_Timer.After(0, function()
        itemReadPending = false
        ReadItemCooldowns()
    end)
end

------------------------------------------------------------
-- Ownership: GetProfessions() for the character being played
------------------------------------------------------------

-- { [skillLine] = { rank, max } }, or nil when the API is missing or broken.
-- All of GetProfessions' returns are read: Forever returns seven (measured,
-- "nil x 7"), and a fixed five would drop whatever sits in the last two.
local function ReadOwned()
    if type(GetProfessions) ~= "function" or type(GetProfessionInfo) ~= "function" then return nil end
    local res = { pcall(GetProfessions) }
    if not res[1] then return nil end
    local owned = {}
    for i = 2, table.maxn(res) do
        local idx = res[i]
        if idx then
            local ok2, _, _, rank, maxRank, _, _, line = pcall(GetProfessionInfo, idx)
            if not ok2 then return nil end
            line = tonumber(line)
            if line and BY_LINE[line] then owned[line] = { rank = tonumber(rank) or 0, max = tonumber(maxRank) or 0 } end
        end
    end
    return owned
end

local pendingLoss   -- { lines = "171,393", at = time() } awaiting confirmation

-- Reconcile the store with what the character has now.
--
-- LOSING a profession is believed only when two reads at least LOSS_CONFIRM
-- seconds apart agree on exactly which lines are gone. At login GetProfessions
-- can answer before the skill lines have loaded - empty, or with lines missing -
-- and the login timer and the SKILL_LINES_CHANGED debounce can land two reads
-- in the same second. Believing that would delete complete scans and sync the
-- loss (review of #132). Gains and skill changes apply at once.
local function RefreshOwnership()
    local guid = UnitGUID and UnitGUID("player")
    if not guid then return end
    local owned = ReadOwned()
    if not owned then return end
    local e = Entry(guid)

    local lost = {}
    for line in pairs(e.profs) do if not owned[line] then lost[#lost + 1] = line end end
    table.sort(lost)
    local lostKey = table.concat(lost, ",")
    local confirmedLoss = false
    if #lost > 0 then
        if pendingLoss and pendingLoss.lines == lostKey and time() - pendingLoss.at >= LOSS_CONFIRM then
            confirmedLoss = true
            pendingLoss = nil
        else
            if not (pendingLoss and pendingLoss.lines == lostKey) then
                pendingLoss = { lines = lostKey, at = time() }
            end
            C_Timer.After(LOSS_CONFIRM + 1, RefreshOwnership)
        end
    else
        pendingLoss = nil
    end

    local changed, char = false, AltStableDB and AltStableDB[guid]
    if confirmedLoss then
        for _, line in ipairs(lost) do
            e.profs[line] = nil
            -- The cooldowns go with it (Changed, below, redraws the sheet).
            if BY_LINE[line] then ClearCooldowns(char, BY_LINE[line].label) end
            changed = true
        end
    end
    for line, s in pairs(owned) do
        local p = e.profs[line]
        if not p then
            e.profs[line] = { rank = s.rank, max = s.max, known = {} }
            changed = true
        elseif p.rank ~= s.rank or p.max ~= s.max then
            p.rank, p.max = s.rank, s.max
            changed = true
        end
    end
    -- A character seen with no professions at all is a snapshot too ("has none"),
    -- so the first read always stamps.
    if changed or not e.stamp then Bump(e); Changed(guid) end
end

------------------------------------------------------------
-- The scan: only while a window is open, only of our own profession
------------------------------------------------------------

local scan = { open = false, gen = 0, retries = 0 }
local MAX_RETRIES = 3

-- A candidate snapshot of the open window, or nil and why not. Nothing here
-- writes: a candidate is committed whole or not at all.
local function Candidate()
    local t = TS()
    if not scan.open then return nil, "closed" end
    local ok, v
    ok, v = Try(t.IsTradeSkillReady);     if ok and v == false then return nil, "not ready" end
    ok, v = Try(t.IsDataSourceChanging);  if ok and v then return nil, "changing" end
    ok, v = Try(t.IsTradeSkillLinked);    if ok and v then return nil, "linked" end
    ok, v = Try(t.IsTradeSkillGuild);     if ok and v then return nil, "guild" end
    ok, v = Try(t.IsNPCCrafting);         if ok and v then return nil, "npc" end
    local okb, base = Try(t.GetBaseProfessionInfo)
    local line = okb and type(base) == "table" and tonumber(base.professionID)
    if not line or not BY_LINE[line] then return nil, "no profession" end
    -- Only a profession this character has. A window can show one it does not
    -- (Forever's overview has a tab per profession; unmeasured) and filing that
    -- as a complete scan would make the alt an owner who knows nothing.
    local owned = ReadOwned()
    if not (owned and owned[line]) then return nil, "not owned" end
    local okr, ids = Try(t.GetAllRecipeIDs)
    if not okr or type(ids) ~= "table" or #ids == 0 then return nil, "no recipes" end

    -- cdOk: every cooldown read answered. A read that FAILED (absent or
    -- throwing) says nothing about readiness - folding it into "nil" turned a
    -- running cooldown into "ready" and synced that (Codex review of #132) - so
    -- one failure leaves the whole profession's cooldown fields as they are.
    local known, cds, labels, cdOk = {}, {}, {}, true
    local catalogued = {}   -- labels from RecipeData's `cd` (#545)
    for _, id in ipairs(ids) do
        local oki, info = Try(t.GetRecipeInfo, id)
        -- Never measured to happen (727 IDs, no nil), but a half-read list
        -- would read as "unlearned" for everything missing: abandon instead.
        if not oki or type(info) ~= "table" then return nil, "incomplete" end
        if info.learned then
            known[id] = true
            -- The cooldown it files under: RecipeData's `cd` for a recipe it has
            -- (#545) - the shared Transmute, Iron to Gold's own hour, nothing for
            -- a recipe without one - in English on every client. The localized
            -- name only for a recipe newer than the data.
            local r = Data()[id]
            local label
            if r then label = r.cd else label = CooldownLabel(info.name) end
            if label then
                labels[label] = true
                if r then catalogued[label] = true end
                local okc, left = Try(t.GetRecipeCooldown, id)
                if not okc then
                    cdOk = false
                else
                    left = tonumber(left)
                    if left and left > 0 then cds[label] = math.max(cds[label] or 0, left) end
                end
            end
        end
    end
    -- The learned recipes' reagents (#348), once per profession per opening:
    -- a scan re-runs after every craft, and the amounts don't change between.
    -- A recipe whose answer can't be read is left out, keeping what we hold.
    local reagents
    if scan.reagentsLine ~= line then
        reagents = {}
        for id in pairs(known) do reagents[id] = SchematicReagents(id) end
    end
    return { line = line, rank = tonumber(base.skillLevel) or 0, max = tonumber(base.maxSkillLevel) or 0,
             known = known, cds = cds, labels = labels, catalogued = catalogued, cdOk = cdOk,
             reagents = reagents }
end

local function Commit(c)
    local guid = UnitGUID and UnitGUID("player")
    if not guid then return end
    local e = Entry(guid)
    local p = e.profs[c.line]
    local changed = false
    if not p then
        p = { known = {} }; e.profs[c.line] = p; changed = true
    end
    if not setsEqual(p.known, c.known) or p.rank ~= c.rank or p.max ~= c.max or not p.full then
        p.known, p.rank, p.max = c.known, c.rank, c.max
        changed = true
    end
    if ClearLearnedWishes(e) then changed = true end
    p.full = time()   -- "last verified", whether or not anything moved
    if changed then Bump(e) end
    local cdChanged = c.cdOk
        and ApplyCooldowns(AltStableDB and AltStableDB[guid], BY_LINE[c.line].label, c.cds, c.labels, c.catalogued)
        or false
    -- A cooldown alone must reach peers too: the core only sends a character
    -- whose lastUpdate moved, and no recipe changed.
    -- Changed also redraws the sheet's Cooldowns view (#543, #545).
    if changed or cdChanged then Changed(guid) end
    -- Not a change of the character's: the store is account-wide and never
    -- synced, so only the tab redraws.
    if c.reagents then
        scan.reagentsLine = c.line
        if ApplyWindowReagents(c.reagents) and AT.isActive and AT.RequestRefresh then AT.RequestRefresh() end
    end
end

local function RunScan(gen)
    if gen ~= scan.gen then return end
    local c, why = Candidate()
    if c then scan.retries = 0; Commit(c); return end
    if why == "incomplete" or why == "not ready" or why == "no recipes" then
        if scan.retries < MAX_RETRIES then
            scan.retries = scan.retries + 1
            C_Timer.After(1, function() RunScan(gen) end)
        end
    end
end

local function ScheduleScan()
    scan.gen = scan.gen + 1
    scan.retries = 0
    local gen = scan.gen
    C_Timer.After(0.5, function() RunScan(gen) end)
end

local function OnShow()   scan.open = true; scan.reagentsLine = nil; ScheduleScan() end
local function OnClose()  scan.open = false; scan.gen = scan.gen + 1 end
local function OnChanging() scan.gen = scan.gen + 1 end

-- Learned with the window shut (a trainer, a recipe item): add it at once,
-- as a positive fact. It does not make the profession's list complete.
local function OnRecipeLearned(recipeID)
    recipeID = tonumber(recipeID)
    local guid = UnitGUID and UnitGUID("player")
    if not recipeID or not guid then return end
    local line
    local ok, info = Try(TS().GetProfessionInfoByRecipeID, recipeID)
    if ok and type(info) == "table" then
        -- The CHILD line comes back (2937 for Alchemy); its parent is the one we key by.
        line = tonumber(info.parentProfessionID)
        if not BY_LINE[line or -1] then line = tonumber(info.professionID) end
    end
    if not BY_LINE[line or -1] then
        local r = Data()[recipeID]
        line = r and r.skill and r.skill[1]
    end
    if not BY_LINE[line or -1] then return end   -- the next full scan will have it
    local e = Entry(guid)
    local p = e.profs[line]
    if not p then p = { known = {} }; e.profs[line] = p end
    if p.known[recipeID] then return end
    p.known[recipeID] = true
    ClearLearnedWishes(e)
    Bump(e)
    Changed(guid)
end

------------------------------------------------------------
-- Sync
--   v1|s=<stamp>[|w=<id,id,...>]|p=<line>:<rank>:<max>:<full or ->:<id,id,...>;...
-- `p=` present and empty = "no professions". Missing = malformed.
-- `w=` is the wishlist (#271), only when there is one. Still v1: every parser
-- reads s= at the start and p= at the end, so an older one skips w= and keeps
-- the rest. No w= = no wishes.
------------------------------------------------------------

local function SerializePlayer(guid)
    local e = AltStableProfessionsDB[guid]
    if type(e) ~= "table" or not e.stamp then return "" end
    -- Always the whole snapshot when the core sends this character: a filter on
    -- our own stamp could hold back a snapshot the peer never received (the
    -- core's lastUpdate moves for many reasons; Codex review of the plan).
    local lines = {}
    for line in pairs(e.profs or {}) do lines[#lines + 1] = line end
    table.sort(lines)
    local parts = {}
    for _, line in ipairs(lines) do
        local p = e.profs[line]
        local ids = {}
        for id in pairs(p.known or {}) do ids[#ids + 1] = id end
        table.sort(ids)
        parts[#parts + 1] = string.format("%d:%d:%d:%s:%s", line, p.rank or 0, p.max or 0,
            p.full and tostring(p.full) or "-", table.concat(ids, ","))
    end
    local wish = {}
    for id in pairs(type(e.wish) == "table" and e.wish or {}) do
        if tonumber(id) then wish[#wish + 1] = id end
    end
    table.sort(wish)
    local w = #wish > 0 and ("|w=" .. table.concat(wish, ",")) or ""
    return BLOB_VERSION .. "|s=" .. e.stamp .. w .. "|p=" .. table.concat(parts, ";")
end

-- The w= field, or nil for none; false when malformed.
local function ParseWish(rest)
    local s = rest:match("|w=([^|]*)|")
    if not s then return nil end
    if not s:match("^[%d,]*$") then return false end
    local wish = {}
    for id in s:gmatch("%d+") do wish[tonumber(id)] = true end
    return next(wish) and wish or nil
end

-- Lines this build does not know (a newer peer's) are skipped, not stored: a
-- stored line with no entry in BY_LINE has no label, and everything that files
-- or clears a cooldown under it would fail.
local function ParseProfs(s)
    local profs = {}
    if s == "" then return profs end
    for seg in s:gmatch("[^;]+") do
        local line, rank, max, full, ids = seg:match("^(%d+):(%d+):(%d+):([%d%-]+):([%d,]*)$")
        line = tonumber(line)
        if not line then return nil end
        if full ~= "-" and not tonumber(full) then return nil end
        local known = {}
        for id in ids:gmatch("[^,]+") do
            local n = tonumber(id)
            if not n then return nil end
            known[n] = true
        end
        if BY_LINE[line] then
            profs[line] = { rank = tonumber(rank), max = tonumber(max), full = tonumber(full), known = known }
        end
    end
    return profs
end

local function DeserializePlayer(guid, blob)
    if not guid or type(blob) ~= "string" or blob == "" then return end
    local ver, rest = blob:match("^(v%d+)|(.*)$")
    if ver ~= BLOB_VERSION then return end              -- a newer format: ignore, never wipe
    local stamp = tonumber(rest:match("^s=(%d+)"))
    local profStr = rest:match("|p=([^|]*)$")
    if not stamp or not profStr then return end
    -- Strictly newer only. Stamps go up per character wherever it is played, so
    -- this also takes one of our own alts played on another PC - the core takes
    -- its record then, and refusing the snapshot left the two apart for good
    -- (review of #132) - while our own echoes come back equal and are ignored.
    local held = AltStableProfessionsDB[guid]
    if type(held) == "table" and (held.stamp or 0) >= stamp then return end
    local profs = ParseProfs(profStr)
    if not profs then return end                        -- malformed: keep what we have
    local wish = ParseWish(rest)
    if wish == false then return end
    AltStableProfessionsDB[guid] = { stamp = stamp, profs = profs, wish = wish }
    -- No TouchCharacter: receiving is not a change of ours, and a relay that
    -- moved lastUpdate would make every peer re-send it forever. The core marks
    -- the record changed instead, on this true (#422): a newer stamp stored.
    if AT.isActive and AT.RequestRefresh then AT.RequestRefresh() end
    return true
end

------------------------------------------------------------
-- Housekeeping
------------------------------------------------------------

-- A snapshot whose character the core has no record of is kept, invisible
-- (every read goes through AltStableDB), until a forget or a cleanup (#418):
-- its wishlist exists nowhere else.
local function DropForgottenOrphans()
    return AltStable.DropForgottenOrphans and AltStable.DropForgottenOrphans(AltStableProfessionsDB) or 0
end

local function Cleanup(keepGuid)
    for guid in pairs(AltStableProfessionsDB) do
        if guid ~= keepGuid then AltStableProfessionsDB[guid] = nil end
    end
end

------------------------------------------------------------
-- Read model
------------------------------------------------------------

local function IsHidden(guid)
    return AltStable.IsCharacterHidden and AltStable.IsCharacterHidden(guid) or false
end

-- Everyone who has this profession, as far as anything says so:
--   "full"      - a complete scan to go on
--   "partial"   - only learned-recipe events
--   "unscanned" - owns it (GetProfessions, or the core's skill field for an alt
--                 the plugin never saw), but no window was ever read
-- Hidden characters are left out of the list, and counted: they still decide
-- whether "nobody" can be said at all.
-- One character as an owner of a line, or nil: this plugin's snapshot once it
-- has one (a confirmed loss must not come back from a stale core rank), the
-- core's skill field only before that. Owners' rule, and the Cooldowns view's (#545).
local function OwnerOf(guid, c, line)
    local e = AltStableProfessionsDB[guid]
    local p = type(e) == "table" and e.profs and e.profs[line]
    if p then
        local state = p.full and "full" or (next(p.known or {}) and "partial" or "unscanned")
        return { guid = guid, name = c.name, class = c.class, realm = c.realm,
                 rank = p.rank or 0, max = p.max or 0, known = p.known or {},
                 full = p.full, state = state }
    elseif not (type(e) == "table" and e.stamp) and CoreSkill(c, line) then
        return { guid = guid, name = c.name, class = c.class, realm = c.realm,
                 rank = CoreSkill(c, line), max = 0, known = {}, state = "unscanned" }
    end
end

local function Owners(line)
    local out, hidden = {}, 0
    for guid, c in pairs(AltStableDB or {}) do
        if type(c) == "table" and c.name then
            local o = OwnerOf(guid, c, line)
            if o then
                if IsHidden(guid) then hidden = hidden + 1 else out[#out + 1] = o end
            end
        end
    end
    table.sort(out, function(a, b)
        if a.rank ~= b.rank then return a.rank > b.rank end
        return (a.name or "") < (b.name or "")
    end)
    return out, hidden
end

-- The recipes of a line: the generated catalogue, less those whose requirement
-- Wowhead does not know (quite possibly not learnable yet), plus anything an
-- alt actually knows that the catalogue lacks (a newer patch).
local function Catalogue(line, owners)
    local set = {}
    for _, id in ipairs(LineRecipes(line)) do set[id] = true end
    for _, o in ipairs(owners) do for id in pairs(o.known) do set[id] = true end end
    return set
end

-- Names come from the client. One the client does not have yet is asked for
-- ONCE; SPELL_DATA_LOAD_RESULT redraws only for an ID we asked about that did
-- load. Asking again on every redraw, and redrawing on every answer, turned an
-- ID the client lacks into a redraw every frame (review of #132).
local names, requested = {}, {}
local function RecipeName(id)
    if names[id] then return names[id] end
    local n
    if C_Spell and C_Spell.GetSpellName then
        local ok, v = pcall(C_Spell.GetSpellName, id); if ok then n = v end
    end
    if n and n ~= "" then names[id] = n; return n end
    if not requested[id] then
        requested[id] = true
        if C_Spell and C_Spell.RequestLoadSpellData then pcall(C_Spell.RequestLoadSpellData, id) end
    end
    return nil
end

local function OnSpellData(id, success)
    id = tonumber(id)
    if not id or not requested[id] then return false end
    requested[id] = nil
    if not success then
        requested[id] = "failed"   -- never asked again this session
        return false
    end
    if AT.isActive then AT.RequestRefresh() end
    return true
end

local function RecipeIcon(id)
    local r = Data()[id]
    if r and r.makes and C_Item and C_Item.GetItemIconByID then
        local ok, icon = pcall(C_Item.GetItemIconByID, r.makes)
        if ok and icon then return icon end
    end
    if C_Spell and C_Spell.GetSpellTexture then
        local ok, icon = pcall(C_Spell.GetSpellTexture, id)
        if ok and icon then return icon end
    end
    return "Interface\\Icons\\INV_Misc_QuestionMark"
end

local SOURCE_LABELS = { [1] = "Crafted", [2] = "Drop", [3] = "PvP", [4] = "Quest", [5] = "Vendor",
                        [6] = "Trainer", [7] = "Discovery", [16] = "Fished", [21] = "Pickpocket" }

-- A recipe a quartermaster sells for Merchant's Favor (#270) says its price
-- where "Vendor" would be: the price is what an alt has to save up.
local function SourceText(r)
    if not r then return "?" end
    local favor = r.favor and (r.favor .. " Favor")
    if not r.src then return favor or "?" end
    local t = {}
    for _, c in ipairs(r.src) do
        if c == 5 and favor then
            t[#t + 1] = favor
            favor = nil
        else
            t[#t + 1] = SOURCE_LABELS[c] or "Other"
        end
    end
    if favor then table.insert(t, 1, favor) end
    return table.concat(t, ", ")
end

-- Any source a player can go and get it from, other than a trainer.
local function HasNonTrainerSource(r)
    for _, c in ipairs((r and r.src) or {}) do if c ~= TRAINER then return true end end
    return false
end

-- What can be said about one owner and one recipe - the ONE rule the tab and
-- the item tooltips share (they had a copy each, and the copies drifted;
-- review of #133):
--   "known"     the owner knows it
--   "unscanned" no complete scan: nothing negative can be said
--   "unknown"   complete scan, not known, and Wowhead does not know the requirement
--   "meets"     complete scan, not known, meets the SKILL requirement - only that:
--               specialisations, reputation and quests are not in the data
--   "low"       complete scan, not known, under the requirement
local function Verdict(o, id)
    if o.known[id] then return "known" end
    if o.state ~= "full" then return "unscanned" end
    local r = Data()[id]
    if not (r and r.learn) then return "unknown" end
    return o.rank >= r.learn and "meets" or "low"
end

local function MeetsSkill(o, id)
    return Verdict(o, id) == "meets"
end

-- What "nobody" may honestly be called for a line's owners: "Nobody knows" only
-- when every owner - hidden ones too, who are not in the list and may know it -
-- has a complete scan.
local function NobodyText(owners, hidden)
    local all = #owners > 0 and (hidden or 0) == 0
    for _, o in ipairs(owners) do if o.state ~= "full" then all = false end end
    return all and "Nobody knows" or "Nobody recorded"
end

-- A class-coloured name, and a list of them capped at four and "+N": a line on
-- a tooltip does not wrap, and ten alts with First Aid would run off the screen.
local function ColorName(o)
    local esc = AltStable.ClassColor and AltStable.ClassColor(o.class) or ""
    return (esc ~= "" and esc or "|cffe6e6e6") .. (o.name or "?") .. "|r"
end

local NAMES_SHOWN = 4
local function NameList(list, fmt)
    local parts = {}
    for i, o in ipairs(list) do
        if i > NAMES_SHOWN then parts[#parts + 1] = "+" .. (#list - NAMES_SHOWN); break end
        parts[#parts + 1] = ColorName(o) .. (fmt and fmt(o) or "")
    end
    return table.concat(parts, ", ")
end

-- The same colours the game uses, for the focused alt's skill.
-- The fourth return names it, for the detail pane (#269); nil when unknown.
local function DifficultyColor(r, rank)
    if not r or not rank then return 1, 1, 1 end
    if r.learn and rank < r.learn then return 0.9, 0.2, 0.2, "too low" end
    local c = r.colors
    if not c then return 1, 1, 1 end
    if rank < c[2] then return 1, 0.5, 0.25, "orange" end
    if rank < c[3] then return 1, 1, 0, "yellow" end
    if rank < c[4] then return 0.25, 0.75, 0.25, "green" end
    return 0.5, 0.5, 0.5, "grey"
end

-- Owners of every line, computed once per redraw and shared by the picker, the
-- cards and the rows.
local function AllOwners()
    local by = {}
    for _, p in ipairs(PROFESSIONS) do
        local list, hidden = Owners(p.line)
        by[p.line] = { list = list, hidden = hidden }
    end
    return by
end

------------------------------------------------------------
-- Reagents across the stable (#268)
--
-- RecipeData carries each recipe's reagents (the client's SpellReagents), flat:
-- { item, count, item, count... }. The counts are the Warband plugin's: it
-- publishes AltStable.ItemHolders while it is loaded - every alt's bags and
-- bank. Without it nothing is claimed about who holds what: "not counted" is
-- not "nobody has any".
------------------------------------------------------------

local function ReagentsCounted()
    return type(AltStable.ItemHolders) == "function"
end

-- One item's holders, hidden alts left out, most first, or nil when Warband's
-- answer could not be read (it threw, or gave no list): unknown, which is not
-- zero (Codex review of #277). `cache` (optional) is one per redraw: a list
-- asks for the same Empty Vial a hundred times.
local function Holders(item, cache)
    if cache and cache[item] then return cache[item] end
    local ok, _, list, unseen = pcall(AltStable.ItemHolders, item)
    if not ok or type(list) ~= "table" then return nil end
    -- Our own alts whose bags or bank were never read (#423), hidden ones left
    -- out as everywhere here: "nobody has it" can't be said while there are any.
    local notRead = 0
    for _, g in ipairs(type(unseen) == "table" and unseen or {}) do
        if not IsHidden(g) then notRead = notRead + 1 end
    end
    local total, out = 0, {}
    for _, h in ipairs(list) do
        -- Bags and bank only: an item in the mail can't be crafted with until it
        -- is taken (#312), so a holder with nothing else is no holder here.
        local n = (h.bags or 0) + (h.bank or 0)
        if not IsHidden(h.guid) and n > 0 then
            total = total + n
            out[#out + 1] = { guid = h.guid, name = h.name, class = h.class, n = n, bankStale = h.bankStale }
        end
    end
    table.sort(out, function(a, b)
        if a.n ~= b.n then return a.n > b.n end
        return (a.name or "") < (b.name or "")
    end)
    local res = { total = total, list = out, unseen = notRead }
    if cache then cache[item] = res end
    return res
end

-- What stops one alt mailing another (#386): "faction", "ruleset", or nil when
-- nothing does. The rule is the core's (AltStable.Barriers), shared with the
-- item tooltips' faction and ruleset options (#403).
local function Barrier(fromGuid, toGuid)
    local otherFaction, otherRuleset = AltStable.Barriers(fromGuid, toGuid)
    if otherFaction then return "faction" end
    if otherRuleset then return "ruleset" end
    return nil
end

-- What the stable can do about one recipe, or nil and why when nothing can be
-- said: "none" (no reagent data), "absent" (no Warband to count with), "failed"
-- (a count could not be read - nothing is claimed then either). Pure over the stores:
--   reagents = { { item, need, total, holders, reach } } for one craft; `reach`
--              the most any one crafter can gather of it (its own and what can
--              be mailed to it), nil without crafters
--   enough   = every reagent's total across the stable covers one craft
--   ready    = one of the crafters can gather every reagent (#386)
--   crafters = for each of `knowers`: { owner, ready, short = { { item, need, have, from,
--              away, wall } } }, `from` the alt holding the most that can mail it;
--              when what can be mailed falls short, `away` the one holding the most
--              that can't, `wall` why ("faction" or "ruleset"). An empty `short` is
--              "has it all"
local function ReagentPlan(id, knowers, cache)
    local list = Reagents(id)
    if not list then return nil, "none" end
    if not ReagentsCounted() then return nil, "absent" end
    local plan = { reagents = {}, enough = true, ready = false, crafters = {} }
    for i = 1, #list - 1, 2 do
        local item, need = list[i], list[i + 1]
        local h = Holders(item, cache)
        if not h then return nil, "failed" end
        plan.reagents[#plan.reagents + 1] = { item = item, need = need, total = h.total, holders = h.list,
                                              unseen = h.unseen or 0 }
        if h.total < need then plan.enough = false end
    end
    for _, o in ipairs(knowers or {}) do
        local short, ready = {}, true
        for _, g in ipairs(plan.reagents) do
            local have, reach, from, away, wall = 0, 0, nil, nil, nil
            for _, h in ipairs(g.holders) do
                if h.guid == o.guid then
                    have = h.n
                    reach = reach + h.n
                else
                    local w = Barrier(h.guid, o.guid)
                    if not w then
                        reach = reach + h.n
                        from = from or h
                    elseif not away then
                        away, wall = h, w
                    end
                end
            end
            g.reach = math.max(g.reach or 0, reach)
            if reach < g.need then ready = false end
            if have < g.need then
                -- The blocked holder is named whenever what can be mailed
                -- falls short, even beside one who can (Codex review of #388).
                local blocked = reach < g.need
                short[#short + 1] = { item = g.item, need = g.need, have = have, from = from,
                                      away = blocked and away or nil, wall = blocked and wall or nil,
                                      unseen = g.unseen }
            end
        end
        if ready then plan.ready = true end
        plan.crafters[#plan.crafters + 1] = { owner = o, short = short, ready = ready }
    end
    return plan
end

-- Item names from the client, asked for once when not cached yet (the next
-- hover has them); "item 2840" until then.
local itemRequested = {}
local function ItemName(item)
    local n
    if C_Item and C_Item.GetItemNameByID then
        local ok, v = pcall(C_Item.GetItemNameByID, item); if ok then n = v end
    end
    if n and n ~= "" then return n end
    if not itemRequested[item] and C_Item and C_Item.RequestLoadItemDataByID then
        itemRequested[item] = true
        pcall(C_Item.RequestLoadItemDataByID, item)
    end
    return "item " .. item
end

local CRAFTERS_SHOWN = 4

-- The reagent block of a recipe row's tooltip, as { left, right, lr, lg, lb, rr, rg, rb }
-- lines (a nil right is a single line). Pure, so tests read it.
local function ReagentLines(id, knowers)
    local list, fromWindow = Reagents(id)
    if not list then return {} end
    -- Flagged (#348): these amounts are the profession window's, because
    -- AltStable's own data says otherwise.
    local out = { fromWindow and { "Reagents", "as the profession window showed", 1, 0.82, 0, 0.6, 0.6, 0.6 }
                  or { "Reagents", nil, 1, 0.82, 0 } }
    local plan, why = ReagentPlan(id, knowers)
    if not plan then
        for i = 1, #list - 1, 2 do
            out[#out + 1] = { list[i + 1] .. " x " .. ItemName(list[i]), nil, 1, 1, 1 }
        end
        out[#out + 1] = { why == "failed" and "The counts across your alts could not be read."
                          or "Turn on the Warband Bank tab to count them across your alts.", nil, 0.6, 0.6, 0.6 }
        return out
    end
    local stale, unread = false, false
    for _, g in ipairs(plan.reagents) do
        local parts = {}
        for i, h in ipairs(g.holders) do
            -- Every holder counts toward the total, so every one's bank age
            -- does - not only the three named (Codex review of #277).
            if h.bankStale then stale = true end
            if i <= 3 then
                parts[#parts + 1] = ColorName(h) .. " " .. h.n
            elseif i == 4 then
                parts[#parts + 1] = "+" .. (#g.holders - 3)
            end
        end
        -- With crafters, what one of them can gather (#386), and the stable's
        -- total beside it when that is more: enough held only on the other
        -- faction is not enough. Without crafters, the stable's total.
        local shown, ofTotal = g.total, ""
        if #plan.crafters > 0 then
            shown = g.reach or 0
            if shown < g.total then ofTotal = " |cff999999of " .. g.total .. "|r" end
        end
        local ok = shown >= g.need
        -- Short, with some of our alts unread: maybe not short at all (#423).
        if not ok and (g.unseen or 0) > 0 then unread = true end
        out[#out + 1] = { g.need .. " x " .. ItemName(g.item),
                          (ok and "|cff40ff40" or "|cffff4040") .. shown .. "|r" .. ofTotal ..
                          (#parts > 0 and ("  " .. table.concat(parts, ", ")) or ""),
                          1, 1, 1, 1, 1, 1 }
    end
    if stale then out[#out + 1] = { "Some bank counts are over a week old.", nil, 0.6, 0.6, 0.6 } end
    if unread then
        out[#out + 1] = { "Some of your alts' bags or bank aren't recorded yet.", nil, 0.6, 0.6, 0.6 }
    end
    for i, c in ipairs(plan.crafters) do
        if i > CRAFTERS_SHOWN then
            out[#out + 1] = { "+" .. (#plan.crafters - CRAFTERS_SHOWN) .. " more who know it", nil, 0.6, 0.6, 0.6 }
            break
        end
        local right
        if #c.short == 0 then
            right = "|cff40ff40has the reagents|r"
        else
            local s = c.short[1]
            -- Who can mail it, and who holds it but can't (#386).
            local whoParts = {}
            if s.from then whoParts[#whoParts + 1] = ColorName(s.from) .. " has " .. s.from.n end
            if s.away then
                whoParts[#whoParts + 1] = ColorName(s.away) .. " has " .. s.away.n .. ", other " .. s.wall
            end
            -- Nobody named: "nobody (else) has it" only when every one of our
            -- alts' bags and bank was read; otherwise none is recorded (#423).
            local who
            if #whoParts > 0 then
                who = " (" .. table.concat(whoParts, "; ") .. ")"
            elseif (s.unseen or 0) > 0 then
                who = s.have > 0 and " (none recorded elsewhere)" or " (none recorded)"
            else
                who = s.have > 0 and " (nobody else has it)" or " (nobody has it)"
            end
            right = "needs " .. (s.need - s.have) .. " " .. ItemName(s.item) .. who ..
                (#c.short > 1 and (" +" .. (#c.short - 1)) or "")
        end
        out[#out + 1] = { ColorName(c.owner), right, 1, 1, 1, 1, 1, 1 }
    end
    return out
end

-- Builds the list the panel shows. Pure: state in, rows out, so tests drive it.
--   state = { line, search, filter ("all"|"known"|"missing"|"nobody"|"craftable"|"wishlist"),
--             onlyDrops, onlyFavor,
--             focus (guid), owners (from AllOwners, optional) }
local function BuildRows(state)
    local lines = {}
    local search = (state.search or ""):lower()
    if search ~= "" then
        for _, p in ipairs(PROFESSIONS) do lines[#lines + 1] = p.line end   -- search spans them all
    else
        lines[1] = state.line
    end
    local ownersBy = state.owners or AllOwners()
    local reagentCache = {}
    local rows = {}
    for _, line in ipairs(lines) do
        local entry = ownersBy[line] or { list = {}, hidden = 0 }
        local owners = entry.list
        local focus
        for _, o in ipairs(owners) do if o.guid == state.focus then focus = o end end
        local nobodyText = NobodyText(owners, entry.hidden)
        for id in pairs(Catalogue(line, owners)) do
            local r = Data()[id]
            local name = RecipeName(id)
            local keep = search == "" or (name and name:lower():find(search, 1, true))
            if keep and state.onlyDrops and not HasNonTrainerSource(r) then keep = false end
            if keep and state.onlyFavor and not (r and r.favor) then keep = false end
            if keep then
                local knownBy, wantedBy = {}, {}
                for _, o in ipairs(owners) do
                    if o.known[id] then knownBy[#knownBy + 1] = o end
                    if Wants(o.guid, id) then wantedBy[#wantedBy + 1] = o end
                end
                local f = state.filter or "all"
                -- A card is selected, but its alt has no `line`: a search spans
                -- every line. It is still the one asked about, never everyone,
                -- so this line has nothing of its (#363). A recipe on two lines
                -- shows on the alt's own one.
                local elsewhere = state.focus and not focus
                if f == "known" then
                    if focus then keep = focus.known[id] and true or false
                    elseif elsewhere then keep = false
                    else keep = #knownBy > 0 end
                elseif f == "missing" then
                    -- Missing is a claim about what someone does NOT know: only
                    -- ever made for an alt with a complete scan - and never for
                    -- a profession it does not have.
                    if focus then
                        keep = focus.state == "full" and not focus.known[id]
                    elseif elsewhere then
                        keep = false
                    else
                        keep = false
                        for _, o in ipairs(owners) do
                            if o.state == "full" and not o.known[id] then keep = true; break end
                        end
                    end
                elseif f == "nobody" then
                    keep = #knownBy == 0
                elseif f == "craftable" then
                    -- Someone (the focused alt, if one is) knows it, and can
                    -- gather every reagent for one craft: its own, and what its
                    -- other alts can mail it - not the other faction's (#386).
                    -- Not counted (no Warband) keeps nothing: it is not a yes.
                    local crafters
                    if focus then crafters = focus.known[id] and { focus } or nil
                    elseif not elsewhere and #knownBy > 0 then crafters = knownBy end
                    local plan = crafters and ReagentPlan(id, crafters, reagentCache)
                    keep = plan and plan.ready or false
                elseif f == "wishlist" then
                    -- The focused alt's stars, or everyone's. By the selected
                    -- card, not this line's owner: a search spans lines the
                    -- alt does not have, and there "no focus" is not "nobody
                    -- selected" (Codex review of #362).
                    if state.focus then keep = Wants(state.focus, id) else keep = #wantedBy > 0 end
                end
                if keep then
                    rows[#rows + 1] = { id = id, line = line, name = name, recipe = r, knownBy = knownBy,
                                        wantedBy = wantedBy, owners = owners, focus = focus,
                                        selected = state.focus,
                                        nobody = #knownBy == 0 and nobodyText or nil }
                end
            end
        end
    end
    table.sort(rows, function(a, b)
        if a.line ~= b.line then return a.line < b.line end
        local la, lb = (a.recipe and a.recipe.learn) or 9999, (b.recipe and b.recipe.learn) or 9999
        if la ~= lb then return la < lb end
        return (a.name or ("~" .. a.id)) < (b.name or ("~" .. b.id))
    end)
    return rows
end

-- One card per owner: skill, known count against the catalogue, cooldowns.
local function Cards(line, owners)
    owners = owners or Owners(line)
    local total = 0
    for _ in pairs(Catalogue(line, owners)) do total = total + 1 end
    local cards = {}
    local prefix = "cd_" .. BY_LINE[line].label .. "@"
    for _, o in ipairs(owners) do
        local n = 0
        for _ in pairs(o.known) do n = n + 1 end
        local cd
        local char = AltStableDB and AltStableDB[o.guid]
        for k, v in pairs(char or {}) do
            local expiry = type(k) == "string" and k:sub(1, #prefix) == prefix and tonumber(v)
            if expiry then
                local left = expiry - time()
                if not cd or left < cd.left then cd = { label = k:sub(#prefix + 1), left = left } end
            end
        end
        cards[#cards + 1] = { owner = o, known = n, total = total, cooldown = cd }
    end
    return cards
end

------------------------------------------------------------
-- Item tooltips: who wants this recipe, who can craft this
--
-- On a recipe item (RecipeData's `items`, matched by name - an item that
-- matched no recipe or several has no line at all):
--   Wanted by      alts that starred it (#271), unless turned off
--   Known by       alts that know it
--   Meets skill    complete scan, the skill, not known - skill ONLY
--   Skill too low  complete scan, not known, under the requirement
--   Not scanned    owners of the profession we cannot speak for
-- On a crafted item: Crafted by, across every recipe that makes it.
-- Hidden characters are left out, as everywhere in the tab.
------------------------------------------------------------

-- How good a verdict is, for an owner of a recipe on several lines: judged by
-- the best of them - knowing it through Tailoring is knowing it, whatever the
-- Leatherworking skill (review of #133).
local VERDICT_RANK = { known = 5, meets = 4, low = 3, unknown = 2, unscanned = 1 }

-- The "Wanted by" line, on unless turned off in Options (#271).
local function WishTooltipOn()
    return not (AltStableConfig and AltStableConfig.professionsWishTooltip == false)
end

-- The lines for one item, as { { label, text }, ... }. Pure, so tests read it.
local function TooltipLines(itemID)
    itemID = tonumber(itemID)
    if not itemID then return {} end
    BuildIndexes()
    -- Owners once per line for this whole tooltip, however many recipes ask.
    local ownersCache = {}
    local function OwnersOf(line)
        if not ownersCache[line] then
            local list, hidden = Owners(line)
            ownersCache[line] = { list = list, hidden = hidden }
        end
        return ownersCache[line]
    end

    local out = {}
    for _, id in ipairs(byTeach[itemID] or {}) do
        local r = Data()[id]
        local best, order, hidden = {}, {}, 0
        for _, line in ipairs(r.skill or {}) do
            if BY_LINE[line] then
                local o = OwnersOf(line)
                hidden = hidden + o.hidden
                for _, owner in ipairs(o.list) do
                    local v = Verdict(owner, id)
                    local held = best[owner.guid]
                    if not held then order[#order + 1] = owner.guid end
                    if not held or VERDICT_RANK[v] > VERDICT_RANK[held.v] then
                        best[owner.guid] = { v = v, o = owner }
                    end
                end
            end
        end
        local groups = { known = {}, meets = {}, low = {}, unknown = {}, unscanned = {} }
        for _, guid in ipairs(order) do
            local b = best[guid]
            table.insert(groups[b.v], b.o)
        end
        if #order == 0 and hidden == 0 then
            -- Only when nobody at all has it: a hidden alt may.
            local names = {}
            for _, line in ipairs(r.skill or {}) do if BY_LINE[line] then names[#names + 1] = BY_LINE[line].label end end
            out[#out + 1] = { "|cff888888AltStable|r", "|cff888888No alt has " ..
                (#names > 0 and table.concat(names, " or ") or "this profession") .. "|r" }
        end
        if WishTooltipOn() then
            local wanted = {}
            for _, guid in ipairs(order) do
                if Wants(guid, id) then wanted[#wanted + 1] = best[guid].o end
            end
            if #wanted > 0 then out[#out + 1] = { "Wanted by", NameList(wanted) } end
        end
        if #groups.known > 0 then out[#out + 1] = { "Known by", NameList(groups.known) } end
        if #groups.meets > 0 then
            out[#out + 1] = { "Meets skill", NameList(groups.meets, function(o) return " (" .. o.rank .. ")" end) }
        end
        if #groups.low > 0 then
            out[#out + 1] = { "Skill too low", NameList(groups.low, function(o)
                return " (" .. o.rank .. ", needs " .. r.learn .. ")" end) }
        end
        if #groups.unknown > 0 then out[#out + 1] = { "Requirement unknown", NameList(groups.unknown) } end
        if #groups.unscanned > 0 then out[#out + 1] = { "Not scanned", NameList(groups.unscanned) } end
    end

    local crafters, seen = {}, {}
    for _, id in ipairs(byOutput[itemID] or {}) do
        local r = Data()[id]
        for _, line in ipairs(r.skill or {}) do
            if BY_LINE[line] then
                for _, o in ipairs(OwnersOf(line).list) do
                    if Verdict(o, id) == "known" and not seen[o.guid] then
                        seen[o.guid] = true
                        crafters[#crafters + 1] = o
                    end
                end
            end
        end
    end
    if #crafters > 0 then out[#out + 1] = { "Crafted by", NameList(crafters) } end
    return out
end

------------------------------------------------------------
-- The Cooldowns view (#545): every cooldown, and where each character stands
--
-- The core's view (Cooldowns.lua, SheetUI) asks these while this plugin is
-- loaded, and falls back to the recorded cooldowns alone when it isn't.
------------------------------------------------------------

-- Every cooldown: RecipeData's `cd` labels, grouped by label and line, plus the
-- item cooldowns. { key, prof, line, label, learn (the lowest of its recipes),
-- spells (by learn, then ID), item }, by profession, then label. Built once,
-- kept on AT (BootstrapPlugin is at Lua 5.1's 60 upvalues: no new local for it).
local function CooldownCatalogue()
    if AT.cdCatalogue then return AT.cdCatalogue end
    local byKey, list = {}, {}
    local function Add(line, label, learn, spell, item)
        local p = BY_LINE[line]
        if not p then return end
        local key = "cd_" .. p.label .. "@" .. label
        local e = byKey[key]
        if not e then
            e = { key = key, prof = p.label, line = line, label = label, spells = {}, item = item }
            byKey[key] = e
            list[#list + 1] = e
        end
        if spell then e.spells[#e.spells + 1] = spell end
        if learn and (not e.learn or learn < e.learn) then e.learn = learn end
    end
    for id, r in pairs(Data()) do
        if r.cd then
            for _, line in ipairs(r.skill or {}) do Add(line, r.cd, r.learn, id) end
        end
    end
    for _, ic in ipairs(ITEM_COOLDOWNS) do Add(ic.line, ic.label, ic.learn, nil, ic.item) end
    local data = Data()
    for _, e in ipairs(list) do
        table.sort(e.spells, function(a, b)
            local la, lb = data[a].learn or 9999, data[b].learn or 9999
            if la ~= lb then return la < lb end
            return a < b
        end)
    end
    table.sort(list, function(a, b)
        if a.prof ~= b.prof then return a.prof < b.prof end
        return a.label < b.label
    end)
    -- Its icon: the item it is used from, or what its lowest recipe makes
    -- (Arcanite Bar for the transmutes, Gold Bar, Mooncloth).
    for _, e in ipairs(list) do
        local first = e.spells[1] and data[e.spells[1]]
        e.iconItem = e.item or (first and first.makes)
    end
    AT.cdCatalogue = list
    return list
end

-- Where a character stands on one cooldown, and its skill:
--   "known"      a recipe of it is in the snapshot (a partial one too)
--   "unscanned"  owns the line, no complete scan to say more
--   "learnable"  complete scan, none known, skill high enough
--   "low"        skill under the lowest recipe's
--   "usable"     an item's: skill high enough (whether it is carried, nobody knows)
--   nil          doesn't have the profession
-- The Recipe Book's evidence order (Verdict), by OwnerOf's ownership rule.
local function CooldownStanding(char, entry)
    local guid = type(char) == "table" and char.guid
    local o = guid and entry and OwnerOf(guid, char, entry.line)
    if not o then return nil end
    if entry.item then
        return (o.rank >= (entry.learn or 0)) and "usable" or "low", o.rank
    end
    for _, id in ipairs(entry.spells) do
        if o.known[id] then return "known", o.rank end
    end
    if o.state ~= "full" then return "unscanned", o.rank end
    if entry.learn and o.rank >= entry.learn then return "learnable", o.rank end
    return "low", o.rank
end

-- Where a recipe is learned. A recipe item with no source code on Wowhead
-- (Legionite) is still a recipe item.
local function CooldownSourceText(r)
    if r and not r.src and r.items then return "Recipe item" end
    return SourceText(r)
end

-- The tooltip's recipe lines for one character, { left, right }: the recipes
-- of the cooldown it knows, then those its skill meets with where each is
-- learned; with none of either, the lowest one, what it needs and where.
local function CooldownRecipeLines(char, entry)
    local guid = type(char) == "table" and char.guid
    local o = guid and entry and not entry.item and OwnerOf(guid, char, entry.line)
    if not o then return {} end
    local known, meets, lowest = {}, {}, nil
    for _, id in ipairs(entry.spells) do
        local v = Verdict(o, id)
        local name = RecipeName(id) or ("Recipe " .. id)
        if v == "known" then known[#known + 1] = { name, "|cff1eff00Known|r" }
        elseif v == "meets" then meets[#meets + 1] = { name, CooldownSourceText(Data()[id]) }
        elseif not lowest then lowest = id end
    end
    for _, l in ipairs(meets) do known[#known + 1] = l end
    if #known == 0 and lowest then
        local r = Data()[lowest]
        known[1] = { RecipeName(lowest) or ("Recipe " .. lowest),
                     (r.learn and ("needs " .. r.learn .. ", ") or "") .. CooldownSourceText(r) }
    end
    return known
end

AltStable.CooldownCatalogue = CooldownCatalogue
AltStable.CooldownStanding = CooldownStanding
AltStable.CooldownRecipeLines = CooldownRecipeLines

local function TooltipsOn()
    return not (AltStableConfig and AltStableConfig.professionsTooltips == false)
end

-- Installed at bootstrap, so it works before the tab is ever opened. A post-call
-- re-fires on every render of the tooltip (an async item load re-renders it
-- from scratch), so lines are added once per render, never twice.
-- OnTooltipSetItem throws on Forever; TooltipDataProcessor is the replacement
-- (Warband, #10).
local ttHooked = false
local function EnsureTooltipHook()
    if ttHooked or not AltStable.HookItemTooltip then return end
    ttHooked = AltStable.HookItemTooltip(function(tt, id)
        if not TooltipsOn() then return end
        local lines = TooltipLines(id)
        if #lines == 0 then return end
        tt:AddLine(" ")
        for _, l in ipairs(lines) do
            tt:AddDoubleLine(l[1], l[2], 1, 0.82, 0, 1, 1, 1)
        end
        if tt.Show then tt:Show() end
    end)
end

------------------------------------------------------------
-- The panel
------------------------------------------------------------

local panel, emptyFS, statusFS, searchBox, strip
local PAD, ROW_H, ICON, STAR = 10, 20, 16, 14
local PICK = 26
local CARD_W, CARD_H = 150, 46
local TOP_PICK = 8
local TOP_FILTER = TOP_PICK + PICK + 8
local TOP_CARDS = TOP_FILTER + 26
local TOP_ROWS = TOP_CARDS + CARD_H + 10

local function C(key, fallback) return (AltStable.C and AltStable.C[key]) or fallback end

-- The shared class colours (Theme.lua), with a neutral fallback.
local function ClassRGB(class)
    if AltStable.GetClassRGB then return AltStable.GetClassRGB(class) end
    return 0.9, 0.9, 0.9
end

local function KnownByText(row)
    if row.nobody then return "|cff888888" .. row.nobody .. "|r" end
    local parts = {}
    for i, o in ipairs(row.knownBy) do
        if i > 4 then parts[#parts + 1] = "+" .. (#row.knownBy - 4); break end
        parts[#parts + 1] = ColorName(o)
    end
    return table.concat(parts, ", ")
end

local function Countdown(left)
    if left <= 0 then return "ready" end
    local d, h, m = math.floor(left / 86400), math.floor(left % 86400 / 3600), math.floor(left % 3600 / 60)
    if d > 0 then return d .. "d " .. h .. "h" end
    if h > 0 then return h .. "h " .. m .. "m" end
    return m .. "m"
end

local function RowOnEnter(self)
    local row = self.row
    if not row then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    local ok = pcall(function() GameTooltip:SetHyperlink("spell:" .. row.id) end)
    if not ok or GameTooltip:NumLines() == 0 then
        GameTooltip:ClearLines()
        GameTooltip:AddLine(row.name or ("Recipe " .. row.id), 1, 1, 1)
    end
    local r = row.recipe
    GameTooltip:AddLine(" ")
    GameTooltip:AddDoubleLine("Requires", r and r.learn and tostring(r.learn) or "unknown", 1, 0.82, 0, 1, 1, 1)
    GameTooltip:AddDoubleLine("Source", SourceText(r), 1, 0.82, 0, 1, 1, 1)
    if #(row.wantedBy or {}) > 0 then
        GameTooltip:AddDoubleLine("Wanted by", NameList(row.wantedBy), 1, 0.82, 0, 1, 1, 1)
    end
    if #row.knownBy > 0 then
        GameTooltip:AddLine("Known by", 1, 0.82, 0)
        for _, o in ipairs(row.knownBy) do
            local cr, cg, cb = ClassRGB(o.class)
            GameTooltip:AddDoubleLine(o.name, o.rank .. (o.max > 0 and ("/" .. o.max) or ""), cr, cg, cb, 1, 1, 1)
        end
    else
        GameTooltip:AddLine(row.nobody, 0.6, 0.6, 0.6)
    end
    local meets = {}
    for _, o in ipairs(row.owners) do if MeetsSkill(o, row.id) then meets[#meets + 1] = o end end
    if #meets > 0 then
        GameTooltip:AddLine("Meets the skill requirement", 0.25, 1, 0.25)
        for _, o in ipairs(meets) do
            local cr, cg, cb = ClassRGB(o.class)
            GameTooltip:AddDoubleLine(o.name, o.rank .. "/" .. o.max, cr, cg, cb, 1, 1, 1)
        end
        GameTooltip:AddLine("Specialisation, reputation and quest requirements are not checked.", 0.6, 0.6, 0.6, true)
    end
    local unknown = {}
    for _, o in ipairs(row.owners) do if Verdict(o, row.id) == "unscanned" then unknown[#unknown + 1] = o.name end end
    if #unknown > 0 then
        GameTooltip:AddLine("Not scanned yet: " .. table.concat(unknown, ", "), 0.6, 0.6, 0.6, true)
    end
    local reagents = ReagentLines(row.id, row.knownBy)
    if #reagents > 0 then GameTooltip:AddLine(" ") end
    for _, l in ipairs(reagents) do
        if l[2] then GameTooltip:AddDoubleLine(l[1], l[2], l[3], l[4], l[5], l[6], l[7], l[8])
        else GameTooltip:AddLine(l[1], l[3], l[4], l[5], true) end
    end
    GameTooltip:Show()
end

local function RowOnLeave() GameTooltip:Hide() end

-- A row's star (#271): what it shows, and whether a click stars or unstars.
--   "on"   wanted - by the alt in focus, or (no focus) by anyone
--   "off"  the alt in focus could star it: our own, and it does not know it
--   nil    nothing to show
-- Without an alt in focus, nobody is the one wanting it: nothing to click.
-- Whom a row's star is for: the alt in focus, or with no card selected, the
-- character being played where it has the row's profession (#365). Nil when a
-- card is selected whose alt lacks this profession (a search spans them all).
local function StarTarget(row)
    if row.focus then return row.focus end
    if row.selected then return nil end
    local me = UnitGUID and UnitGUID("player")
    for _, o in ipairs(row.owners or {}) do
        if o.guid == me then return o end
    end
end

local function StarState(row)
    local t = StarTarget(row)
    if t then
        local can = CanWish(t.guid) and not t.known[row.id]
        if Wants(t.guid, row.id) then return "on", can end
        if can then return "off", true end
    end
    -- A selected card speaks for its alt alone. Only with none does a star
    -- the played character can't use still show that someone wants it.
    if row.selected then return nil, false end
    return #(row.wantedBy or {}) > 0 and "on" or nil, false
end

-- SetWish refuses what may not be starred: another account's alt, a known recipe.
local function StarOnClick(self)
    local row = self:GetParent().row
    local t = row and StarTarget(row)
    if not t then return end
    if SetWish(t.guid, row.id, not Wants(t.guid, row.id)) then AT.Refresh() end
end

local function StarOnEnter(self)
    local row = self:GetParent().row
    if not row then return end
    local state, can = StarState(row)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("Wishlist", 1, 1, 1)
    if #(row.wantedBy or {}) > 0 then
        GameTooltip:AddDoubleLine("Wanted by", NameList(row.wantedBy), 1, 0.82, 0, 1, 1, 1)
    end
    local f = StarTarget(row)
    if not f then
        GameTooltip:AddLine("Pick an alt's card above to star recipes for it.", 0.7, 0.7, 0.7, true)
    elseif can then
        GameTooltip:AddLine((state == "on" and "Click: no longer wanted by " or "Click: wanted by ") .. ColorName(f),
            0.7, 0.7, 0.7, true)
    elseif f.known[row.id] then
        GameTooltip:AddLine(ColorName(f) .. " knows it.", 0.7, 0.7, 0.7, true)
    else
        GameTooltip:AddLine(ColorName(f) .. " is played on another account: star it there.", 0.7, 0.7, 0.7, true)
    end
    GameTooltip:Show()
end

------------------------------------------------------------
-- The detail pane (#269): a recipe's whole story beside the list, open while
-- a row is selected (a click on it; again, or the pane's close, shuts it).
-- While it is open the list drops its Source and Known-by columns: the pane
-- says both in full.
------------------------------------------------------------

local PANE_W, PANE_LABEL_W, PANE_HEAD = 300, 84, 8 + 28 + 10
local QUALITY_HEX = { [0] = "9d9d9d", [1] = "ffffff", [2] = "1eff00", [3] = "0070dd", [4] = "a335ee",
                      [5] = "ff8000", [6] = "e6cc80", [7] = "00ccff" }

local function Hex(r, g, b)
    return string.format("|cff%02x%02x%02x", math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5),
                         math.floor(b * 255 + 0.5))
end

-- What the client holds about an item, or nil until it has it. A cache miss
-- returns nothing at all (forever-api-notes, "Items"), so the load is asked for
-- once and GET_ITEM_INFO_RECEIVED redraws.
local itemInfoAsked = {}
local function ItemInfo(item)
    item = tonumber(item)
    if not item then return nil end
    local ok, name, link, quality, _, minLevel, _, _, _, _, icon = pcall(AltStable.API.GetItemInfo, item)
    if ok and name then
        return { name = name, link = link, quality = quality, minLevel = tonumber(minLevel) or 0, icon = icon }
    end
    if not itemInfoAsked[item] and C_Item and C_Item.RequestLoadItemDataByID then
        itemInfoAsked[item] = true
        pcall(C_Item.RequestLoadItemDataByID, item)
    end
end

local function QualityName(info, fallback)
    local hex = info and QUALITY_HEX[info.quality]
    local name = info and info.name or fallback
    return hex and ("|cff" .. hex .. name .. "|r") or name
end

local function Names(list, fmt)
    local parts = {}
    for _, o in ipairs(list) do parts[#parts + 1] = ColorName(o) .. (fmt and fmt(o) or "") end
    return table.concat(parts, ", ")
end

-- What the pane shows for a row: { icon, title, link, lines }, the lines in
-- ReagentLines' shape ({ left, right, lr, lg, lb, rr, rg, rb }; no right = one
-- line across). Pure, so tests read it.
local function DetailLines(row)
    local id, r, f = row.id, row.recipe, row.focus
    local info = r and r.makes and ItemInfo(r.makes)
    local d = { icon = info and info.icon or RecipeIcon(id), link = info and info.link,
                title = QualityName(info, row.name or RecipeName(id) or ("Recipe " .. id)), lines = {} }
    local lines = d.lines
    local function add(left, right) lines[#lines + 1] = { left, right, 1, 0.82, 0, 1, 1, 1 } end
    local function note(text) lines[#lines + 1] = { text, nil, 0.6, 0.6, 0.6 } end

    -- The level to use what it makes, against the alt in focus.
    if info and info.minLevel > 1 then
        local c = f and AltStableDB and AltStableDB[f.guid]
        local lvl = c and tonumber(c.level)
        if lvl and lvl < info.minLevel then
            add("Use", "|cffff4040level " .. info.minLevel .. "|r  (" .. ColorName(f) .. " is " .. lvl .. ")")
        else
            add("Use", "level " .. info.minLevel)
        end
    elseif r and r.makes and not info then
        add("Use", "|cff888888loading...|r")
    end

    -- The skill: to learn it, the colour thresholds, and where the focused alt is.
    add("Requires", r and r.learn and tostring(r.learn) or "unknown")
    if r and r.colors then
        local c = r.colors
        add("Difficulty", Hex(1, 0.5, 0.25) .. c[1] .. "|r  " .. Hex(1, 1, 0) .. c[2] .. "|r  "
            .. Hex(0.25, 0.75, 0.25) .. c[3] .. "|r  " .. Hex(0.5, 0.5, 0.5) .. c[4] .. "|r")
    end
    if f then
        local cr, cg, cb, word = DifficultyColor(r, f.rank)
        add(ColorName(f), Hex(cr, cg, cb) .. f.rank .. (word and (", " .. word) or "") .. "|r")
    end

    -- Where it comes from, and the recipe items that teach it.
    add("Source", SourceText(r))
    for _, item in ipairs(r and r.items or {}) do
        add("Recipe", QualityName(ItemInfo(item), "item " .. item))
    end

    -- Who wants it, knows it, could learn it - the Verdict rule.
    lines[#lines + 1] = { " " }
    if #(row.wantedBy or {}) > 0 then add("Wanted by", Names(row.wantedBy)) end
    local groups = { known = {}, meets = {}, low = {}, unknown = {}, unscanned = {} }
    for _, o in ipairs(row.owners or {}) do table.insert(groups[Verdict(o, id)], o) end
    if #groups.known > 0 then add("Known by", Names(groups.known)) end
    if #groups.meets > 0 then
        add("Meets skill", Names(groups.meets, function(o) return " (" .. o.rank .. ")" end))
    end
    if #groups.low > 0 then
        add("Skill too low", Names(groups.low, function(o) return " (" .. o.rank .. ")" end))
    end
    if #groups.unknown > 0 then add("Req. unknown", Names(groups.unknown)) end
    if #groups.unscanned > 0 then add("Not scanned", Names(groups.unscanned)) end
    if #groups.known == 0 and row.nobody then note(row.nobody) end
    if #groups.meets > 0 then note("Specialisation, reputation and quest requirements are not checked.") end

    -- Reagents, with the counts across the alts (#268).
    local reagents = ReagentLines(id, row.knownBy or {})
    if #reagents > 0 then lines[#lines + 1] = { " " } end
    for _, l in ipairs(reagents) do lines[#lines + 1] = l end
    return d
end

local pane
local function PaneOnLeave() GameTooltip:Hide() end

local function BuildPane()
    pane = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    pane:SetWidth(PANE_W)
    pane:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -PAD - 12, -TOP_ROWS)
    pane:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -PAD - 12, PAD)
    pane:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    pane:SetBackdropColor(1, 1, 1, 0.04)
    pane:SetBackdropBorderColor(1, 0.82, 0, 0.25)
    if pane.SetClipsChildren then pane:SetClipsChildren(true) end

    -- Icon and name: hover for the item, shift-click to link it.
    pane.head = CreateFrame("Button", nil, pane)
    pane.head:SetPoint("TOPLEFT", pane, "TOPLEFT", 8, -8)
    pane.head:SetPoint("RIGHT", pane, "RIGHT", -48, 0)
    pane.head:SetHeight(28)
    pane.icon = pane.head:CreateTexture(nil, "ARTWORK")
    pane.icon:SetSize(28, 28)
    pane.icon:SetPoint("LEFT", pane.head, "LEFT", 0, 0)
    pane.title = pane.head:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    pane.title:SetPoint("LEFT", pane.icon, "RIGHT", 6, 0)
    pane.title:SetPoint("RIGHT", pane.head, "RIGHT", 0, 0)
    pane.title:SetJustifyH("LEFT")
    pane.head:SetScript("OnClick", function()
        local handle = rawget(_G, "HandleModifiedItemClick")
        if pane.link and handle then handle(pane.link) end
    end)
    pane.head:SetScript("OnEnter", function(self)
        if not pane.link then return end
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        pcall(GameTooltip.SetHyperlink, GameTooltip, pane.link)
        GameTooltip:Show()
    end)
    pane.head:SetScript("OnLeave", PaneOnLeave)

    -- The wishlist star (#271): the same as the row's, reading pane.row.
    pane.star = CreateFrame("Button", nil, pane)
    pane.star:SetSize(STAR + 2, STAR + 2)
    pane.star:SetPoint("TOPRIGHT", pane, "TOPRIGHT", -28, -14)
    pane.star.tex = pane.star:CreateTexture(nil, "ARTWORK")
    pane.star.tex:SetAllPoints()
    pane.star:SetScript("OnClick", StarOnClick)
    pane.star:SetScript("OnEnter", StarOnEnter)
    pane.star:SetScript("OnLeave", PaneOnLeave)

    pane.close = CreateFrame("Button", nil, pane)
    pane.close:SetSize(16, 16)
    pane.close:SetPoint("TOPRIGHT", pane, "TOPRIGHT", -6, -14)
    pane.close.text = pane.close:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    pane.close.text:SetAllPoints()
    pane.close.text:SetText("x")
    pane.close:SetScript("OnClick", function() AT.CloseRecipe() end)

    -- The body under the header scrolls on its own (the wheel over the pane):
    -- at the tab's 400 px floor it has about 200 px, and a recipe's lines,
    -- names in full and reagents run well past that (Codex review of #367).
    -- A slim bar on its right says where it is, when there is more to see.
    pane.body = CreateFrame("Frame", nil, pane)
    pane.body:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, -PANE_HEAD)
    pane.body:SetPoint("BOTTOMRIGHT", pane, "BOTTOMRIGHT", 0, 4)
    if pane.body.SetClipsChildren then pane.body:SetClipsChildren(true) end
    pane.thumb = pane.body:CreateTexture(nil, "OVERLAY")
    pane.thumb:SetWidth(3)
    pane.thumb:SetColorTexture(1, 1, 1, 0.28)
    pane.thumb:Hide()
    pane.lines = {}
    pane:Hide()
end

-- The same star a row draws, on a texture.
local function DrawStar(tex, row)
    local star, can = StarState(row)
    if star then
        tex:SetAtlas(star == "on" and "auctionhouse-icon-favorite" or "auctionhouse-icon-favorite-off")
        tex:SetAlpha((star == "on" and can) and 1 or (star == "on" and 0.7 or 0.45))
        tex:Show()
    else
        tex:Hide()
    end
end

local function LayoutPane(row)
    pane.row = row
    local d = DetailLines(row)
    pane.icon:SetTexture(d.icon)
    pane.title:SetText(d.title)
    pane.link = d.link
    DrawStar(pane.star.tex, row)
    -- Text and width first, to measure the wrapped heights; then the places,
    -- once the scroll offset is clamped to what there is.
    local inner, tops, y = PANE_W - 20, {}, 0
    for i, l in ipairs(d.lines) do
        local p = pane.lines[i]
        if not p then
            p = { l = pane.body:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"),
                  r = pane.body:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall") }
            p.l:SetJustifyH("LEFT"); p.r:SetJustifyH("LEFT")
            p.l:SetWordWrap(true); p.r:SetWordWrap(true)
            pane.lines[i] = p
        end
        p.l:SetText(l[1] or "")
        p.l:SetTextColor(l[3] or 1, l[4] or 0.82, l[5] or 0)
        local h
        if l[2] then
            p.l:SetWidth(PANE_LABEL_W)
            p.r:SetWidth(inner - PANE_LABEL_W - 6)
            p.r:SetText(l[2])
            p.r:SetTextColor(l[6] or 1, l[7] or 1, l[8] or 1)
            p.r:Show()
            h = math.max(tonumber(p.l:GetStringHeight()) or 12, tonumber(p.r:GetStringHeight()) or 12)
        else
            p.l:SetWidth(inner)
            p.r:Hide()
            h = tonumber(p.l:GetStringHeight()) or 12
        end
        p.l:Show()
        tops[i] = y
        y = y + h + 3
    end
    for i = #d.lines + 1, #pane.lines do pane.lines[i].l:Hide(); pane.lines[i].r:Hide() end

    local view = tonumber(pane.body:GetHeight()) or 0
    local maxOff = math.max(0, y - view)
    AT.paneMax = maxOff
    AT.paneOffset = math.max(0, math.min(AT.paneOffset or 0, maxOff))
    local off = AT.paneOffset
    for i = 1, #d.lines do
        local p = pane.lines[i]
        p.l:ClearAllPoints(); p.r:ClearAllPoints()
        p.l:SetPoint("TOPLEFT", pane.body, "TOPLEFT", 8, -(tops[i] - off))
        p.r:SetPoint("TOPLEFT", pane.body, "TOPLEFT", 8 + PANE_LABEL_W + 6, -(tops[i] - off))
    end
    if maxOff > 0 and view > 0 then
        local th = math.max(12, view * view / y)
        pane.thumb:ClearAllPoints()
        pane.thumb:SetHeight(th)
        pane.thumb:SetPoint("TOPRIGHT", pane.body, "TOPRIGHT", -3, -((view - th) * off / maxOff))
        pane.thumb:Show()
    else
        pane.thumb:Hide()
    end
    pane:Show()
end

-- The wheel over the open pane scrolls its body, three lines a notch.
function AT.ScrollPane(delta)
    if not (pane and pane:IsShown() and pane.row) then return end
    AT.paneOffset = (AT.paneOffset or 0) - delta * 3 * 14
    LayoutPane(pane.row)
end

-- A click on a row opens it; on the open one, closes it.
function AT.ToggleRecipe(row)
    if not row then return end
    local sel = AT.selected
    if sel and sel.id == row.id and sel.line == row.line then
        AT.selected = nil
    else
        AT.selected = { id = row.id, line = row.line }
    end
    AT.paneOffset = 0   -- another recipe starts at its top
    AT.Refresh()
end

function AT.CloseRecipe()
    AT.selected = nil
    AT.Refresh()
end

local function RowOnClick(self) AT.ToggleRecipe(self.row) end

local function GetRow(i)
    local row = AT.rowsPool[i]
    if row then return row end
    row = CreateFrame("Button", nil, panel)
    row:SetHeight(ROW_H)
    row.sel = row:CreateTexture(nil, "BACKGROUND")
    row.sel:SetAllPoints()
    row.sel:SetColorTexture(1, 0.82, 0, 0.12)
    row.sel:Hide()
    row.star = CreateFrame("Button", nil, row)
    row.star:SetSize(STAR, STAR)
    row.star:SetPoint("LEFT", row, "LEFT", 0, 0)
    row.star.tex = row.star:CreateTexture(nil, "ARTWORK")
    row.star.tex:SetAllPoints()
    row.star:SetScript("OnClick", StarOnClick)
    row.star:SetScript("OnEnter", StarOnEnter)
    row.star:SetScript("OnLeave", RowOnLeave)
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(ICON, ICON)
    row.icon:SetPoint("LEFT", row, "LEFT", STAR + 2, 0)
    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
    row.name:SetWidth(210 - STAR - 2)
    row.name:SetJustifyH("LEFT")
    row.skill = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.skill:SetPoint("LEFT", row, "LEFT", 240, 0)
    row.skill:SetWidth(34)
    row.skill:SetJustifyH("RIGHT")
    row.source = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.source:SetPoint("LEFT", row, "LEFT", 284, 0)
    row.source:SetWidth(110)
    row.source:SetJustifyH("LEFT")
    row.known = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.known:SetPoint("LEFT", row, "LEFT", 400, 0)
    row.known:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    row.known:SetJustifyH("LEFT")
    row:SetScript("OnEnter", RowOnEnter)
    row:SetScript("OnLeave", RowOnLeave)
    row:SetScript("OnClick", RowOnClick)
    AT.rowsPool[i] = row
    return row
end

local function VisibleRows()
    local h = panel and panel:GetHeight() or 0
    if not h or h < 100 then h = 400 end
    return math.max(1, math.floor((h - TOP_ROWS - PAD) / ROW_H))
end

function AT.Layout()
    if not panel or not panel:IsShown() then return end
    local rows = AT.rows or {}
    local visible = VisibleRows()
    local maxStart = math.max(0, #rows - visible)
    AT.scrollRow = math.max(0, math.min(AT.scrollRow or 0, maxStart))
    if AT.scrollBar then
        if maxStart > 0 then
            AT.scrollBar._syncing = true
            AT.scrollBar:SetMinMaxValues(0, maxStart)
            AT.scrollBar:SetValue(AT.scrollRow)
            AT.scrollBar._syncing = false
            AT.scrollBar:Show()
        else
            AT.scrollBar:Hide()
        end
    end
    local n = 0
    local open = pane and pane:IsShown() and AT.selected
    for slot = 1, visible do
        local r = rows[AT.scrollRow + slot]
        if not r then break end
        n = n + 1
        local w = GetRow(n)
        w:ClearAllPoints()
        w:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD, -(TOP_ROWS + (slot - 1) * ROW_H))
        if open then
            w:SetPoint("RIGHT", pane, "LEFT", -8, 0)
        else
            w:SetPoint("RIGHT", panel, "RIGHT", -PAD - 12, 0)
        end
        w.row = r
        -- With no star, the button stays to hover: its tooltip says how to star.
        DrawStar(w.star.tex, r)
        w.sel:SetShown(open and open.id == r.id and open.line == r.line or false)
        w.source:SetShown(not open)
        w.known:SetShown(not open)
        w.icon:SetTexture(RecipeIcon(r.id))
        local label = r.name or ("#" .. r.id)
        if (AT.search or "") ~= "" then label = label .. "  |cff888888" .. BY_LINE[r.line].label .. "|r" end
        w.name:SetText(label)
        local fr, fg, fb = 1, 1, 1
        if r.focus then fr, fg, fb = DifficultyColor(r.recipe, r.focus.rank) end
        w.name:SetTextColor(fr, fg, fb)
        w.skill:SetText(r.recipe and r.recipe.learn and tostring(r.recipe.learn) or "?")
        w.source:SetText(SourceText(r.recipe))
        w.known:SetText(KnownByText(r))
        w:Show()
    end
    for i = n + 1, #AT.rowsPool do AT.rowsPool[i]:Hide() end
end

local function CardsFit()
    local width = panel and panel:GetWidth()
    if not width or width < 200 then width = 600 end
    return math.max(1, math.floor((width - 2 * PAD) / (CARD_W + 6)))
end

-- Sideways through the alt cards, a card at a time.
local function ScrollCards(delta)
    local fit = CardsFit()
    local maxStart = math.max(0, #(AT.cardData or {}) - fit)
    AT.cardStart = math.max(0, math.min((AT.cardStart or 0) - delta, maxStart))
end

local function LayoutCards()
    local cards = AT.cardData or {}
    local fit = CardsFit()
    ScrollCards(0)
    for i = 1, fit do
        local data = cards[AT.cardStart + i]
        local card = AT.cards[i]
        if not card then
            card = CreateFrame("Button", nil, panel, "BackdropTemplate")
            card:SetSize(CARD_W, CARD_H)
            card:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
            card.l1 = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            card.l1:SetPoint("TOPLEFT", card, "TOPLEFT", 6, -5)
            card.l1:SetPoint("RIGHT", card, "RIGHT", -6, 0)
            card.l1:SetJustifyH("LEFT")
            card.l2 = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            card.l2:SetPoint("TOPLEFT", card.l1, "BOTTOMLEFT", 0, -2)
            card.l2:SetPoint("RIGHT", card, "RIGHT", -6, 0)
            card.l2:SetJustifyH("LEFT")
            card.l3 = card:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            card.l3:SetPoint("TOPLEFT", card.l2, "BOTTOMLEFT", 0, -2)
            card.l3:SetPoint("RIGHT", card, "RIGHT", -6, 0)
            card.l3:SetJustifyH("LEFT")
            card:SetScript("OnClick", function(self)
                local g = self.data and self.data.owner.guid
                AT.focus = (AT.focus ~= g) and g or nil
                AT.Refresh()
            end)
            AT.cards[i] = card
        end
        if data then
            local o = data.owner
            card.data = data
            card:ClearAllPoints()
            card:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD + (i - 1) * (CARD_W + 6), -TOP_CARDS)
            local focused = AT.focus == o.guid
            card:SetBackdropColor(1, 1, 1, focused and 0.12 or 0.04)
            card:SetBackdropBorderColor(1, 0.82, 0, focused and 0.9 or 0.15)
            card.l1:SetText(ColorName(o) .. "  |cffffffff" .. o.rank .. (o.max > 0 and ("/" .. o.max) or "") .. "|r")
            if o.state == "unscanned" then
                card.l2:SetText("|cff888888not scanned - open the window|r")
            elseif o.state == "partial" then
                card.l2:SetText(data.known .. " known |cff888888(partial)|r")
            else
                card.l2:SetText(data.known .. "/" .. data.total .. " known")
            end
            -- Selected, but played on another account: its stars are set
            -- there, and a row shows none to click (#365). Said while it is
            -- selected, before a cooldown.
            local char = AltStableDB and AltStableDB[o.guid]
            if focused and not (type(char) == "table" and char.scannedHere) then
                card.l3:SetText("|cff888888Stars: on its own account|r")
            elseif data.cooldown then
                local cd = data.cooldown
                card.l3:SetText(cd.label .. ": " .. (cd.left <= 0 and "|cff1eff00ready|r" or Countdown(cd.left)))
            else
                card.l3:SetText("")
            end
            card:Show()
        else
            card:Hide()
        end
    end
    for i = fit + 1, #AT.cards do AT.cards[i]:Hide() end
end

local function LayoutPicker(ownersBy)
    for i, p in ipairs(PROFESSIONS) do
        local b = AT.pick[i]
        local n = #ownersBy[p.line].list
        b.count:SetText(n > 0 and tostring(n) or "")
        b.icon:SetDesaturated(n == 0)
        b:SetAlpha(n == 0 and 0.45 or 1)
        b.sel:SetShown(AT.line == p.line and (AT.search or "") == "")
    end
end

function AT.Refresh()
    if not panel or not panel:IsShown() then return end
    local ownersBy = AllOwners()
    AT._owners = ownersBy
    if not AT.line then
        -- Start on the profession most alts have.
        local best, bestN = PROFESSIONS[1].line, -1
        for _, p in ipairs(PROFESSIONS) do
            local n = #ownersBy[p.line].list
            if n > bestN then best, bestN = p.line, n end
        end
        AT.line = best
    end
    -- A focus on someone without this profession is dropped, not carried over.
    AT.cardData = Cards(AT.line, ownersBy[AT.line].list)
    local stillThere = false
    for _, c in ipairs(AT.cardData) do if c.owner.guid == AT.focus then stillThere = true end end
    if not stillThere then AT.focus = nil end
    AT.rows = BuildRows({ line = AT.line, search = AT.search, filter = AT.filter,
                          onlyDrops = AT.onlyDrops, onlyFavor = AT.onlyFavor, focus = AT.focus,
                          owners = ownersBy })
    -- The open recipe, if it is still listed; a filter or another profession
    -- that drops it closes the pane.
    local selRow
    if AT.selected then
        for _, r in ipairs(AT.rows) do
            if r.id == AT.selected.id and r.line == AT.selected.line then selRow = r; break end
        end
        if not selRow then AT.selected = nil end
    end
    if pane then
        if selRow then LayoutPane(selRow) else pane:Hide() end
    end
    LayoutPicker(ownersBy)
    LayoutCards()
    for key, b in pairs(AT.filterButtons) do b.sel:SetShown(AT.filter == key) end
    local p = BY_LINE[AT.line]
    if #AT.cardData == 0 and (AT.search or "") == "" then
        emptyFS:SetText("Nobody has " .. p.label .. " - or they have not opened its window yet.")
        emptyFS:Show()
    else
        emptyFS:Hide()
    end
    -- Craftable counts with Warband's bags and banks: without it, say why it is empty.
    if AT.filter == "craftable" and not ReagentsCounted() then
        statusFS:SetText("Needs the Warband Bank tab")
    else
        statusFS:SetText(#AT.rows .. " recipes")
    end
    AT.Layout()
end

-- Many characters arrive in one sync; redraw once, on the next frame.
function AT.RequestRefresh()
    if AT._pending then return end
    AT._pending = true
    C_Timer.After(0, function() AT._pending = false; if AT.isActive then AT.Refresh() end end)
end

-- One wheel handler for the whole panel: over the card strip it moves the
-- cards sideways, anywhere else it scrolls the list. (A second wheel-enabled
-- frame for the strip sat under the panel and never got the wheel; review of
-- #132.)
function AT.OnWheel(delta, overCards, overPane)
    if overCards then
        ScrollCards(delta)
        LayoutCards()
    elseif overPane then
        AT.ScrollPane(delta)
    else
        AT.scrollRow = math.max(0, (AT.scrollRow or 0) - delta * 3)
        AT.Layout()
    end
end

local FILTERS = { { "all", "All" }, { "known", "Known" }, { "missing", "Missing" }, { "nobody", "Nobody" },
                  { "craftable", "Craftable" }, { "wishlist", "Wishlist" } }

-- The filter last picked (#385), so a player who only wants what their alts
-- know picks Known once. Per account and not synced, like the tooltip
-- switches: an unknown or missing value is All.
local function SavedFilter()
    local f = AltStableConfig and AltStableConfig.professionsFilter
    for _, def in ipairs(FILTERS) do
        if def[1] == f then return f end
    end
    return "all"
end

local function PickFilter(key)
    AT.filter, AT.scrollRow = key, 0
    if AltStable.SetConfigValue then AltStable.SetConfigValue("professionsFilter", key) end
    AT.Refresh()
end

local function BuildPanel(mainFrame)
    if panel then return end
    AT.filter = SavedFilter()
    local sidebarW = (AltStable.LAYOUT and AltStable.LAYOUT.SIDEBAR_WIDTH) or 230
    local titleH   = (AltStable.LAYOUT and AltStable.LAYOUT.TITLE_H) or 30
    panel = CreateFrame("Frame", nil, mainFrame, "BackdropTemplate")
    -- Beside the sidebar's edge, so it follows when the sidebar collapses (#150).
    if not (AltStable.AnchorBesideSidebar and AltStable.AnchorBesideSidebar(panel, mainFrame)) then
        panel:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", sidebarW + 1, -titleH)
    end
    panel:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", 0, 1)
    local bg = C("BG_MAIN", { 0.05, 0.05, 0.05, 0.95 })
    if not (AltStable.SkinPanelFill and AltStable.SkinPanelFill(panel, mainFrame, bg)) and AltStable.ApplyBGOnly then
        AltStable.ApplyBGOnly(panel, bg[1], bg[2], bg[3], bg[4])
    end
    panel:Hide()

    -- Profession picker
    AT.pick = {}
    for i, p in ipairs(PROFESSIONS) do
        local b = CreateFrame("Button", nil, panel)
        b:SetSize(PICK, PICK)
        b:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD + (i - 1) * (PICK + 4), -TOP_PICK)
        b.icon = b:CreateTexture(nil, "ARTWORK")
        b.icon:SetAllPoints()
        b.icon:SetTexture(p.icon)
        b.sel = b:CreateTexture(nil, "OVERLAY")
        b.sel:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", 0, -3)
        b.sel:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", 0, -3)
        b.sel:SetHeight(2)
        b.sel:SetColorTexture(1, 0.82, 0, 1)
        b.count = b:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
        b.count:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", 1, -1)
        b:SetScript("OnClick", function()
            AT.line, AT.focus, AT.scrollRow, AT.cardStart = p.line, nil, 0, 0
            if searchBox then searchBox:SetText("") end
            AT.Refresh()
        end)
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
            GameTooltip:AddLine(p.label, 1, 1, 1)
            local n = AT._owners and AT._owners[p.line] and #AT._owners[p.line].list or 0
            GameTooltip:AddLine(n == 1 and "1 alt" or (n .. " alts"), 0.7, 0.7, 0.7)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", RowOnLeave)
        AT.pick[i] = b
    end

    searchBox = CreateFrame("EditBox", nil, panel, "SearchBoxTemplate")
    searchBox:SetSize(170, 20)
    searchBox:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -PAD, -TOP_PICK - 3)
    searchBox:HookScript("OnTextChanged", function(self)
        AT.search = self:GetText() or ""
        AT.scrollRow = 0
        AT.Refresh()
    end)

    -- Filters
    AT.filterButtons = {}
    local x = PAD
    for _, f in ipairs(FILTERS) do
        local key, label = f[1], f[2]
        local b = CreateFrame("Button", nil, panel)
        b:SetHeight(18)
        b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        b.text:SetPoint("CENTER")
        b.text:SetText(label)
        b:SetWidth(58)
        b:SetPoint("TOPLEFT", panel, "TOPLEFT", x, -TOP_FILTER)
        b.sel = b:CreateTexture(nil, "BACKGROUND")
        b.sel:SetAllPoints()
        b.sel:SetColorTexture(1, 0.82, 0, 0.18)
        b:SetScript("OnClick", function() PickFilter(key) end)
        AT.filterButtons[key] = b
        x = x + 62
    end
    local drops = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    drops:SetSize(18, 18)
    drops:SetPoint("TOPLEFT", panel, "TOPLEFT", x + 10, -TOP_FILTER)
    drops:SetScript("OnClick", function(self) AT.onlyDrops = self:GetChecked() and true or false; AT.scrollRow = 0; AT.Refresh() end)
    local dropsLbl = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    dropsLbl:SetPoint("LEFT", drops, "RIGHT", 2, 0)
    dropsLbl:SetText("Not from a trainer")
    dropsLbl:SetTextColor(unpack(C("TEXT_DIM", { 0.7, 0.7, 0.7 })))

    -- Bought with Merchant's Favor (#270): with Missing and an alt in focus,
    -- what that alt could buy at a quartermaster.
    local favor = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    favor:SetSize(18, 18)
    favor:SetPoint("LEFT", dropsLbl, "RIGHT", 16, 0)
    favor:SetScript("OnClick", function(self) AT.onlyFavor = self:GetChecked() and true or false; AT.scrollRow = 0; AT.Refresh() end)
    AT.favorCheck = favor
    local favorLbl = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    favorLbl:SetPoint("LEFT", favor, "RIGHT", 2, 0)
    favorLbl:SetText("Favor")
    favorLbl:SetTextColor(unpack(C("TEXT_DIM", { 0.7, 0.7, 0.7 })))

    -- The item-tooltip lines, on by default; the one setting this plugin has,
    -- kept in its panel as Warband keeps its own.
    local tips = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    tips:SetSize(18, 18)
    tips:SetPoint("LEFT", favorLbl, "RIGHT", 16, 0)
    tips:SetChecked(TooltipsOn())
    tips:SetScript("OnClick", function(self)
        AltStable.SetConfigValue("professionsTooltips", self:GetChecked() and true or false)
    end)
    local tipsLbl = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    tipsLbl:SetPoint("LEFT", tips, "RIGHT", 2, 0)
    tipsLbl:SetText("On item tooltips")
    tipsLbl:SetTextColor(unpack(C("TEXT_DIM", { 0.7, 0.7, 0.7 })))

    statusFS = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    statusFS:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -PAD, -TOP_FILTER - 3)

    emptyFS = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    emptyFS:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD, -TOP_CARDS - 14)
    emptyFS:SetTextColor(unpack(C("TEXT_DIM", { 0.7, 0.7, 0.7 })))
    emptyFS:Hide()

    -- The card strip's area, for the wheel handler to test against. No mouse
    -- of its own: the cards on top of it take the clicks.
    strip = CreateFrame("Frame", nil, panel)
    strip:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -TOP_CARDS)
    strip:SetPoint("RIGHT", panel, "RIGHT", 0, 0)
    strip:SetHeight(CARD_H)

    panel:EnableMouseWheel(true)
    panel:SetScript("OnMouseWheel", function(_, delta)
        AT.OnWheel(delta, strip:IsMouseOver(), pane and pane:IsShown() and pane:IsMouseOver())
    end)

    -- Built last, as in Warband: the expendable part goes at the end.
    local bar = CreateFrame("Slider", nil, panel)
    AT.scrollBar = bar
    bar:SetWidth(10)
    bar:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -4, -TOP_ROWS)
    bar:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -4, PAD)
    bar:SetOrientation("VERTICAL")
    bar:SetValueStep(1)
    bar:SetObeyStepOnDrag(true)
    local track = bar:CreateTexture(nil, "BACKGROUND")
    track:SetAllPoints()
    track:SetColorTexture(1, 1, 1, 0.05)
    local thumb = bar:CreateTexture(nil, "OVERLAY")
    thumb:SetColorTexture(1, 1, 1, 0.28)
    thumb:SetSize(10, 32)
    bar:SetThumbTexture(thumb)
    bar:SetScript("OnValueChanged", function(self, value)
        if self._syncing then return end
        AT.scrollRow = math.floor((value or 0) + 0.5)
        AT.Layout()
    end)
    bar:Hide()
    BuildPane()
end

local function HookRefresh()
    if AT._refreshHooked or type(AltStable.RefreshSheet) ~= "function" then return end
    local prev = AltStable.RefreshSheet
    AltStable.RefreshSheet = function(...)
        prev(...)
        if AT.isActive then AT.RequestRefresh() end
    end
    AT._refreshHooked = true
end

local GRID_PARTS = { "bodyScroll", "frozenScroll", "headerScroll", "frozenHeader", "hScrollBar", "totalsBar" }

-- The size the tab opens at, and the least it works in (#150). It had no floor
-- at all, so it took whatever the tab before it left. The recipe row needs
-- about 700 (name 210, skill, source, then the "known by" names from 400 on),
-- and the toolbar - twelve profession buttons and the search box - about 570.
-- The filter row needs about 700 since Craftable made it five buttons (#268),
-- and 740 since the Favor checkbox (#270): the three checkboxes and the status
-- text on its right would overlap below that. Wishlist made it six (#271),
-- 62 more.
-- Below the floor's height there is no room for rows under the cards.
local PREFERRED_PANEL_W = 820
local MIN_PANEL_W, MIN_PANEL_H = 802, 400
AT.PREFERRED_PANEL_W, AT.MIN_PANEL_W, AT.MIN_PANEL_H = PREFERRED_PANEL_W, MIN_PANEL_W, MIN_PANEL_H

-- The floor as a window size: the panel sits beside the sidebar, under the
-- title, 1 above the window's bottom (BuildPanel).
function AT.HoldMinSize()
    if not AltStable.EnsureWindowMinSize then return end
    local sidebarW = (AltStable.LAYOUT and AltStable.LAYOUT.SIDEBAR_WIDTH) or 230
    local titleH   = (AltStable.LAYOUT and AltStable.LAYOUT.TITLE_H) or 30
    AltStable.EnsureWindowMinSize(sidebarW + 1 + MIN_PANEL_W, titleH + 1 + MIN_PANEL_H)
end

function AT.Activate(mainFrame)
    if AltStable.RequestPluginSize then AltStable.RequestPluginSize(PREFERRED_PANEL_W) end
    AT.HoldMinSize()
    BuildPanel(mainFrame)
    HookRefresh()
    AT.isActive = true
    for _, k in ipairs(GRID_PARTS) do if mainFrame[k] then mainFrame[k]:Hide() end end
    panel:Show()
    AT.Refresh()
end

function AT.Deactivate(mainFrame)
    AT.isActive = false
    if panel then panel:Hide() end
    for _, k in ipairs(GRID_PARTS) do if mainFrame[k] then mainFrame[k]:Show() end end
end

------------------------------------------------------------
-- Bootstrap + events
------------------------------------------------------------

-- The wishlist's test exports (#271), added here: BootstrapPlugin is at Lua
-- 5.1's 60 upvalues.
local function WishExports(t)
    t.Wants, t.CanWish, t.SetWish, t.ClearLearnedWishes = Wants, CanWish, SetWish, ClearLearnedWishes
    t.ParseWish, t.StarState, t.StarOnClick, t.StarOnEnter = ParseWish, StarState, StarOnClick, StarOnEnter
    t.WishTooltipOn, t.FILTERS = WishTooltipOn, FILTERS
    t.DetailLines, t.ItemInfo, t.itemInfoAsked = DetailLines, ItemInfo, itemInfoAsked
    t.Pane = function() return pane end
    return t
end

local function BootstrapPlugin()
    if not AltStable or not AltStable.RegisterPlugin then
        Print("AltStable not found - make sure it is installed and enabled.")
        return
    end
    AltStable.RegisterPlugin({
        id            = ADDON_ID,
        label         = "Recipe Book",
        icon          = (AltStable.MEDIA_PATH or "Interface\\AddOns\\AltStable\\Media\\") .. "Icons\\recipes.tga",
        _isPlugin     = true,
        -- Our snapshots carry their own stamp, so the core hands them over even
        -- when it keeps its own copy of the character record.
        independentStamp = true,
        OnActivate    = function(mf) AT.Activate(mf) end,
        -- The window changed size under us: maximize, restore, the sidebar (#150).
        OnResize      = function()
            if not AT.isActive then return end
            -- Expanding the sidebar narrows the panel while the window keeps
            -- its width (#157): the floor again, as Warband does.
            AT.HoldMinSize()
            AT.Refresh()
        end,
        OnDeactivate  = function(mf) AT.Deactivate(mf) end,
        OnSerialize   = function(g) return SerializePlayer(g) end,
        OnDeserialize = function(g, b) return DeserializePlayer(g, b) end,
        OnCleanup     = function(keepGuid) Cleanup(keepGuid) end,
        DropForgottenOrphans = function() return DropForgottenOrphans() end,
        OnForget      = function(guid) if guid then AltStableProfessionsDB[guid] = nil end end,
        _at           = AT,
        _test = WishExports({
            SerializePlayer = SerializePlayer, DeserializePlayer = DeserializePlayer, ParseProfs = ParseProfs,
            Candidate = Candidate, Commit = Commit, RunScan = RunScan, ScheduleScan = ScheduleScan,
            OnShow = OnShow, OnClose = OnClose, OnChanging = OnChanging, OnRecipeLearned = OnRecipeLearned,
            RefreshOwnership = RefreshOwnership, ReadOwned = ReadOwned, ApplyCooldowns = ApplyCooldowns,
            CooldownLabel = CooldownLabel,
            ReadItemCooldowns = ReadItemCooldowns, QueueItemRead = QueueItemRead, ClearCooldowns = ClearCooldowns,
            Owners = Owners, AllOwners = AllOwners, Catalogue = Catalogue, BuildRows = BuildRows, Cards = Cards,
            MeetsSkill = MeetsSkill, DifficultyColor = DifficultyColor, HasNonTrainerSource = HasNonTrainerSource,
            SourceText = SourceText,
            RecipeName = RecipeName, OnSpellData = OnSpellData,
            TooltipLines = TooltipLines, EnsureTooltipHook = EnsureTooltipHook,
            DropForgottenOrphans = DropForgottenOrphans, Cleanup = Cleanup, BootstrapPlugin = BootstrapPlugin,
            PROFESSIONS = PROFESSIONS, scan = scan, names = names, requested = requested,
            ResetState = function()
                pendingLoss = nil; lineIndex, byTeach, byOutput = nil, nil, nil
                AT.cdCatalogue = nil
            end,
            Verdict = Verdict, NobodyText = NobodyText, NameList = NameList,
            ReagentPlan = ReagentPlan, ReagentLines = ReagentLines, ReagentsCounted = ReagentsCounted,
            Barrier = Barrier,
            Reagents = Reagents, SchematicReagents = SchematicReagents, SameReagents = SameReagents,
            ApplyWindowReagents = ApplyWindowReagents,
            ItemName = ItemName, itemRequested = itemRequested,
            SavedFilter = SavedFilter,
        }),
    })

    EnsureTooltipHook()
    DropForgottenOrphans()
    -- A full pull from every peer when there is nothing to build on: no
    -- snapshot of a character the core knows (orphans don't count). Switching
    -- the plugin on from Options is covered by the core (SetPluginEnabled resets
    -- the watermarks for any plugin it loads). NOT on "loaded on demand" - that
    -- is every login (see Warband's bootstrap).
    if AltStable.ResetPeerWatermarks and AltStable.HoldsAttached
       and not AltStable.HoldsAttached(AltStableProfessionsDB) then
        AltStable.ResetPeerWatermarks()
    end
    -- Once (#422): a star made on an offline alt before deltas could carry it
    -- is below every peer's watermark, with nothing to mark it. One full reply
    -- to each peer, now that this plugin can send it. The core clears the key
    -- again if a full reply goes out without this plugin registered.
    if AltStable.OnSyncScopeChanged and AltStable.SetConfigValue
       and not (AltStableConfig and AltStableConfig.wishDeltaRepair) then
        AltStable.OnSyncScopeChanged()
        AltStable.SetConfigValue("wishDeltaRepair", true)
    end
    -- The Shaker's cooldown (#460) after ownership: who is a leatherworker.
    C_Timer.After(4, function() RefreshOwnership(); ReadItemCooldowns() end)
end

local frame = CreateFrame("Frame")
local ownershipTimer
frame:SetScript("OnEvent", function(_, event, arg1, arg2, arg3)
    if event == "PLAYER_LOGIN" then
        C_Timer.After(1, BootstrapPlugin)
    elseif event == "TRADE_SKILL_SHOW" then
        OnShow()
    elseif event == "TRADE_SKILL_LIST_UPDATE" or event == "TRADE_SKILL_DATA_SOURCE_CHANGED" then
        if scan.open then ScheduleScan() end
    elseif event == "TRADE_SKILL_DATA_SOURCE_CHANGING" then
        OnChanging()
    elseif event == "TRADE_SKILL_CLOSE" then
        OnClose()
    elseif event == "NEW_RECIPE_LEARNED" then
        OnRecipeLearned(arg1)
    elseif event == "SKILL_LINES_CHANGED" then
        -- Also fires on every weapon skill-up: debounced, and cheap when nothing moved.
        if ownershipTimer then ownershipTimer:Cancel() end
        ownershipTimer = C_Timer.NewTimer(2, function() ownershipTimer = nil; RefreshOwnership() end)
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        -- A craft with the window open may have started a cooldown.
        if arg1 == "player" and scan.open then ScheduleScan() end
        -- The Salt Shaker used (#460): its spell is the third argument.
        if arg1 == "player" and ITEM_SPELLS[tonumber(arg3) or 0] then QueueItemRead() end
    elseif event == "BAG_UPDATE_COOLDOWN" or event == "BAG_UPDATE_DELAYED" then
        -- A cooldown started or ended, or the Shaker moved in or out (#460).
        QueueItemRead()
    elseif event == "SPELL_DATA_LOAD_RESULT" then
        OnSpellData(arg1, arg2)
    elseif event == "GET_ITEM_INFO_RECEIVED" then
        -- An item the open pane asked for (its own, or a reagent's name).
        local id = tonumber(arg1)
        if id and AT.isActive and AT.selected and (itemInfoAsked[id] or itemRequested[id]) then
            AT.RequestRefresh()
        end
    end
end)
for _, ev in ipairs({ "PLAYER_LOGIN", "TRADE_SKILL_SHOW", "TRADE_SKILL_LIST_UPDATE",
                      "TRADE_SKILL_DATA_SOURCE_CHANGED", "TRADE_SKILL_DATA_SOURCE_CHANGING",
                      "TRADE_SKILL_CLOSE", "NEW_RECIPE_LEARNED", "SKILL_LINES_CHANGED",
                      "SPELL_DATA_LOAD_RESULT", "GET_ITEM_INFO_RECEIVED",
                      "BAG_UPDATE_COOLDOWN", "BAG_UPDATE_DELAYED" }) do
    frame:RegisterEvent(ev)
end
-- The player's casts only: registered for every unit, each party, raid and
-- nameplate cast would wake this in combat.
if frame.RegisterUnitEvent then
    frame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
else
    frame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
end

-- Loaded on demand from the core's PLAYER_LOGIN handler, so PLAYER_LOGIN will
-- not fire for us again.
if IsLoggedIn() then
    C_Timer.After(1, BootstrapPlugin)
end
