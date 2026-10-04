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

AltStable = AltStable or {}
AltStable.Glass = LibStub("LibGlass-1.0"):New({ style = { rimAlpha = 1 } })
