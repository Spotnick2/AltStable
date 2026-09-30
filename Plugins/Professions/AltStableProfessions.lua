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
--                               full = time of the last COMPLETE scan, or nil } }
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
------------------------------------------------------------

AltStableProfessionsDB = AltStableProfessionsDB or {}

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

local AT = { isActive = false, search = "", filter = "all", onlyDrops = false, rowsPool = {}, cards = {} }

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

-- Per-line lists of recipes with a known requirement, built once: the tab asks
-- for a line's catalogue on every redraw, and walking 2500 recipes each time
-- (twelve times over while searching) is the one cost here that adds up.
local lineIndex
local function LineRecipes(line)
    if not lineIndex then
        lineIndex = {}
        for id, r in pairs(Data()) do
            if r.learn then
                for _, s in ipairs(r.skill or {}) do
                    lineIndex[s] = lineIndex[s] or {}
                    table.insert(lineIndex[s], id)
                end
            end
        end
    end
    return lineIndex[line] or {}
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

local function Changed(guid)
    if AltStable.TouchCharacter then AltStable.TouchCharacter(guid) end
    if AT.isActive and AT.RequestRefresh then AT.RequestRefresh() end
end

local function setsEqual(a, b)
    for k in pairs(a or {}) do if not (b and b[k]) then return false end end
    for k in pairs(b or {}) do if not (a and a[k]) then return false end end
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

-- cds = { [label] = seconds remaining } for the learned recipes whose cooldown
-- is RUNNING; knownLabels = every label a learned recipe files under. A ready
-- cooldown may come back as nil or as 0 (Retail returns nil; Forever is not
-- measured), so "known but not running" is what means ready. Returns true if
-- anything changed.
--   * a running cooldown is written as an absolute expiry; a shift under 60 s
--     is timing jitter between two reads and is not a change;
--   * one that has come back up keeps a past expiry, so the grid says "Ready!";
--   * a label no learned recipe files under any more takes its field with it.
local function ApplyCooldowns(char, label, cds, knownLabels)
    if type(char) ~= "table" then return false end
    local prefix, now, changed = "cd_" .. label .. "@", time(), false
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
    for key, v in pairs(char) do
        if type(key) == "string" and key:sub(1, #prefix) == prefix then
            local name = key:sub(#prefix + 1)
            if not knownLabels[name] then
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
    for _, id in ipairs(ids) do
        local oki, info = Try(t.GetRecipeInfo, id)
        -- Never measured to happen (727 IDs, no nil), but a half-read list
        -- would read as "unlearned" for everything missing: abandon instead.
        if not oki or type(info) ~= "table" then return nil, "incomplete" end
        if info.learned then
            known[id] = true
            local label = CooldownLabel(info.name)
            if label then
                labels[label] = true
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
    return { line = line, rank = tonumber(base.skillLevel) or 0, max = tonumber(base.maxSkillLevel) or 0,
             known = known, cds = cds, labels = labels, cdOk = cdOk }
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
    p.full = time()   -- "last verified", whether or not anything moved
    if changed then Bump(e) end
    local cdChanged = c.cdOk
        and ApplyCooldowns(AltStableDB and AltStableDB[guid], BY_LINE[c.line].label, c.cds, c.labels)
        or false
    -- A cooldown alone must reach peers too: the core only sends a character
    -- whose lastUpdate moved, and no recipe changed.
    if changed or cdChanged then Changed(guid) end
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

local function OnShow()   scan.open = true;  ScheduleScan() end
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
    Bump(e)
    Changed(guid)
end

------------------------------------------------------------
-- Sync
--   v1|s=<stamp>|p=<line>:<rank>:<max>:<full or ->:<id,id,...>;...
-- `p=` present and empty = "no professions". Missing = malformed.
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
    return BLOB_VERSION .. "|s=" .. e.stamp .. "|p=" .. table.concat(parts, ";")
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
    AltStableProfessionsDB[guid] = { stamp = stamp, profs = profs }
    -- No TouchCharacter: receiving is not a change of ours, and a relay that
    -- moved lastUpdate would make every peer re-send it forever.
    if AT.isActive and AT.RequestRefresh then AT.RequestRefresh() end
end

------------------------------------------------------------
-- Housekeeping
------------------------------------------------------------

local function PruneOrphans()
    for guid in pairs(AltStableProfessionsDB) do
        local c = AltStableDB and AltStableDB[guid]
        if type(c) ~= "table" or not c.name then AltStableProfessionsDB[guid] = nil end
    end
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
local function Owners(line)
    local out, hidden = {}, 0
    for guid, c in pairs(AltStableDB or {}) do
        if type(c) == "table" and c.name then
            local e = AltStableProfessionsDB[guid]
            local p = type(e) == "table" and e.profs and e.profs[line]
            local o
            if p then
                local state = p.full and "full" or (next(p.known or {}) and "partial" or "unscanned")
                o = { guid = guid, name = c.name, class = c.class, realm = c.realm,
                      rank = p.rank or 0, max = p.max or 0, known = p.known or {},
                      full = p.full, state = state }
            elseif not (type(e) == "table" and e.stamp) and CoreSkill(c, line) then
                o = { guid = guid, name = c.name, class = c.class, realm = c.realm,
                      rank = CoreSkill(c, line), max = 0, known = {}, state = "unscanned" }
            end
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

local function SourceText(r)
    if not r or not r.src then return "?" end
    local t = {}
    for _, c in ipairs(r.src) do t[#t + 1] = SOURCE_LABELS[c] or "Other" end
    return table.concat(t, ", ")
end

-- Any source a player can go and get it from, other than a trainer.
local function HasNonTrainerSource(r)
    for _, c in ipairs((r and r.src) or {}) do if c ~= TRAINER then return true end end
    return false
end

-- Meets the SKILL requirement - only that: specialisations, reputation and
-- quests are not in the data, and the tooltip says so. Offered only for an alt
-- with a complete scan, or "doesn't know it" is not something we know.
local function MeetsSkill(o, id)
    local r = Data()[id]
    return o.state == "full" and not o.known[id] and r and r.learn and o.rank >= r.learn or false
end

-- The same colours the game uses, for the focused alt's skill.
local function DifficultyColor(r, rank)
    if not r or not rank then return 1, 1, 1 end
    if r.learn and rank < r.learn then return 0.9, 0.2, 0.2 end
    local c = r.colors
    if not c then return 1, 1, 1 end
    if rank < c[2] then return 1, 0.5, 0.25 end
    if rank < c[3] then return 1, 1, 0 end
    if rank < c[4] then return 0.25, 0.75, 0.25 end
    return 0.5, 0.5, 0.5
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

-- Builds the list the panel shows. Pure: state in, rows out, so tests drive it.
--   state = { line, search, filter ("all"|"known"|"missing"|"nobody"), onlyDrops,
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
    local rows = {}
    for _, line in ipairs(lines) do
        local entry = ownersBy[line] or { list = {}, hidden = 0 }
        local owners = entry.list
        local focus
        for _, o in ipairs(owners) do if o.guid == state.focus then focus = o end end
        -- "Nobody knows" needs every owner scanned in full - hidden ones too,
        -- which are not in the list: one of them may know it.
        local allComplete = #owners > 0 and entry.hidden == 0
        for _, o in ipairs(owners) do if o.state ~= "full" then allComplete = false end end
        for id in pairs(Catalogue(line, owners)) do
            local r = Data()[id]
            local name = RecipeName(id)
            local keep = search == "" or (name and name:lower():find(search, 1, true))
            if keep and state.onlyDrops and not HasNonTrainerSource(r) then keep = false end
            if keep then
                local knownBy = {}
                for _, o in ipairs(owners) do if o.known[id] then knownBy[#knownBy + 1] = o end end
                local f = state.filter or "all"
                if f == "known" then
                    if focus then keep = focus.known[id] and true or false else keep = #knownBy > 0 end
                elseif f == "missing" then
                    -- Missing is a claim about what someone does NOT know: only
                    -- ever made for an alt with a complete scan.
                    if focus then
                        keep = focus.state == "full" and not focus.known[id]
                    else
                        keep = false
                        for _, o in ipairs(owners) do
                            if o.state == "full" and not o.known[id] then keep = true; break end
                        end
                    end
                elseif f == "nobody" then
                    keep = #knownBy == 0
                end
                if keep then
                    rows[#rows + 1] = { id = id, line = line, name = name, recipe = r, knownBy = knownBy,
                                        owners = owners, focus = focus,
                                        nobody = #knownBy == 0 and (allComplete and "Nobody knows" or "Nobody recorded") or nil }
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
-- The panel
------------------------------------------------------------

local panel, emptyFS, statusFS, searchBox, strip
local PAD, ROW_H, ICON = 10, 20, 16
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

local function ColorName(o)
    local esc = AltStable.ClassColor and AltStable.ClassColor(o.class) or ""
    return (esc ~= "" and esc or "|cffe6e6e6") .. (o.name or "?") .. "|r"
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
    for _, o in ipairs(row.owners) do if o.state ~= "full" and not o.known[row.id] then unknown[#unknown + 1] = o.name end end
    if #unknown > 0 then
        GameTooltip:AddLine("Not scanned yet: " .. table.concat(unknown, ", "), 0.6, 0.6, 0.6, true)
    end
    GameTooltip:Show()
end

local function RowOnLeave() GameTooltip:Hide() end

local function GetRow(i)
    local row = AT.rowsPool[i]
    if row then return row end
    row = CreateFrame("Button", nil, panel)
    row:SetHeight(ROW_H)
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(ICON, ICON)
    row.icon:SetPoint("LEFT", row, "LEFT", 0, 0)
    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
    row.name:SetWidth(210)
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
    for slot = 1, visible do
        local r = rows[AT.scrollRow + slot]
        if not r then break end
        n = n + 1
        local w = GetRow(n)
        w:ClearAllPoints()
        w:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD, -(TOP_ROWS + (slot - 1) * ROW_H))
        w:SetPoint("RIGHT", panel, "RIGHT", -PAD - 12, 0)
        w.row = r
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
            if data.cooldown then
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
                          onlyDrops = AT.onlyDrops, focus = AT.focus, owners = ownersBy })
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
    statusFS:SetText(#AT.rows .. " recipes")
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
function AT.OnWheel(delta, overCards)
    if overCards then
        ScrollCards(delta)
        LayoutCards()
    else
        AT.scrollRow = math.max(0, (AT.scrollRow or 0) - delta * 3)
        AT.Layout()
    end
end

local FILTERS = { { "all", "All" }, { "known", "Known" }, { "missing", "Missing" }, { "nobody", "Nobody" } }

local function BuildPanel(mainFrame)
    if panel then return end
    local sidebarW = (AltStable.LAYOUT and AltStable.LAYOUT.SIDEBAR_WIDTH) or 230
    local titleH   = (AltStable.LAYOUT and AltStable.LAYOUT.TITLE_H) or 30
    panel = CreateFrame("Frame", nil, mainFrame, "BackdropTemplate")
    panel:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", sidebarW + 1, -titleH)
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
        b:SetScript("OnClick", function() AT.filter = key; AT.scrollRow = 0; AT.Refresh() end)
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
        AT.OnWheel(delta, strip:IsMouseOver())
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

function AT.Activate(mainFrame)
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

local function BootstrapPlugin()
    if not AltStable or not AltStable.RegisterPlugin then
        Print("AltStable not found - make sure it is installed and enabled.")
        return
    end
    AltStable.RegisterPlugin({
        id            = ADDON_ID,
        label         = "Professions",
        icon          = (AltStable.MEDIA_PATH or "Interface\\AddOns\\AltStable\\Media\\") .. "Icons\\recipes.tga",
        _isPlugin     = true,
        -- Our snapshots carry their own stamp, so the core hands them over even
        -- when it keeps its own copy of the character record.
        independentStamp = true,
        OnActivate    = function(mf) AT.Activate(mf) end,
        OnDeactivate  = function(mf) AT.Deactivate(mf) end,
        OnSerialize   = function(g) return SerializePlayer(g) end,
        OnDeserialize = function(g, b) DeserializePlayer(g, b) end,
        OnCleanup     = function(keepGuid) Cleanup(keepGuid) end,
        OnForget      = function(guid) if guid then AltStableProfessionsDB[guid] = nil end end,
        _at           = AT,
        _test = {
            SerializePlayer = SerializePlayer, DeserializePlayer = DeserializePlayer, ParseProfs = ParseProfs,
            Candidate = Candidate, Commit = Commit, RunScan = RunScan, ScheduleScan = ScheduleScan,
            OnShow = OnShow, OnClose = OnClose, OnChanging = OnChanging, OnRecipeLearned = OnRecipeLearned,
            RefreshOwnership = RefreshOwnership, ReadOwned = ReadOwned, ApplyCooldowns = ApplyCooldowns,
            CooldownLabel = CooldownLabel,
            Owners = Owners, AllOwners = AllOwners, Catalogue = Catalogue, BuildRows = BuildRows, Cards = Cards,
            MeetsSkill = MeetsSkill, DifficultyColor = DifficultyColor, HasNonTrainerSource = HasNonTrainerSource,
            RecipeName = RecipeName, OnSpellData = OnSpellData,
            PruneOrphans = PruneOrphans, Cleanup = Cleanup, BootstrapPlugin = BootstrapPlugin,
            PROFESSIONS = PROFESSIONS, scan = scan, names = names, requested = requested,
            ResetState = function() pendingLoss = nil; lineIndex = nil end,
        },
    })

    PruneOrphans()
    -- A full pull from every peer when there is nothing to build on. Switching
    -- the plugin on from Options is covered by the core (SetPluginEnabled resets
    -- the watermarks for any plugin it loads). NOT on "loaded on demand" - that
    -- is every login (see Warband's bootstrap).
    if AltStable.ResetPeerWatermarks and not next(AltStableProfessionsDB) then
        AltStable.ResetPeerWatermarks()
    end
    C_Timer.After(4, RefreshOwnership)
end

local frame = CreateFrame("Frame")
local ownershipTimer
frame:SetScript("OnEvent", function(_, event, arg1, arg2)
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
    elseif event == "SPELL_DATA_LOAD_RESULT" then
        OnSpellData(arg1, arg2)
    end
end)
for _, ev in ipairs({ "PLAYER_LOGIN", "TRADE_SKILL_SHOW", "TRADE_SKILL_LIST_UPDATE",
                      "TRADE_SKILL_DATA_SOURCE_CHANGED", "TRADE_SKILL_DATA_SOURCE_CHANGING",
                      "TRADE_SKILL_CLOSE", "NEW_RECIPE_LEARNED", "SKILL_LINES_CHANGED",
                      "SPELL_DATA_LOAD_RESULT" }) do
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
