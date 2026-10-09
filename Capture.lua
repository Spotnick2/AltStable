------------------------------------------------------------
-- Capture.lua - photograph the LIVE character for the Roster lineup (#89)
--
-- Offline characters cannot be textured on this client (measured on
-- 1.60.1.70009, docs/forever-api-notes.md): they come back as geometry with no
-- skin, face or armour. The live one renders perfectly, so the Roster's
-- portraits are pictures taken earlier by this client: pose the live model on a
-- flat backdrop, screenshot it, and matte it to a transparent cutout outside
-- the game. An addon can neither write an image file nor read the Screenshots
-- folder, so the matte cannot happen in here.
--
-- TWO SHOTS, not a chroma key. The same frozen pose is captured once on BLACK
-- and once on WHITE; then for each pixel
--
--     alpha  = 1 - (white - black)
--     colour = black / alpha
--
-- which is exact, including hair, capes and anything semi-transparent, and has
-- none of the fringing a key leaves behind. It costs one extra screenshot and
-- requires the pose to be IDENTICAL in both, which is why the animation is
-- paused and frozen before either shot.
--
-- Screenshots must be TGA: JPEG smears every edge and the matte maths would be
-- reading compression noise. A capture that cannot switch the format is not
-- taken at all.
--
-- What gets recorded goes to AltStablePortraits, whose shape is the contract a
-- converter reads - see docs/PORTRAIT-CONTRACT.md before changing a field.
--
-- Lifted from the development probe (Tools/AltStableProbe/Render.lua, removed
-- in #89 - see git history). Automatic capture - a toast with a countdown when
-- the look changes - is AutoCapture.lua (#124), through AltStable.CapturePortrait,
-- PortraitBlockedReason and PortraitCapturing.
------------------------------------------------------------

AltStable = AltStable or {}

local KEY_DELAY   = 1.25   -- let the model stream in before the first shot
local SHOT_DELAY  = 0.65   -- let the client finish writing a file

-- The pause between the backdrop swap and the SECOND shot.
--
-- SHOT_DELAY + this is the gap between the two Screenshot() calls, and it must
-- come to MORE THAN ONE SECOND. The client names screenshots to the second -
-- WoWScrnShot_MMDDYY_HHMMSS.tga - so two shots inside one second are one
-- filename, and the second overwrites the first. What survives is a single
-- file the converter cannot pair, and both records claim the same stamp.
--
-- It was 0.25, for a gap of 0.9s, so roughly one capture in ten quietly lost
-- its pair depending on where the clock happened to tick. Caught on a live
-- roster: Morphisto Ruskador recorded both shots at 02:14:44 and left one file.
--
-- Any gap strictly greater than 1.0s guarantees two different seconds.
local SWAP_DELAY  = 0.45   -- 0.65 + 0.45 = 1.10s between shutter and shutter

-- The whole chain is a string of timers; if a link fails nothing restores the
-- interface, so an independent timer does it regardless.
local WATCHDOG    = 12


-- A camera shutter per shot, so the three seconds with no interface sound like
-- what they are. SOUNDKIT.REPORT_SCREENSHOT_CAMERA (230810) is defined in the
-- Mainline SoundKitConstants this client ships (wow-ui-source 1.60.1.70009),
-- and MEASURED: `/run PlaySound(SOUNDKIT.REPORT_SCREENSHOT_CAMERA)` on
-- 1.60.1.70009 is the selfie camera's shutter. Looked up at call time:
-- SOUNDKIT is Blizzard's table.
local function ShutterSound()
    local id = type(SOUNDKIT) == "table" and SOUNDKIT.REPORT_SCREENSHOT_CAMERA
    if id and type(PlaySound) == "function" then pcall(PlaySound, id) end
end
local STORE_VERSION = 1

-- Both defined with the "is a capture due" code below (#128). Declared here because
-- the event handler, further up than that, calls it: undeclared, Lua 5.1 reads
-- it as a nil GLOBAL and every pull threw (review of #134).
local PortraitStatus, GlowForCombat

-- Which way the character is turned, in degrees. 0 is dead-on, the default
-- since #149: straight on looks right everywhere - the scene, the grid, the
-- detail pane - where a turn only suits one side of the fire. Facing the fire
-- is #152's (mirror one turned capture per side of the scene, rather than
-- capture per seat). The same value is used for every capture so a row of alts
-- is consistent; Options > Presentation > Portrait angle changes it.
local DEFAULT_FACING = 0
-- What a store with captures but no `facing` was shot at: the default before
-- #149. Written into it once (MigrateFacing), so a lineup captured then stays
-- consistent - the next capture is not suddenly straight on beside nine
-- turned ones - and so no reader is left guessing what absent means.
local LEGACY_FACING = 20
-- The setting's range, shared by the slider and the command so they cannot
-- disagree about what is stored.
local FACING_LIMIT = 45

-- The capture records. Created on first use, so an install that never
-- captures never writes the table at all.
--
-- The version is written only on a store that has none. A NEWER version on
-- disk - a downgrade after a later AltStable wrote it - is left alone and not
-- written to: relabelling it 1 would make a converter parse its records as v1,
-- which is the guess the contract says a reader must refuse to make.
local function Store()
    local fresh = (AltStablePortraits == nil)
    AltStablePortraits = AltStablePortraits or {}
    AltStablePortraits.version = AltStablePortraits.version or STORE_VERSION
    AltStablePortraits.renders = AltStablePortraits.renders or {}
    -- A new store records its angle from the start (#149): `facing` is never
    -- absent in anything written from v0.7 on.
    if fresh then AltStablePortraits.facing = DEFAULT_FACING end
    return AltStablePortraits
end

local function StoreTooNew()
    local v = tonumber(AltStablePortraits and AltStablePortraits.version)
    return v ~= nil and v > STORE_VERSION
end

-- A store from before #149 with captures and no angle was shot at 20: say so,
-- once. One with no captures has no lineup to keep, so it takes the new
-- default. A newer AltStable's store is not ours to edit.
local function MigrateFacing()
    local s = AltStablePortraits
    if type(s) ~= "table" or s.facing ~= nil or StoreTooNew() then return end
    s.facing = (type(s.renders) == "table" and #s.renders > 0) and LEGACY_FACING or DEFAULT_FACING
end

local function Facing()
    MigrateFacing()
    local deg = tonumber(AltStablePortraits and AltStablePortraits.facing)
    if not deg then deg = DEFAULT_FACING end
    return math.rad(deg), deg
end

-- The angle as a setting (#149), shared by the Options slider and
-- `/alts portrait facing`. It writes the field the portrait contract already
-- documents (AltStablePortraits.facing, docs/PORTRAIT-CONTRACT.md), so the
-- Companion reads the same number the capture used. Refused, rather than
-- written, into a store a newer AltStable wrote: that version is not ours to
-- edit.
function AltStable.GetPortraitFacing()
    local _, deg = Facing()
    return deg
end

AltStable.DEFAULT_PORTRAIT_FACING = DEFAULT_FACING

local function Out(s)
    if AltStable.Print then
        AltStable.Print(s)
    else
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff[AltStable]|r " .. tostring(s))
    end
end

-- UIParent:Hide()/Show() are PROTECTED. Called once combat has started the
-- client blocks them, and the block lands on the way BACK - so the interface
-- stays hidden for the whole fight and the addon takes the blame in an error
-- report (#70). SetUIVisibility is the engine's own call - the one Alt+Z makes
-- - and is not protected, so it is what hides the interface here.
--
-- The stage survives it by being parented to WorldFrame rather than UIParent,
-- so the engine's hide does not take it with the rest of the interface.
local uiHidden        -- "engine" | "uiparent" | nil
local uiWasShown      -- was the interface up before we touched it?
local owedRestore     -- a protected restore we could not make during combat

-- Frames that survive the blackout because somebody lifted them OUT from under
-- UIParent on purpose.
--
-- The sheet's camera showcase reparents the sheet and GameTooltip so that
-- hiding the game UI does not take them with it. Hiding UIParent therefore
-- does not hide them, and UIParent:IsShown() says the interface is gone while
-- the addon's own window is still standing in front of the camera.
--
-- Named rather than discovered: "anything not under UIParent" would also match
-- the STAGE, which is parented to WorldFrame for this very reason.
--
-- Alpha, not Hide: hiding the sheet fires its OnHide, which tears the showcase
-- down and restores the interface in the middle of the capture.
-- Our own prompts (Prompt.lua) are parented to nothing on purpose too, so a
-- copy box or a sync question left open would be matted into the portrait.
local STRAY_FRAMES = { "AltStableSheet", "AltStableCopyPrompt", "AltStableForgetPrompt",
                       "AltStableSyncAskPrompt" }

-- The character menu is CLOSED rather than dimmed. During the showcase it is
-- lifted to its own parentless root, so the sheet's alpha does not reach it,
-- and a capture never hides the sheet, so the sheet's OnHide cannot close it
-- either. Closing it uses the path that already exists: it releases the
-- keyboard and the full-screen click catcher, which left alive would eat every
-- click during the capture.
local function CloseStrayMenu()
    if AltStable.CloseCharacterMenu then pcall(AltStable.CloseCharacterMenu) end
end
local strays

local function SuppressStrays()
    strays = {}

    -- Settle anything mid-animation BEFORE reading its alpha. The sheet's
    -- opening fade owns its alpha for 0.22 seconds; a capture starting inside
    -- that window borrowed a partial value, and the restore afterwards wrote it
    -- back over a sheet that was then shown and invisible. Two owners of one
    -- property need an order, not a race.
    if type(AltStable.FinishOpenAnimation) == "function" then
        pcall(AltStable.FinishOpenAnimation)
    end

    -- `evenHidden` is for the tooltip: it is hidden a moment before this runs,
    -- but anything hovered during the capture shows it again - the sheet is
    -- invisible, not gone, and its rows still answer the mouse - and a tooltip
    -- shown at full alpha draws above the stage and is matted into the cutout.
    local function zero(f, evenHidden)
        if type(f) ~= "table" then return end
        if type(f.GetAlpha) ~= "function" or type(f.SetAlpha) ~= "function" then return end
        if not evenHidden and f.IsShown and f:IsShown() == false then return end

        -- Only a frame genuinely NOT under UIParent. One that still is has
        -- already gone with the interface, and zeroing it would hand the
        -- player back an invisible window afterwards.
        local p = f.GetParent and f:GetParent()
        while p do
            if p == UIParent then return end
            p = p.GetParent and p:GetParent()
        end

        strays[#strays + 1] = { frame = f, alpha = f:GetAlpha() }
        pcall(f.SetAlpha, f, 0)
    end

    CloseStrayMenu()
    for _, name in ipairs(STRAY_FRAMES) do zero(_G[name]) end
    zero(GameTooltip, true)
    return #strays
end

-- Unconditional, and called before every early return in ShowUI: a capture that
-- is abandoned half way through must not leave the player's sheet at alpha 0.
local function RestoreStrays()
    for _, s in ipairs(strays or {}) do
        pcall(s.frame.SetAlpha, s.frame, s.alpha or 1)
    end
    strays = nil
end

-- Returns true only if the interface is ACTUALLY gone. The caller aborts
-- otherwise: two screenshots of a character behind a full interface are not a
-- portrait.
local function HideUI()
    if uiHidden then return true end

    uiWasShown = not (UIParent and UIParent.IsShown and UIParent:IsShown() == false)

    if type(SetUIVisibility) == "function" then
        pcall(SetUIVisibility, false)
        if UIParent and UIParent:IsShown() then
            return false            -- the call did not take
        end
        SuppressStrays()
        uiHidden = "engine"
        return true
    end

    -- No engine support: fall back, but never in combat, where the call is
    -- blocked and would strand the player looking at nothing.
    if InCombatLockdown and InCombatLockdown() then return false end
    if UIParent and UIParent:IsShown() then
        pcall(UIParent.Hide, UIParent)
        if UIParent:IsShown() then return false end
        SuppressStrays()
        uiHidden = "uiparent"
        return true
    end
    return false
end

-- Returns true when the interface is back, false when we still owe it.
--
-- The flag is cleared ONLY on success. UIParent:Show() is protected, so on the
-- fallback path during combat the call is blocked - and clearing the flag first
-- would lose the fact that we still owe a restore.
local function ShowUI()
    -- Before every branch, including the early returns: "leave the interface
    -- off, that is how we found it" is a statement about UIParent, not about
    -- frames whose alpha we borrowed.
    RestoreStrays()

    if not uiHidden then return true end

    -- Leave it off if that is how we found it - the player hid it themselves,
    -- or the sheet's showcase did and still owns it.
    if uiWasShown == false then uiHidden = nil; return true end

    if uiHidden == "engine" then
        -- The engine call is safe in combat; it is what Alt+Z does.
        if type(SetUIVisibility) == "function" then pcall(SetUIVisibility, true) end
        uiHidden = nil
        return true
    end

    if InCombatLockdown and InCombatLockdown() then
        owedRestore = true          -- paid at PLAYER_REGEN_ENABLED
        return false
    end
    pcall(UIParent.Show, UIParent)
    uiHidden = nil
    owedRestore = nil
    return true
end

local frame, model, backdrop, hint

local savedFormat
local previewing
local capturing          -- one at a time, always
-- Bumped by every capture and by every abort. Each timer in the chain holds the
-- value it was scheduled under and does nothing if it no longer matches, so an
-- abandoned capture cannot take a shot or restore an interface that a later
-- capture is legitimately hiding.
local captureToken = 0
-- How many records existed before the current capture began. Abandoning
-- truncates back to it, so a half-written pair cannot be picked up later.
local renderMark = 0
local captureStartedAt
local watchdog           -- cancelled by Finish, or it fires into the NEXT capture
-- Started by the auto-capture countdown rather than by the player (#124). Such
-- a capture asks nothing afterwards: the reload dialog would interrupt someone
-- who did not just ask for a picture, and logging out writes the record anyway.
local autoRun

local function Build()
    if frame then return end

    -- Parented to WorldFrame, NOT UIParent, so hiding UIParent during the shots
    -- takes every other frame away and leaves the stage standing. A tooltip
    -- draws at TOOLTIP strata, above FULLSCREEN_DIALOG, and gets matted
    -- straight into the cutout - measured, after a minimap tooltip turned a
    -- 250x885 character into a 1790x1350 image with a tooltip beside her.
    frame = CreateFrame("Frame", "AltStableRenderStage", WorldFrame)
    frame:SetFrameStrata("FULLSCREEN_DIALOG")
    frame:SetFrameLevel(10000)
    frame:SetAllPoints(WorldFrame)
    frame:Hide()

    backdrop = frame:CreateTexture(nil, "BACKGROUND")
    backdrop:SetAllPoints()
    backdrop:SetColorTexture(0, 0, 0, 1)

    -- Preview-only caption. It must be HIDDEN for a capture: anything drawn on
    -- the stage is matted straight into the cutout.
    hint = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    hint:SetPoint("TOP", 0, -80)
    hint:Hide()

    model = CreateFrame("DressUpModel", nil, frame)
    -- A tall, narrow stage centred on screen: the converter trims to content,
    -- so the only thing that matters is that the figure fits with margin.
    model:SetPoint("CENTER", 0, -20)
    model:SetSize(420, 760)
end

-- The render settings measured as correct on 1.60.1.70009: both transmog
-- knobs OFF (either one blackens the face), auto-dress ON.
local function PoseLiveCharacter()
    model:ClearModel()
    if model.SetUseTransmogSkin then pcall(model.SetUseTransmogSkin, model, false) end
    if model.SetUseTransmogChoices then pcall(model.SetUseTransmogChoices, model, false) end
    if model.SetAutoDress then pcall(model.SetAutoDress, model, true) end
    pcall(model.SetUnit, model, "player")
    pcall(model.SetPortraitZoom, model, 0)
    pcall(model.SetPosition, model, 0, 0, 0)
    pcall(model.SetFacing, model, (Facing()))
    -- Identical pose in both shots or the matte is nonsense.
    if model.SetAnimation then pcall(model.SetAnimation, model, 0) end
    if model.FreezeAnimation then pcall(model.FreezeAnimation, model, 0, 0, 0) end
    if model.SetPaused then pcall(model.SetPaused, model, true) end
end

------------------------------------------------------------
-- When a capture may not happen
------------------------------------------------------------

-- Dead, or a ghost on a corpse run: a portrait of a wisp is not a portrait of
-- the character. UnitIsDeadOrGhost covers face-down and released.
local function DeadOrGhost()
    if type(UnitIsDeadOrGhost) ~= "function" then return false end
    local ok, dead = pcall(UnitIsDeadOrGhost, "player")
    return ok and dead and true or false
end

-- Inside a dungeon, raid, battleground or arena - never, including by hand.
-- The stage is a flat backdrop, so where the character stands makes no
-- difference to the picture; hiding the interface for three seconds does make
-- a difference to four people relying on you. instanceType is "none" in the
-- open world and names the kind otherwise, so anything a patch adds is covered.
local function InInstance()
    if type(IsInInstance) ~= "function" then return false end
    local ok, inside, kind = pcall(IsInInstance)
    if not ok then return false end
    if kind and kind ~= "none" then return true end
    return inside and true or false
end

-- Moving or falling: a roster portrait mid-stride is not what anyone wants,
-- and one that begins as somebody leaves the ground is worse.
local function Moving()
    if type(GetUnitSpeed) == "function" then
        -- Through PlainNumber: a unit number can be a secret value, and a
        -- comparison on one throws (docs/forever-api-notes.md, "Secret
        -- values"). Unknown speed is not a reason to refuse.
        local ok, speed = pcall(GetUnitSpeed, "player")
        local plain = ok and AltStable.API and AltStable.API.PlainNumber
            and AltStable.API.PlainNumber(speed)
        if plain and plain > 0 then return true end
    end
    if type(IsFalling) == "function" then
        local ok, falling = pcall(IsFalling)
        if ok and falling then return true end
    end
    return false
end

-- Why a capture cannot happen right now, or nil if it can. One function, so
-- every entry point refuses for the same reasons and says the same thing.
local function BlockedReason()
    if InCombatLockdown and InCombatLockdown() then
        return "not while you are in combat", "combat"
    end
    if DeadOrGhost() then
        return "not while you are dead - a portrait of a wisp is not a portrait", "dead"
    end
    if InInstance() then
        return "not inside a dungeon - it would hide your interface mid-run", "instance"
    end
    if Moving() then
        return "not while you are moving", "moving"
    end
    return nil
end

------------------------------------------------------------
-- The look (#128): what the portrait would show, to tell when it is out of date
------------------------------------------------------------

-- The slots a portrait SHOWS. Rings, trinkets and the neck are invisible in a
-- full-body shot, so changing one must not make a portrait "out of date"; nor
-- the ranged slot, which on Vanilla content is as often a relic (libram, idol,
-- totem) as a weapon (review of #134). The display ID is left out too: it
-- changes with a druid's forms, and the probe's auto-capture already found it
-- an unreliable signal (#124).
local LOOK_SLOTS = { 1, 3, 4, 5, 6, 7, 8, 9, 10, 15, 16, 17, 19 }
local HEAD, BACK = 1, 15
local SLOT_NAMES = {
    [1] = "Head", [3] = "Shoulder", [4] = "Shirt", [5] = "Chest", [6] = "Waist", [7] = "Legs",
    [8] = "Feet", [9] = "Wrist", [10] = "Hands", [15] = "Back", [16] = "Main Hand",
    [17] = "Off Hand", [19] = "Tabard",
}

-- Whether the helm and cloak are SHOWN: the equipment list cannot say a slot is
-- hidden (Scanner.lua, hidehelm), and a hidden helm is not in the portrait.
local function Showing(fn)
    if type(fn) ~= "function" then return true end
    local ok, v = pcall(fn)
    return not ok or v and true or false
end

-- "slot:itemID;slot:itemID;..." for the visible slots, 0 for an empty one and
-- "h" for a helm or cloak that is equipped but hidden. `;`, not `,`: the
-- converter's field reader stops a value at a comma.
--
-- nil when the client cannot say - and when NOTHING came back at all, which is
-- what inventory looks like before it has loaded after a login or a loading
-- screen. Reading that as "wearing nothing" made every slot "changed" (review
-- of #134). A character who really wears nothing in every shown slot reads as
-- unknown too; that is the cheaper mistake.
local function ReadLook()
    if type(GetInventoryItemID) ~= "function" then return nil end
    local showHelm, showCloak = Showing(ShowingHelm), Showing(ShowingCloak)
    local parts, any = {}, false
    for _, slot in ipairs(LOOK_SLOTS) do
        local id = tonumber((GetInventoryItemID("player", slot)))
        if id then any = true end
        local v = tostring(id or 0)
        if id and ((slot == HEAD and not showHelm) or (slot == BACK and not showCloak)) then v = "h" end
        parts[#parts + 1] = slot .. ":" .. v
    end
    return any and table.concat(parts, ";") or nil
end

-- Never lets a look failure out: it is read inside the capture's timer chain,
-- and an error there would stop the chain with the interface hidden.
local function CurrentLook()
    local ok, look = pcall(ReadLook)
    return ok and look or nil
end

-- The names of the slots two looks disagree on, in slot order. This, not the
-- strings being different, is what "changed" means: a stored look written by
-- another version of this code differs as a string without any slot differing.
local function LookDiff(a, b)
    local function parse(s)
        local t = {}
        for slot, v in tostring(s or ""):gmatch("(%d+):(%w+)") do t[tonumber(slot)] = v end
        return t
    end
    local pa, pb, out = parse(a), parse(b), {}
    for _, slot in ipairs(LOOK_SLOTS) do
        if pa[slot] ~= nil and pb[slot] ~= nil and pa[slot] ~= pb[slot] then out[#out + 1] = SLOT_NAMES[slot] end
    end
    return out
end

local function RecordMetadata(shotIndex)
    local store = Store()

    local first, surname = UnitName("player")
    local name = (surname and surname ~= "") and (first .. " " .. surname) or first
    local raceLoc, raceToken = UnitRace("player")
    local _, classToken = UnitClass("player")
    -- Both from the SAME source. Written as one and/or expression the call is
    -- truncated to a single value, so the width came from GetPhysicalScreenSize
    -- and the height from GetScreenHeight - physical pixels paired with a
    -- UI-scaled number, which is nobody's screen.
    local w, h
    if type(GetPhysicalScreenSize) == "function" then
        w, h = GetPhysicalScreenSize()
    else
        w, h = GetScreenWidth(), GetScreenHeight()
    end

    -- Unit numbers through PlainNumber: a secret value stored here would throw
    -- on every later read, and the store is written to disk. nil, not 0, when
    -- the client will not say - unknown is not zero.
    local Plain = (AltStable.API and AltStable.API.PlainNumber) or tonumber
    table.insert(store.renders, {
        name = name, guid = UnitGUID("player"),
        race = raceToken, raceLoc = raceLoc, class = classToken,
        sex = Plain(UnitSex("player")), level = Plain(UnitLevel("player")),
        shot = shotIndex,                     -- 1 = on black, 2 = on white
        -- Local time, the same clock the screenshot's FILENAME uses, so a
        -- converter can match the record to the file.
        stamp = date("%Y-%m-%d %H:%M:%S"),
        -- And an absolute one to ORDER by: local time repeats an hour when
        -- the clocks go back, and "newest" must not reverse across it.
        epoch = time(),
        screenW = w, screenH = h,
        uiScale = UIParent:GetEffectiveScale(),
        -- What the portrait shows, so a later change of gear can say it is out
        -- of date (#128). Converters do not read it (PORTRAIT-CONTRACT.md).
        look = CurrentLook(),
    })
end

local function RestoreFormat()
    if savedFormat and type(SetCVar) == "function" then
        pcall(SetCVar, "screenshotFormat", savedFormat)
    end
    savedFormat = nil
end

-- Give up on the capture in flight, completely.
--
-- Three callers give up for different reasons - combat, the player taking
-- their interface back, the watchdog - and all of them must do the same thing:
-- the timer chain stops, the records this capture wrote are removed, and the
-- interface comes back. A capture that only set a flag let the chain run on and
-- photograph the restored interface, and the converter pairs from the RECORDS,
-- so the ruined pair would have overwritten a good portrait.
--
-- restoreUI is false when the player has already put the interface back
-- themselves; there is nothing to give them and nothing we still own.
local function AbandonCapture(message, restoreUI)
    -- The stage goes first and unconditionally - but only if it EXISTS: it is
    -- built lazily by the first capture or preview. A preview goes with it
    -- completely: left marked as previewing, a later `facing` brought back a
    -- stage the player had not reopened - in the middle of the fight that
    -- closed it.
    if frame then
        frame:Hide()
        frame:EnableMouse(false)
        frame:SetScript("OnMouseDown", nil)
        if hint then hint:Hide() end
    end
    previewing = false
    if not capturing then return end

    captureToken = captureToken + 1     -- every pending callback is now void
    capturing = false
    if watchdog then watchdog:Cancel(); watchdog = nil end
    RestoreFormat()

    -- Drop whatever this capture already wrote. A lone shot-1 record is
    -- harmless (a converter only pairs a 1 with a 2), but a complete pair taken
    -- through a restored interface is not, and the watchdog can fire after
    -- both are on disk.
    local renders = AltStablePortraits and AltStablePortraits.renders
    if renders then
        for i = #renders, renderMark + 1, -1 do table.remove(renders, i) end
    end

    -- The strays come back WHATEVER restoreUI says. Declining to re-show
    -- UIParent respects a player who pressed Alt+Z; it does not extend to
    -- frames whose alpha we borrowed, which nobody else knows are at zero.
    RestoreStrays()

    local back = true
    if restoreUI then back = ShowUI() end
    if message then
        Out(message .. ((back or not restoreUI) and ""
            or " (interface returns when the fight ends)"))
    end
end

------------------------------------------------------------
-- After the shots: the record is only on disk after a reload
------------------------------------------------------------
-- SavedVariables are written on /reload and on logout, never in between. A
-- converter watching for new captures therefore sees the screenshots at once
-- and the record that says whose they are only later - so the capture offers
-- the reload itself rather than leaving the player to know.

-- Through SheetUI's secure prompt, not a StaticPopup calling ReloadUI(): that
-- call is blocked on this client when our code makes it (measured, #89; see
-- AltStable.ShowReloadPrompt).
local function ShowReloadPrompt()
    if AltStable.ShowReloadPrompt then
        AltStable.ShowReloadPrompt("Portrait captured.\nReload now so it reaches AltStable Companion?")
    end
end

local function Finish()
    capturing = false
    if watchdog then watchdog:Cancel(); watchdog = nil end
    frame:Hide()

    -- ALWAYS give the interface back. Everything else here is a nicety; a
    -- player left staring at an empty screen is not.
    ShowUI()
    RestoreFormat()

    Out("portrait captured - |cffffff00/reload|r so it reaches AltStable Companion "
        .. "(the record is only written on reload or logout)")
    if not autoRun then ShowReloadPrompt() end
    autoRun = nil
    if AltStable.RefreshPortraitStatus then AltStable.RefreshPortraitStatus() end
end

local function Capture(opts)
    -- ONE AT A TIME. Overlapping captures fought over the UI-restore flag and
    -- left the interface hidden. The age check is the get-out: a capture that
    -- somehow never finished does not seize the feature up forever.
    if capturing and captureStartedAt and (GetTime() - captureStartedAt) < 15 then
        return
    end
    -- No capture in combat, dead, in a dungeon or on the move, from ANY entry
    -- point - hiding the interface for three seconds during a pull is the
    -- single worst thing this feature can do.
    local why = BlockedReason()
    if why then
        Out("|cffff8800" .. why .. "|r")
        return
    end

    if type(Screenshot) ~= "function" then
        Out("|cffff5555Screenshot() is unavailable on this client.|r")
        return
    end
    if StoreTooNew() then
        Out("|cffff8800your capture records were written by a newer AltStable - "
            .. "update it to capture again|r")
        return
    end

    -- TGA or nothing. JPEG makes the matte read compression noise as coverage,
    -- and the converter cannot tell that from a real portrait - so a capture
    -- that could not switch the format is not taken, rather than taken badly.
    if type(GetCVar) == "function" and type(SetCVar) == "function" then
        savedFormat = GetCVar("screenshotFormat")
        pcall(SetCVar, "screenshotFormat", "tga")
        if GetCVar("screenshotFormat") ~= "tga" then
            RestoreFormat()
            Out("|cffff8800could not switch screenshots to TGA - no portrait taken|r")
            return
        end
    end

    capturing = true
    autoRun = type(opts) == "table" and opts.auto and true or nil
    captureStartedAt = GetTime()
    captureToken = captureToken + 1
    local token = captureToken
    renderMark = #Store().renders

    Build()

    -- Take the preview's click handler off the stage. Left attached, a click
    -- during the three seconds hides the stage while UIParent is still hidden.
    previewing = false
    hint:Hide()
    frame:EnableMouse(false)
    frame:SetScript("OnMouseDown", nil)
    PoseLiveCharacter()
    backdrop:SetColorTexture(0, 0, 0, 1)
    Out("staging... hold still, two screenshots are coming")

    -- Hiding UIParent fires the sheet's OnHide when the sheet is under it; the
    -- sheet knows that is its parent going, not a close (SheetUI's OnHide).
    if GameTooltip and GameTooltip.Hide then pcall(GameTooltip.Hide, GameTooltip) end
    -- And kept down: zeroing its alpha covers the lifted tooltip, but a tooltip
    -- that resets its own alpha when shown would not stay covered. See the
    -- Show hook at the bottom of the file.
    if not HideUI() then
        capturing = false
        RestoreFormat()
        Out("|cffff8800could not hide the interface - no portrait taken|r"
            .. (InCombatLockdown and InCombatLockdown() and " (in combat)" or ""))
        return
    end
    frame:Show()

    -- CANCELLED on success. Left running, one armed by an earlier capture fires
    -- in the middle of a later one and photographs the restored interface.
    -- NewTimer rather than After, precisely so it can be cancelled.
    if watchdog then watchdog:Cancel() end
    watchdog = C_Timer.NewTimer(WATCHDOG, function()
        watchdog = nil
        if token ~= captureToken then return end
        AbandonCapture("|cffff8800capture did not finish - your interface is back|r", true)
    end)

    C_Timer.After(KEY_DELAY, function()
        if token ~= captureToken then return end
        Screenshot()
        ShutterSound()
        RecordMetadata(1)
        C_Timer.After(SHOT_DELAY, function()
            if token ~= captureToken then return end
            backdrop:SetColorTexture(1, 1, 1, 1)     -- same pose, other backdrop
            C_Timer.After(SWAP_DELAY, function()
                if token ~= captureToken then return end
                Screenshot()
                ShutterSound()
                RecordMetadata(2)
                C_Timer.After(SHOT_DELAY, function()
                    if token ~= captureToken then return end
                    Finish()
                end)
            end)
        end)
    end)
end

-- Show the stage WITHOUT shooting, so the framing and the angle can be judged
-- before two screenshots are spent on them. The UI stays up (this is not a
-- capture) and a click dismisses it.
local function Preview()
    -- Not over a capture: re-posing unfreezes the model and repaints the
    -- backdrop between the two shots, and the pair is recorded as good anyway.
    if capturing then
        Out("a capture is running - preview after it")
        return
    end
    -- Not in combat either: the stage is a full-screen opaque frame.
    if InCombatLockdown and InCombatLockdown() then
        Out("|cffff8800not while you are in combat|r")
        return
    end
    Build()
    local _, deg = Facing()
    PoseLiveCharacter()
    backdrop:SetColorTexture(0.06, 0.06, 0.07, 1)
    hint:SetText(("facing %d\194\176  -  |cffffff00/alts portrait facing <deg>|r to turn, " ..
                  "|cffffff00/alts portrait|r to capture  (click to close)"):format(deg))
    hint:Show()
    previewing = true
    frame:EnableMouse(true)
    frame:SetScript("OnMouseDown", function()
        frame:Hide(); frame:EnableMouse(false); hint:Hide(); previewing = false
    end)
    frame:Show()
end

-- The player taking their interface back mid-capture - Alt+Z, or Escape.
--
-- Abandon, do not merely mark: flagging it left the chain running, and the
-- shots were taken through the restored interface. Pressing those keys means
-- "stop", and the stage goes at once.
if type(hooksecurefunc) == "function" and type(SetUIVisibility) == "function" then
    hooksecurefunc("SetUIVisibility", function(visible)
        if visible and capturing and uiHidden then
            uiHidden = nil          -- they restored it; we no longer own it
            AbandonCapture("|cffff8800interface came back mid-capture - "
                .. "portrait discarded|r", false)
        end
    end)
end

-- A tooltip shown DURING a capture is hidden again at once. The stage is at
-- FULLSCREEN_DIALOG and a tooltip draws at TOOLTIP, above it, so one raised by
-- the cursor resting on the (invisible, still hoverable) sheet is in the shot.
if type(hooksecurefunc) == "function" and GameTooltip then
    hooksecurefunc(GameTooltip, "Show", function(tip)
        if capturing and uiHidden then pcall(tip.Hide, tip) end
    end)
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_REGEN_DISABLED")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
-- Dying inside the three seconds is not exotic on a corpse run: shot one is
-- the character, shot two a wisp, and a converter pairs them happily.
events:RegisterEvent("PLAYER_DEAD")
-- screenshotFormat is a SAVED CVar. A reload, logout or disconnect inside the
-- three seconds ends the Lua state before the timer chain can put it back, and
-- the player's screenshots would be TGA from then on. PLAYER_LOGOUT fires on
-- a reload too.
events:RegisterEvent("PLAYER_LOGOUT")
-- What can make a new capture due (#128). Inventory is not readable at once on
-- entering the world (the probe measured it the hard way), so the first look
-- waits; gear changes come in bursts and are coalesced.
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
local STATUS_SETTLE, EQUIP_SETTLE = 8, 2
local equipTimer, worldTimer
events:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_ENTERING_WORLD" then
        -- Every loading screen fires this: one pending look, not one per zone.
        if worldTimer then worldTimer:Cancel() end
        worldTimer = C_Timer.NewTimer(STATUS_SETTLE, function()
            worldTimer = nil
            AltStable.RefreshPortraitStatus()
        end)
    elseif event == "PLAYER_EQUIPMENT_CHANGED" then
        if equipTimer then equipTimer:Cancel() end
        equipTimer = C_Timer.NewTimer(EQUIP_SETTLE, function()
            equipTimer = nil
            AltStable.RefreshPortraitStatus()
        end)
    elseif event == "PLAYER_LOGOUT" then
        RestoreFormat()
    elseif event == "PLAYER_DEAD" then
        AbandonCapture("|cffff8800you died - portrait abandoned|r", true)
    elseif event == "PLAYER_REGEN_DISABLED" then
        -- On EVERY path, not just the fallback. The engine hide is combat-safe
        -- to reverse, but leaving it in place means fighting the pull with no
        -- action bars until the chain finishes.
        AbandonCapture("|cffff8800combat started - portrait abandoned|r", true)
        -- No glow in a fight: the button cannot be used there anyway.
        GlowForCombat(true)
    elseif event == "PLAYER_REGEN_ENABLED" then
        if owedRestore then
            owedRestore = nil
            if ShowUI() then Out("interface restored") end
        end
        GlowForCombat(false)
    end
end)

------------------------------------------------------------
-- Public
------------------------------------------------------------

-- The capture, wherever it is asked for: the sheet's title-bar button and
-- /alts portrait. Returns true because it has taken responsibility - refusing
-- (combat, a dungeon) is an answer the player has been given, not a fall-through.
-- opts.auto: started by the countdown, not by a click (see autoRun).
function AltStable.CapturePortrait(opts)
    Capture(opts)
    return true
end

-- Whether a capture is running now - the countdown must not start a second.
function AltStable.PortraitCapturing()
    return capturing and true or false
end

-- Why a capture cannot happen right now, or nil. For anything that wants to
-- ask before offering one - the auto-capture follow-up in particular.
function AltStable.PortraitBlockedReason()
    return (BlockedReason())
end

------------------------------------------------------------
-- Is a new capture due? (#128)
--
-- For the character being played:
--   "changed" - the newest capture's look differs from what is worn now
--   "missing" - no portrait, and no capture waiting to become one
--   "pending" - captured, not converted yet (NOT due: it is done, and the
--               companion or a reload is what it waits for)
--   "none"    - a portrait, and nothing says it is out of date
-- A capture recorded before looks were (no `look`) never reads as "changed".
------------------------------------------------------------

-- The Roster's identity rules, from the core: a portrait there is one here.
-- The character's manifest entry, or nil.
local function CutoutEntry(guid, name)
    return AltStable.CutoutFor and AltStable.CutoutFor({ guid = guid, name = name }) or nil
end

-- For an entry that does not say which capture it was made from (written
-- before entries carried `epoch`): the manifest is loaded once, at startup, so
-- a capture taken since cannot be in it.
local SESSION_START = time()

-- The newest COMPLETE pair for a GUID (a shot 1 followed by its shot 2): an
-- abandoned half says nothing about what the portrait will show. Returns the
-- second record (it carries the look) and the FIRST shot's epoch, which is the
-- capture's identity in the contract.
local function LatestPair(guid)
    local renders = AltStablePortraits and AltStablePortraits.renders
    if type(renders) ~= "table" then return nil end
    for i = #renders, 2, -1 do
        local r2, r1 = renders[i], renders[i - 1]
        if type(r2) == "table" and type(r1) == "table" and r2.guid == guid and r1.guid == guid
           and r2.shot == 2 and r1.shot == 1 then
            return r2, tonumber(r1.epoch) or tonumber(r2.epoch)
        end
    end
    return nil
end

-- The name the Roster keys legacy portraits by: the scanner's own helper.
local function PlayerName()
    return AltStable.API and AltStable.API.PlayerFullName and AltStable.API.PlayerFullName() or nil
end

-- Built afresh on every call: whoever asks gets their own table.
function PortraitStatus()
    local guid = UnitGUID and UnitGUID("player")
    local status = { due = false, reason = "none", changedSlots = {} }
    if not guid then return status end
    local pair, captured = LatestPair(guid)
    local look = CurrentLook()
    -- What is worn now, so the auto-capture can remember a look it was told to
    -- skip (#124).
    status.look = look
    local diff = (pair and pair.look and look) and LookDiff(pair.look, look) or {}
    local entry = CutoutEntry(guid, PlayerName())
    local madeFrom = entry and tonumber(entry.epoch)
    if #diff > 0 then
        status.due, status.reason, status.changedSlots = true, "changed", diff
    elseif pair and not entry then
        status.reason = "pending"
    elseif pair and madeFrom then
        -- The portrait says which capture it was made from: pending until that
        -- is the newest one. Across reloads too - where "taken this session"
        -- alone let a replacement read as done the moment the game reloaded,
        -- with nothing converted (Codex review of #134).
        status.reason = (captured and captured > madeFrom) and "pending" or "none"
    elseif pair and (captured or 0) >= SESSION_START then
        -- An entry from before `epoch`: only "taken this session" can be told.
        status.reason = "pending"
    elseif entry then
        status.reason = "none"
    else
        status.due, status.reason = true, "missing"
    end
    return status
end
AltStable.CurrentPortraitStatus = PortraitStatus

-- Called whenever the status CHANGES. SheetUI's glow reads it, and PublicAPI
-- wraps it to tell other addons ("PortraitStatusChanged"). Everything that can
-- change the answer goes through RefreshPortraitStatus below.
function AltStable.PortraitStatusUpdated(status)
    if AltStable.UpdateCaptureGlow then AltStable.UpdateCaptureGlow(status) end
end

local lastStatusKey, lastStatus
function AltStable.RefreshPortraitStatus()
    local status = PortraitStatus()
    lastStatus = status
    -- The look too, while one is due: chest B and chest C are both "Chest
    -- changed", but a different answer - the auto-capture skips a LOOK, and
    -- without this, swapping a skipped chest for another one was never offered
    -- (#124).
    local key = status.reason .. "|" .. table.concat(status.changedSlots, ",")
        .. "|" .. (status.due and tostring(status.look) or "")
    if key == lastStatusKey then return status end
    lastStatusKey = key
    AltStable.PortraitStatusUpdated(status)
    return status
end

-- Combat changes whether the button glows, not whether a capture is due: the
-- last answer is reused rather than recomputed at the busiest moment. And the
-- combat state is SAID, not asked: at PLAYER_REGEN_DISABLED InCombatLockdown()
-- is still false (SheetUI notes the same), so asking kept the glow on for the
-- whole fight (review of #134).
function GlowForCombat(inCombat)
    if AltStable.UpdateCaptureGlow then
        AltStable.UpdateCaptureGlow(lastStatus or PortraitStatus(), inCombat)
    end
end

function AltStable.SetPortraitFacing(deg)
    deg = tonumber(deg)
    if not deg or StoreTooNew() then return false end
    deg = math.max(-FACING_LIMIT, math.min(FACING_LIMIT, deg))
    Store().facing = deg
    if previewing then Preview() end
    -- Options may be open: the slider follows the command.
    if AltStable.OnPortraitFacingChanged then AltStable.OnPortraitFacingChanged(deg) end
    return true
end
AltStable.PORTRAIT_FACING_LIMIT = FACING_LIMIT

local USAGE = "usage: |cffffff00/alts portrait|r [preview | facing <degrees> | cancel | glow on|off | auto on|off]"

-- /alts portrait [preview | facing <deg> | cancel]. `args` is what Core's
-- dispatcher left after the subcommand, already trimmed, or nil.
function AltStable.PortraitCommand(args)
    local msg = tostring(args or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()

    if msg == "" then
        Capture()
        return
    end
    if msg == "cancel" then
        if capturing then
            AbandonCapture("portrait cancelled", true)
        else
            Out("nothing to cancel")
        end
        return
    end
    if msg == "preview" then
        Preview()
        return
    end
    if msg == "facing" then
        local _, d = Facing()
        Out(("facing is %d\194\176 (0 faces you straight on) - "
            .. "|cffffff00/alts portrait facing <degrees>|r to change it"):format(d))
        return
    end
    local glow = msg:match("^glow%s+(%a+)$")
    if glow == "on" or glow == "off" then
        -- Through the config seam, like every other setting write.
        AltStable.SetConfigValue("portraitGlow", glow == "on")
        Out(glow == "on" and "the capture button will glow when a new portrait is due"
            or "the capture button will not glow")
        if AltStable.UpdateCaptureGlow then AltStable.UpdateCaptureGlow(AltStable.CurrentPortraitStatus()) end
        return
    end
    local auto = msg:match("^auto%s+(%a+)$")
    if auto == "on" or auto == "off" then
        AltStable.SetConfigValue("portraitAuto", auto == "on")
        Out(auto == "on"
            and "when your look changes, a toast above the chat counts down 5 minutes to a new portrait"
            or "no automatic portraits")
        if AltStable.EvaluateAutoCapture then AltStable.EvaluateAutoCapture() end
        return
    end
    local deg = msg:match("^facing%s+(%-?%d+%.?%d*)$")
    if deg then
        if AltStable.SetPortraitFacing(deg) then
            Out(("facing set to %d\194\176 - every capture from now on uses it"):format(AltStable.GetPortraitFacing()))
        else
            Out("a newer AltStable wrote the portrait store - not changing it")
        end
        return
    end
    Out(USAGE)
end

-- Test seam (the AltStable._test convention). Everything above is local, so
-- without this the file can be loaded but not driven, and the combat and Alt+Z
-- paths - the two that have produced real bugs - are unreachable from a test.
-- A sub-table: Core and SheetUI already own names on _test.
AltStable._test = AltStable._test or {}
AltStable._test.portrait = {
    Capture        = function(opts) return Capture(opts) end,
    autoRun        = function() return autoRun end,
    AbandonCapture = function(m, r) return AbandonCapture(m, r) end,
    Build          = function() return Build() end,
    Preview        = function() return Preview() end,
    events         = events,
    stage          = function() return frame end,
    model          = function() return model end,
    Store          = function() return Store() end,
    MigrateFacing  = function() return MigrateFacing() end,
    capturing      = function() return capturing and true or false end,
    previewing     = function() return previewing and true or false end,
    token          = function() return captureToken end,
    renderMark     = function() return renderMark end,
    DeadOrGhost    = function() return DeadOrGhost() end,
    STRAY_FRAMES   = STRAY_FRAMES,
    SuppressStrays = function() return SuppressStrays() end,
    -- Its counterpart. Suppression zeroes real alphas; a test that calls one
    -- without the other leaves those frames invisible for every assertion after.
    RestoreStrays  = function() return RestoreStrays() end,
    HideUI         = function() return HideUI() end,
    ShowUI         = function() return ShowUI() end,
    strays         = function() return strays end,
    owedRestore    = function() return owedRestore end,
    KEY_DELAY      = KEY_DELAY,
    SHOT_DELAY     = SHOT_DELAY,
    SWAP_DELAY     = SWAP_DELAY,
    WATCHDOG       = WATCHDOG,
    STORE_VERSION  = STORE_VERSION,
    CurrentLook    = function() return CurrentLook() end,
    LookDiff       = LookDiff,
    PortraitStatus = function() return PortraitStatus() end,
    CutoutEntry    = CutoutEntry,
    LOOK_SLOTS     = LOOK_SLOTS,
    ResetStatus    = function() lastStatusKey, lastStatus = nil, nil end,
    SetSessionStart = function(t) SESSION_START = t end,
}
