-- Retail-API adapters; see Compat.lua.
local API = AltStable.API
local GetNumFactions        = API.GetNumFactions
local GetFactionDataByIndex = API.GetFactionDataByIndex

-- Outland factions, carried over unchanged. They do not exist on a Vanilla
-- client, so every lookup below simply misses and the columns read empty.
-- Replacing this with the Vanilla set, keyed by faction ID, is #8 - this file
-- only moves to the Retail API here.
local TBC_REPUTATIONS = {

    -- Shattrath
    ["The Aldor"]              = "aldor",
    ["The Scryers"]            = "scryer",
    ["The Sha'tar"]            = "shatar",
    ["Lower City"]             = "lowercity",

    -- Main Outland
    ["Cenarion Expedition"]    = "cenarion",
    ["The Consortium"]         = "consortium",
    ["Keepers of Time"]        = "keepers",
    ["Sporeggar"]              = "sporeggar",

    -- Alliance / Horde city
    ["Honor Hold"]             = "honorhold",
    ["Thrallmar"]              = "thrallmar",
    ["Kurenai"]                = "kurenai",
    ["The Mag'har"]            = "maghar",

    -- Phased / reputation grinds
    ["Ogri'la"]                = "ogrila",
    ["Sha'tari Skyguard"]      = "skyguard",
    ["Netherwing"]             = "netherwing",
    ["Ashtongue Deathsworn"]   = "ashtongue",
    ["The Scale of the Sands"] = "scaleofsands",
    ["Shattered Sun Offensive"]= "shatteredsun",

    -- Karazhan
    ["The Violet Eye"]         = "violeteye",

}


function AltStable.ScanReputations(char)

    -- Clear any previous values so rep that the character no longer
    -- has visible (never discovered, or removed from tracking) doesn't
    -- persist stale data from an earlier scan or sync.
    for _, key in pairs(TBC_REPUTATIONS) do
        char[key] = nil
    end

    for i = 1, GetNumFactions() do

        -- One struct, not the old tuple. Standing used to be the THIRD return
        -- of GetFactionInfo; it is `reaction` here. Reading it positionally
        -- would store nil for every faction with no error.
        local data = GetFactionDataByIndex(i)

        if data then
            local key = TBC_REPUTATIONS[data.name]
            if key then
                char[key] = data.reaction
            end
        end

    end

end