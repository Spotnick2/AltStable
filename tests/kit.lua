-- tests/kit.lua: loads WowTestKit at the commit tests/kit.pin names.
-- Copied from WowTestKit's bootstrap/kit.lua: never edit a consumer's copy;
-- change the kit's and copy it again.
--
-- The kit is found at $WOWTESTKIT (set by tests/run.ps1 and by CI), else in
-- the local cache, %LOCALAPPDATA%\WowTestKit\<sha>, that tests/run.ps1 fills.
-- So one test can run by hand once run.ps1 has run:
--   lua tests/test_boot.lua

local pin = {}
for line in io.lines("tests/kit.pin") do
    local k, v = line:match("^%s*([%w_]+)%s*=%s*(%S+)")
    if k then pin[k] = v end
end
assert(pin.sha and pin.build, "tests/kit.pin needs sha= and build=")

local dir = os.getenv("WOWTESTKIT")
if not dir or dir == "" then
    local base = os.getenv("LOCALAPPDATA") or ((os.getenv("HOME") or ".") .. "/.cache")
    dir = base:gsub("\\", "/") .. "/WowTestKit/" .. pin.sha
end
dir = dir:gsub("\\", "/"):gsub("/$", "")
local f = io.open(dir .. "/kit.lua", "rb")
if not f then
    error("WowTestKit not found at " .. dir .. ": run tests/run.ps1 once (it fetches the pinned kit), "
        .. "or set WOWTESTKIT", 0)
end
f:close()
dofile(dir .. "/kit.lua")
Kit.load({ build = pin.build, sha = pin.sha, api = pin.api })
