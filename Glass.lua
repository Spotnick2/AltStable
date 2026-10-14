-- Glass.lua: this addon's instance of the "liquid glass" material.
--
-- The material lives in the embedded library LibGlass-1.0 (Libs\LibGlass-1.0,
-- from github.com/Spotnick2/LibGlass through .pkgmeta externals; the TOC loads
-- it first). Its contract, write-up (docs/GLASS-MATERIAL.md there) and textures
-- are there: material changes are LibGlass PRs, not edits here.
--
-- An instance, not the library itself: STYLE is this addon's own, so Skin.lua
-- can keep pushing the chosen preset into it before each Apply without touching
-- another glass addon's surfaces. Every call site keeps its dot-call shape
-- (Glass.Apply, Glass.Mask, Glass.MEDIA, ...).
--
-- rimAlpha = 1 keeps the rim as it has always drawn here; the library's own
-- default is a softer 0.7 (LibGlass#3).
--
-- Looked up QUIETLY: Libs/LibGlass-1.0 is gitignored, so a copy installed from
-- a git clone or GitHub's source zip has no library. Without one, Glass stays
-- nil and Skin.SkinIsGlass sends every surface down the flat path, as it
-- always did for a missing material - a flat window, not a load error. (A
-- library that is there but half-loaded still errors in New, loudly: that is
-- a broken copy to find, not an install to forgive.)

--
-- The look (#230): LibGlass r6's clean preset - thin rectangular rims, no
-- grain, softer gloss and shading - is a construction setting, and the saved
-- choice is only readable once SavedVariables load, after every file has taken
-- its `local Glass = AltStable.Glass`. So AltStable.Glass forwards to the
-- instance in use, which Skin.lua picks once through UseGlassLook before
-- anything is built (GlassUnitFrames#102's shape). The instance's functions are
-- closures bound to it, so a forwarded Glass.Apply(...) is that instance's own.

AltStable = AltStable or {}
local lib = LibStub("LibGlass-1.0", true)
if lib then
    local looks = { classic = lib:New({ style = { rimAlpha = 1 } }) }
    local current = looks.classic
    AltStable.Glass = setmetatable({}, {
        __index = function(_, k) return current[k] end,
        __newindex = function(_, k, v) current[k] = v end,
    })
    -- Before the build only: surfaces built earlier keep their look. The clean
    -- instance is made the first time it is asked for, so a classic session
    -- never makes one.
    function AltStable.UseGlassLook(clean)
        if clean and not looks.clean then
            looks.clean = lib:New({ preset = "clean", style = { rimAlpha = 1 } })
        end
        current = clean and looks.clean or looks.classic
    end
else
    AltStable.Glass = nil
    AltStable.UseGlassLook = nil
end
