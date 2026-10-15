------------------------------------------------------------
-- tests/foreverprobe.lua - ForeverProbe, the host Tools/AltStableProbe runs
-- on (#240), loaded into the stub environment the way the client loads it,
-- and the probe's own files after it. Load tests/wow_stubs.lua first.
--
-- The host is private and lives beside this checkout
-- (C:\Projects\WoW\ForeverProbe, or $FOREVERPROBE), so CI cannot fetch it.
-- There FOREVERPROBE_OPTIONAL=1 turns a missing checkout into a SKIPPED line
-- and a clean exit; locally a missing checkout is an error, never a silent
-- skip (ForeverProbe docs/GUIDE.md, section 8). loadForeverProbe() is
-- GlassChat's (tests/harness.lua), with this suite's event firing.
------------------------------------------------------------

-- Every frame made from here on, so an event reaches whoever registered it.
local frames = {}
local createFrame = CreateFrame
function CreateFrame(...)
    local f = createFrame(...)
    frames[#frames + 1] = f
    return f
end

-- The client's dispatch: every frame registered for `event` gets it.
function fireProbeEvent(event, ...)
    for _, f in ipairs(frames) do
        local handler = f.IsEventRegistered and f:IsEventRegistered(event) and f:GetScript("OnEvent")
        if handler then handler(f, event, ...) end
    end
end

function loadForeverProbe()
    local root = (os.getenv("FOREVERPROBE") or "../ForeverProbe"):gsub("\\", "/"):gsub("/$", "")
    local toc = io.open(root .. "/ForeverProbe.toc", "rb")
    if not toc then
        if os.getenv("FOREVERPROBE_OPTIONAL") == "1" then
            io.write("SKIPPED: ForeverProbe isn't here (private, local only); the probe tests run locally\n")
            os.exit(0)
        end
        error("ForeverProbe checkout not found at " .. root .. ": clone it there or set FOREVERPROBE", 0)
    end
    local files = {}
    for line in toc:read("*a"):gmatch("[^\r\n]+") do
        if line:match("%.lua$") and not line:match("^#") then files[#files + 1] = root .. "/" .. line end
    end
    toc:close()
    for _, file in ipairs(files) do assert(loadfile(file))("ForeverProbe", {}) end
    fireProbeEvent("ADDON_LOADED", "ForeverProbe")
    return ForeverProbe
end

-- The probe's files in TOC order with (name, ns), then its ADDON_LOADED.
-- `saved`, if given, runs in between: that is when the client loads the
-- SavedVariables, replacing anything the files made at file scope.
function loadAltStableProbe(saved)
    local toc = assert(io.open("Tools/AltStableProbe/AltStableProbe.toc", "rb"))
    local ns = {}
    for line in toc:read("*a"):gmatch("[^\r\n]+") do
        if line:match("%.lua$") and not line:match("^#") then
            assert(loadfile("Tools/AltStableProbe/" .. line))("AltStableProbe", ns)
        end
    end
    toc:close()
    if saved then saved() end
    fireProbeEvent("ADDON_LOADED", "AltStableProbe")
    return ns
end
