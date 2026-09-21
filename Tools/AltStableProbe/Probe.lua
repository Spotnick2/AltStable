--[[
    AltStableProbe — answers the open API questions for the WoW: Forever port.

    This is a throwaway diagnostic, not part of AltStable. It never ships (it
    lives under Tools/, which .pkgmeta ignores).

    The point is NOT "does this function exist" — the captured API dump already
    answers that. The point is the *contract*: argument shape, return ORDER, and
    whether the underlying system is actually wired up on a Vanilla-content
    client. A tuple that shifts by one position yields empty data with no error,
    which is the failure mode this addon exists to prevent.

    Usage in-game:
        /asprobe              run every section
        /asprobe bank         run the container section with the bank window OPEN
        /asprobe <section>    client|identity|skills|prof|rep|items|containers|tooltip|instances|events
        /asprobe whisper <Name>   send a cross-account addon-message ping
        /asprobe copy         reopen the copy window (selectable text, Ctrl+A/Ctrl+C)
        /asprobe dump         re-print the last run

    Results also land in AltStableProbeDB so they can be read off disk:
        _classic_beta_\WTF\Account\<id>\SavedVariables\AltStableProbe.lua
]]

local ADDON = ...

AltStableProbeDB = AltStableProbeDB or {}
AltStableProbeCharDB = AltStableProbeCharDB or {}
-- Machine scope lands in the TOP-LEVEL WTF\SavedVariables\ folder, not under
-- WTF\Account\<id>\. That folder demonstrably survives a full restart on
-- 1.60.1.69913 - Blizzard_Console.lua carries history across launches - while
-- everything under WTF\Account\ is wiped. On 1.60.1.69913 the answer is no:
-- the client never writes a third-party machine-scope variable at all. Kept so
-- each new build can be checked the same way.
AltStableProbeMachineDB = AltStableProbeMachineDB or {}

local lines = {}

local function Out(s)
    DEFAULT_CHAT_FRAME:AddMessage("|cff66ccff[probe]|r " .. tostring(s))
end

local function Record(s)
    lines[#lines + 1] = s
    Out(s)
end

local function Section(name)
    Record(" ")
    Record("|cffffd100== " .. name .. " ==|r")
end

-- Describe one value, including table contents (structs are the whole reason
-- this exists). `depth` bounds recursion so a frame reference can't run away.
local function ValStr(v, depth)
    local t = type(v)
    if t == "nil" then return "nil" end
    if t == "string" then return string.format("%q", v) end
    if t == "number" or t == "boolean" then return tostring(v) end
    if t == "table" then
        if (depth or 0) <= 0 then return "{...}" end
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        if #keys == 0 then return "{}" end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        local parts = {}
        for i = 1, #keys do
            local k = keys[i]
            parts[#parts + 1] = tostring(k) .. "=" .. ValStr(v[k], (depth or 1) - 1)
        end
        return "{" .. table.concat(parts, ", ") .. "}"
    end
    return "<" .. t .. ">"
end

-- Call `fn` and report the return tuple with positions preserved, INCLUDING
-- trailing nils. Building a table from pcall's results would silently drop
-- those, and trailing nils are exactly what we're checking for.
local function Call(label, fn, ...)
    if type(fn) ~= "function" then
        Record(("%-46s ABSENT (%s)"):format(label, type(fn)))
        return
    end
    local function handle(ok, ...)
        if not ok then
            Record(("%-46s ERROR: %s"):format(label, tostring((...))))
            return
        end
        local n = select("#", ...)
        if n == 0 then
            Record(("%-46s (no returns)"):format(label))
            return
        end
        local parts = {}
        for i = 1, n do
            parts[#parts + 1] = "[" .. i .. "]=" .. ValStr((select(i, ...)), 2)
        end
        Record(("%-46s %d: %s"):format(label, n, table.concat(parts, "  ")))
    end
    handle(pcall(fn, ...))
end

local function Has(path, v)
    Record(("%-46s %s"):format(path, type(v) == "nil" and "|cffff5555ABSENT|r" or ("present (" .. type(v) .. ")")))
end

----------------------------------------------------------------------------
-- Sections
----------------------------------------------------------------------------

local P = {}

function P.client()
    Section("client")
    local function buildinfo()
        local n = select("#", GetBuildInfo())
        local parts = {}
        for i = 1, n do parts[#parts + 1] = "[" .. i .. "]=" .. ValStr((select(i, GetBuildInfo())), 1) end
        Record(("%-46s %d: %s"):format("GetBuildInfo()", n, table.concat(parts, "  ")))
    end
    buildinfo()
    Record(("%-46s %s"):format("WOW_PROJECT_ID", ValStr(WOW_PROJECT_ID, 1)))
    Record(("%-46s %s"):format("WOW_PROJECT_MAINLINE", ValStr(WOW_PROJECT_MAINLINE, 1)))
    Record(("%-46s %s"):format("MAX_PLAYER_LEVEL (level cap)", ValStr(MAX_PLAYER_LEVEL, 1)))
    Record(("%-46s %s"):format("GetMaxPlayerLevel()", type(GetMaxPlayerLevel) == "function" and ValStr(GetMaxPlayerLevel(), 1) or "ABSENT"))
    Call("UnitLevel('player')", UnitLevel, "player")
    Call("GetAverageItemLevel()", GetAverageItemLevel)
    Call("UnitXP('player')", UnitXP, "player")
    Call("UnitXPMax('player')", UnitXPMax, "player")
    Call("GetXPExhaustion()", GetXPExhaustion)
end

-- Forever gives characters a SURNAME as well as a first name
-- (C_PlayerInfo.ShouldDisplaySurname returns true).
--
-- MEASURED: the surname is part of the name string, SPACE-separated
-- ("Example Surname"), not hyphenated. The hyphenated form appears only in WTF
-- folder names on disk. That is better than feared for sync: Core.lua's
-- PeerShort() splits on "-" to strip a realm, so a space-separated surname
-- passes through intact.
--
-- Also measured: UnitName gives the full name, but GetPlayerInfoByGUID returns
-- the FIRST NAME ONLY, so the two identity sources disagree.
--
-- Still open: what CHAT_MSG_ADDON reports as `sender`, and whether a whisper
-- routes to a target containing a space. That is what /asprobe whisper answers.
function P.identity()
    Section("identity  (SURNAMES - first names are no longer unique)")
    local function multi(label, fn, ...)
        Call(label, fn, ...)
    end
    multi("UnitName('player')", UnitName, "player")
    multi("UnitFullName('player')", UnitFullName, "player")
    multi("UnitNameUnmodified('player')", UnitNameUnmodified, "player")
    multi("GetUnitName('player', false)", GetUnitName, "player", false)
    multi("GetUnitName('player', true)", GetUnitName, "player", true)
    multi("UnitGUID('player')", UnitGUID, "player")
    local guid = UnitGUID and UnitGUID("player")
    if guid then
        multi("UnitNameFromGUID(guid)", UnitNameFromGUID, guid)
        multi("GetPlayerInfoByGUID(guid)", GetPlayerInfoByGUID, guid)
    end
    multi("GetRealmName()", GetRealmName)
    multi("GetNormalizedRealmName()", GetNormalizedRealmName)
    if type(C_PlayerInfo) == "table" then
        multi("C_PlayerInfo.ShouldDisplaySurname()", C_PlayerInfo.ShouldDisplaySurname)
        multi("C_PlayerInfo.GetName('player')", C_PlayerInfo.GetName, "player")
        multi("C_PlayerInfo.GetPlayerCharacterData()", C_PlayerInfo.GetPlayerCharacterData)
    end
    -- Anything we can see about other players tells us what a whisper target
    -- and an incoming CHAT_MSG_ADDON sender look like.
    for _, unit in ipairs({ "target", "party1", "party2" }) do
        if UnitExists and UnitExists(unit) and UnitIsPlayer and UnitIsPlayer(unit) then
            multi("UnitName('" .. unit .. "')", UnitName, unit)
            multi("UnitFullName('" .. unit .. "')", UnitFullName, unit)
        end
    end
    Record("  >> compare the above against this character's WTF folder name")
    Record("  >> if the surname appears in NONE of these, sync must key on GUID, not name")
    Record("  >> to check whisper routing: /asprobe whisper <FirstName> and see if it lands")
end

function P.skills()
    Section("skills  (Scanner reads name/isHeader/rank/max at 1/2/4/7)")
    Has("C_SkillInfo", C_SkillInfo)
    if type(C_SkillInfo) ~= "table" then return end
    Call("C_SkillInfo.GetNumSkillLines()", C_SkillInfo.GetNumSkillLines)
    local n = 0
    if type(C_SkillInfo.GetNumSkillLines) == "function" then
        local ok, v = pcall(C_SkillInfo.GetNumSkillLines)
        if ok and type(v) == "number" then n = v end
    end
    for i = 1, math.min(n, 20) do
        Call("  GetSkillLineInfo(" .. i .. ")", C_SkillInfo.GetSkillLineInfo, i)
    end
    if n > 20 then Record("  ... " .. (n - 20) .. " more skill lines") end
end

function P.prof()
    Section("professions")
    Call("GetProfessions()", GetProfessions)
    if type(GetProfessions) == "function" then
        local ok, p1, p2, arch, fish, cook, firstaid = pcall(GetProfessions)
        if ok then
            for _, idx in ipairs({ p1, p2, arch, fish, cook, firstaid }) do
                if idx then Call("  GetProfessionInfo(" .. idx .. ")", GetProfessionInfo, idx) end
            end
        end
    end
    Has("C_TradeSkillUI", C_TradeSkillUI)
    if type(C_TradeSkillUI) == "table" then
        Call("C_TradeSkillUI.GetAllProfessionTradeSkillLines()", C_TradeSkillUI.GetAllProfessionTradeSkillLines)
    end
end

function P.rep()
    Section("reputation  (Reputations.lua takes standing from return 3)")
    Has("C_Reputation", C_Reputation)
    if type(C_Reputation) ~= "table" then return end
    Call("C_Reputation.GetNumFactions()", C_Reputation.GetNumFactions)
    local n = 0
    if type(C_Reputation.GetNumFactions) == "function" then
        local ok, v = pcall(C_Reputation.GetNumFactions)
        if ok and type(v) == "number" then n = v end
    end
    for i = 1, math.min(n, 12) do
        Call("  GetFactionDataByIndex(" .. i .. ")", C_Reputation.GetFactionDataByIndex, i)
    end
    if n > 12 then Record("  ... " .. (n - 12) .. " more factions") end
    -- Known Vanilla faction IDs: 72 Stormwind, 76 Orgrimmar, 529 Argent Dawn,
    -- 609 Cenarion Circle, 270 Zandalar Tribe, 59 Thorium Brotherhood.
    for _, id in ipairs({ 72, 76, 529, 609, 270, 59 }) do
        Call("  GetFactionDataByID(" .. id .. ")", C_Reputation.GetFactionDataByID, id)
    end
    -- The old scan walked the *visible* list; confirm headers can be expanded.
    Has("C_Reputation.ExpandAllFactionHeaders", C_Reputation.ExpandAllFactionHeaders)
end

function P.items()
    Section("items  (GetItemIcon vs GetItemIconByID is the known trap)")
    Has("C_Item", C_Item)
    if type(C_Item) ~= "table" then return end
    local HEARTHSTONE, THUNDERFURY = 6948, 19019
    Call("C_Item.GetItemInfo(6948)", C_Item.GetItemInfo, HEARTHSTONE)
    Call("C_Item.GetItemInfoInstant(6948)", C_Item.GetItemInfoInstant, HEARTHSTONE)
    Call("C_Item.GetItemIconByID(6948)", C_Item.GetItemIconByID, HEARTHSTONE)
    Call("C_Item.GetItemIcon(6948)", C_Item.GetItemIcon, HEARTHSTONE)
    Call("C_Item.GetItemQualityByID(19019)", C_Item.GetItemQualityByID, THUNDERFURY)
    Call("C_Item.GetItemInfo(19019) [epic ilvl]", C_Item.GetItemInfo, THUNDERFURY)
    Call("C_Item.GetItemCount(6948)", C_Item.GetItemCount, HEARTHSTONE)
    Call("C_Item.GetItemStats('item:19019')", C_Item.GetItemStats, "item:19019")
    -- Cache-miss behaviour: an item we almost certainly have not seen.
    Call("C_Item.GetItemInfo(21877) [likely uncached]", C_Item.GetItemInfo, 21877)
    Section("defense / stats")
    Call("UnitDefenseSkill('player')", UnitDefenseSkill, "player")
    Call("UnitStat('player',1)", UnitStat, "player", 1)
    Call("UnitAttackPower('player')", UnitAttackPower, "player")
end

function P.containers()
    Section("containers  (run '/asprobe bank' with the BANK WINDOW OPEN)")
    Has("C_Container", C_Container)
    if type(C_Container) ~= "table" then return end
    -- Enum.BagIndex is the authoritative container-id map. Forever remapped
    -- these (bag -1 is the Keyring here, not the bank), so sweep what the enum
    -- names plus a wide numeric net rather than trusting Classic's constants.
    if Enum and Enum.BagIndex then
        Record("Enum.BagIndex: " .. ValStr(Enum.BagIndex, 2))
    else
        Record("Enum.BagIndex ABSENT")
    end
    local ids, seen = {}, {}
    if Enum and Enum.BagIndex then
        for _, v in pairs(Enum.BagIndex) do
            if type(v) == "number" and not seen[v] then seen[v] = true; ids[#ids + 1] = v end
        end
    end
    for n = -10, 40 do if not seen[n] then seen[n] = true; ids[#ids + 1] = n end end
    table.sort(ids)

    Record("bag id -> slots / name")
    for _, bag in ipairs(ids) do
        local slots
        if type(C_Container.GetContainerNumSlots) == "function" then
            local ok, v = pcall(C_Container.GetContainerNumSlots, bag)
            slots = ok and v or nil
        end
        if slots and slots > 0 then
            local name
            if type(C_Container.GetBagName) == "function" then
                local ok, v = pcall(C_Container.GetBagName, bag)
                name = ok and v or nil
            end
            Record(("  bag %-4d slots=%-3d name=%s"):format(bag, slots, ValStr(name, 1)))
            -- Return SHAPE of the first occupied slot in this bag.
            for s = 1, math.min(slots, 6) do
                local ok, info = pcall(C_Container.GetContainerItemInfo, bag, s)
                if ok and info ~= nil then
                    Call(("    GetContainerItemInfo(%d,%d)"):format(bag, s), C_Container.GetContainerItemInfo, bag, s)
                    break
                end
            end
        end
    end
    Section("bank type / shared storage")
    Record(("%-46s %s"):format("BankFrame:IsShown()",
        (BankFrame and BankFrame.IsShown) and tostring(BankFrame:IsShown()) or "no BankFrame"))
    if Enum and Enum.BankType then
        Record(("%-46s %s"):format("Enum.BankType", ValStr(Enum.BankType, 2)))
        for label, id in pairs(Enum.BankType) do
            if type(id) == "number" then
                Call(("  C_Bank.CanViewBank(%s=%d)"):format(tostring(label), id), C_Bank and C_Bank.CanViewBank, id)
            end
        end
    end
    Has("C_Bank", C_Bank)
    if type(C_Bank) == "table" then
        Call("C_Bank.FetchViewableBankTypes()", C_Bank.FetchViewableBankTypes)
        Call("C_Bank.AreAnyBankTypesViewable()", C_Bank.AreAnyBankTypesViewable)
        Call("C_Bank.CanViewBank(1)", C_Bank.CanViewBank, 1)
    end
    Record(("%-46s %s"):format("NUM_BANKGENERIC_SLOTS", ValStr(NUM_BANKGENERIC_SLOTS, 1)))
    Record(("%-46s %s"):format("NUM_BAG_SLOTS", ValStr(NUM_BAG_SLOTS, 1)))
    Record(("%-46s %s"):format("NUM_BANKBAGSLOTS", ValStr(NUM_BANKBAGSLOTS, 1)))
end

-- Open question. With the bank demonstrably open (BankFrame:IsShown() == true)
-- NO container id in -5..20 reported any slots, yet the bank shows 48 slots
-- plus 8 purchasable bag slots. So Classic's BANK_IDS = { -1, 5..11 } is wrong
-- here, and -1 is the Keyring. Either the ids moved, or the bank is reached
-- through C_Bank rather than as plain containers. Enum.BagIndex settles it.
function P.bank()
    Section("bank  (open the bank first)")
    Record(("%-46s %s"):format("BankFrame:IsShown()",
        (BankFrame and BankFrame.IsShown) and tostring(BankFrame:IsShown()) or "no BankFrame"))
    if not (Enum and Enum.BankType) then Record("Enum.BankType ABSENT"); return end
    Record(("%-46s %s"):format("Enum.BankType", ValStr(Enum.BankType, 2)))
    if type(C_Bank) ~= "table" then Record("C_Bank ABSENT"); return end

    Call("C_Bank.FetchViewableBankTypes()", C_Bank.FetchViewableBankTypes)
    for label, bt in pairs(Enum.BankType) do
        if type(bt) == "number" then
            local tag = ("%s=%d"):format(tostring(label), bt)
            Call(("  CanViewBank(%s)"):format(tag), C_Bank.CanViewBank, bt)
            Call(("  FetchNumPurchasedBankTabs(%s)"):format(tag), C_Bank.FetchNumPurchasedBankTabs, bt)
            Call(("  FetchPurchasedBankTabIDs(%s)"):format(tag), C_Bank.FetchPurchasedBankTabIDs, bt)
            Call(("  FetchPurchasedBankTabData(%s)"):format(tag), C_Bank.FetchPurchasedBankTabData, bt)
            Call(("  FetchMaxNumBankTabs(%s)"):format(tag), C_Bank.FetchMaxNumBankTabs, bt)
            Call(("  FetchNextPurchasableBankTabData(%s)"):format(tag), C_Bank.FetchNextPurchasableBankTabData, bt)
            Call(("  DoesBankTypeSupportAutoDeposit(%s)"):format(tag), C_Bank.DoesBankTypeSupportAutoDeposit, bt)
        end
    end
    -- If a tab id comes back above, read it as a container to confirm the
    -- tab id IS the bag id that C_Container accepts.
    local ok, tabs = pcall(C_Bank.FetchPurchasedBankTabIDs, Enum.BankType.Character)
    if ok and type(tabs) == "table" then
        for _, id in ipairs(tabs) do
            Call(("  GetContainerNumSlots(tab %d)"):format(id), C_Container.GetContainerNumSlots, id)
            Call(("  GetContainerItemInfo(tab %d, 1)"):format(id), C_Container.GetContainerItemInfo, id, 1)
        end
    end
end

-- The load-blocker. Warband hooks OnTooltipSetItem during bootstrap; on
-- Mainline that hook may never fire (TooltipDataProcessor replaced it), and a
-- hard error there aborts plugin registration entirely.
function P.tooltip()
    Section("tooltip  (does OnTooltipSetItem still fire?)")
    local fired = { hook = false, tdp = false }

    local okHook, errHook = pcall(function()
        GameTooltip:HookScript("OnTooltipSetItem", function() fired.hook = true end)
    end)
    Record(("%-46s %s"):format("GameTooltip:HookScript('OnTooltipSetItem')",
        okHook and "installed without error" or ("|cffff5555ERROR: " .. tostring(errHook) .. "|r")))

    Has("TooltipDataProcessor", TooltipDataProcessor)
    Has("C_TooltipInfo", C_TooltipInfo)
    if type(TooltipDataProcessor) == "table" and type(TooltipDataProcessor.AddTooltipPostCall) == "function"
       and Enum and Enum.TooltipDataType and Enum.TooltipDataType.Item then
        local ok, err = pcall(TooltipDataProcessor.AddTooltipPostCall, Enum.TooltipDataType.Item,
            function() fired.tdp = true end)
        Record(("%-46s %s"):format("TooltipDataProcessor.AddTooltipPostCall",
            ok and "installed without error" or ("ERROR: " .. tostring(err))))
    end

    -- Now actually drive a tooltip and see which path fires.
    GameTooltip:SetOwner(UIParent, "ANCHOR_NONE")
    local okSet, errSet = pcall(function() GameTooltip:SetHyperlink("item:6948") end)
    Record(("%-46s %s"):format("GameTooltip:SetHyperlink('item:6948')",
        okSet and "ok" or ("ERROR: " .. tostring(errSet))))
    GameTooltip:Hide()

    local function report(when)
        Record(("%-46s OnTooltipSetItem=%s  TooltipDataProcessor=%s"):format(
            "  fired " .. when, tostring(fired.hook), tostring(fired.tdp)))
        if not fired.hook then
            Record("  |cffff5555>> OnTooltipSetItem did NOT fire - Warband's tooltip must move to TooltipDataProcessor|r")
        else
            Record("  |cff55ff55>> OnTooltipSetItem fires - Warband's existing hook is safe|r")
        end
    end
    report("immediately")
    if C_Timer and C_Timer.After then
        C_Timer.After(0.5, function() report("after 0.5s") end)
    end

    Call("C_TooltipInfo.GetHyperlink('item:6948')", C_TooltipInfo and C_TooltipInfo.GetHyperlink, "item:6948")
end

function P.instances()
    Section("saved instances  (boss mask depends on ENCOUNTER ORDER being stable)")
    Call("GetNumSavedInstances()", GetNumSavedInstances)
    local n = 0
    if type(GetNumSavedInstances) == "function" then
        local ok, v = pcall(GetNumSavedInstances)
        if ok and type(v) == "number" then n = v end
    end
    if n == 0 then
        Record("  no lockouts right now - re-run after saving to a raid to check encounter order")
    end
    for i = 1, n do
        Call("  GetSavedInstanceInfo(" .. i .. ")", GetSavedInstanceInfo, i)
        local ok, _, _, _, _, _, _, _, _, _, _, numEnc = pcall(GetSavedInstanceInfo, i)
        if ok and type(numEnc) == "number" then
            for e = 1, numEnc do
                Call(("    GetSavedInstanceEncounterInfo(%d,%d)"):format(i, e), GetSavedInstanceEncounterInfo, i, e)
            end
        end
    end
end

function P.events()
    Section("events  (unknown names throw on this client - failures are logged, not swallowed)")
    local f = CreateFrame("Frame")
    local want = {
        -- Core.lua
        "PLAYER_LOGIN", "CHAT_MSG_ADDON", "PLAYER_EQUIPMENT_CHANGED", "GET_ITEM_INFO_RECEIVED",
        "PLAYER_MONEY", "PLAYER_UPDATE_RESTING", "PLAYER_XP_UPDATE", "UPDATE_INSTANCE_INFO",
        "MAIL_INBOX_UPDATE", "CHAT_MSG_SYSTEM",
        -- Warband
        "BAG_UPDATE", "BAG_UPDATE_DELAYED", "BANKFRAME_OPENED", "BANKFRAME_CLOSED",
        "PLAYERBANKSLOTS_CHANGED", "PLAYERBANKBAGSLOTS_CHANGED",
        -- Scanner
        "SKILL_LINES_CHANGED", "UPDATE_FACTION", "PLAYER_LEVEL_UP",
        -- Professions (deferred, but cheap to answer now)
        "TRADE_SKILL_SHOW", "TRADE_SKILL_UPDATE", "TRADE_SKILL_LIST_UPDATE",
        "TRADE_SKILL_DATA_SOURCE_CHANGED",
    }
    local bad = {}
    for _, ev in ipairs(want) do
        local ok, err = pcall(f.RegisterEvent, f, ev)
        if not ok then
            bad[#bad + 1] = ev
            Record(("  |cffff5555%-34s REJECTED: %s|r"):format(ev, tostring(err)))
        end
    end
    if #bad == 0 then
        Record("  all " .. #want .. " events registered cleanly")
    else
        Record("  |cffff5555" .. #bad .. " of " .. #want .. " events rejected (above)|r")
    end
    f:UnregisterAllEvents()
end

----------------------------------------------------------------------------
-- Driver
----------------------------------------------------------------------------

-- Defined further down (needs the frame helpers); forward-declared so Run can call it.
local ShowCopy

local ORDER = { "client", "identity", "skills", "prof", "rep", "items", "containers", "bank", "tooltip", "instances", "events" }

local function Run(which)
    lines = {}
    Record("AltStableProbe  " .. date("%Y-%m-%d %H:%M:%S"))
    if which and P[which] then
        P[which]()
    else
        for _, k in ipairs(ORDER) do P[k]() end
    end
    AltStableProbeDB.lastRun = date("%Y-%m-%d %H:%M:%S")
    AltStableProbeDB.build = { GetBuildInfo() }
    AltStableProbeDB.lines = lines
    Out("|cff55ff55done|r - " .. #lines .. " lines saved to AltStableProbeDB (written on logout/reload)")
    ShowCopy(lines)
end

----------------------------------------------------------------------------
-- Copy window.
--
-- The chat frame can't be selected, so the same output also goes into a
-- scrollable multi-line EditBox where Ctrl+A / Ctrl+C works. Paged, because a
-- full sweep is a few hundred lines and stuffing all of it into one EditBox is
-- asking for a truncation surprise.
--
-- Built without UIPanelScrollFrameTemplate on purpose: that template still
-- exists on Mainline but its scrollbar internals changed in 10.1, and this is
-- the one piece of UI that has to work on an unfamiliar client.
----------------------------------------------------------------------------

local LINES_PER_PAGE = 150
local copyFrame, copyEdit, copyScroll, copyLabel
local copyPages, copyPage = {}, 1

local function StripColors(s)
    s = tostring(s)
    s = s:gsub("|c%x%x%x%x%x%x%x%x", "")
    s = s:gsub("|r", "")
    s = s:gsub("|T.-|t", "")
    return s
end

local function BuildPages(src)
    copyPages = {}
    local buf = {}
    for i = 1, #src do
        buf[#buf + 1] = StripColors(src[i])
        if #buf >= LINES_PER_PAGE then
            copyPages[#copyPages + 1] = table.concat(buf, "\n")
            buf = {}
        end
    end
    if #buf > 0 then copyPages[#copyPages + 1] = table.concat(buf, "\n") end
    if #copyPages == 0 then copyPages[1] = "(no output - run /asprobe first)" end
end

local function ShowPage(n)
    copyPage = math.max(1, math.min(n, #copyPages))
    copyEdit:SetText(copyPages[copyPage])
    copyEdit:SetCursorPosition(0)
    copyScroll:SetVerticalScroll(0)
    copyLabel:SetText(("page %d / %d      Ctrl+A  then  Ctrl+C"):format(copyPage, #copyPages))
end

local function Button(parent, text, width)
    local ok, b = pcall(CreateFrame, "Button", nil, parent, "UIPanelButtonTemplate")
    if not ok or not b then
        b = CreateFrame("Button", nil, parent)
        local fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetAllPoints(); fs:SetJustifyH("CENTER")
        b.Text = fs
    end
    b:SetSize(width or 80, 22)
    if b.SetText then b:SetText(text) elseif b.Text then b.Text:SetText(text) end
    return b
end

local function CreateCopyFrame()
    if copyFrame then return end

    local ok, f = pcall(CreateFrame, "Frame", "AltStableProbeCopyFrame", UIParent, "BackdropTemplate")
    if not ok or not f then f = CreateFrame("Frame", "AltStableProbeCopyFrame", UIParent) end
    copyFrame = f

    f:SetSize(780, 540)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    if f.SetBackdrop then
        f:SetBackdrop({
            bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 32,
            insets = { left = 11, right = 12, top = 12, bottom = 11 },
        })
    end
    -- Escape closes it.
    tinsert(UISpecialFrames, "AltStableProbeCopyFrame")

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("AltStable probe output")

    copyLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    copyLabel:SetPoint("TOPRIGHT", -16, -18)

    local sc = CreateFrame("ScrollFrame", nil, f)
    sc:SetPoint("TOPLEFT", 18, -44)
    sc:SetPoint("BOTTOMRIGHT", -20, 44)
    copyScroll = sc

    local eb = CreateFrame("EditBox", nil, sc)
    eb:SetMultiLine(true)
    eb:SetAutoFocus(false)
    eb:SetMaxLetters(0)
    eb:SetFontObject(ChatFontNormal)
    eb:SetWidth(740)
    eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    sc:SetScrollChild(eb)
    copyEdit = eb

    sc:EnableMouseWheel(true)
    sc:SetScript("OnMouseWheel", function(self, delta)
        local cur, max = self:GetVerticalScroll(), self:GetVerticalScrollRange()
        local new = cur - delta * 45
        if new < 0 then new = 0 elseif new > max then new = max end
        self:SetVerticalScroll(new)
    end)

    local prev = Button(f, "< Prev", 70)
    prev:SetPoint("BOTTOMLEFT", 18, 14)
    prev:SetScript("OnClick", function() ShowPage(copyPage - 1) end)

    local nxt = Button(f, "Next >", 70)
    nxt:SetPoint("LEFT", prev, "RIGHT", 6, 0)
    nxt:SetScript("OnClick", function() ShowPage(copyPage + 1) end)

    local sel = Button(f, "Select all", 90)
    sel:SetPoint("LEFT", nxt, "RIGHT", 12, 0)
    sel:SetScript("OnClick", function()
        copyEdit:SetFocus()
        copyEdit:HighlightText()
    end)

    local close = Button(f, "Close", 80)
    close:SetPoint("BOTTOMRIGHT", -18, 14)
    close:SetScript("OnClick", function() f:Hide() end)

    f:Hide()
end

function ShowCopy(src)
    CreateCopyFrame()
    BuildPages(src or {})
    ShowPage(1)
    copyFrame:Show()
end

----------------------------------------------------------------------------
-- Cross-account whisper test (run with both WOW1 and WOW12 logged in).
--
-- The sender string CHAT_MSG_ADDON hands us is what Core.lua's PeerShort()
-- parses into a watermark key. With surnames in play we need to see it
-- verbatim: does it carry the surname, the realm, both, or neither?
----------------------------------------------------------------------------

local WPREFIX = "ASPROBE"
local wire = CreateFrame("Frame")

-- The wire log is kept separately: Run() wipes `lines`, and a PONG can land
-- minutes after the sweep that prompted it.
local function WireRecord(s)
    AltStableProbeDB.wireLog = AltStableProbeDB.wireLog or {}
    local entry = date("%H:%M:%S") .. "  " .. s
    AltStableProbeDB.wireLog[#AltStableProbeDB.wireLog + 1] = entry
    lines[#lines + 1] = entry
    Out(s)
end

-- Send the same ping to every plausible spelling of the target, each tagged
-- with the form that produced it. Whichever tags come back as PONG are the
-- forms that actually route - no guessing about space vs hyphen.
local function SendPing(target)
    if not C_ChatInfo or not C_ChatInfo.SendAddonMessage then
        Out("|cffff5555C_ChatInfo.SendAddonMessage absent|r"); return
    end
    local me = (UnitFullName and UnitFullName("player")) or UnitName("player") or "?"

    local variants, seen = {}, {}
    local function add(label, t)
        if t and t ~= "" and not seen[t] then
            seen[t] = true
            variants[#variants + 1] = { label = label, target = t }
        end
    end
    add("as-typed", target)
    add("space",      (target:gsub("%-", " ")))
    add("hyphen",     (target:gsub(" ", "-")))
    add("first-only", target:match("^(%S+)"))

    WireRecord(("whisper test -> %d target form(s), 0.4s apart"):format(#variants))
    for idx, v in ipairs(variants) do
        local function fire()
            local ok, err = pcall(C_ChatInfo.SendAddonMessage, WPREFIX,
                "PING|" .. v.label .. "|" .. tostring(me), "WHISPER", v.target)
            WireRecord(("  [%-10s] %-28s %s"):format(v.label, v.target,
                ok and "sent" or ("ERROR: " .. tostring(err))))
        end
        if C_Timer and C_Timer.After and idx > 1 then
            C_Timer.After((idx - 1) * 0.4, fire)
        else
            fire()
        end
    end
    WireRecord("  >> 'sent' only means the client accepted it, NOT that it was delivered.")
    WireRecord("  >> A PONG line naming a form is the proof that form routes.")
end

wire:RegisterEvent("CHAT_MSG_ADDON")
pcall(wire.RegisterEvent, wire, "BANKFRAME_OPENED")
wire:SetScript("OnEvent", function(_, event, prefix, text, channel, sender)
    if event == "BANKFRAME_OPENED" then
        -- Run one frame later: the bank bags are not populated at the instant
        -- the event fires, which is why a manual "/asprobe bank" kept coming
        -- back empty.
        if C_Timer and C_Timer.After then
            C_Timer.After(0.25, function()
                Out("|cffffd100bank opened - auto-capturing containers + bank tabs|r")
                lines = {}
                Record("AltStableProbe (bank auto-capture)  " .. date("%Y-%m-%d %H:%M:%S"))
                P.containers()
                P.bank()
                AltStableProbeDB.lines = lines
                ShowCopy(lines)
            end)
        end
        return
    end
    if event ~= "CHAT_MSG_ADDON" then return end
    if prefix ~= WPREFIX then return end
    -- `sender` verbatim is the whole point of this test.
    WireRecord(("|cff55ff55RECV|r prefix=%s channel=%s sender=%s text=%s"):format(
        tostring(prefix), tostring(channel), ValStr(sender, 1), ValStr(text, 1)))
    local kind, label = tostring(text):match("^(%u+)|([^|]*)")
    if kind == "PING" then
        local me = (UnitFullName and UnitFullName("player")) or UnitName("player") or "?"
        -- Reply to `sender` verbatim. If that string does not itself route, the
        -- PONG never arrives - which is also a result worth having.
        pcall(C_ChatInfo.SendAddonMessage, WPREFIX,
            "PONG|" .. tostring(label) .. "|" .. tostring(me), "WHISPER", sender)
        WireRecord(("  got PING (form=%s), replied PONG to sender verbatim"):format(tostring(label)))
    elseif kind == "PONG" then
        WireRecord(("  |cff55ff55ROUND-TRIP OK|r  target form '%s' routes, and the sender string replies"):format(tostring(label)))
    end
end)
if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
    pcall(C_ChatInfo.RegisterAddonMessagePrefix, WPREFIX)
end

SLASH_ASPROBE1 = "/asprobe"
SlashCmdList["ASPROBE"] = function(msg)
    msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local cmd, arg = msg:match("^(%S+)%s*(.*)$")
    cmd = (cmd or ""):lower()
    if cmd == "whisper" then
        if arg == "" then
            Out("usage: /asprobe whisper <CharacterName>   (log the other account in first)")
        else
            SendPing(arg)
        end
        return
    end
    msg = msg:lower()
    if msg == "copy" then
        local src = (#lines > 0) and lines or (AltStableProbeDB.lines or {})
        ShowCopy(src)
        return
    end
    if msg == "dump" then
        for _, l in ipairs(AltStableProbeDB.lines or {}) do Out(l) end
        local w = AltStableProbeDB.wireLog or {}
        if #w > 0 then
            Out("|cffffd100-- wire log --|r")
            for _, l in ipairs(w) do Out(l) end
        end
        return
    end
    if msg == "bank" then
        Out("running container section - make sure the bank window is OPEN")
        Run("containers")
        return
    end
    if msg ~= "" and not P[msg] then
        Out("unknown section '" .. msg .. "'. try: " .. table.concat(ORDER, " ") .. " bank whisper copy dump")
        return
    end
    Run(msg ~= "" and msg or nil)
end

----------------------------------------------------------------------------
-- SavedVariables persistence probe.
--
-- Decisive test for "the client writes SavedVariables but never reads them
-- back". A counter that never rises above 1 means the load is not happening;
-- a counter that climbs means it is.
--
-- Deliberately read at PLAYER_LOGIN rather than file scope: SavedVariables are
-- not guaranteed to be populated while an addon's files are still executing.
----------------------------------------------------------------------------

local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_LOGIN")
boot:SetScript("OnEvent", function()
    -- Account-wide and per-character are SEPARATE mechanisms; test them
    -- independently. If only one is broken that is a real workaround for any
    -- addon whose state does not need sharing across characters.
    local prev        = AltStableProbeDB.loadCount
    local prevChar    = AltStableProbeCharDB.loadCount
    local prevMachine = AltStableProbeMachineDB.loadCount

    if prev == nil then
        Out("|cffff5555SavedVariables (account)|r first ever run - not loaded")
    else
        Out(("|cff55ff55SavedVariables (account) LOADED|r - previous loadCount=%s")
            :format(tostring(prev)))
    end

    if prevChar == nil then
        Out("|cffff5555SavedVariablesPerCharacter|r first ever run - not loaded")
    else
        Out(("|cff55ff55SavedVariablesPerCharacter LOADED|r - previous loadCount=%s")
            :format(tostring(prevChar)))
    end

    if prevMachine == nil then
        Out("|cffff5555SavedVariablesMachine|r first ever run - not loaded")
    else
        Out(("|cff55ff55SavedVariablesMachine LOADED|r - previous loadCount=%s, last written on build %s")
            :format(tostring(prevMachine), tostring(AltStableProbeMachineDB.lastBuild)))
    end

    AltStableProbeDB.loadCount = (tonumber(prev) or 0) + 1
    AltStableProbeDB.lastLoadStamp = date("%Y-%m-%d %H:%M:%S")
    AltStableProbeCharDB.loadCount = (tonumber(prevChar) or 0) + 1
    AltStableProbeCharDB.lastLoadStamp = date("%Y-%m-%d %H:%M:%S")
    AltStableProbeMachineDB.loadCount = (tonumber(prevMachine) or 0) + 1
    AltStableProbeMachineDB.lastLoadStamp = date("%Y-%m-%d %H:%M:%S")
    AltStableProbeMachineDB.lastBuild = select(2, GetBuildInfo())

    -- This line used to say "reload and both must go up". That instruction is
    -- how three separate tests concluded a store persisted when it did not:
    -- /reload keeps the client process alive, so a value survives in memory and
    -- the counter climbs without anything touching the disk. Only a count that
    -- climbs across a FULL EXIT proves persistence - and the file on disk is
    -- the evidence, not this chat line.
    Out(("account #%d / per-character #%d / machine #%d - only a FULL EXIT and relaunch "
        .. "counts; /reload proves nothing"):format(
        AltStableProbeDB.loadCount, AltStableProbeCharDB.loadCount,
        AltStableProbeMachineDB.loadCount))

    -- Rule out a LATE load: if the client executes a SavedVariables file after
    -- PLAYER_LOGIN, it REPLACES the global table. Different bug, different
    -- workaround, so it is worth distinguishing - for every store, not just the
    -- account one.
    --
    -- Detected by identity, not by count. Every session starts at loadCount = 1
    -- on this client, so a late load of the file just written reads back as 1 -
    -- indistinguishable from the probe's own 1, and a `now > 1` check can never
    -- fire. A per-session mark on each table can: a replaced table has lost it.
    local mark = tostring(GetTime()) .. ":" .. tostring(math.random(1, 1000000000))
    local STORES = {
        { label = "account",       global = "AltStableProbeDB",        atLogin = prev },
        { label = "per-character", global = "AltStableProbeCharDB",    atLogin = prevChar },
        { label = "machine",       global = "AltStableProbeMachineDB", atLogin = prevMachine },
    }
    for _, store in ipairs(STORES) do
        -- Resolve through _G each time: a late load swaps the global itself.
        local t = _G[store.global]
        if type(t) == "table" then t.sessionMark = mark end
    end

    local function Replaced(store)
        local t = _G[store.global]
        return type(t) == "table" and t.sessionMark ~= mark
    end

    if C_Timer and C_Timer.After then
        for _, delay in ipairs({ 5, 15, 30 }) do
            C_Timer.After(delay, function()
                for _, store in ipairs(STORES) do
                    if store.atLogin == nil and not store.reportedLate and Replaced(store) then
                        store.reportedLate = true
                        Out(("|cff55ff55%s SV arrived LATE|r - replaced after %ds, loadCount=%s")
                            :format(store.label, delay, tostring(_G[store.global].loadCount)))
                    end
                end
            end)
        end
        C_Timer.After(31, function()
            local never = {}
            for _, store in ipairs(STORES) do
                if store.atLogin == nil and not Replaced(store) then
                    never[#never + 1] = store.label
                end
            end
            if #never > 0 then
                Out(("|cffff5555SV never loaded|r - still nothing after 30s for: %s. "
                    .. "The client writes these files but does not read them back.")
                    :format(table.concat(never, ", ")))
            end
        end)
    end

    Out("run |cffffd100/asprobe|r for everything, or |cffffd100/asprobe bank|r with the bank open.")
end)
