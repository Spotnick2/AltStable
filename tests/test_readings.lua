------------------------------------------------------------
-- test_readings.lua: durability, location and guild rank on the record
-- (#508, #395, #515), read as measured on 1.60.1.71139.
--
-- The rules under test (Readings.lua, the plan on #508): unknown is nil and
-- never 0/100/""; a durability read is a snapshot or nothing; an empty zone
-- keeps the stored one; the guild is read only after PLAYER_LOGIN, and a guild
-- with no name yet keeps what is stored. Each changed value stamps the record
-- (TouchCharacter); an unchanged one doesn't.
--
--   & 'C:\Program Files (x86)\Lua\5.1\lua.exe' tests\test_readings.lua
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

WoW.reset()
AltStable = AltStable or {}
dofile("Compat.lua")
dofile("Scanner.lua")       -- AltStable.GEAR_SLOTS
dofile("Readings.lua")

local R = AltStable.Readings
check("Readings is loaded", R ~= nil)

local touched = 0
AltStable.TouchCharacter = function() touched = touched + 1 end
AltStable.RefreshSheet = function() end

local function Durable(map)          -- slot id -> { current, max }
    WoW.durability = map
end

------------------------------------------------------------
-- Durability (#508)
------------------------------------------------------------
do
    local c = {}
    -- As measured: armour answers current/max, rings and the cloak nil/nil.
    Durable({ [1] = { 39, 40 }, [5] = { 36, 60 }, [15] = nil, [11] = nil, [16] = { 90, 90 } })
    check("a read with damage changes the record", R.Durability(c, false))
    eq("the lowest worn item, as a whole percent", c.durMin, 60)
    eq("each slot below 100 kept", c.dur_head, 97)
    eq("  the chest", c.dur_chest, 60)
    eq("  a full one isn't", c.dur_mainhand, nil)
    eq("  nor a ring with no durability", c.dur_ring1, nil)
    check("the same read again changes nothing", not R.Durability(c, false))

    Durable({ [1] = { 40, 40 }, [5] = { 60, 60 } })
    check("a repair changes it", R.Durability(c, false))
    eq("  all full: 100", c.durMin, 100)
    eq("  the repaired slots' readings gone", (c.dur_head or 0) + (c.dur_chest or 0), 0)

    Durable({ [5] = { 29, 50 } })
    R.Durability(c, false)
    eq("exactly 58 % is 58, not 57 (multiplied before dividing)", c.durMin, 58)

    Durable({ [7] = { 0, 45 }, [5] = { 60, 60 } })
    R.Durability(c, false)
    eq("a broken item counts, as 0 %", c.durMin, 0)
    eq("  its slot at 0", c.dur_legs, 0)

    Durable({ [11] = nil, [15] = nil })
    R.Durability(c, false)
    eq("nothing durable worn: unknown, not 100", c.durMin, nil)
    eq("  and no slot reading left", c.dur_legs, nil)
    Durable({ [5] = { 60, 60 } })
    R.Durability(c, false)
    Durable({})
    check("all full, then nothing durable: a change, though no slot reading moved", R.Durability(c, false))

    -- Unreadable (secret): never measured, but a wrong 100 % must not be possible.
    Durable({ [1] = { 20, 40 }, [5] = { 60, 60 } })
    R.Durability(c, false)
    eq("(a snapshot: 50)", c.durMin, 50)
    Durable({ [1] = { WoW.secret(10), 40 }, [5] = { 60, 60 } })
    check("an unreadable read with the same gear changes nothing", not R.Durability(c, false))
    eq("  the last snapshot stands", c.durMin, 50)
    eq("  its slot too", c.dur_head, 50)
    check("an unreadable read after a swap changes the record", R.Durability(c, true))
    eq("  the snapshot dropped: unknown", c.durMin, nil)
    eq("  the old helm's reading gone with it", c.dur_head, nil)
    Durable({})
end

------------------------------------------------------------
-- Location (#395)
------------------------------------------------------------
do
    local c = { zone = "Orgrimmar", subzone = "The Drag" }
    WoW.zone, WoW.subzone = nil, ""                  -- login +2 s, measured
    check("no zone yet (login): nothing changes", not R.Location(c))
    eq("  the stored zone kept", c.zone, "Orgrimmar")
    eq("  and subzone", c.subzone, "The Drag")

    WoW.zone, WoW.subzone = "Orgrimmar", "Valley of Strength"
    check("a new subzone changes it", R.Location(c))
    eq("  the subzone", c.subzone, "Valley of Strength")
    check("the same place again changes nothing", not R.Location(c))

    WoW.zone, WoW.subzone = "Orgrimmar", "Orgrimmar"  -- a city's centre, measured
    R.Location(c)
    eq("a subzone that is the zone is stored once", c.subzone, nil)

    WoW.zone, WoW.subzone = "Durotar", ""
    R.Location(c)
    eq("open world, no subzone: the zone", c.zone, "Durotar")
    eq("  and the old subzone gone", c.subzone, nil)

    WoW.zone, WoW.subzone = "Ragefire Chasm", ""     -- an instance, measured
    R.Location(c)
    eq("an instance names itself", c.zone, "Ragefire Chasm")

    WoW.zone, WoW.subzone = WoW.secret("Somewhere"), "x"
    check("a secret zone changes nothing", not R.Location(c))
    WoW.zone, WoW.subzone = nil, nil
end

------------------------------------------------------------
-- Guild and rank (#515)
------------------------------------------------------------
do
    local c = { guild = "Parse Partout", guildRank = "Member", guildRankIndex = 5 }
    WoW.loggedIn = false                              -- before PLAYER_LOGIN
    WoW.inGuild, WoW.guildInfo = false, nil           -- a guilded character reads this then (measured)
    check("before login nothing is read", not R.Guild(c))
    eq("  the guild kept", c.guild, "Parse Partout")
    WoW.loggedIn = true

    WoW.inGuild, WoW.guildInfo = true, nil            -- the details lag membership (measured)
    check("in a guild with no name yet: nothing changes", not R.Guild(c))
    eq("  the guild kept", c.guild, "Parse Partout")
    eq("  the rank kept", c.guildRank, "Member")
    eq("  its index kept", c.guildRankIndex, 5)

    WoW.guildInfo = { "Parse Partout", "Officer", 1 }
    check("a promotion changes it", R.Guild(c))
    eq("  the rank's name", c.guildRank, "Officer")
    eq("  its index", c.guildRankIndex, 1)
    check("the same again changes nothing", not R.Guild(c))

    WoW.guildInfo = { "Parse Partout", "Guild Master", 0 }
    R.Guild(c)
    eq("the guild master's index is 0", c.guildRankIndex, 0)

    WoW.inGuild, WoW.guildInfo = false, nil           -- stub: nil, nil, 0
    check("leaving the guild changes it", R.Guild(c))
    eq("  no guild", c.guild, "")
    eq("  no rank", c.guildRank, nil)
    eq("  and no index, though the client answers 0", c.guildRankIndex, nil)

    WoW.inGuild = WoW.secret(true)
    check("a secret answer changes nothing", not R.Guild(c))
    WoW.inGuild, WoW.guildInfo = nil, nil
end

------------------------------------------------------------
-- Between scans: the events, on our own record
------------------------------------------------------------
do
    local guid = UnitGUID("player")
    AltStableDB = { [guid] = { guid = guid, name = "Me" } }
    local c = AltStableDB[guid]
    for _, ev in ipairs({ "ZONE_CHANGED", "ZONE_CHANGED_INDOORS", "ZONE_CHANGED_NEW_AREA",
                          "UPDATE_INVENTORY_DURABILITY", "PLAYER_GUILD_UPDATE",
                          "GUILD_RANKS_UPDATE", "GUILD_RANKS_UPDATE_ACTIVE_PLAYER" }) do
        local listed = false
        for _, e in ipairs(R.EVENTS) do if e == ev then listed = true end end
        check("listens to " .. ev, listed)
    end

    touched = 0
    WoW.zone, WoW.subzone = "Orgrimmar", "The Drag"
    R.OnEvent("ZONE_CHANGED_INDOORS")
    eq("a zone event reads at once", c.subzone, "The Drag")
    eq("  and stamps the record once", touched, 1)
    R.OnEvent("ZONE_CHANGED")
    eq("the same place again: no stamp", touched, 1)

    touched = 0
    Durable({ [1] = { 30, 40 } })
    for _ = 1, 5 do R.OnEvent("UPDATE_INVENTORY_DURABILITY") end
    eq("durability events wait for their delay", c.durMin, nil)
    WoW.flushTimers()
    eq("  then one read", c.durMin, 75)
    eq("  and one stamp", touched, 1)
    for _ = 1, 5 do R.OnEvent("UPDATE_INVENTORY_DURABILITY") end
    WoW.flushTimers()
    eq("the same durability again: no stamp", touched, 1)

    -- A swap with a durability read already queued (Codex review of #573):
    -- the record keeps the old item and its durability together until the
    -- equipment scan, which writes both.
    -- The worn items are checked against the record's, however late the
    -- equipment scan comes (a pet event restarts its timer).
    local HELM = "|cffffffff|Hitem:10657::::::::21:::::::::|h[Helm]|h|r"
    touched = 0
    R.OnEvent("UPDATE_INVENTORY_DURABILITY")     -- queued, 1 s
    WoW.equipped[1] = HELM                       -- a helm put on: the record says none
    Durable({ [1] = { 10, 40 } })
    WoW.flushTimers()
    eq("a read while the worn items differ from the record's writes nothing", c.durMin, 75)
    eq("  and stamps nothing, so no delta carries a half", touched, 0)
    for _ = 1, 3 do R.OnEvent("UPDATE_INVENTORY_DURABILITY"); WoW.flushTimers() end
    eq("  however many come before the equipment scan", c.durMin, 75)
    c.gearid_head = 10657                        -- the equipment scan: the items...
    R.Durability(c, true)                        -- ...and their durability, together
    eq("the equipment scan writes the new durability", c.durMin, 25)
    Durable({ [1] = { 5, 40 } })
    R.OnEvent("UPDATE_INVENTORY_DURABILITY")
    WoW.flushTimers()
    eq("  after it, durability events read again", c.durMin, 12)
    WoW.equipped[1] = nil                        -- taken off, not yet scanned
    check("an item taken off doesn't match", not R.GearMatches(c))
    WoW.equipped[1] = HELM
    check("the same item worn matches", R.GearMatches(c))
    WoW.equipped[1] = nil; c.gearid_head = nil
    check("(nothing worn, nothing recorded: a match)", R.GearMatches(c))
    local realID = GetInventoryItemID
    GetInventoryItemID = function() return WoW.secret(1) end
    check("an item that can't be read doesn't match, even then", not R.GearMatches(c))
    GetInventoryItemID = realID

    touched = 0
    WoW.loggedIn, WoW.inGuild, WoW.guildInfo = true, true, { "Parse Partout", "Member", 5 }
    R.OnEvent("PLAYER_GUILD_UPDATE", "party1")
    WoW.flushTimers()
    eq("another unit's guild update is not ours", c.guildRank, nil)
    R.OnEvent("PLAYER_GUILD_UPDATE", "player")
    R.OnEvent("GUILD_RANKS_UPDATE")
    R.OnEvent("GUILD_RANKS_UPDATE_ACTIVE_PLAYER")
    WoW.flushTimers()
    eq("our guild update: read after its delay", c.guildRank, "Member")
    eq("  one stamp for the burst", touched, 1)

    AltStableDB = {}
    touched = 0
    R.OnEvent("ZONE_CHANGED_NEW_AREA")
    R.OnEvent("UPDATE_INVENTORY_DURABILITY")
    WoW.flushTimers()
    eq("no record yet: nothing written, nothing stamped", touched, 0)
    WoW.zone, WoW.subzone, WoW.inGuild, WoW.guildInfo = nil, nil, nil, nil
    Durable({})
end

print(("test_readings: %d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
