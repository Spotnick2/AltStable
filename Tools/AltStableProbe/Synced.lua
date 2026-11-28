----------------------------------------------------------------------------
-- /fp steps as synced - what the synced-fields release reads (#508 #395 #515
-- #517 #516), on the live client before any of it is built. The plan:
-- https://github.com/Spotnick2/AltStable/issues/508#issuecomment-7237014013
--
-- Recorded on its own while the probe is deployed (every line goes to
-- AltStableProbeDB.log, read after a /reload):
--   * the guild pair, IsInGuild() and GetGuildInfo("player") at the same
--     instant, at login +0/1/2/5/10 s and on every guild event: the plan's
--     rule for an empty read hangs on whether a guilded character can read
--     "not in a guild" for a moment after login;
--   * every zone event, with the four zone texts and the map id;
--   * every UPDATE_INVENTORY_DURABILITY, with the worn slots' durability and
--     whether the player is in combat.
-- The steps take the readings the owner has to go somewhere for: the open
-- world between named areas, an instance, damaged gear in combat, a mailbox
-- holding a player's mail and the Auction House's, a guildless character.
----------------------------------------------------------------------------

local _, NS = ...
local Probe = NS.Probe
local Show = ForeverProbe.Show
local IsSecret = ForeverProbe.IsSecret

local function Out(s) Probe:Say(("[synced %s] %s"):format(date("%H:%M:%S"), tostring(s))) end

local SLOTS = { 1, 2, 3, 15, 5, 9, 10, 6, 7, 8, 11, 12, 13, 14, 16, 17, 18 }

local function Guild(tag)
    local inGuild = IsInGuild()
    local name, rank, index = GetGuildInfo("player")
    local line = ("GUILD %s IsInGuild=%s GetGuildInfo=%s, %s, %s"):format(tag, Show(inGuild),
        Show(name), Show(rank), Show(index))
    Out(line)
    return line
end

local function Zone(tag)
    local map = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    local inInstance, kind = IsInInstance()
    local line = ("ZONE %s real=%s zone=%s sub=%s minimap=%s map=%s instance=%s/%s"):format(tag,
        Show(GetRealZoneText()), Show(GetZoneText()), Show(GetSubZoneText()),
        Show(GetMinimapZoneText()), Show(map), Show(inInstance), Show(kind))
    Out(line)
    return line
end

-- Each worn slot: item id, then current/max as the client answers (nil
-- for an item with no durability, <secret> if it won't say).
local function Durability(tag)
    local parts = {}
    for _, slot in ipairs(SLOTS) do
        local id = GetInventoryItemID("player", slot)
        if id then
            local ok, cur, max = pcall(GetInventoryItemDurability, slot)
            parts[#parts + 1] = ("%d:%s=%s/%s"):format(slot, Show(id),
                ok and Show(cur) or ("error " .. tostring(cur)), ok and Show(max) or "")
        end
    end
    local line = ("DUR %s combat=%s %s"):format(tag, Show(InCombatLockdown()), table.concat(parts, " "))
    Out(line)
    return line
end

local function XP()
    local line = ("XP IsXPUserDisabled=%s level=%s"):format(Show(IsXPUserDisabled()), Show(UnitLevel("player")))
    Out(line)
    return line
end

-- Every inbox mail: what the client says happens at expiry, beside what
-- LibMailbox would call it. The sender only as its shape: it is another
-- player's name.
local function Mail()
    local n, total = GetInboxNumItems()
    Out(("MAIL %s of %s"):format(Show(n), Show(total)))
    local lines = {}
    for i = 1, (tonumber(n) or 0) do
        local _, _, sender, subject, money, cod, daysLeft, itemCount, wasRead, wasReturned,
              textCreated, canReply, isGM = GetInboxHeaderInfo(i)
        local line = ("MAIL %d sender=%s subject=%s money=%s cod=%s days=%s items=%s returned=%s canReply=%s gm=%s CanDelete=%s"):format(
            i, ForeverProbe.Shape(sender), ForeverProbe.Shape(subject), Show(money), Show(cod),
            Show(daysLeft), Show(itemCount), Show(wasReturned), Show(canReply), Show(isGM),
            Show(InboxItemCanDelete(i)))
        Out(line)
        lines[#lines + 1] = line
    end
    return #lines .. " mails"
end

local f = CreateFrame("Frame")
for _, ev in ipairs({ "PLAYER_LOGIN", "PLAYER_GUILD_UPDATE", "GUILD_RANKS_UPDATE",
                      "GUILD_RANKS_UPDATE_ACTIVE_PLAYER", "ZONE_CHANGED", "ZONE_CHANGED_INDOORS",
                      "ZONE_CHANGED_NEW_AREA", "UPDATE_INVENTORY_DURABILITY", "ENABLE_XP_GAIN",
                      "DISABLE_XP_GAIN" }) do
    f:RegisterEvent(ev)
end
f:SetScript("OnEvent", function(_, event, arg1)
    if event == "PLAYER_LOGIN" then
        Out("login as " .. Show(UnitName("player")))
        for _, s in ipairs({ 0, 1, 2, 5, 10 }) do
            C_Timer.After(s, function() Guild("login+" .. s) end)
        end
        C_Timer.After(2, function() Zone("login+2"); Durability("login+2"); XP() end)
    elseif event:find("^GUILD") or event == "PLAYER_GUILD_UPDATE" then
        Guild(event .. "(" .. Show(arg1) .. ")")
    elseif event:find("^ZONE") then
        Zone(event)
    elseif event == "UPDATE_INVENTORY_DURABILITY" then
        Durability(event)
    else
        XP(); Out(event)
    end
end)

Probe:Command("synced", function() Guild("now"); Zone("now"); Durability("now"); XP() end,
    "log the guild pair, the zone, durability and XP now")

Probe:Steps("synced", {
    title = "Synced fields: what the client gives (#508 #395 #515 #517)",
    rev = 1,
    { text = "Readings where you stand: guild, zone, durability, XP.", auto = true,
      run = function() return Guild("step"), Zone("step"), Durability("step"), XP() end },
    { text = "ZONE: go somewhere in the open world away from any named place, where the minimap "
          .. "shows only the zone's name. Press Run there. (Skip if it's too far.)",
      button = "Read zone", run = function() return Zone("open world") end },
    { text = "ZONE: enter any instance (a dungeon entrance is enough), then press Run inside. "
          .. "(Skip if none is near.)",
      button = "Read zone", run = function() return Zone("instance") end },
    { text = "DURABILITY: wear something damaged (fight a little, or die once). Then start a fight "
          .. "and press Run WHILE in combat.",
      button = "Read in combat", run = function() return Durability("combat step") end },
    { text = "MAIL: open a mailbox holding at least one mail from a player and one from the "
          .. "Auction House (a returned mail too, if you have one). Press Run with the inbox open.",
      button = "Read inbox", run = function() return Mail() end },
    { text = "In the mailbox, does a player's mail show \"Return\" when opened, and an Auction House "
          .. "mail \"Delete\"?", ask = true },
    { text = "GUILD: log out and log in a character WITHOUT a guild, then back on a guilded one. "
          .. "The login readings are taken by themselves. Press Next when back. (Skip if you "
          .. "have no guildless character.)" },
    { text = "GUILD (optional): if you can, promote or demote one of your alts in its guild, "
          .. "or have it done. The events are logged by themselves. Press Next, or Skip." },
    { text = "Done. Press Finish, then /reload so the log is saved.", reload = true },
})
