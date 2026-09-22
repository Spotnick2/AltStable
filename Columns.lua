AltStable = AltStable or {}

-- Reputation column: the faction's icon when it has one that exists on this
-- client, else a stacked text header (see BuildHeaders in SheetUI.lua).
local ICON_DIR = "Interface\\Icons\\"
local function rep(r)
    local icon
    if r.icon then
        local path = ICON_DIR .. r.icon
        -- Unknown (no GetFileIDFromPath) trusts the name; a confirmed miss
        -- keeps the text label rather than drawing a green box.
        if AltStable.API.TextureExists(path) ~= false then icon = path end
    end
    return { label=r.label, field=AltStable.RepField(r.id), width=22, align="RIGHT",
             type="rep", vertical=true, verticalLabel=r.short, group="rep",
             repIcon=icon }
end

-- Profession skill column
local function prof(label, skillField, maxField, icon)
    return { label=label, field=skillField, maxField=maxField, width=38,
             align="RIGHT", type="profSkill", profIcon=icon, group="prof" }
end

AltStable.Columns = {
    -- Frozen (col 1 = Name)
    { label="Name",  field="name",  width=140, align="LEFT", type="name", group="always" },

    -- Always-visible identity
    { label="Class", field="class", width=22, align="CENTER", type="classIcon", group="always" },
    { label="Race",  field="race",  width=22, align="CENTER", type="raceIcon",  group="always" },
    { label="Lvl",   field="level", width=35, align="RIGHT",  type="number",    group="always" },
    { label="iLvl",  field="ilvl",  width=45, align="RIGHT",  type="number",    group="always" },

    -- Gear slots — slotSlug drives icon resolution via AltStable.GetGearIconPath()
    -- at header-build time so Alliance/Horde icons update based on logged-in character.
    -- slotID matches the WoW inventory slot number for SetInventoryItem live tooltips.
    { label="Head",      field="gear_head",     slotSlug="head",      slotID=1,  width=32, align="RIGHT", type="gearSlot", group="gear" },
    { label="Neck",      field="gear_neck",     slotSlug="neck",      slotID=2,  width=32, align="RIGHT", type="gearSlot", group="gear" },
    { label="Shoulder",  field="gear_shoulder", slotSlug="shoulders", slotID=3,  width=32, align="RIGHT", type="gearSlot", group="gear" },
    { label="Back",      field="gear_back",     slotSlug="back",      slotID=15, width=32, align="RIGHT", type="gearSlot", group="gear" },
    { label="Chest",     field="gear_chest",    slotSlug="chest",     slotID=5,  width=32, align="RIGHT", type="gearSlot", group="gear" },
    { label="Wrist",     field="gear_wrist",    slotSlug="wrists",    slotID=9,  width=32, align="RIGHT", type="gearSlot", group="gear" },
    { label="Hands",     field="gear_hands",    slotSlug="hands",     slotID=10, width=32, align="RIGHT", type="gearSlot", group="gear" },
    { label="Waist",     field="gear_waist",    slotSlug="waist",     slotID=6,  width=32, align="RIGHT", type="gearSlot", group="gear" },
    { label="Legs",      field="gear_legs",     slotSlug="legs",      slotID=7,  width=32, align="RIGHT", type="gearSlot", group="gear" },
    { label="Feet",      field="gear_feet",     slotSlug="feet",      slotID=8,  width=32, align="RIGHT", type="gearSlot", group="gear" },
    { label="Ring 1",    field="gear_ring1",    slotSlug="ring1",     slotID=11, width=32, align="RIGHT", type="gearSlot", group="gear" },
    { label="Ring 2",    field="gear_ring2",    slotSlug="ring2",     slotID=12, width=32, align="RIGHT", type="gearSlot", group="gear" },
    { label="Trinket 1", field="gear_trinket1", slotSlug="trinket1",  slotID=13, width=32, align="RIGHT", type="gearSlot", group="gear" },
    { label="Trinket 2", field="gear_trinket2", slotSlug="trinket2",  slotID=14, width=32, align="RIGHT", type="gearSlot", group="gear" },
    { label="Main Hand", field="gear_mainhand", slotSlug="mainhand",  slotID=16, width=32, align="RIGHT", type="gearSlot", group="gear" },
    { label="Off Hand",  field="gear_offhand",  slotSlug="offhand",   slotID=17, width=32, align="RIGHT", type="gearSlot", group="gear" },
    { label="Ranged",    field="gear_ranged",   slotSlug="ranged",    slotID=18, width=32, align="RIGHT", type="gearSlot", group="gear" },

    -- Info (always visible — shown in name tooltip but kept as columns too)
    { label="Guild",       field="guild",       width=110, align="LEFT",  type="text",       group="always" },
    { label="Rested XP",   field="restPercent", width=70,  align="RIGHT", type="restXP",     group="always" },
    { label="Gold",        field="money",       width=150, align="RIGHT", type="money",      group="always" },
    { label="Last Online", field="lastUpdate",  width=85,  align="RIGHT", type="lastOnline", group="always" },

    -- Professions
    prof("Alchemy",       "prof_Alchemy",        "profmax_Alchemy",        "Interface\\Icons\\Trade_Alchemy"),
    prof("Blacksmithing", "prof_Blacksmithing",  "profmax_Blacksmithing",  "Interface\\Icons\\Trade_BlackSmithing"),
    prof("Enchanting",    "prof_Enchanting",     "profmax_Enchanting",     "Interface\\Icons\\Trade_Engraving"),
    prof("Engineering",   "prof_Engineering",    "profmax_Engineering",    "Interface\\Icons\\Trade_Engineering"),
    prof("Leatherworking","prof_Leatherworking", "profmax_Leatherworking", "Interface\\Icons\\Trade_LeatherWorking"),
    prof("Tailoring",     "prof_Tailoring",      "profmax_Tailoring",      "Interface\\Icons\\Trade_Tailoring"),
    prof("Herbalism",     "prof_Herbalism",      "profmax_Herbalism",      "Interface\\Icons\\Trade_Herbalism"),
    prof("Mining",        "prof_Mining",         "profmax_Mining",         "Interface\\Icons\\Trade_Mining"),
    prof("Skinning",      "prof_Skinning",       "profmax_Skinning",       "Interface\\Icons\\INV_Misc_Pelt_Wolf_01"),
    prof("Cooking",       "cooking",             "cookingMax",             "Interface\\Icons\\INV_Misc_Food_15"),
    prof("Fishing",       "fishing",             "fishingMax",             "Interface\\Icons\\Trade_Fishing"),
    prof("First Aid",     "firstAid",            "firstAidMax",            "Interface\\Icons\\Spell_Holy_SealOfSacrifice"),
    prof("Riding",        "riding",              "ridingMax",              "Interface\\Icons\\Ability_Mount_RidingHorse"),

    -- Reputations: appended below from AltStable.REPUTATIONS
}

for _, r in ipairs(AltStable.REPUTATIONS) do
    AltStable.Columns[#AltStable.Columns + 1] = rep(r)
end

-- Header height for a set of columns: stacked text labels need 64px, icons fit
-- the usual 32. Only as tall as the columns actually shown need.
function AltStable.HeaderHeightFor(columns, default)
    for _, col in ipairs(columns) do
        if col.vertical and not col.repIcon then return 64 end
    end
    return default or 32
end

function AltStable.GetTotalColumnWidth()
    local total = 20
    for _, col in ipairs(AltStable.Columns) do
        total = total + col.width
    end
    return total
end