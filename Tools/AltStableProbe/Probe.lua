--[[
    AltStableProbe — answers the open API questions for the WoW: Forever port.

    This is a throwaway diagnostic, not part of AltStable. It never ships (it
    lives under Tools/, which .pkgmeta ignores).

    The point is NOT "does this function exist" — the captured API dump already
    answers that. The point is the *contract*: argument shape, return ORDER, and
    whether the underlying system is actually wired up on a Vanilla-content
    client. A tuple that shifts by one position yields empty data with no error,
    which is the failure mode this addon exists to prevent.

    A ForeverProbe module (C:\Projects\WoW\ForeverProbe, docs/GUIDE.md, #240):
    every line goes to the /fp console and to AltStableProbeDB.log, never to
    chat. The copy window it used to open is gone: in the console, Freeze, then
    Select all, then Ctrl+C.

    Usage in-game (/fp as alone lists every command):
        /fp as all              run every section
        /fp as bank             containers + bank tabs, with the bank window OPEN
        /fp as <section>        client|savedvariables|identity|skills|prof|rep|items|containers|tooltip|instances|events
        /fp as whisper <Name>   send a cross-account addon-message ping
        /fp as enchant          each equipped slot's enchant: link id + tooltip lines (#94)
        /fp as channel|bnet|pet|model|recipes|scene|icon ...   the other files
        /fp as clear            empty the saved log
        /fp steps as check      the guided in-game check of this module (#240)

    Results land in AltStableProbeDB so they can be read off disk after a /reload:
        _forever_\WTF\Account\<id>\SavedVariables\AltStableProbe.lua
]]

local ADDON, NS = ...
local MAX_LOG = 3000

local Probe = ForeverProbe:Module("AltStableProbe", { api = 1, cmd = "as" })
NS.Probe = Probe   -- the other files' handle on it

local function Say(s) Probe:Say(s) end

local function Section(name)
    Say("|cffffd100== " .. name .. " ==|r")
end

-- One value as text, tables included (structs are the whole reason this
-- exists). Describe is this probe's old ValStr, moved into the host.
local Describe = Probe.Describe

-- The return tuple with positions preserved, INCLUDING trailing nils: the
-- host's Call is this probe's old one.
local function Call(label, fn, ...) Probe:Call(label, fn, ...) end

local function Has(path, v)
    Say(path .. "  " .. (type(v) == "nil" and "|cffff5555ABSENT|r" or ("present (" .. type(v) .. ")")))
end

local function Value(label, v) Say(label .. "  " .. Describe(v, 1)) end

----------------------------------------------------------------------------
-- Sections
----------------------------------------------------------------------------

local P = {}

-- Where the SavedVariables counts live now that login is silent about them.
--
-- They are worth having when somebody is investigating persistence, which is
-- what this section is for, and worth nothing as a line at every login.
function P.savedvariables()
    Section("savedvariables  (#23 - only a FULL EXIT proves anything)")
    Value("account loadCount", AltStableProbeDB and AltStableProbeDB.loadCount)
    Value("  last load", AltStableProbeDB and AltStableProbeDB.lastLoadStamp)
    Value("per-character loadCount", AltStableProbeCharDB and AltStableProbeCharDB.loadCount)
    Value("  last load", AltStableProbeCharDB and AltStableProbeCharDB.lastLoadStamp)
    -- Stated rather than measured again: the answer is on disk and does not
    -- change between sessions.
    Say("machine scope  NEVER WRITTEN on this client - no file under WTF (measured)")
    Say("A count only proves persistence if it climbs across a FULL EXIT and")
    Say("relaunch. /reload keeps the process alive, so the value survives in")
    Say("memory and the counter climbs without anything touching the disk -")
    Say("which is how three separate tests concluded a store persisted when")
    Say("it did not.")
end

function P.client()
    Section("client")
    Call("GetBuildInfo()", GetBuildInfo)
    Value("WOW_PROJECT_ID", WOW_PROJECT_ID)
    Value("WOW_PROJECT_MAINLINE", WOW_PROJECT_MAINLINE)
    Value("MAX_PLAYER_LEVEL (level cap)", MAX_PLAYER_LEVEL)
    Call("GetMaxPlayerLevel()", GetMaxPlayerLevel)
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
-- routes to a target containing a space. That is what /fp as whisper answers.
function P.identity()
    Section("identity  (SURNAMES - first names are no longer unique)")
    Call("UnitName('player')", UnitName, "player")
    Call("UnitFullName('player')", UnitFullName, "player")
    Call("UnitNameUnmodified('player')", UnitNameUnmodified, "player")
    Call("GetUnitName('player', false)", GetUnitName, "player", false)
    Call("GetUnitName('player', true)", GetUnitName, "player", true)
    Call("UnitGUID('player')", UnitGUID, "player")
    local guid = UnitGUID and UnitGUID("player")
    if guid then
        Call("UnitNameFromGUID(guid)", UnitNameFromGUID, guid)
        Call("GetPlayerInfoByGUID(guid)", GetPlayerInfoByGUID, guid)
    end
    Call("GetRealmName()", GetRealmName)
    Call("GetNormalizedRealmName()", GetNormalizedRealmName)
    if type(C_PlayerInfo) == "table" then
        Call("C_PlayerInfo.ShouldDisplaySurname()", C_PlayerInfo.ShouldDisplaySurname)
        Call("C_PlayerInfo.GetName('player')", C_PlayerInfo.GetName, "player")
        Call("C_PlayerInfo.GetPlayerCharacterData()", C_PlayerInfo.GetPlayerCharacterData)
    end
    -- Anything we can see about other players tells us what a whisper target
    -- and an incoming CHAT_MSG_ADDON sender look like.
    for _, unit in ipairs({ "target", "party1", "party2" }) do
        if UnitExists and UnitExists(unit) and UnitIsPlayer and UnitIsPlayer(unit) then
            Call("UnitName('" .. unit .. "')", UnitName, unit)
            Call("UnitFullName('" .. unit .. "')", UnitFullName, unit)
        end
    end
    Say("  >> compare the above against this character's WTF folder name")
    Say("  >> if the surname appears in NONE of these, sync must key on GUID, not name")
    Say("  >> to check whisper routing: /fp as whisper <FirstName> and see if it lands")
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
    if n > 20 then Say("  ... " .. (n - 20) .. " more skill lines") end
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
    if n > 12 then Say("  ... " .. (n - 12) .. " more factions") end
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
    Section("containers  (run '/fp as bank' with the BANK WINDOW OPEN)")
    Has("C_Container", C_Container)
    if type(C_Container) ~= "table" then return end
    -- Enum.BagIndex is the authoritative container-id map. Forever remapped
    -- these (bag -1 is the Keyring here, not the bank), so sweep what the enum
    -- names plus a wide numeric net rather than trusting Classic's constants.
    if Enum and Enum.BagIndex then
        Say("Enum.BagIndex: " .. Describe(Enum.BagIndex, 2))
    else
        Say("Enum.BagIndex ABSENT")
    end
    local ids, seen = {}, {}
    if Enum and Enum.BagIndex then
        for _, v in pairs(Enum.BagIndex) do
            if type(v) == "number" and not seen[v] then seen[v] = true; ids[#ids + 1] = v end
        end
    end
    for n = -10, 40 do if not seen[n] then seen[n] = true; ids[#ids + 1] = n end end
    table.sort(ids)

    Say("bag id -> slots / name")
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
            Say(("  bag %-4d slots=%-3d name=%s"):format(bag, slots, Describe(name, 1)))
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
    Say("BankFrame:IsShown()  " ..
        ((BankFrame and BankFrame.IsShown) and tostring(BankFrame:IsShown()) or "no BankFrame"))
    if Enum and Enum.BankType then
        Say("Enum.BankType  " .. Describe(Enum.BankType, 2))
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
    Value("NUM_BANKGENERIC_SLOTS", NUM_BANKGENERIC_SLOTS)
    Value("NUM_BAG_SLOTS", NUM_BAG_SLOTS)
    Value("NUM_BANKBAGSLOTS", NUM_BANKBAGSLOTS)
end

-- Open question. With the bank demonstrably open (BankFrame:IsShown() == true)
-- NO container id in -5..20 reported any slots, yet the bank shows 48 slots
-- plus 8 purchasable bag slots. So Classic's BANK_IDS = { -1, 5..11 } is wrong
-- here, and -1 is the Keyring. Either the ids moved, or the bank is reached
-- through C_Bank rather than as plain containers. Enum.BagIndex settles it.
function P.bank()
    Section("bank  (open the bank first)")
    Say("BankFrame:IsShown()  " ..
        ((BankFrame and BankFrame.IsShown) and tostring(BankFrame:IsShown()) or "no BankFrame"))
    if not (Enum and Enum.BankType) then Say("Enum.BankType ABSENT"); return end
    Say("Enum.BankType  " .. Describe(Enum.BankType, 2))
    if type(C_Bank) ~= "table" then Say("C_Bank ABSENT"); return end

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
    Say("GameTooltip:HookScript('OnTooltipSetItem')  " ..
        (okHook and "installed without error" or ("|cffff5555ERROR: " .. tostring(errHook) .. "|r")))

    Has("TooltipDataProcessor", TooltipDataProcessor)
    Has("C_TooltipInfo", C_TooltipInfo)
    if type(TooltipDataProcessor) == "table" and type(TooltipDataProcessor.AddTooltipPostCall) == "function"
       and Enum and Enum.TooltipDataType and Enum.TooltipDataType.Item then
        local ok, err = pcall(TooltipDataProcessor.AddTooltipPostCall, Enum.TooltipDataType.Item,
            function() fired.tdp = true end)
        Say("TooltipDataProcessor.AddTooltipPostCall  " ..
            (ok and "installed without error" or ("ERROR: " .. tostring(err))))
    end

    -- Now actually drive a tooltip and see which path fires.
    GameTooltip:SetOwner(UIParent, "ANCHOR_NONE")
    local okSet, errSet = pcall(function() GameTooltip:SetHyperlink("item:6948") end)
    Say("GameTooltip:SetHyperlink('item:6948')  " .. (okSet and "ok" or ("ERROR: " .. tostring(errSet))))
    GameTooltip:Hide()

    local function report(when)
        Say(("  fired %s  OnTooltipSetItem=%s  TooltipDataProcessor=%s"):format(
            when, tostring(fired.hook), tostring(fired.tdp)))
        if not fired.hook then
            Say("  |cffff5555>> OnTooltipSetItem did NOT fire - Warband's tooltip must move to TooltipDataProcessor|r")
        else
            Say("  |cff55ff55>> OnTooltipSetItem fires - Warband's existing hook is safe|r")
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
        Say("  no lockouts right now - re-run after saving to a raid to check encounter order")
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
            Say(("  |cffff5555%-34s REJECTED: %s|r"):format(ev, tostring(err)))
        end
    end
    if #bad == 0 then
        Say("  all " .. #want .. " events registered cleanly")
    else
        Say("  |cffff5555" .. #bad .. " of " .. #want .. " events rejected (above)|r")
    end
    f:UnregisterAllEvents()
end

----------------------------------------------------------------------------
-- Driver
----------------------------------------------------------------------------

local ORDER = { "client", "savedvariables", "identity", "skills", "prof", "rep", "items", "containers", "bank", "tooltip", "instances", "events" }

local function Run(which)
    Say("AltStableProbe " .. (which or "all") .. "  " .. date("%Y-%m-%d %H:%M:%S"))
    if which then
        P[which]()
    else
        for _, k in ipairs(ORDER) do P[k]() end
    end
    Say("|cff55ff55done|r - saved to AltStableProbeDB.log (written on logout/reload)")
end

-- The bank's sections together, the way the BANKFRAME_OPENED capture runs
-- them: the bank tabs answer only with the window open.
local function Bank()
    Say("AltStableProbe bank  " .. date("%Y-%m-%d %H:%M:%S"))
    P.containers()
    P.bank()
end

Probe:Command("all", function() Run(nil) end, "every section below, in order")
local HELP = {
    client = "build, project, level cap, XP",
    savedvariables = "the load counters (#23)",
    identity = "names, surnames, GUID, realm",
    skills = "C_SkillInfo skill lines",
    prof = "GetProfessions / GetProfessionInfo",
    rep = "C_Reputation factions",
    items = "C_Item tuples, cache misses, stats",
    containers = "every container id and its first item",
    tooltip = "OnTooltipSetItem vs TooltipDataProcessor",
    instances = "saved lockouts and encounter order",
    events = "which events this client rejects",
}
for _, k in ipairs(ORDER) do
    if k ~= "bank" then
        local section = k
        Probe:Command(section, function() Run(section) end, HELP[section])
    end
end
Probe:Command("bank", Bank, "containers + bank tabs: open the bank window first")
Probe:Command("clear", function() Probe:ClearLog(); Say("log cleared") end, "empty the saved log")

----------------------------------------------------------------------------
-- Cross-account whisper test (run with both WOW1 and WOW12 logged in).
--
-- The sender string CHAT_MSG_ADDON hands us is what Core.lua's PeerShort()
-- parses into a watermark key. With surnames in play we need to see it
-- verbatim: does it carry the surname, the realm, both, or neither?
----------------------------------------------------------------------------

local WPREFIX = "ASPROBE"
local wire = CreateFrame("Frame")

-- The wire log is kept apart from the module log: it spans sessions and both
-- accounts' files, and Tools/AltStableProbe/read-wirelog.py reads it straight
-- from WTF\...\AltStableProbe.lua. Its lines keep their shape for that.
local function WireRecord(s)
    AltStableProbeDB.wireLog = AltStableProbeDB.wireLog or {}
    -- Who wrote it, on every line: two characters of one account share this
    -- file.
    local who = (AltStable and AltStable.API and AltStable.API.PlayerFullName
        and AltStable.API.PlayerFullName()) or (UnitName and UnitName("player")) or "?"
    local entry = date("%Y-%m-%d %H:%M:%S") .. "  [" .. who .. "]  " .. s
    AltStableProbeDB.wireLog[#AltStableProbeDB.wireLog + 1] = entry
    Say(s)
end
NS.WireRecord = WireRecord     -- Channel.lua and BNet.lua log through it

-- Send the same ping to every plausible spelling of the target, each tagged
-- with the form that produced it. Whichever tags come back as PONG are the
-- forms that actually route - no guessing about space vs hyphen.
local function SendPing(target)
    if not C_ChatInfo or not C_ChatInfo.SendAddonMessage then
        Say("|cffff5555C_ChatInfo.SendAddonMessage absent|r"); return
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
    add("first-only", target:match("^(%S+)"))
    -- Across rulesets the bare name does not route (measured, 70124: "No player
    -- named" both ways, both online). In other versions "Name-Server" does, so
    -- try the name with every server suffix the client knows: the auto-complete
    -- list (logged - is it the rulesets?), our own, and the two measured ones.
    -- The old "hyphen" form turned "First Surname" into "First-Surname": with
    -- surnames that is a different, wrong name, so it is gone.
    if not target:find("-", 1, true) then
        local realms, seenRealm = {}, {}
        local function addRealm(r)
            if type(r) == "string" and r ~= "" and not seenRealm[r] then
                seenRealm[r] = true
                realms[#realms + 1] = r
            end
        end
        local auto = C_AutoComplete and C_AutoComplete.GetAutoCompleteRealms
            and { pcall(C_AutoComplete.GetAutoCompleteRealms) }
        if auto then
            WireRecord("  GetAutoCompleteRealms -> " .. Describe(auto[2], 2))
            if auto[1] and type(auto[2]) == "table" then
                for _, r in ipairs(auto[2]) do addRealm(r) end
            end
        else
            WireRecord("  C_AutoComplete.GetAutoCompleteRealms absent")
        end
        addRealm(GetNormalizedRealmName and GetNormalizedRealmName())
        addRealm("ClassicBetaPvE")
        addRealm("ClassicBetaPvP2")
        for _, r in ipairs(realms) do add("+" .. r, target .. "-" .. r) end
    end

    WireRecord(("whisper test -> %d target form(s), 0.4s apart"):format(#variants))
    for idx, v in ipairs(variants) do
        local function fire()
            local ok, err = pcall(C_ChatInfo.SendAddonMessage, WPREFIX,
                "PING|" .. v.label .. "|" .. tostring(me), "WHISPER", v.target)
            WireRecord(("  [%-16s] %-40s %s"):format(v.label, v.target,
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

Probe:Command("whisper", function(arg)
    if arg == "" then
        Say("usage: /fp as whisper <CharacterName>   (log the other account in first)")
    else
        SendPing(arg)
    end
end, "<Name>: a cross-account addon-message ping, every spelling of the name")

Probe:RegisterEvents(wire, { "CHAT_MSG_ADDON", "BANKFRAME_OPENED" })
wire:SetScript("OnEvent", function(_, event, prefix, text, channel, sender)
    if event == "BANKFRAME_OPENED" then
        -- Run one frame later: the bank bags are not populated at the instant
        -- the event fires, which is why a manual bank run kept coming back
        -- empty.
        if C_Timer and C_Timer.After then
            C_Timer.After(0.25, function()
                Say("|cffffd100bank opened - auto-capturing containers + bank tabs|r")
                Bank()
            end)
        end
        return
    end
    if event ~= "CHAT_MSG_ADDON" then return end
    if prefix ~= WPREFIX then return end
    -- Only the whisper test's own kinds: Channel.lua shares the prefix and logs
    -- its pings itself (review of #141 - every channel echo was logged twice).
    local kindOnly = tostring(text):match("^(%u+)|")
    if kindOnly ~= "PING" and kindOnly ~= "PONG" then return end
    -- `sender` verbatim is the whole point of this test.
    WireRecord(("|cff55ff55RECV|r prefix=%s channel=%s sender=%s text=%s"):format(
        tostring(prefix), tostring(channel), Describe(sender, 1), Describe(text, 1)))
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

----------------------------------------------------------------------------
-- Saved tables, and the SavedVariables persistence canary.
--
-- The tables are adopted at our own ADDON_LOADED, never made at file scope:
-- the client loads SavedVariables after the addon's files, so a table made
-- here would be replaced (GUIDE.md section 1).
--
-- The canary is the decisive test for "the client writes SavedVariables but
-- never reads them back". A counter that never rises above 1 means the load is
-- not happening; a counter that climbs means it is. Read at PLAYER_LOGIN.
----------------------------------------------------------------------------

local function Adopt()
    Probe:Ready()
    if type(AltStableProbeDB) ~= "table" then AltStableProbeDB = {} end
    if type(AltStableProbeCharDB) ~= "table" then AltStableProbeCharDB = {} end
    -- Machine scope lands in the TOP-LEVEL WTF\SavedVariables\ folder, not
    -- under WTF\Account\<id>\. On 1.60.1.69913 the answer was no: the client
    -- never writes a third-party machine-scope variable at all. Kept so each
    -- new build can be checked the same way.
    if type(AltStableProbeMachineDB) ~= "table" then AltStableProbeMachineDB = {} end
    local db = AltStableProbeDB
    if type(db.log) ~= "table" then db.log = {} end
    Probe:UseLog(db.log, MAX_LOG)
    -- Retired with the copy window (#240): the last run's lines, which the
    -- log now holds. Left on disk, an old run reads as a fresh one.
    db.lines, db.lastRun, db.build, db.enchants = nil, nil, nil, nil
    Say("loaded. /fp as for the commands")
end

local function Canary()
    -- Account-wide and per-character are SEPARATE mechanisms; test them
    -- independently. If only one is broken that is a real workaround for any
    -- addon whose state does not need sharing across characters.
    local prev     = AltStableProbeDB.loadCount
    local prevChar = AltStableProbeCharDB.loadCount

    -- SILENT WHEN THEY LOAD, which since #23 was fixed on 1.60.1.70009 is
    -- every session. A status line that says "still fine" every session is
    -- one nobody reads, which is how the day it says something else gets
    -- missed. The counts are on demand under /fp as savedvariables.
    --
    -- Machine scope is not reported: it is never written on this client
    -- (measured - no file anywhere under WTF, see docs/forever-api-notes.md),
    -- so its line was a "not loaded" at every login, a settled answer
    -- reported as a fault.
    if prev == nil then
        Say("|cffff5555SavedVariables (account)|r did not load - first ever run, or #23 has come back")
    end
    if prevChar == nil then
        Say("|cffff5555SavedVariablesPerCharacter|r did not load - first ever run, or #23 has come back")
    end

    AltStableProbeDB.loadCount = (tonumber(prev) or 0) + 1
    AltStableProbeDB.lastLoadStamp = date("%Y-%m-%d %H:%M:%S")
    AltStableProbeCharDB.loadCount = (tonumber(prevChar) or 0) + 1
    AltStableProbeCharDB.lastLoadStamp = date("%Y-%m-%d %H:%M:%S")

    -- Rule out a LATE load: if the client executes a SavedVariables file after
    -- PLAYER_LOGIN, it REPLACES the global table. Different bug, different
    -- workaround, so it is worth distinguishing - for every store.
    --
    -- Detected by identity, not by count. Every session starts at loadCount = 1
    -- on this client, so a late load of the file just written reads back as 1 -
    -- indistinguishable from the probe's own 1. A per-session mark on each
    -- table can: a replaced table has lost it.
    --
    -- #23 is fixed on 1.60.1.70009, but this is a beta client and everything
    -- the addon persists rides on these two scopes. Silent while they work,
    -- loud the day a patch breaks them again - which is what a canary is for.
    local mark = tostring(GetTime()) .. ":" .. tostring(math.random(1, 1000000000))
    local STORES = {
        { label = "account",       global = "AltStableProbeDB",     atLogin = prev },
        { label = "per-character", global = "AltStableProbeCharDB", atLogin = prevChar },
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
                        Say(("|cff55ff55%s SV arrived LATE|r - replaced after %ds, loadCount=%s")
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
            -- Say only what was observed. "Never loaded" covers two different
            -- failures - a file written but not read, and a file never written
            -- at all - and nothing in-game can tell them apart, because the
            -- global is nil either way. Only the disk can, so this points
            -- there rather than guessing which one it is.
            if #never > 0 then
                Say(("|cffff5555SV never loaded|r - still nothing after 30s for: %s. "
                    .. "That only says they did not LOAD: check the files under WTF on disk "
                    .. "to tell 'written but not read' from 'never written'.")
                    :format(table.concat(never, ", ")))
            end
        end)
    end
end

----------------------------------------------------------------------------
-- /fp steps as check - the in-game check of the move onto ForeverProbe (#240):
-- what the stubs cannot show (the viewers' template frames, the console in
-- the way of a cursor reading), as answers saved for a session to read.
----------------------------------------------------------------------------

local function Command(line) SlashCmdList.FOREVERPROBE("as " .. line) end

Probe:Steps("check", {
    title = "AltStableProbe on ForeverProbe (#240)",
    { text = "Every section runs into the console.", auto = true,
      run = function() Run(nil); return #Probe.log end },
    { text = "Press Run: the model viewer opens.", button = "Run", run = function() Command("model") end },
    { text = "Did the model viewer open on that first press, with two panes?", ask = true, screenshot = "model viewer" },
    { text = "Close it. Press Run: the scene viewer opens.", button = "Run", run = function() Command("scene") end },
    { text = "Did the scene viewer open on that first press?", ask = true, screenshot = "scene viewer" },
    { text = "Close it. The icon reading is its own procedure: /fp steps as icon.", },
    { text = "Type /reload (or press Reload now) to save the results.", reload = true },
})

-- /fp steps as icon - a cursor reading where it is most wanted: on the
-- AltStable sheet, which hides the game UI. The countdown is the probe's own
-- banner, and the console and this panel stay up over the sheet since
-- ForeverProbe#7; the reading puts them away (Probe:HideWindows) and brings
-- them back. One question each: the first check asked two at once and got a
-- "no" that could be either.
Probe:Steps("icon", {
    title = "/fp as icon on the AltStable sheet",
    { text = "Open the AltStable sheet (/alts). Is this panel still in view over it?", ask = true },
    { text = "Press Run, then within 5 seconds hover an icon on the sheet (a side tab) and hold "
          .. "still until the reading is done.",
      button = "Run", run = function() Command("icon") end },
    { text = "While you waited: did this panel go away, and a countdown (\"hover the thing now\", "
          .. "then 4... 3... 2... 1..., then \"read: ...\") show near the top of the screen?", ask = true },
    { text = "Is the /fp console open now, listing the icon's textures (lines tagged [icon])?", ask = true },
    { text = "Type /reload (or press Reload now) to save the results.", reload = true },
})

----------------------------------------------------------------------------
-- /fp steps as audit - the audit's in-game part (#279, docs/AUDIT.md section
-- 5): what the scan's sources answer 2 s after PLAYER_LOGIN (the scan's
-- moment), and a Warband round trip with the owner's other account, with a
-- full exit. The reading is taken at every login while the probe is deployed,
-- so the procedure can show it whenever it is started.
----------------------------------------------------------------------------

local function LoginReading()
    local first, second = UnitName("player")
    local r = {
        at = time(), build = select(2, GetBuildInfo()),
        name = first, surname = second,
        guild = GetGuildInfo("player"),
        skillLines = C_SkillInfo and C_SkillInfo.GetNumSkillLines and C_SkillInfo.GetNumSkillLines(),
        displayID = C_PlayerInfo and C_PlayerInfo.GetDisplayID and C_PlayerInfo.GetDisplayID(),
    }
    AltStableProbeDB.audit = AltStableProbeDB.audit or {}
    AltStableProbeDB.audit.login = r
    Say(("[audit] login+2s: name %s / %s, guild %s, skill lines %s, display %s"):format(
        Describe(r.name), Describe(r.surname), Describe(r.guild), Describe(r.skillLines), Describe(r.displayID)))
    return r
end

local function Reading() return type(AltStableProbeDB.audit) == "table" and AltStableProbeDB.audit.login or nil end

-- The owner's yes/no on step i of this procedure, from the host's record;
-- nil when unanswered or unsure, which a check reports as unverified.
local function Answered(i)
    local fp = rawget(_G, "ForeverProbeDB")
    local recs = type(fp) == "table" and type(fp.steps) == "table" and type(fp.steps.records) == "table" and fp.steps.records
    local r = recs and recs["AltStableProbe/audit"]
    local res = type(r) == "table" and type(r.results) == "table" and r.results[i]
    if type(res) ~= "table" then return nil end
    if res.status == "yes" then return true elseif res.status == "no" then return false end
    return nil
end

local function MyWarband()
    local guid = UnitGUID("player")
    local wb = rawget(_G, "AltStableWarbandDB")
    return guid and type(wb) == "table" and wb[guid] or nil
end
local function Count(map) local n = 0; for _, c in pairs(map or {}) do n = n + c end; return n end
local function Inventory()
    local wb = MyWarband()
    if not wb then return "no Warband data for this character" end
    return ("bags %d items (stamp %s), bank %d items (stamp %s)"):format(
        Count(wb.bags), tostring(wb.bagsStamp), Count(wb.bank), tostring(wb.bankStamp))
end

Probe:Steps("audit", {
    title = "Audit: the scan's sources at login, and a Warband round trip (#279)",
    rev = 1,
    { text = "The reading taken 2 s after this login, the scan's moment: name, guild, skill lines, display id.",
      auto = true,
      run = function()
          local r = Reading()
          if not r then error("no login reading yet: /reload, then start again", 0) end
          return r.name, r.surname, r.guild, r.skillLines, r.displayID
      end,
      check = function()
          local r = Reading()
          local ok = r ~= nil and type(r.skillLines) == "number" and r.skillLines > 0 and r.name ~= nil
          return ok, ("skill lines %s, name %s"):format(Describe(r and r.skillLines), Describe(r and r.name))
      end },
    { text = "Is this character in a guild?", ask = true },
    { text = "GetGuildInfo at login+2 s, against your answer.", auto = true,
      run = function() local r = Reading(); return r and r.guild end,
      check = function()
          local r = Reading()
          local inGuild = Answered(2)
          if inGuild == nil then return false, "unverified: no answer on the guild question" end
          if inGuild and (r == nil or r.guild == nil) then
              return false, "A3: in a guild, but GetGuildInfo was nil at login+2 s (the scan would write \"\")"
          end
          if not inGuild and r and r.guild ~= nil then
              return false, "not in a guild, but GetGuildInfo answered " .. Describe(r.guild)
          end
          return true, "GetGuildInfo at login+2 s agrees: " .. Describe(r and r.guild)
      end },
    { text = "Log your other account in too, with AltStable running, and open its Warband tab. "
          .. "Then press Record: this character's bags and bank as the plugin holds them here.",
      button = "Record",
      run = function()
          AltStableProbeDB.audit = AltStableProbeDB.audit or {}
          AltStableProbeDB.audit.before = Inventory()
          return Inventory()
      end },
    { text = "Move an item between two bags here and wait 10 s. On the other account, type /alts sync. "
          .. "Does its Warband tab now show this character's bags as they are now?", ask = true },
    { text = "Without opening the bank here: does the other account's Warband tab still list this "
          .. "character's bank items, the snapshot from the last bank visit?", ask = true },
    { text = "Exit the game fully on BOTH accounts (not /reload), then relaunch this one. "
          .. "The procedure resumes at login.", reload = "exit" },
    { text = "After the relaunch: this character's inventory as the plugin holds it.", auto = true,
      run = function() return Inventory() end,
      check = function()
          local wb = MyWarband()
          return wb ~= nil and wb.bags ~= nil and next(wb.bags) ~= nil, Inventory()
      end },
    { text = "Log the other account in again. Does its Warband tab still show this character's bags "
          .. "and bank as before the exit?", ask = true },
    { text = "Type /reload (or press Reload now) to save the results.", reload = true },
})

----------------------------------------------------------------------------
-- /fp steps as gear - the Glass Gear API in game (#281: AS-001 #282, AS-003
-- #283; #275 section 2). Two accounts, both running this probe (one AddOns
-- folder): the procedure runs on one, the other account acts. From each
-- login, both clients record the API's callbacks and the own-account
-- messages, so each account's log keeps its own side (GearChanged fires on
-- both after a swap).
----------------------------------------------------------------------------

local NS_PING = "AltStableProbe"
local G   -- this session's recording: AltStableProbeDB.gear, reset at each login

local function GearListen()
    local AS = rawget(_G, "AltStable")
    if type(AS) ~= "table" or type(AS.RegisterCallback) ~= "function" then
        Say("[gear] AltStable's public API is not loaded: nothing recorded")
        return
    end
    G = { at = time(), gear = {}, provenance = 0, peers = 0, messages = {} }
    AltStableProbeDB.gear = G
    AS.RegisterCallback("GearChanged", function(_, guids)
        local list = {}
        for _, g in ipairs(guids or {}) do list[#list + 1] = g end
        G.gear[#G.gear + 1] = { at = time(), guids = list }
        Say("[gear] GearChanged: " .. table.concat(list, ", "))
    end)
    AS.RegisterCallback("ProvenanceChanged", function()
        G.provenance = G.provenance + 1
        Say("[gear] ProvenanceChanged (" .. G.provenance .. " this session)")
    end)
    AS.RegisterCallback("OwnAccountPeersChanged", function()
        G.peers = G.peers + 1
        Say("[gear] OwnAccountPeersChanged (" .. G.peers .. " this session)")
    end)
    if type(AS.RegisterOwnAccountHandler) == "function" then
        AS.RegisterOwnAccountHandler(NS_PING, function(payload, sender)
            local s = type(sender) == "table" and sender or {}
            G.messages[#G.messages + 1] = { at = time(), payload = payload, name = s.name, guid = s.guid }
            Say(("[gear] own-account message %s from %s (%s)"):format(Describe(payload), Describe(s.name), Describe(s.guid)))
        end)
    end
end

-- /fp as ping: one own-account message, sent from the account that acts.
Probe:Command("ping", function()
    local AS = rawget(_G, "AltStable")
    if type(AS) ~= "table" or type(AS.SendToOwnAccounts) ~= "function" then Say("[gear] no SendToOwnAccounts"); return end
    local n, why = AS.SendToOwnAccounts(NS_PING, "ping " .. time())
    Say(("[gear] ping sent: taken by %s account(s)%s"):format(Describe(n), why and (", " .. Describe(why)) or ""))
end, "send one own-account message (for /fp steps as gear)")

local function OwnCharacters()
    local AS = rawget(_G, "AltStable")
    local kinds, other = { self = 0, ["own-account"] = 0, ["third-party"] = 0 }, nil
    for _, c in ipairs(type(AS) == "table" and AS.GetCharacters and AS.GetCharacters() or {}) do
        local k = c.provenance
        kinds[k] = (kinds[k] or 0) + 1
        if k == "own-account" and not other then other = c end
    end
    return kinds, other
end
local function Peers()
    local AS = rawget(_G, "AltStable")
    return type(AS) == "table" and AS.GetOwnAccountPeers and AS.GetOwnAccountPeers() or {}
end
-- The other account's character the swap is watched on: the first GUID a
-- GearChanged named that isn't one of ours.
local function SwappedGuid()
    local AS = rawget(_G, "AltStable")
    for i = #(G and G.gear or {}), 1, -1 do
        for _, guid in ipairs(G.gear[i].guids) do
            if AS.GetCharacterProvenance(guid) == "own-account" then return guid end
        end
    end
end
local function GearReading(guid)
    local AS = rawget(_G, "AltStable")
    local g = guid and AS.GetCharacterGear(guid)
    if not g then return nil end
    local occupied, empty, unknown, suffixed = 0, 0, 0, {}
    for _, s in pairs(g.slots or {}) do
        if s.state == "occupied" then
            occupied = occupied + 1
            -- A random suffix on Forever is a bonus id: "...:1:<bonus>" after the
            -- string's fixed fields (PUBLIC-API.md, measured on 205 links).
            if type(s.itemString) == "string" and s.itemString:match(":1:%d+$") then suffixed[#suffixed + 1] = s.itemString end
        elseif s.state == "empty" then empty = empty + 1
        else unknown = unknown + 1 end
    end
    return { capturedAt = g.capturedAt, gearAt = g.gearAt, provenance = g.provenance,
             occupied = occupied, empty = empty, unknown = unknown, suffixed = suffixed }
end

Probe:Steps("gear", {
    title = "Glass Gear API: gear strings, timestamps, provenance, the own-account channel (#281)",
    rev = 1,
    { text = "Log your other account in too (AltStable and this probe load there as well), on a character "
          .. "that has an item \"of the ...\" in its bags, NOT worn yet. Wait until both have synced, then press Record.",
      button = "Record",
      run = function()
          local kinds, other = OwnCharacters()
          local peers = Peers()
          return #peers, kinds.self, kinds["own-account"], kinds["third-party"], other and other.provenanceVia
      end,
      check = function()
          local kinds, other = OwnCharacters()
          local ok = #Peers() >= 1 and kinds.self >= 1 and kinds["own-account"] >= 1 and other ~= nil and other.provenanceVia ~= nil
          return ok, ("peers %d; self %d, own-account %d (via %s), third-party %d; ProvenanceChanged %s this session"):format(
              #Peers(), kinds.self, kinds["own-account"], Describe(other and other.provenanceVia), kinds["third-party"],
              Describe(G and G.provenance))
      end },
    { text = "On the OTHER account, equip that \"of the ...\" item (a swap). This step completes when the swap "
          .. "reaches this account (type /alts sync here if it takes long).",
      wait = function() local g = SwappedGuid(); return g ~= nil, "waiting for a GearChanged naming the other account's character" end,
      timeout = 300 },
    { text = "That character's gear as GetCharacterGear reads it here.", auto = true,
      run = function()
          local r = GearReading(SwappedGuid())
          if not r then error("no gear record for the swapped character", 0) end
          AltStableProbeDB.gear.afterSwap = r
          return r.occupied, r.empty, r.unknown, r.suffixed[1], r.capturedAt, r.gearAt
      end,
      check = function()
          local r = AltStableProbeDB.gear.afterSwap
          return r ~= nil and #r.suffixed >= 1 and r.unknown == 0 and r.gearAt ~= nil and r.capturedAt ~= nil,
              ("suffixed %s, unknown %s, empty %s"):format(Describe(r and r.suffixed[1]), Describe(r and r.unknown), Describe(r and r.empty))
      end },
    { text = "On the OTHER account, move an item between two bags only (don't touch the gear), wait 10 s, "
          .. "then type /alts sync here and press Next." },
    { text = "The timestamps again: a bag move must not move gearAt, and must not fire GearChanged.", auto = true,
      run = function()
          local r = GearReading(SwappedGuid())
          return r and r.capturedAt, r and r.gearAt, #G.gear
      end,
      check = function()
          local before, now = AltStableProbeDB.gear.afterSwap, GearReading(SwappedGuid())
          local guid, later = SwappedGuid(), 0
          for _, e in ipairs(G.gear) do
              if before and e.at > (before.gearAt or 0) then
                  for _, g in ipairs(e.guids) do if g == guid then later = later + 1 end end
              end
          end
          return before ~= nil and now ~= nil and now.gearAt == before.gearAt and later <= 1,
              ("gearAt %s -> %s, capturedAt %s -> %s, GearChanged for it since the swap: %d"):format(
                  Describe(before and before.gearAt), Describe(now and now.gearAt),
                  Describe(before and before.capturedAt), Describe(now and now.capturedAt), later)
      end },
    { text = "On the OTHER account, type /fp as ping. This step completes when the message arrives here.",
      wait = function() return G ~= nil and #G.messages >= 1, "waiting for the ping" end,
      timeout = 120,
      check = function()
          local m = G.messages[#G.messages]
          local fromPeer = false
          for _, p in ipairs(Peers()) do if m and p.guid == m.guid then fromPeer = true end end
          return m ~= nil and fromPeer, ("from %s (%s), a listed peer: %s"):format(Describe(m and m.name), Describe(m and m.guid), tostring(fromPeer))
      end },
    { text = "Here, in AltStable's Options (sync), refuse your other account. This step completes when "
          .. "AltStable reports the peers changed and lists none.",
      wait = function() return G ~= nil and G.peers >= 1 and #Peers() == 0, "peers listed: " .. #Peers() end,
      timeout = 300 },
    { text = "On the OTHER account, type /fp as ping again, wait 10 s, then press Next.",
      button = "Pinged",
      run = function() AltStableProbeDB.gear.messagesWhenRefused = #G.messages; return #G.messages end },
    { text = "Nothing should have arrived while refused.", auto = true,
      run = function() return #G.messages end,
      check = function()
          local n = AltStableProbeDB.gear.messagesWhenRefused
          return n ~= nil and #G.messages == n, ("messages %s before, %d now"):format(Describe(n), #G.messages)
      end },
    { text = "Take the refusal back in Options, so the accounts sync again. Then press Next." },
    { text = "Type /reload (or press Reload now) here AND on the other account, to save both sides.", reload = true },
})

local boot = CreateFrame("Frame")
Probe:RegisterEvents(boot, { "ADDON_LOADED", "PLAYER_LOGIN" })
boot:SetScript("OnEvent", function(self, event, name)
    if event == "ADDON_LOADED" then
        if name ~= ADDON then return end
        self:UnregisterEvent("ADDON_LOADED")
        Adopt()
    elseif event == "PLAYER_LOGIN" then
        Canary()
        -- The scan's moment (Core.lua's PLAYER_LOGIN timer): read what it reads.
        C_Timer.After(2, LoginReading)
        -- The Glass Gear API's callbacks and messages, from the start (#281).
        GearListen()
    end
end)
