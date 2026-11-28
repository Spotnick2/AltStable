------------------------------------------------------------
-- Search.lua: find an item on every character (#503)
--
-- One window: type part of an item's name, see who holds it and where - bags,
-- bank, mail (the Warband plugin's records) and worn gear (the core's) - and
-- who can craft it (the Professions plugin's known recipes, whose names match
-- too: "transmute" finds Arcanite Bar). Enter opens the Warband tab on the
-- first holder with the item lit; Shift+Enter puts its link in chat. Filters
-- (quality, slot, armour or weapon type, required level, one character) work
-- with no text, and the rows sort by total, name, quality, item level or
-- where the item is first found.
--
-- In the core, not a plugin: worn gear is the core's, and a search for worn
-- gear works with every plugin off. What a plugin knows comes through what it
-- publishes while it is loaded (AltStable.ItemMapsFor), and its absence is
-- said, never read as "none".
--
-- The plan, agreed over five Codex review rounds, is on the issue
-- (https://github.com/Spotnick2/AltStable/issues/503). The parts that are
-- easy to get wrong:
--   * Counts come from ItemMapsFor, one call per character the sheet lists.
--     Not CountItem: that counts hidden characters too, which is right for
--     an item's tooltip and wrong here. ItemMapsFor already holds the mail
--     rules (what is in flight to a character counts once, under them).
--   * One snapshot per change of data, not per keystroke. Rebuilt when the
--     Warband plugin restamps a section (NotifyItemDataChanged) and on the
--     public "CharactersChanged" (a sheet refresh, a scan, a record touched),
--     while the window is open.
--   * Item names come from the client's cache, which knows only what it has
--     seen. The missing ones are asked for at most 20 at a time; an answer
--     with no name, or none in 10 s, retires the item for the session.
------------------------------------------------------------

local S = {}
AltStable._search = S

local MAX_PENDING   = 20      -- item loads asked for at once
local LOAD_TIMEOUT  = 10      -- seconds before a load with no answer is given up
local REBUILD_DELAY = 0.2     -- a burst of writes, one rebuild
local TYPE_DELAY    = 0.15    -- after the last keystroke
local REPAINT_DELAY = 0.25    -- names arriving, one repaint
local MIN_CHARS     = 2
local ROWS          = 10
local ROW_H         = 34
local WIN_W         = 470
local BAR_Y         = 72      -- the two filter bars, under the search box
local ROWS_TOP      = 128

local frame                   -- the window, built on first open

------------------------------------------------------------
-- Text: folded with the client's own lowercase, which knows more than
-- ASCII; the query's length in characters, not bytes.
------------------------------------------------------------

local function Fold(s)
    if C_Intl and C_Intl.ToLower then return C_Intl.ToLower(s) end
    return s:lower()
end

local function Chars(s)
    if strlenutf8 then return strlenutf8(s) end
    return #s
end

------------------------------------------------------------
-- The snapshot: every item a listed character holds or wears
------------------------------------------------------------

local PLACES = { "bags", "bank", "mail" }

-- The characters the sheet lists: a named record, not hidden. A forgotten
-- character has no record, so what someone mailed it never shows here.
local function Eligible(guid, c)
    if type(c) ~= "table" or c.name == nil then return false end
    return not (AltStable.IsCharacterHidden and AltStable.IsCharacterHidden(guid))
end

function S.BuildSnapshot()
    local snap = {}
    local mapsFor = AltStable.ItemMapsFor
    local function add(id, guid, c, place, n)
        id, n = tonumber(id), tonumber(n)
        if not id or not n or n <= 0 then return end
        local e = snap[id]
        if not e then e = { id = id, total = 0, holders = {}, by = {} }; snap[id] = e end
        local h = e.by[guid]
        if not h then
            h = { guid = guid, name = c.name, class = c.class, total = 0,
                  bags = 0, bank = 0, mail = 0, worn = 0 }
            e.by[guid] = h
            e.holders[#e.holders + 1] = h
        end
        h[place] = h[place] + n
        h.total = h.total + n
        e.total = e.total + n
    end
    for guid, c in pairs(AltStableDB or {}) do
        if Eligible(guid, c) then
            local maps = mapsFor and mapsFor(guid)
            if maps then
                for _, place in ipairs(PLACES) do
                    for id, n in pairs(maps[place] or {}) do add(id, guid, c, place, n) end
                end
            end
            -- Worn: one per slot, so two of one ring are two. The item's id
            -- is enough to know the item; the exact string (suffix, enchant)
            -- is what the gear model can call unknown, not the item.
            for _, slot in ipairs(AltStable.GEAR_SLOTS or {}) do
                local id = tonumber(c["gearid_" .. slot.key])
                if id and id > 0 then add(id, guid, c, "worn", 1) end
            end
        end
    end
    -- Who can craft each item (the Professions plugin, while loaded): also the
    -- items nobody holds, and the recipes' names as aliases (PR 2 of #503).
    local crafters = AltStable.ItemCrafters and AltStable.ItemCrafters()
    for id, c in pairs(crafters or {}) do
        id = tonumber(id)
        if id then
            local e = snap[id]
            if not e then e = { id = id, total = 0, holders = {}, by = {} }; snap[id] = e end
            e.crafters, e.aliases = c.crafters or {}, {}
            for i, a in ipairs(c.aliases or {}) do e.aliases[i] = Fold(a) end
        end
    end
    for _, e in pairs(snap) do
        table.sort(e.holders, function(a, b)
            if a.total ~= b.total then return a.total > b.total end
            return (a.name or "") < (b.name or "")
        end)
    end
    return snap
end

------------------------------------------------------------
-- Names, asked for at a pace
------------------------------------------------------------

-- names[id]: the name, or false once retired without one (never asked again
-- this session). folded[id]: the name, folded for matching.
S.names, S.folded, S.queue, S.pending, S.outstanding = {}, {}, {}, {}, 0

local function NameNow(id)
    local nm = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)
    if type(nm) == "string" and nm ~= "" then return nm end
    return nil
end

local function Known(id, nm)
    S.names[id] = nm
    S.folded[id] = nm and Fold(nm) or nil
end

local ScheduleRepaint, ArmTimeout

local function Pump()
    while S.outstanding < MAX_PENDING and #S.queue > 0 do
        local id = table.remove(S.queue, 1)
        if S.names[id] == nil and not S.pending[id] then
            S.pending[id] = GetTime()
            S.outstanding = S.outstanding + 1
            C_Item.RequestLoadItemDataByID(id)
        end
    end
    if S.outstanding > 0 then ArmTimeout() end
end

-- The candidates of a rebuild: each item with no name yet is queued once.
local function QueueNames(snap)
    local queued = {}
    for _, id in ipairs(S.queue) do queued[id] = true end
    for id in pairs(snap) do
        if S.names[id] == nil and not S.pending[id] and not queued[id] then
            local nm = NameNow(id)
            if nm then Known(id, nm)
            else S.queue[#S.queue + 1] = id; queued[id] = true end
        end
    end
    Pump()
end

local function Retire(id)
    if not S.pending[id] then return end
    S.pending[id] = nil
    S.outstanding = S.outstanding - 1
    Known(id, NameNow(id) or false)
end

function S.OnItemDataLoaded(id)
    id = tonumber(id)
    if not id or not S.pending[id] then return end   -- not ours
    Retire(id)
    Pump()
    ScheduleRepaint()
end

-- A load that never answers would hold its place for good, and the status
-- would say "looking up" for good: given up after LOAD_TIMEOUT.
local timeoutArmed
function ArmTimeout()
    if timeoutArmed then return end
    timeoutArmed = true
    C_Timer.After(1, function()
        timeoutArmed = nil
        if not (frame and frame:IsShown()) then return end
        local now, any = GetTime(), false
        for id, at in pairs(S.pending) do
            if now - at >= LOAD_TIMEOUT then Retire(id); any = true end
        end
        if any then Pump(); ScheduleRepaint() end
        if S.outstanding > 0 then ArmTimeout() end
    end)
end

local function PendingCount() return S.outstanding + #S.queue end

------------------------------------------------------------
-- Matching
------------------------------------------------------------

------------------------------------------------------------
-- Filters and sorting (PR 3 of #503). Kept for the session, never saved.
-- A filter alone is a search: "a chest for my level-24 alt" needs no text.
------------------------------------------------------------

S.filters = {}       -- quality, slot, class (+ sub), minLevel, maxLevel, char
S.sort = "total"
S.meta = {}          -- [id] = what the client says of the item (see S.Meta)

S.QUALITIES = { { 0, "Poor" }, { 1, "Common" }, { 2, "Uncommon" }, { 3, "Rare" },
                { 4, "Epic" }, { 5, "Legendary" } }

-- An equipment slot, by the item's equip location.
S.SLOTS = {
    { key = "HEAD", text = "Head", locs = { "INVTYPE_HEAD" } },
    { key = "NECK", text = "Neck", locs = { "INVTYPE_NECK" } },
    { key = "SHOULDER", text = "Shoulder", locs = { "INVTYPE_SHOULDER" } },
    { key = "BACK", text = "Back", locs = { "INVTYPE_CLOAK" } },
    { key = "CHEST", text = "Chest", locs = { "INVTYPE_CHEST", "INVTYPE_ROBE" } },
    { key = "SHIRT", text = "Shirt", locs = { "INVTYPE_BODY" } },
    { key = "TABARD", text = "Tabard", locs = { "INVTYPE_TABARD" } },
    { key = "WRIST", text = "Wrist", locs = { "INVTYPE_WRIST" } },
    { key = "HANDS", text = "Hands", locs = { "INVTYPE_HAND" } },
    { key = "WAIST", text = "Waist", locs = { "INVTYPE_WAIST" } },
    { key = "LEGS", text = "Legs", locs = { "INVTYPE_LEGS" } },
    { key = "FEET", text = "Feet", locs = { "INVTYPE_FEET" } },
    { key = "FINGER", text = "Finger", locs = { "INVTYPE_FINGER" } },
    { key = "TRINKET", text = "Trinket", locs = { "INVTYPE_TRINKET" } },
    { key = "ONEHAND", text = "One-hand", locs = { "INVTYPE_WEAPON" } },
    { key = "TWOHAND", text = "Two-hand", locs = { "INVTYPE_2HWEAPON" } },
    { key = "MAINHAND", text = "Main hand", locs = { "INVTYPE_WEAPONMAINHAND" } },
    { key = "OFFHAND", text = "Off hand",
      locs = { "INVTYPE_WEAPONOFFHAND", "INVTYPE_HOLDABLE", "INVTYPE_SHIELD" } },
    { key = "RANGED", text = "Ranged",
      locs = { "INVTYPE_RANGED", "INVTYPE_RANGEDRIGHT", "INVTYPE_THROWN", "INVTYPE_RELIC" } },
    { key = "BAG", text = "Bag", locs = { "INVTYPE_BAG", "INVTYPE_QUIVER" } },
    { key = "AMMO", text = "Ammo", locs = { "INVTYPE_AMMO" } },
}
S.SLOT_OF = {}
for _, s in ipairs(S.SLOTS) do for _, loc in ipairs(s.locs) do S.SLOT_OF[loc] = s.key end end

-- The armour and weapon types the Type filter offers (item class ids).
S.TYPE_CLASSES = { { 4, "Armor" }, { 2, "Weapon" } }

S.SORTS = { { "total", "Total" }, { "name", "Name" }, { "quality", "Quality" },
            { "ilvl", "Item level" }, { "location", "Location" } }

-- What the client says of an item. Its class, subclass and slot come at
-- once (GetItemInfoInstant); its quality, item level and required level only
-- once its data is cached, which the name queue sees to. Until then they are
-- unknown, and an unknown never passes a filter on them.
function S.Meta(id)
    local m = S.meta[id]
    if m and m.full then return m end
    m = m or {}
    if m.classID == nil then
        local _, _, _, equipLoc, _, classID, subclassID = AltStable.API.GetItemInfoInstant(id)
        m.equipLoc, m.classID, m.subclassID = equipLoc, classID, subclassID
    end
    local name, _, quality, ilvl, minLevel = AltStable.API.GetItemInfo(id)
    if name then
        m.quality, m.ilvl, m.minLevel, m.full = quality, ilvl, minLevel, true
    else
        m.quality = C_Item.GetItemQualityByID and C_Item.GetItemQualityByID(id) or nil
    end
    S.meta[id] = m
    return m
end

function S.AnyFilter()
    local f = S.filters
    return (f.quality or f.slot or f.class or f.minLevel or f.maxLevel or f.char) ~= nil
end

-- The item's own filters (the character filter is a view: S.ForCharacter).
function S.Pass(id)
    local f, m = S.filters, S.Meta(id)
    if f.quality and m.quality ~= f.quality then return false end
    if f.slot and S.SLOT_OF[m.equipLoc or ""] ~= f.slot then return false end
    if f.class and (m.classID ~= f.class or (f.sub and m.subclassID ~= f.sub)) then return false end
    if f.minLevel or f.maxLevel then
        local lvl = m.full and tonumber(m.minLevel)
        if not lvl then return false end            -- unknown never matches a range
        if f.minLevel and lvl < f.minLevel then return false end
        if f.maxLevel and lvl > f.maxLevel then return false end
    end
    return true
end

-- One character's part of an item: what they hold and whether they can craft
-- it, with their own total; nil when neither. Its location, Enter and the
-- hover all follow from it.
function S.ForCharacter(e, guid)
    local h = e.by[guid]
    local crafters
    for _, c in ipairs(e.crafters or {}) do
        if c.guid == guid then crafters = { c }; break end
    end
    if not h and not crafters then return nil end
    return { id = e.id, total = h and h.total or 0, holders = { h }, by = { [guid] = h },
             crafters = crafters, aliases = e.aliases }
end

-- Where an item is first found: bags < bank < mail < worn < only craftable.
function S.LocationRank(e)
    local best = 5
    for _, h in ipairs(e.holders) do
        if h.bags > 0 then return 1 end
        if h.bank > 0 then best = math.min(best, 2)
        elseif h.mail > 0 then best = math.min(best, 3)
        elseif h.worn > 0 then best = math.min(best, 4) end
    end
    return best
end

-- Unknown last, whichever way the key runs.
local function ByKey(ka, kb, descending)
    if ka == kb then return nil end
    if ka == nil then return false end
    if kb == nil then return true end
    if descending then return ka > kb end
    return ka < kb
end

local function FoldedName(id)
    local f = S.folded[id]
    return type(f) == "string" and f or nil
end

S.SORT_KEYS = {
    total    = function(e) return e.total end, -- descending
    quality  = function(e) return S.Meta(e.id).quality end,
    ilvl     = function(e) local m = S.Meta(e.id); return m.full and m.ilvl or nil end,
    location = function(e) return S.LocationRank(e) end,
}
local DESCENDING = { total = true, quality = true, ilvl = true }

function S.Compare(a, b)
    local key = S.SORT_KEYS[S.sort]
    if key then
        local r = ByKey(key(a), key(b), DESCENDING[S.sort])
        if r ~= nil then return r end
    end
    -- Then by name, unnamed last, then by id: a stable order for equal names.
    local r = ByKey(FoldedName(a.id), FoldedName(b.id), false)
    if r ~= nil then return r end
    return a.id < b.id
end

-- The rows for a query and the filters: items whose name (or a recipe
-- making it) holds the text, and that pass the filters; sorted by S.sort.
function S.Match(snap, query)
    local out = {}
    query = (query or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local text = Chars(query) >= MIN_CHARS
    local filtered = S.AnyFilter()
    if not (text or filtered) then return out end
    local q = text and Fold(query)
    local char = S.filters.char
    -- A character hidden or forgotten since it was chosen: the filter goes.
    if char and not Eligible(char, AltStableDB and AltStableDB[char]) then
        S.filters.char, char = nil, nil
        filtered = S.AnyFilter()
        if not (text or filtered) then return out end
    end
    for id, e in pairs(snap or {}) do
        local hit = true
        if text then
            local f = S.folded[id]
            hit = f and f:find(q, 1, true)
            -- Or a recipe making it: "transmute" finds Arcanite Bar, even
            -- before the bar's own name has loaded ("item 12345" until then).
            if not hit then
                for _, a in ipairs(e.aliases or {}) do
                    if a:find(q, 1, true) then hit = true; break end
                end
            end
        end
        if hit and char then e = S.ForCharacter(e, char); hit = e ~= nil end
        if hit and filtered then hit = S.Pass(id) end
        if hit then out[#out + 1] = e end
    end
    table.sort(out, S.Compare)
    return out
end

------------------------------------------------------------
-- What a row says
------------------------------------------------------------

local function ClassName(h)
    local col = AltStable.ClassColor and AltStable.ClassColor(h.class) or ""
    return (col ~= "" and (col .. (h.name or "?") .. "|r")) or (h.name or "?")
end

-- "Evelyne 264, Brom 166, +4 more"
function S.HoldersLine(e, max)
    max = max or 3
    local parts = {}
    for i, h in ipairs(e.holders) do
        if i > max then
            parts[#parts + 1] = "+" .. (#e.holders - max) .. " more"
            break
        end
        parts[#parts + 1] = ClassName(h) .. " " .. h.total
    end
    return table.concat(parts, ", ")
end

-- "Carissa (Tailoring), Brom (Tailoring), +1 more"
function S.CraftersText(e, max)
    max = max or 2
    local parts = {}
    for i, c in ipairs(e.crafters or {}) do
        if i > max then
            parts[#parts + 1] = "+" .. (#e.crafters - max) .. " more"
            break
        end
        parts[#parts + 1] = ClassName(c) .. " (" .. (c.line or "?") .. ")"
    end
    return table.concat(parts, ", ")
end

-- A row's second line: who holds it, then who can craft it. Nobody holding
-- it is "None recorded": what is recorded, never a claim that nobody has it.
function S.WhoLine(e, holders, crafters)
    local held = (#e.holders > 0) and S.HoldersLine(e, holders) or "None recorded"
    if e.crafters and #e.crafters > 0 then
        return held .. "  ·  can craft: " .. S.CraftersText(e, crafters)
    end
    return held
end

-- The row's line, shortened until it fits: fewer holders first, so "can
-- craft" isn't cut off the end (seen in game, 2026-11-28: "can cra..." on
-- Linen Bandage). Past the shortest it is cut with "..."; the hover has all.
S.WHO_FITS = { { 3, 2 }, { 2, 2 }, { 2, 1 }, { 1, 1 } }
function S.FitWhoLine(fs, e)
    local width = fs:GetWidth() or 0
    for i, m in ipairs(S.WHO_FITS) do
        fs:SetText(S.WhoLine(e, m[1], m[2]))
        if width <= 0 or i == #S.WHO_FITS or fs:GetUnboundedStringWidth() <= width then return end
    end
end

-- "12 in bags, 3 in the bank, 1 in the mail, 1 worn"
function S.PlacesText(h)
    local parts = {}
    if h.bags > 0 then parts[#parts + 1] = h.bags .. " in bags" end
    if h.bank > 0 then parts[#parts + 1] = h.bank .. " in the bank" end
    if h.mail > 0 then parts[#parts + 1] = h.mail .. " in the mail" end
    if h.worn > 0 then parts[#parts + 1] = (h.worn > 1 and (h.worn .. " worn") or "worn") end
    return table.concat(parts, ", ")
end

-- The first holder with the item somewhere Warband shows: bags, bank, mail.
function S.RevealTarget(e)
    for _, h in ipairs(e.holders) do
        if h.bags + h.bank + h.mail > 0 then return h end
    end
    return nil
end

------------------------------------------------------------
-- The window's state
------------------------------------------------------------

S.snap, S.rows, S.offset, S.selected = nil, {}, 0, nil

local function SetStatus(text)
    if frame then frame.status:SetText(text or "") end
end

local function DefaultStatus()
    local n = PendingCount()
    if n > 0 then return ("Looking up %d item %s"):format(n, n == 1 and "name" or "names") end
    if Chars(S.query or "") < MIN_CHARS and not S.AnyFilter() then
        return "Type at least two letters of an item's name, or choose a filter."
    end
    if #S.rows == 0 then return "None recorded." end
    return ("%d %s"):format(#S.rows, #S.rows == 1 and "item" or "items")
end

local Paint, QueueRerun

-- fromData: a refresh of the data (a rebuild, names loading), not something
-- the player did: what the status says (a send's answer) stays.
local function Rerun(fromData)
    if not frame then return end
    S.queryPending = nil
    -- The selection follows its item, wherever a re-sort puts it.
    local held = S.selected and S.rows[S.selected]
    local keep = held and held.id
    S.rows = S.Match(S.snap, S.query)
    S.selected = nil
    for i, e in ipairs(S.rows) do
        if e.id == keep then S.selected = i end
    end
    if not S.selected and #S.rows > 0 then S.selected = 1 end
    if not fromData then S.message = nil end
    Paint()
end

-- Typed (the search box, a level bound): one rerun, TYPE_DELAY after the last
-- key. S.queryPending says the rows are behind what the boxes say.
local typeArmed
function QueueRerun()
    S.queryPending = true
    if typeArmed then return end
    typeArmed = true
    C_Timer.After(TYPE_DELAY, function()
        typeArmed = nil
        if frame and frame:IsShown() and S.queryPending then S.offset = 0; Rerun() end
    end)
end

function S.Rebuild()
    S.snap = S.BuildSnapshot()
    QueueNames(S.snap)
    Rerun(true)
end

local repaintArmed
function ScheduleRepaint()
    if repaintArmed then return end
    repaintArmed = true
    C_Timer.After(REPAINT_DELAY, function()
        repaintArmed = nil
        if frame and frame:IsShown() then Rerun(true) end
    end)
end

-- Data changed somewhere: one rebuild for the burst, and only while the
-- window is open - closed, there is nothing to keep current.
local rebuildArmed
function AltStable.NotifyItemDataChanged()
    if not (frame and frame:IsShown()) or rebuildArmed then return end
    rebuildArmed = true
    C_Timer.After(REBUILD_DELAY, function()
        rebuildArmed = nil
        if frame and frame:IsShown() then S.Rebuild() end
    end)
end

local function OnCharactersChanged() AltStable.NotifyItemDataChanged() end

------------------------------------------------------------
-- Actions
------------------------------------------------------------

local function Selected() return S.selected and S.rows[S.selected] end

-- Enter: the Warband tab, on the first holder, the item lit.
function S.Reveal(e)
    e = e or Selected()
    if not e then return false end
    -- Nothing in bags, bank or mail to open: say who wears it and who can
    -- craft it, which are known with Warband off too (review of #554).
    local warband = AltStable.ItemMapsFor ~= nil
    local h = warband and S.RevealTarget(e)
    if not h then
        local worn, parts = {}, {}
        for _, x in ipairs(e.holders) do if x.worn > 0 then worn[#worn + 1] = x.name end end
        if #worn > 0 then parts[1] = "Worn by " .. table.concat(worn, ", ") .. "."
        elseif warband then parts[1] = "None recorded." end
        if e.crafters and #e.crafters > 0 then
            parts[#parts + 1] = "Can craft: " .. S.CraftersText(e, 3) .. "."
        end
        if not warband then parts[#parts + 1] = "Bags, bank and mail need the Warband module." end
        S.message = table.concat(parts, " ")
        Paint(); return false
    end
    local ok = AltStable._OpenPluginTab and AltStable._OpenPluginTab("warband", "item", h.guid, e.id)
    if not ok then
        S.message = "The Warband tab isn't available."
        Paint(); return false
    end
    frame:Hide()
    return true
end

-- Shift: the item's link into chat, never sent. Straight into the chat box,
-- not ChatFrameUtil.InsertLink, which may hand it to the auction house's
-- search instead.
-- The item's link, or nil once it has been asked for (and the status says so).
local function LinkOf(e)
    local _, link = AltStable.API.GetItemInfo(e.id)
    if not link then
        C_Item.RequestLoadItemDataByID(e.id)
        S.message = "Item link loading, try again."
        Paint()
    end
    return link
end

local function NameOf(e) return S.names[e.id] or ("item " .. e.id) end

function S.Link(e)
    e = e or Selected()
    if not e then return false end
    -- Presentation mode: chat is under the hidden UI, and bringing it back
    -- would end the showcase look. The link to copy instead (owner, 2026-11-28).
    if AltStable.IsGameUIHidden and AltStable.IsGameUIHidden() then return S.Copy(e) end
    local link = LinkOf(e)
    if not link then return false end
    local eb = ChatFrameUtil.GetActiveWindow()
    if not eb then
        eb = ChatFrameUtil.ChooseBoxForSend()
        if eb then ChatFrameUtil.ActivateChat(eb) end
        -- Activation can be refused (a box that may not open).
        if not eb or ChatFrameUtil.GetActiveWindow() ~= eb then
            S.message = "Chat isn't available."
            Paint(); return false
        end
    end
    eb:Insert(link)
    eb:SetFocus()          -- Blizzard's own order for an open draft
    return true
end

-- The link sent straight out, from the row menu: no chat box needed, so it
-- works in presentation mode too. A whisper's target is "Name Surname", the
-- form a whisper was measured to route with (docs/forever-api-notes.md).
S.SENT_TO = { GUILD = "guild", PARTY = "party", RAID = "raid" }

-- SendChatMessage returns nothing, and a whisper to someone not online fails
-- with a system message in chat, which presentation mode hides (Codex review
-- of #561). So "Sending...", then "Sent" when chat echoes the link back, or
-- what went wrong; nothing heard in SEND_WAIT seconds is said too.
local SEND_WAIT = 5
S.ECHOES = { GUILD = { "CHAT_MSG_GUILD" }, PARTY = { "CHAT_MSG_PARTY", "CHAT_MSG_PARTY_LEADER" },
             RAID = { "CHAT_MSG_RAID", "CHAT_MSG_RAID_LEADER" }, WHISPER = { "CHAT_MSG_WHISPER_INFORM" } }

local function StopListening()
    local p = S.sending
    S.sending = nil
    if not (p and frame) then return end
    for _, ev in ipairs(S.ECHOES[p.chatType] or {}) do frame.events:UnregisterEvent(ev) end
    frame.events:UnregisterEvent("CHAT_MSG_SYSTEM")
end

local function Heard(text)
    StopListening()
    S.message = text
    Paint()
end

-- Readable: a string that isn't secret. A secret one can't even be compared
-- (PORTING-TBC-TO-FOREVER.md); it is left to the wait, which says nothing was
-- confirmed.
local function Readable(v)
    local isSecret = rawget(_G, "issecretvalue")
    if isSecret and isSecret(v) then return nil end
    return type(v) == "string" and v or nil
end

-- "Name Surname", or with a "-realm" the client may add: compared without it,
-- either case.
local function SameName(a, b)
    a, b = a:lower(), b:lower()
    return a == b or a:match("^(.-)%-") == b
end

-- The event's arguments are chat's (CHAT_MSG_*): the text, then the other
-- player's name (an outgoing whisper's recipient), ..., the 12th the
-- sender's GUID. Only the pending send's own echo confirms it (Codex review
-- of #561): a guildmate linking the same item, or a whisper to someone else,
-- doesn't; and nothing readable to tell by leaves it unconfirmed.
function S.OnChatEvent(event, text, who, ...)
    local p = S.sending
    if not p then return end
    text = Readable(text)
    if not text then return end
    if event == "CHAT_MSG_SYSTEM" then
        -- Blizzard's own test for it (ChatFrameOverrides.lua).
        local err = rawget(_G, "ERR_CHAT_PLAYER_NOT_FOUND_S")
        if p.target and type(err) == "string" and text:lower() == err:format(p.target):lower() then
            Heard("No player named " .. p.target .. " is playing.")
        end
        return
    end
    if not text:find("|Hitem:" .. p.id .. "[:|]") then return end
    if p.target then
        -- An outgoing whisper: to the one this send was for.
        who = Readable(who)
        if not (who and SameName(who, p.target)) then return end
    else
        -- Guild, party, raid: said by this character.
        local guid = Readable((select(10, ...)))
        if not (guid and guid == UnitGUID("player")) then return end
    end
    Heard("Sent to " .. p.to .. ": " .. p.name .. ".")
end

function S.Send(e, chatType, target)
    e = e or Selected()
    if not e then return false end
    if C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown() then
        S.message = "Chat can't be sent right now."
        Paint(); return false
    end
    local link = LinkOf(e)
    if not link then return false end
    StopListening()
    local p = { chatType = chatType, target = target, id = e.id, name = NameOf(e),
                to = target or S.SENT_TO[chatType] or chatType }
    S.sending = p
    for _, ev in ipairs(S.ECHOES[chatType] or {}) do frame.events:RegisterEvent(ev) end
    if target then frame.events:RegisterEvent("CHAT_MSG_SYSTEM") end
    C_ChatInfo.SendChatMessage(link, chatType, nil, target)
    S.message = "Sending " .. p.name .. " to " .. p.to .. "..."
    C_Timer.After(SEND_WAIT, function()
        if S.sending == p then Heard("Chat didn't confirm sending " .. p.name .. " to " .. p.to .. ".") end
    end)
    Paint(); return true
end

-- A chat line that prints the link, as item sites give them: pasted into chat
-- later, it shows the link, which a Shift-click then puts in a message.
-- Copying is the player's Ctrl+C on a selected box: CopyToClipboard is
-- forbidden to addons (PORTING-TBC-TO-FOREVER.md).
function S.ScriptLine(link)
    local s = link:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("|", "\\124")
    return '/script DEFAULT_CHAT_FRAME:AddMessage("' .. s .. '");'
end

-- The box in place of the search box, for a moment: the copy line (selected,
-- read-only) or a name to whisper (typed). Escape, Enter or a click elsewhere
-- puts the search box back.
local function StartAside(e, mode, text)
    local a = frame.aside
    a.mode, a.entry, a.fixed = mode, e, text
    frame.box:Hide()
    a._restoring = true; a:SetText(text); a._restoring = nil
    a:Show()
    a:SetFocus()
    if mode == "copy" then a:HighlightText() end
end

function S.EndAside()
    local a = frame and frame.aside
    if not (a and a:IsShown()) then return end
    a:Hide()                       -- first: losing focus ends it again
    a.mode, a.entry, a.fixed = nil, nil, nil
    frame.box:Show()
    S.message = nil
    Paint()
    if frame:IsShown() then frame.box:SetFocus() end
end

-- What the open box is for, from its mode: a refresh while it is open can't
-- put the search's status over it (Codex review of #561).
function S.AsideText()
    local a = frame and frame.aside
    if not (a and a:IsShown() and a.entry) then return nil end
    if a.mode == "copy" then return "Selected: press Ctrl+C. Pasted into chat, it shows the link." end
    return "Whisper " .. NameOf(a.entry) .. " to: type a name, then Enter."
end

function S.Copy(e)
    e = e or Selected()
    if not e then return false end
    local link = LinkOf(e)
    if not link then return false end
    StartAside(e, "copy", S.ScriptLine(link))
    Paint(); return true
end

function S.AskName(e)
    e = e or Selected()
    if not e then return false end
    StartAside(e, "name", "")
    Paint(); return true
end

-- A menu this window opened, closed with it (Codex review of #561): in combat
-- the menu doesn't take the keyboard, so Escape could close the search and
-- leave the menu up, a pick still able to send. S.menu is set while it is up
-- and cleared by its onClose (which runs before any next menu shows); a pick
-- after the window closed does nothing. The menu is above this window in
-- presentation mode too: see the lift in ShowSearch.
function S.ShowOwnedMenu(list, onPick, anchor)
    if not AltStable.ShowMenu then return false end
    local shown = AltStable.ShowMenu(list, function(id)
        if frame and frame:IsShown() then onPick(id) end
    end, nil, { anchor = anchor, onClose = function() S.menu = nil end })
    if not shown then return false end
    S.menu = true
    return shown
end

-- The row menu (right-click). Unavailable entries stay, greyed, with why.
function S.MenuEntries(e)
    local hidden = AltStable.IsGameUIHidden and AltStable.IsGameUIHidden()
    local list = { { id = "title", text = NameOf(e), title = true } }
    local function add(id, text, why)
        list[#list + 1] = { id = id, text = text, disabled = why and true or nil, why = why }
    end
    add("link", "Link in chat", hidden and "Chat is hidden in presentation mode: copy it instead." or nil)
    add("GUILD", "Send to guild", not IsInGuild() and "You aren't in a guild." or nil)
    add("PARTY", "Send to party", not IsInGroup() and "You aren't in a group." or nil)
    add("RAID", "Send to raid", not IsInRaid() and "You aren't in a raid." or nil)
    if UnitIsPlayer("target") and not UnitIsUnit("target", "player") then
        add("target", "Whisper " .. (GetUnitName("target", false) or "your target"),
            not UnitIsFriend("player", "target") and "Whispers don't reach the other faction." or nil)
    end
    add("whisper", "Whisper to...")
    add("copy", "Copy the link")
    return list
end

function S.MenuPick(e, id, targetName)
    if id == "link" then return S.Link(e)
    elseif S.SENT_TO[id] then return S.Send(e, id)
    elseif id == "target" then return targetName and S.Send(e, "WHISPER", targetName)
    elseif id == "whisper" then return S.AskName(e)
    elseif id == "copy" then return S.Copy(e) end
end

function S.OpenMenu(e)
    if not (e and AltStable.ShowMenu) then return false end
    -- The target as it is now: the pick comes later.
    local targetName = UnitIsPlayer("target") and GetUnitName("target", false) or nil
    return S.ShowOwnedMenu(S.MenuEntries(e), function(id) S.MenuPick(e, id, targetName) end)
end

-- The filter and sort menus, hung under their buttons.
local CHECK_ON  = "|TInterface\\Buttons\\UI-CheckBox-Check:14:14:0:0:32:32:0:32:0:32:255:255:255|t "
local CHECK_OFF = "|TInterface\\Buttons\\UI-CheckBox-Check:14:14:0:0:32:32:0:32:0:32:60:60:60|t "
local function Mark(on, text) return (on and CHECK_ON or CHECK_OFF) .. text end

local function QualityColor(q, text)
    local c = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
    if not c then return text end
    return ("|cff%02x%02x%02x%s|r"):format((c.r or 1) * 255, (c.g or 1) * 255, (c.b or 1) * 255, text)
end

local function ClassLabel(cls)
    local n = C_Item.GetItemClassInfo and C_Item.GetItemClassInfo(cls)
    if type(n) == "string" and n ~= "" then return n end
    for _, t in ipairs(S.TYPE_CLASSES) do if t[1] == cls then return t[2] end end
    return "Class " .. cls
end

local function SubLabel(cls, sub)
    local n = C_Item.GetItemSubClassInfo and C_Item.GetItemSubClassInfo(cls, sub)
    if type(n) == "string" and n ~= "" then return n end
    return ClassLabel(cls) .. " " .. sub
end

-- What each filter button says its value is.
function S.FilterText(kind)
    local f = S.filters
    if kind == "quality" then
        for _, x in ipairs(S.QUALITIES) do if x[1] == f.quality then return x[2] end end
    elseif kind == "slot" then
        for _, s in ipairs(S.SLOTS) do if s.key == f.slot then return s.text end end
    elseif kind == "type" and f.class then
        return f.sub and SubLabel(f.class, f.sub) or ClassLabel(f.class)
    elseif kind == "char" and f.char then
        local c = AltStableDB and AltStableDB[f.char]
        return c and c.name
    elseif kind == "sort" then
        for _, x in ipairs(S.SORTS) do if x[1] == S.sort then return x[2] end end
    end
    return nil
end

function S.FilterEntries(kind)
    local f, list = S.filters, {}
    local function add(id, text, on) list[#list + 1] = { id = id, text = Mark(on, text) } end
    if kind == "quality" then
        list[1] = { title = true, text = "Quality" }
        add("any", "Any", f.quality == nil)
        for _, x in ipairs(S.QUALITIES) do add(x[1], QualityColor(x[1], x[2]), f.quality == x[1]) end
    elseif kind == "slot" then
        list[1] = { title = true, text = "Equipment slot" }
        add("any", "Any", f.slot == nil)
        for _, s in ipairs(S.SLOTS) do add(s.key, s.text, f.slot == s.key) end
    elseif kind == "type" then
        -- The armour and weapon types of the items recorded, not every type
        -- the game has.
        add("any", "Any", f.class == nil)
        local subs = {}
        for id in pairs(S.snap or {}) do
            local m = S.Meta(id)
            if m.classID and m.subclassID then
                subs[m.classID] = subs[m.classID] or {}
                subs[m.classID][m.subclassID] = true
            end
        end
        for _, t in ipairs(S.TYPE_CLASSES) do
            local cls = t[1]
            if subs[cls] then
                list[#list + 1] = { title = true, text = ClassLabel(cls) }
                add(tostring(cls), "All " .. ClassLabel(cls):lower(), f.class == cls and f.sub == nil)
                local sorted = {}
                for sub in pairs(subs[cls]) do sorted[#sorted + 1] = sub end
                table.sort(sorted, function(a, b) return SubLabel(cls, a) < SubLabel(cls, b) end)
                for _, sub in ipairs(sorted) do
                    add(cls .. ":" .. sub, SubLabel(cls, sub), f.class == cls and f.sub == sub)
                end
            end
        end
        table.insert(list, 1, { title = true, text = "Armor and weapon type" })
    elseif kind == "char" then
        list[1] = { title = true, text = "Character" }
        add("any", "All characters", f.char == nil)
        local chars = {}
        for guid, c in pairs(AltStableDB or {}) do
            if Eligible(guid, c) then chars[#chars + 1] = { guid = guid, name = c.name, class = c.class } end
        end
        table.sort(chars, function(a, b) return a.name < b.name end)
        for _, c in ipairs(chars) do add(c.guid, ClassName(c), f.char == c.guid) end
    elseif kind == "sort" then
        list[1] = { title = true, text = "Sort by" }
        for _, x in ipairs(S.SORTS) do add(x[1], x[2], S.sort == x[1]) end
    end
    return list
end

function S.FilterPick(kind, id)
    local f = S.filters
    if kind == "quality" then f.quality = (id ~= "any") and tonumber(id) or nil
    elseif kind == "slot" then f.slot = (id ~= "any") and id or nil
    elseif kind == "type" then
        local cls, sub = tostring(id):match("^(%d+):?(%d*)$")
        f.class, f.sub = tonumber(cls), tonumber(sub)
    elseif kind == "char" then f.char = (id ~= "any") and id or nil
    elseif kind == "sort" then S.sort = id
    end
    S.offset = 0
    Rerun()
end

function S.ClearFilters()
    S.filters = {}
    if frame and frame.levelMin then
        frame.levelMin:SetText(""); frame.levelMax:SetText("")
    end
    S.offset = 0
    Rerun()
end

function S.OpenFilterMenu(kind)
    if not frame then return false end
    return S.ShowOwnedMenu(S.FilterEntries(kind), function(id) S.FilterPick(kind, id) end,
                           frame.filterBtns[kind])
end

local function Move(delta)
    if #S.rows == 0 then return end
    S.selected = math.max(1, math.min(#S.rows, (S.selected or 1) + delta))
    if S.selected <= S.offset then S.offset = S.selected - 1 end
    if S.selected > S.offset + ROWS then S.offset = S.selected - ROWS end
    Paint()
end

------------------------------------------------------------
-- The window
------------------------------------------------------------

local function RowTooltip(row)
    local e = row.entry
    if not e then return end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:SetText(S.names[e.id] or ("item " .. e.id), 1, 1, 1)
    for _, h in ipairs(e.holders) do
        GameTooltip:AddDoubleLine(ClassName(h), S.PlacesText(h), 1, 1, 1, 0.8, 0.8, 0.8)
    end
    if #e.holders == 0 then GameTooltip:AddLine("None recorded", 0.8, 0.8, 0.8) end
    if e.crafters and #e.crafters > 0 then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Can craft it", 1, 0.82, 0)
        for _, c in ipairs(e.crafters) do
            GameTooltip:AddDoubleLine(ClassName(c), c.line or "", 1, 1, 1, 0.8, 0.8, 0.8)
        end
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Right-click: send or copy the link", 0.5, 0.5, 0.5)
    GameTooltip:Show()
end

local function MakeRow(i)
    local row = CreateFrame("Button", nil, frame)
    row:SetHeight(ROW_H)
    row:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -ROWS_TOP - (i - 1) * ROW_H)
    row:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -12, -ROWS_TOP - (i - 1) * ROW_H)
    row.sel = row:CreateTexture(nil, "BACKGROUND")
    row.sel:SetAllPoints()
    row.sel:SetColorTexture(1, 1, 1, 0.08)
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(28, 28)
    row.icon:SetPoint("LEFT", row, "LEFT", 2, 0)
    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 8, -1)
    row.name:SetPoint("RIGHT", row, "RIGHT", -60, 0)
    row.name:SetJustifyH("LEFT")
    -- One line each, cut with "...": a wrapped line ran over the next row (seen
    -- in game, 2026-11-28). The hover has the whole list.
    row.name:SetWordWrap(false)
    row.total = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.total:SetPoint("TOPRIGHT", row, "TOPRIGHT", -4, -3)
    row.who = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.who:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT", 8, 1)
    row.who:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    row.who:SetJustifyH("LEFT")
    row.who:SetWordWrap(false)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetScript("OnClick", function(self, button)
        if not self.entry then return end
        S.selected = self.index
        if button == "RightButton" then
            if GameTooltip:IsOwned(self) then GameTooltip:Hide() end
            Paint()
            S.OpenMenu(self.entry)
        elseif IsShiftKeyDown() then S.Link(self.entry) else S.Reveal(self.entry) end
    end)
    row:SetScript("OnEnter", RowTooltip)
    row:SetScript("OnLeave", function(self) if GameTooltip:IsOwned(self) then GameTooltip:Hide() end end)
    return row
end

function Paint()
    if not frame then return end
    local maxOffset = math.max(0, #S.rows - ROWS)
    S.offset = math.max(0, math.min(S.offset or 0, maxOffset))
    for i = 1, ROWS do
        local row = frame.rows[i]
        local idx = S.offset + i
        local e = S.rows[idx]
        row.entry, row.index = e, idx
        if e then
            local nm = S.names[e.id]
            row.icon:SetTexture((C_Item.GetItemIconByID and C_Item.GetItemIconByID(e.id))
                or "Interface\\Icons\\INV_Misc_QuestionMark")
            local q = C_Item.GetItemQualityByID and C_Item.GetItemQualityByID(e.id)
            local qc = q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
            row.name:SetText(nm or ("item " .. e.id))
            if qc then row.name:SetTextColor(qc.r, qc.g, qc.b) else row.name:SetTextColor(1, 1, 1) end
            row.total:SetText(tostring(e.total))
            S.FitWhoLine(row.who, e)
            row.sel:SetShown(idx == S.selected)
            row:Show()
        else
            row:Hide()
        end
    end
    SetStatus(S.AsideText() or S.message or DefaultStatus())
    -- The filter buttons say what they are set to.
    local fb = frame.filterBtns
    fb.quality.label:SetText("Quality: " .. (S.FilterText("quality") or "Any"))
    fb.slot.label:SetText("Slot: " .. (S.FilterText("slot") or "Any"))
    fb.type.label:SetText("Type: " .. (S.FilterText("type") or "Any"))
    fb.char.label:SetText(S.FilterText("char") or "All characters")
    fb.sort.label:SetText("Sort: " .. (S.FilterText("sort") or "Total"))
    fb.clear:SetEnabled(S.AnyFilter())
    frame.warn:SetShown(AltStable.ItemMapsFor == nil)
end

local function BuildWindow()
    if frame then return end
    frame = CreateFrame("Frame", "AltStableSearch", UIParent, "BackdropTemplate")
    frame:SetSize(WIN_W, ROWS_TOP + ROWS * ROW_H + 34)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
    frame:SetToplevel(true)
    if not (AltStable.SkinWindow and AltStable.SkinWindow(frame, "small")) then
        AltStable.ApplyBackdrop(frame, 0.05, 0.05, 0.08, 0.97)
    end
    -- Glass: the box and the list on the sheet's reading surface, opaque (see
    -- SkinDataColor). The popup's glass alone let the sheet's rows show
    -- through the results (seen in game, 2026-11-28); the title stays glass.
    if AltStable.SkinIsGlass and AltStable.SkinIsGlass() and AltStable.SkinDataColor then
        local surface = frame:CreateTexture(nil, "BACKGROUND", nil, -3)
        surface:SetPoint("TOPLEFT", frame, "TOPLEFT", 6, -36)
        surface:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -6, 6)
        surface:SetColorTexture(unpack(AltStable.SkinDataColor()))
        -- Inside the window's rounded corners: its own (small) glass mask.
        local g = frame._glass
        if g and g.mask and surface.AddMaskTexture then surface:AddMaskTexture(g.mask) end
        frame.surface = surface
    end
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    tinsert(UISpecialFrames, "AltStableSearch")

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 14, -12)
    title:SetText("Find an item")
    if AltStable.SkinText then AltStable.SkinText(title) end

    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)

    local warn = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    warn:SetPoint("TOPRIGHT", close, "TOPLEFT", -4, -8)
    warn:SetText("Bags, bank and mail need the Warband module.")
    warn:SetTextColor(1, 0.6, 0.3)
    frame.warn = warn

    local box = CreateFrame("EditBox", nil, frame, "SearchBoxTemplate")
    box:SetSize(WIN_W - 36, 20)
    box:SetPoint("TOPLEFT", frame, "TOPLEFT", 18, -44)
    box:SetAutoFocus(false)
    -- Hooked: the template's own text handler shows and hides its hint.
    box:HookScript("OnTextChanged", function(self, userInput)
        S.query = self:GetText() or ""
        QueueRerun()
    end)
    -- Set, not hooked: the template's Enter and Escape only clear focus.
    -- Enter acts on what the box says now: typed within the delay, the rows
    -- are still the last query's (Codex review of #548).
    box:SetScript("OnEnterPressed", function()
        if S.queryPending then S.offset = 0; Rerun() end
        if IsShiftKeyDown() then S.Link() else S.Reveal() end
    end)
    box:SetScript("OnEscapePressed", function() frame:Hide() end)
    box:SetScript("OnArrowPressed", function(_, key)
        if key == "UP" then Move(-1) elseif key == "DOWN" then Move(1) end
    end)
    frame.box = box

    -- In the search box's place for a moment (StartAside): the copy line, or
    -- a name to whisper the link to.
    local aside = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
    aside:SetSize(WIN_W - 44, 20)
    aside:SetPoint("TOPLEFT", frame, "TOPLEFT", 24, -44)
    aside:SetAutoFocus(false)
    aside:SetMaxLetters(0)          -- a link cut short is a wrong link
    aside:Hide()
    -- The copy line is read-only: typing over it puts it back, selected.
    aside:SetScript("OnTextChanged", function(self)
        if self.mode ~= "copy" or self._restoring then return end
        if self:GetText() ~= self.fixed then
            self._restoring = true
            self:SetText(self.fixed)
            self:HighlightText()
            self._restoring = nil
        end
    end)
    -- Still selected after a key (Ctrl alone, an arrow), so Ctrl+C copies it all.
    aside:SetScript("OnKeyUp", function(self) if self.mode == "copy" then self:HighlightText() end end)
    aside:SetScript("OnEnterPressed", function(self)
        local e, name = self.entry, (self.mode == "name") and (self:GetText() or ""):match("^%s*(.-)%s*$")
        S.EndAside()
        if e and name and name ~= "" then S.Send(e, "WHISPER", name) end
    end)
    aside:SetScript("OnEscapePressed", function() S.EndAside() end)
    aside:SetScript("OnEditFocusLost", function() S.EndAside() end)
    frame.aside = aside

    -- The filters and the sort (PR 3): two bars under the search box. The
    -- first: quality, slot, type, character; the second: the level range,
    -- the sort, Clear.
    local function FilterButton(kind, w)
        local b = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
        b:SetSize(w, 22)
        b.label = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        b.label:SetPoint("LEFT", b, "LEFT", 6, 0)
        b.label:SetPoint("RIGHT", b, "RIGHT", -6, 0)
        b.label:SetWordWrap(false)
        if kind then b:SetScript("OnClick", function() S.OpenFilterMenu(kind) end) end
        return b
    end
    frame.filterBtns = {}
    local BW, GAP = math.floor((WIN_W - 24 - 3 * 6) / 4), 6
    for i, kind in ipairs({ "quality", "slot", "type", "char" }) do
        local b = FilterButton(kind, BW)
        b:SetPoint("TOPLEFT", frame, "TOPLEFT", 12 + (i - 1) * (BW + GAP), -BAR_Y)
        frame.filterBtns[kind] = b
    end

    local levelLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    levelLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -BAR_Y - 32)
    levelLabel:SetText("Level")
    -- A required-level bound: blank is none, both ends inclusive.
    local function LevelBox(key)
        local lb = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
        lb:SetSize(30, 20)
        lb:SetAutoFocus(false)
        lb:SetNumeric(true)
        lb:SetMaxLetters(2)
        lb:SetScript("OnTextChanged", function(self, userInput)
            if not userInput then return end
            local n = tonumber(self:GetText() or "")
            S.filters[key] = (n and n > 0) and n or nil
            QueueRerun()
        end)
        lb:SetScript("OnEnterPressed", function() frame.box:SetFocus() end)
        lb:SetScript("OnEscapePressed", function() frame.box:SetFocus() end)
        return lb
    end
    frame.levelMin = LevelBox("minLevel")
    frame.levelMin:SetPoint("LEFT", levelLabel, "RIGHT", 10, 0)
    local dash = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    dash:SetPoint("LEFT", frame.levelMin, "RIGHT", 4, 0)
    dash:SetText("to")
    frame.levelMax = LevelBox("maxLevel")
    frame.levelMax:SetPoint("LEFT", dash, "RIGHT", 10, 0)

    local clear = FilterButton(nil, 80)
    clear:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -12, -BAR_Y - 26)
    clear.label:SetText("Clear filters")
    clear:SetScript("OnClick", function() S.ClearFilters() end)
    frame.filterBtns.clear = clear
    local sort = FilterButton("sort", 2 * BW - 80 + GAP)
    sort:SetPoint("RIGHT", clear, "LEFT", -GAP, 0)
    frame.filterBtns.sort = sort

    frame.rows = {}
    for i = 1, ROWS do frame.rows[i] = MakeRow(i) end
    frame:EnableMouseWheel(true)
    frame:SetScript("OnMouseWheel", function(_, delta)
        S.offset = (S.offset or 0) - delta
        Paint()
    end)

    local status = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    status:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 14, 12)
    status:SetPoint("RIGHT", frame, "RIGHT", -14, 0)
    status:SetJustifyH("LEFT")
    status:SetTextColor(0.75, 0.75, 0.75)
    frame.status = status

    frame.events = CreateFrame("Frame")
    frame.events:SetScript("OnEvent", function(_, event, id, ...)
        if event == "ITEM_DATA_LOAD_RESULT" then S.OnItemDataLoaded(id)
        else S.OnChatEvent(event, id, ...) end  -- a send's echo, or its error
    end)

    -- Closing lets everything go: the names, the queue, the snapshot. A load
    -- already asked for is the client's; its answer is ignored.
    -- Closing, not hiding the game UI: OnHide fires for a child of UIParent
    -- when Alt+Z hides UIParent, while the window itself is still shown and
    -- comes back with it. That keeps everything (Codex review of #548).
    frame:SetScript("OnHide", function(self)
        if self:IsShown() then return end
        self.events:UnregisterEvent("ITEM_DATA_LOAD_RESULT")
        StopListening()
        -- Its menu goes with it: its onClose clears S.menu.
        if S.menu and AltStable.CloseCharacterMenu then AltStable.CloseCharacterMenu() end
        if AltStable.UnregisterCallback then AltStable.UnregisterCallback("CharactersChanged", OnCharactersChanged) end
        S.names, S.folded, S.queue, S.pending, S.outstanding = {}, {}, {}, {}, 0
        S.snap, S.rows, S.selected, S.message = nil, {}, nil, nil
        -- A focused box keeps the keyboard after its window is gone (Prompt.lua):
        -- every key would go on landing in it. The search box is back next time
        -- (ShowSearch ends a copy line or a name left open).
        self.box:ClearFocus()
        self.aside:ClearFocus()
        if GameTooltip:IsOwned(self) then GameTooltip:Hide() end
        -- Back under UIParent, as Export does (#434).
        if AltStable.LiftAboveHiddenUI then AltStable.LiftAboveHiddenUI(self, false) end
    end)
    frame:Hide()
end

-- Open the window, with a query when given one (/alts search <words>).
function AltStable.ShowSearch(query)
    BuildWindow()
    S.EndAside()                   -- the search box, not a copy line, takes the query
    -- With the game UI hidden (the showcase), a child of UIParent is invisible
    -- whatever its strata: lifted out first, as Export does (#434).
    if AltStable.LiftAboveHiddenUI and AltStable.IsGameUIHidden then
        -- To DIALOG, its strata with the UI shown and the lifted sheet's: the
        -- menus it opens are FULLSCREEN_DIALOG, and lifted there too it drew
        -- over them (seen in game, 2026-11-28).
        AltStable.LiftAboveHiddenUI(frame, AltStable.IsGameUIHidden(), "DIALOG")
    end
    local wasShown = frame:IsShown()
    frame:Show()
    -- Above the sheet: both are DIALOG and toplevel, the last raised wins.
    if frame.Raise then frame:Raise() end
    if not wasShown then
        frame.events:RegisterEvent("ITEM_DATA_LOAD_RESULT")
        if AltStable.RegisterCallback then AltStable.RegisterCallback("CharactersChanged", OnCharactersChanged) end
        S.Rebuild()
    end
    if query then
        frame.box:SetText(query)
        S.query = query
        S.offset = 0
        Rerun()
    end
    frame.box:SetFocus()
end

-- Tests.
S._test = {
    Window = function() return frame end,
    Rerun = function() Rerun() end,
    MAX_PENDING = MAX_PENDING, LOAD_TIMEOUT = LOAD_TIMEOUT,
}
