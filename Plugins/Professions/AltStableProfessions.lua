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
--   no entry for a guid      -> never scanned: nothing is claimed about it
--   profs[line] with full=nil -> partial: only NEW_RECIPE_LEARNED seen; the
--                                recipes it lists are known, the rest unknown
--   profs = {}               -> scanned, has no professions
-- Only the client that plays a character writes its entry; everyone else
-- adopts it as sent. That, plus the strictly increasing stamp, is what keeps
-- two peers from bouncing different snapshots of one character between them.
--
-- Craft cooldowns go on the CORE record as cd_<Profession>@<recipe name>, the
-- field the grid's profession tooltip already reads (RowRenderer.lua), so the
-- core syncs and clears them like any other field.
------------------------------------------------------------

AltStableProfessionsDB = AltStableProfessionsDB or {}

local ADDON_ID     = "professions"
local BLOB_VERSION = "v1"
local TRAINER      = 6

-- The twelve lines Forever gives recipes to (Camping reached even Fishing and
-- First Aid). `label` is the grid column's label, which is also the cd_ prefix.
local PROFESSIONS = {
    { line = 171, label = "Alchemy",        icon = "Interface\\Icons\\Trade_Alchemy" },
    { line = 164, label = "Blacksmithing",  icon = "Interface\\Icons\\Trade_BlackSmithing" },
    { line = 333, label = "Enchanting",     icon = "Interface\\Icons\\Trade_Engraving" },
    { line = 202, label = "Engineering",    icon = "Interface\\Icons\\Trade_Engineering" },
    { line = 165, label = "Leatherworking", icon = "Interface\\Icons\\Trade_LeatherWorking" },
    { line = 197, label = "Tailoring",      icon = "Interface\\Icons\\Trade_Tailoring" },
    { line = 186, label = "Mining",         icon = "Interface\\Icons\\Trade_Mining" },
    { line = 182, label = "Herbalism",      icon = "Interface\\Icons\\Trade_Herbalism" },
    { line = 393, label = "Skinning",       icon = "Interface\\Icons\\INV_Misc_Pelt_Wolf_01" },
    { line = 185, label = "Cooking",        icon = "Interface\\Icons\\INV_Misc_Food_15" },
    { line = 129, label = "First Aid",      icon = "Interface\\Icons\\Spell_Holy_SealOfSacrifice" },
    { line = 356, label = "Fishing",        icon = "Interface\\Icons\\Trade_Fishing" },
}
local BY_LINE = {}
for _, p in ipairs(PROFESSIONS) do BY_LINE[p.line] = p end

-- The core's skill fields, for alts this plugin has never scanned: they still
-- show up as "has it, not scanned" rather than not at all.
local CORE_SKILL_FIELD = {
    [185] = "cooking", [129] = "firstAid", [356] = "fishing",
}
local function CoreSkill(char, line)
    local p = BY_LINE[line]
    if not p or type(char) ~= "table" then return nil end
    local v = char[CORE_SKILL_FIELD[line] or ("prof_" .. p.label)]
    v = tonumber(v)
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

-- The skill line a recipe belongs to when it is in several (one Leatherworking
-- spell is also Tailoring's): the one asked about if it is among them.
local function RecipeInLine(r, line)
    for _, s in ipairs(r.skill or {}) do if s == line then return true end end
    return false
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
    if AT.isActive and AT.Refresh then AT.Refresh() end
end

local function setsEqual(a, b)
    for k in pairs(a or {}) do if not (b and b[k]) then return false end end
    for k in pairs(b or {}) do if not (a and a[k]) then return false end end
    return true
end

------------------------------------------------------------
-- Cooldowns: cd_<Profession>@<recipe name> on the core record
------------------------------------------------------------

-- cds = { [recipe name] = seconds remaining (0 = ready) } for one profession's
-- learned recipes that have a cooldown at all. Returns true if anything changed.
--   * a running cooldown is written as an absolute expiry; a shift under 60 s is
--     timing jitter between two reads and is not a change;
--   * one that has come back up keeps a past expiry, so the grid says "Ready!";
--   * a recipe no longer known takes its field with it.
local function ApplyCooldowns(char, label, cds, knownNames)
    if type(char) ~= "table" then return false end
    local prefix, now, changed = "cd_" .. label .. "@", time(), false
    for name, left in pairs(cds) do
        local key = prefix .. name
        local held = tonumber(char[key])
        if left > 0 then
            local expiry = now + left
            if not held or held <= now or math.abs(held - expiry) > 60 then
                char[key] = expiry; changed = true
            end
        elseif held and held > now then
            char[key] = now; changed = true           -- ready again: a transition, never jitter
        end
    end
    for key in pairs(char) do
        if type(key) == "string" and key:sub(1, #prefix) == prefix then
            if not knownNames[key:sub(#prefix + 1)] then char[key] = nil; changed = true end
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
local function ReadOwned()
    if type(GetProfessions) ~= "function" or type(GetProfessionInfo) ~= "function" then return nil end
    local ok, a, b, c, d, e = pcall(GetProfessions)
    if not ok then return nil end
    local owned = {}
    for _, idx in pairs({ a, b, c, d, e }) do
        local ok2, _, _, rank, maxRank, _, _, line = pcall(GetProfessionInfo, idx)
        if not ok2 then return nil end
        line = tonumber(line)
        if line and BY_LINE[line] then owned[line] = { rank = tonumber(rank) or 0, max = tonumber(maxRank) or 0 } end
    end
    return owned
end

local emptyOnce = false

-- Reconcile the store with what the character has now. An EMPTY answer is only
-- believed the second time running: at login GetProfessions can answer before
-- the skill lines have loaded, and believing that once would prune everything.
local function RefreshOwnership()
    local guid = UnitGUID and UnitGUID("player")
    if not guid then return end
    local owned = ReadOwned()
    if not owned then return end
    local e = Entry(guid)
    if not next(owned) and next(e.profs) and not emptyOnce then
        emptyOnce = true
        C_Timer.After(5, RefreshOwnership)
        return
    end
    emptyOnce = false

    local changed, char = false, AltStableDB and AltStableDB[guid]
    for line, p in pairs(e.profs) do
        if not owned[line] then
            e.profs[line] = nil
            ClearCooldowns(char, BY_LINE[line].label)
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
    local okr, ids = Try(t.GetAllRecipeIDs)
    if not okr or type(ids) ~= "table" or #ids == 0 then return nil, "no recipes" end

    local known, cds, names = {}, {}, {}
    for _, id in ipairs(ids) do
        local oki, info = Try(t.GetRecipeInfo, id)
        -- Never measured to happen (727 IDs, no nil), but a half-read list
        -- would read as "unlearned" for everything missing: abandon instead.
        if not oki or type(info) ~= "table" then return nil, "incomplete" end
        if info.learned then
            known[id] = true
            local okc, left = Try(t.GetRecipeCooldown, id)
            left = okc and tonumber(left) or nil
            local name = info.name
            if left and name then cds[name] = math.max(0, left) end
            if name then names[name] = true end
        end
    end
    return { line = line, rank = tonumber(base.skillLevel) or 0, max = tonumber(base.maxSkillLevel) or 0,
             known = known, cds = cds, names = names }
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
    local cdChanged = ApplyCooldowns(AltStableDB and AltStableDB[guid], BY_LINE[c.line].label, c.cds, c.names)
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
        profs[line] = { rank = tonumber(rank), max = tonumber(max), full = tonumber(full), known = known }
    end
    return profs
end

local function DeserializePlayer(guid, blob)
    if not guid or type(blob) ~= "string" or blob == "" then return end
    local ver, rest = blob:match("^(v%d+)|(.*)$")
    if ver ~= BLOB_VERSION then return end              -- a newer format: ignore, never wipe
    -- Our own characters are ours: this client's scan is the authority for them.
    local char = AltStableDB and AltStableDB[guid]
    if type(char) == "table" and char.scannedHere then return end
    local stamp = tonumber(rest:match("^s=(%d+)"))
    local profStr = rest:match("|p=([^|]*)$")
    if not stamp or not profStr then return end
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

local function Visible(guid)
    return not (AltStable.IsCharacterHidden and AltStable.IsCharacterHidden(guid))
end

-- Everyone who has this profession, as far as anything says so:
--   state "full"    - a complete scan to go on
--   state "partial" - only learned-recipe events
--   state "unscanned" - the core's skill field says they have it; the plugin
--                       has never seen their window
local function Owners(line)
    local out = {}
    for guid, c in pairs(AltStableDB or {}) do
        if type(c) == "table" and c.name and Visible(guid) then
            local e = AltStableProfessionsDB[guid]
            local p = type(e) == "table" and e.profs and e.profs[line]
            if p then
                -- Owned but its window never opened (and nothing learned since)
                -- is "unscanned": nothing is claimed either way.
                local state = p.full and "full" or (next(p.known or {}) and "partial" or "unscanned")
                out[#out + 1] = { guid = guid, name = c.name, class = c.class, realm = c.realm,
                                  rank = p.rank or 0, max = p.max or 0, known = p.known or {},
                                  full = p.full, state = state }
            elseif not (type(e) == "table" and e.stamp) and CoreSkill(c, line) then
                out[#out + 1] = { guid = guid, name = c.name, class = c.class, realm = c.realm,
                                  rank = CoreSkill(c, line), max = 0, known = {}, state = "unscanned" }
            end
        end
    end
    table.sort(out, function(a, b)
        if a.rank ~= b.rank then return a.rank > b.rank end
        return (a.name or "") < (b.name or "")
    end)
    return out
end

-- The recipes of a line: the generated catalogue, less those whose requirement
-- Wowhead does not know (quite possibly not learnable yet), plus anything an
-- alt actually knows that the catalogue lacks (a newer patch).
local function Catalogue(line, owners)
    local set = {}
    for id, r in pairs(Data()) do
        if r.learn and RecipeInLine(r, line) then set[id] = true end
    end
    for _, o in ipairs(owners) do for id in pairs(o.known) do set[id] = true end end
    return set
end

local names = {}
local function RecipeName(id)
    if names[id] then return names[id] end
    local n
    if C_Spell and C_Spell.GetSpellName then
        local ok, v = pcall(C_Spell.GetSpellName, id); if ok then n = v end
    end
    if n and n ~= "" then names[id] = n; return n end
    if C_Spell and C_Spell.RequestLoadSpellData then pcall(C_Spell.RequestLoadSpellData, id) end
    return nil
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

-- Builds the list the panel shows. Pure: state in, rows out, so tests drive it.
--   state = { line, search, filter ("all"|"known"|"missing"|"nobody"), onlyDrops, focus (guid) }
local function BuildRows(state)
    local lines = {}
    local search = (state.search or ""):lower()
    if search ~= "" then
        for _, p in ipairs(PROFESSIONS) do lines[#lines + 1] = p.line end   -- search spans them all
    else
        lines[1] = state.line
    end
    local rows = {}
    for _, line in ipairs(lines) do
        local owners = Owners(line)
        local focus
        for _, o in ipairs(owners) do if o.guid == state.focus then focus = o end end
        local allComplete = #owners > 0
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
                    keep = focus and focus.known[id] or (not focus and #knownBy > 0)
                elseif f == "missing" then
                    if focus then keep = not focus.known[id]
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
local function Cards(line)
    local owners = Owners(line)
    local total = 0
    for _ in pairs(Catalogue(line, owners)) do total = total + 1 end
    local cards = {}
    for _, o in ipairs(owners) do
        local n = 0
        for _ in pairs(o.known) do n = n + 1 end
        local cd
        local char = AltStableDB and AltStableDB[o.guid]
        local prefix = "cd_" .. BY_LINE[line].label .. "@"
        for k, v in pairs(char or {}) do
            if type(k) == "string" and k:sub(1, #prefix) == prefix then
                local left = (tonumber(v) or 0) - time()
                local label = k:sub(#prefix + 1)
                if not cd or left < cd.left then cd = { label = label, left = left } end
            end
        end
        cards[#cards + 1] = { owner = o, known = n, total = total, cooldown = cd }
    end
    return cards
end

------------------------------------------------------------
-- The panel
------------------------------------------------------------

local panel, emptyFS, statusFS, searchBox
local PAD, ROW_H, ICON = 10, 20, 16
local PICK = 26
local CARD_W, CARD_H = 150, 46
local TOP_PICK = 8
local TOP_FILTER = TOP_PICK + PICK + 8
local TOP_CARDS = TOP_FILTER + 26
local TOP_ROWS = TOP_CARDS + CARD_H + 10

local function C(key, fallback) return (AltStable.C and AltStable.C[key]) or fallback end

local function ClassColor(class)
    local cc = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if cc then return cc.r, cc.g, cc.b end
    return 0.9, 0.9, 0.9
end

local function ColorName(o)
    local r, g, b = ClassColor(o.class)
    return string.format("|cff%02x%02x%02x%s|r", r * 255, g * 255, b * 255, o.name or "?")
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
            local cr, cg, cb = ClassColor(o.class)
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
            local cr, cg, cb = ClassColor(o.class)
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

local function LayoutCards()
    local cards = AT.cardData or {}
    local width = panel:GetWidth()
    if not width or width < 200 then width = 600 end
    local fit = math.max(1, math.floor((width - 2 * PAD) / (CARD_W + 6)))
    AT.cardStart = math.max(0, math.min(AT.cardStart or 0, math.max(0, #cards - fit)))
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

local function LayoutPicker()
    for i, p in ipairs(PROFESSIONS) do
        local b = AT.pick[i]
        local n = #Owners(p.line)
        b.count:SetText(n > 0 and tostring(n) or "")
        b.icon:SetDesaturated(n == 0)
        b:SetAlpha(n == 0 and 0.45 or 1)
        b.sel:SetShown(AT.line == p.line and (AT.search or "") == "")
    end
end

function AT.Refresh()
    if not panel or not panel:IsShown() then return end
    if not AT.line then
        -- Start on the profession most alts have.
        local best, bestN = PROFESSIONS[1].line, -1
        for _, p in ipairs(PROFESSIONS) do
            local n = #Owners(p.line)
            if n > bestN then best, bestN = p.line, n end
        end
        AT.line = best
    end
    -- A focus on someone without this profession is dropped, not carried over.
    AT.cardData = Cards(AT.line)
    local stillThere = false
    for _, c in ipairs(AT.cardData) do if c.owner.guid == AT.focus then stillThere = true end end
    if not stillThere then AT.focus = nil end
    AT.rows = BuildRows({ line = AT.line, search = AT.search, filter = AT.filter,
                          onlyDrops = AT.onlyDrops, focus = AT.focus })
    LayoutPicker()
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
            local n = #Owners(p.line)
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

    -- Cards scroll sideways with the wheel when there are more than fit.
    local strip = CreateFrame("Frame", nil, panel)
    strip:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -TOP_CARDS)
    strip:SetPoint("RIGHT", panel, "RIGHT", 0, 0)
    strip:SetHeight(CARD_H)
    strip:EnableMouseWheel(true)
    strip:SetScript("OnMouseWheel", function(_, delta)
        AT.cardStart = math.max(0, (AT.cardStart or 0) - delta)
        LayoutCards()
    end)
    strip:SetFrameLevel(math.max(0, panel:GetFrameLevel() - 1))

    panel:EnableMouseWheel(true)
    panel:SetScript("OnMouseWheel", function(_, delta)
        AT.scrollRow = math.max(0, (AT.scrollRow or 0) - delta * 3)
        AT.Layout()
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
            Owners = Owners, Catalogue = Catalogue, BuildRows = BuildRows, Cards = Cards,
            MeetsSkill = MeetsSkill, DifficultyColor = DifficultyColor, HasNonTrainerSource = HasNonTrainerSource,
            PruneOrphans = PruneOrphans, Cleanup = Cleanup, BootstrapPlugin = BootstrapPlugin,
            scan = scan, names = names,
            ResetEmptyGuard = function() emptyOnce = false end,
        },
    })

    PruneOrphans()
    -- A full pull from every peer when there is nothing to build on: when we
    -- hold no snapshots at all, or when the plugin was switched on from Options
    -- just now (a peer's watermark for us may be ahead of snapshots we never
    -- received, which a delta pull would never backfill). NOT on "loaded on
    -- demand" - that is every login (see Warband's bootstrap).
    if AltStable.ResetPeerWatermarks then
        local justEnabled = AltStable.pluginsEnabledThisSession and AltStable.pluginsEnabledThisSession[ADDON_ID]
        if justEnabled or not next(AltStableProfessionsDB) then AltStable.ResetPeerWatermarks() end
    end
    C_Timer.After(4, RefreshOwnership)
end

local frame = CreateFrame("Frame")
local ownershipTimer
frame:SetScript("OnEvent", function(_, event, arg1)
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
        if AT.isActive then AT.RequestRefresh() end
    end
end)
for _, ev in ipairs({ "PLAYER_LOGIN", "TRADE_SKILL_SHOW", "TRADE_SKILL_LIST_UPDATE",
                      "TRADE_SKILL_DATA_SOURCE_CHANGED", "TRADE_SKILL_DATA_SOURCE_CHANGING",
                      "TRADE_SKILL_CLOSE", "NEW_RECIPE_LEARNED", "SKILL_LINES_CHANGED",
                      "UNIT_SPELLCAST_SUCCEEDED", "SPELL_DATA_LOAD_RESULT" }) do
    frame:RegisterEvent(ev)
end

-- Loaded on demand from the core's PLAYER_LOGIN handler, so PLAYER_LOGIN will
-- not fire for us again.
if IsLoggedIn() then
    C_Timer.After(1, BootstrapPlugin)
end
