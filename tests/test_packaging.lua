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

-- Every shipped Lua file at the root is listed in the main TOC: a file added to
-- the repo but not the TOC simply never loads in game, silently.
do
    local src = read("AltStable.toc") or ""
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
    check("the root .lua files could be listed", #names >= 10, tostring(#names))
    local unlisted = {}
    for _, name in ipairs(names) do
        if not src:find(name, 1, true) then unlisted[#unlisted + 1] = name end
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
    check("LICENSE is NOT ignored", ignore:find("LICENSE") == nil)
end

check("CHANGELOG.md exists", read("CHANGELOG.md") ~= nil)

------------------------------------------------------------
-- The deploy script
------------------------------------------------------------

local deploy = read("Tools/deploy.ps1")
check("the deploy script exists", deploy ~= nil)
if deploy then
    -- Every deployed TOC needs the keyword substituted, not just the main one,
    -- or the plugins show "@project-version@" in the AddOns list.
    check("it substitutes the version in every deployed TOC",
          deploy:find("foreach ($toc in $deployedTocs)", 1, true) ~= nil)
    check("  and only in the deployed copy",
          deploy:find("DEPLOYED copies", 1, true) ~= nil)
    check("it fans the plugins out to sibling folders",
          deploy:find("$pluginDest", 1, true) ~= nil)
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

print(("test_packaging: %d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
