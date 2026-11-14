----------------------------------------------------------------------------
-- /fp steps as online - who does AltStable hear from on our other account,
-- across a character switch? (Last Online, #337/#338)
--
-- Seen in game on 70938: after Drakuza logged off to a druid on the same
-- account, the sheet on the other account went on reading Drakuza Online, then
-- "0m ago" long after; after a /reload there, the druid (still in game) read
-- "2m ago": nothing was heard from it at all. To measure, on BOTH clients
-- (every line is saved to AltStableProbeDB.log, read after a /reload):
--   * every message the library delivers to AltStable: the sender the library
--     names, the command and the character the message names (HERE8/BYE8);
--   * every message AltStable hands the library, and whether it was taken;
--   * Battle.net's own record of each WoW game account we can see
--     (isOnline, characterName, playerGuid), whenever it changes;
--   * the library's per-account diagnostics, whenever they change;
--   * who the sheet counts as online, whenever that changes.
-- Recording starts at login and runs while the probe is deployed.
----------------------------------------------------------------------------

local _, NS = ...
local Probe = NS.Probe

local function Out(s) Probe:Say(("[online %s] %s"):format(date("%H:%M:%S"), tostring(s))) end

local function Short(guid)
    if type(guid) ~= "string" then return tostring(guid) end
    return guid:match("%-(%x+)$") or guid
end

local function NameOf(guid)
    local c = type(AltStableDB) == "table" and AltStableDB[guid]
    return (type(c) == "table" and c.name or "?") .. "/" .. Short(guid)
end

local function Plain(v)
    local ok, s = pcall(tostring, v)
    return ok and s or "<secret>"
end

local function Lib()
    local T = AltStable and AltStable._test
    return T and T.LibSync
end

-- Wrap the library instance's handler and SendTo once: log, then pass on.
local wrapped = false
local function Wrap()
    local L = Lib()
    local inst = L and L.inst
    if wrapped or type(inst) ~= "table" or type(inst.handler) ~= "function" then return wrapped end
    local handler = inst.handler
    inst.handler = function(payload, sender, sid)
        local cmd, body = tostring(payload):match("^([^|]*)|?(.*)$")
        local named = body and body:match("(Player%-[%w%-]+)")
        Out(("IN  %s %s from library-sender %s%s"):format(cmd or "?",
            (cmd == "HERE8" or cmd == "BYE8") and ("[" .. body:sub(1, 2) .. "]") or ("(" .. #tostring(payload) .. " B)"),
            NameOf(sender and sender.guid), named and (" names " .. NameOf(named)) or ""))
        return handler(payload, sender, sid)
    end
    local send = inst.SendTo
    if type(send) == "function" then
        inst.SendTo = function(guid, msg, onResult)
            local r, why = send(guid, msg, onResult)
            local cmd = tostring(msg):match("^([^|]*)")
            Out(("OUT %s to %s -> %s%s"):format(cmd, NameOf(guid), tostring(r), why and (" " .. tostring(why)) or ""))
            return r, why
        end
    end
    wrapped = true
    Out("recording (handler and SendTo wrapped)")
    return true
end

local last = { bnet = "", diag = "", online = "" }

local function Snapshot()
    -- Battle.net's record of each WoW game account.
    local rows = {}
    if C_BattleNet and C_BattleNet.GetGameAccountInfoByID then
        for id = 1, 256 do
            local ok, g = pcall(C_BattleNet.GetGameAccountInfoByID, id)
            if ok and type(g) == "table" and Plain(g.clientProgram) == "WoW" then
                rows[#rows + 1] = ("id %d online=%s char=%s guid=%s"):format(id, Plain(g.isOnline),
                    Plain(g.characterName), Short(Plain(g.playerGuid)))
            end
        end
    end
    local bnet = table.concat(rows, "; ")
    if bnet ~= last.bnet then last.bnet = bnet; Out("BNET " .. (bnet ~= "" and bnet or "(no WoW game accounts)")) end

    local L = Lib()
    local inst = L and L.inst
    if inst and type(inst.Diagnostics) == "function" then
        local lines = {}
        local ok, iter = pcall(inst.Diagnostics)
        if ok and type(iter) == "function" then
            for line in iter do
                if line:find("^  id ") then lines[#lines + 1] = line:gsub("^%s+", "") end
            end
        end
        local diag = table.concat(lines, "; ")
        if diag ~= last.diag then last.diag = diag; Out("LIB  " .. (diag ~= "" and diag or "(no ids)")) end
    end

    local on = {}
    if AltStable and AltStable.IsCharacterOnline and type(AltStableDB) == "table" then
        for guid, c in pairs(AltStableDB) do
            if type(c) == "table" and AltStable.IsCharacterOnline(guid) then on[#on + 1] = c.name or guid end
        end
    end
    table.sort(on)
    local online = table.concat(on, ", ")
    if online ~= last.online then last.online = online; Out("SHEET online: " .. online) end
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_LOGOUT")
f:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGOUT" then Out("PLAYER_LOGOUT on " .. NameOf(UnitGUID("player"))); return end
    Out("login as " .. NameOf(UnitGUID("player")))
    C_Timer.After(1, Wrap)
    C_Timer.NewTicker(5, function() Wrap(); Snapshot() end)
end)

Probe:Command("online", function() Wrap(); last = { bnet = "", diag = "", online = "" }; Snapshot() end,
    "log Battle.net, the library and the sheet's online set now")

Probe:Steps("online", {
    title = "Last Online: who is heard from across a character switch",
    rev = 1,
    { text = "Run this on the account that stays logged in (Kaleidria's). The other account must be "
          .. "in game too, with the probe deployed (same AddOns folder). Open the AltStable sheet (/alts) "
          .. "and leave it open. Press Next when the other account's character reads Online, or after 30 s." },
    { text = "On the OTHER account: log out to the character list and log in another character there. "
          .. "Note the time you clicked Log Out. Press Next once the new character is in the world." },
    { text = "Watch the sheet for 90 s. Did the old character stop reading Online, and when? "
          .. "Does the new one read Online?", ask = true, screenshot = "sheet after the switch" },
    { text = "Now /reload THIS client, reopen the sheet and wait 30 s. Does the other account's "
          .. "character read Online?", ask = true, screenshot = "sheet after reload" },
    { text = "Last: /reload the OTHER client too, so its log is saved. Then press Done here and /reload once more." },
})
