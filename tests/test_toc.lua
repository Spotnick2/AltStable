-- test_toc.lua: what every addon TOC must get right (Kit.checkToc, #284):
-- the interface, the packager's version token, every listed .lua file there
-- and listed once. test_packaging.lua keeps this repo's own TOC checks (store
-- IDs, the plugins' dependencies, .pkgmeta, the deploy script).

dofile("tests/wow_stubs.lua")

for _, t in ipairs({
    { toc = "AltStable.toc",               dir = "" },
    { toc = "AltStableWarband.toc",        dir = "Plugins/Warband/" },
    { toc = "AltStableInstances.toc",      dir = "Plugins/Instances/" },
    { toc = "AltStableRoster.toc",         dir = "Plugins/Roster/" },
    { toc = "AltStableProfessions.toc",    dir = "Plugins/Professions/" },
}) do
    Kit.checkToc(t.toc, { dir = t.dir })
end

done("test_toc")
