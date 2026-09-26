------------------------------------------------------------
-- test_whaticon.lua — naming the texture under the cursor (/asicon)
--
-- The command exists because guessing a texture path from a screenshot is how
-- you ship the green question mark. It shipped with a bug that threw on
-- ATLAS-BACKED art - the exact case it was written for - because `..` binds
-- tighter than `or` and the fallback chain concatenated a nil before `or` could
-- reach it. One test with an atlas and no path would have caught it, and there
-- was no test at all. So: an atlas, a bare file id, and a path each get one.
------------------------------------------------------------

dofile("tests/wow_stubs.lua")

local passed, failed = 0, 0
local function check(name, ok, detail)
    if ok then passed = passed + 1
    else failed = failed + 1; print("  FAIL: " .. name .. (detail and ("  -- " .. detail) or "")) end
end
local function eq(name, got, want)
    check(name, got == want, "got " .. tostring(got) .. ", want " .. tostring(want))
end

AltStable, AltStableDB, AltStableConfig = {}, {}, {}
AltStableProbe = {}
dofile("Compat.lua")
dofile("Tools/AltStableProbe/WhatIcon.lua")

local T = AltStableProbe._testIcon
check("the probe exposes a seam", T ~= nil)
if not T then
    print(("test_whaticon: %d passed, %d failed"):format(passed, failed + 1))
    os.exit(1)
end

-- A texture that answers only what it was given, like the real widget.
local function tex(fields)
    local t = { _shown = fields.shown ~= false }
    t.GetObjectType = function() return "Texture" end
    t.GetAtlas = function() return fields.atlas end
    t.GetTextureFilePath = function() return fields.path end
    t.GetTextureFileID = function() return fields.id end
    t.IsShown = function(self) return self._shown end
    return t
end

------------------------------------------------------------
-- Describing one texture
------------------------------------------------------------

do
    -- THE CRASH. Atlas-backed art with no path is what a Blizzard button
    -- usually carries, and it is the whole reason this command exists.
    local ok, line = pcall(T.Describe, tex({ atlas = "worldquest-icon" }))
    check("atlas-backed art does not throw", ok, tostring(line))
    check("  and is named", ok and line and line:find("worldquest-icon", 1, true) ~= nil,
          tostring(line))

    -- A bare file id is still reusable - SetTexture takes one - so it has to
    -- be printed rather than treated as nothing.
    local okId, idLine = pcall(T.Describe, tex({ id = 4620672 }))
    check("a bare file id does not throw", okId, tostring(idLine))
    check("  and is named", okId and idLine and idLine:find("4620672", 1, true) ~= nil,
          tostring(idLine))

    local pathLine = T.Describe(tex({ path = "Interface\\Icons\\INV_Misc_GroupNeedMore" }))
    check("a path is named",
          pathLine and pathLine:find("INV_Misc_GroupNeedMore", 1, true) ~= nil,
          tostring(pathLine))

    -- ALL of them, when a texture has more than one. The broken version printed
    -- only the first, which is the other half of the same mistake.
    local both = T.Describe(tex({ path = "Interface\\Foo", atlas = "bar-atlas" }))
    check("a texture with a path AND an atlas reports both",
          both and both:find("Interface\\Foo", 1, true) and both:find("bar-atlas", 1, true),
          tostring(both))

    -- Empty layers are skipped, or they bury the answer.
    eq("a texture set to nothing is skipped", T.Describe(tex({})), nil)
    eq("  and so is a zero file id", T.Describe(tex({ id = 0 })), nil)
    eq("  a non-texture region is not described", T.Describe({ GetObjectType = function() return "FontString" end }), nil)
    eq("  and neither is nothing at all", T.Describe(nil), nil)

    local hidden = T.Describe(tex({ path = "Interface\\Hidden", shown = false }))
    check("a hidden texture says so", hidden and hidden:find("hidden", 1, true) ~= nil,
          tostring(hidden))
end

------------------------------------------------------------
-- What came back from GetMouseFoci
------------------------------------------------------------
-- A widget IS a table with no array part, so type() cannot tell "a list of
-- frames" from "one frame, first of a tuple" - the struct-vs-tuple false friend
-- this whole probe suite exists to catch. Guessing wrong means reporting
-- "nothing under the cursor" while the button is plainly hovered.

do
    local frame = { GetObjectType = function() return "Frame" end }

    local list, shape = T.FociList({ frame, frame })
    eq("a list is recognised", shape, "list")
    eq("  with its frames", #list, 2)

    local tuple, tshape = T.FociList(frame, frame, frame)
    eq("frames returned as a tuple are recognised as one", tshape, "tuple")
    eq("  and collected rather than dropped", #tuple, 3)

    local none, nshape = T.FociList()
    eq("no return at all is nothing", nshape, "nothing")
    eq("  with an empty list", #none, 0)
    eq("a nil return is nothing too", select(2, T.FociList(nil)), "nothing")
end

------------------------------------------------------------
-- The whole command
------------------------------------------------------------

do
    local said = {}
    local function sink(line) said[#said + 1] = line end

    local iconTex = tex({ atlas = "lfg-eye" })
    local plain   = tex({ path = "Interface\\Buttons\\UI-Panel-Button-Up" })
    local button = {
        GetObjectType = function() return "Frame" end,
        GetDebugName = function() return "SideButton3" end,
        -- The same texture is BOTH a region and the named field, which is how a
        -- real Button is built. It must be reported once, not twice.
        GetRegions = function() return plain, iconTex end,
        Icon = iconTex,
    }
    _G.GetMouseFoci = function() return { button } end

    local lines = T.WhatIsUnderTheCursor(sink)
    local all = table.concat(said, "\n")

    check("the frame is named", all:find("SideButton3", 1, true) ~= nil, all)
    check("  its atlas is reported", all:find("lfg-eye", 1, true) ~= nil, all)
    check("  and its plain texture", all:find("UI-Panel-Button-Up", 1, true) ~= nil, all)

    local hits = 0
    for _ in all:gmatch("lfg%-eye") do hits = hits + 1 end
    eq("a texture that is both a region and a named field is reported once", hits, 1)

    -- The returned lines are what the copy window shows, so they must be free
    -- of colour codes - a path with |cffffff00 glued to it is not a path.
    local joined = table.concat(lines, "\n")
    check("the copyable lines carry no colour codes",
          joined:find("|c", 1, true) == nil and joined:find("|r", 1, true) == nil,
          joined)
    check("  but do carry the answer", joined:find("lfg-eye", 1, true) ~= nil, joined)

    -- Nothing hovered.
    said = {}
    _G.GetMouseFoci = function() return {} end
    T.WhatIsUnderTheCursor(sink)
    check("nothing under the cursor says so",
          table.concat(said, " "):find("nothing under the cursor", 1, true) ~= nil,
          table.concat(said, " "))

    -- A frame with no art of its own.
    said = {}
    _G.GetMouseFoci = function()
        return { { GetObjectType = function() return "Frame" end,
                   GetName = function() return "Empty" end,
                   GetRegions = function() return tex({}) end } }
    end
    T.WhatIsUnderTheCursor(sink)
    check("a frame that draws nothing says so, rather than nothing at all",
          table.concat(said, " "):find("draws no texture", 1, true) ~= nil,
          table.concat(said, " "))

    -- The API missing entirely.
    said = {}
    _G.GetMouseFoci = nil
    T.WhatIsUnderTheCursor(sink)
    check("a client without GetMouseFoci is reported, not crashed into",
          table.concat(said, " "):find("GetMouseFoci is missing", 1, true) ~= nil,
          table.concat(said, " "))
end

------------------------------------------------------------
-- It waits for you to point at the thing
------------------------------------------------------------
-- The first version read the cursor the instant the command ran, which sounds
-- right and is useless: typing "/asicon" means being at the chat box, so the
-- pointer has already left whatever you wanted named. The first real use came
-- back "UI-HUD-ExperienceBar-Fill-Prediction" - the status bar behind the chat
-- frame, correctly identified and entirely beside the point.

do
    WoW.timers = {}
    local said = {}
    local answered = false
    _G.GetMouseFoci = function()
        answered = true
        return { { GetObjectType = function() return "Frame" end,
                   GetName = function() return "TheThing" end,
                   GetRegions = function()
                       local t = { GetObjectType = function() return "Texture" end,
                                   GetAtlas = function() return "the-atlas" end,
                                   GetTextureFilePath = function() return nil end,
                                   GetTextureFileID = function() return 0 end,
                                   IsShown = function() return true end }
                       return t
                   end } }
    end

    T.ReadAfterDelay()
    check("the read is pending", T.reading())
    check("  and nothing was read yet", not answered,
          "it read the cursor while the player was still at the chat box")

    -- Tick down. It must not fire early.
    for i = 1, T.READ_DELAY - 1 do
        WoW.flushTimers()
        check(("  still waiting after %d tick(s)"):format(i), not answered)
    end

    WoW.flushTimers()
    check("it reads once the countdown ends", answered)
    check("  and stops being pending", not T.reading())

    -- The ticker must not keep firing afterwards.
    answered = false
    WoW.flushTimers()
    check("  and does not read again", not answered,
          "the ticker was left running")
end

do
    -- THROUGH THE REAL COMMAND, because which of the two it calls is the whole
    -- fix. Calling ReadAfterDelay directly proves the countdown works and says
    -- nothing about whether /asicon uses it - and "it reads immediately" is
    -- exactly the bug being fixed.
    WoW.timers = {}
    local reads = 0
    _G.GetMouseFoci = function() reads = reads + 1; return {} end

    SlashCmdList["ASICON"]("")
    eq("bare /asicon does not read straight away", reads, 0)
    check("  it counts down instead", T.reading())
    for _ = 1, T.READ_DELAY do WoW.flushTimers() end
    eq("  and reads when the countdown ends", reads, 1)

    SlashCmdList["ASICON"]("now")
    eq("/asicon now reads immediately", reads, 2)
    check("  without queueing anything", not T.reading())

    SlashCmdList["ASICON"]("")
    check("a countdown is running", T.reading())
    SlashCmdList["ASICON"]("cancel")
    check("/asicon cancel stops it", not T.reading())
    for _ = 1, T.READ_DELAY + 1 do WoW.flushTimers() end
    eq("  and it never reads", reads, 2)

    SlashCmdList["ASICON"]("nonsense")
    eq("an unknown argument reads nothing", reads, 2)
    check("  and starts nothing", not T.reading())
end

do
    -- Cancelling, and not stacking.
    WoW.timers = {}
    local answered = false
    _G.GetMouseFoci = function() answered = true; return {} end

    T.ReadAfterDelay()
    T.ReadAfterDelay()          -- a second one must not queue a second read
    check("asking twice does not start two countdowns", T.reading())
    check("cancelling reports it cancelled something", T.CancelRead())
    check("  and there is nothing pending", not T.reading())
    eq("  cancelling nothing says so", T.CancelRead(), false)

    for _ = 1, T.READ_DELAY + 2 do WoW.flushTimers() end
    check("a cancelled countdown never reads", not answered)
end

print(("test_whaticon: %d passed, %d failed"):format(passed, failed))
os.exit(failed > 0 and 1 or 0)
