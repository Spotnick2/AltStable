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

        local name, _, standing = GetFactionInfo(i)

        local key = TBC_REPUTATIONS[name]

        if key then
            char[key] = standing
        end

    end

end