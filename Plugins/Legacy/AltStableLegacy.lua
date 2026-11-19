------------------------------------------------------------
-- AltStableLegacy - Forever's Legacy Challenges across every alt (#373)
--
-- What the client gives, measured on 1.60.1.70959 (forever-api-notes.md,
-- "Legacy Challenges: one state per Battle.net account"), and the design
-- follows it:
--
--   * A challenge is an achievement worth Legacy points
--     (C_Traits.GetTraitCurrencyForAchievement(4225, id) > 0), found by walking
--     the achievement categories as Blizzard's own Legacy window does. 65 of
--     them, readable from PLAYER_LOGIN on.
--   * Completion AND criteria are one state per Battle.net account: every
--     character of both WoW accounts read the same. So this plugin reads it
--     live and syncs nothing; the other WoW account reads the same thing.
--     wasEarnedByMe is true everywhere and earnedBy empty: nobody is named as
--     the one who earned a challenge.
--   * A craft challenge's criterion holds the account's best skill in that
--     craft, alts we never saw included. A class challenge has no criteria, so
--     its progress comes from the levels AltStable holds for our own alts.
--   * Explorer is the per-character exception: Explore Azeroth's progress is
--     read on the character playing and kept per GUID, here only.
--   * The points are the renown level of the Legacy Track (faction 2802), out
--     of GetMaxAvailableTraitCurrency(4225, false); its rewards are that
--     track's levels.
--
-- What is never shown as a number it does not know: a challenge list that
-- did not read is "Not read yet", a criterion list that did not read keeps
-- the last good one, and a threshold an alt reached on a challenge that is
-- still open is "~" (credit unknown), never "Gain 0 levels".
--
-- AltStableLegacyDB (this WoW account only, never synced):
--   explore[guid] = { parts = { { name, done, n } }, done, at }
--   open[sectionKey] = true   -- a section the owner expanded
--
-- LoadOnDemand: registers on PLAYER_LOGIN, or right away when enabled later.
------------------------------------------------------------

local D = AltStable.LegacyData

AltStableLegacyDB = AltStableLegacyDB or {}

local ADDON_ID = "legacy"
local L = { expanded = {} }

local PAD        = 10
local HEADER_H   = 38     -- the title and the view tab
local ROW_H      = 22
local TITLE_ROW  = 24     -- a grid's title line
local SECTION_H  = 24
local CRIT_H     = 18
local CELL_W     = 58
local GAP        = 12
local GRID_MIN_W = 400    -- two grids side by side from 2 x this
local PREFERRED_PANEL_W = 900
local MIN_PANEL_W, MIN_PANEL_H = 460, 360

local CHECK = "|TInterface\\RAIDFRAME\\ReadyCheck-Ready:14:14|t"
local DASH  = "|cff666666\226\128\148|r"   -- an em dash
local GOLD  = { 1, 0.82, 0 }

local panel, scroll, content, titleFS, poolFS, emptyFS

------------------------------------------------------------
-- Small helpers
------------------------------------------------------------

local function DB()
    if type(AltStableLegacyDB) ~= "table" then AltStableLegacyDB = {} end
    local db = AltStableLegacyDB
    if type(db.explore) ~= "table" then db.explore = {} end
    if type(db.open) ~= "table" then db.open = {} end
    return db
end

-- The Legacy calls are read through rawget: a build without one of them
-- leaves this plugin with nothing to show, never with an error.
local function G(name) return rawget(_G, name) end
local function Api(ns, name)
    local t = rawget(_G, ns)
    return type(t) == "table" and t[name] or nil
end
local function Try(fn, ...)
    if type(fn) ~= "function" then return false end
    return pcall(fn, ...)
end

local function Color(key, fallback)
    local c = AltStable.C and AltStable.C[key]
    return c or fallback
end

local function ClassHex(class)
    if AltStable.ClassColor and class then return AltStable.ClassColor(class) end
    return "|cffffffff"
end

local function HideTip() GameTooltip:Hide() end

-- 42000 as 42,000.
function L.Number(n)
    local s = tostring(math.floor(tonumber(n) or 0))
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (out:gsub("^,", ""))
end

------------------------------------------------------------
-- Reading the client
------------------------------------------------------------

-- Every criterion of an achievement, or nil when the list did not read.
function L.ReadCriteria(id)
    local ok, n = Try(G("GetAchievementNumCriteria"), id)
    if not ok or type(n) ~= "number" then return nil end
    local list = {}
    for i = 1, n do
        local okC, text, ctype, done, q, req, _, _, asset, _, cid = Try(G("GetAchievementCriteriaInfo"), id, i)
        if not okC then return nil end
        list[i] = { text = text, type = ctype, done = done and true or false,
                    q = tonumber(q), req = tonumber(req), asset = asset, id = cid }
    end
    return list
end

-- The renown track's rewards, one per level that has one.
function L.ReadRewards()
    local out = {}
    local ok, levels = Try(Api("C_MajorFactions", "GetRenownLevels"), D.FACTION)
    if not ok or type(levels) ~= "table" then return out end
    for _, lv in ipairs(levels) do
        local level = type(lv) == "table" and tonumber(lv.level) or nil
        local okR, rewards = Try(Api("C_MajorFactions", "GetRenownRewardsForLevel"), D.FACTION, level)
        if level and okR and type(rewards) == "table" then
            for _, r in ipairs(rewards) do
                if type(r) == "table" and r.itemID then
                    out[#out + 1] = { level = level, itemID = r.itemID, name = r.name }
                    break
                end
            end
        end
    end
    table.sort(out, function(a, b) return a.level < b.level end)
    return out
end

-- The whole state, read live. `prev` is the last good read: what this read
-- could not see, it keeps.
--   * a challenge seen completed stays completed (a later read never
--     un-earns it);
--   * a criterion list that did not read, or came back empty where the last
--     read had parts, keeps the last one: the full challenge list does not
--     prove the criteria are ready;
--   * a list that is empty, or under half the last one, is not a read at all.
function L.Read(prev)
    local ok, cats = Try(G("GetCategoryList"))
    if not ok or type(cats) ~= "table" then return prev, "no categories" end
    local s = { challenges = {}, order = {}, inA = 0, inB = 0 }
    local before = prev and prev.challenges or {}
    for _, cat in ipairs(cats) do
        local okN, total = Try(G("GetCategoryNumAchievements"), cat, true)
        for i = 1, (okN and tonumber(total) or 0) do
            local okA, id, name, _, completed, month, day, year, desc, _, icon = Try(G("GetAchievementInfo"), cat, i)
            local okP, pts = Try(Api("C_Traits", "GetTraitCurrencyForAchievement"), D.CURRENCY, id)
            if okA and id and okP and (tonumber(pts) or 0) > 0 then
                local old = before[id]
                local c = { id = id, name = name, cat = cat, desc = desc, icon = icon,
                            completed = (completed or (old and old.completed)) and true or false }
                if completed and month and day and year then
                    c.date = ("%d-%02d-%02d"):format(year < 100 and 2000 + year or year, month, day)
                elseif old then
                    c.date = old.date
                end
                local crit = L.ReadCriteria(id)
                if old and old.criteria and (not crit or (#crit == 0 and #old.criteria > 0)) then
                    crit = old.criteria
                end
                c.criteria = crit
                s.challenges[id] = c
                s.order[#s.order + 1] = id
                local g = D.GRID[id]
                if g then
                    if g[4] == "B" then s.inB = s.inB + 1 else s.inA = s.inA + 1 end
                end
            end
        end
    end
    if #s.order == 0 or (prev and #s.order < #prev.order / 2) then return prev, "partial list" end
    s.pool = (s.inB > s.inA) and "B" or "A"
    local okR, level = Try(Api("C_MajorFactions", "GetCurrentRenownLevel"), D.FACTION)
    s.points = (okR and tonumber(level)) or (prev and prev.points) or nil
    local okM, max = Try(Api("C_Traits", "GetMaxAvailableTraitCurrency"), D.CURRENCY, false)
    s.max = (okM and tonumber(max)) or (prev and prev.max) or nil
    s.rewards = L.ReadRewards()
    if #s.rewards == 0 and prev then s.rewards = prev.rewards end
    s.at = time()
    return s
end

-- Explore Azeroth on the character playing: its continents' parts, kept per
-- GUID. A part list that does not read leaves the stored one alone.
function L.ReadExplore()
    local guid = UnitGUID("player")
    if not guid then return end
    local crit = L.ReadCriteria(D.EXPLORE_AZEROTH)
    if not crit or #crit == 0 then return end
    local parts = {}
    for _, c in ipairs(crit) do
        if c.asset and c.asset ~= 0 then
            local sub = L.ReadCriteria(c.asset)
            if not sub or #sub == 0 then return end
            local done = 0
            for _, x in ipairs(sub) do if x.done then done = done + 1 end end
            parts[#parts + 1] = { name = c.text, done = done, n = #sub }
        end
    end
    if #parts == 0 then return end
    local okA, _, _, _, completed = Try(G("GetAchievementInfo"), D.EXPLORE_AZEROTH)
    DB().explore[guid] = { parts = parts, done = (okA and completed) and true or nil, at = time() }
end

------------------------------------------------------------
-- The model: pure, from a read and the alts we hold
------------------------------------------------------------

-- Our own alts only: scanned here, or proven our own account's. A friend's
-- characters in the roster cannot earn our challenges. Hidden ones are left
-- out, as the sheet leaves them out.
function L.OwnAlts()
    local out = {}
    for guid, c in pairs(AltStableDB or {}) do
        if type(c) == "table" and c.name and (c.scannedHere or c.provKind == "own-account")
           and not (AltStable.IsCharacterHidden and AltStable.IsCharacterHidden(guid)) then
            out[#out + 1] = { guid = guid, name = c.name, class = c.class,
                              level = tonumber(c.level) or 0, rec = c }
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

local function Sectioned(cat)
    for _, sec in ipairs(D.SECTIONS) do if sec.cats[cat] then return true end end
    return false
end

-- One grid row's three cells, given the progress `have` toward each
-- threshold (nil: nobody to advance it).
local function Cells(byKey, kind, key, have)
    local cells, open, done, total = {}, false, 0, 0
    for i, t in ipairs(D.TIERS[kind]) do
        local c = byKey[kind .. ":" .. key .. ":" .. t]
        local cell = { ch = c, need = t, have = have }
        if not c then
            cell.state = "unknown"
        else
            total = total + 1
            if c.completed then
                cell.state = "done"; done = done + 1
            elseif not have or have <= 0 then
                cell.state = "none"
            elseif have >= t then
                cell.state = "credit"
            elseif not open then
                cell.state = "progress"; open = true
            else
                cell.state = "later"
            end
        end
        cells[i] = cell
    end
    return cells, done, total
end

-- A checklist challenge's row: progress, its parts (missing first), and the
-- one thing left when only one is.
function L.ChallengeRow(c, secKey)
    local r = { ch = c, id = c.id, done = c.completed, sec = secKey, parts = {} }
    local crit = c.criteria
    if crit and #crit == 1 and crit[1].type == 8 and crit[1].asset == D.EXPLORE_AZEROTH then
        -- Explorer: per character, the most complete one we have seen.
        r.perChar = true
        local bestDone, bestN, best
        for guid, e in pairs(DB().explore) do
            local rec = AltStableDB and AltStableDB[guid]
            local d, n = 0, 0
            for _, p in ipairs(e.parts or {}) do d = d + (p.done or 0); n = n + (p.n or 0) end
            if type(rec) == "table" and rec.name and n > 0 and (not best or d > bestDone) then
                best, bestDone, bestN = { rec = rec, e = e }, d, n
            end
        end
        if best then
            r.char, r.charClass = best.rec.name, best.rec.class
            r.have, r.total = bestDone, bestN
            for _, p in ipairs(best.e.parts) do
                r.parts[#r.parts + 1] = { text = p.name, done = p.done >= p.n, q = p.done, req = p.n }
            end
        end
    elseif not crit then
        r.unknown = true
        return r
    elseif #crit == 0 then
        r.nocrit = true
        return r
    else
        r.char = "Account"
        if #crit == 1 and (crit[1].req or 0) > 1 then
            -- One counted criterion (a reputation): the number is the row;
            -- a part list would only repeat it.
            r.numeric = true
            r.have, r.total = math.min(crit[1].q or 0, crit[1].req), crit[1].req
            return r
        elseif #crit == 1 then
            -- One plain criterion (a Field of Honor week) is the challenge
            -- itself: "0/1" and "Complete <its name>" would say nothing more.
            r.nocrit = true
            return r
        end
        local d = 0
        for _, x in ipairs(crit) do if x.done then d = d + 1 end end
        r.have, r.total = d, #crit
        for _, x in ipairs(crit) do
            r.parts[#r.parts + 1] = { text = x.text, done = x.done, q = x.q, req = x.req }
        end
    end
    -- Missing first, each half in the game's order.
    for i, p in ipairs(r.parts) do p.order = i end
    table.sort(r.parts, function(a, b)
        if a.done ~= b.done then return not a.done end
        return a.order < b.order
    end)
    local missing = {}
    for _, p in ipairs(r.parts) do if not p.done then missing[#missing + 1] = p end end
    if not r.done and #missing == 1 and not r.numeric and not r.perChar then
        local verb = (secKey == "dungeons" and "Finish ") or (secKey == "raids" and "Defeat ") or ""
        r.action = verb .. tostring(missing[1].text)
    end
    return r
end

function L.Model(s, alts)
    local m = { classes = {}, crafts = {}, sections = {}, read = s ~= nil, pool = s and s.pool }
    local byKey = {}
    if s then
        for id, c in pairs(s.challenges) do
            local g = D.GRID[id]
            if g then byKey[g[1] .. ":" .. g[2] .. ":" .. g[3]] = c end
        end
    end

    m.classDone, m.classTotal = 0, 0
    for _, class in ipairs(D.CLASSES) do
        local best
        for _, a in ipairs(alts) do
            if a.class == class and (not best or a.level > best.level) then best = a end
        end
        local cells, done, total = Cells(byKey, "class", class, best and best.level)
        m.classes[#m.classes + 1] = { key = class, label = D.CLASS_NAMES[class], best = best, cells = cells }
        m.classDone, m.classTotal = m.classDone + done, m.classTotal + total
    end

    m.craftDone, m.craftTotal = 0, 0
    for _, craft in ipairs(D.CRAFTS) do
        -- The game's figure first: the account's best, alts we never saw too.
        local skill
        for _, t in ipairs(D.TIERS.craft) do
            local c = byKey["craft:" .. craft .. ":" .. t]
            local crit = c and c.criteria and c.criteria[1]
            if crit and crit.q then skill = math.max(skill or 0, crit.q) end
        end
        local derived = 0
        for _, a in ipairs(alts) do
            local v = tonumber(a.rec["prof_" .. craft])
            if v and v > derived then derived = v end
        end
        if not skill and derived > 0 then skill = derived end
        local crafter
        if skill and skill > 0 then
            for _, a in ipairs(alts) do
                if tonumber(a.rec["prof_" .. craft]) == skill then crafter = a; break end
            end
        end
        local cells, done, total = Cells(byKey, "craft", craft, skill)
        m.crafts[#m.crafts + 1] = { key = craft, label = craft, skill = skill, crafter = crafter, cells = cells }
        m.craftDone, m.craftTotal = m.craftDone + done, m.craftTotal + total
    end

    for _, sec in ipairs(D.SECTIONS) do
        local rows, done = {}, 0
        if s then
            for _, id in ipairs(s.order) do
                local c = s.challenges[id]
                if not D.GRID[id] and (sec.cats[c.cat] or (sec.key == "other" and not Sectioned(c.cat))) then
                    local r = L.ChallengeRow(c, sec.key)
                    rows[#rows + 1] = r
                    if r.done then done = done + 1 end
                end
            end
        end
        if #rows > 0 or sec.key ~= "other" then
            m.sections[#m.sections + 1] = { key = sec.key, label = sec.label, rows = rows, done = done }
        end
    end
    return m
end

-- The footer: points earned, out of the account's maximum, and the next
-- reward. The account's total, whatever a view filters.
function L.FooterModel(s)
    if not s then return { unread = true } end
    local done = 0
    for _, c in pairs(s.challenges) do if c.completed then done = done + 1 end end
    local f = { points = s.points or done, max = s.max or #s.order, rewards = s.rewards or {} }
    for _, r in ipairs(f.rewards) do
        if r.level > f.points then f.nextReward = r; break end
    end
    if f.nextReward then f.toGo = f.nextReward.level - f.points end
    return f
end

------------------------------------------------------------
-- Words
------------------------------------------------------------

function L.CellText(cell)
    local st = cell.state
    if st == "done" then return CHECK end
    if st == "progress" then return ("%d/%d"):format(cell.have, cell.need) end
    if st == "credit" then return "|cffffd100~|r" end
    if st == "unknown" then return "|cff888888?|r" end
    return DASH
end

function L.ProgressText(r)
    if r.done then return CHECK end
    if r.unknown then return "|cff888888Not read yet|r" end
    if r.nocrit then return DASH end
    if not r.total then return "|cff888888?|r" end
    if r.numeric then return L.Number(r.have) .. " / " .. L.Number(r.total) end
    local pct = r.total > 0 and math.floor(100 * r.have / r.total + 0.5) or 0
    return ("%d/%d \194\183 %d%%"):format(r.have, r.total, pct)
end

------------------------------------------------------------
-- Widgets: pooled by kind, laid out top-down on the scroll child
------------------------------------------------------------

local pools = {}

local function Acquire(kind, make)
    local p = pools[kind]
    if not p then p = { list = {}, used = 0 }; pools[kind] = p end
    p.used = p.used + 1
    local w = p.list[p.used]
    if not w then w = make(); p.list[p.used] = w end
    w:ClearAllPoints()
    w:Show()
    return w
end

local function ReleaseAll()
    for _, p in pairs(pools) do
        for i = 1, #p.list do p.list[i]:Hide() end
        p.used = 0
    end
end

local function FS(parent, template, justify)
    local f = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlight")
    f:SetJustifyH(justify or "LEFT")
    return f
end

-- A grid cell's tooltip: the challenge, then where it stands.
local function CellOnEnter(self)
    local cell, row = self.cell, self.row
    if not cell then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    local c = cell.ch
    GameTooltip:AddLine(c and c.name or ("Level " .. cell.need), 1, 1, 1)
    if c and c.desc then GameTooltip:AddLine(c.desc, 0.8, 0.8, 0.8, true) end
    local st, who = cell.state, row and row.who
    if st == "done" then
        GameTooltip:AddLine("Earned" .. (c and c.date and (" on " .. c.date) or ""), 0.4, 1, 0.4)
    elseif st == "progress" then
        GameTooltip:AddLine(("%s: %d of %d"):format(who or "Best", cell.have, cell.need), 1, 0.82, 0)
    elseif st == "credit" then
        GameTooltip:AddLine(("%s has reached %d, but the game does not count it as earned."):format(
            who or "An alt", cell.need), 1, 0.82, 0, true)
    elseif st == "none" then
        GameTooltip:AddLine(row and row.noneText or "Nobody on your accounts yet.", 0.7, 0.7, 0.7)
    elseif st == "unknown" then
        GameTooltip:AddLine("Not read yet.", 0.7, 0.7, 0.7)
    end
    GameTooltip:Show()
end

local function MakeGridTitle()
    local f = CreateFrame("Frame", nil, content)
    f:SetHeight(TITLE_ROW)
    f.title = FS(f, "GameFontNormalLarge")
    f.title:SetPoint("LEFT", f, "LEFT", 4, 0)
    f.count = FS(f, "GameFontHighlight")
    f.count:SetPoint("LEFT", f.title, "RIGHT", 10, 0)
    return f
end

local function MakeGridHead()
    local f = CreateFrame("Frame", nil, content)
    f:SetHeight(ROW_H)
    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetAllPoints()
    f.name = FS(f, "GameFontNormalSmall")
    f.alt = FS(f, "GameFontNormalSmall")
    f.tiers = {}
    for i = 1, 3 do f.tiers[i] = FS(f, "GameFontNormalSmall", "CENTER") end
    return f
end

local function MakeGridRow()
    local f = CreateFrame("Frame", nil, content)
    f:SetHeight(ROW_H)
    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetAllPoints()
    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.icon:SetSize(16, 16)
    f.icon:SetPoint("LEFT", f, "LEFT", 6, 0)
    f.name = FS(f)
    f.name:SetPoint("LEFT", f.icon, "RIGHT", 6, 0)
    f.alt = FS(f)
    f.alt:SetWordWrap(false)
    f.cells = {}
    for i = 1, 3 do
        local b = CreateFrame("Button", nil, f)
        b:SetSize(CELL_W, ROW_H)
        b.text = FS(b, "GameFontHighlight", "CENTER")
        b.text:SetAllPoints()
        b:SetScript("OnEnter", CellOnEnter)
        b:SetScript("OnLeave", HideTip)
        f.cells[i] = b
    end
    return f
end

-- One grid: its title, column heads and rows, from (x, y) at width w.
-- Returns the y below it.
function L.DrawGrid(title, rows, kind, x, y, w, done, total)
    local t = Acquire("gridTitle", MakeGridTitle)
    t:SetPoint("TOPLEFT", content, "TOPLEFT", x, -y)
    t:SetWidth(w)
    t.title:SetText(title)
    t.count:SetText(total > 0 and ("%d / %d"):format(done, total) or "")
    y = y + TITLE_ROW

    local cellsX = w - 3 * CELL_W - 4
    local altX = 116
    local h = Acquire("gridHead", MakeGridHead)
    h:SetPoint("TOPLEFT", content, "TOPLEFT", x, -y)
    h:SetWidth(w)
    h.bg:SetColorTexture(1, 1, 1, 0.05)
    h.name:SetPoint("LEFT", h, "LEFT", 8, 0)
    h.name:SetText(kind == "class" and "Class" or "Trade")
    h.alt:SetPoint("LEFT", h, "LEFT", altX, 0)
    h.alt:SetText(kind == "class" and "Highest-level alt" or "Crafter")
    for i, tier in ipairs(D.TIERS[kind]) do
        h.tiers[i]:SetPoint("CENTER", h, "LEFT", cellsX + (i - 0.5) * CELL_W, 0)
        h.tiers[i]:SetText(tostring(tier))
    end
    y = y + ROW_H

    local dim = Color("TEXT_DIM", { 0.6, 0.6, 0.6 })
    for i, r in ipairs(rows) do
        local f = Acquire("gridRow", MakeGridRow)
        f:SetPoint("TOPLEFT", content, "TOPLEFT", x, -y)
        f:SetWidth(w)
        f.alt:ClearAllPoints()
        f.alt:SetPoint("LEFT", f, "LEFT", altX, 0)
        f.alt:SetWidth(math.max(40, cellsX - altX - 6))
        if kind == "class" then
            local cr, cg, cb = 1, 1, 1
            if AltStable.GetClassRGB then cr, cg, cb = AltStable.GetClassRGB(r.key) end
            f.bg:SetColorTexture(cr, cg, cb, (Color("CLASS_TINT_ALPHA", 0.08)) + 0.04)
            f.icon:SetTexture("Interface\\Icons\\ClassIcon_" .. r.label)
            f.name:SetText(ClassHex(r.key) .. r.label .. "|r")
            if r.best then
                f.alt:SetText(ClassHex(r.key) .. r.best.name .. "|r")
                r.who = r.best.name .. " (level " .. r.best.level .. ")"
            else
                f.alt:SetText(("|cff%02x%02x%02xNo known %s|r"):format(dim[1] * 255, dim[2] * 255, dim[3] * 255,
                    r.label:lower()))
            end
            r.noneText = "No known " .. r.label:lower() .. " on your accounts."
        else
            f.bg:SetColorTexture(1, 1, 1, (i % 2 == 0) and 0.04 or 0.015)
            f.icon:SetTexture(D.CRAFT_ICONS[r.key])
            f.name:SetText(r.label)
            local noun = D.CRAFT_NOUNS[r.key] or r.key:lower()
            if r.crafter then
                f.alt:SetText(ClassHex(r.crafter.class) .. r.crafter.name .. "|r")
                r.who = r.crafter.name .. ", the best " .. r.key .. " on the account"
            elseif r.skill and r.skill > 0 then
                f.alt:SetText("|cff999999Crafter unknown|r")
                r.who = "Best " .. r.key .. " on the account"
            else
                f.alt:SetText(("|cff%02x%02x%02xNo known %s|r"):format(dim[1] * 255, dim[2] * 255, dim[3] * 255, noun))
            end
            r.noneText = "No known " .. noun .. " on your accounts."
        end
        for k, cell in ipairs(r.cells) do
            local b = f.cells[k]
            b:ClearAllPoints()
            b:SetPoint("LEFT", f, "LEFT", cellsX + (k - 1) * CELL_W, 0)
            b.cell, b.row = cell, r
            b.text:SetText(L.CellText(cell))
        end
        y = y + ROW_H
    end
    return y
end

local function SectionOnClick(self)
    local db = DB()
    db.open[self.key] = not db.open[self.key] or nil
    L.Render()
end

local function MakeSection()
    local b = CreateFrame("Button", nil, content)
    b:SetHeight(SECTION_H)
    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetAllPoints()
    b.line = b:CreateTexture(nil, "ARTWORK")
    b.line:SetHeight(1)
    b.line:SetPoint("BOTTOMLEFT")
    b.line:SetPoint("BOTTOMRIGHT")
    b.arrow = b:CreateTexture(nil, "ARTWORK")
    b.arrow:SetSize(14, 14)
    b.arrow:SetPoint("LEFT", b, "LEFT", 6, 0)
    b.label = FS(b, "GameFontNormal")
    b.label:SetPoint("LEFT", b.arrow, "RIGHT", 8, 0)
    b.count = FS(b, "GameFontHighlight")
    b.count:SetPoint("LEFT", b.label, "RIGHT", 10, 0)
    b:SetScript("OnClick", SectionOnClick)
    return b
end

local function RowOnClick(self)
    local r = self.r
    if not r or #r.parts == 0 then return end
    L.expanded[r.id] = not L.expanded[r.id] or nil
    L.Render()
end

local function RowOnEnter(self)
    local r = self.r
    if not r then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine(r.ch.name, 1, 1, 1)
    if r.ch.desc then GameTooltip:AddLine(r.ch.desc, 0.8, 0.8, 0.8, true) end
    if r.done then
        GameTooltip:AddLine("Earned" .. (r.ch.date and (" on " .. r.ch.date) or ""), 0.4, 1, 0.4)
    elseif r.perChar then
        GameTooltip:AddLine("Explored per character: the most complete one seen on this account.", 0.7, 0.7, 0.7, true)
    elseif r.char == "Account" then
        GameTooltip:AddLine("Counted for the whole Battle.net account.", 0.7, 0.7, 0.7)
    end
    if #r.parts > 0 then GameTooltip:AddLine("Click to list its parts.", 0.5, 0.5, 0.5) end
    GameTooltip:Show()
end

local function MakeChallengeRow()
    local b = CreateFrame("Button", nil, content)
    b:SetHeight(ROW_H)
    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetAllPoints()
    b.arrow = b:CreateTexture(nil, "ARTWORK")
    b.arrow:SetSize(12, 12)
    b.arrow:SetPoint("LEFT", b, "LEFT", 14, 0)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetSize(16, 16)
    b.icon:SetPoint("LEFT", b, "LEFT", 32, 0)
    b.name = FS(b)
    b.name:SetPoint("LEFT", b.icon, "RIGHT", 6, 0)
    b.char = FS(b)
    b.char:SetWordWrap(false)
    b.prog = FS(b)
    b.action = FS(b, "GameFontHighlight")
    b.action:SetWordWrap(false)
    b:SetScript("OnClick", RowOnClick)
    b:SetScript("OnEnter", RowOnEnter)
    b:SetScript("OnLeave", HideTip)
    return b
end

local function MakeCritRow()
    local f = CreateFrame("Frame", nil, content)
    f:SetHeight(CRIT_H)
    f.mark = f:CreateTexture(nil, "ARTWORK")
    f.mark:SetSize(14, 14)
    f.mark:SetPoint("LEFT", f, "LEFT", 54, 0)
    f.text = FS(f, "GameFontHighlightSmall")
    f.text:SetPoint("LEFT", f.mark, "RIGHT", 8, 0)
    f.qty = FS(f, "GameFontHighlightSmall")
    return f
end

-- The columns of a checklist row, as fractions of the width.
local function Columns(w)
    return math.floor(w * 0.40), math.floor(w * 0.60), math.floor(w * 0.60) + 110
end

function L.DrawSection(sec, y, w)
    local open = DB().open[sec.key] and true or false
    local b = Acquire("section", MakeSection)
    b:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
    b:SetWidth(w)
    b.key = sec.key
    b.bg:SetColorTexture(1, 1, 1, 0.04)
    local sep = Color("SEP", { 0.22, 0.22, 0.22, 1 })
    b.line:SetColorTexture(sep[1], sep[2], sep[3], sep[4] or 1)
    b.arrow:SetTexture(open and "Interface\\Buttons\\UI-MinusButton-Up" or "Interface\\Buttons\\UI-PlusButton-Up")
    b.label:SetText(sec.label)
    b.count:SetText(("%d / %d"):format(sec.done, #sec.rows))
    y = y + SECTION_H
    if not open then return y end

    local charX, progX, actX = Columns(w)
    if #sec.rows == 0 then
        local r = Acquire("critRow", MakeCritRow)
        r:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
        r:SetWidth(w)
        r.mark:Hide()
        r.text:SetText("|cff888888Not read yet|r")
        r.qty:SetText("")
        return y + CRIT_H
    end
    for _, row in ipairs(sec.rows) do
        local f = Acquire("challengeRow", MakeChallengeRow)
        f:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
        f:SetWidth(w)
        f.r = row
        local expanded = L.expanded[row.id] and true or false
        f.bg:SetColorTexture(1, 1, 1, expanded and 0.06 or 0.0)
        if #row.parts > 0 then
            f.arrow:SetTexture(expanded and "Interface\\Buttons\\UI-MinusButton-Up" or "Interface\\Buttons\\UI-PlusButton-Up")
            f.arrow:Show()
        else
            f.arrow:Hide()
        end
        f.icon:SetTexture(row.ch.icon)
        f.name:SetText(row.done and ("|cff9fe09f" .. row.ch.name .. "|r") or row.ch.name)
        f.name:SetWidth(math.max(60, charX - 60))
        f.char:ClearAllPoints()
        f.char:SetPoint("LEFT", f, "LEFT", charX, 0)
        f.char:SetWidth(progX - charX - 8)
        if row.char == "Account" then
            f.char:SetText("|cff999999Account|r")
        elseif row.char then
            f.char:SetText(ClassHex(row.charClass) .. row.char .. "|r")
        else
            f.char:SetText(row.perChar and "|cff999999Not seen yet|r" or "")
        end
        f.prog:ClearAllPoints()
        f.prog:SetPoint("LEFT", f, "LEFT", progX, 0)
        f.prog:SetText(L.ProgressText(row))
        f.action:ClearAllPoints()
        f.action:SetPoint("LEFT", f, "LEFT", actX, 0)
        f.action:SetPoint("RIGHT", f, "RIGHT", -6, 0)
        f.action:SetText(row.action and ("|cffffd100" .. row.action .. "|r") or "")
        y = y + ROW_H
        if expanded then
            for _, p in ipairs(row.parts) do
                local cr = Acquire("critRow", MakeCritRow)
                cr:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
                cr:SetWidth(w)
                cr.mark:Show()
                cr.mark:SetTexture(p.done and "Interface\\RAIDFRAME\\ReadyCheck-Ready"
                    or "Interface\\Buttons\\UI-CheckBox-Up")
                cr.mark:SetAlpha(p.done and 1 or 0.6)
                cr.text:SetText(p.done and ("|cffaaaaaa" .. tostring(p.text) .. "|r") or tostring(p.text))
                cr.qty:ClearAllPoints()
                cr.qty:SetPoint("LEFT", cr, "LEFT", progX, 0)
                cr.qty:SetText((p.req and p.req > 1) and (L.Number(math.min(p.q or 0, p.req)) .. " / " .. L.Number(p.req)) or "")
                y = y + CRIT_H
            end
        end
    end
    return y
end

------------------------------------------------------------
-- The panel
------------------------------------------------------------

function L.UpdateScrollBar()
    local bar = L.scrollBar
    if not (bar and scroll and content) then return end
    local maxS = math.max(0, (content:GetHeight() or 0) - (scroll:GetHeight() or 0))
    bar:SetMinMaxValues(0, maxS)
    local v = math.min(bar:GetValue() or 0, maxS)
    bar:SetValue(v)
    scroll:SetVerticalScroll(v)
    if maxS > 0 then bar:Show() else bar:Hide() end
end

function L.Render()
    if not panel then return end
    local m = L.model or L.Model(nil, {})
    ReleaseAll()
    local w = scroll:GetWidth() or 0
    if w < 100 then w = PREFERRED_PANEL_W - 2 * PAD - 14 end
    content:SetWidth(w)
    poolFS:SetText(m.pool == "B" and "|cff999999Pool B|r" or "")
    emptyFS:SetShown(not m.read)

    local y = m.read and 0 or 22
    local side = w >= 2 * GRID_MIN_W + GAP
    local gw = side and math.floor((w - GAP) / 2) or w
    local y1 = L.DrawGrid("Classes", m.classes, "class", 0, y, gw, m.classDone, m.classTotal)
    if side then
        local y2 = L.DrawGrid("Tradeskills", m.crafts, "craft", gw + GAP, y, gw, m.craftDone, m.craftTotal)
        y = math.max(y1, y2)
    else
        y = L.DrawGrid("Tradeskills", m.crafts, "craft", 0, y1 + GAP, gw, m.craftDone, m.craftTotal)
    end
    y = y + GAP
    for _, sec in ipairs(m.sections) do y = L.DrawSection(sec, y, w) end
    content:SetHeight(math.max(1, y + PAD))
    L.UpdateScrollBar()
end

function L.BuildPanel(mainFrame)
    if panel then return end
    local layout = AltStable.LAYOUT or {}
    local sidebarW = layout.SIDEBAR_WIDTH or 230
    local titleH = layout.TITLE_H or 30
    local footerH = layout.FOOTER_HEIGHT or 22
    panel = CreateFrame("Frame", nil, mainFrame, "BackdropTemplate")
    if not (AltStable.AnchorBesideSidebar and AltStable.AnchorBesideSidebar(panel, mainFrame)) then
        panel:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", sidebarW + 1, -titleH)
    end
    -- Stops above the footer: the totals bar stays, and carries our points.
    panel:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", 0, footerH + 1)
    local bg = Color("BG_MAIN", { 0.05, 0.05, 0.05, 0.95 })
    if not (AltStable.SkinPanelFill and AltStable.SkinPanelFill(panel, mainFrame, bg)) and AltStable.ApplyBGOnly then
        AltStable.ApplyBGOnly(panel, bg[1], bg[2], bg[3], bg[4])
    end
    panel:Hide()

    titleFS = FS(panel, "GameFontNormalLarge")
    titleFS:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD + 4, -12)
    titleFS:SetText("Legacy")
    titleFS:SetTextColor(unpack(Color("TEXT_BRIGHT", { 1, 1, 1 })))

    -- The view tab, with the sheet's gold underline. One view for now; the
    -- Bucket List joins it.
    local tab = CreateFrame("Button", nil, panel)
    tab:SetHeight(24)
    tab:SetPoint("LEFT", titleFS, "RIGHT", 28, 0)
    tab.text = FS(tab, "GameFontHighlight", "CENTER")
    tab.text:SetPoint("CENTER")
    tab.text:SetText("Challenges")
    tab:SetWidth(96)
    tab.sel = tab:CreateTexture(nil, "OVERLAY")
    tab.sel:SetPoint("BOTTOMLEFT", tab, "BOTTOMLEFT", 0, -4)
    tab.sel:SetPoint("BOTTOMRIGHT", tab, "BOTTOMRIGHT", 0, -4)
    tab.sel:SetHeight(2)
    tab.sel:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 1)
    L.tab = tab

    poolFS = FS(panel, "GameFontHighlightSmall", "RIGHT")
    poolFS:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -PAD - 4, -16)

    scroll = CreateFrame("ScrollFrame", nil, panel)
    scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD, -HEADER_H)
    scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -PAD - 14, 4)
    content = CreateFrame("Frame", nil, scroll)
    content:SetSize(1, 1)
    scroll:SetScrollChild(content)

    emptyFS = FS(content, "GameFontHighlightSmall")
    emptyFS:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -2)
    emptyFS:SetText("|cff888888The Legacy Challenges have not been read yet.|r")
    emptyFS:Hide()

    local bar = CreateFrame("Slider", nil, panel)
    L.scrollBar = bar
    bar:SetWidth(10)
    bar:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -4, -HEADER_H)
    bar:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -4, 4)
    bar:SetOrientation("VERTICAL")
    bar:SetValueStep(1)
    local track = bar:CreateTexture(nil, "BACKGROUND")
    track:SetAllPoints()
    track:SetColorTexture(1, 1, 1, 0.05)
    local thumb = bar:CreateTexture(nil, "OVERLAY")
    thumb:SetColorTexture(1, 1, 1, 0.28)
    thumb:SetSize(10, 32)
    bar:SetThumbTexture(thumb)
    bar:SetScript("OnValueChanged", function(_, value) scroll:SetVerticalScroll(value or 0) end)
    bar:Hide()

    panel:EnableMouseWheel(true)
    panel:SetScript("OnMouseWheel", function(_, delta)
        if bar:IsShown() then bar:SetValue((bar:GetValue() or 0) - delta * 3 * ROW_H) end
    end)
end

------------------------------------------------------------
-- The footer: our points, in the sheet's totals bar
------------------------------------------------------------

local function BarOnEnter(self)
    local f = L.footModel
    if not f or f.unread then return end
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine(("Legacy Points: %d / %d"):format(f.points, f.max), 1, 1, 1)
    for _, r in ipairs(f.rewards) do
        local name = r.name or L.ItemName(r.itemID) or ("item " .. r.itemID)
        local got = f.points >= r.level
        GameTooltip:AddDoubleLine((got and CHECK .. " " or "") .. name, tostring(r.level),
            got and 0.6 or 1, got and 0.6 or 1, got and 0.6 or 1, 1, 0.82, 0)
    end
    GameTooltip:AddLine("Earned on every character of your Battle.net account.", 0.5, 0.5, 0.5, true)
    GameTooltip:Show()
end

local function RewardOnEnter(self)
    local r = self.reward
    if not r then return BarOnEnter(self) end
    GameTooltip:SetOwner(self, "ANCHOR_TOPRIGHT")
    GameTooltip:SetHyperlink("item:" .. r.itemID)
    GameTooltip:Show()
end

local itemAsked = {}
function L.ItemName(itemID)
    local okN, name = Try(Api("C_Item", "GetItemNameByID"), itemID)
    if okN and name then return name end
    if not itemAsked[itemID] then
        itemAsked[itemID] = true
        Try(Api("C_Item", "RequestLoadItemDataByID"), itemID)
    end
    L.wantItem = itemID
    return nil
end

function L.BuildFooter(mainFrame)
    local tb = mainFrame and mainFrame.totalsBar
    if L.foot or not tb then return end
    local f = CreateFrame("Frame", nil, tb)
    f:SetAllPoints(tb)
    f:Hide()
    f.left = FS(f, "GameFontHighlightSmall")
    f.left:SetPoint("LEFT", f, "LEFT", 10, 0)

    f.reward = CreateFrame("Button", nil, f)
    f.reward:SetHeight(18)
    f.reward:SetPoint("RIGHT", f, "RIGHT", -10, 0)
    f.reward.text = FS(f.reward, "GameFontHighlightSmall", "RIGHT")
    f.reward.text:SetPoint("RIGHT", f.reward, "RIGHT", 0, 0)
    f.reward.icon = f.reward:CreateTexture(nil, "ARTWORK")
    f.reward.icon:SetSize(16, 16)
    f.reward.icon:SetPoint("LEFT", f.reward, "LEFT", 0, 0)
    f.reward:SetScript("OnEnter", RewardOnEnter)
    f.reward:SetScript("OnLeave", HideTip)

    local bar = CreateFrame("StatusBar", nil, f)
    bar:SetHeight(8)
    bar:SetPoint("LEFT", f.left, "RIGHT", 12, 0)
    bar:SetPoint("RIGHT", f.reward, "LEFT", -12, 0)
    bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    bar.bg = bar:CreateTexture(nil, "BACKGROUND")
    bar.bg:SetAllPoints()
    bar.bg:SetColorTexture(0, 0, 0, 0.45)
    bar:SetMinMaxValues(0, 1)
    bar.ticks = {}
    bar:EnableMouse(true)
    bar:SetScript("OnEnter", BarOnEnter)
    bar:SetScript("OnLeave", HideTip)
    bar:SetScript("OnSizeChanged", function() L.PlaceTicks() end)
    f.bar = bar
    L.foot = f
end

function L.PlaceTicks()
    local f, m = L.foot, L.footModel
    if not (f and m and not m.unread) then return end
    local bar = f.bar
    local w = bar:GetWidth() or 0
    for i, r in ipairs(m.rewards) do
        local t = bar.ticks[i]
        if not t then
            t = bar:CreateTexture(nil, "OVERLAY")
            t:SetSize(2, 12)
            bar.ticks[i] = t
        end
        t:ClearAllPoints()
        t:SetPoint("CENTER", bar, "LEFT", (m.max > 0 and w * r.level / m.max or 0), 0)
        local got = m.points >= r.level
        t:SetColorTexture(got and GOLD[1] or 0.8, got and GOLD[2] or 0.8, got and GOLD[3] or 0.8, got and 1 or 0.7)
        t:Show()
    end
    for i = #m.rewards + 1, #bar.ticks do bar.ticks[i]:Hide() end
end

function L.RenderFooter()
    local f = L.foot
    if not f then return end
    local m = L.FooterModel(L.state)
    L.footModel = m
    local ar, ag, ab = GOLD[1], GOLD[2], GOLD[3]
    if AltStable.GetAccentRGB then ar, ag, ab = AltStable.GetAccentRGB() end
    if m.unread then
        f.left:SetText("|cff888888Legacy Points: not read yet|r")
        f.bar:SetValue(0)
        f.reward.text:SetText("")
        f.reward.icon:Hide()
        f.reward.reward = nil
        return
    end
    local hex = ("|cff%02x%02x%02x"):format(ar * 255, ag * 255, ab * 255)
    f.left:SetText(("%s%d|r |cffaaaaaa/ %d Legacy Points|r"):format(hex, m.points, m.max))
    f.bar:SetStatusBarColor(ar, ag, ab, 0.9)
    f.bar:SetValue(m.max > 0 and math.min(1, m.points / m.max) or 0)
    local r = m.nextReward
    if r then
        local name = r.name or L.ItemName(r.itemID) or "next reward"
        local icon = select(2, Try(Api("C_Item", "GetItemIconByID"), r.itemID))
        f.reward.icon:SetTexture(icon)
        f.reward.icon:SetShown(icon ~= nil)
        f.reward.text:SetText(("|cffaaaaaaNext reward:|r %s |cffaaaaaa\194\183 %d %s to go|r"):format(
            name, m.toGo, m.toGo == 1 and "point" or "points"))
        f.reward.reward = r
    else
        f.reward.icon:Hide()
        f.reward.text:SetText(("|cffaaaaaaAll rewards earned \194\183|r %d / %d"):format(m.points, m.max))
        f.reward.reward = nil
    end
    f.reward:SetWidth((f.reward.text:GetStringWidth() or 100) + 22)
    L.PlaceTicks()
end

------------------------------------------------------------
-- Refresh, activation, bootstrap
------------------------------------------------------------

function L.Refresh()
    L.state = L.Read(L.state)
    L.model = L.Model(L.state, L.OwnAlts())
    L.Render()
    L.RenderFooter()
end

local refreshTimer
function L.RequestRefresh(delay)
    if refreshTimer then return end
    refreshTimer = C_Timer.NewTimer(delay or 1, function()
        refreshTimer = nil
        if L.isActive then L.Refresh() end
    end)
end

local function HookRefresh()
    if L._refreshHooked or type(AltStable.RefreshSheet) ~= "function" then return end
    local prev = AltStable.RefreshSheet
    AltStable.RefreshSheet = function(...)
        prev(...)
        if L.isActive then L.RequestRefresh(0) end
    end
    L._refreshHooked = true
end

-- The grid's parts this tab covers. Not the totals bar: it stays, with our
-- points in place of the core's totals.
local GRID_PARTS = { "bodyScroll", "frozenScroll", "headerScroll", "frozenHeader", "hScrollBar" }

function L.HoldMinSize()
    if not AltStable.EnsureWindowMinSize then return end
    local layout = AltStable.LAYOUT or {}
    AltStable.EnsureWindowMinSize((layout.SIDEBAR_WIDTH or 230) + 1 + MIN_PANEL_W,
        (layout.TITLE_H or 30) + (layout.FOOTER_HEIGHT or 22) + 2 + MIN_PANEL_H)
end

function L.Activate(mainFrame)
    if AltStable.RequestPluginSize then AltStable.RequestPluginSize(PREFERRED_PANEL_W) end
    L.HoldMinSize()
    L.BuildPanel(mainFrame)
    L.BuildFooter(mainFrame)
    HookRefresh()
    L.isActive = true
    for _, k in ipairs(GRID_PARTS) do if mainFrame[k] then mainFrame[k]:Hide() end end
    local tb = mainFrame.totalsBar
    if tb then
        tb:Show()
        if tb.core then tb.core:Hide() end
    end
    if L.foot then L.foot:Show() end
    panel:Show()
    L.ReadExplore()
    L.Refresh()
end

function L.Deactivate(mainFrame)
    L.isActive = false
    if panel then panel:Hide() end
    if L.foot then L.foot:Hide() end
    local tb = mainFrame.totalsBar
    if tb and tb.core then tb.core:Show() end
    for _, k in ipairs(GRID_PARTS) do if mainFrame[k] then mainFrame[k]:Show() end end
end

function L.Bootstrap()
    if not AltStable or not AltStable.RegisterPlugin then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff[AltStable Legacy]|r AltStable not found.")
        return
    end
    HookRefresh()
    AltStable.RegisterPlugin({
        id           = ADDON_ID,
        label        = "Legacy",
        icon         = (AltStable.MEDIA_PATH or "Interface\\AddOns\\AltStable\\Media\\") .. "Icons\\legacy.tga",
        _isPlugin    = true,
        OnActivate   = function(mainFrame) L.Activate(mainFrame) end,
        -- The window changed size under us: maximize, restore, the sidebar (#150).
        OnResize     = function()
            if not L.isActive then return end
            L.HoldMinSize()
            L.Render()
        end,
        OnDeactivate = function(mainFrame) L.Deactivate(mainFrame) end,
        OnForget     = function(guid) if guid then DB().explore[guid] = nil end end,
        _test        = L,
    })
    -- Explore Azeroth is readable from login on: keep this character's.
    C_Timer.After(3, L.ReadExplore)
end

local frame = CreateFrame("Frame")
frame:SetScript("OnEvent", function(_, event, arg1)
    if event == "PLAYER_LOGIN" then
        C_Timer.After(1, L.Bootstrap)
    elseif event == "ACHIEVEMENT_EARNED" then
        C_Timer.After(1, L.ReadExplore)
        L.RequestRefresh(1)
    elseif event == "GET_ITEM_INFO_RECEIVED" then
        if L.isActive and L.wantItem and tonumber(arg1) == L.wantItem then L.RenderFooter() end
    else
        -- CRITERIA_UPDATE fires on every kill: debounced, and only read while
        -- the tab shows.
        L.RequestRefresh(2)
    end
end)
for _, ev in ipairs({ "PLAYER_LOGIN", "ACHIEVEMENT_EARNED", "CRITERIA_UPDATE", "RECEIVED_ACHIEVEMENT_LIST",
                      "MAJOR_FACTION_RENOWN_LEVEL_CHANGED", "GET_ITEM_INFO_RECEIVED" }) do
    frame:RegisterEvent(ev)
end

-- Loaded on demand from the core's PLAYER_LOGIN handler, so PLAYER_LOGIN will
-- not fire for us again.
if IsLoggedIn() then
    C_Timer.After(1, L.Bootstrap)
end
