--[[
    AltStableDevConfig — dev-only settings seeding.

    The beta client writes SavedVariables and never reads them back (issue #23),
    so AltStableConfig is empty at every login: no whitelist, no account number,
    no toggles. That makes anything configuration-driven untestable, sync most
    of all, because GetSyncTargets() returns nothing when the whitelist is empty.

    The workaround is simply that addon FILES do load. So this seeds the config
    in Lua instead of relying on the saved table.

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

local function Seed()
    AltStableConfig = AltStableConfig or {}

    -- Names are the full "First Last" form: Forever gives every character a
    -- surname, and CHAT_MSG_ADDON reports the sender that way, so the
    -- whitelist has to match it exactly.
    local me = (UnitName and UnitName("player")) or ""
    local list = {}
    for _, name in ipairs(PEERS) do
        if name ~= me then list[#list + 1] = name end
    end
    AltStableConfig.whitelist = list

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
    local me, n = Seed()
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage(("|cffff9900[AltStable dev]|r seeded %d sync peer(s) for %s "
            .. "- SavedVariables do not load on this client (#23)"):format(n, me))
    end
end)
