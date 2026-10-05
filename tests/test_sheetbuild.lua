------------------------------------------------------------
-- test_sheetbuild.lua - the sheet's FIRST build, with the animation on
--
-- Its own file because the build happens once per Lua state: test_sheetui
-- builds with the open animation off and can never come back to this.
------------------------------------------------------------

dofile("tests/wow_stubs.lua")

local passed, failed = 0, 0
local function check(name, ok, detail)
    if ok then passed = passed + 1
    else failed = failed + 1; print("  FAIL: " .. name .. (detail and ("  -- " .. detail) or "")) end
end

AltStable, AltStableDB, AltStableConfig = {}, {}, {}
dofile("Compat.lua")
dofile("tests/libglass.lua"); LoadGlass("AltStable")
-- The camera showcase (LibShowcase-1.0), next in the TOC.
dofile("tests/libshowcase.lua"); LoadShowcase("AltStable")
dofile("Theme.lua")
dofile("Skin.lua")
assert(loadfile("Core.lua"))()
dofile("Scanner.lua")
dofile("Reputations.lua")
dofile("Config.lua")
dofile("Toasts.lua")
dofile("Columns.lua")
dofile("RowRenderer.lua")
dofile("CharacterMenu.lua")
dofile("SheetUI.lua")

AltStableDB = {
    a = { guid = "a", name = "First One", class = "MAGE", realm = "R", level = 60, ilvl = 66, lastUpdate = 1 },
}
-- On, as it is by default in game.
AltStableConfig.enableOpenAnimation = true

local T = AltStable._test
local ok, err = pcall(T.BuildSheet)
check("the sheet builds with the animation on", ok, tostring(err))

-- The first tab is activated during the build, while the window is still shown
-- (it is hidden at the end). Animated, that started a trip on a window nobody
-- sees, re-anchored to a temporary point while it ran (#164 review).
local runner = T.WindowAnimRunner and T.WindowAnimRunner()
check("the first build starts no window trip", not (runner and runner:GetScript("OnUpdate")))
local f = T.frame
check("  and leaves the window hidden, on its own anchor", f and not f:IsShown() and (f:GetPoint(1)) ~= "BOTTOMLEFT",
      tostring(f and f:GetPoint(1)))

print(("test_sheetbuild: %d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
