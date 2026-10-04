------------------------------------------------------------
-- AltStableWarband — consolidated cross-alt bag + bank inventory (P3).
--
-- A single "Warband bank"-style grid of every item across all tracked
-- characters (bags + bank), each unique item shown once as a stack with its
-- total count, grouped by item type, with a search that dims non-matches in
-- place and a per-item tooltip listing which alt holds how many.
--
-- We capture + sync our OWN data (not another addon's SavedVariables) so the
-- other account's characters merge in over AltStable's transport.
--
-- Persistence (plugin-owned; kept out of the core AltStableDB record):
--   AltStableWarbandDB[guid] = {
--       bags = { [itemID] = count },   -- summed across the carried bags + keyring
--       bank = { [itemID] = count },   -- summed across the purchased bank tabs
--       bagsStamp, bankStamp,          -- when each section last changed
--       stamp = max(bagsStamp,bankStamp)  -- drives the delta watermark
--   }
-- bags and bank are SEPARATE maps: bags refresh live on BAG_UPDATE, but the
-- bank is only readable while its frame is open, so a bag rescan must never
-- clobber the (intentionally stale) bank snapshot.
------------------------------------------------------------

AltStableWarbandDB = AltStableWarbandDB or {}

local ADDON_ID     = "warband"
local BLOB_VERSION = "v1"

local BANK_STALE = 7 * 86400   -- flag a bank snapshot as "may be out of date" past this

------------------------------------------------------------
-- Which containers to read
--
-- Every Classic constant this plugin used is wrong on Forever: -1 is the
-- KEYRING (not the main bank), -2 and -3 are bank-TYPE pseudo-ids that hold
-- nothing, and 5 is the carried reagent bag. Measured ids live in Enum.BagIndex
-- and are read through the adapter (see "Container identity" in Compat.lua).
--
-- The bank is not a fixed range either: tabs are bought one at a time, so the
-- set is whatever C_Bank reports as purchased - Character tabs only. An account
-- bank exists in the API but is not viewable on this build; folding its tabs
-- into each character's map would count the same shared items once per alt.
------------------------------------------------------------

local function CarriedBagIDs()
    local ids = AltStable.API.GetCarriedBagIDs()
    if not ids then return nil end
    -- The keyring rides along with the bags so keys are findable too.
    local keyring = AltStable.API.GetKeyringBagID()
    if keyring then
        local out = { keyring }
        for _, id in ipairs(ids) do out[#out + 1] = id end
        return out
    end
    return ids
end

-- nil (not {}) when the bank tabs can't be enumerated, so a failed read aborts
-- the scan instead of recording an empty bank over a good snapshot.
--
-- Cached: BAG_UPDATE fires several times a second while questing and each one
-- asks whether the bag is a bank tab. The set only changes when a tab is
-- bought, which happens at the bank - so every bank session re-reads it.
local tabCache
local function BankTabIDs()
    if tabCache == nil then tabCache = AltStable.API.GetCharacterBankTabIDs() or false end
    return tabCache or nil
end

local function InvalidateTabCache()
    tabCache = nil
end

local function IsBankContainer(bag)
    local tabs = BankTabIDs()
    if not tabs then return false end
    for _, id in ipairs(tabs) do if id == bag then return true end end
    return false
end

local AT_WB = { cells = {}, isActive = false, search = "" }

-- Bank-session state for the transactional bank scan.
local isBankOpen  = false
local bankGen     = 0
local bagsPending = false
local bankPending = false

-- Async item metadata we've asked the client to load (re-render on arrival).
local requestedIDs = {}

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff[AltStable Warband]|r " .. msg)
end

------------------------------------------------------------
-- Retail-API adapters; see Compat.lua. GetContainerItemInfo returns a STRUCT
-- here, not the old positional tuple - reading `stackCount` off return 2 would
-- store nil counts for every slot.
------------------------------------------------------------

local CGetNumSlots = AltStable.API.GetContainerNumSlots
local CGetItemID   = AltStable.API.GetContainerItemID
local CGetItemLink = AltStable.API.GetContainerItemLink
local CGetItemInfo = AltStable.API.GetContainerItemInfo

local function ItemIDFromLink(link)
    if type(link) ~= "string" then return nil end
    return tonumber(link:match("item:(%d+)"))
end

-- Read one slot. Returns:
--   itemID, count   for an occupied, well-formed slot
--   nil             for an empty slot
--   nil, "bad"      occupied but the count is unreadable (caller aborts the scan)
local function ReadSlot(bag, slot)
    local itemID
    if CGetItemID then itemID = CGetItemID(bag, slot) end
    if not itemID or itemID == 0 then
        itemID = ItemIDFromLink(CGetItemLink and CGetItemLink(bag, slot))
    end
    if not itemID or itemID == 0 then return nil end

    local count
    if CGetItemInfo then
        local info = CGetItemInfo(bag, slot)
        count = type(info) == "table" and info.stackCount or nil
    end
    count = tonumber(count)
    if not count or count < 1 then return nil, "bad" end
    return itemID, count
end

-- Sum a set of containers into { [itemID] = count }. Returns nil if any
-- occupied slot is unreadable, so a mid-transition scan aborts instead of
-- recording garbage.
local function ScanContainerSet(ids)
    if not CGetNumSlots or not ids then return nil end
    local map = {}
    for _, bag in ipairs(ids) do
        local n = CGetNumSlots(bag)
        if n and n > 0 then
            for slot = 1, n do
                local id, count = ReadSlot(bag, slot)
                if id then
                    map[id] = (map[id] or 0) + count
                elseif count == "bad" then
                    return nil
                end
            end
        end
    end
    return map
end

local function mapsEqual(a, b)
    if a == b then return true end
    if not a or not b then return false end
    for k, v in pairs(a) do if b[k] ~= v then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

local function GetDB(guid)
    AltStableWarbandDB[guid] = AltStableWarbandDB[guid] or {}
    return AltStableWarbandDB[guid]
end

-- Commit a freshly-built section map for the current player, but only if it
-- actually changed — otherwise cosmetic BAG_UPDATEs would churn the sync.
local function ApplyScan(sectionKey, stampKey, newMap)
    if not newMap then return end
    local guid = UnitGUID("player")
    if not guid then return end
    local db = GetDB(guid)
    if mapsEqual(db[sectionKey], newMap) then return end

    db[sectionKey] = newMap
    db[stampKey]   = time()
    db.stamp       = math.max(db.bagsStamp or 0, db.bankStamp or 0)
    if AltStable.TouchCharacter then AltStable.TouchCharacter(guid) end
    if AT_WB.isActive and AT_WB.Refresh then AT_WB.Refresh() end
end

local function ScanBags()
    ApplyScan("bags", "bagsStamp", ScanContainerSet(CarriedBagIDs()))
end

-- Transactional bank scan. A genuinely emptied bank MUST be allowed to replace
-- a non-empty snapshot, so we never gate on "candidate is empty". The bank is
-- only readable while open, so we require isBankOpen; a scan whose bank session
-- ended before it ran is blocked at SCHEDULE time via the generation counter
-- (see ScheduleBank), not here — an in-flight synchronous scan can't have its
-- own generation change under it.
--
-- Readiness is now per tab: the purchased list is authoritative, so a character
-- who owns tabs whose slot counts have not arrived yet is not ready, while one
-- who owns none legitimately has an empty bank. (Which is why the old
-- MAIN_BANK slot-count gate is gone along with the constant.)
local function ScanBank()
    if not isBankOpen then return end
    local tabs = BankTabIDs()
    if not tabs then return end                   -- can't enumerate: not ready
    for _, bag in ipairs(tabs) do
        local n = CGetNumSlots and CGetNumSlots(bag)
        if not n or n <= 0 then return end        -- slots not ready yet
    end
    local candidate = ScanContainerSet(tabs)
    if not candidate then return end              -- malformed mid-transition: abort
    ApplyScan("bank", "bankStamp", candidate)
end

local function ScheduleBags()
    if bagsPending then return end
    bagsPending = true
    C_Timer.After(1, function() bagsPending = false; ScanBags() end)
end

-- Debounced, and tied to the CURRENT bank session: a scan is dropped when the
-- bank closed before it fired, but a close-then-reopen inside the window must
-- not lose the new session's scan. So a pending timer is re-pointed at the
-- newest generation rather than the request being dropped.
local pendingBankGen
local function ScheduleBank()
    pendingBankGen = bankGen
    if bankPending then return end
    bankPending = true
    C_Timer.After(1, function()
        bankPending = false
        if pendingBankGen == bankGen and isBankOpen then ScanBank() end
    end)
end

------------------------------------------------------------
-- Event routing
------------------------------------------------------------

local function OnBagUpdate(bag)
    bag = tonumber(bag)
    if bag and IsBankContainer(bag) then
        if isBankOpen then ScheduleBank() end   -- bank-tab change while open
        return
    end
    ScheduleBags()   -- carried bags / keyring (or a nil/unspecified bag)
end

local function OnBankOpened()
    isBankOpen = true
    InvalidateTabCache()   -- a tab may have been bought since the last session
    bankGen = bankGen + 1
    ScanBank()          -- immediate...
    ScheduleBank()      -- ...plus a follow-up in case slot counts aren't ready yet
end

-- A tab bought without closing the bank: its BAG_UPDATE would be classified as
-- a carried bag (the cached list predates it) and ScanBank would keep reading
-- the old tabs. BANK_TABS_CHANGED carries the bank type, so only ours counts.
local function OnBankTabsChanged(bankType)
    if Enum and Enum.BankType and bankType ~= nil and bankType ~= Enum.BankType.Character then
        return
    end
    InvalidateTabCache()
    if isBankOpen then ScanBank(); ScheduleBank() end
end

local function OnBankClosed()
    isBankOpen = false
    InvalidateTabCache()
    bankGen = bankGen + 1   -- invalidate any in-flight scheduled scan
end

------------------------------------------------------------
-- Sync — compact, single-line, no "\n". Only itemID+count integers ride the
-- wire (item links are reconstructed client-side, like the core gear scan).
--   v1|s=<stamp>|kt=<bankStamp>|b=id,count;id,count|k=id,count;...
------------------------------------------------------------

local function EncodeMap(map)
    local ids = {}
    for id in pairs(map or {}) do ids[#ids + 1] = id end
    table.sort(ids)   -- deterministic output for tests/diffs/compression
    local parts = {}
    for _, id in ipairs(ids) do parts[#parts + 1] = id .. "," .. map[id] end
    return table.concat(parts, ";")
end

-- Parse "id,count;id,count" into { [id]=count }. Returns nil on any malformed
-- entry so a corrupt blob cannot half-replace good data.
local function ParseMap(s)
    local map = {}
    if not s or s == "" then return map end
    for pair in s:gmatch("([^;]+)") do
        local id, count = pair:match("^(%d+),(%d+)$")
        id, count = tonumber(id), tonumber(count)
        if not id or not count or id < 1 or count < 1 then return nil end
        map[id] = count
    end
    return map
end

local function SerializePlayer(guid, sinceTS)
    local db = AltStableWarbandDB[guid]
    if not db then return "" end
    local stamp = db.stamp or 0
    -- Strict "<": the core delta includes a char at lastUpdate >= sinceTS
    -- (resend-on-equality is idempotent), so skipping at equality would drop a
    -- same-second change permanently once the watermark reaches it.
    if sinceTS and sinceTS > 0 and stamp < sinceTS then return "" end
    return BLOB_VERSION
        .. "|s=" .. stamp
        .. "|kt=" .. (db.bankStamp or 0)
        .. "|b=" .. EncodeMap(db.bags)
        .. "|k=" .. EncodeMap(db.bank)
end

local function DeserializePlayer(guid, blob)
    if not guid or not blob or blob == "" then return end
    local ver, rest = blob:match("^(v%d+)|(.+)$")
    if ver ~= BLOB_VERSION then return end   -- unknown version: ignore, don't wipe

    local incomingStamp = tonumber(rest:match("s=(%d+)"))
    if not incomingStamp then return end
    -- Stale-reject: never let an older relayed record roll back fresher local
    -- inventory. Equality is NOT stale, though: stamps come from time(), so two
    -- item moves in the same second produce different maps under one stamp, and
    -- the core deliberately re-sends records at the watermark. So a same-stamp
    -- blob is applied when its contents actually differ (idempotent when they
    -- don't), and only an older one is refused.
    local existing = AltStableWarbandDB[guid]
    if existing and (existing.stamp or 0) > incomingStamp then return end

    -- The fields must be PRESENT, not merely parseable: ParseMap(nil) is an
    -- empty map, so a truncated blob would silently blank the peer's inventory.
    local bagsStr, bankStr = rest:match("b=([^|]*)"), rest:match("k=([^|]*)")
    if not bagsStr or not bankStr then return end
    local bags, bank = ParseMap(bagsStr), ParseMap(bankStr)
    if not bags or not bank then return end   -- malformed: keep existing good data

    local bankStamp = tonumber(rest:match("kt=(%d+)")) or incomingStamp

    -- Nothing new: a full response re-sends every character, and the sheet is
    -- redrawn per character while the panel is open - each redraw rebuilds the
    -- whole aggregate, its buckets and its rows. Compare what we would store,
    -- not just the stamp, so an unchanged record costs nothing.
    if existing and (existing.stamp or 0) == incomingStamp
       and (existing.bankStamp or 0) == bankStamp
       and mapsEqual(existing.bags, bags) and mapsEqual(existing.bank, bank) then
        return
    end

    local db = GetDB(guid)
    db.bags = bags
    db.bank = bank
    db.stamp = incomingStamp
    db.bagsStamp = incomingStamp
    db.bankStamp = bankStamp
    if AT_WB.isActive and AT_WB.Refresh then AT_WB.Refresh() end
end

------------------------------------------------------------
-- Read model for the grid: merge every character's bags+bank by itemID.
--   agg[itemID] = { total, holders = { {name,class,realm,bags,bank,bankStamp} } }
------------------------------------------------------------

-- The core's /alts cleanup wipes AltStableDB down to this character and resets
-- the peer watermarks so everything is re-pulled in full. Our records are keyed
-- by the same guids, and the stale-reject guard below would refuse the re-pull
-- (the peers' stamps have not moved), so they have to go at the same time.
-- Orphans are dropped too: a guid no peer still has is invisible in the UI but
-- would sit in SavedVariables forever.
local function CleanupWarbandDB(keepGuid)
    for guid in pairs(AltStableWarbandDB) do
        if guid ~= keepGuid then AltStableWarbandDB[guid] = nil end
    end
end

local function PruneOrphans()
    for guid in pairs(AltStableWarbandDB) do
        local c = AltStableDB and AltStableDB[guid]
        if type(c) ~= "table" or not c.name then AltStableWarbandDB[guid] = nil end
    end
end

-- filter (optional, #153):
--   only       = guid    one character (Personal), hidden or not
--   ruleset    = "PvP"   characters whose realm is on that ruleset
--   skipHidden = true    leave hidden characters out, as the sheet's totals do
-- No filter is every character - the tooltips' and the tests' view.
local function Included(guid, c, filter)
    if not filter then return true end
    if filter.personal or filter.only then return filter.only ~= nil and guid == filter.only end
    if filter.skipHidden and AltStable.IsCharacterHidden and AltStable.IsCharacterHidden(guid) then
        return false
    end
    if filter.ruleset and AltStableWarbandModel.RulesetOf(c.realm) ~= filter.ruleset then
        return false
    end
    return true
end

local function gather(filter)
    AltStableDB = AltStableDB or {}
    local agg = {}
    for guid, c in pairs(AltStableDB) do
        if type(c) == "table" and c.name and Included(guid, c, filter) then
            local wb = AltStableWarbandDB[guid]
            if type(wb) == "table" then
                local per = {}
                if wb.bags then
                    for id, n in pairs(wb.bags) do per[id] = { bags = n, bank = 0 } end
                end
                if wb.bank then
                    for id, n in pairs(wb.bank) do
                        per[id] = per[id] or { bags = 0, bank = 0 }
                        per[id].bank = n
                    end
                end
                for id, v in pairs(per) do
                    local a = agg[id]
                    if not a then a = { total = 0, holders = {} }; agg[id] = a end
                    a.total = a.total + v.bags + v.bank
                    a.holders[#a.holders + 1] = {
                        name = c.name, class = c.class, realm = c.realm,
                        bags = v.bags, bank = v.bank, bankStamp = wb.bankStamp,
                    }
                end
            end
        end
    end
    return agg
end

------------------------------------------------------------
-- Display (#153) - a retail Warband Bank, read-only. User tabs on a rail at
-- the right; one tab at a time (Single) or three side by side (Combined); the
-- logged-in character (Personal) or everyone on a ruleset (Warband). The model
-- - categories, rulesets, which tabs claim what, which are on screen - is in
-- WarbandTabs.lua; this is frames.
--
-- Cells stay DIRECT children of the panel and scrolling stays virtual: a real
-- ScrollFrame swallowed the cells' hover. Combined shares one row offset over
-- its columns, ranged by the longest.
------------------------------------------------------------

local M = AltStableWarbandModel

local PAD       = 12
local ICON      = 34
local STRIDE    = 40     -- icon + gutter
local HEAD_H    = 70     -- title row + the controls row
local TABTITLE_H = 28    -- a tab's name above its grid
local FOOT_H    = 34     -- Personal / Warband and the status line
local RAIL_W    = 58     -- the tab bar at the right
local RAIL_BTN  = 40
local SCROLL_W  = 14
local COL_GAP   = 18     -- between Combined's columns
local ROW_TOP   = HEAD_H + TABTITLE_H   -- first grid row, from the panel's top
local ARROW_W   = 26    -- Combined's paging arrows get their own margin
-- The room the tab asks the window for: the toolbar's controls side by side
-- (~640) plus the rail, and the Configure dialog's height. Inherited from a
-- narrow or short section, the ruleset control ran off the window and the
-- dialog's last icon rows past its own Save (Codex review of #154).
local MIN_PANEL_W, MIN_PANEL_H = 720, 470

local panel, titleFS, emptyFS, searchBox, statusFS
AT_WB.scrollRow = 0
AT_WB.tabBtns, AT_WB.colHeads = {}, {}

local function fmtCount(n)
    if n >= 1000 then return string.format("%.1fk", n / 1000) end
    return tostring(n)
end

local GetItemInfo        = AltStable.API.GetItemInfo
local GetItemInfoInstant = AltStable.API.GetItemInfoInstant
local GetItemIconByID    = AltStable.API.GetItemIconByID

local function RequestMeta(id)
    if requestedIDs[id] then return end
    requestedIDs[id] = true
    if GetItemInfo then GetItemInfo(id) end   -- schedules the async cache load
end

local function DupName(holders, name)
    local c = 0
    for _, h in ipairs(holders) do if h.name == name then c = c + 1 end end
    return c > 1
end

local BAG_ICON  = "|TInterface\\Icons\\INV_Misc_Bag_08:12:12:0:0|t"
local BANK_ICON = "|TInterface\\Minimap\\Tracking\\Banker:13:13:0:0|t"

-- Inline class-icon texture escape for a tooltip line (empty if unknown).
local function ClassIconMarkup(class)
    local t = CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[class]
    if not t then return "" end
    return string.format(
        "|TInterface\\TargetingFrame\\UI-Classes-Circles:14:14:0:0:256:256:%d:%d:%d:%d|t ",
        math.floor(t[1] * 256), math.floor(t[2] * 256),
        math.floor(t[3] * 256), math.floor(t[4] * 256))
end

-- Sum one itemID across every tracked character's bags+bank (for the global
-- item-tooltip hook). Returns total + a holders list shaped like gather()'s.
-- Unfiltered on purpose: a tooltip on an item anywhere in the game answers
-- "who has this", whatever the Warband tab happens to be showing.
local function CountItem(itemID)
    local total, holders = 0, {}
    for guid, c in pairs(AltStableDB or {}) do
        if type(c) == "table" and c.name then
            local wb = AltStableWarbandDB[guid]
            if type(wb) == "table" then
                local bags = (wb.bags and wb.bags[itemID]) or 0
                local bank = (wb.bank and wb.bank[itemID]) or 0
                if bags + bank > 0 then
                    total = total + bags + bank
                    holders[#holders + 1] = {
                        name = c.name, class = c.class, realm = c.realm,
                        bags = bags, bank = bank, bankStamp = wb.bankStamp,
                    }
                end
            end
        end
    end
    return total, holders
end
AT_WB.CountItem = CountItem

-- The cross-alt breakdown block: "Total: N", then one line per character —
-- class icon + class-coloured name on the left, the per-location counts with
-- inline bag/bank icons on the right (e.g. "17[bag] +46[bank]").
local function AppendBreakdown(tt, total, holders)
    if not total or total <= 0 or not holders or #holders == 0 then return end
    tt:AddLine(" ")
    tt:AddDoubleLine("Total:", tostring(total), 1, 0.82, 0, 1, 1, 1)

    local list = {}
    for _, h in ipairs(holders) do list[#list + 1] = h end
    table.sort(list, function(a, b) return (a.name or "") < (b.name or "") end)

    local now, stale = time(), false
    for _, h in ipairs(list) do
        local cc = (h.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[h.class]) or { r = .9, g = .9, b = .9 }
        local nm = ClassIconMarkup(h.class) .. (h.name or "?")
        if h.realm and DupName(list, h.name) then nm = nm .. "-" .. h.realm end
        local parts = {}
        if (h.bags or 0) > 0 then parts[#parts + 1] = h.bags .. BAG_ICON end
        if (h.bank or 0) > 0 then
            parts[#parts + 1] = h.bank .. BANK_ICON
            if h.bankStamp and (now - h.bankStamp) > BANK_STALE then stale = true end
        end
        -- Bagnon-style right cell: single location shows just "N[icon]"; a split
        -- shows the per-character total then the breakdown, e.g. "63=17[bag]+46[bank]".
        local right = parts[1] or ""
        if #parts > 1 then
            right = ((h.bags or 0) + (h.bank or 0)) .. "=" .. table.concat(parts, "+")
        end
        tt:AddDoubleLine(nm, right, cc.r, cc.g, cc.b, 1, 1, 1)
    end
    if stale then tt:AddLine("Bank data may be out of date", .55, .55, .55) end
    tt:Show()
end

-- A tooltip re-renders itself from the item link when the async item info
-- arrives (and for uncached remote-alt items), wiping anything appended after
-- SetHyperlink — so the breakdown is appended from a post-call that re-fires on
-- every render. Installed once at bootstrap so it also enriches item tooltips
-- everywhere (bags, bank, merchant, links), gated by the warbandItemTooltips
-- setting. hoverEntry routes our own panel cells to their precomputed aggregate.
--
-- GameTooltip:HookScript("OnTooltipSetItem", ...) is gone on Forever: the script
-- type no longer exists and the call THROWS, which used to abort this plugin's
-- registration entirely (#10). TooltipDataProcessor is the replacement, and the
-- item id arrives in the data payload rather than through tt:GetItem().
-- AT_WB._ttHooked: true once installed, nil when this client has no
-- TooltipDataProcessor (CellOnEnter appends the breakdown itself then).
local function EnsureTooltipHook()
    if AT_WB._ttHooked then return end
    -- The post-call and the item lookup are the core's (Core.lua), shared with
    -- the Professions plugin. Without TooltipDataProcessor nothing is hooked;
    -- the panel still works.
    local hooked = AltStable.HookItemTooltip and AltStable.HookItemTooltip(function(tt, id)
        -- Our own panel cell, and only for the item it holds: comparison
        -- tooltips (Shift, or alwaysCompareItems) render the EQUIPPED items
        -- through this same post-call, and would otherwise be labelled with the
        -- hovered item's holders - bypassing the opt-in below as well.
        local e = AT_WB.hoverEntry
        if e and id == e.id then AppendBreakdown(tt, e.total, e.holders); return end
        if e then return end
        -- Global enrichment is opt-in (default off) so it doesn't double up with
        -- another inventory addon's counts. Enable it in the Warband tab.
        if not (AltStableConfig and AltStableConfig.warbandItemTooltips) then return end
        if id then
            local total, holders = CountItem(id)
            if total > 0 then AppendBreakdown(tt, total, holders) end
        end
    end)
    if hooked then AT_WB._ttHooked = true end
end

local function CellOnEnter(self)
    local e = self.entry
    if not e then return end      -- an empty slot
    AT_WB.hoverEntry = e
    AT_WB.hoverCell = self
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    -- SetHyperlink drives the item tooltip; OnTooltipSetItem then appends the
    -- breakdown. Guard it so a finicky bare-item string never aborts the hover.
    local ok = pcall(function() GameTooltip:SetHyperlink("item:" .. e.id) end)
    if ok and AT_WB._ttHooked == nil then
        -- No TooltipDataProcessor on this client, so nothing appends for us:
        -- add the breakdown here, where the grid's whole point lives.
        AppendBreakdown(GameTooltip, e.total, e.holders)
        return
    end
    if not ok or GameTooltip:NumLines() == 0 then
        -- Fallback: no item tooltip available (uncached, no data yet) — show a
        -- quality-coloured name header and the breakdown directly.
        GameTooltip:ClearLines()
        local r, g, b = 1, 1, 1
        local qc = e.quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[e.quality]
        if qc then r, g, b = qc.r, qc.g, qc.b end
        GameTooltip:AddLine(e.name or ("Item " .. e.id), r, g, b)
        AppendBreakdown(GameTooltip, e.total, e.holders)
    end
end

local function CellOnLeave()
    AT_WB.hoverEntry, AT_WB.hoverCell = nil, nil
    GameTooltip:Hide()
end

local function ClearHover()
    if AT_WB.hoverEntry then
        AT_WB.hoverEntry, AT_WB.hoverCell = nil, nil
        if GameTooltip and GameTooltip.Hide then GameTooltip:Hide() end
    end
end

-- After a layout: the tooltip stays while the cell under the mouse still holds
-- the same item (its entry refreshed), and goes the moment it holds another or
-- nothing. Clearing unconditionally closed it under a resting mouse on every
-- refresh - item info arriving 0.2 s after the hover, a bag update, a sync
-- (review of #154).
local function ReconcileHover()
    local e, cell = AT_WB.hoverEntry, AT_WB.hoverCell
    if not e then return end
    local now = cell and cell:IsShown() and cell.entry
    if now and now.id == e.id then
        AT_WB.hoverEntry = now
    else
        ClearHover()
    end
end

-- Shown only when there is something to scroll to, and kept in step with the
-- wheel. _syncing stops the value we set here from re-entering Layout.
function AT_WB.UpdateScrollBar(maxStart, start)
    local scrollBar = AT_WB.scrollBar
    if not scrollBar then return end
    if (maxStart or 0) <= 0 then scrollBar:Hide(); return end
    scrollBar._syncing = true
    scrollBar:SetMinMaxValues(0, maxStart)
    scrollBar:SetValue(start or 0)
    scrollBar._syncing = false
    scrollBar:Show()
end

local function hideFrom(pool, from)
    for k = from, #pool do if pool[k] then pool[k]:Hide() end end
end

-- How much of the grid fits, and where the window starts. Whole rows only:
-- cells are laid out on a fixed stride, so a partial row at the bottom would be
-- a clipped row rather than a scrolled one. The grid sits between the tab
-- titles and the Personal/Warband bar. Returns visible rows, the highest
-- first-row index, and the requested start clamped into range.
local function ScrollBounds(rowCount, panelHeight, requested)
    local ph = (panelHeight and panelHeight >= 50) and panelHeight or 400
    local visible = math.max(1, math.floor((ph - ROW_TOP - FOOT_H - PAD) / STRIDE))
    local maxStart = math.max(0, (rowCount or 0) - visible)
    local start = math.max(0, math.min(requested or 0, maxStart))
    return visible, maxStart, start
end
AT_WB.ScrollBounds = ScrollBounds

local function getCell(i)
    local cell = AT_WB.cells[i]
    if not cell then
        cell = CreateFrame("Button", nil, panel, "BackdropTemplate")
        cell:SetSize(ICON, ICON)
        cell:EnableMouse(true)
        cell:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
        cell.icon = cell:CreateTexture(nil, "ARTWORK")
        cell.icon:SetPoint("TOPLEFT", 1, -1)
        cell.icon:SetPoint("BOTTOMRIGHT", -1, 1)
        cell.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        cell.count = cell:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
        cell.count:SetPoint("BOTTOMRIGHT", -1, 1)
        cell:SetScript("OnEnter", CellOnEnter)
        cell:SetScript("OnLeave", CellOnLeave)
        AT_WB.cells[i] = cell
    end
    return cell
end

-- One cell, holding an item or (entry nil) an empty slot. An empty slot clears
-- everything an item left on it: the hover, the count and the search name.
local function FillCell(cell, e)
    cell.entry = e
    if e then
        cell.icon:SetTexture(e.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
        cell.icon:SetDesaturated(false)
        cell.count:SetText(e.total > 1 and fmtCount(e.total) or "")
        local qc = e.quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[e.quality]
        if qc then cell:SetBackdropBorderColor(qc.r, qc.g, qc.b, 1)
        else cell:SetBackdropBorderColor(0.3, 0.3, 0.3, 1) end
        cell.itemName = e.name
        cell:SetAlpha(1)
    else
        -- A quiet box, not slot art: these are filters, not storage, and the
        -- textured slots outweighed the items (review, 2026-10-03).
        cell.icon:SetTexture(nil)
        cell.count:SetText("")
        cell:SetBackdropBorderColor(1, 1, 1, 0.07)
        cell.itemName = nil
        cell:SetAlpha(1)        -- faint by its border, not its alpha
    end
end

------------------------------------------------------------
-- The read model, filtered
------------------------------------------------------------

local function Cfg(key, default)
    local v = AltStableConfig and AltStableConfig[key]
    if v == nil then return default end
    return v
end

-- Tabs from config, seeded with the defaults the first time - for an existing
-- profile as well as a new one - and never overwritten once there.
local function Tabs()
    local tabs = AltStableConfig and AltStableConfig.warbandTabs
    if type(tabs) ~= "table" or #tabs == 0 then
        tabs = M.DefaultTabs()
        AltStable.SetConfigValue("warbandTabs", tabs)
    end
    return tabs
end

local function Scope() return Cfg("warbandScope", "warband") end
local function View() return Cfg("warbandView", "single") end

-- Who the grid is about: Personal is the logged-in character alone, ruleset
-- ignored, hidden or not; Warband is every character not hidden (the sheet's
-- totals leave hidden ones out too) on the chosen ruleset.
local function CurrentFilter()
    if Scope() == "personal" then
        -- `personal` is the flag, not the GUID: with no GUID yet this shows
        -- nobody, never everybody (review of #154).
        return { personal = true, only = UnitGUID and UnitGUID("player") }
    end
    return {
        ruleset = M.ResolveRuleset(Cfg("warbandRuleset", "current"), GetRealmName and GetRealmName()),
        skipHidden = true,
    }
end

-- Every unique item, resolved to what the view needs. An item whose metadata
-- has not arrived sits in misc until GET_ITEM_INFO_RECEIVED refreshes it.
local function BuildEntries(agg)
    local list = {}
    for id, a in pairs(agg) do
        local icon, classID
        if GetItemInfoInstant then
            local _, _, _, _, ic, cid = GetItemInfoInstant(id)
            icon, classID = ic, cid
        end
        local name, _, quality = nil, nil, nil
        if GetItemInfo then name, _, quality = GetItemInfo(id) end
        if not name then RequestMeta(id) end
        if not icon and GetItemIconByID then icon = GetItemIconByID(id) end
        list[#list + 1] = {
            id = id, total = a.total, holders = a.holders, icon = icon, name = name,
            quality = quality, classID = classID, cat = M.CategoryOf(classID),
        }
    end
    -- Grouped by kind inside a tab, then best first, then by name.
    table.sort(list, function(x, y)
        local cx, cy = x.classID or 99, y.classID or 99
        if cx ~= cy then return cx < cy end
        local qx, qy = x.quality or -1, y.quality or -1
        if qx ~= qy then return qx > qy end
        return (x.name or ("zzz" .. x.id)) < (y.name or ("zzz" .. y.id))
    end)
    return list
end

local RULESET_LABEL = {
    current = "Current ruleset", all = "All rulesets",
    Normal = "Normal", PvP = "PvP", RP = "RP", Hardcore = "Hardcore",
}

local function RulesetText(setting)
    setting = setting or Cfg("warbandRuleset", "current")
    if setting == "current" then
        return "Current ruleset (" .. M.RulesetOf(GetRealmName and GetRealmName()) .. ")"
    end
    return RULESET_LABEL[setting] or tostring(setting)
end

------------------------------------------------------------
-- Small glass widgets
------------------------------------------------------------

local function Accent()
    if AltStable.GetAccentRGB then return AltStable.GetAccentRGB() end
    return 1, 0.82, 0
end

local function StyleButton(btn, active)
    local r, g, b = Accent()
    local glass = AltStable.SkinIsGlass and AltStable.SkinIsGlass()
    if active then
        btn:SetBackdropColor(r, g, b, glass and 0.18 or 0.25)
        btn:SetBackdropBorderColor(r, g, b, 1)
        if btn.label then btn.label:SetTextColor(r, g, b) end
    else
        if glass then
            btn:SetBackdropColor(1, 1, 1, btn._hover and 0.10 or 0.04)
            btn:SetBackdropBorderColor(1, 1, 1, 0.18)
        else
            -- The flat skin's own button fills (Theme.lua), not glass tints.
            local c = btn._hover and AltStable.C.BG_BTN_HOVER or AltStable.C.BG_BTN_ACTIVE
            btn:SetBackdropColor(c[1], c[2], c[3], c[4])
            btn:SetBackdropBorderColor(0, 0, 0, 1)
        end
        if btn.label then btn.label:SetTextColor(unpack(AltStable.C.TEXT_NORM)) end
    end
end

local function MakeButton(parent, w, h, text, onClick)
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    btn:SetSize(w, h)
    btn:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    btn.label = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    btn.label:SetPoint("CENTER")
    btn.label:SetText(text or "")
    if AltStable.SkinText then AltStable.SkinText(btn.label) end
    btn:SetScript("OnEnter", function(self) self._hover = true; StyleButton(self, self._active) end)
    btn:SetScript("OnLeave", function(self) self._hover = false; StyleButton(self, self._active) end)
    if onClick then btn:SetScript("OnClick", onClick) end
    StyleButton(btn, false)
    return btn
end

local function SetActive(btn, on)
    btn._active = on and true or false
    StyleButton(btn, btn._active)
end

-- Closes on a click anywhere else in the panel, and on Escape.
local function MakeCatcher(owner, onClose, dim)
    local c = CreateFrame("Button", nil, panel)
    c:SetAllPoints(panel)
    c:SetFrameStrata("FULLSCREEN_DIALOG")
    c:RegisterForClicks("AnyUp")
    c:SetScript("OnClick", onClose)
    if dim then
        -- The bank behind a dialog is dimmed, so it stops competing with it.
        local t = c:CreateTexture(nil, "BACKGROUND")
        t:SetAllPoints()
        t:SetColorTexture(0, 0, 0, dim)
        c.dim = t
    end
    c:Hide()
    return c
end

-- Escape closes it and is swallowed; every other key goes on to the game, so
-- an open menu never eats movement.
--
-- SetPropagateKeyboardInput is restricted in combat (HasRestrictions in the
-- API docs), so this follows CharacterMenu.lua exactly (review of #154): the
-- call is pcall'd and a failure RELEASES the keyboard - a caught error leaves
-- propagation where the last Escape put it, false, and W would be swallowed;
-- the keyboard is not grabbed in combat at all; and combat starting with the
-- frame open releases it before the first key.
local function CloseOnEscape(f, onClose)
    f:SetScript("OnKeyDown", function(self, key)
        local stop = (key == "ESCAPE")
        local handed = true
        if type(self.SetPropagateKeyboardInput) == "function" then
            handed = pcall(self.SetPropagateKeyboardInput, self, not stop)
        end
        if not handed and type(self.EnableKeyboard) == "function" then
            pcall(self.EnableKeyboard, self, false)
        end
        if stop then onClose() end
    end)
    f:RegisterEvent("PLAYER_REGEN_DISABLED")
    f:SetScript("OnEvent", function(self)
        if type(self.EnableKeyboard) == "function" then pcall(self.EnableKeyboard, self, false) end
    end)
end

-- On opening: take the keyboard only out of combat, and reset propagation, which
-- outlives the frame and was left false by the last Escape.
local function GrabKeyboard(f)
    if type(f.EnableKeyboard) ~= "function" then return end
    if InCombatLockdown and InCombatLockdown() then
        pcall(f.EnableKeyboard, f, false)
        return
    end
    f:EnableKeyboard(true)
    if type(f.SetPropagateKeyboardInput) == "function" then
        pcall(f.SetPropagateKeyboardInput, f, true)
    end
end

------------------------------------------------------------
-- The ruleset menu
------------------------------------------------------------

local rulesetBtn, rulesetMenu, rulesetCatcher

local function CloseRulesetMenu()
    if rulesetMenu then rulesetMenu:Hide() end
    if rulesetCatcher then rulesetCatcher:Hide() end
end

local function OpenRulesetMenu()
    if Scope() == "personal" then return end
    if not rulesetMenu then
        rulesetCatcher = MakeCatcher(panel, CloseRulesetMenu)
        rulesetMenu = CreateFrame("Frame", nil, panel, "BackdropTemplate")
        rulesetMenu:SetFrameStrata("FULLSCREEN_DIALOG")
        rulesetMenu:SetFrameLevel(rulesetCatcher:GetFrameLevel() + 5)
        if not (AltStable.SkinWindow and AltStable.SkinWindow(rulesetMenu, "small")) then
            AltStable.ApplyBackdrop(rulesetMenu, 0.08, 0.08, 0.1, 0.97)
        end
        CloseOnEscape(rulesetMenu, CloseRulesetMenu)
        rulesetMenu.rows = {}
        local keys = { "current", "all", "Normal", "PvP", "RP", "Hardcore" }
        for i, key in ipairs(keys) do
            local row = MakeButton(rulesetMenu, 180, 22, "", function()
                CloseRulesetMenu()
                AltStable.SetConfigValue("warbandRuleset", key)
                AT_WB.scrollRow = 0
                AT_WB.Refresh()
            end)
            row:SetPoint("TOPLEFT", rulesetMenu, "TOPLEFT", 8, -8 - (i - 1) * 24)
            row.key = key
            rulesetMenu.rows[i] = row
        end
        rulesetMenu:SetSize(196, 16 + #keys * 24)
    end
    local current = Cfg("warbandRuleset", "current")
    for _, row in ipairs(rulesetMenu.rows) do
        row.label:SetText(row.key == "current" and RulesetText("current") or RULESET_LABEL[row.key])
        SetActive(row, row.key == current)
    end
    rulesetMenu:ClearAllPoints()
    rulesetMenu:SetPoint("TOPLEFT", rulesetBtn, "BOTTOMLEFT", 0, -2)
    rulesetCatcher:Show()
    rulesetMenu:Show()
    GrabKeyboard(rulesetMenu)
end

------------------------------------------------------------
-- Configure Tab
------------------------------------------------------------

local dialog, dialogCatcher
local ICON_COLS, ICON_ROWS, ICON_SIZE = 10, 4, 34
local iconList                       -- deduplicated, built once on first open

-- The client's icon lists can run to thousands of entries: read once, kept,
-- and only ICON_COLS x ICON_ROWS cells ever exist.
local function IconList()
    if iconList then return iconList end
    iconList = {}
    local seen = {}
    local function add(v)
        if v and not seen[v] then seen[v] = true; iconList[#iconList + 1] = v end
    end
    for _, t in ipairs(M.DefaultTabs()) do add(t.icon) end
    -- By name: `ipairs({ GetMacroItemIcons, GetMacroIcons })` stops at the first
    -- nil, so a client without the first list would silently lose the second.
    for _, fname in ipairs({ "GetMacroItemIcons", "GetMacroIcons" }) do
        local fn = _G[fname]
        if type(fn) == "function" then
            local out = {}
            local ok, r = pcall(fn, out)
            local src = (ok and type(r) == "table") and r or out
            for _, v in ipairs(src) do add(v) end
        end
    end
    return iconList
end
AT_WB.IconList = IconList
AT_WB.ResetIconList = function() iconList = nil end   -- tests: a different client list

-- Icon rows that fit a dialog of height h: the grid starts GRID_TOP down and
-- must end above the buttons' strip.
local GRID_TOP, BUTTON_STRIP = 224, 46
local function DialogIconRows(h)
    local rows = math.floor((h - BUTTON_STRIP - GRID_TOP - ICON_SIZE) / (ICON_SIZE + 4)) + 1
    return math.max(1, math.min(ICON_ROWS, rows))
end
AT_WB.DialogIconRows = DialogIconRows

local function CloseDialog()
    if dialog then dialog:Hide(); dialog.draft = nil end
    if dialogCatcher then dialogCatcher:Hide() end
end

local function RenderIconGrid()
    local list = IconList()
    local rows = dialog.visRows or ICON_ROWS
    local total = math.ceil(#list / ICON_COLS)
    local maxStart = math.max(0, total - rows)
    dialog.iconRow = math.max(0, math.min(dialog.iconRow or 0, maxStart))
    if dialog.iconBar then
        dialog.iconBar._syncing = true
        dialog.iconBar:SetMinMaxValues(0, maxStart)
        dialog.iconBar:SetValue(dialog.iconRow)
        dialog.iconBar._syncing = false
        dialog.iconBar:SetShown(maxStart > 0)
    end
    if dialog.iconCount then dialog.iconCount:SetText(#list .. " icons - scroll for more") end
    if dialog.iconBar then
        dialog.iconBar:ClearAllPoints()
        dialog.iconBar:SetPoint("TOPLEFT", dialog.iconCells[ICON_COLS], "TOPRIGHT", 6, 0)
        dialog.iconBar:SetPoint("BOTTOMLEFT", dialog.iconCells[rows * ICON_COLS], "BOTTOMRIGHT", 6, 0)
    end
    for r = 0, ICON_ROWS - 1 do
        for c = 1, ICON_COLS do
            local cell = dialog.iconCells[r * ICON_COLS + c]
            local v = (r < rows) and list[(dialog.iconRow + r) * ICON_COLS + c] or nil
            cell.value = v
            if v then
                cell.icon:SetTexture(v)
                local picked = dialog.draft and dialog.draft.icon == v
                local ar, ag, ab = Accent()
                if picked then cell:SetBackdropBorderColor(ar, ag, ab, 1)
                else cell:SetBackdropBorderColor(0.25, 0.25, 0.28, 1) end
                cell:Show()
            else
                cell:Hide()
            end
        end
    end
end

local function SaveDialog()
    local d = dialog.draft
    if not d then return end
    local name = (dialog.nameBox:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local tabs = M.CopyTabs(Tabs())
    local index = dialog.index
    if name == "" then name = "Tab " .. (index or (#tabs + 1)) end
    d.name = name
    if index then
        tabs[index] = d
    else
        -- The cap is enforced where a new tab is started (OpenDialog).
        tabs[#tabs + 1] = d
        index = #tabs
    end
    AltStable.SetConfigValue("warbandTabs", tabs)
    AltStable.SetConfigValue("warbandTab", index)
    CloseDialog()
    AT_WB.scrollRow = 0
    AT_WB.Refresh()        -- SetConfigValue does not refresh anything itself
end

local function DeleteFromDialog()
    local index = dialog.index
    local tabs = M.CopyTabs(Tabs())
    if not index or #tabs <= 1 then return end
    table.remove(tabs, index)
    AltStable.SetConfigValue("warbandTabs", tabs)
    AltStable.SetConfigValue("warbandTab", M.AfterDelete(Cfg("warbandTab", 1), index, #tabs) or 1)
    CloseDialog()
    AT_WB.scrollRow = 0
    AT_WB.Refresh()
end

local function BuildDialog()
    dialogCatcher = MakeCatcher(panel, CloseDialog, 0.55)
    dialog = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    dialog:SetFrameStrata("FULLSCREEN_DIALOG")
    dialog:SetFrameLevel(dialogCatcher:GetFrameLevel() + 5)
    dialog:SetSize(ICON_COLS * (ICON_SIZE + 4) + 40, 420)
    dialog:SetPoint("CENTER", panel, "CENTER", -RAIL_W / 2, 0)
    dialog:EnableMouse(true)
    if not (AltStable.SkinWindow and AltStable.SkinWindow(dialog, "small")) then
        AltStable.ApplyBackdrop(dialog, 0.08, 0.08, 0.1, 0.98)
    end
    -- Glass around the edge, a dark near-opaque body: through the glass alone,
    -- item icons and titles showed straight through the labels (review).
    local body = dialog:CreateTexture(nil, "BACKGROUND", nil, 1)
    body:SetPoint("TOPLEFT", 6, -6)
    body:SetPoint("BOTTOMRIGHT", -6, 6)
    body:SetColorTexture(0.06, 0.065, 0.08, 0.94)
    CloseOnEscape(dialog, CloseDialog)

    -- An upper-right close, as well as Cancel and Escape.
    local close = MakeButton(dialog, 22, 22, "x", CloseDialog)
    close:SetPoint("TOPRIGHT", -12, -12)

    local title = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 18, -14)
    title:SetText("Configure Tab")

    dialog.preview = dialog:CreateTexture(nil, "ARTWORK")
    dialog.preview:SetSize(44, 44)
    dialog.preview:SetPoint("TOPLEFT", 18, -44)
    dialog.preview:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    local nameLbl = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nameLbl:SetPoint("TOPLEFT", dialog.preview, "TOPRIGHT", 12, 0)
    nameLbl:SetText("Tab Name")
    local box = CreateFrame("EditBox", nil, dialog, "InputBoxTemplate")
    box:SetSize(230, 22)
    box:SetPoint("TOPLEFT", nameLbl, "BOTTOMLEFT", 4, -4)
    box:SetAutoFocus(false)
    box:SetMaxLetters(32)
    box:SetScript("OnEscapePressed", function() CloseDialog() end)
    box:SetScript("OnEnterPressed", function() SaveDialog() end)
    dialog.nameBox = box
    local note = dialog:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    note:SetPoint("TOPLEFT", box, "BOTTOMLEFT", -4, -2)
    note:SetText("Display filters only - nothing is moved.")

    local catLbl = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    catLbl:SetPoint("TOPLEFT", 18, -108)
    catLbl:SetText("Item Categories")
    dialog.checks = {}
    for i, cat in ipairs(M.CATEGORIES) do
        local cb = CreateFrame("CheckButton", nil, dialog, "UICheckButtonTemplate")
        cb:SetSize(20, 20)
        local col, row = (i - 1) % 2, math.floor((i - 1) / 2)
        cb:SetPoint("TOPLEFT", 16 + col * 180, -126 - row * 24)
        local lbl = dialog:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        lbl:SetPoint("LEFT", cb, "RIGHT", 2, 0)
        lbl:SetText(M.CATEGORY_LABEL[cat])
        cb:SetScript("OnClick", function(self)
            if dialog.draft then dialog.draft.cats[cat] = self:GetChecked() and true or nil end
        end)
        cb.cat = cat
        dialog.checks[i] = cb
    end

    local iconLbl = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    iconLbl:SetPoint("TOPLEFT", 18, -206)
    iconLbl:SetText("Choose an Icon")
    dialog.iconCells = {}
    for r = 0, ICON_ROWS - 1 do
        for c = 1, ICON_COLS do
            local cell = CreateFrame("Button", nil, dialog, "BackdropTemplate")
            cell:SetSize(ICON_SIZE, ICON_SIZE)
            cell:SetPoint("TOPLEFT", 18 + (c - 1) * (ICON_SIZE + 4), -GRID_TOP - r * (ICON_SIZE + 4))
            cell:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
            cell.icon = cell:CreateTexture(nil, "ARTWORK")
            cell.icon:SetPoint("TOPLEFT", 1, -1)
            cell.icon:SetPoint("BOTTOMRIGHT", -1, 1)
            cell.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
            cell:SetScript("OnClick", function(self)
                if dialog.draft and self.value then
                    dialog.draft.icon = self.value
                    dialog.preview:SetTexture(self.value)
                    RenderIconGrid()
                end
            end)
            dialog.iconCells[r * ICON_COLS + c] = cell
        end
    end
    dialog:EnableMouseWheel(true)
    dialog:SetScript("OnMouseWheel", function(_, delta)
        dialog.iconRow = (dialog.iconRow or 0) - delta * 2
        RenderIconGrid()
    end)
    -- A scrollbar and a count: the lists run to thousands, and they are bare
    -- file ids with no names, so there is nothing a search box could match.
    local bar = CreateFrame("Slider", nil, dialog)
    bar:SetWidth(8)
    bar:SetPoint("TOPLEFT", dialog.iconCells[ICON_COLS], "TOPRIGHT", 6, 0)
    bar:SetPoint("BOTTOMLEFT", dialog.iconCells[ICON_ROWS * ICON_COLS], "BOTTOMRIGHT", 6, 0)
    bar:SetOrientation("VERTICAL")
    bar:SetValueStep(1)
    local track = bar:CreateTexture(nil, "BACKGROUND")
    track:SetAllPoints(); track:SetColorTexture(1, 1, 1, 0.06)
    local thumb = bar:CreateTexture(nil, "OVERLAY")
    thumb:SetColorTexture(1, 1, 1, 0.3); thumb:SetSize(8, 24)
    bar:SetThumbTexture(thumb)
    bar:SetScript("OnValueChanged", function(self, v)
        if self._syncing then return end
        dialog.iconRow = math.floor((v or 0) + 0.5)
        RenderIconGrid()
    end)
    dialog.iconBar = bar
    dialog.iconCount = dialog:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    dialog.iconCount:SetPoint("LEFT", iconLbl, "RIGHT", 10, 0)

    dialog.save = MakeButton(dialog, 90, 24, "Save", SaveDialog)
    dialog.save:SetPoint("BOTTOMRIGHT", -16, 14)
    SetActive(dialog.save, true)             -- the primary action, in gold
    dialog.save:SetScript("OnLeave", function(self) self._hover = false; StyleButton(self, true) end)
    dialog.cancel = MakeButton(dialog, 90, 24, "Cancel", CloseDialog)
    dialog.cancel:SetPoint("RIGHT", dialog.save, "LEFT", -8, 0)
    dialog.delete = MakeButton(dialog, 100, 24, "Delete Tab", DeleteFromDialog)
    dialog.delete:SetPoint("BOTTOMLEFT", 16, 14)
    dialog:Hide()
end

-- index nil = a new tab: nothing is inserted until Save.
local function OpenDialog(index)
    if not dialog then BuildDialog() end
    CloseRulesetMenu()
    local tabs = Tabs()
    if not index and #tabs >= M.MAX_TABS then return end
    dialog.index = index
    dialog.draft = index and M.CopyTab(tabs[index])
        or { name = "", icon = M.DefaultTabs()[1].icon, cats = {} }
    dialog.nameBox:SetText(dialog.draft.name or "")
    dialog.preview:SetTexture(dialog.draft.icon)
    for _, cb in ipairs(dialog.checks) do cb:SetChecked(dialog.draft.cats[cb.cat] and true or false) end
    -- Never taller than the panel it sits on, and its content fits what it
    -- gets: as many icon rows as clear the buttons (the window is asked for
    -- room on activation; a display too small for that still must not put
    -- icons under Save - Codex review of #154). Sized
    -- BEFORE the grid is drawn, which reads visRows.
    local ph = panel:GetHeight()
    local h = 420
    if ph and ph > 100 then h = math.min(420, ph - 8) end
    dialog:SetHeight(h)
    dialog.visRows = DialogIconRows(h)
    dialog.iconRow = 0
    RenderIconGrid()
    -- Delete exists for a saved tab, and never for the last one.
    dialog.delete:SetShown(index ~= nil)
    dialog.delete:SetEnabled(index ~= nil and #tabs > 1)
    dialog.delete:SetAlpha((index ~= nil and #tabs > 1) and 1 or 0.4)
    dialogCatcher:Show()
    dialog:Show()
    GrabKeyboard(dialog)
end
AT_WB.OpenDialog = OpenDialog
AT_WB.SaveDialog = function() return SaveDialog() end
AT_WB.CloseDialog = CloseDialog
AT_WB.DeleteFromDialog = function() return DeleteFromDialog() end
AT_WB.Dialog = function() return dialog end
AT_WB.MIN_PANEL_W, AT_WB.MIN_PANEL_H = MIN_PANEL_W, MIN_PANEL_H

------------------------------------------------------------
-- Tab rail and column heads
------------------------------------------------------------

local function TabMeta(key, tabs)
    if key == "other" then return "Other", M.OTHER_ICON end
    local t = tabs[key]
    return (t and t.name) or ("Tab " .. tostring(key)), (t and t.icon) or M.OTHER_ICON
end

local function Select(key)
    AltStable.SetConfigValue("warbandTab", key)
    AT_WB.scrollRow = 0
    AT_WB.Refresh()
end

local function getTabBtn(i)
    local b = AT_WB.tabBtns[i]
    if b then return b end
    b = CreateFrame("Button", nil, panel, "BackdropTemplate")
    b:SetSize(RAIL_BTN, RAIL_BTN)
    b:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 2 })
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetPoint("TOPLEFT", 3, -3)
    b.icon:SetPoint("BOTTOMRIGHT", -3, 3)
    b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    b.plus = b:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    b.plus:SetPoint("CENTER", 0, 1)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:SetScript("OnClick", function(self, button)
        if self.isAdd then OpenDialog(nil); return end
        if button == "RightButton" then
            if type(self.key) == "number" then OpenDialog(self.key) end
            return
        end
        Select(self.key)
    end)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine(self.tip or "")
        if not self.isAdd then
            if self.shown then
                GameTooltip:AddLine(View() == "combined" and "Shown in the combined view" or "Shown", .6, .9, .6)
            else
                GameTooltip:AddLine("Click to show", .8, .8, .8)
            end
        end
        if type(self.key) == "number" then GameTooltip:AddLine("Right-click to configure", .7, .7, .7) end
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    AT_WB.tabBtns[i] = b
    return b
end

local function getColHead(i)
    local h = AT_WB.colHeads[i]
    if h then return h end
    h = CreateFrame("Frame", nil, panel)
    h:SetHeight(TABTITLE_H - 4)
    h.icon = h:CreateTexture(nil, "ARTWORK")
    h.icon:SetSize(20, 20)
    h.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    h.name = h:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    if AltStable.SkinText then AltStable.SkinText(h.name) end
    h.gear = CreateFrame("Button", nil, h)
    h.gear:SetSize(18, 18)
    h.gear.tex = h.gear:CreateTexture(nil, "ARTWORK")
    h.gear.tex:SetAllPoints()
    h.gear.tex:SetTexture("Interface\\Buttons\\UI-OptionsButton")
    h.gear:SetScript("OnClick", function(self) if type(self.key) == "number" then OpenDialog(self.key) end end)
    AT_WB.colHeads[i] = h
    return h
end

------------------------------------------------------------
-- Layout
------------------------------------------------------------

-- The grid area: everything between the header, the bar, the rail and the
-- scrollbar.
local function GridBox()
    local pw = panel:GetWidth()
    if not pw or pw < 200 then pw = 700 end
    local left = PAD
    local right = pw - RAIL_W - SCROLL_W - PAD
    -- Combined's arrows have a margin of their own at each end; drawn over the
    -- grid, they sat on the first tab's icon and the last one's gear (review).
    if AT_WB._paging then
        left = left + ARROW_W
        right = right - ARROW_W
    end
    return left, math.max(STRIDE, right - left)
end

-- Lay out only the visible window of rows, for one column (Single) or several
-- (Combined), offset by AT_WB.scrollRow.
function AT_WB.Layout()
    if not panel or not panel:IsShown() then return end
    local cols = AT_WB._cols or {}
    if #cols == 0 then
        ClearHover()
        hideFrom(AT_WB.cells, 1)
        hideFrom(AT_WB.colHeads, 1)
        AT_WB.UpdateScrollBar(0, 0)   -- nothing to scroll: no bar
        return
    end

    local left, width = GridBox()
    local n = #cols
    local colW = (width - (n - 1) * COL_GAP) / n
    local perRow = math.max(1, math.floor((colW + (STRIDE - ICON)) / STRIDE))
    local visible = ScrollBounds(0, panel:GetHeight(), 0)

    -- Rows: enough for the longest column, and never fewer than fill the view,
    -- so a tab reads as a bank with empty slots rather than a short list.
    local longest = 0
    for _, col in ipairs(cols) do
        col.rows = math.ceil(#col.entries / perRow)
        if col.rows > longest then longest = col.rows end
    end
    local rowCount = math.max(longest, visible)
    local _, maxStart, start = ScrollBounds(rowCount, panel:GetHeight(), AT_WB.scrollRow)
    AT_WB.scrollRow = start
    AT_WB.UpdateScrollBar(maxStart, start)

    local ci = 0
    for c, col in ipairs(cols) do
        local x0 = left + (c - 1) * (colW + COL_GAP)
        local gridW = perRow * STRIDE - (STRIDE - ICON)
        local gx = x0 + math.floor((colW - gridW) / 2)

        local head = getColHead(c)
        head:ClearAllPoints()
        head:SetPoint("TOPLEFT", panel, "TOPLEFT", x0, -HEAD_H)
        head:SetWidth(colW)
        head.name:SetText(col.title)
        head.icon:SetTexture(col.icon)
        head.icon:SetShown(n > 1)
        head.icon:ClearAllPoints()
        head.name:ClearAllPoints()
        if n > 1 then
            head.icon:SetPoint("LEFT", head, "LEFT", 0, 0)
            head.name:SetPoint("LEFT", head.icon, "RIGHT", 6, 0)
        else
            head.name:SetPoint("CENTER", head, "CENTER", 0, 0)
        end
        head.gear.key = col.key
        head.gear:ClearAllPoints()
        if n > 1 then head.gear:SetPoint("RIGHT", head, "RIGHT", 0, 0)
        else head.gear:SetPoint("LEFT", head.name, "RIGHT", 8, 0) end
        head.gear:SetShown(type(col.key) == "number")
        head:Show()

        for slot = 0, visible - 1 do
            local r = start + slot
            if r >= rowCount then break end
            for k = 1, perRow do
                local e = col.entries[r * perRow + k]
                ci = ci + 1
                local cell = getCell(ci)
                cell:ClearAllPoints()
                cell:SetPoint("TOPLEFT", panel, "TOPLEFT", gx + (k - 1) * STRIDE, -(ROW_TOP + slot * STRIDE))
                FillCell(cell, e)
                cell:Show()
            end
        end
    end
    hideFrom(AT_WB.cells, ci + 1)
    hideFrom(AT_WB.colHeads, n + 1)
    ReconcileHover()
    AT_WB.ApplySearchDim()
end

-- Search dims what is on screen, in every column; it does not decide what is
-- shown, and a match in a tab that is off screen stays off screen.
local function ApplySearchDim()
    local q = AT_WB.search or ""
    for i = 1, #AT_WB.cells do
        local cell = AT_WB.cells[i]
        if cell:IsShown() and cell.entry then
            local match = (q == "")
            if not match then
                local nm = cell.itemName
                match = nm and nm:lower():find(q, 1, true) and true or false
            end
            cell.icon:SetDesaturated(not match)
            cell:SetAlpha(match and 1 or 0.25)
        end
    end
end
AT_WB.ApplySearchDim = ApplySearchDim

-- The rail's step: as tall as the buttons want, shorter when the panel cannot
-- fit them all - eight tabs, Other and "+" ran off a short window and over the
-- status line (review of #154).
local function RailStep(count, panelH)
    local ph = (panelH and panelH >= 50) and panelH or 400
    local room = ph - HEAD_H - FOOT_H - PAD
    return math.max(24, math.min(RAIL_BTN + 8, math.floor(room / math.max(1, count))))
end
AT_WB.RailStep = RailStep

local function LayoutRail(pages, shown, tabs)
    local pw = panel:GetWidth()
    if not pw or pw < 200 then pw = 700 end
    local step = RailStep(#pages + 1, panel:GetHeight())
    local size = math.min(RAIL_BTN, step - 6)
    local x = pw - RAIL_W + (RAIL_W - size) / 2 - 4
    local ar, ag, ab = Accent()
    local i = 0
    for _, key in ipairs(pages) do
        i = i + 1
        local b = getTabBtn(i)
        b.isAdd, b.key = false, key
        local name, icon = TabMeta(key, tabs)
        b.tip = name
        b.icon:SetTexture(icon)
        b.icon:Show()
        b.plus:SetText("")
        b:SetBackdropColor(0, 0, 0, 0.35)
        b.shown = shown[key] and true or false
        if shown[key] then b:SetBackdropBorderColor(ar, ag, ab, 1)
        else b:SetBackdropBorderColor(1, 1, 1, 0.15) end
        b:SetAlpha(1)
        b:ClearAllPoints()
        b:SetSize(size, size)
        b:SetPoint("TOPLEFT", panel, "TOPLEFT", x, -(HEAD_H + (i - 1) * step))
        b:Show()
    end
    -- "+", disabled at the cap.
    i = i + 1
    local add = getTabBtn(i)
    add.isAdd, add.key = true, nil
    add.tip = (#tabs >= M.MAX_TABS) and ("At most " .. M.MAX_TABS .. " tabs") or "Add a tab"
    add.icon:Hide()
    add.plus:SetText("+")
    add.plus:SetTextColor(ar, ag, ab)
    add:SetBackdropColor(0, 0, 0, 0.35)
    add:SetBackdropBorderColor(1, 1, 1, 0.15)
    add:SetEnabled(#tabs < M.MAX_TABS)
    add:SetAlpha(#tabs < M.MAX_TABS and 1 or 0.35)
    add:ClearAllPoints()
    add:SetSize(size, size)
    add:SetPoint("TOPLEFT", panel, "TOPLEFT", x, -(HEAD_H + (i - 1) * step))
    add:Show()
    hideFrom(AT_WB.tabBtns, i + 1)
end

------------------------------------------------------------
-- Refresh
------------------------------------------------------------

local scopeBtns, viewBtns = {}, {}
local prevBtn, nextBtn

local function UpdateControls()
    SetActive(viewBtns.single, View() ~= "combined")
    SetActive(viewBtns.combined, View() == "combined")
    SetActive(scopeBtns.personal, Scope() == "personal")
    SetActive(scopeBtns.warband, Scope() ~= "personal")
    local personal = Scope() == "personal"
    rulesetBtn.label:SetText(personal and "This character" or RulesetText())
    rulesetBtn.chevron:SetShown(not personal)
    rulesetBtn:SetEnabled(not personal)
    rulesetBtn:SetAlpha(personal and 0.5 or 1)
end

local function StatusText()
    local w = AT_WB._window
    local paging = (w and #w.pages > M.COMBINED)
        and ("Tabs " .. w.first .. "-" .. (w.first + w.width - 1) .. " of " .. #w.pages .. "  ·  ") or ""
    if Scope() == "personal" then
        local me = AltStableDB and UnitGUID and AltStableDB[UnitGUID("player")]
        return paging .. ((me and me.name) or "This character") .. "  ·  Bags + bank  ·  Read-only"
    end
    local r = M.ResolveRuleset(Cfg("warbandRuleset", "current"), GetRealmName and GetRealmName())
    return paging .. "Bags + banks  ·  " .. (r or "All rulesets") .. "  ·  Read-only"
end

AT_WB.StatusText = function() return StatusText() end

-- Recompute what is shown from current data, then lay out.
function AT_WB.Refresh()
    if not panel or not panel:IsShown() then return end
    UpdateControls()

    local filter = CurrentFilter()
    local agg = gather(filter)
    local tabs = Tabs()
    if not next(agg) then
        AT_WB._cols = {}
        hideFrom(AT_WB.cells, 1)
        hideFrom(AT_WB.colHeads, 1)
        AT_WB.UpdateScrollBar(0, 0)   -- nothing left to scroll
        AT_WB._window, AT_WB._paging = nil, false
        statusFS:SetText(StatusText())
        LayoutRail(M.Pages(#tabs, false), {}, tabs)
        prevBtn:Hide(); nextBtn:Hide()
        local me = UnitGUID and UnitGUID("player")
        emptyFS:SetText((Scope() == "personal" and not (AltStableDB and AltStableDB[me]))
            and "This character has not been scanned yet - open your bags, or your bank."
            or "Nothing here yet. Log in on your alts (and open a bank) to fill it.")
        emptyFS:Show()
        return
    end
    emptyFS:Hide()

    local perTab, other = M.Distribute(BuildEntries(agg), tabs)
    local pages = M.Pages(#tabs, #other > 0)
    local sel = M.RepairSelection(Cfg("warbandTab", 1), pages)
    if sel ~= Cfg("warbandTab", 1) then AltStable.SetConfigValue("warbandTab", sel) end

    local keys
    if View() == "combined" then
        local first, width = M.CombinedWindow(pages, sel, AT_WB._first)
        AT_WB._first = first
        keys = {}
        for i = first, first + width - 1 do keys[#keys + 1] = pages[i] end
        AT_WB._paging = #pages > M.COMBINED
        prevBtn:SetShown(AT_WB._paging)
        nextBtn:SetShown(AT_WB._paging)
        prevBtn:SetEnabled(first > 1)
        nextBtn:SetEnabled(first + width - 1 < #pages)
        AT_WB._window = { first = first, width = width, pages = pages }
    else
        keys = { sel }
        prevBtn:Hide(); nextBtn:Hide()
        AT_WB._paging = false
        AT_WB._window = nil
    end

    local cols, shown = {}, {}
    for _, key in ipairs(keys) do
        local title, icon = TabMeta(key, tabs)
        cols[#cols + 1] = {
            key = key, title = title, icon = icon,
            entries = (key == "other") and other or (perTab[key] or {}),
        }
        shown[key] = true
    end
    AT_WB._cols = cols
    statusFS:SetText(StatusText())
    LayoutRail(pages, shown, tabs)
    AT_WB.Layout()
end

-- Combined's arrows: move the window by one page, keeping the selection on the
-- page that enters.
local function StepWindow(delta)
    local w = AT_WB._window
    if not w then return end
    local target = delta < 0 and w.pages[w.first - 1] or w.pages[w.first + w.width]
    if target then Select(target) end
end

------------------------------------------------------------
-- Panel + activation
------------------------------------------------------------

local function BuildPanel(mainFrame)
    if panel then return end
    EnsureTooltipHook()
    local sidebarW = (AltStable.LAYOUT and AltStable.LAYOUT.SIDEBAR_WIDTH) or 230
    local titleH   = (AltStable.LAYOUT and AltStable.LAYOUT.TITLE_H) or 30

    panel = CreateFrame("Frame", nil, mainFrame, "BackdropTemplate")
    -- Beside the sidebar's edge, so it follows when the sidebar collapses (#150).
    if not (AltStable.AnchorBesideSidebar and AltStable.AnchorBesideSidebar(panel, mainFrame)) then
        panel:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", sidebarW + 1, -titleH)
    end
    panel:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", 0, 1)
    -- Reaches BOTTOMRIGHT (0, 1), so under glass this panel owns the window's
    -- bottom-right corner and its fill has to be clipped to the window outline.
    -- A backdrop cannot be masked; SkinPanelFill paints a texture instead.
    if not AltStable.SkinPanelFill(panel, mainFrame, AltStable.C.BG_MAIN) then
        AltStable.ApplyBGOnly(panel, AltStable.C.BG_MAIN[1], AltStable.C.BG_MAIN[2], AltStable.C.BG_MAIN[3], AltStable.C.BG_MAIN[4])
    end
    panel:Hide()
    -- Anything open goes with the panel: a menu or dialog left up over another
    -- tab would act on a view that is not there.
    panel:SetScript("OnHide", function()
        CloseRulesetMenu()
        CloseDialog()
        ClearHover()
    end)

    titleFS = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    titleFS:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD, -PAD + 2)
    titleFS:SetText("Warband Inventory")
    titleFS:SetTextColor(unpack(AltStable.C.TEXT_BRIGHT))

    searchBox = CreateFrame("EditBox", nil, panel, "SearchBoxTemplate")
    searchBox:SetSize(200, 20)
    searchBox:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -PAD, -PAD + 2)
    searchBox:HookScript("OnTextChanged", function(self)
        AT_WB.search = (self:GetText() or ""):lower()
        ApplySearchDim()
    end)

    -- The controls row: Single | Combined, the tooltip opt-in, the ruleset.
    local rowY = -(PAD + 30)
    viewBtns.single = MakeButton(panel, 76, 22, "Single", function() AT_WB.SetView("single") end)
    viewBtns.single:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD, rowY)
    viewBtns.combined = MakeButton(panel, 86, 22, "Combined", function() AT_WB.SetView("combined") end)
    viewBtns.combined:SetPoint("LEFT", viewBtns.single, "RIGHT", 2, 0)

    -- Opt-in toggle for the global item-tooltip enrichment (off by default so it
    -- doesn't double up with Bagnon). Lives here rather than in SheetUI's Options.
    local tipCheck = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    tipCheck:SetSize(18, 18)
    tipCheck:SetPoint("LEFT", viewBtns.combined, "RIGHT", 16, 0)
    tipCheck:SetChecked(AltStableConfig and AltStableConfig.warbandItemTooltips and true or false)
    tipCheck:SetScript("OnClick", function(self)
        -- Through the config seam (Config.lua), like every other setting write.
        AltStable.SetConfigValue("warbandItemTooltips", self:GetChecked() and true or false)
    end)
    local tipLbl = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    tipLbl:SetPoint("LEFT", tipCheck, "RIGHT", 2, 0)
    tipLbl:SetText("Show character counts in tooltips")
    tipLbl:SetTextColor(unpack(AltStable.C.TEXT_NORM))
    tipCheck:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine("Show character counts in tooltips")
        GameTooltip:AddLine("Adds who holds how many to item tooltips everywhere - bags, "
            .. "merchants, links - not only in AltStable.", .8, .8, .8, true)
        GameTooltip:Show()
    end)
    tipCheck:SetScript("OnLeave", function() GameTooltip:Hide() end)

    rulesetBtn = MakeButton(panel, 200, 22, "", OpenRulesetMenu)
    rulesetBtn:SetPoint("LEFT", tipLbl, "RIGHT", 16, 0)
    rulesetBtn.chevron = rulesetBtn:CreateTexture(nil, "OVERLAY")
    rulesetBtn.chevron:SetSize(12, 12)
    rulesetBtn.chevron:SetPoint("RIGHT", -8, 0)
    rulesetBtn.chevron:SetTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up")

    -- Combined's paging arrows, either side of the column titles.
    prevBtn = MakeButton(panel, 22, 22, "<", function() StepWindow(-1) end)
    prevBtn:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD, -HEAD_H + 1)
    nextBtn = MakeButton(panel, 22, 22, ">", function() StepWindow(1) end)
    nextBtn:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -(RAIL_W + SCROLL_W + PAD), -HEAD_H + 1)
    prevBtn:Hide(); nextBtn:Hide()

    -- The bottom bar: Personal Bank / Warband, and what is being shown.
    scopeBtns.personal = MakeButton(panel, 110, 24, "Personal Bank", function()
        CloseRulesetMenu()
        AltStable.SetConfigValue("warbandScope", "personal"); AT_WB.scrollRow = 0; AT_WB.Refresh()
    end)
    scopeBtns.personal:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", PAD, 6)
    scopeBtns.warband = MakeButton(panel, 110, 24, "Warband", function()
        AltStable.SetConfigValue("warbandScope", "warband"); AT_WB.scrollRow = 0; AT_WB.Refresh()
    end)
    scopeBtns.warband:SetPoint("LEFT", scopeBtns.personal, "RIGHT", 4, 0)
    statusFS = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statusFS:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -PAD, 12)
    statusFS:SetTextColor(unpack(AltStable.C.TEXT_DIM))

    -- Virtual scroll: the wheel shifts which rows are laid out (cells are direct
    -- panel children, so hover works — a real ScrollFrame ate the mouse events).
    panel:EnableMouseWheel(true)
    panel:SetScript("OnMouseWheel", function(_, delta)
        AT_WB.scrollRow = math.max(0, (AT_WB.scrollRow or 0) - delta * 2)
        AT_WB.Layout()
    end)

    emptyFS = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    emptyFS:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD, -(ROW_TOP + 6))
    emptyFS:SetTextColor(unpack(AltStable.C.TEXT_DIM))
    emptyFS:Hide()

    -- Scrollbar. The wheel already scrolls, but nothing showed there was more
    -- below - and a grid whose last group is off-screen just looks short. Built
    -- from a bare Slider rather than a scroll-frame template: the cells are
    -- direct children of the panel (a ScrollFrame swallowed their hover), and
    -- template names differ across builds.
    --
    -- Built LAST in this function: BuildPanel early-returns once `panel` is
    -- assigned, so a widget call that failed here would leave the panel
    -- half-built for the session - emptyFS nil, and the next data-less Refresh
    -- throwing on it. The bar is the expendable part, so it goes at the end.
    -- SetObeyStepOnDrag is measured on this build (Slider:SetObeyStepOnDrag in
    -- the build-matched API dump); SheetUI omits it because TBC 2.5.x lacked it.
    local scrollBar = CreateFrame("Slider", nil, panel)
    AT_WB.scrollBar = scrollBar
    scrollBar:SetWidth(10)
    scrollBar:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -(RAIL_W + 2), -ROW_TOP)
    scrollBar:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -(RAIL_W + 2), FOOT_H + PAD)
    scrollBar:SetOrientation("VERTICAL")
    scrollBar:SetValueStep(1)
    scrollBar:SetObeyStepOnDrag(true)
    local track = scrollBar:CreateTexture(nil, "BACKGROUND")
    track:SetAllPoints()
    track:SetColorTexture(1, 1, 1, 0.05)
    local thumb = scrollBar:CreateTexture(nil, "OVERLAY")
    thumb:SetColorTexture(1, 1, 1, 0.28)
    thumb:SetSize(10, 32)
    scrollBar:SetThumbTexture(thumb)
    scrollBar:SetScript("OnValueChanged", function(self, value)
        if self._syncing then return end
        AT_WB.scrollRow = math.floor((value or 0) + 0.5)
        AT_WB.Layout()
    end)
    scrollBar:Hide()
end

local function HookRefresh()
    if AT_WB._refreshHooked or type(AltStable.RefreshSheet) ~= "function" then return end
    local prev = AltStable.RefreshSheet
    AltStable.RefreshSheet = function(...)
        prev(...)
        if AT_WB.isActive then C_Timer.After(0, function() if AT_WB.isActive then AT_WB.Refresh() end end) end
    end
    AT_WB._refreshHooked = true
end

-- The panel's floor, as a window size: on activation, and again whenever the
-- window changes under the tab - expanding the sidebar narrows the panel by
-- 174px while the window keeps its width (#157 review).
function AT_WB.HoldMinSize()
    if not AltStable.EnsureWindowMinSize then return end
    local sidebarW = (AltStable.LAYOUT and AltStable.LAYOUT.SIDEBAR_WIDTH) or 230
    local titleH   = (AltStable.LAYOUT and AltStable.LAYOUT.TITLE_H) or 30
    AltStable.EnsureWindowMinSize(sidebarW + 1 + MIN_PANEL_W, titleH + 1 + MIN_PANEL_H)
end

-- The size each view opens at (#150): Single is its floor, a retail-style
-- 14-wide tab; Combined holds three tabs at seven icons each (3 x 274 + the
-- gaps, the rail, the scroll bar and the paging arrows = 1006). The window
-- height is the one every plugin tab shares.
AT_WB.PREFERRED_PANEL_W = { single = MIN_PANEL_W, combined = 1010 }
function AT_WB.RequestPreferredSize()
    if not AltStable.RequestPluginSize then return end
    AltStable.RequestPluginSize(AT_WB.PREFERRED_PANEL_W[View()] or MIN_PANEL_W)
end

-- Single <-> Combined: the view and its size, gliding like a tab switch
-- rather than jumping (#150). The LAYOUT is the animator's to place, through
-- OnResize (the floor, then Refresh): at the end of a trip that grows, so
-- Combined's columns never stand past a window still on its way there, and
-- before one that shrinks. Refreshing here as well laid Combined out at its
-- final width before the trip and gathered every bag twice (#191 review).
function AT_WB.SetView(view)
    if View() == view then return end
    local function apply()
        AltStable.SetConfigValue("warbandView", view)
        AT_WB.scrollRow = 0
        AT_WB.RequestPreferredSize()
    end
    if AltStable.AnimateWindowChange then AltStable.AnimateWindowChange(apply) else apply() end
end

function AT_WB.Activate(mainFrame)
    BuildPanel(mainFrame)
    HookRefresh()
    AT_WB.isActive = true
    AT_WB.RequestPreferredSize()
    AT_WB.HoldMinSize()

    if mainFrame.bodyScroll   then mainFrame.bodyScroll:Hide()   end
    if mainFrame.frozenScroll then mainFrame.frozenScroll:Hide() end
    if mainFrame.headerScroll then mainFrame.headerScroll:Hide() end
    if mainFrame.frozenHeader then mainFrame.frozenHeader:Hide() end
    if mainFrame.hScrollBar   then mainFrame.hScrollBar:Hide()   end
    if mainFrame.totalsBar    then mainFrame.totalsBar:Hide()    end

    panel:Show()
    ScanBags()                     -- freshen our own bags on open
    if isBankOpen then ScanBank() end
    AT_WB.Refresh()
end

function AT_WB.Deactivate(mainFrame)
    AT_WB.isActive = false
    if panel then panel:Hide() end
    CloseRulesetMenu()
    CloseDialog()
    ClearHover()
    if mainFrame.bodyScroll   then mainFrame.bodyScroll:Show()   end
    if mainFrame.frozenScroll then mainFrame.frozenScroll:Show() end
    if mainFrame.headerScroll then mainFrame.headerScroll:Show() end
    if mainFrame.frozenHeader then mainFrame.frozenHeader:Show() end
    if mainFrame.hScrollBar   then mainFrame.hScrollBar:Show()   end
    if mainFrame.totalsBar    then mainFrame.totalsBar:Show()    end
end

------------------------------------------------------------
-- Bootstrap + events
------------------------------------------------------------

local function BootstrapPlugin()
    if not AltStable or not AltStable.RegisterPlugin then
        Print("AltStable not found — make sure it is installed and enabled.")
        return
    end
    EnsureTooltipHook()   -- install now so the global item-tooltip option works pre-panel
    AltStable.RegisterPlugin({
        id            = ADDON_ID,
        label         = "Warband",
        icon          = (AltStable.MEDIA_PATH or "Interface\\AddOns\\AltStable\\Media\\")
                        .. "Icons\\warband.tga",
        _isPlugin     = true,
        OnActivate    = function(mf) AT_WB.Activate(mf) end,
        -- The window changed size under us: maximize, restore, the sidebar (#150).
        OnResize      = function()
            if not AT_WB.isActive then return end
            AT_WB.HoldMinSize()
            AT_WB.Refresh()
        end,
        OnDeactivate  = function(mf) AT_WB.Deactivate(mf) end,
        OnSerialize   = function(g, s) return SerializePlayer(g, s) end,
        OnDeserialize = function(g, b) DeserializePlayer(g, b) end,
        OnCleanup     = function(keepGuid) CleanupWarbandDB(keepGuid) end,
        -- #65: a forgotten character's bags and bank go with its record, or
        -- they sit in SavedVariables until PruneOrphans happens to run at the
        -- next login - for a character nothing shows.
        OnForget      = function(guid)
            if guid and AltStableWarbandDB then AltStableWarbandDB[guid] = nil end
        end,
        _wb           = AT_WB,
        _test = {
            SerializePlayer = SerializePlayer, DeserializePlayer = DeserializePlayer,
            gather = gather, ScanBags = ScanBags, ScanBank = ScanBank, CountItem = CountItem,
            EncodeMap = EncodeMap, ParseMap = ParseMap, mapsEqual = mapsEqual,
            OnBagUpdate = OnBagUpdate, OnBankOpened = OnBankOpened, OnBankClosed = OnBankClosed,
            CarriedBagIDs = CarriedBagIDs, BankTabIDs = BankTabIDs, IsBankContainer = IsBankContainer,
            CleanupWarbandDB = CleanupWarbandDB, PruneOrphans = PruneOrphans,
            InvalidateTabCache = InvalidateTabCache, BootstrapPlugin = BootstrapPlugin,
            OnBankTabsChanged = OnBankTabsChanged,
            ScanContainerSet = ScanContainerSet, EnsureTooltipHook = EnsureTooltipHook,
        },
    })

    -- Orphans first: inventory for a guid no character record mentions is
    -- invisible in the UI, so counting it as "we hold data" could skip the
    -- baseline pull below and leave the real inventory unfetched.
    PruneOrphans()

    -- Full-baseline pull when we hold no inventory at all: the peer watermark
    -- may already be ahead of data we never received, which a delta pull would
    -- never backfill.
    --
    -- NOT on "loaded on demand": the core loads enabled plugins from its own
    -- PLAYER_LOGIN handler, so IsLoggedIn() is already true and EVERY login
    -- took that branch. That reset every peer watermark about a second before
    -- the login sync, turning every session into a full-database pull (minutes
    -- on a large database). Holding data is the only signal that matters.
    if AltStable.ResetPeerWatermarks then
        local hasData = false
        for _, cdb in pairs(AltStableWarbandDB) do
            if type(cdb) == "table" and ((cdb.bags and next(cdb.bags)) or (cdb.bank and next(cdb.bank))) then
                hasData = true; break
            end
        end
        if not hasData then AltStable.ResetPeerWatermarks() end
    end

    C_Timer.After(3, ScanBags)   -- prime our own bags after the login event storm
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("BAG_UPDATE")
frame:RegisterEvent("BANKFRAME_OPENED")
frame:RegisterEvent("BANKFRAME_CLOSED")
frame:RegisterEvent("PLAYERBANKSLOTS_CHANGED")
frame:RegisterEvent("BANK_TABS_CHANGED")
frame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
frame:SetScript("OnEvent", function(self, event, arg1, arg2)
    if event == "PLAYER_LOGIN" then
        C_Timer.After(1, BootstrapPlugin)
    elseif event == "BAG_UPDATE" then
        OnBagUpdate(arg1)
    elseif event == "BANKFRAME_OPENED" then
        OnBankOpened()
    elseif event == "BANKFRAME_CLOSED" then
        OnBankClosed()
    elseif event == "PLAYERBANKSLOTS_CHANGED" then
        if isBankOpen then ScheduleBank() end
    elseif event == "BANK_TABS_CHANGED" then
        OnBankTabsChanged(arg1)
    elseif event == "GET_ITEM_INFO_RECEIVED" then
        local id, success = arg1, arg2
        if id and success and requestedIDs[id] then
            requestedIDs[id] = nil
            if AT_WB.isActive then
                if self._metaTimer then self._metaTimer:Cancel() end
                self._metaTimer = C_Timer.NewTimer(0.2, function()
                    self._metaTimer = nil
                    if AT_WB.isActive and AT_WB.Refresh then AT_WB.Refresh() end
                end)
            end
        end
    end
end)

-- Loaded on demand after login (the usual path: the core loads enabled plugins
-- from its PLAYER_LOGIN handler), so PLAYER_LOGIN will not fire for us again.
if IsLoggedIn() then
    C_Timer.After(1, BootstrapPlugin)
end
