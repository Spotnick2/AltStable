--[[
    AltStableDevConfig — dev-only settings seeding.

    Through client 1.60.1.69977 the beta wrote SavedVariables and never read
    them back (issue #23), so AltStableConfig was empty at every login: no
    whitelist, no account number, no toggles. That made anything
    configuration-driven untestable, sync most of all, because GetSyncTargets()
    returns nothing when the whitelist is empty. This seeds the config in Lua,
    because addon FILES always loaded even when the saved table did not.

    1.60.1.70009 fixed the client, so on a normal machine this now stands aside
    every login. It earns its keep for a fresh WTF, a second test account, or a
    wiped config - and as the canary if persistence ever regresses.

    It is a separate addon on purpose:
      * it never ships - it lives under Tools/, which .pkgmeta ignores
      * the real addon carries no test scaffolding
      * it can be disabled in the AddOns list to check genuine first-run
        behaviour

    It declares `## Dependencies: AltStable`, so AltStable's files - including
    Config.lua's EnsureDefaults - have already run by the time this executes.
    Those defaults are all `x = x or default`, so values set here survive.

    Edit PEERS below for your own characters.
]]

------------------------------------------------------------
-- Edit this: every character you want to sync between.
-- The logged-in character is skipped automatically, so the same list works
-- on every account.
------------------------------------------------------------

local PEERS = {
    "Karuzo Elegia",
    "Kaleid Sumner",
    "Zoruka Mortalis",
}

-- Account number tags this client's data. Leave "" to skip.
-- Give each WoW account a different value if you want to tell them apart.
local ACCOUNT_NUMBER = ""

------------------------------------------------------------

-- Whether the current whitelist is one this addon wrote. Seed() runs twice -
-- at file load, and again at PLAYER_LOGIN because UnitName("player") is not
-- reliable until then - so the second pass must rebuild the list it made
-- itself (the first pass may have used a missing name for `me`, leaving the
-- player whitelisted against themselves). Only a list that arrived from disk
-- is someone else's to keep.
local seededByUs = false

local function Seed()
    AltStableConfig = AltStableConfig or {}

    -- Names are the full "First Last" form: Forever gives every character a
    -- surname, and CHAT_MSG_ADDON reports the sender that way, so the
    -- whitelist has to match it exactly.
    local me = (UnitName and UnitName("player")) or ""

    -- Stand aside when a whitelist arrived from disk. Since 1.60.1.70009 that
    -- is the normal case; before it, never. This ASSIGNS rather than merges, so
    -- seeding over a loaded whitelist would silently discard every peer the
    -- user added, at every login, and look exactly like persistence being
    -- broken.
    if not seededByUs and type(AltStableConfig.whitelist) == "table"
       and #AltStableConfig.whitelist > 0 then
        return me, #AltStableConfig.whitelist, true
    end

    local list = {}
    for _, name in ipairs(PEERS) do
        if name ~= me then list[#list + 1] = name end
    end
    AltStableConfig.whitelist = list
    seededByUs = true

    if ACCOUNT_NUMBER ~= "" then
        AltStableConfig.accountNumber = ACCOUNT_NUMBER
    end

    return me, #list
end

-- Seed once at file load so the values are in place before anything reads
-- them, then again at PLAYER_LOGIN because UnitName("player") is not reliable
-- until the player is in the world - the same reason Core.lua refreshes
-- PLAYER_NAME there.
Seed()

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function()
    local me, n, stoodAside = Seed()
    if DEFAULT_CHAT_FRAME then
        if stoodAside then
            DEFAULT_CHAT_FRAME:AddMessage(("|cff55ff55[AltStable dev]|r kept %d saved sync peer(s) for %s "
                .. "- the whitelist loaded from disk"):format(n, me))
        else
            -- Not evidence of anything on its own: an empty whitelist is also
            -- what a fresh WTF, a new account or a wiped config looks like.
            DEFAULT_CHAT_FRAME:AddMessage(("|cffff9900[AltStable dev]|r seeded %d sync peer(s) for %s "
                .. "- nothing was on disk to keep"):format(n, me))
        end
    end
end)
