------------------------------------------------------------
-- Professions.lua - step 0 of the Professions plugin (#14)
--
-- The plugin's scan design hangs on facts only the live client can give, and
-- the questions do not fit in chat: a /run line is capped at 255 characters,
-- and the answers depend on WHEN they are asked - window closed, window open,
-- after switching to another profession. So this probe watches instead of
-- being asked.
--
--   /asprof         snapshot now (also runs by itself, see below)
--   /asprof cd      every learned recipe that reports a cooldown, full tuple
--   /asprof log     toggle the event log in chat (the snapshots always save)
--   /asprof clear   empty the saved log
--
-- While loaded it listens to the trade-skill events and takes a snapshot one
-- second after each, tagged with the event that triggered it. One chat line per
-- snapshot; the full detail - every learned recipe ID, one recipe's whole info
-- struct, the cooldown tuples - goes to AltStableProbeDB.prof, which is written
-- on logout/reload and read off disk.
--
-- What the plan needs to know (bubbly-singing-pine.md, step 0):
--   * does GetAllRecipeIDs answer with the window CLOSED, and for which
--     profession - the last one viewed?
--   * does it include unlearned recipes; is it independent of the UI filters
--     (compared with GetFilteredRecipeIDs)?
--   * can GetRecipeInfo return nil for an ID in the list?
--   * are recipe IDs Wowhead's spell IDs (2329 = Elixir of Minor Strength)?
--   * the event order around open / switch / close / learning a recipe
--   * GetRecipeCooldown's tuple, and whether transmutes share one
--
-- Every call is pcall'd: several of these are namespace-present but
-- undocumented on this client, which proves existence and nothing else.
------------------------------------------------------------

AltStableProbeDB = AltStableProbeDB or {}

local MAX_ENTRIES = 80
local chatLog = true

local function Out(s)
    DEFAULT_CHAT_FRAME:AddMessage("|cff66ccff[prof]|r " .. tostring(s))
end

local function Try(fn, ...)
    if type(fn) ~= "function" then return false, "absent" end
    return pcall(fn, ...)
end

-- A struct as a flat copy of its plain fields, so it survives into the SV file.
local function Plain(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do
        local tv = type(v)
        if tv == "string" or tv == "number" or tv == "boolean" then
            out[k] = v
        elseif tv == "table" then
            out[k] = "{table #" .. #v .. "}"
        end
    end
    return out
end

local function SpellName(id)
    if C_Spell and C_Spell.GetSpellName then
        local ok, n = pcall(C_Spell.GetSpellName, id)
        if ok then return n end
    end
    return nil
end

local TS = C_TradeSkillUI or {}

local function Snapshot(trigger)
    local e = { at = date("%H:%M:%S"), t = GetTime(), trigger = trigger }

    -- The character's own professions (spellbook indices).
    local ok, a, b, c, d, f = Try(GetProfessions)
    e.GetProfessions = ok and { a, b, c, d, f } or ("error: " .. tostring(a))
    if ok then
        e.professions = {}
        for _, idx in pairs({ a, b, c, d, f }) do
            local ok2, name, _, rank, maxRank, _, _, skillLine = Try(GetProfessionInfo, idx)
            e.professions[#e.professions + 1] = ok2 and { idx = idx, name = name, rank = rank, max = maxRank, skillLine = skillLine }
                or { idx = idx, err = tostring(name) }
        end
    end

    local okb, base = Try(TS.GetBaseProfessionInfo)
    e.base = okb and Plain(base) or ("error: " .. tostring(base))
    local okc, child = Try(TS.GetChildProfessionInfo)
    e.child = okc and Plain(child) or ("error: " .. tostring(child))

    e.flags = {}
    for _, fn in ipairs({ "IsTradeSkillReady", "IsDataSourceChanging", "IsTradeSkillLinked",
                          "IsTradeSkillGuild", "IsNPCCrafting" }) do
        local okf, v = Try(TS[fn])
        e.flags[fn] = okf and tostring(v) or ("error: " .. tostring(v))
    end

    -- Every line the client lists, with its skill - known lines vs all lines.
    local okl, lines = Try(TS.GetAllProfessionTradeSkillLines)
    if okl and type(lines) == "table" then
        e.lines = {}
        for _, id in ipairs(lines) do
            local oki, info = Try(TS.GetProfessionInfoBySkillLineID, id)
            local p = oki and info or {}
            e.lines[#e.lines + 1] = string.format("%s %s %s/%s", tostring(id), tostring(p.professionName),
                tostring(p.skillLevel), tostring(p.maxSkillLevel))
        end
    else
        e.lines = "error: " .. tostring(lines)
    end

    -- The recipe list, and how complete it is.
    local okr, ids = Try(TS.GetAllRecipeIDs)
    local okfl, filtered = Try(TS.GetFilteredRecipeIDs)
    e.allCount = okr and type(ids) == "table" and #ids or ("error: " .. tostring(ids))
    e.filteredCount = okfl and type(filtered) == "table" and #filtered or ("error: " .. tostring(filtered))
    local learned, unlearned, nilInfo = {}, 0, 0
    if okr and type(ids) == "table" then
        for _, id in ipairs(ids) do
            local oki, info = Try(TS.GetRecipeInfo, id)
            if not oki or not info then
                nilInfo = nilInfo + 1
            elseif info.learned then
                learned[#learned + 1] = id
                if not e.sampleInfo then e.sampleInfo = Plain(info) end
            else
                unlearned = unlearned + 1
                if not e.sampleUnlearned then
                    e.sampleUnlearned = Plain(info)
                    local oks, src = Try(TS.GetRecipeSourceText, id)
                    e.sampleSourceText = oks and src or ("error: " .. tostring(src))
                end
            end
        end
        table.sort(learned)
    end
    e.learned, e.unlearned, e.nilInfo = learned, unlearned, nilInfo
    e.learnedNames = {}
    for i = 1, math.min(#learned, 8) do
        e.learnedNames[i] = learned[i] .. " " .. tostring(SpellName(learned[i]))
    end

    -- The ID join with Wowhead, whatever this character knows.
    local okp, byRecipe = Try(TS.GetProfessionInfoByRecipeID, 2329)
    e.recipe2329 = okp and Plain(byRecipe) or ("error: " .. tostring(byRecipe))
    e.spell2329 = SpellName(2329)

    AltStableProbeDB.prof = AltStableProbeDB.prof or {}
    local log = AltStableProbeDB.prof
    log[#log + 1] = e
    while #log > MAX_ENTRIES do table.remove(log, 1) end

    local baseName = type(e.base) == "table" and (tostring(e.base.professionName) .. "(" .. tostring(e.base.professionID) .. ")") or "?"
    Out(string.format("%s %s base=%s ready=%s all=%s filtered=%s learned=%d unlearned=%d nil=%d",
        e.at, trigger, baseName, tostring(e.flags.IsTradeSkillReady), tostring(e.allCount),
        tostring(e.filteredCount), #learned, unlearned, nilInfo))
    return e
end

local function Cooldowns()
    local okr, ids = Try(TS.GetAllRecipeIDs)
    if not okr or type(ids) ~= "table" then Out("GetAllRecipeIDs: " .. tostring(ids)) return end
    local rows = {}
    for _, id in ipairs(ids) do
        local oki, info = Try(TS.GetRecipeInfo, id)
        if oki and info and info.learned then
            local r = { pcall(TS.GetRecipeCooldown, id) }
            if r[1] and (r[2] ~= nil or r[3] ~= nil or r[4] ~= nil or r[5] ~= nil) then
                local line = string.format("%d %s cd=%s day=%s charges=%s/%s", id, tostring(SpellName(id)),
                    tostring(r[2]), tostring(r[3]), tostring(r[4]), tostring(r[5]))
                rows[#rows + 1] = line
                Out(line)
            end
        end
    end
    if #rows == 0 then Out("no learned recipe reports a cooldown (window open on the right profession?)") end
    AltStableProbeDB.profCooldowns = { at = date("%H:%M:%S"), rows = rows }
end

-- Events: logged in order, each followed by a snapshot a second later. A
-- rejected event is reported rather than fatal - TRADE_SKILL_UPDATE is rejected
-- on this client, and another may be on the next.
local EVENTS = { "TRADE_SKILL_SHOW", "TRADE_SKILL_LIST_UPDATE", "TRADE_SKILL_DATA_SOURCE_CHANGED",
                 "TRADE_SKILL_DATA_SOURCE_CHANGING", "TRADE_SKILL_CLOSE", "TRADE_SKILL_DETAILS_UPDATE",
                 "NEW_RECIPE_LEARNED", "SKILL_LINES_CHANGED" }

local frame = CreateFrame("Frame")
for _, ev in ipairs(EVENTS) do
    local ok, err = pcall(frame.RegisterEvent, frame, ev)
    if not ok then Out("RegisterEvent " .. ev .. " rejected: " .. tostring(err)) end
end

local pending = {}
frame:SetScript("OnEvent", function(_, ev, ...)
    local args = {}
    for i = 1, select("#", ...) do args[i] = tostring((select(i, ...))) end
    local line = date("%H:%M:%S") .. string.format(" %.2f ", GetTime()) .. ev .. " " .. table.concat(args, " ")
    AltStableProbeDB.profEvents = AltStableProbeDB.profEvents or {}
    local evlog = AltStableProbeDB.profEvents
    evlog[#evlog + 1] = line
    while #evlog > 300 do table.remove(evlog, 1) end
    if chatLog then Out("|cff888888" .. line .. "|r") end
    -- One snapshot per event name per second: LIST_UPDATE can fire in bursts.
    if not pending[ev] then
        pending[ev] = true
        C_Timer.After(1, function() pending[ev] = nil Snapshot(ev .. "+1s") end)
    end
end)

SLASH_ASPROF1 = "/asprof"
SlashCmdList["ASPROF"] = function(msg)
    msg = (msg or ""):lower():match("^%s*(.-)%s*$")
    if msg == "cd" then
        Cooldowns()
    elseif msg == "log" then
        chatLog = not chatLog
        Out("event log in chat: " .. (chatLog and "on" or "off"))
    elseif msg == "clear" then
        AltStableProbeDB.prof, AltStableProbeDB.profEvents, AltStableProbeDB.profCooldowns = nil, nil, nil
        Out("cleared")
    else
        Snapshot("manual")
    end
end
