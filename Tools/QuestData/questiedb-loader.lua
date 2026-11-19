-- Tools/QuestData/questiedb-loader.lua - run QuestieDB's own reader under plain Lua 5.1
--
-- Part of the Loremaster plugin's data generator (#374). Never ships.
-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- QuestieDB's Forever edition bakes its data into its TOC as `## X-<Entity>-<id>-<field>`
-- metadata: base64 of CBOR, and for the ID headers base64 of zlib of CBOR, split into `~N~`
-- chunks. This file loads QuestieDB's own Lua files, BY PATH from the reference copy (nothing
-- is copied here), in the TOC's order, with the few client functions they call replaced:
--   * C_AddOns.GetAddOnMetadata over the parsed TOC;
--   * C_EncodingUtil.DecodeBase64 / DecompressString (zlib, through our LibDeflate) /
--     DeserializeCBOR (a small decoder below);
--   * UnitFactionGroup / UnitClassBase / UnitRace, set per export, because QuestieDB's
--     Dynamic Corrections branch on the player's faction and class.
--
-- Load(dir, player) returns the LibQuestieDB table (ns.Quest is the quest entity).

local M = {}

----------------------------------------------------------------------------
-- base64
----------------------------------------------------------------------------

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64INDEX = {}
for i = 1, #B64 do B64INDEX[B64:byte(i)] = i - 1 end

function M.DecodeBase64(s)
    local out, buf, bits = {}, 0, 0
    for i = 1, #s do
        local v = B64INDEX[s:byte(i)]
        if v then
            buf = buf * 64 + v
            bits = bits + 6
            if bits >= 8 then
                bits = bits - 8
                local byte = math.floor(buf / 2 ^ bits)
                out[#out + 1] = string.char(byte)
                buf = buf - byte * 2 ^ bits
            end
        end
    end
    return table.concat(out)
end

----------------------------------------------------------------------------
-- CBOR (RFC 8949), the subset a CBOR encoder writes for Lua values: integers,
-- byte and text strings, arrays (-> 1-based tables), maps, simple values and
-- floats. Indefinite lengths are supported for strings, arrays and maps.
----------------------------------------------------------------------------

local function float16(b1, b2)
    local sign = b1 >= 128 and -1 or 1
    local exp = math.floor(b1 / 4) % 32
    local mant = (b1 % 4) * 256 + b2
    if exp == 0 then return sign * mant * 2 ^ -24 end
    if exp == 31 then return mant == 0 and sign * math.huge or 0 / 0 end
    return sign * (1 + mant / 1024) * 2 ^ (exp - 15)
end

local function float32(s, p)
    local b1, b2, b3, b4 = s:byte(p, p + 3)
    local sign = b1 >= 128 and -1 or 1
    local exp = (b1 % 128) * 2 + math.floor(b2 / 128)
    local mant = ((b2 % 128) * 256 + b3) * 256 + b4
    if exp == 0 then return sign * mant * 2 ^ -149 end
    if exp == 255 then return mant == 0 and sign * math.huge or 0 / 0 end
    return sign * (1 + mant / 2 ^ 23) * 2 ^ (exp - 127)
end

local function float64(s, p)
    local b = { s:byte(p, p + 7) }
    local sign = b[1] >= 128 and -1 or 1
    local exp = (b[1] % 128) * 16 + math.floor(b[2] / 16)
    local mant = b[2] % 16
    for i = 3, 8 do mant = mant * 256 + b[i] end
    if exp == 0 then return sign * mant * 2 ^ -1074 end
    if exp == 2047 then return mant == 0 and sign * math.huge or 0 / 0 end
    return sign * (1 + mant / 2 ^ 52) * 2 ^ (exp - 1023)
end

local function uint(s, p, n)
    local v = 0
    for i = p, p + n - 1 do v = v * 256 + s:byte(i) end
    return v
end

local decodeItem

-- The argument of an item: returns value, next position (nil value = indefinite).
local function argument(s, p, info)
    if info < 24 then return info, p end
    if info == 24 then return s:byte(p), p + 1 end
    if info == 25 then return uint(s, p, 2), p + 2 end
    if info == 26 then return uint(s, p, 4), p + 4 end
    if info == 27 then return uint(s, p, 8), p + 8 end
    if info == 31 then return nil, p end
    error(("CBOR: bad additional info %d at %d"):format(info, p - 1))
end

local BREAK = {}

decodeItem = function(s, p)
    local ib = s:byte(p)
    if not ib then error("CBOR: truncated at " .. p) end
    p = p + 1
    local major, info = math.floor(ib / 32), ib % 32
    if major == 7 then
        if info == 20 then return false, p end
        if info == 21 then return true, p end
        if info == 22 or info == 23 then return nil, p end
        if info == 25 then return float16(s:byte(p, p + 1)), p + 2 end
        if info == 26 then return float32(s, p), p + 4 end
        if info == 27 then return float64(s, p), p + 8 end
        if info == 31 then return BREAK, p end
        if info < 24 then return info, p end
        error(("CBOR: simple value %d at %d"):format(info, p - 1))
    end
    local n
    n, p = argument(s, p, info)
    if major == 0 then return n, p end
    if major == 1 then return -1 - n, p end
    if major == 2 or major == 3 then
        if n then return s:sub(p, p + n - 1), p + n end
        local parts = {}
        while true do
            local part
            part, p = decodeItem(s, p)
            if part == BREAK then break end
            parts[#parts + 1] = part
        end
        return table.concat(parts), p
    end
    if major == 4 then
        local t, i = {}, 0
        while not n or i < n do
            local v
            v, p = decodeItem(s, p)
            if v == BREAK then break end
            i = i + 1
            t[i] = v
        end
        return t, p
    end
    if major == 5 then
        local t, i = {}, 0
        while not n or i < n do
            local k, v
            k, p = decodeItem(s, p)
            if k == BREAK then break end
            v, p = decodeItem(s, p)
            if k ~= nil then t[k] = v end
            i = i + 1
        end
        return t, p
    end
    if major == 6 then          -- a tag: keep the tagged value
        return decodeItem(s, p)
    end
    error(("CBOR: major type %d at %d"):format(major, p - 1))
end

function M.DeserializeCBOR(s)
    local v = decodeItem(s, 1)
    return v
end

----------------------------------------------------------------------------
-- The TOC as a metadata store
----------------------------------------------------------------------------

local function ReadToc(path)
    local f = assert(io.open(path, "rb"))
    local meta, files = {}, {}
    for line in f:read("*a"):gmatch("[^\r\n]+") do
        local k, v = line:match("^## ([^:]+):%s?(.*)$")
        if k then
            meta[k] = v
        elseif not line:match("^#") and line:match("%.lua$") then
            files[#files + 1] = (line:gsub("\\", "/"))
        end
    end
    f:close()
    return meta, files
end

----------------------------------------------------------------------------
-- Loading
----------------------------------------------------------------------------

-- The client functions QuestieDB's files call, as plain-Lua stand-ins.
local function InstallClient(meta, libDeflate, player)
    C_AddOns = { GetAddOnMetadata = function(_, key) return meta[key] end }
    GetAddOnMetadata = C_AddOns.GetAddOnMetadata
    C_EncodingUtil = {
        DecodeBase64 = M.DecodeBase64,
        DeserializeCBOR = M.DeserializeCBOR,
        DecompressString = function(data, method)
            local out
            if method == 0 then out = libDeflate:DecompressDeflate(data)
            else out = libDeflate:DecompressZlib(data) end
            if not out then error("DecompressString: method " .. tostring(method) .. " failed") end
            return out
        end,
    }
    UnitFactionGroup = function() return player.faction, player.faction end
    UnitClassBase = function() return player.classFile, player.classID end
    UnitClass = function() return player.classFile, player.classFile, player.classID end
    UnitRace = function() return player.raceFile, player.raceFile, player.raceID end
    GetLocale = function() return "enUS" end
    GetBuildInfo = function() return "1.60.1", "70959", "Nov 17 2026", 16001 end
    C_Seasons = { GetActiveSeason = function() return nil end }
    CreateFrame = function()
        local f = {}
        return setmetatable(f, { __index = function() return function() return f end end })
    end
    C_Timer = { After = function() end, NewTicker = function() return { Cancel = function() end } end }
    -- Lua 5.1 lacks these WoW string/table helpers.
    wipe = wipe or function(t) for k in pairs(t) do t[k] = nil end return t end
    tinsert = tinsert or table.insert
    tremove = tremove or table.remove
    strsplit = strsplit or function(sep, s)
        local out = {}
        for part in (s .. sep):gmatch("(.-)" .. sep:gsub("%p", "%%%0")) do out[#out + 1] = part end
        return unpack(out)
    end
end

-- player = { faction = "Alliance"|"Horde", classFile = "WARRIOR", classID = 1, raceFile, raceID }
function M.Load(dir, libDeflatePath, player)
    local meta, files = ReadToc(dir .. "/QuestieDB_Forever.toc")
    local libDeflate = assert(loadfile(libDeflatePath))()
    InstallClient(meta, libDeflate, player)
    local ns = {}
    for _, file in ipairs(files) do
        if not file:match("^src/ui/") then
            local chunk = assert(loadfile(dir .. "/" .. file))
            chunk("QuestieDB", ns)
        end
    end
    ns.tocMeta = meta
    return ns
end

return M
