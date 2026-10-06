------------------------------------------------------------
-- test_packaging.lua — the TOCs, .pkgmeta and the deploy script (#12)
--
-- The release zip is built by CurseForge's packager from .pkgmeta, which no
-- test here can run. What IS checkable offline is everything that feeds it: a
-- TOC listing a file that doesn't exist (or missing one that does), a
-- development folder that .pkgmeta forgets to ignore, and the version keyword
-- getting a literal committed over it - which has happened twice on sibling
-- projects. CI checks the built zip's shape; this checks the inputs.
------------------------------------------------------------

local passed, failed = 0, 0
local function check(name, ok, detail)
    if ok then passed = passed + 1
    else failed = failed + 1; print("  FAIL: " .. name .. (detail and ("  -- " .. detail) or "")) end
end
local function eq(name, got, want)
    check(name, got == want, "got " .. tostring(got) .. ", want " .. tostring(want))
end

local function read(path)
    local h = io.open(path, "r")
    if not h then return nil end
    local s = h:read("*a"); h:close(); return s
end

local function exists(path)
    local h = io.open(path, "r")
    if h then h:close(); return true end
    return false
end

------------------------------------------------------------
-- Every TOC: its files exist, and the version is the keyword
------------------------------------------------------------

local TOCS = {
    { toc = "AltStable.toc",                              dir = "" },
    { toc = "Plugins/Warband/AltStableWarband.toc",       dir = "Plugins/Warband/" },
    { toc = "Plugins/Instances/AltStableInstances.toc",   dir = "Plugins/Instances/" },
    { toc = "Plugins/Roster/AltStableRoster.toc",         dir = "Plugins/Roster/" },
    { toc = "Plugins/Professions/AltStableProfessions.toc", dir = "Plugins/Professions/" },
}

for _, t in ipairs(TOCS) do
    local src = read(t.toc)
    check(t.toc .. " exists", src ~= nil)
    if src then
        local listed, missing = 0, nil
        for line in (src .. "\n"):gmatch("([^\r\n]*)[\r\n]") do
            local file = line:match("^%s*([%w_%-%./\\]+%.lua)%s*$")
            if file then
                listed = listed + 1
                local path = t.dir .. file:gsub("\\", "/")
                if not exists(path) then missing = path end
            end
        end
        check(t.toc .. " lists files", listed > 0, tostring(listed))
        check("  every file it lists exists", missing == nil, tostring(missing))

        local version = src:match("##%s*Version:%s*([^\r\n]*)")
        eq("  its version is the packager keyword", version, "@project-version@")
        local iface = src:match("##%s*Interface:%s*(%d+)")
        eq("  its interface is the measured one", iface, "16001")
        check("  no flavor suffix in the filename",
              not t.toc:find("_Forever") and not t.toc:find("_Vanilla"))
    end
end

-- No packager keyword in shipped Lua. The packager substitutes them in EVERY
-- file it ships, not only the .toc: v0.7.0-beta's Config.lua compared the
-- version against "@project-version@" written out, shipped comparing it
-- against "v0.7.0-beta", and the release counted itself as a dev copy. Code
-- that needs a keyword assembles it at runtime. Read from the TOCs, so this is
-- exactly the Lua that ships.
--
-- Matched by SHAPE (#193, as Priestly does after its own #83): the packager has
-- a family of keywords - @project-version@, @file-date-iso@, @debug@, @alpha@,
-- @do-not-package@ ... - and a list of families let the bare ones through.
-- XML too (only what is in the repo: LibGlass's is checked in its own repo and
-- in CI's zip check), and the first hit is reported as file:line.
do
    local found, scanned = nil, 0
    for _, t in ipairs(TOCS) do
        local src = read(t.toc) or ""
        for line in (src .. "\n"):gmatch("([^\r\n]*)[\r\n]") do
            local file = line:match("^%s*([%w_%-%./\\]+%.[lx][um][al])%s*$")
            local code = file and read(t.dir .. file:gsub("\\", "/"))
            if code then
                scanned = scanned + 1
                local n = 0
                for codeLine in (code .. "\n"):gmatch("([^\n]*)\n") do
                    n = n + 1
                    local keyword = codeLine:match("(@[%w%-]+@)")
                    if keyword and not found then
                        found = t.dir .. file:gsub("\\", "/") .. ":" .. n .. ": " .. keyword
                    end
                end
            end
        end
    end
    check("the keyword sweep read the shipped files", scanned >= 20, tostring(scanned))
    check("no shipped Lua or XML file contains a packager keyword (it would be substituted)",
          found == nil, found)
end

-- Every shipped Lua file at the root is listed in the main TOC: a file added to
-- the repo but not the TOC simply never loads in game, silently.
do
    -- Whole LINES, not a substring search over the file: "UI.lua" is a suffix
    -- of "SheetUI.lua", so a plain find() reports four of today's files as
    -- listed no matter what the TOC says - and a new root UI.lua would pass
    -- while never loading.
    local listed = {}
    for line in ((read("AltStable.toc") or "") .. "\n"):gmatch("([^\r\n]*)[\r\n]") do
        local file = line:match("^%s*([%w_%-%./\\]+%.lua)%s*$")
        if file then listed[file:gsub("^.*[/\\]", "")] = true end
    end
    -- The listing command differs by platform, and this suite runs on both
    -- (Windows locally, Linux in CI). A wrong one would list nothing and the
    -- check would pass while testing nothing, so the count is asserted too.
    local windows = package.config:sub(1, 1) == "\\"
    local cmd = windows and "dir /b *.lua 2>nul" or "ls -1 *.lua 2>/dev/null"
    local names = {}
    local pipe = io.popen and io.popen(cmd)
    if pipe then
        for name in pipe:lines() do
            name = name:gsub("%s+$", "")
            if name ~= "" then names[#names + 1] = name end
        end
        pipe:close()
    end
    check("the root .lua files could be listed", #names > 0, tostring(#names))
    local unlisted = {}
    for _, name in ipairs(names) do
        if not listed[name] then unlisted[#unlisted + 1] = name end
    end
    check("every root .lua file is listed in the TOC", #unlisted == 0, table.concat(unlisted, ", "))
end

------------------------------------------------------------
-- .pkgmeta
------------------------------------------------------------

local pkg = read(".pkgmeta")
check(".pkgmeta exists", pkg ~= nil)
if pkg then
    eq("the package is named AltStable", pkg:match("package%-as:%s*(%S+)"), "AltStable")

    -- WoW only discovers top-level addon folders, so the plugins must be moved
    -- out of AltStable/Plugins into siblings.
    check("Warband moves to its own folder",
          pkg:find("AltStable/Plugins/Warband: AltStableWarband", 1, true) ~= nil)
    check("Raids moves to its own folder",
          pkg:find("AltStable/Plugins/Instances: AltStableInstances", 1, true) ~= nil)
check("Roster moves to its own folder",
      pkg:find("AltStable/Plugins/Roster: AltStableRoster", 1, true) ~= nil)
check("Professions moves to its own folder",
      pkg:find("AltStable/Plugins/Professions: AltStableProfessions", 1, true) ~= nil)

    -- The ignore list must be a YAML list. Markdown bullets parse as nothing,
    -- and the result is a published zip carrying the probe and the tests.
    local ignore = pkg:match("ignore:%s*\n(.-)\n%s*\n") or pkg:match("ignore:%s*\n(.*)$") or ""
    local bullets = 0
    for line in (ignore .. "\n"):gmatch("([^\n]*)\n") do
        if line:match("^%s*%-%s+%S") then bullets = bullets + 1 end
    end
    check("the ignore list uses YAML dashes", bullets >= 5, tostring(bullets))
    for _, want in ipairs({ "tests", "Tools", "docs", ".github", "AGENTS.md", "CLAUDE.md" }) do
        check("  " .. want .. " is ignored", ignore:find("%-%s*" .. want:gsub("%.", "%%.") .. "%s") ~= nil
              or ignore:find("%-%s*" .. want:gsub("%.", "%%.") .. "$") ~= nil)
    end

    -- Both, on purpose: manual-changelog reads it, ignore keeps the file itself
    -- out of the addon folder.
    check("CHANGELOG.md is the manual changelog",
          pkg:find("filename: CHANGELOG.md", 1, true) ~= nil)
    check("  and is also ignored", ignore:find("CHANGELOG%.md") ~= nil)

    -- MIT: the notice travels with the distribution.
    -- An ENTRY, not the word: the comments may say why it ships (#184), and
    -- LibGlass's own LICENSE ships too.
    local licenceIgnored = false
    -- Every entry, the first one included: the captured block starts AT it,
    -- and a pattern anchored on a newline slipped past it (#185 review).
    for line in (ignore .. "\n"):gmatch("([^\n]*)\n") do
        local entry = line:match("^%s*%-%s*(.*)$")
        if entry and entry:find("LICENSE", 1, true) then licenceIgnored = true end
    end
    check("LICENSE is NOT ignored (ours or LibGlass's)", not licenceIgnored)

    -- CurseForge's packager does NOT apply an external's own ignore list, so
    -- each of LibGlass's non-dot ignores must be repeated here under
    -- Libs/LibGlass-1.0/. CI cannot see a missing one: its BigWigs dry run DOES
    -- honour the library's list, so the zip comes out clean either way and
    -- only the published one would carry the library's tests/docs/Tools.
    dofile("tests/libglass.lua")
    dofile("tests/libshowcase.lua")
    -- Line by line: a pattern that eats the newline on both sides skips every
    -- other entry.
    local function entries(block)
        local out = {}
        for line in (block .. "\n"):gmatch("([^\n]*)\n") do
            local e = line:gsub("\r", ""):match("^%s*%-%s*([^#]-)%s*$")
            if e and e ~= "" then out[#out + 1] = e end
        end
        return out
    end
    local ours = {}
    for _, e in ipairs(entries(ignore)) do ours[e] = true end
    -- Both embedded libraries, the same way. Each is also an external pinned
    -- to a tag (never `latest`: the packager would pick by creation date).
    for _, lib in ipairs({ { "LibGlass", "LibGlass-1.0", LibGlassRoot },
                           { "LibShowcase", "LibShowcase-1.0", LibShowcaseRoot } }) do
        local name, major, root = lib[1], lib[2], lib[3]
        local libPkg = read(root() .. "/.pkgmeta") or ""
        local libIgnore = libPkg:match("ignore:%s*\n(.*)$") or ""
        local theirs, missing = 0, {}
        for _, entry in ipairs(entries(libIgnore)) do
            if not entry:match("^%.") then
                theirs = theirs + 1
                if not ours["Libs/" .. major .. "/" .. entry] then missing[#missing + 1] = entry end
            end
        end
        check(name .. "'s own ignore list was read", theirs >= 3, tostring(theirs))
        check("each of " .. name .. "'s non-dot ignores is repeated under Libs/" .. major,
              #missing == 0, table.concat(missing, ", "))
        local plain = pkg:gsub("\r", "")
        local at = plain:find("\n  Libs/" .. major .. ":\n", 1, true)
        local url = at and plain:match("^\n  [^\n]*\n    url: ([^\n]*)", at)
        local tag = at and plain:match("^\n  [^\n]*\n    url: [^\n]*\n    tag: ([^\n]*)", at)
        eq(name .. " is an external from its repo", url, "https://github.com/Spotnick2/" .. name)
        check("  pinned to a tag", tag ~= nil and tag:match("^r%d+$") ~= nil, tostring(tag))
    end
end

-- The embedded libraries load before any of the addon's own files: LibGlass,
-- then LibShowcase (SheetUI.lua builds its showcase instance at load).
do
    local order, n = {}, 0
    for line in ((read("AltStable.toc") or "") .. "\n"):gmatch("([^\r\n]*)[\r\n]") do
        if line:match("^[^#%s]") then n = n + 1; order[(line:gsub("%s+$", ""))] = n end
    end
    local glass = order[ [[Libs\LibGlass-1.0\LibGlass-1.0.xml]] ]
    local showcase = order[ [[Libs\LibShowcase-1.0\LibShowcase-1.0.xml]] ]
    check("the TOC loads LibShowcase's XML", showcase ~= nil)
    check("  after LibGlass's", glass ~= nil and showcase ~= nil and glass < showcase)
    check("  before the addon's own files", showcase ~= nil and order["Compat.lua"] ~= nil
          and showcase < order["Compat.lua"] and showcase < order["SheetUI.lua"])
end

check("CHANGELOG.md exists", read("CHANGELOG.md") ~= nil)

------------------------------------------------------------
-- The deploy script
------------------------------------------------------------

-- These read the script's text rather than running it: the suite runs under
-- Lua on both Windows and Linux CI, and pwsh is not a given. So assert the
-- BODY of the substitution loop, not that the loop exists - a grep for the
-- `foreach` line alone stays green with the replacement deleted from inside it,
-- which is exactly the bug (every deployed TOC showing the raw keyword).
local deploy = read("Tools/deploy.ps1")
check("the deploy script exists", deploy ~= nil)
if deploy then
    local loop = deploy:match("foreach %(%$toc in %$deployedTocs%) {(.-)\n}")
    check("it loops over every deployed TOC", loop ~= nil)
    if loop then
        check("  and substitutes the version keyword in each",
              loop:find("@project%-version@") ~= nil and loop:find("Set%-Content") ~= nil, loop)
    end

    -- The repo copy must keep the keyword: a literal written back here is how a
    -- version gets committed over it.
    check("  writing only to the deployed copy",
          deploy:find("$dest", 1, true) ~= nil and not deploy:find("$RepoRoot" .. "\\AltStable.toc", 1, true))

    local pluginLoop = deploy:match("foreach %(%$dir in Get%-ChildItem %$pluginRoot %-Directory%) {(.-)\n    }")
    -- The statement, not the text: a commented-out line still contains it.
    check("it fans each plugin out to its own folder",
          pluginLoop ~= nil and pluginLoop:find("\n%s*robocopy @pluginArgs") ~= nil)
    check("  and collects that folder's TOC for substitution",
          pluginLoop ~= nil and pluginLoop:find("$deployedTocs +=", 1, true) ~= nil)
end

------------------------------------------------------------
-- No literal version committed over the keyword
------------------------------------------------------------

for _, t in ipairs(TOCS) do
    local src = read(t.toc) or ""
    local version = src:match("##%s*Version:%s*([^\r\n]*)") or ""
    check(t.toc .. " has no literal version committed",
          not version:find("%d+%.%d+") and not version:find("dev"), version)
end

------------------------------------------------------------
-- Every addon has an icon, and they all have the SAME one
------------------------------------------------------------
-- Without ## IconTexture the AddOns list draws a red question mark, and with
-- this many folders that is a column of them.
--
-- The expected id is read out of SheetUI rather than written here. The comment
-- beside it tells a future maintainer to re-derive the id with /asicon and
-- update it there - and doing exactly that used to leave six TOCs and the
-- Cutouts generator on the stale one, with a green suite and a minimap button
-- that disagreed with the AddOns list.
--
-- The list is its own, not the TOCS above: that one holds the four PACKAGED
-- addons, while the icon matters for the dev tools and the generated Cutouts
-- template too. Dropping the line from the PS1 template regenerates every
-- user's Cutouts folder with a question mark and nothing else would notice.

local WANTED_ICON = read("SheetUI.lua"):match("ROSTER_ICON_FILE_ID%s*=%s*(%d+)")
check("SheetUI names the icon this checks against", WANTED_ICON ~= nil)

local ICON_FILES = {
    "AltStable.toc",
    "Plugins/Warband/AltStableWarband.toc",
    "Plugins/Instances/AltStableInstances.toc",
    "Plugins/Roster/AltStableRoster.toc",
    "Plugins/Professions/AltStableProfessions.toc",
    "Tools/AltStableProbe/AltStableProbe.toc",
    -- Not a TOC: the generator that WRITES one.
    "Tools/RenderCutout/Update-Cutouts.ps1",
}

for _, file in ipairs(ICON_FILES) do
    local src = read(file)
    local icon = src:match("##%s*IconTexture:%s*(%S+)")
    check(file .. " declares an icon", icon ~= nil,
          "the AddOns list shows a red question mark without one")
    if icon and WANTED_ICON then
        eq("  and it is the one SheetUI uses", icon, WANTED_ICON)
    end

    -- ## Dependencies: AltStable is what nests a folder UNDER the main addon in
    -- the AddOns list. Without it a member of this family sits at the top level
    -- among unrelated addons, which is how Cutouts and the Probe looked until
    -- someone noticed. The main addon is the parent and depends on nobody.
    if file ~= "AltStable.toc" then
        check("  and hangs off the main addon in the list",
              src:match("##%s*Dependencies:[^\n]*AltStable") ~= nil,
              "it would sit at the top level on its own")
    end
end

------------------------------------------------------------
-- Every bundled library is named in LICENSE
------------------------------------------------------------
-- The MIT terms cover this addon's own code and do not relicense anything
-- under Libs/. LICENSE says so and names each one - and LICENSE is the file
-- that SHIPS, unlike README, so it is the one that has to be right.
--
-- Pinned per directory rather than as a count, because the failure is silent:
-- vendoring a fourth library and forgetting the note leaves a distribution
-- claiming MIT over somebody else's work. The test fails on the library's
-- name, which is also the thing to go and write about.

do
    local lic = read("LICENSE") or ""
    check("LICENSE exists and is not empty", #lic > 0)
    check("  it still carries the MIT grant",
          lic:find("MIT License", 1, true) ~= nil)
    check("  and says the bundled libraries are not covered by it",
          lic:find("THIRD-PARTY COMPONENTS", 1, true) ~= nil)

    local windows = package.config:sub(1, 1) == "\\"
    local cmd = windows and "dir /b /ad Libs 2>nul" or "ls -1 Libs 2>/dev/null"
    local libs = {}
    local pipe = io.popen and io.popen(cmd)
    if pipe then
        for name in pipe:lines() do
            name = name:gsub("%s+$", "")
            if name ~= "" then libs[#libs + 1] = name end
        end
        pipe:close()
    end
    -- Asserted, because a listing command that returns nothing would make
    -- every check below pass without testing anything.
    check("the bundled libraries could be listed", #libs > 0, tostring(#libs))

    for _, name in ipairs(libs) do
        check("  LICENSE names " .. name, lic:find(name, 1, true) ~= nil,
              "a distribution claiming MIT over somebody else's work")
    end
end

print(("test_packaging: %d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
