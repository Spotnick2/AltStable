-- test_methods.lua: every widget method the addon calls must exist on this
-- client (Kit.checkMethods, #284).
--
-- The stub answers any capitalised method (a no-op for one it does not
-- implement), so a call to a method Forever lacks would otherwise pass
-- silently. This loads the addon and its four tabs the way the client does,
-- fires every event it registered, runs its slash commands, opens the sheet
-- and clicks and hovers every button it built (every tab, menu and Options
-- page), then checks each recorded "Type:Method" pair against the pinned
-- build's widget methods.

dofile("tests/wow_stubs.lua")

local function try(fn, ...) pcall(fn, ...) end

-- The libraries, then each TOC's files in load order, as the client loads them.
dofile("tests/libglass.lua"); LoadGlass("AltStable")
dofile("tests/libshowcase.lua"); LoadShowcase("AltStable")
dofile("tests/libaccountsync.lua"); LoadAccountSync("AltStable")
dofile("Libs/LibStub/LibStub.lua")
dofile("Libs/LibDeflate/LibDeflate.lua")
dofile("Libs/ChatThrottleLib/ChatThrottleLib.lua")
local function loadToc(toc, dir)
    for _, file in ipairs(Kit.tocFiles(toc, dir)) do
        if not file:match("Libs/") then assert(loadfile(file))() end
    end
end
loadToc("AltStable.toc", "")
for _, p in ipairs({ "Warband", "Instances", "Roster", "Professions" }) do
    loadToc("AltStable" .. p .. ".toc", "Plugins/" .. p .. "/")
end

-- The login: ADDON_LOADED per folder, then every registered event once.
for _, a in ipairs({ "AltStable", "AltStableWarband", "AltStableInstances", "AltStableRoster", "AltStableProfessions" }) do
    try(WoW.fire, "ADDON_LOADED", a)
end
try(WoW.fire, "PLAYER_LOGIN")
try(WoW.fire, "PLAYER_ENTERING_WORLD", true, false)
try(WoW.fireAllRegistered)
for _ = 1, 3 do try(WoW.flushTimers) end
WoW.tick()

for _, cmd in ipairs({ "help", "status", "stale", "forgotten", "whitelist", "auth", "account", "export", "sync", "config", "" }) do
    try(SlashCmdList.ALTSTABLE, cmd)
    try(WoW.flushTimers)
end

-- Every button the addon built, clicked and hovered, twice: the first round
-- opens tabs and menus whose own buttons the second round reaches.
local function exercise()
    local list = {}
    for _, f in ipairs(WoW.frames) do list[#list + 1] = f end
    for _, f in ipairs(list) do
        local s = f._scripts
        if s.OnEnter then try(s.OnEnter, f) end
        if s.OnLeave then try(s.OnLeave, f) end
        if s.OnClick then try(s.OnClick, f, "LeftButton", false) end
        try(WoW.flushTimers)
    end
    WoW.tick()
end
try(AltStable.ShowSheet)
exercise()
exercise()

-- Methods a Blizzard mixin adds in Lua, which the dump's widget walk can't see
-- (wow-ui-source, 70862).
local BACKDROP = "BackdropTemplateMixin (Blizzard_SharedXML/Backdrop.lua), from BackdropTemplate"
local TOOLTIP = "TooltipDataHandler's accessors, added in Lua (Blizzard_SharedXMLGame/Tooltip/TooltipDataHandler.lua)"
local recorded = Kit.checkMethods({ allow = {
    ["Button:SetBackdrop"] = BACKDROP, ["Button:SetBackdropColor"] = BACKDROP,
    ["Button:SetBackdropBorderColor"] = BACKDROP,
    ["Frame:SetBackdrop"] = BACKDROP, ["Frame:SetBackdropColor"] = BACKDROP,
    ["Frame:SetBackdropBorderColor"] = BACKDROP,
    ["GameTooltip:SetHyperlink"] = TOOLTIP, ["GameTooltip:SetInventoryItem"] = TOOLTIP,
} })
-- The floor: what loading and the exercise record today, rounded down, so the
-- exercise can't quietly shrink.
check(recorded >= 230, "the exercise reached the windows (" .. recorded .. " recorded)")

done("test_methods")
