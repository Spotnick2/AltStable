------------------------------------------------------------
-- test_instances.lua — the Raids plugin (#11)
--
-- Forever's launch raids (Barrow Deeps, Hyjal Summit, Onyxia's Lair), with the
-- Vanilla raids kept for their return and shown only when someone is saved.
--
-- BOSS NAMES COME FROM THE LOCKOUT (#17). A static name list would have to
-- match the client's encounter order, which no beta lockout could check, so
-- there is none: the core learns each raid's names from the same API row as
-- the kill flag, and the plugin names bosses only from a list that is stable
-- and as long as the lockout's boss count. Anything else is "X/Y".
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

AltStable = {}
AltStableDB = {}
AltStableConfig = {}
dofile("Compat.lua")
dofile("Theme.lua")   -- the plugin colours headers with AltStable.GetClassRGB
assert(loadfile("Core.lua"))()
dofile("Config.lua")
-- Skin.lua, because this plugin's palette comes from it now - and Glass first,
-- the way the .toc loads them, or SkinIsGlass is false and every colour here
-- would be the flat one.
dofile("tests/libglass.lua"); LoadGlass("AltStable")
dofile("Skin.lua")
dofile("Plugins/Instances/AltStableInstances.lua")
WoW.flushTimers()

local plugin
for _, p in ipairs(AltStable.plugins or {}) do if p.id == "instances" then plugin = p end end
check("the plugin registers itself with the core", plugin ~= nil)
if not plugin then
    print(("test_instances: %d passed, %d failed"):format(passed, failed + 1))
    os.exit(1)
end
local T = plugin._test

------------------------------------------------------------
-- The catalogue
------------------------------------------------------------

local byName = {}
for _, r in ipairs(T.RAIDS) do byName[r.apiName] = r end
-- The launch raids, in the owner's order, always shown.
do
    local launch = {}
    for _, r in ipairs(T.RAIDS) do if not r.later then launch[#launch + 1] = r.apiName end end
    eq("the launch raids, in order", table.concat(launch, ","), "Barrow Deeps,Hyjal Summit,Onyxia's Lair")
    eq("  and first in the list", T.RAIDS[1].apiName, "Barrow Deeps")
end
-- The Vanilla raids come back later: kept, with their art, until they do.
for _, name in ipairs({ "Molten Core", "Blackwing Lair", "Zul'Gurub",
                        "Ruins of Ahn'Qiraj", "Temple of Ahn'Qiraj", "Naxxramas" }) do
    check(name .. " is kept for later", byName[name] ~= nil and byName[name].later == true)
    check("  with its art", byName[name] ~= nil and byName[name].art ~= nil)
end
eq("nine raids in all", #T.RAIDS, 9)
-- Every raid's art ships: a missing file draws nothing and throws nothing.
for _, r in ipairs(T.RAIDS) do
    local f = r.art and io.open("Media/Raids/scene-raid-" .. r.art .. ".tga", "rb")
    check(r.apiName .. " has its art on disk", f ~= nil, tostring(r.art))
    if f then
        local h = f:read(18); f:close()
        check("  uncompressed, 512x256", h:byte(3) == 2 and h:byte(13) + h:byte(14) * 256 == 512
              and h:byte(15) + h:byte(16) * 256 == 256)
    end
end
for _, name in ipairs({ "Karazhan", "Gruul's Lair", "Serpentshrine Cavern", "Black Temple",
                        "Zul'Aman", "Sunwell Plateau", "Tempest Keep", "Magtheridon's Lair" }) do
    check("no " .. name .. " (Outland)", byName[name] == nil)
end
eq("Barrow Deeps binds with its article", T.matchRaid("the barrow deeps")
   and T.matchRaid("the barrow deeps").apiName, "Barrow Deeps")
do
    local named = nil
    for _, r in ipairs(T.RAIDS) do if r.bosses then named = r.apiName end end
    check("no raid carries a boss-name list (#17)", named == nil, tostring(named))
end

------------------------------------------------------------
-- Matching a live lockout name to a row
------------------------------------------------------------

eq("an exact name matches", T.matchRaid("molten core") and T.matchRaid("molten core").apiName, "Molten Core")
eq("a prefixed name still binds", T.matchRaid("blackrock depths: blackwing lair")
   and T.matchRaid("blackrock depths: blackwing lair").apiName, "Blackwing Lair")
eq("an alias binds", T.matchRaid("ahn'qiraj temple") and T.matchRaid("ahn'qiraj temple").apiName,
   "Temple of Ahn'Qiraj")
eq("an unknown raid matches nothing", T.matchRaid("karazhan"), nil)

------------------------------------------------------------
-- Parsing what the core stored
------------------------------------------------------------

local lk = T.parseLockout("si_Molten Core@1", "1700086400|7|10|40|Normal")
check("a lockout parses", lk ~= nil)
eq("  name", lk and lk.name, "Molten Core")
eq("  progress", lk and lk.prog, 7)
eq("  total", lk and lk.total, 10)
eq("  raid size", lk and lk.size, 40)
eq("  difficulty name", lk and lk.diffName, "Normal")
eq("a killmask value is not a lockout", T.parseLockout("si_boss_Molten Core@1", "5"), nil)
eq("a non-si_ field is not a lockout", T.parseLockout("prof_Mining", "300|1|2|3|x"), nil)

------------------------------------------------------------
-- Formatting the reset column
------------------------------------------------------------

eq("a lockout already past reads now", T.fmtDur(-5), "now")
eq("minutes", T.fmtDur(90 * 60), "1h 30m")
eq("hours and minutes", T.fmtDur(3600 + 120), "1h 2m")
eq("days and hours", T.fmtDur(2 * 86400 + 4 * 3600), "2d 4h")
eq("a reset moment reads as a weekday and time", T.resetLabel(1700000000), "Tue 22:13")

local function firstOf(...) return (select(1, ...)) end
check("a lockout resetting within 12h is red", firstOf(T.resetColor(3600)) == 1.00)
check("  within two days, amber", select(2, T.resetColor(30 * 3600)) == 0.82)
check("  further out, green", firstOf(T.resetColor(5 * 86400)) == 0.52)

------------------------------------------------------------
-- Names in the column headers
------------------------------------------------------------

-- Forever gives every character a surname, and first names are not unique, so
-- the header shows the first name rather than a byte-truncated full name.
eq("the first name is what fits a 58px column", T.shortName("Kaleid Sumner", 9), "Kaleid")
eq("a long first name is cut", T.shortName("Bartholomew Smith", 9), "Bartholom")
eq("a short one is left alone", T.shortName("Ash Grey", 9), "Ash")
eq("a missing name is not an error", T.shortName(nil, 9), "?")

-- First names are not unique here, so two "Kaleid" columns would be useless:
-- the surname initial is added only where the shown names would collide.
do
    local names = T.headerNames({ { name = "Kaleid Sumner" }, { name = "Kaleid Thorne" },
                                  { name = "Ash Grey" } }, 9)
    eq("a collision gets the surname initial", names[1], "Kaleid S")
    eq("  for both of them", names[2], "Kaleid T")
    eq("a name that does not collide is left alone", names[3], "Ash")
    local solo = T.headerNames({ { name = "Kaleid Sumner" } }, 9)
    eq("one character needs no initial", solo[1], "Kaleid")
    local nosur = T.headerNames({ { name = "Kaleid" }, { name = "Kaleid" } }, 9)
    eq("two identical names stay identical - nothing distinguishes them", nosur[1], "Kaleid")

    -- One initial is not always enough: two surnames starting with the same
    -- letter would both read "Kaleid S".
    local same = T.headerNames({ { name = "Kaleid Sumner" }, { name = "Kaleid Stone" } }, 9)
    check("colliding initials extend until the labels differ", same[1] ~= same[2],
          tostring(same[1]) .. " / " .. tostring(same[2]))
    eq("  taking more of the surname", same[1], "Kaleid Su")

    -- An accented surname: taking the first BYTE renders invalid UTF-8.
    local acute = string.char(0xC3, 0x89)   -- E with an acute accent, 2 bytes
    local accentedPair = T.headerNames({ { name = "Kaleid " .. acute .. "toile" },
                                         { name = "Kaleid Thorne" } }, 9)
    check("an accented initial is a whole character", accentedPair[1]:find(acute, 1, true) ~= nil,
          accentedPair[1])
    check("  and never a lone lead byte",
          accentedPair[1]:byte(#accentedPair[1]) ~= 0xC3, accentedPair[1])
end

-- Whole characters, not bytes.
eq("one character of an ASCII name", T.firstChars("Sumner", 1), "S")
eq("two characters", T.firstChars("Sumner", 2), "Su")
eq("a two-byte character counts as one", T.firstChars(string.char(0xC3, 0x89) .. "toile", 1),
   string.char(0xC3, 0x89))
eq("asking for more than there is returns it all", T.firstChars("Su", 5), "Su")

-- The label is abbreviated to fit 58px, so hovering a header has to give the
-- full name - that is what settles identity when two labels still look alike.
do
    WoW.tooltipLines = {}
    local hdr = T.getHeader(1)
    hdr.fullName, hdr.class, hdr.level = "Kaleid Sumner", "MAGE", 60
    local onEnter = hdr:GetScript("OnEnter")
    check("the header has a hover handler", type(onEnter) == "function")
    if type(onEnter) == "function" then
        onEnter(hdr)
        eq("hovering shows the full name", WoW.tooltipLines[1], "Kaleid Sumner")
        check("  and the level", WoW.tooltipLines[2] == "Level 60", tostring(WoW.tooltipLines[2]))
    end
end
-- "Ceridwen" with an accented e (2 bytes): cutting at 9 bytes would split it.
local accented = "Cerid" .. string.char(0xC3, 0xA9) .. "wen"
local cut = T.shortName(accented, 6)
check("a multibyte character is never cut in half", cut == "Cerid" or cut == "Cerid" .. string.char(0xC3, 0xA9),
      cut)

------------------------------------------------------------
-- The read model
------------------------------------------------------------

WoW.reset()
AltStableDB = {
    ["Player-A-1"] = { guid = "Player-A-1", name = "Raider", class = "WARRIOR", level = 60, ilvl = 66,
                       ["si_Molten Core@1"] = "1700086400|7|10|40|Normal",
                       ["si_boss_Molten Core@1"] = "127",
                       ["si_Onyxia's Lair@1"] = "1700086400|1|1|40|Normal" },
    ["Player-B-1"] = { guid = "Player-B-1", name = "Alt", class = "MAGE", level = 60, ilvl = 60 },
    ["Player-C-1"] = { guid = "Player-C-1", name = "Leveller", class = "ROGUE", level = 22, ilvl = 20 },
    ["Player-D-1"] = { guid = "Player-D-1", name = "Saved Low", class = "PRIEST", level = 30, ilvl = 25,
                       ["si_Zul'Gurub@1"] = "1700086400|2|8|20|Normal" },
}
local allChars, lookup = T.gather()
eq("every character is a candidate column", #allChars, 4)
check("a saved character has its lockouts", lookup["Player-A-1"] ~= nil)
eq("  keyed by the canonical raid name", lookup["Player-A-1"]["molten core"].prog, 7)
eq("  a second lockout too", lookup["Player-A-1"]["onyxia's lair"].total, 1)
check("an unsaved character has none", lookup["Player-B-1"] == nil)
eq("the killmask is read with its lockout (#17)", lookup["Player-A-1"]["molten core"].mask, 127)
eq("  but no names without a learned list", lookup["Player-A-1"]["molten core"].bosses, nil)

-- Boss names, from the list the core learned off a lockout (#17).
do
    local names8 = { "Chillhowl", "Khalith the Dreadspinner", "Amethrax", "Ravus and Darlissa",
                     "Elder Tangleclaw", "Well of Sorrow", "Del'lynar Songwood", "Sonya Darkhallow" }
    local function deeps(mask, total)
        AltStableDB["Player-Deep-1"] = { guid = "Player-Deep-1", name = "Delver", class = "MAGE", level = 60,
                                         ["si_Barrow Deeps@14"] = "1700086400|3|" .. (total or 8) .. "|20|Normal",
                                         ["si_boss_Barrow Deeps@14"] = mask and tostring(mask) or nil }
        local _, lk = T.gather()
        AltStableDB["Player-Deep-1"] = nil
        return lk["Player-Deep-1"]["barrow deeps"]
    end
    AltStableConfig.raidEncounters = { ["Barrow Deeps@14"] = { names = names8 } }
    local b = deeps(1 + 4 + 128).bosses   -- the 1st, 3rd and 8th dead
    check("a learned list names the bosses", b ~= nil and #b == 8, b and #b)
    eq("  in encounter order", b and b[2].name, "Khalith the Dreadspinner")
    eq("  bit 0 is the first boss", b and b[1].killed, true)
    eq("  bit 1 the second", b and b[2].killed, false)
    eq("  bit 2 the third", b and b[3].killed, true)
    eq("  bit 7 the eighth", b and b[8].killed, true)
    eq("no mask stored: nobody killed yet", deeps(nil).bosses[1].killed, false)
    eq("a list of another length names nothing", deeps(5, 9).bosses, nil)
    AltStableConfig.raidEncounters["Barrow Deeps@14"].unstable = true
    eq("an unstable list names nothing", deeps(5).bosses, nil)
    AltStableConfig.raidEncounters = { ["Barrow Deeps@1"] = { names = names8 } }
    eq("another difficulty's list is not used", deeps(5).bosses, nil)
    AltStableConfig.raidEncounters = nil
end

-- Two lockouts for the same raid at different difficulties: one row, one rule.
-- Without it, pairs() order decides, and it can change between refreshes.
do
    local a = { expires = 100, prog = 3, diff = 1 }
    local b = { expires = 200, prog = 1, diff = 2 }
    eq("the later reset wins", T.PreferLockout(a, b), b)
    eq("  whichever order they arrive in", T.PreferLockout(b, a), b)
    local c = { expires = 100, prog = 5, diff = 2 }
    eq("same reset: more progress wins", T.PreferLockout(a, c), c)
    local d = { expires = 100, prog = 3, diff = 3 }
    eq("same reset and progress: the lower difficulty", T.PreferLockout(a, d), a)
    eq("nothing to compare against", T.PreferLockout(nil, a), a)
end

-- ...and gather applies it: the core stores one field per difficulty, the grid
-- has one row per raid.
do
    AltStableDB["Player-Two-1"] = { guid = "Player-Two-1", name = "Twice", class = "MAGE", level = 60,
                                    ["si_Naxxramas@1"] = "1700086400|3|15|40|Normal",
                                    ["si_Naxxramas@2"] = "1700172800|1|15|40|Heroic" }
    local _, lk2 = T.gather()
    local kept = lk2["Player-Two-1"]["naxxramas"]
    eq("two difficulties collapse to the later reset", kept.expires, 1700172800)
    eq("  deterministically, not whichever pairs() saw last", kept.prog, 1)
    AltStableDB["Player-Two-1"] = nil
end

-- An expired lockout is not a lockout: left in the model it would keep a
-- low-level character in the columns, and an unknown raid in the Other rows,
-- showing nothing but dashes.
do
    AltStableDB["Player-Old-1"] = { guid = "Player-Old-1", name = "Lapsed", class = "MAGE", level = 30,
                                    ["si_Molten Core@1"] = (WoW.now - 60) .. "|7|10|40|Normal" }
    local chars3, lk4 = T.gather()
    eq("an expired lockout is dropped", lk4["Player-Old-1"], nil)
    local cols3 = T.columnsForView(chars3, lk4)
    local kept3 = false
    for _, c in ipairs(cols3) do if c.guid == "Player-Old-1" then kept3 = true end end
    check("  and stops holding a column open", not kept3)
    AltStableDB["Player-Old-1"] = nil
end

-- An open tab drops a save when it expires, without waiting for a scan.
do
    WoW.timers = {}
    T.ScheduleExpiryRefresh({ a = { mc = { expires = WoW.now + 600 } },
                              b = { zg = { expires = WoW.now + 120 } } })
    eq("a refresh is scheduled", #WoW.timers, 1)
    check("  at the soonest expiry", WoW.timers[1].delay >= 120 and WoW.timers[1].delay <= 122,
          tostring(WoW.timers[1].delay))
    WoW.timers = {}
    T.ScheduleExpiryRefresh({})
    eq("nothing to expire, nothing scheduled", #WoW.timers, 0)
end

-- The footer counts tracked characters, not visible columns (UI code, so this
-- reads the source).
do
    local src = io.open("Plugins/Instances/AltStableInstances.lua"):read("*a")
    local stats = src:match("statsFS:SetText%((.-)%)%s*" .. "statsBar:Show")
    -- The call site, not the definition: "ScheduleExpiryRefresh(lookup)" also
    -- matches "local function ScheduleExpiryRefresh(lookup)".
    local refreshBody = src:match("function AT_SI.Refresh%(%)(.-)\nend")
    check("a refresh schedules the next expiry",
          refreshBody ~= nil and refreshBody:find("ScheduleExpiryRefresh(lookup)", 1, true) ~= nil)
    check("the footer frame gets the backdrop template its theming needs",
          src:find('statsBar = CreateFrame("Frame", nil, panel, "BackdropTemplate")', 1, true) ~= nil)
    check("the footer reports #allChars as tracked",
          stats ~= nil and stats:find("#allChars", 1, true) ~= nil, tostring(stats))
end

local cols = T.columnsForView(allChars, lookup)
local names = {}
for _, c in ipairs(cols) do names[#names + 1] = c.name end
eq("columns: level 60s plus anyone saved", table.concat(names, ","), "Raider,Alt,Saved Low")
check("a low-level character with no lockout is left out",
      not table.concat(names, ","):find("Leveller", 1, true))

local rows = T.buildDisplayRows(lookup)
local groups, raidRows = 0, 0
for _, r in ipairs(rows) do
    if r.isGroup then groups = groups + 1 else raidRows = raidRows + 1 end
end
eq("one group header", groups, 1)
-- The launch three, plus the returning raids someone is saved to (Molten Core
-- and Zul'Gurub in this fixture) - not the four nobody is.
do
    local shown = {}
    for _, r in ipairs(rows) do if r.raid then shown[#shown + 1] = r.raid.apiName end end
    eq("  the launch raids, then the returning ones someone is saved to", table.concat(shown, ","),
       "Barrow Deeps,Hyjal Summit,Onyxia's Lair,Molten Core,Zul'Gurub")
end

-- The column cap must not drop a saved character: they sort last (low level),
-- so a plain truncation would cut exactly the ones the filter exists to keep.
do
    local many, look = {}, { ["Player-Saved-1"] = { ["zul'gurub"] = { prog = 1 } } }
    many[1] = { guid = "Player-Saved-1", name = "Bank Alt", level = 30, ilvl = 20 }
    for i = 1, 60 do
        many[#many + 1] = { guid = "Player-F-" .. i, name = "Filler" .. i, level = 60, ilvl = 100 }
    end
    local capped = T.columnsForView(many, look)
    eq("columns are capped", #capped, 40)
    local kept = false
    for _, c in ipairs(capped) do if c.guid == "Player-Saved-1" then kept = true end end
    check("the saved low-level character survives the cap", kept)
end

-- A lockout the catalogue doesn't know still shows, under "Other".
AltStableDB["Player-E-1"] = { guid = "Player-E-1", name = "Explorer", class = "DRUID", level = 60,
                              ["si_Some New Raid@1"] = "1700086400|1|5|20|Normal" }
local _, lookup2 = T.gather()
local rows2 = T.buildDisplayRows(lookup2)
local other, otherRow = false, nil
for _, r in ipairs(rows2) do
    if r.isGroup and r.key == "other" then other = true end
    if r.raid and r.raid.isOther then otherRow = r.raid.display end
end
check("an unknown lockout gets an Other group", other)
eq("  and its own row", otherRow, "Some New Raid")

-- Those rows are sorted and bounded: the panel has no vertical scroller, so an
-- unbounded list would run under the stats bar with no way to reach it.
do
    AltStableDB = { ["Player-F-1"] = { guid = "Player-F-1", name = "Finder", class = "MAGE", level = 60 } }
    for i = 1, 14 do
        AltStableDB["Player-F-1"]["si_Zone " .. string.char(90 - i) .. "@1"] = "1700086400|1|5|20|Normal"
    end
    local _, lk3 = T.gather()
    local rows3 = T.buildDisplayRows(lk3)
    local others, label = {}, nil
    for _, r in ipairs(rows3) do
        if r.isGroup and r.key == "other" then label = r.label end
        if r.raid and r.raid.isOther then others[#others + 1] = r.raid.display end
    end
    eq("the Other rows are bounded", #others, 10)
    check("  the header says how many there are", label and label:find("10 of 14", 1, true) ~= nil, label)
    local sorted = true
    for i = 2, #others do if others[i - 1] > others[i] then sorted = false end end
    check("  and they are in a stable, sorted order", sorted, table.concat(others, ","))
end

-- Collapsing hides a group's rows, and the state is remembered.
T.toggleCollapse("vanilla")
check("a collapsed group is remembered", T.isCollapsed("vanilla"))
local collapsed = T.buildDisplayRows(lookup)
local shown = 0
for _, r in ipairs(collapsed) do if not r.isGroup then shown = shown + 1 end end
eq("  and its raids are hidden", shown, 0)
T.toggleCollapse("vanilla")
check("expanding brings them back", not T.isCollapsed("vanilla"))

------------------------------------------------------------
-- The grid's own palette comes from the skin (#97)
------------------------------------------------------------
-- This suite has never built a panel - it is pure logic - so every colour this
-- plugin paints has been unasserted, which is how a column header shipped
-- darker than the rows it labels. A panel is buildable here with a stand-in for
-- the sheet, and that is cheaper than a third PR that names the gap again.
do
    AltStable.LAYOUT = AltStable.LAYOUT or {}
    AltStable.LAYOUT.TITLE_H       = AltStable.LAYOUT.TITLE_H or 30
    AltStable.LAYOUT.SIDEBAR_WIDTH = AltStable.LAYOUT.SIDEBAR_WIDTH or 230
    AltStable.LAYOUT.FOOTER_HEIGHT = AltStable.LAYOUT.FOOTER_HEIGHT or 22

    local main = CreateFrame("Frame", "AltStableSheet", UIParent)
    main:SetSize(1000, 600)
    for _, key in ipairs({ "bodyScroll", "frozenScroll", "headerScroll",
                           "frozenHeader", "hScrollBar", "totalsBar" }) do
        main[key] = CreateFrame("Frame", nil, main)
    end

    -- Anchored beside the sidebar's edge through the sheet's helper (#150), so
    -- it follows a collapse. Declining here keeps the fixed-offset fallback.
    local besideSidebar
    AltStable.AnchorBesideSidebar = function(region) besideSidebar = region; return false end
    local ok, err = pcall(plugin.OnActivate, main)
    check("the Raids panel builds", ok, tostring(err))
    check("the panel anchors beside the sidebar's edge (#150)", besideSidebar ~= nil)
    check("  and re-lays out when the window changes size", type(plugin.OnResize) == "function")
    AltStable.AnchorBesideSidebar = nil
    if ok then
        local hdr = T.HeaderBG and T.HeaderBG()
        check("  and has a column header", hdr ~= nil)
        if hdr and hdr._colorTexture then
            local want = { AltStable.SkinCardColor() }
            local got = hdr._colorTexture
            local same = true
            for i = 1, 4 do if got[i] ~= want[i] then same = false end end
            check("  painted with the skin's card, not a literal", same,
                  table.concat(got, ","))
            -- The failure this closes: a header DARKER than the rows it
            -- labels. Against a band that was actually PAINTED - comparing it
            -- to the same helper that painted the header is equal by
            -- construction and says nothing about the ordering.
            local firstBand
            for _, b in ipairs(T.Bands() or {}) do
                if b.row and b.row._colorTexture then firstBand = b.row; break end
            end
            check("  there is a painted row band to compare against", firstBand ~= nil)
            if firstBand then
                check("  and the header is no darker than one",
                      got[1] >= firstBand._colorTexture[1],
                      ("header %s vs band %s"):format(got[1], firstBand._colorTexture[1]))
            end
        end

        -- The bands and group headers are only painted once there are rows to
        -- paint, which depends on lockout data this suite does not create - so
        -- whichever exist are checked, and the count is reported rather than
        -- assumed.
        local painted = 0
        for _, band in ipairs(T.Bands() or {}) do
            if band.row and band.row._colorTexture then
                painted = painted + 1
                local want = { AltStable.SkinCardColor() }
                check("a row band is the skin's card",
                      band.row._colorTexture[1] == want[1]
                      and band.row._colorTexture[4] == want[4],
                      table.concat(band.row._colorTexture, ","))
            end
        end
        for _, gh in ipairs(T.Groups() or {}) do
            if gh.bg and gh.bg._colorTexture then
                local want = { AltStable.SkinCardGroupColor() }
                check("a group header is the skin's",
                      gh.bg._colorTexture[1] == want[1],
                      table.concat(gh.bg._colorTexture, ","))
            end
        end
        check("at least the header was painted", hdr ~= nil)

        -- Hovering a cell names each boss, killed or not (#17).
        do
            local guid = "Player-Hover-1"
            AltStableDB[guid] = { guid = guid, name = "Delver Hover", class = "MAGE", level = 60, ilvl = 70,
                                  ["si_Onyxia's Lair@1"] = (WoW.now + 86400) .. "|1|1|40|Normal",
                                  ["si_boss_Onyxia's Lair@1"] = "1",
                                  ["si_Hyjal Summit@1"] = (WoW.now + 86400) .. "|0|2|20|Normal" }
            AltStableConfig.raidEncounters = { ["Onyxia's Lair@1"] = { names = { "Onyxia" } } }
            T.Refresh()
            local onyCell, hyjalCell
            for _, col in pairs(T.Cells() or {}) do
                for _, cell in pairs(col) do
                    local d = cell.info
                    if d and d.charName == "Delver Hover" then
                        if d.raidName == "Onyxia's Lair" then onyCell = cell end
                        if d.raidName == "Hyjal Summit" then hyjalCell = cell end
                    end
                end
            end
            check("the saved character has an Onyxia cell", onyCell ~= nil)
            if onyCell then
                WoW.tooltipLines = {}
                onyCell:GetScript("OnEnter")(onyCell)
                local text = table.concat(WoW.tooltipLines, " / ")
                check("  hovering it names the boss as killed", text:find("Onyxia|Killed", 1, true), text)
            end
            if hyjalCell then
                WoW.tooltipLines = {}
                hyjalCell:GetScript("OnEnter")(hyjalCell)
                local text = table.concat(WoW.tooltipLines, " / ")
                check("a raid with no learned names shows progress only",
                      text:find("Progress: 0/2", 1, true) and not text:find("|Killed", 1, true)
                      and not text:find("Not killed", 1, true), text)
            end
            AltStableDB[guid], AltStableConfig.raidEncounters = nil, nil
        end

        -- Nobody level 60 and nobody saved: the raids still show (owner's
        -- call), with a word where the columns will go.
        do
            local held = AltStableDB
            AltStableDB = { ["Player-Low-1"] = { guid = "Player-Low-1", name = "Low Alt", class = "MAGE", level = 18 } }
            T.Refresh()
            local shownBands, withArt = 0, 0
            for _, b in ipairs(T.Bands() or {}) do
                if b.row and b.row:IsShown() then shownBands = shownBands + 1 end
                if b.art and b.art:IsShown() then withArt = withArt + 1 end
            end
            eq("no columns yet: the three launch raids still show", shownBands, 3)
            eq("  each with its art", withArt, 3)
            eq("  and a word where the columns go", T.EmptyText(), "Your level-60 characters show here.")
            AltStableDB = {}
            T.Refresh()
            eq("no characters at all says so", T.EmptyText(), "No characters tracked yet.")
            AltStableDB = { ["Player-Max-1"] = { guid = "Player-Max-1", name = "Max Alt", class = "MAGE", level = 60 } }
            T.Refresh()
            eq("a level-60 column takes the word away", T.EmptyText(), nil)
            AltStableDB = held
            T.Refresh()
        end

        -- Sized through the sheet's request (#150), so a maximized window
        -- stays maximized; and measured from the sidebar as it is now, so a
        -- collapsed one asks for less.
        local asked
        local realReq = AltStable.RequestWindowSize
        AltStable.RequestWindowSize = function(w, h) asked = { w, h } end
        plugin.OnResize()
        check("the Raids tab sizes the window through the request", asked ~= nil)
        check("  and says so, so a geometry animation lays it out before measuring",
              plugin.sizesWindow == true)
        local fullW = asked and asked[1]
        AltStable.LAYOUT.SIDEBAR_WIDTH = 56
        plugin.OnResize()
        eq("  narrower by what a collapsed sidebar gives back, down to its floor",
           asked and asked[1], fullW and math.max(fullW - 174, 560))
        check("  and narrower at all", asked and fullW and asked[1] < fullW)
        AltStable.LAYOUT.SIDEBAR_WIDTH = 230
        AltStable.RequestWindowSize = realReq
    end
end

print(("test_instances: %d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
