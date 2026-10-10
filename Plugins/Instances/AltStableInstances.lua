------------------------------------------------------------
-- AltStableInstances — cross-alt raid-lockout matrix (P2).
--
-- Pure display. The lockout data is captured + synced by the AltStable core
-- (Core.lua ScanSavedInstances) into flat fields on each character record:
--   si_<name>@<diff>      = "expiresAt|progress|total|maxPlayers|diffName"
--   si_boss_<name>@<diff> = "<killmask>"  (bit e-1 set = encounter e dead)
--
-- Laid out SavedInstances-style, grouped DBM-style:
--   rows   = the launch raids (and any returning Vanilla raid someone is
--            saved to) under a collapsible header; collapse state
--            persists per logged-in character. A raid nobody is saved to still
--            shows, with a dash per alt. A landmark thumbnail sits in the name
--            cell; the rest of the row is a plain band.
--   cols   = characters level 60+ (fillers), ranked by level then item level,
--            plus anyone who actually holds a lockout.
--   cell   = boss progress "X/Y", coloured by how soon it resets,
--   hover  = progress, each boss killed or not, lockout size and time to reset.
--
-- KILLED / NOT KILLED COMES FROM THE LOCKOUT, never from a list here (#17). The core
-- encodes kills as a positional bitmask by API encounter index; a static name
-- list would have to match the client's order, which no beta lockout could
-- check - and a wrong name looks like data. Instead the core keeps each boss's
-- name from the same API row as its kill flag (AltStable.LearnRaidEncounters),
-- and a list that ever comes back in another order is marked unstable. A cell
-- names its bosses only when the list is there, stable, and as long as the
-- lockout's boss count; otherwise it shows "X/Y", which cannot be wrong.
-- The `listed` names in RAIDS (from the achievements) only feed the raid
-- name's tooltip, which says who is in the raid and nothing about who is dead.
--
-- LoadOnDemand: registers on PLAYER_LOGIN, or immediately if enabled mid-session.
------------------------------------------------------------

local ADDON_ID = "instances"
local AT_SI = {
    headers = {}, rowLabels = {}, resetCells = {}, cells = {}, bands = {},
    vlines = {}, cvlines = {}, hlines = {}, groups = {},
}

local NAME_COL_W  = 190   -- left (frozen) column: landmark thumbnail + raid name
local RESET_COL_W = 92     -- (frozen) reset day/time column
local COL_W       = 58     -- per-character column
local HEADER_H    = 24
local ROW_H       = 40     -- raid row
local GROUP_H     = 26     -- expansion header row
local ROW_GAP     = 1
local PAD_X       = 12
local PAD_Y       = 10
local TITLE_H     = 22
local STATS_H     = 30
local HBAR_H      = 14     -- horizontal scrollbar strip
local MAX_COLS    = 40
local MAX_OTHER_ROWS = 10  -- unrecognised lockouts shown; the panel has no v-scroll
local MAX_VIEW_COLS = 12   -- character columns visible at once before scrolling
local COL_LEVEL_MIN = 60   -- a character is a "filler" column at this level+
local MAX_FRAME_H = 880    -- don't grow the window past this; collapse to manage

-- Frozen widgets live on `panel`; the character columns (headers, cells, their
-- vertical grid lines) live on `colChild` inside the horizontally-scrolling
-- `colScroll`, so Raid + Reset stay put while many alts scroll.
local panel, colScroll, colChild, hbar
local titleFS, emptyFS, raidHdr, resetHdr, headerBG, headerSep, statsBar, statsFS

-- Thumbnail cover-crop. The shipped art is 512x256 with the (aspect-preserved)
-- image in the top two thirds and black padding below (see Media/Raids/README.md).
-- Only the RATIOS below matter, so art at another power-of-two size with the same
-- 3:1 content in the top two thirds crops identically.
local BAND_IMG_W  = 512
local BAND_IMG_H  = 170
local BAND_TEX_H  = 256
local BAND_CASP   = BAND_IMG_W / BAND_IMG_H      -- content aspect (~3:1)
local BAND_VSCALE = BAND_IMG_H / BAND_TEX_H

------------------------------------------------------------
-- Canonical raid catalogue
--
-- Order = table order (drives row order within a group).
-- `match` lists the lower-cased phrase(s) a live lockout name must contain to
-- bind to this row (GetSavedInstanceInfo prefixes some, e.g. "Coilfang:
-- Serpentshrine Cavern"). No boss names here: they come from the lockout
-- itself (#17, see the note at the top).
--
-- Forever's launch raids first, always shown: Barrow Deeps (8 bosses), Hyjal
-- Summit (13) and Onyxia's Lair (1), in the owner's order, with the owner's
-- art for all three (toned apart: teal, gold, ember).
--
-- `listed` is the bosses as their "Conqueror" achievement lists them, for the
-- raid name's tooltip only (owner's call, until a lockout teaches the client's
-- own list). It is NEVER read against a killmask: its order is the
-- achievement's, not the encounters' (#17). See bossNames and raidBossList.
--
-- The Vanilla raids are not in at launch but will come back (owner): `later`
-- rows are kept, art and all, and shown only once a character holds a lockout
-- there - so their return needs no change here.
------------------------------------------------------------
local RAIDS = {
    { apiName = "Barrow Deeps",        display = "Barrow Deeps",        art = "deeps",
      listed = { "Chillhowl", "Khalith the Dreadspinner", "Amethrax", "Ravus and Darlissa",
                 "Elder Tangleclaw", "Well of Sorrow", "Del'lynar Songwood", "Sonya Darkhallow" } },
    { apiName = "Hyjal Summit",        display = "Hyjal Summit",        art = "hyjal",
      listed = { "Bandalar", "Time-Lost Battalion", "Old Gloomlurker", "Kathris the Haunted",
                 "Elder Minderel", "Council of Thorns", "The Wild King", "Ancient of Decay",
                 "Sylvestris Dusksong", "Gharalis the Abyssal", "Anara Chillwind",
                 "Tracker Stillwind", "Nythus the Dreambound" } },
    { apiName = "Onyxia's Lair",       display = "Onyxia's Lair",       art = "ony",
      listed = { "Onyxia" } },
    { apiName = "Molten Core",         display = "Molten Core",         art = "mc",   later = true },
    { apiName = "Blackwing Lair",      display = "Blackwing Lair",      art = "bwl",  later = true },
    { apiName = "Zul'Gurub",           display = "Zul'Gurub",           art = "zg",   later = true },
    { apiName = "Ruins of Ahn'Qiraj",  display = "Ruins of Ahn'Qiraj",  art = "aq20", later = true },
    { apiName = "Temple of Ahn'Qiraj", aliases = { "Ahn'Qiraj Temple" },
      display = "Temple of Ahn'Qiraj", art = "aq40", later = true },
    { apiName = "Naxxramas",           display = "Naxxramas",           art = "naxx", later = true },
}

-- One group on Forever. A group header still renders (the "Other" group below
-- joins it when a lockout doesn't match the catalogue), and the rows stay
-- collapsible.
local GROUPS = {
    { key = "vanilla", label = "Raids" },
}
-- Nothing starts collapsed: three raids (nine at most) fit without folding.
local DEFAULT_COLLAPSED = {}

-- Build each raid's lower-cased match phrases (apiName + aliases).
for _, r in ipairs(RAIDS) do
    r.match = { r.apiName:lower() }
    if r.aliases then for _, a in ipairs(r.aliases) do r.match[#r.match + 1] = a:lower() end end
end

-- Resolve a live lockout name to its canonical raid by substring-contains, so a
-- prefixed name ("Coilfang: Serpentshrine Cavern") still binds.
local function matchRaid(nameLower)
    for _, r in ipairs(RAIDS) do
        for _, ph in ipairs(r.match) do
            if nameLower == ph or nameLower:find(ph, 1, true) then return r end
        end
    end
    return nil
end

------------------------------------------------------------
-- Per-character collapse state (persisted in AltStableConfig, keyed by GUID)
------------------------------------------------------------
local function collapseStore()
    AltStableConfig = AltStableConfig or {}
    AltStableConfig.instancesCollapse = AltStableConfig.instancesCollapse or {}
    local key = (UnitGUID and UnitGUID("player")) or "default"
    AltStableConfig.instancesCollapse[key] = AltStableConfig.instancesCollapse[key] or {}
    return AltStableConfig.instancesCollapse[key]
end

local function isCollapsed(groupKey)
    local s = collapseStore()
    if s[groupKey] == nil then return DEFAULT_COLLAPSED[groupKey] == true end
    return s[groupKey] == true
end

local function toggleCollapse(groupKey)
    local s = collapseStore()
    local cur = s[groupKey]
    if cur == nil then cur = DEFAULT_COLLAPSED[groupKey] == true end
    s[groupKey] = not cur
    AT_SI.Refresh()
end

------------------------------------------------------------
-- Formatting helpers
------------------------------------------------------------

-- Column headers are 58px. Names here are "First Surname" (Forever gives every
-- character one), so the header shows the first name - cutting the full name at
-- a byte count would hide the part that distinguishes two alts, and on an
-- accented name could slice a UTF-8 character in half. Truncation, when still
-- needed, stops on a character boundary: a continuation byte is 10xxxxxx.
local function truncate(s, maxBytes)
    if #s <= maxBytes then return s end
    local cut = maxBytes
    while cut > 1 do
        local b = s:byte(cut + 1)
        if not b or b < 0x80 or b > 0xBF then break end
        cut = cut - 1
    end
    return s:sub(1, cut)
end

local function shortName(name, maxBytes)
    return truncate((name or "?"):match("^(%S+)") or "?", maxBytes)
end

-- The first `n` CHARACTERS of a string, not bytes: an initial taken with
-- `:sub(1, 1)` cuts an accented surname ("Elodie" with an acute) in half and
-- renders invalid UTF-8.
local function firstChars(s, n)
    local i, taken = 1, 0
    while i <= #s and taken < n do
        local b = s:byte(i)
        local len = (b < 0x80 and 1) or (b < 0xE0 and 2) or (b < 0xF0 and 3) or 4
        i = i + len
        taken = taken + 1
    end
    return s:sub(1, i - 1)
end

-- First names are NOT unique on Forever, so a column of "Kaleid" over another
-- "Kaleid" is useless. Where the shown names would collide, as much of the
-- surname as fits is appended - one character first ("Kaleid S"), more when
-- that still collides ("Kaleid St" / "Kaleid Su"). Two characters whose names
-- are identical stay identical; nothing this narrow could separate them, which
-- is what the full-name tooltip on each header is for.
local function headerNames(chars, maxBytes)
    local out, first, surname = {}, {}, {}
    for i, ch in ipairs(chars) do
        first[i] = shortName(ch.name, maxBytes)
        surname[i] = (ch.name or ""):match("^%S+%s+(%S+)") or ""
        out[i] = first[i]
    end

    local function collisions()
        local counts = {}
        for _, label in ipairs(out) do counts[label] = (counts[label] or 0) + 1 end
        return counts
    end

    for extra = 1, 4 do
        local counts, done = collisions(), true
        for i = 1, #out do
            if counts[out[i]] > 1 and surname[i] ~= "" then
                local room = maxBytes - 1 - #first[i]
                local abbrev = firstChars(surname[i], extra)
                if #abbrev <= room then
                    out[i] = first[i] .. " " .. abbrev
                    done = false
                end
            end
        end
        if done then break end
    end
    return out
end

-- "in 2d 4h" style, from a seconds-remaining value.
local function fmtDur(sec)
    sec = tonumber(sec) or 0
    if sec <= 0 then return "now" end
    local d = math.floor(sec / 86400)
    local h = math.floor((sec % 86400) / 3600)
    local m = math.floor((sec % 3600) / 60)
    if d > 0 then return d .. "d " .. h .. "h" end
    if h > 0 then return h .. "h " .. m .. "m" end
    return m .. "m"
end

-- Reset moment -> "Tue 11:00" (the weekday/time the lockout frees up).
local function resetLabel(ts)
    return date("%a %H:%M", ts)
end

-- Colour a cell by how soon the lockout resets (planning cue).
local function resetColor(remaining)
    if remaining < 12 * 3600 then return 1.00, 0.42, 0.34   -- <12h — going soon
    elseif remaining < 2 * 86400 then return 1.00, 0.82, 0.30 -- <2 days
    else return 0.52, 0.90, 0.52 end                          -- plenty of time
end

-- Parse "si_<name>@<diff>" + "expiresAt|prog|total|size|diffName".
-- A si_boss_ mask value ("5", no pipes) is rejected here — that's what keeps old
-- clients from rendering it as a bogus raid row.
local function parseLockout(key, val)
    local name, diff = key:match("^si_(.+)@(%d+)$")
    if not name then return nil end
    local e, p, t, size, dname = val:match("^(%d+)|(%d*)|(%d*)|(%d*)|(.*)$")
    if not e then return nil end
    return {
        name     = name,
        diff     = tonumber(diff) or 0,
        expires  = tonumber(e) or 0,
        prog     = tonumber(p) or 0,
        total    = tonumber(t) or 0,
        size     = tonumber(size) or 0,
        diffName = dname or "",
    }
end

------------------------------------------------------------
-- Read model
------------------------------------------------------------

-- A list the core learned off a lockout (AltStable.LearnRaidEncounters), when
-- it can be used at all: shaped as written, with names, and not marked
-- unstable. The one rule both readers below share.
local function usableList(known)
    if type(known) ~= "table" or known.unstable or type(known.names) ~= "table"
       or #known.names == 0 then
        return nil
    end
    return known.names
end

-- The lockout's bosses in encounter order, each { name, killed }, or nil when
-- they cannot be named safely (#17): no usable list learned on this machine,
-- or one whose length is not the lockout's boss count. Worked out on hover,
-- not per refresh: only the hovered cell ever needs it.
local function bossNames(lk)
    local store = AltStableConfig and AltStableConfig.raidEncounters
    local names = type(store) == "table" and usableList(store[lk.name .. "@" .. lk.diff])
    if not names or lk.total <= 0 or #names ~= lk.total then return nil end
    local out = {}
    for e, name in ipairs(names) do
        out[e] = { name = name, killed = math.floor(lk.mask / 2 ^ (e - 1)) % 2 == 1 }
    end
    return out
end

-- Which of two lockouts for the same raid row to show (see gather).
local function PreferLockout(a, b)
    if not a then return b end
    if not b then return a end
    if a.expires ~= b.expires then return (a.expires > b.expires) and a or b end
    if a.prog ~= b.prog then return (a.prog > b.prog) and a or b end
    return (a.diff <= b.diff) and a or b
end

-- All tracked characters (with level/ilvl for ranking) + per-char lockouts keyed
-- by canonical raid apiName (lower) when recognised, else raw name; `lk.canon`
-- points at the canonical raid (nil = unknown -> Other).
--
-- The core keys lockouts by name@difficulty and never merges them, but the grid
-- has ONE row per raid - so a character saved to the same raid at two
-- difficulties needs a rule, or `pairs` order decides which one renders and the
-- answer changes between refreshes. Rule: the one that expires latest, then the
-- one with more progress, then the lower difficulty id.
-- Expired lockouts are dropped here rather than at render time: they would
-- otherwise keep a low-level character in the columns and an unrecognised raid
-- in the Other rows, both showing nothing but dashes. Refresh schedules itself
-- for the next expiry so an open tab lets them go without needing a scan.
local function gather()
    local now = time()
    local allChars, lookup = {}, {}
    AltStableDB = AltStableDB or {}
    for guid, c in pairs(AltStableDB) do
        if type(c) == "table" and c.name then
            local mine
            for k, v in pairs(c) do
                if type(k) == "string" then
                    -- si_boss_<name>@<diff> is the per-encounter killmask: read
                    -- with its lockout below, not as a lockout of its own.
                    if k:find("^si_boss_") then   -- skip
                    elseif type(v) == "string" and k:find("^si_") then
                        local lk = parseLockout(k, v)
                        if lk and lk.expires > now then
                            mine = mine or {}
                            lk.canon = matchRaid(lk.name:lower())
                            lk.mask = tonumber(c["si_boss_" .. lk.name .. "@" .. lk.diff]) or 0
                            local key = lk.canon and lk.canon.apiName:lower() or lk.name:lower()
                            mine[key] = PreferLockout(mine[key], lk)
                        end
                    end
                end
            end
            if mine then lookup[guid] = mine end
            allChars[#allChars + 1] = {
                guid = guid, name = c.name, class = c.class,
                level = tonumber(c.level) or 0, ilvl = tonumber(c.ilvl) or 0,
            }
        end
    end
    return allChars, lookup
end

local function findLockout(mine, raid)
    return mine and mine[raid.apiName:lower()] or nil
end

-- Columns: every character level 60+ (filler), plus anyone holding any lockout so
-- a real save is never hidden. Ranked by level, then item level, then name.
--
-- MAX_COLS is applied HERE, not at layout time, and saved characters survive it:
-- the ranking puts a level-30 bank alt last, so a plain truncation would drop
-- exactly the characters the filter exists to include - leaving a raid row of
-- dashes and no column that explains it.
local function columnsForView(allChars, lookup)
    local saved, fillers = {}, {}
    for _, ch in ipairs(allChars) do
        if lookup[ch.guid] then saved[#saved + 1] = ch
        elseif (ch.level or 0) >= COL_LEVEL_MIN then fillers[#fillers + 1] = ch end
    end
    local function rank(a, b)
        if (a.level or 0) ~= (b.level or 0) then return (a.level or 0) > (b.level or 0) end
        if (a.ilvl or 0)  ~= (b.ilvl or 0)  then return (a.ilvl or 0)  > (b.ilvl or 0)  end
        return (a.name or "") < (b.name or "")
    end
    table.sort(saved, rank)
    table.sort(fillers, rank)

    local cols = {}
    for _, ch in ipairs(saved) do
        if #cols >= MAX_COLS then break end
        cols[#cols + 1] = ch
    end
    for _, ch in ipairs(fillers) do
        if #cols >= MAX_COLS then break end
        cols[#cols + 1] = ch
    end
    table.sort(cols, rank)
    return cols
end

-- A returning raid gets its row once anyone holds a lockout there.
local function anySaved(lookup, raid)
    local key = raid.apiName:lower()
    for _, mine in pairs(lookup) do
        if mine[key] then return true end
    end
    return false
end

-- Flatten the catalogue into display rows: an expansion header per group, its
-- raid rows when expanded, then an "Other" group for any unrecognised lockout.
local function buildDisplayRows(lookup)
    local out = {}
    for _, g in ipairs(GROUPS) do
        out[#out + 1] = { isGroup = true, key = g.key, label = g.label }
        if not isCollapsed(g.key) then
            for _, r in ipairs(RAIDS) do
                if not r.later or anySaved(lookup, r) then out[#out + 1] = { raid = r } end
            end
        end
    end
    -- Bounded and sorted: rows sit at absolute offsets with no vertical scroller,
    -- so an unbounded list would run under the stats bar with no way to reach it,
    -- and pairs() over guid-keyed tables would reshuffle them between refreshes.
    local otherRows, seen = {}, {}
    for _, mine in pairs(lookup) do
        for key, lk in pairs(mine) do
            if not lk.canon and not seen[key] then
                seen[key] = true
                otherRows[#otherRows + 1] = { apiName = lk.name, display = lk.name,
                                              isOther = true, match = {} }
            end
        end
    end
    table.sort(otherRows, function(a, b) return a.display < b.display end)
    if #otherRows > 0 then
        local shown = math.min(#otherRows, MAX_OTHER_ROWS)
        local label = (shown < #otherRows)
            and ("Other (" .. shown .. " of " .. #otherRows .. ")") or "Other"
        out[#out + 1] = { isGroup = true, key = "other", label = label }
        if not isCollapsed("other") then
            for i = 1, shown do out[#out + 1] = { raid = otherRows[i] } end
        end
    end
    return out
end

------------------------------------------------------------
-- Widget pools (created lazily, parented to the panel)
------------------------------------------------------------

-- Character-column widgets live on colChild (they scroll horizontally).
-- A button, not a bare font string: the label is abbreviated to fit 58px, so the
-- full name has to be reachable. Hovering a column header shows it.
local function getHeader(i)
    local btn = AT_SI.headers[i]
    if not btn then
        btn = CreateFrame("Button", nil, colChild)
        btn:SetSize(COL_W, HEADER_H)
        btn.text = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        btn.text:SetAllPoints()
        btn.text:SetJustifyH("CENTER")
        btn:SetScript("OnEnter", function(self)
            if not self.fullName then return end
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
            GameTooltip:ClearLines()
            GameTooltip:AddLine(self.fullName, AltStable.GetClassRGB(self.class))
            if self.level then
                GameTooltip:AddLine("Level " .. self.level, 0.7, 0.7, 0.7)
            end
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
        AT_SI.headers[i] = btn
    end
    return btn
end

local function getCVLine(i)
    local t = AT_SI.cvlines[i]
    if not t then
        t = colChild:CreateTexture(nil, "ARTWORK")
        t:SetColorTexture(0, 0, 0, 0.40)
        t:SetWidth(1)
        AT_SI.cvlines[i] = t
    end
    return t
end

local function getRowLabel(j)
    local fs = AT_SI.rowLabels[j]
    if not fs then
        fs = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        fs:SetJustifyH("LEFT")
        fs:SetWidth(NAME_COL_W - 14)
        AT_SI.rowLabels[j] = fs
    end
    return fs
end

-- Reset column = a hover frame (so it can show time-to-reset) with a fontstring.
local function getResetCell(j)
    local rc = AT_SI.resetCells[j]
    if not rc then
        rc = CreateFrame("Frame", nil, panel)
        rc:SetSize(RESET_COL_W, ROW_H - ROW_GAP)
        rc.text = rc:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        rc.text:SetPoint("LEFT", 6, 0)
        rc.text:SetTextColor(0.62, 0.78, 0.95)
        rc:EnableMouse(true)
        rc:SetScript("OnEnter", function(self)
            if not self.expires then return end
            local rem = self.expires - time()
            if rem <= 0 then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(self.raidName or "Reset", 0.6, 0.8, 1)
            GameTooltip:AddLine("Resets in " .. fmtDur(rem), 0.9, 0.9, 0.9)
            GameTooltip:AddLine(resetLabel(self.expires), 0.6, 0.85, 1)
            GameTooltip:Show()
        end)
        rc:SetScript("OnLeave", function() GameTooltip:Hide() end)
        AT_SI.resetCells[j] = rc
    end
    return rc
end

-- Expansion header row: a clickable band with a +/- toggle and a label.
local function getGroup(i)
    local gh = AT_SI.groups[i]
    if not gh then
        gh = CreateFrame("Button", nil, panel)
        gh.bg = gh:CreateTexture(nil, "BACKGROUND")
        gh.bg:SetAllPoints(gh)
        gh.icon = gh:CreateTexture(nil, "ARTWORK")
        gh.icon:SetSize(16, 16)
        gh.icon:SetPoint("LEFT", 6, 0)
        gh.label = gh:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        gh.label:SetPoint("LEFT", gh.icon, "RIGHT", 6, 0)
        gh.sep = gh:CreateTexture(nil, "OVERLAY")
        gh.sep:SetHeight(1)
        gh.sep:SetPoint("BOTTOMLEFT", 0, 0)
        gh.sep:SetPoint("BOTTOMRIGHT", 0, 0)
        gh.sep:SetColorTexture(unpack(AltStable.C.ACCENT))
        gh:SetScript("OnClick", function(self) toggleCollapse(self.key) end)
        gh:SetScript("OnEnter", function(self) self.label:SetTextColor(unpack(AltStable.C.ACCENT)) end)
        gh:SetScript("OnLeave", function(self) self.label:SetTextColor(unpack(AltStable.C.TEXT_BRIGHT)) end)
        AT_SI.groups[i] = gh
    end
    return gh
end

-- The bosses to list for a raid's name: a stable list a lockout taught this
-- machine (any difficulty), else the achievement's `listed`, else nil.
local function raidBossList(raid)
    local store = AltStableConfig and AltStableConfig.raidEncounters
    if type(store) == "table" then
        local keys = {}
        for key in pairs(store) do keys[#keys + 1] = key end
        table.sort(keys)   -- the same answer every time, whatever pairs() does
        for _, key in ipairs(keys) do
            local known = store[key]
            local name = key:match("^(.+)@%d+$")
            local r = name and matchRaid(name:lower())
            local same = (r == raid) or (raid.isOther and name == raid.apiName)
            local names = same and usableList(store[key])
            if names then return names end
        end
    end
    return raid.listed
end

-- A raid row's background: full-width plain band + a landmark thumbnail in the
-- name cell + a readability shade. `art`/`solid` are SEPARATE textures on purpose.
local function getBand(j)
    local b = AT_SI.bands[j]
    if not b then
        b = {}
        b.row   = panel:CreateTexture(nil, "BACKGROUND", nil, 1)
        b.art   = panel:CreateTexture(nil, "BORDER", nil, 0)
        b.shade = panel:CreateTexture(nil, "BORDER", nil, 1)
        -- Hovering the raid's name lists its bosses (owner's call).
        b.hit = CreateFrame("Frame", nil, panel)
        b.hit:EnableMouse(true)
        b.hit:SetScript("OnEnter", function(self)
            local raid = self.raid
            if not raid then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(raid.display, 0.6, 0.8, 1)
            local bosses = raidBossList(raid)
            if bosses then
                GameTooltip:AddLine(#bosses == 1 and "1 boss" or (#bosses .. " bosses"), 0.7, 0.7, 0.7)
                for _, name in ipairs(bosses) do GameTooltip:AddLine(name, 0.9, 0.9, 0.9) end
            end
            GameTooltip:Show()
        end)
        b.hit:SetScript("OnLeave", function() GameTooltip:Hide() end)
        AT_SI.bands[j] = b
    end
    return b
end

local function getVLine(i)
    local t = AT_SI.vlines[i]
    if not t then
        t = panel:CreateTexture(nil, "ARTWORK")
        t:SetColorTexture(0, 0, 0, 0.40)
        t:SetWidth(1)
        AT_SI.vlines[i] = t
    end
    return t
end

local function getHLine(i)
    local t = AT_SI.hlines[i]
    if not t then
        t = panel:CreateTexture(nil, "ARTWORK")
        t:SetColorTexture(0, 0, 0, 0.40)
        t:SetHeight(1)
        AT_SI.hlines[i] = t
    end
    return t
end

-- Load a texture (cached by path). Verifies the load actually took.
local function LoadTexture(tex, path)
    if tex._appliedPath == path and path ~= nil then return true end
    tex:SetTexture(nil)
    if type(path) ~= "string" or path == "" then tex._appliedPath = nil; return false end
    local ok = pcall(tex.SetTexture, tex, path)
    if not ok or not tex:GetTexture() then tex:SetTexture(nil); tex._appliedPath = nil; return false end
    tex._appliedPath = path
    return true
end

-- Cover-crop the content region of the thumbnail into a dw x dh rect.
local function fitBand(tex, dw, dh)
    if dw <= 0 or dh <= 0 then return end
    local dAsp = dw / dh
    local u0, u1, v0, v1 = 0, 1, 0, 1
    if dAsp > BAND_CASP then
        local vis = BAND_CASP / dAsp
        v0 = (1 - vis) / 2; v1 = 1 - v0
    else
        local vis = dAsp / BAND_CASP
        u0 = (1 - vis) / 2; u1 = 1 - u0
    end
    tex:SetTexCoord(u0, u1, v0 * BAND_VSCALE, v1 * BAND_VSCALE)
end

-- Each cell is a mouse-enabled frame with a centered fontstring + a tooltip.
local function getCell(j, i)
    AT_SI.cells[j] = AT_SI.cells[j] or {}
    local cell = AT_SI.cells[j][i]
    if not cell then
        cell = CreateFrame("Frame", nil, colChild)
        cell:SetSize(COL_W, ROW_H)
        cell.text = cell:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        cell.text:SetPoint("CENTER")
        cell:EnableMouse(true)
        cell:SetScript("OnEnter", function(self)
            local d = self.info
            if not d then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(d.raidName, 0.6, 0.8, 1)
            GameTooltip:AddLine(d.charName, AltStable.GetClassRGB(d.class))
            if d.total > 0 then
                GameTooltip:AddLine("Progress: " .. d.prog .. "/" .. d.total, 0.85, 0.85, 0.85)
            end
            -- Each boss, named from the lockout itself (#17); none when the
            -- names cannot be trusted, and "Progress" above still says it all.
            for _, boss in ipairs(d.lk and bossNames(d.lk) or {}) do
                if boss.killed then
                    GameTooltip:AddDoubleLine(boss.name, "Killed", 0.85, 0.85, 0.85, 0.52, 0.90, 0.52)
                else
                    GameTooltip:AddDoubleLine(boss.name, "Not killed", 0.85, 0.85, 0.85, 0.6, 0.6, 0.6)
                end
            end
            local rem = (d.expires or 0) - time()
            if rem > 0 then
                GameTooltip:AddLine("Resets in " .. fmtDur(rem), 0.6, 0.85, 1)
            end

            if d.size and d.size > 0 then
                GameTooltip:AddLine(d.size .. "-player" .. ((d.diffName ~= "" and d.diffName)
                                    and ("  " .. d.diffName) or ""), 0.7, 0.7, 0.7)
            end
            GameTooltip:Show()
        end)
        cell:SetScript("OnLeave", function() GameTooltip:Hide() end)
        AT_SI.cells[j][i] = cell
    end
    return cell
end

------------------------------------------------------------
-- Layout
------------------------------------------------------------

local function hideFrom(pool, from)
    for k = from, #pool do if pool[k] then pool[k]:Hide() end end
end

local function hideBand(b)
    if b then b.row:Hide(); b.art:Hide(); b.shade:Hide(); b.hit:Hide() end
end

-- Wake up when the soonest displayed lockout expires, so a tab left open drops
-- it instead of showing a stale save until the next scan or sync.
local function ScheduleExpiryRefresh(lookup)
    if AT_SI._expiryTimer then AT_SI._expiryTimer:Cancel(); AT_SI._expiryTimer = nil end
    local soonest
    for _, mine in pairs(lookup or {}) do
        for _, lk in pairs(mine) do
            if not soonest or lk.expires < soonest then soonest = lk.expires end
        end
    end
    if not soonest or not C_Timer or not C_Timer.NewTimer then return end
    local delay = soonest - time() + 1
    if delay < 1 then delay = 1 end
    AT_SI._expiryTimer = C_Timer.NewTimer(delay, function()
        AT_SI._expiryTimer = nil
        if AT_SI.isActive then AT_SI.Refresh() end
    end)
end

function AT_SI.Refresh()
    if not panel or not panel:IsShown() then return end

    local allChars, lookup = gather()
    ScheduleExpiryRefresh(lookup)
    local now = time()
    local chars = columnsForView(allChars, lookup)

    raidHdr:Show(); resetHdr:Show()

    local display  = buildDisplayRows(lookup)
    local nCols    = math.min(#chars, MAX_COLS)
    local colX0    = PAD_X + NAME_COL_W + RESET_COL_W
    local rowTop   = PAD_Y + TITLE_H + HEADER_H
    local hdrTop   = -(PAD_Y + TITLE_H)

    -- No columns yet (nobody level 60, nobody saved): the raids still show,
    -- art and all (owner's call), with a word where the columns will go.
    if nCols == 0 then
        emptyFS:ClearAllPoints()
        emptyFS:SetPoint("LEFT", panel, "TOPLEFT", colX0 + 10, hdrTop - HEADER_H / 2)
        emptyFS:SetText((#allChars == 0) and "No characters tracked yet."
                        or "Your level-60 characters show here.")
        emptyFS:Show()
    else
        emptyFS:Hide()
    end
    local CHILD_DY = PAD_Y + TITLE_H          -- panelY + CHILD_DY = colChild-local y

    -- Total content height up front, to size the scroller.
    local contentH = 0
    for _, drow in ipairs(display) do contentH = contentH + (drow.isGroup and GROUP_H or ROW_H) end

    -- Horizontal viewport: at most MAX_VIEW_COLS character columns before scrolling.
    local fullColsW = nCols * COL_W
    local viewportW = math.min(nCols, MAX_VIEW_COLS) * COL_W
    local visibleR  = colX0 + viewportW
    local maxScroll = math.max(0, fullColsW - viewportW)

    colScroll:ClearAllPoints()
    colScroll:SetPoint("TOPLEFT", panel, "TOPLEFT", colX0, hdrTop)
    colScroll:SetSize(viewportW, HEADER_H + contentH)
    colChild:SetSize(math.max(fullColsW, viewportW), HEADER_H + contentH)
    colScroll:Show()

    -- Header band + gold underline (spans the visible width; char headers scroll over it).
    headerBG:ClearAllPoints()
    headerBG:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD_X, hdrTop)
    headerBG:SetPoint("BOTTOMRIGHT", panel, "TOPLEFT", visibleR, hdrTop - HEADER_H)
    -- The same plate as a row card, which is what this grid always had: the
    -- column header and the row bands shared one tone. NOT SkinHeaderBand -
    -- that lifts from the sheet's reading surface, and a plugin section hides
    -- that surface along with the viewports, so the lift would come off a
    -- colour that is not behind this panel and land darker than its own rows.
    headerBG:SetColorTexture(AltStable.SkinCardHeaderColor())
    headerBG:Show()
    headerSep:ClearAllPoints()
    headerSep:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD_X, hdrTop - HEADER_H)
    headerSep:SetPoint("TOPRIGHT", panel, "TOPLEFT", visibleR, hdrTop - HEADER_H)
    headerSep:Show()

    -- Character headers (class-coloured) — on colChild, so they scroll.
    local headerText = headerNames(chars, 9)
    for i = 1, nCols do
        local ch = chars[i]
        local hdr = getHeader(i)
        hdr:ClearAllPoints()
        hdr:SetPoint("TOPLEFT", colChild, "TOPLEFT", (i - 1) * COL_W, -5)
        hdr.text:SetText(headerText[i] or shortName(ch.name, 9))
        hdr.text:SetTextColor(AltStable.GetClassRGB(ch.class))
        hdr.fullName, hdr.class, hdr.level = ch.name, ch.class, ch.level
        hdr:Show()
    end
    hideFrom(AT_SI.headers, nCols + 1)

    local activeSaves, sumProg, sumTotal = 0, 0, 0
    local rr, gg, hl = 0, 0, 0        -- raid-row, group, h-line counters
    local yOff = rowTop               -- running offset from panel top (positive)

    do  -- top border of the grid
        local t = getHLine(hl + 1); hl = hl + 1
        t:ClearAllPoints()
        t:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD_X, -yOff)
        t:SetPoint("TOPRIGHT", panel, "TOPLEFT", visibleR, -yOff)
        t:Show()
    end

    for _, drow in ipairs(display) do
        local y = -yOff
        if drow.isGroup then
            gg = gg + 1
            local gh = getGroup(gg)
            gh.key = drow.key
            gh:ClearAllPoints()
            gh:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD_X, y)
            gh:SetSize(math.max(1, visibleR - PAD_X), GROUP_H)
            gh:SetFrameLevel(colScroll:GetFrameLevel() + 5)   -- above the scrolled cells
            gh.bg:SetColorTexture(AltStable.SkinCardGroupColor())
            gh.icon:SetTexture(isCollapsed(drow.key)
                and "Interface\\Buttons\\UI-PlusButton-Up"
                or  "Interface\\Buttons\\UI-MinusButton-Up")
            gh.label:SetText(drow.label)
            gh.label:SetTextColor(unpack(AltStable.C.TEXT_BRIGHT))
            gh:Show()
            yOff = yOff + GROUP_H
        else
            rr = rr + 1
            local raid = drow.raid
            local rh = ROW_H - ROW_GAP
            local childY = y + CHILD_DY     -- this row's top, in colChild-local coords

            local band = getBand(rr)
            band.row:ClearAllPoints()
            band.row:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD_X, y)
            band.row:SetPoint("BOTTOMRIGHT", panel, "TOPLEFT", visibleR, y - rh)
            -- The card this row is drawn on: opaque, and brighter than the
            -- material it lies on. See AltStable.SkinCardColor.
            band.row:SetColorTexture(AltStable.SkinCardColor())
            band.row:Show()

            local artPath = raid.art and ((AltStable.MEDIA_PATH or "Interface\\AddOns\\AltStable\\Media\\")
                            .. "Raids\\scene-raid-" .. raid.art .. ".tga")
            if artPath and LoadTexture(band.art, artPath) then
                band.art:ClearAllPoints()
                band.art:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD_X, y)
                band.art:SetPoint("BOTTOMRIGHT", panel, "TOPLEFT", PAD_X + NAME_COL_W, y - rh)
                fitBand(band.art, NAME_COL_W, rh)
                band.art:Show()
                band.shade:ClearAllPoints()
                band.shade:SetAllPoints(band.art)
                band.shade:SetColorTexture(0, 0, 0, 0.42)
                band.shade:Show()
            else
                band.art:Hide(); band.shade:Hide()
            end

            band.hit:ClearAllPoints()
            band.hit:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD_X, y)
            band.hit:SetSize(NAME_COL_W, rh)
            band.hit.raid = raid
            band.hit:Show()

            local lbl = getRowLabel(rr)
            lbl:ClearAllPoints()
            lbl:SetPoint("LEFT", panel, "TOPLEFT", PAD_X + 8, y - rh / 2)
            lbl:SetText(raid.display)
            lbl:SetTextColor(unpack(raid.isOther and AltStable.C.TEXT_DIM or AltStable.C.TEXT_BRIGHT))
            lbl:Show()

            -- Reset day/time (real value only; blank when nobody is saved).
            local resetExpires
            for i = 1, nCols do
                local lk = findLockout(lookup[chars[i].guid], raid)
                if lk and lk.expires > now then resetExpires = lk.expires; break end
            end
            local rc = getResetCell(rr)
            rc:ClearAllPoints()
            rc:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD_X + NAME_COL_W, y)
            rc:SetSize(RESET_COL_W, rh)
            rc.text:SetText(resetExpires and resetLabel(resetExpires) or "")
            rc.expires = resetExpires
            rc.raidName = raid.display
            rc:Show()

            for i = 1, nCols do
                local cell = getCell(rr, i)
                cell:ClearAllPoints()
                cell:SetPoint("TOPLEFT", colChild, "TOPLEFT", (i - 1) * COL_W, childY)
                cell:SetSize(COL_W, rh)
                local lk = findLockout(lookup[chars[i].guid], raid)
                if lk and lk.expires > now then
                    cell.text:SetText(lk.total > 0 and (lk.prog .. "/" .. lk.total) or "\226\151\143")
                    cell.text:SetTextColor(resetColor(lk.expires - now))
                    cell.info = {
                        charName = chars[i].name, class = chars[i].class,
                        raidName = raid.display,
                        prog = lk.prog, total = lk.total,
                        size = lk.size, diffName = lk.diffName,
                        expires = lk.expires, lk = lk,
                    }
                    activeSaves = activeSaves + 1
                    sumProg  = sumProg + (lk.prog or 0)
                    sumTotal = sumTotal + (lk.total or 0)
                    cell:Show()
                else
                    cell.text:SetText("|cff555555\226\128\148|r")   -- dim em-dash
                    cell.info = nil
                    cell:Show()
                end
            end
            for i = nCols + 1, #(AT_SI.cells[rr] or {}) do AT_SI.cells[rr][i]:Hide() end
            yOff = yOff + ROW_H
        end

        -- Bottom border of this display row (frozen, spans the visible width).
        local t = getHLine(hl + 1); hl = hl + 1
        t:ClearAllPoints()
        t:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD_X, -yOff)
        t:SetPoint("TOPRIGHT", panel, "TOPLEFT", visibleR, -yOff)
        t:Show()
    end

    -- Frozen vertical separators (name|reset, reset|chars) on the panel.
    do
        local fx = { PAD_X + NAME_COL_W, colX0 }
        for i = 1, #fx do
            local t = getVLine(i)
            t:ClearAllPoints()
            t:SetPoint("TOPLEFT", panel, "TOPLEFT", fx[i], -rowTop)
            t:SetPoint("BOTTOMLEFT", panel, "TOPLEFT", fx[i], -yOff)
            t:Show()
        end
        hideFrom(AT_SI.vlines, 3)
    end

    -- Character column separators — on colChild, so they scroll. Group header
    -- bands (opaque, above colScroll) mask them within header rows.
    local cvTop = -(HEADER_H)
    local cvBot = -(HEADER_H + contentH)
    for i = 1, nCols do
        local t = getCVLine(i)
        t:ClearAllPoints()
        t:SetPoint("TOPLEFT", colChild, "TOPLEFT", i * COL_W, cvTop)
        t:SetPoint("BOTTOMLEFT", colChild, "TOPLEFT", i * COL_W, cvBot)
        t:Show()
    end
    hideFrom(AT_SI.cvlines, nCols + 1)

    -- Horizontal scrollbar (only when the columns overflow the viewport).
    if maxScroll > 0 then
        hbar:SetMinMaxValues(0, maxScroll)
        if hbar:GetValue() > maxScroll then hbar:SetValue(maxScroll) end
        colScroll:SetHorizontalScroll(hbar:GetValue())
        hbar:ClearAllPoints()
        hbar:SetPoint("TOPLEFT", panel, "TOPLEFT", colX0, -(rowTop + contentH + 3))
        hbar:SetWidth(viewportW)
        hbar:Show()
    else
        colScroll:SetHorizontalScroll(0)
        hbar:SetValue(0)
        hbar:Hide()
    end

    -- Hide leftovers.
    hideFrom(AT_SI.rowLabels, rr + 1)
    hideFrom(AT_SI.resetCells, rr + 1)
    for j = rr + 1, #AT_SI.cells do for _, c in ipairs(AT_SI.cells[j]) do c:Hide() end end
    for j = rr + 1, #AT_SI.bands do hideBand(AT_SI.bands[j]) end
    hideFrom(AT_SI.groups, gg + 1)
    hideFrom(AT_SI.hlines, hl + 1)

    -- Stats bar.
    local pct = (sumTotal > 0) and (" (" .. math.floor(100 * sumProg / sumTotal + 0.5) .. "%)") or ""
    local defeated = (sumTotal > 0) and (sumProg .. "/" .. sumTotal .. pct) or "—"
    -- #allChars is what "tracked" means; nCols is how many of them fit as columns.
    local shownNote = (nCols < #allChars) and (" (" .. nCols .. " shown)") or ""
    statsFS:SetText(("|cffffd100Active saves:|r %d       |cffffd100Bosses defeated:|r %s       |cffffd100Characters tracked:|r %d%s")
        :format(activeSaves, defeated, #allChars, shownNote))
    statsBar:Show()

    -- Size the shared window to our content (plugins own their sizing). Width fits
    -- the frozen columns + the (capped) character viewport; extra alts scroll.
    local f = _G["AltStableSheet"]
    if f and AT_SI._sidebarW then
        local leftBase = ((AltStable.LAYOUT and AltStable.LAYOUT.SIDEBAR_WIDTH) or AT_SI._sidebarW) + 1 + PAD_X
        -- With no columns, the word where they will go needs its room too
        -- (review of #223: it ran past the window's edge).
        local emptyW   = emptyFS:IsShown() and ((emptyFS:GetStringWidth() or 0) + 20) or 0
        local wGrid    = leftBase + (NAME_COL_W + RESET_COL_W + math.max(viewportW, emptyW)) + 12
        local wFooter  = leftBase + (statsFS:GetStringWidth() or 0) + PAD_X + 6
        local w = math.max(wGrid, wFooter, 560)
        local h = (AT_SI._titleH or 30) + (PAD_Y + TITLE_H + HEADER_H) + contentH
                + (maxScroll > 0 and HBAR_H or 0) + STATS_H + 8
        local sidebarMin = (AT_SI._titleH or 30)
                + (AltStable.GetSidebarRequiredHeight and AltStable.GetSidebarRequiredHeight() or 0)
        if h < sidebarMin then h = sidebarMin end
        if h > MAX_FRAME_H then h = MAX_FRAME_H end
        -- Through the sheet's request (#150), which remembers it, clamps it to
        -- the display, and leaves a maximized window maximized.
        if AltStable.RequestWindowSize then AltStable.RequestWindowSize(w, h) else f:SetSize(w, h) end
    end
end

------------------------------------------------------------
-- Panel + activation
------------------------------------------------------------

-- Every colour this panel bakes in at build time, in one place - and registered
-- with the theme so a Dark/Class switch repaints it. Without that the panel keeps
-- the old palette until /reload while the per-refresh colours (group backgrounds,
-- row labels) update around it: a half-themed window.
function AT_SI.ApplyTheme()
    if not panel then return end
    local C = AltStable.C
    -- Both of these reach the window's bottom edge - the panel to
    -- BOTTOMRIGHT (0, 1) and its stats bar along the bottom of that - so under
    -- glass they own the bottom corners on this tab and their fills are clipped
    -- to the window outline. A backdrop cannot be masked, so SkinPanelFill
    -- paints a texture instead; under flat nothing changes.
    local win = panel:GetParent()
    if not AltStable.SkinPanelFill(panel, win, C.BG_MAIN) then
        AltStable.ApplyBGOnly(panel, C.BG_MAIN[1], C.BG_MAIN[2], C.BG_MAIN[3], C.BG_MAIN[4])
    end
    if statsBar then
        if not AltStable.SkinPanelFill(statsBar, win, C.BG_FOOTER) then
            AltStable.ApplyBGOnly(statsBar, C.BG_FOOTER[1], C.BG_FOOTER[2], C.BG_FOOTER[3], C.BG_FOOTER[4])
        end
    end
    if AT_SI._hbarThumb then
        AT_SI._hbarThumb:SetColorTexture(C.ACCENT[1], C.ACCENT[2], C.ACCENT[3], 0.85)
    end
    if AT_SI._headerSep then AT_SI._headerSep:SetColorTexture(unpack(C.ACCENT)) end
    if AT_SI._footSep   then AT_SI._footSep:SetColorTexture(unpack(C.ACCENT))   end
    for _, fs in ipairs({ titleFS, raidHdr, resetHdr, statsFS }) do
        if fs then fs:SetTextColor(unpack(C.TEXT_BRIGHT)) end
    end
    if emptyFS then emptyFS:SetTextColor(unpack(C.TEXT_DIM)) end
end

local function BuildPanel(mainFrame)
    if panel then return end
    local sidebarW = (AltStable.LAYOUT and AltStable.LAYOUT.SIDEBAR_WIDTH) or 230
    local titleH   = (AltStable.LAYOUT and AltStable.LAYOUT.TITLE_H) or 30
    AT_SI._sidebarW = sidebarW
    AT_SI._titleH   = titleH

    panel = CreateFrame("Frame", nil, mainFrame, "BackdropTemplate")
    -- Beside the sidebar's edge, so it follows when the sidebar collapses (#150).
    if not (AltStable.AnchorBesideSidebar and AltStable.AnchorBesideSidebar(panel, mainFrame)) then
        panel:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", sidebarW + 1, -titleH)
    end
    panel:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", 0, 1)
    AT_SI._headerSep = headerSep
    panel:Hide()

    -- Horizontally-scrolling viewport for the character columns (Raid + Reset stay
    -- frozen on the panel). colChild holds the char headers/cells/grid lines.
    colScroll = CreateFrame("ScrollFrame", nil, panel)
    colChild  = CreateFrame("Frame", nil, colScroll)
    colChild:SetSize(1, 1)
    colScroll:SetScrollChild(colChild)
    colScroll:EnableMouseWheel(true)
    colScroll:SetScript("OnMouseWheel", function(_, delta)
        if hbar and hbar:IsShown() then hbar:SetValue(hbar:GetValue() - delta * COL_W) end
    end)
    colScroll:Hide()

    hbar = CreateFrame("Slider", nil, panel)
    hbar:SetOrientation("HORIZONTAL")
    hbar:SetHeight(HBAR_H)
    hbar:SetValueStep(1)
    local hbarTrack = hbar:CreateTexture(nil, "BACKGROUND")
    hbarTrack:SetAllPoints(hbar)
    hbarTrack:SetColorTexture(0, 0, 0, 0.40)
    local hbarThumb = hbar:CreateTexture(nil, "OVERLAY")
    AT_SI._hbarThumb = hbarThumb
    hbarThumb:SetSize(48, HBAR_H)
    hbar:SetThumbTexture(hbarThumb)
    hbar:SetScript("OnValueChanged", function(_, val)
        if colScroll then colScroll:SetHorizontalScroll(val) end
    end)
    hbar:Hide()

    titleFS = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    titleFS:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD_X, -PAD_Y + 2)
    titleFS:SetText("Raid Lockouts")


    headerBG = panel:CreateTexture(nil, "BACKGROUND", nil, 2)
    headerBG:Hide()
    headerSep = panel:CreateTexture(nil, "ARTWORK")
    headerSep:SetHeight(1)

    headerSep:Hide()

    raidHdr = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    raidHdr:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD_X + 8, -(PAD_Y + TITLE_H + 5))
    raidHdr:SetText("Raid")

    raidHdr:Hide()

    resetHdr = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    resetHdr:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD_X + NAME_COL_W + 6, -(PAD_Y + TITLE_H + 5))
    resetHdr:SetText("Reset")

    resetHdr:Hide()

    -- BackdropTemplate: ApplyBGOnly colours this through SetBackdrop, which a
    -- plain Frame does not have - the background would silently never appear.
    statsBar = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    statsBar:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 0, 0)
    statsBar:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 0, 0)
    statsBar:SetHeight(STATS_H)

    local footSep = statsBar:CreateTexture(nil, "ARTWORK")
    footSep:SetHeight(1)
    footSep:SetPoint("TOPLEFT", statsBar, "TOPLEFT", 0, 0)
    footSep:SetPoint("TOPRIGHT", statsBar, "TOPRIGHT", 0, 0)
    AT_SI._footSep = footSep
    statsFS = statsBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    statsFS:SetPoint("LEFT", statsBar, "LEFT", PAD_X, 0)

    statsBar:Hide()

    emptyFS = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    emptyFS:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD_X, -(PAD_Y + TITLE_H + 6))
    emptyFS:SetText("No raid lockouts on any tracked character.")

    emptyFS:Hide()

    AT_SI.ApplyTheme()
    if not AT_SI._themeHooked and AltStable.RegisterThemeCallback then
        AltStable.RegisterThemeCallback(function() AT_SI.ApplyTheme() end)
        AT_SI._themeHooked = true
    end
end

local function HookRefresh()
    if AT_SI._refreshHooked or type(AltStable.RefreshSheet) ~= "function" then return end
    local prev = AltStable.RefreshSheet
    AltStable.RefreshSheet = function(...)
        prev(...)
        if AT_SI.isActive then C_Timer.After(0, function() if AT_SI.isActive then AT_SI.Refresh() end end) end
    end
    AT_SI._refreshHooked = true
end

function AT_SI.Activate(mainFrame)
    BuildPanel(mainFrame)
    HookRefresh()
    AT_SI.isActive = true

    if mainFrame.bodyScroll   then mainFrame.bodyScroll:Hide()   end
    if mainFrame.frozenScroll then mainFrame.frozenScroll:Hide() end
    if mainFrame.headerScroll then mainFrame.headerScroll:Hide() end
    if mainFrame.frozenHeader then mainFrame.frozenHeader:Hide() end
    if mainFrame.hScrollBar   then mainFrame.hScrollBar:Hide()   end
    if mainFrame.totalsBar    then mainFrame.totalsBar:Hide()    end

    panel:Show()
    if AltStable.RequestLockouts then AltStable.RequestLockouts() end  -- refresh our own lockouts
    AT_SI.Refresh()
end

function AT_SI.Deactivate(mainFrame)
    AT_SI.isActive = false
    if panel then panel:Hide() end
    if mainFrame.bodyScroll   then mainFrame.bodyScroll:Show()   end
    if mainFrame.frozenScroll then mainFrame.frozenScroll:Show() end
    if mainFrame.headerScroll then mainFrame.headerScroll:Show() end
    if mainFrame.frozenHeader then mainFrame.frozenHeader:Show() end
    if mainFrame.hScrollBar   then mainFrame.hScrollBar:Show()   end
    if mainFrame.totalsBar    then mainFrame.totalsBar:Show()    end
end

function AT_SI._Bootstrap()
    if not AltStable or not AltStable.RegisterPlugin then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff[AltStable Raids]|r AltStable not found.")
        return
    end
    HookRefresh()
    AltStable.RegisterPlugin({
        id           = ADDON_ID,
        label        = "Raids",
        icon         = (AltStable.MEDIA_PATH or "Interface\\AddOns\\AltStable\\Media\\") .. "Icons\\raid.tga",
        _isPlugin    = true,
        OnActivate   = function(mainFrame) AT_SI.Activate(mainFrame) end,
        -- The window changed size under us: maximize, restore, the sidebar (#150).
        OnResize     = function() if AT_SI.isActive then AT_SI.Refresh() end end,
        -- Refresh sizes the window to the grid, so a geometry animation lays
        -- this tab out before measuring where it ends, as for a sheet tab.
        sizesWindow  = true,
        OnDeactivate = function(mainFrame) AT_SI.Deactivate(mainFrame) end,
        _test        = {
            parseLockout = parseLockout, gather = gather, shortName = shortName,
            fmtDur = fmtDur, resetLabel = resetLabel, resetColor = resetColor,
            findLockout = findLockout, PreferLockout = PreferLockout,
            headerNames = headerNames, ScheduleExpiryRefresh = ScheduleExpiryRefresh,
            firstChars = firstChars, getHeader = getHeader,
            matchRaid = matchRaid, columnsForView = columnsForView,
            buildDisplayRows = buildDisplayRows, toggleCollapse = toggleCollapse,
            isCollapsed = isCollapsed, RAIDS = RAIDS,
            -- The painted furniture, so a test can ask what colour this grid
            -- actually used rather than only what the helper would return.
            HeaderBG = function() return headerBG end,
            Bands    = function() return AT_SI.bands end,
            Groups   = function() return AT_SI.groups end,
            Cells    = function() return AT_SI.cells end,
            Refresh  = function() AT_SI.Refresh() end,
            raidBossList = raidBossList, bossNames = bossNames,
            EmptyText = function() return emptyFS and emptyFS:IsShown() and emptyFS:GetText() or nil end,
        },
    })
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:SetScript("OnEvent", function(_, event)
    if event ~= "PLAYER_LOGIN" then return end
    C_Timer.After(1, AT_SI._Bootstrap)
end)

-- Loaded on demand after login: PLAYER_LOGIN already fired, so bootstrap now.
if IsLoggedIn() then
    C_Timer.After(1, AT_SI._Bootstrap)
end
