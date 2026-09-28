------------------------------------------------------------
-- Render.lua — make a cutout of the LIVE character, locally (#15)
--
-- Offline characters cannot be textured on this client (see Models.lua). The
-- live one renders perfectly, so the image source is our own client rather
-- than an armory: pose the live model on a flat backdrop, screenshot it, and
-- matte it to a transparent cutout on disk. Same look the old .NET pipeline
-- got from the Battle.net armory, with nothing to wait for.
--
-- TWO SHOTS, not a chroma key. The same frozen pose is captured once on BLACK
-- and once on WHITE; then for each pixel
--
--     alpha  = 1 - (white - black)
--     colour = black / alpha
--
-- which is exact, including hair, capes and anything semi-transparent, and has
-- none of the magenta fringing a key leaves behind. It costs one extra
-- screenshot and requires the pose to be IDENTICAL in both, which is why the
-- animation is paused and frozen before either shot.
--
-- Screenshots must be TGA: the default JPEG smears every edge and the matte
-- maths would be reading compression noise.
------------------------------------------------------------

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

-- Auto-capture timings. The login one is long because inventory is not
-- reliably readable the instant the world loads, and a fingerprint taken from
-- half-loaded gear would trigger a pointless capture every single login.
local LOGIN_SETTLE = 8
local WARN_SECONDS = 5

-- How long the player has to be OUT of combat before a capture is considered.
-- Leaving combat is not the same as being done fighting: between pulls there is
-- a gap of a few seconds, and hiding the interface in one of those is worse
-- than not taking the picture at all. Login is the intended moment; this is the
-- fallback for a gear change mid-session, and it is deliberately patient.
local COMBAT_SETTLE = 30

-- Declared up here because Capture() hides the notice before it hides the UI,
-- and Capture is defined long before the popup is. A constant referenced above
-- its own declaration is simply nil - the call still runs, does nothing, and
-- looks right.
local CONSENT_POPUP = "ALTSTABLE_RENDER_CONSENT"

-- Which way the character is turned, in degrees. 0 is dead-on; a slight turn
-- reads better in a lineup than a passport photo, and the same value is used
-- for every capture so a row of alts is consistent. Tunable because the right
-- angle is a matter of taste and can only be judged on screen.
local DEFAULT_FACING = 20

local function Facing()
    local deg = tonumber(AltStableProbeDB and AltStableProbeDB.facing)
    if not deg then deg = DEFAULT_FACING end
    return math.rad(deg), deg
end

local function Out(s)
    DEFAULT_CHAT_FRAME:AddMessage("|cff66ccff[render]|r " .. tostring(s))
end

-- UIParent:Hide()/Show() are PROTECTED. Called once combat has started the
-- client blocks them, and the block lands on the way BACK - so the interface
-- stays hidden for the whole fight and the addon takes the blame in an error
-- report. Seen live:
--
--   AddOn 'AltStableProbe' tried to call the protected function 'UIParent:Show()'
--
-- SetUIVisibility is the engine's own call - the one Alt+Z makes - and is not
-- protected. AltStable's camera showcase already uses it for exactly this
-- reason; the stage should never have hidden the UI a different way.
--
-- The stage survives it by being parented to WorldFrame rather than UIParent,
-- so the engine's hide does not take it with the rest of the interface.
-- Forward declarations, and they live UP HERE rather than beside the things
-- they name, because the blackout below is defined first and calls into them:
-- HideUI moves the prompt when the interface goes down, and Capture supersedes
-- a queued countdown. Declared later, those names resolve to globals - always
-- nil - and the call errors at the exact moment somebody is watching.
local StartCountdown, CancelPending, HidePrompt, Supersede, WaitForStillness
local PlacePrompt, SnoozeCapture, ConsiderCapture

local uiHidden        -- "engine" | "uiparent" | nil
local uiWasShown      -- was the interface up before we touched it?
local owedRestore     -- a protected restore we could not make during combat

-- Frames that survive the blackout because somebody lifted them OUT from under
-- UIParent on purpose.
--
-- AltStable's showcase reparents exactly two - the sheet and GameTooltip - so
-- that hiding the game UI does not take them with it. Hiding UIParent therefore
-- does not hide them, and UIParent:IsShown() says the interface is gone while
-- the addon's own window is still standing in front of the camera. The
-- portraits that came out of the sheet's capture button were pictures of the
-- sheet, tooltip included, and the check below was satisfied every time.
--
-- Named rather than discovered. "Anything not under UIParent" would also match
-- the STAGE, which is parented to WorldFrame for this very reason and is the
-- thing being photographed.
--
-- Alpha, not Hide: hiding the sheet fires its OnHide, which tears the showcase
-- down and restores the interface in the middle of the capture. Alpha is
-- invisible to the screenshot and to the frame.
-- The prompt is in here too, as a safety net rather than as the mechanism:
-- every path hides it before the shutter, and if one ever forgets, the
-- blackout catches it rather than printing it into the portrait.
local STRAY_FRAMES = { "AltStableSheet", "AltStableRenderPrompt" }

-- The character menu is CLOSED before a capture rather than dimmed, and it is
-- not on the list above.
--
-- Zeroing alpha is how the sheet is suppressed, and the menu cannot be handled
-- that way: during the showcase it is lifted to its own parentless root, so it
-- is not a child of the sheet and the sheet's alpha does not reach it. The
-- sheet closes the menu from OnHide, but a capture never hides the sheet - it
-- makes it invisible - so that handler does not run either.
--
-- Closing it uses the path that already exists: it releases the keyboard, hides
-- the full-screen click catcher and puts the menu back under its real parent. A
-- catcher left invisible but alive would still be eating every click on screen
-- during the capture, which is worse than a menu in the portrait.
--
-- This gap predates the glass work - the flat menu was equally unsuppressed -
-- and was found reviewing it.
local function CloseStrayMenu()
    if AltStable and AltStable.CloseCharacterMenu then
        pcall(AltStable.CloseCharacterMenu)
    end
end
local strays

local function SuppressStrays()
    strays = {}

    -- Settle anything that is mid-animation BEFORE reading its alpha.
    --
    -- The sheet's opening fade owns its alpha for 0.22 seconds, from 0 up to
    -- 1. A capture starting inside that window borrowed whatever it found -
    -- 0, or a third of the way up - while the fade carried on to 1 under its
    -- own timer; the restore afterwards then wrote the stale number back and
    -- left a sheet that was shown and completely invisible.
    --
    -- Two owners of one property need an order, not a race. This is the order.
    if AltStable and type(AltStable.FinishOpenAnimation) == "function" then
        pcall(AltStable.FinishOpenAnimation)
    end

    local function zero(f)
        if type(f) ~= "table" then return end
        if type(f.GetAlpha) ~= "function" or type(f.SetAlpha) ~= "function" then return end
        if f.IsShown and f:IsShown() == false then return end

        -- Only a frame that is genuinely NOT under UIParent. One that still is
        -- has already gone with the rest of the interface, and zeroing it would
        -- hand the player back an invisible window afterwards.
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
    zero(GameTooltip)
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
-- portrait, and the fingerprint that follows would record the ruin as done.
local function HideUI()
    if uiHidden then return true end

    uiWasShown = not (UIParent and UIParent.IsShown and UIParent:IsShown() == false)

    if type(SetUIVisibility) == "function" then
        pcall(SetUIVisibility, false)
        if UIParent and UIParent:IsShown() then
            return false            -- the call did not take
        end
        SuppressStrays()
        -- No PlacePrompt here: this branch just called SetUIVisibility, and
        -- the hook on it does the move. A second call would be a second answer
        -- to the same question, and no test could fail it.
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
        -- HERE it is load-bearing: this is the fallback for a client with no
        -- SetUIVisibility, so there is no hook to fire and nothing else would
        -- move the prompt out from under the UIParent just hidden.
        PlacePrompt()
        uiHidden = "uiparent"
        return true
    end
    return false
end

-- Returns true when the interface is back, false when we still owe it.
--
-- The flag is cleared ONLY on success. UIParent:Show() is protected, so on the
-- fallback path during combat the call is blocked - and clearing the flag first
-- would lose the fact that we still owe a restore, leaving the player without
-- an interface and nothing tracking that. That is the reported bug with an
-- extra step.
local function ShowUI()
    -- Before every branch below, including the early returns: the combat path
    -- gives up still owing a restore, and "leave the interface off, that is how
    -- we found it" is a statement about UIParent, not about frames whose alpha
    -- we borrowed.
    --
    -- Stated plainly because it matters for anyone changing this: the strays
    -- are set and cleared together with uiHidden, so `not uiHidden` with strays
    -- still pending is not reachable today - the one path that produced it,
    -- Alt+Z clearing uiHidden mid-capture, is handled at AbandonCapture where
    -- ShowUI is deliberately not called. This position is insurance against the
    -- next thing that clears uiHidden, and no test covers it on its own.
    RestoreStrays()

    if not uiHidden then return true end

    -- Leave it off if that is how we found it. The quiet-after-combat trigger
    -- fires in exactly the idle moments where someone has deliberately hidden
    -- their own interface, and forcing it back would be the addon overruling
    -- them.
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
    -- AFTER the interface is actually back, and only on this branch: the
    -- engine branch above returns through SetUIVisibility, whose hook does it.
    -- Called before the Show, it would read the interface as still down and
    -- leave the prompt out on WorldFrame.
    PlacePrompt()
    uiHidden = nil
    owedRestore = nil
    return true
end

local frame, model, backdrop, hint

-- Forward declarations, and they have to be UP HERE rather than beside the
-- countdown they belong to: Capture() cancels the queued countdown and takes
-- the prompt down, and Capture is defined several hundred lines before either.
-- Without this the names resolve to globals, which are nil - so the call errors
-- at the exact moment somebody presses the sheet's Capture button.
local savedFormat
local previewing
local capturing          -- one at a time, always
-- How many render records existed before the current capture began. Abandoning
-- truncates back to it, so a half-written pair cannot be picked up later.
-- Bumped by every capture and by every abort. Each timer in the chain holds the
-- value it was scheduled under and does nothing if it no longer matches, so an
-- abandoned capture cannot take a shot, record a fingerprint, or restore an
-- interface that a later capture is legitimately hiding.
local captureToken = 0
local renderMark = 0
local combatSettle       -- the quiet-after-combat wait, cancellable like the rest
-- Beside combatSettle rather than beside the countdown it belongs to, because
-- Capture() reads it to cancel a queued countdown and is defined first.
-- Declared later, `pending` inside Capture was a GLOBAL - always nil - so the
-- cancel never ran and the test that should have caught it read `pending` from
-- the right scope and saw the timer still armed.
local pending            -- the countdown timer, so it can be cancelled
local captureStartedAt
local watchdog           -- cancelled by Finish, or it fires into the NEXT capture
local toldConverter      -- the "run the converter" hint: once a session

local function Build()
    if frame then return end

    -- Parented to WorldFrame, NOT UIParent, so hiding UIParent during the shots
    -- takes every other frame away and leaves the stage standing. A fullscreen
    -- frame is not enough on its own: a tooltip draws at TOOLTIP strata, above
    -- FULLSCREEN_DIALOG, and gets matted straight into the cutout - measured,
    -- after AltStable's own minimap tooltip turned a 250x885 character into a
    -- 1790x1350 image with a tooltip floating beside her.
    frame = CreateFrame("Frame", "AltStableRenderStage", WorldFrame)
    frame:SetFrameStrata("FULLSCREEN_DIALOG")
    frame:SetFrameLevel(10000)
    frame:SetAllPoints(WorldFrame)
    frame:Hide()

    backdrop = frame:CreateTexture(nil, "BACKGROUND")
    backdrop:SetAllPoints()
    backdrop:SetColorTexture(0, 0, 0, 1)

    -- Preview-only caption. It must be HIDDEN for a capture: anything drawn on
    -- the stage is matted straight into the cutout, which is how a tooltip once
    -- ended up beside a gnome.
    hint = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    hint:SetPoint("TOP", 0, -80)
    hint:Hide()

    model = CreateFrame("DressUpModel", nil, frame)
    -- A tall, narrow stage centred on screen: the converter trims to content,
    -- so the only thing that matters is that the figure fits with margin.
    model:SetPoint("CENTER", 0, -20)
    model:SetSize(420, 760)
end

-- The render settings measured as correct on 1.60.1.70009 (see Models.lua):
-- both transmog knobs OFF, auto-dress ON.
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
-- "Has the character's look changed since the last portrait?"
--
-- The whole point of auto-capture: a portrait should refresh when the
-- character actually looks different, and never otherwise. Item IDs are the
-- right granularity - they decide the model - so enchants, gems and stat
-- rerolls do not trigger a pointless re-shoot, and neither does levelling.
------------------------------------------------------------

-- Dead, or a ghost on a corpse run.
--
-- Two reasons, and the second is the one that actually bit:
--
--   * a portrait of a wisp is not a portrait of the character;
--   * C_PlayerInfo.GetDisplayID() returns the GHOST display while you are one,
--     so the fingerprint below flips the moment you die and flips back when you
--     resurrect. Every death is therefore "your gear changed" - twice. A level
--     one corpse run produced three captures in as many minutes, each of them a
--     picture of a wisp, and the reported reason was gear the player had never
--     touched.
--
-- UnitIsDeadOrGhost covers both states in one call: face-down before releasing,
-- and the ghost afterwards.
local function DeadOrGhost()
    if type(UnitIsDeadOrGhost) ~= "function" then return false end
    local ok, dead = pcall(UnitIsDeadOrGhost, "player")
    return ok and dead and true or false
end

local function StoredFingerprint(guid)
    local looks = AltStableProbeDB and AltStableProbeDB.looks
    local rec = looks and looks[guid]
    return rec and rec.fp
end

-- Inside a dungeon, raid, battleground or arena.
--
-- Never, and that includes a capture asked for by hand. The stage is a flat
-- backdrop, so where the character is standing makes no difference to the
-- picture - but hiding the entire interface for three seconds does make a
-- difference when there are four other people relying on you, and the request
-- was "never in a dungeon" rather than "not usually".
--
-- instanceType is "none" in the open world and names the kind otherwise, so
-- this covers scenarios and anything a future patch adds without a list to
-- keep up to date.
local function InInstance()
    if type(IsInInstance) ~= "function" then return false end
    local ok, inside, kind = pcall(IsInInstance)
    if not ok then return false end
    if kind and kind ~= "none" then return true end
    return inside and true or false
end

-- Moving, falling, or otherwise not standing still.
--
-- The two shots have to be the SAME POSE - the matte subtracts one from the
-- other - and the model is frozen for that. But the character is also being
-- photographed mid-stride if the player is running, which is not what a roster
-- portrait should look like, and a capture that begins as somebody leaves the
-- ground is worse still.
local function Moving()
    if type(GetUnitSpeed) == "function" then
        local ok, speed = pcall(GetUnitSpeed, "player")
        if ok and (tonumber(speed) or 0) > 0 then return true end
    end
    if type(IsFalling) == "function" then
        local ok, falling = pcall(IsFalling)
        if ok and falling then return true end
    end
    return false
end

-- Why a capture cannot happen right now, or nil if it can.
--
-- One function, so that every entry point refuses for the same reasons and
-- says the same thing. Ordered by how permanent the answer is: combat and
-- death end on their own and have events that bring the trigger back, a
-- dungeon needs the player to leave, and standing still is a second away.
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

local function LookFingerprint(guid)
    local parts = {}
    for slot = 1, 19 do
        local link = GetInventoryItemLink("player", slot)
        local id = link and link:match("item:(%d+)")
        parts[#parts + 1] = id or "-"
    end

    -- The display id changes with a barber-shop visit or a race change, which
    -- is exactly the kind of "looks different" this is for.
    --
    -- It does NOT change when you die. MEASURED on 1.60.1.70009, both states,
    -- same character:
    --
    --     /run print(C_PlayerInfo.GetDisplayID(), UnitIsDeadOrGhost("player"))
    --     56658  false          (alive)
    --     56658  true           (a ghost, mid corpse run)
    --
    -- Which kills the theory this file briefly carried: that a ghost's own
    -- display id was flipping the fingerprint twice per death and producing
    -- "gear changed" on a corpse run where nothing had changed. It is not. The
    -- symptom is real and reproduced; the cause is NOT this field, and no
    -- substitution here would have helped. See docs/forever-api-notes.md.
    local displayID
    if C_PlayerInfo and type(C_PlayerInfo.GetDisplayID) == "function" then
        local ok, id = pcall(C_PlayerInfo.GetDisplayID)
        if ok then displayID = id end
    end
    parts[#parts + 1] = tostring(displayID or "?")
    return table.concat(parts, ":")
end

-- WHICH part of the look changed, as a short human-readable list.
--
-- Written because the cause of the repeated "gear changed" on a corpse run is
-- still unknown: the display id was measured and cleared, so it is one of the
-- nineteen equipment slots, and guessing which has already cost one wrong
-- theory. The next time this fires, the chat line names the slot instead of
-- describing the symptom - which turns the next occurrence into a measurement
-- rather than another round of reasoning.
local SLOT_NAMES = {
    "head", "neck", "shoulder", "shirt", "chest", "belt", "legs", "feet",
    "wrist", "gloves", "ring 1", "ring 2", "trinket 1", "trinket 2", "back",
    "main hand", "off hand", "ranged", "tabard",
}

local function FingerprintDiff(a, b)
    if not a or not b then return "no previous fingerprint" end
    -- Split on a TRAILING separator, not "[^:]*" on its own: the star matches
    -- the empty string between every pair of fields too, so the naive pattern
    -- returns twice as many parts and every index is doubled - which named the
    -- display id "field 39".
    local function split(fp)
        local out = {}
        for part in (fp .. ":"):gmatch("([^:]*):") do out[#out + 1] = part end
        return out
    end
    local old, new = split(a), split(b)

    local changed = {}
    for i = 1, math.max(#old, #new) do
        if old[i] ~= new[i] then
            local name = SLOT_NAMES[i] or (i == 20 and "display id") or ("field " .. i)
            changed[#changed + 1] = ("%s %s->%s"):format(
                name, tostring(old[i] or "-"), tostring(new[i] or "-"))
        end
    end
    if #changed == 0 then return "nothing" end
    return table.concat(changed, ", ")
end

local function RememberFingerprint(guid, fp)
    AltStableProbeDB = AltStableProbeDB or {}
    AltStableProbeDB.looks = AltStableProbeDB.looks or {}
    AltStableProbeDB.looks[guid] = { fp = fp, stamp = date("%Y-%m-%d %H:%M:%S") }
end

local function RecordMetadata(shotIndex)
    AltStableProbeDB = AltStableProbeDB or {}
    AltStableProbeDB.renders = AltStableProbeDB.renders or {}

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

    table.insert(AltStableProbeDB.renders, {
        name = name, guid = UnitGUID("player"),
        race = raceToken, raceLoc = raceLoc, class = classToken,
        sex = UnitSex("player"), level = UnitLevel("player"),
        shot = shotIndex,                     -- 1 = on black, 2 = on white
        stamp = date("%Y-%m-%d %H:%M:%S"),
        screenW = w, screenH = h,
        uiScale = UIParent:GetEffectiveScale(),
    })
end

-- Give up on the capture in flight, completely.
--
-- Three callers give up for different reasons - combat, the player taking their
-- interface back, and the watchdog - and they were not doing the same thing.
-- The user-restoration path in particular only set a flag: the timer chain ran
-- on, both screenshots were taken WITH the interface in them, and both records
-- were appended. Finish() then skipped the look fingerprint and said the
-- portrait was discarded, but the converter pairs from the RENDER records, not
-- the fingerprint - so the ruined pair was still eligible and would overwrite a
-- good portrait with one full of action bars.
--
-- restoreUI is false when the player has already put the interface back
-- themselves; there is nothing to give them and nothing we still own.
local function AbandonCapture(message, restoreUI)
    -- The stage goes first and unconditionally - but only if it EXISTS. It is
    -- built lazily by the first capture or preview, so combat entry on a fresh
    -- login, or after declining the notice, reaches this with frame still nil.
    -- Unconditional was right; unguarded was not.
    if frame then frame:Hide() end
    if not capturing then return end

    captureToken = captureToken + 1     -- every pending callback is now void
    capturing = false
    if watchdog then watchdog:Cancel(); watchdog = nil end

    if savedFormat and type(SetCVar) == "function" then
        pcall(SetCVar, "screenshotFormat", savedFormat)
        savedFormat = nil
    end

    -- Drop whatever this capture already wrote. A lone shot-1 record is
    -- harmless (the converter only pairs a 1 with a 2), but a complete pair
    -- taken through a restored interface is not, and the watchdog can fire
    -- after both are on disk.
    local renders = AltStableProbeDB and AltStableProbeDB.renders
    if renders then
        for i = #renders, renderMark + 1, -1 do table.remove(renders, i) end
    end

    -- The strays come back WHATEVER restoreUI says.
    --
    -- restoreUI is false when the player took their own interface back - Alt+Z
    -- mid-capture - and re-showing UIParent would then be the addon overruling
    -- them. That reasoning does not extend to frames whose alpha we borrowed:
    -- nobody else knows they are at zero, so skipping this leaves the player
    -- with the game UI they just asked for and an AltStable window that has
    -- silently vanished. Alt+Z is exactly what somebody presses when an addon
    -- starts taking pictures unexpectedly, so this is the likely path, not the
    -- exotic one.
    RestoreStrays()

    local back = true
    if restoreUI then back = ShowUI() end
    if message then
        Out(message .. ((back or not restoreUI) and ""
            or " (interface returns when the fight ends)"))
    end
end

local function Finish()
    capturing = false
    if watchdog then watchdog:Cancel(); watchdog = nil end
    frame:Hide()

    -- ALWAYS give the interface back. Everything else here is a nicety; a
    -- player left staring at an empty screen is not.
    ShowUI()
    -- Only now, once both shots are on disk: a fingerprint stored after a
    -- capture that failed half-way would suppress the retry.
    local guid = UnitGUID("player")
    if guid then RememberFingerprint(guid, LookFingerprint()) end
    if savedFormat and type(SetCVar) == "function" then
        pcall(SetCVar, "screenshotFormat", savedFormat)
    end
    -- One line per capture. The converter hint is worth saying once a session
    -- and no more: repeated identical chat is indistinguishable from something
    -- being stuck, which is exactly how the capture loop was first noticed.
    Out("portrait captured.")
    if not toldConverter then
        toldConverter = true
        Out("turn it into a cutout with:  |cffffff00pwsh Tools/RenderCutout/Update-Cutouts.ps1|r"
            .. "  (or -Watch once, and forget about it)")
    end
    -- The addon records that this LOOK was photographed; whether the picture
    -- came out is something only the converter can see. So if one is spoiled,
    -- /asrender forget puts this character back in the automatic queue.
end

local function Capture()
    -- ONE AT A TIME. Overlapping captures fought over the UI-restore flag and
    -- left the interface hidden - the player had to alt-z to get it back. The
    -- age check is the get-out: if a capture somehow never finished, a later
    -- one is allowed through rather than the feature seizing up forever.
    if capturing and captureStartedAt and (GetTime() - captureStartedAt) < 15 then
        return
    end
    -- No captures in combat, from ANY entry point. ConsiderCapture checks this
    -- for the automatic path, but /asrender and the notice's own button both
    -- reach here directly - and hiding the interface for three seconds during a
    -- pull is the single worst thing this feature can do.
    -- Checked HERE as well as in ConsiderCapture, because the countdown fires
    -- five seconds after it was armed and any of these can become true inside
    -- those five seconds - dying is most of what a corpse run consists of, and
    -- walking away is the most ordinary thing in the world. /asrender and the
    -- sheet's button also land here directly.
    local why = BlockedReason()
    if why then
        Out("|cffff8800" .. why .. "|r")
        return
    end

    -- Take the queued countdown with us, HERE rather than at each caller.
    --
    -- Every entry point has to do this or the armed timer fires five seconds
    -- into the capture it was overtaken by, and the player gets two captures
    -- and two interface blackouts. The Now button did it; /asrender and the
    -- sheet's Capture button did not - so pressing the sheet button while a
    -- countdown was up ran the whole chain twice. One place, and the rule
    -- cannot be forgotten by the next caller.
    --
    -- Supersede, not CancelPending: the countdown was not cancelled, it was
    -- overtaken, and the picture is being taken right now. CancelPending
    -- announces whenever a countdown was live - its `announce` argument only
    -- ever FORCES the message, there is no way to ask it for silence - so
    -- routing this through it told the player "auto-capture cancelled" one
    -- line before "staging... hold still".
    Supersede()

    capturing = true
    captureStartedAt = GetTime()
    captureToken = captureToken + 1
    local token = captureToken
    AltStableProbeDB = AltStableProbeDB or {}
    AltStableProbeDB.renders = AltStableProbeDB.renders or {}
    renderMark = #AltStableProbeDB.renders

    Build()

    if type(Screenshot) ~= "function" then
        capturing = false
        Out("|cffff5555Screenshot() is unavailable on this client.|r")
        return
    end

    -- The stage hides UIParent, which hides any StaticPopup, which fires its
    -- OnCancel - so take the notice down ourselves first, deliberately, rather
    -- than letting the client dismiss it as a side effect.
    if type(StaticPopup_Hide) == "function" then
        pcall(StaticPopup_Hide, CONSENT_POPUP)
    end
    -- JPEG would make the matte read compression noise instead of coverage.
    if type(GetCVar) == "function" and type(SetCVar) == "function" then
        savedFormat = GetCVar("screenshotFormat")
        pcall(SetCVar, "screenshotFormat", "tga")
        if GetCVar("screenshotFormat") ~= "tga" then
            Out("|cffff8800could not switch screenshots to TGA|r - the matte will be noisy")
        end
    end

    -- Take the preview's click handler off the stage. Left attached, a click
    -- during the three seconds hides the stage while UIParent is still hidden -
    -- the shots then photograph the bare world and the player sees nothing at
    -- all until the watchdog.
    previewing = false
    hint:Hide()
    frame:EnableMouse(false)
    frame:SetScript("OnMouseDown", nil)
    PoseLiveCharacter()
    backdrop:SetColorTexture(0, 0, 0, 1)
    Out("staging... hold still, two screenshots are coming")

    -- Say it BEFORE the UI goes, or the message lands in a hidden chat frame.
    if GameTooltip and GameTooltip.Hide then pcall(GameTooltip.Hide, GameTooltip) end
    if not HideUI() then
        capturing = false
        if watchdog then watchdog:Cancel(); watchdog = nil end
        if savedFormat and type(SetCVar) == "function" then
            pcall(SetCVar, "screenshotFormat", savedFormat)
            savedFormat = nil
        end
        Out("|cffff8800could not hide the interface - no portrait taken|r"
            .. (InCombatLockdown and InCombatLockdown() and " (in combat)" or ""))
        return
    end
    frame:Show()

    -- The whole sequence is a chain of timers. If any link fails, nothing
    -- restores the interface - so an independent timer does it regardless.
    --
    -- CANCELLED on success. Left running, the one armed by an earlier capture
    -- fires in the middle of a later one: it restores the interface and hides
    -- the stage while the second shot is still pending, so that shot
    -- photographs the restored UI and the matte reads the whole frame as
    -- opaque. NewTimer rather than After, precisely so it can be cancelled.
    if watchdog then watchdog:Cancel() end
    watchdog = C_Timer.NewTimer(12, function()
        watchdog = nil
        if token ~= captureToken then return end
        -- The same giving-up as combat and Alt+Z, for the same reasons. This
        -- used to restore the interface and the screenshot format by hand and
        -- stop there, which left the records of a chain that hung AFTER both
        -- shots were taken - a complete pair from a capture nobody trusts.
        AbandonCapture("|cffff8800capture did not finish - your interface is back|r", true)
    end)

    C_Timer.After(KEY_DELAY, function()
        if token ~= captureToken then return end
        Screenshot()
        RecordMetadata(1)
        C_Timer.After(SHOT_DELAY, function()
            if token ~= captureToken then return end
            backdrop:SetColorTexture(1, 1, 1, 1)     -- same pose, other backdrop
            C_Timer.After(SWAP_DELAY, function()
                if token ~= captureToken then return end
                Screenshot()
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
    Build()
    local _, deg = Facing()
    PoseLiveCharacter()
    backdrop:SetColorTexture(0.06, 0.06, 0.07, 1)
    hint:SetText(("facing %d\194\176  -  |cffffff00/asrender facing <deg>|r to turn, " ..
                  "|cffffff00/asrender|r to capture  (click to close)"):format(deg))
    hint:Show()
    previewing = true
    frame:EnableMouse(true)
    frame:SetScript("OnMouseDown", function()
        frame:Hide(); frame:EnableMouse(false); hint:Hide(); previewing = false
    end)
    frame:Show()
end

------------------------------------------------------------
-- Auto-capture: keep portraits current without anyone typing anything
------------------------------------------------------------


-- Automatic capture is OPT-IN now.
--
-- A portrait is an aesthetic choice, not a data field. Transmogrification
-- exists, so the gear somebody happens to be wearing when the addon notices a
-- change is very often not the gear they want to be seen in - and the addon
-- deciding that for them, by hiding their interface for three seconds to
-- photograph it, is the wrong default however politely it asks first.
--
-- So the recommended path is the capture button: you press it when you look
-- the way you want to look. Automatic capture is there for anyone who would
-- rather it just kept up, and it is off until they say so.
--
-- A NEW key, `autoCaptureOn`, rather than inverting the meaning of the
-- `autoCaptureOff` already on disk. Reinterpreting a persisted key is how
-- somebody who once turned the feature off has it turned back on by an update
-- - the old key simply stops being read, and absence means off, which is the
-- answer anyone who never chose would want.
local function AutoEnabled()
    return (AltStableProbeDB and AltStableProbeDB.autoCaptureOn) == true
end

------------------------------------------------------------
-- Say what is about to happen, the first time
--
-- The capture hides the ENTIRE UI for about three seconds and takes two
-- screenshots. Unannounced, that reads as something going badly wrong with the
-- game rather than a feature working.
--
-- Shaped after the client's own layer-swap notice: state plainly what will
-- happen, offer to do it immediately, otherwise let it proceed. Two buttons, no
-- interrogation - the alarming part is an interface that vanishes without
-- warning, not the capture. After the first one the five-second chat warning is
-- enough, because by then it is a known behaviour.
------------------------------------------------------------

-- Set to "yes" once the player has seen the notice, by either button. Escape
-- closes it without answering, which leaves this nil so the notice returns next
-- login rather than capturing unannounced.
local function Consent()
    return AltStableProbeDB and AltStableProbeDB.autoConsent
end

-- Both are defined below and both are called from the popup's buttons. Without
-- the forward declaration those closures resolve a nil GLOBAL at click time -
-- which is invisible until someone presses the button.

if type(StaticPopupDialogs) == "table" then
    StaticPopupDialogs[CONSENT_POPUP] = {
        text = "AltStable will take a portrait of this character for the Roster lineup.\n\n"
            .. "Your interface will be hidden for about 3 seconds while it takes two "
            .. "screenshots. They are deleted once the portrait is made.\n\n"
            .. "Later takes it next time your gear changes. "
            .. "Type |cffffff00/asrender auto|r if you would rather it never did this.",
        button1 = "Capture Now",
        button2 = "Later",
        OnAccept = function()                 -- Capture Now: skip the wait
            AltStableProbeDB.autoConsent = "yes"
            CancelPending()
            Capture()
        end,
        -- "Okay", but ALSO every programmatic dismissal: hiding UIParent hides
        -- the popup and the client calls this. So it records the answer and
        -- nothing more - starting a capture from here is what looped, because
        -- the capture hides the UI, which dismisses the popup, which lands
        -- straight back in this function.
        OnCancel = function()
            AltStableProbeDB.autoConsent = "yes"
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        -- Escape closes the notice WITHOUT running OnCancel. Without this the
        -- client routes Escape through OnCancel, which records consent - so
        -- waving the dialog away would quietly agree to it, and the next gear
        -- change would hide the interface for three seconds unannounced. That
        -- is the exact outcome the notice exists to prevent.
        noCancelOnEscape = true,
        showAlert = false,
    }
end

-- How long "not right now" lasts before it asks again.
--
-- Ten minutes: long enough that it is genuinely out of the way, short enough
-- that a portrait the player does want still happens this session. A snooze
-- that quietly never returned would be a Cancel wearing a friendlier label.
local SNOOZE_SECONDS = 600
local snoozed
-- The DEADLINE, kept beside the timer and outliving it.
--
-- The timer is what brings the portrait back; this is what keeps every other
-- trigger away until then. Without it "in ten minutes" meant only "there is a
-- timer for ten minutes" - a zone change, a resurrection or a login in the
-- meantime armed a fresh countdown for the same unrecorded look, and the
-- snooze the player pressed did nothing at all.
local snoozeUntil

-- "Not right now." Distinct from Cancel, which drops the trigger and waits for
-- something natural to raise it again, and from Never, which is a slash
-- command because it is the rare one.
function SnoozeCapture(why)
    Supersede()                       -- silently: the player is being told below
    snoozeUntil = GetTime() + SNOOZE_SECONDS
    snoozed = C_Timer.NewTimer(SNOOZE_SECONDS, function()
        snoozed, snoozeUntil = nil, nil
        ConsiderCapture(why or "gear changed since your last portrait")
    end)
    Out(("portrait postponed - asking again in %d minutes. "
        .. "|cffffff00/asrender auto|r stops it asking at all."):format(SNOOZE_SECONDS / 60))
end

-- Drop the queued countdown WITHOUT a word, because something is about to do
-- the thing it was counting down to. The player is about to be told "staging...
-- hold still"; a cancellation notice in front of that is a contradiction.
function Supersede()
    if combatSettle then combatSettle:Cancel(); combatSettle = nil end
    if pending then pending:Cancel(); pending = nil end
    -- The deadline goes too: a capture is happening right now, which is what
    -- the snooze was postponing.
    if snoozed then snoozed:Cancel(); snoozed = nil end
    snoozeUntil = nil
    HidePrompt()
end

-- Cancel whatever is queued. Returns whether anything was.
--
-- Only the COUNTDOWN is announced, because only the countdown was announced
-- when it started ("refreshing your portrait in 5s"). Cancelling it silently
-- would leave the player waiting for a picture that is not coming.
--
-- The quiet-after-combat wait is different: nothing told the player it was
-- running, so nothing should tell them it stopped. It did, and the result was
-- "[render] auto-capture cancelled - combat started" on EVERY pull - the timer
-- is armed when combat ends and cancelled the moment the next fight starts,
-- which while questing is a line of chat per mob.
--
-- announce forces the message for "/asrender cancel", where the player asked
-- and silence would look like the command did nothing.
-- keepSnooze: cancel the countdown but LEAVE the ten-minute delay alone.
--
-- Combat starting and dying both cancel a queued countdown, and both used to
-- take the snooze with it - so a fight inside those ten minutes ended the
-- delay, and the settle after the fight started a fresh countdown. Fighting
-- during a snooze is an ordinary thing to do, not a request to cancel it.
-- Explicit cancellation, turning auto-capture off, and a capture actually
-- happening still clear it.
function CancelPending(reason, announce, keepSnooze)
    -- The quiet-after-combat wait counts as pending. Without this, "/asrender
    -- cancel" during that window answered "nothing pending" and then took the
    -- picture thirty seconds later anyway.
    local hadCountdown, hadSettle = false, false
    if combatSettle then combatSettle:Cancel(); combatSettle = nil; hadSettle = true end
    if pending then pending:Cancel(); pending = nil; hadCountdown = true end
    -- A snooze counts as pending: "/asrender cancel" during one answered
    -- "nothing pending" and then took the picture ten minutes later anyway,
    -- which is the same bug the quiet-after-combat wait had.
    if snoozed and not keepSnooze then
        snoozed:Cancel(); snoozed = nil; snoozeUntil = nil; hadSettle = true
    end
    -- Every route out of the countdown passes through here - the buttons, the
    -- slash command, combat starting, the timer firing - so this is the one
    -- place the prompt has to come down. Unconditional: a prompt left on screen
    -- promising a portrait that is not coming is worse than no prompt.
    HidePrompt()
    if not (hadCountdown or hadSettle) then return false end
    if hadCountdown or announce then
        Out("auto-capture cancelled" .. (reason and (" - " .. reason) or ""))
    end
    return true
end

------------------------------------------------------------
-- The countdown, on screen and cancellable
--
-- It used to be a line of chat saying to type /asrender cancel. That is the
-- wrong shape for a five-second warning: it scrolls away behind combat spam,
-- it asks the player to find and type a command while the clock runs, and if
-- they are moving - a corpse run, say - they have neither the time nor a free
-- hand. The report that prompted this was exactly that: "I need to be able to
-- cancel it and I don't see the warning dialog."
--
-- So the buttons are on screen. NOT a StaticPopup: those take the centre of
-- the screen for what is a five-second interruption, and the consent notice
-- already uses one - two dialogs for one feature is one too many.
--
-- Parented to UIParent ON PURPOSE. The blackout hides it along with the rest
-- of the interface, so the prompt can never appear in the photograph.
------------------------------------------------------------

local prompt

-- The longest reason there is, which is the one a player sees mid-session:
-- the combat-settle trigger passes "quiet since combat - gear changed since
-- your last portrait". Sized for that rather than for the short one every test
-- happened to use, and the label is given its own height so it can wrap above
-- the buttons instead of through them.
local PROMPT_W, PROMPT_H = 360, 82
local PROMPT_LABEL_H = 40

local function BuildPrompt()
    if prompt then return prompt end

    -- pcall on the template, matching Probe.lua's Button/CreateCopyFrame in
    -- this same addon. A template that is missing on some build would
    -- otherwise throw inside ShowPrompt - which StartCountdown calls AFTER it
    -- has already promised a portrait in chat and BEFORE it arms the timer, so
    -- the player is told a picture is coming, sees an addon error, and no
    -- picture is ever taken.
    local ok, f = pcall(CreateFrame, "Frame", "AltStableRenderPrompt", UIParent, "BackdropTemplate")
    if not ok or not f then
        f = CreateFrame("Frame", "AltStableRenderPrompt", UIParent)
    end
    prompt = f
    -- Parked outside UIParent the moment it exists, and left there. Not
    -- lifted when the interface goes down: the repair would have to run on the
    -- very frame that stops receiving updates once its parent is hidden, which
    -- is the trap the previous version fell into. One statement, no transition
    -- to detect, no state to get wrong.
    -- FULLSCREEN_DIALOG, and nothing may set it back afterwards.
    --
    -- The sheet is DIALOG, which is ABOVE High - so the strata this used to
    -- end on left the warning underneath a window the player can drag
    -- anywhere, including over it. Being un-hidden is not the same as being on
    -- screen, and IsVisible() cannot see occlusion by a sibling either.
    --
    -- The parent is set by PlacePrompt on every show; UIParent is only where
    -- it starts.
    pcall(prompt.SetFrameStrata, prompt, "FULLSCREEN_DIALOG")
    prompt:SetSize(PROMPT_W, PROMPT_H)
    prompt:SetPoint("TOP", UIParent, "TOP", 0, -150)
    if prompt.SetBackdrop then
        prompt:SetBackdrop({
            bgFile   = "Interface/Buttons/WHITE8X8",
            edgeFile = "Interface/Buttons/WHITE8X8",
            tile = true, tileSize = 8, edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 },
        })
        prompt:SetBackdropColor(0.06, 0.06, 0.06, 0.94)
        prompt:SetBackdropBorderColor(0, 0, 0, 1)
    end

    prompt.label = prompt:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    prompt.label:SetPoint("TOPLEFT", 10, -9)
    prompt.label:SetPoint("TOPRIGHT", -10, -9)
    prompt.label:SetHeight(PROMPT_LABEL_H)
    prompt.label:SetJustifyH("LEFT")
    prompt.label:SetJustifyV("TOP")
    if prompt.label.SetWordWrap then prompt.label:SetWordWrap(true) end

    local function button(text, width, x, onClick)
        local ok2, b = pcall(CreateFrame, "Button", nil, prompt, "UIPanelButtonTemplate")
        if not ok2 or not b then
            b = CreateFrame("Button", nil, prompt)
            local fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            fs:SetAllPoints(); fs:SetJustifyH("CENTER")
            b.Text = fs
        end
        b:SetSize(width, 20)
        b:SetPoint("BOTTOMLEFT", prompt, "BOTTOMLEFT", x, 8)
        if b.SetText then b:SetText(text) elseif b.Text then b.Text:SetText(text) end
        b:SetScript("OnClick", onClick)
        return b
    end

    -- Now / Snooze / Cancel.
    --
    -- The three questions a player actually has, which the previous set did
    -- not cover: "Skip" and "Never" are both refusals, and neither of them is
    -- "not right now". Skip did come back eventually - at the next login or
    -- the end of the next fight - but nothing said so, and a button that
    -- looks like a refusal is not a way to say "later".
    --
    -- Turning it off for good is not a button any more. It is the rarest of
    -- the four and the only irreversible-feeling one, and it lives on
    -- /asrender auto, which the chat line names.
    button("Now", 70, 10, function()
        -- Just Capture(). It supersedes the countdown itself, which is the
        -- only way every other entry point gets the same treatment.
        Capture()
    end)
    button("Snooze", 80, 88, function()
        SnoozeCapture(prompt and prompt.why)
    end)
    button("Cancel", 80, 176, function()
        CancelPending("cancelled - it will ask again at the next login or "
            .. "after your next fight", true)
    end)

    prompt:Hide()
    return prompt
end

-- One definition of the line, used by the immediate paint and by OnUpdate.
-- Written twice, a colour or wording change applied to one shows a different
-- first frame from every frame after it.
local function Paint(p, left)
    p.shown = left
    p.label:SetText(("|cffffffffPortrait in %ds|r  |cffaaaaaa%s|r"):format(left, p.why or ""))
end

-- The prompt lives OUTSIDE UIParent for its whole shown life, like the stage.
--
-- Not conditionally, and not repaired when the interface goes down. An earlier
-- version lifted it only while UIParent was hidden and re-checked from the
-- prompt's own OnUpdate - which cannot work, because a frame whose parent is
-- hidden receives no OnUpdate. The repair lived on the very frame it was meant
-- to rescue, so opening the sheet mid-countdown hid the prompt for the rest of
-- the countdown while the independent timer ran on and took the picture
-- anyway. The test that "proved" it worked reached in and called the hidden
-- frame's handler by hand, supplying an update the client never delivers.
--
-- Unconditional removes the whole class: there is no transition to detect, no
-- driver that can stop running, and no state to get wrong.
--
-- It still cannot reach the photograph. Every path hides it before the
-- shutter, and STRAY_FRAMES covers it if one ever stops doing so.
-- Where the prompt has to live depends on whether the interface is up, and
-- there is no single answer.
--
-- Under UIParent it is an ordinary piece of interface and draws where the
-- player expects - but the showcase hides UIParent, and a shown frame under a
-- hidden parent is not on screen. Under WorldFrame it survives that hide, but
-- WorldFrame is the 3D scene: with the interface UP, a frame parented there
-- sits beneath all of it. Parking it there permanently fixed the showcase case
-- and broke the ordinary one - a countdown at login showed nothing at all,
-- which is the report that brought this back.
--
-- So it moves, and the thing that moves it is the blackout - not the prompt's
-- own OnUpdate, which stops arriving the moment its parent is hidden and was
-- the reason the first attempt at this could never work. Called from the
-- SetUIVisibility hook and from HideUI/ShowUI, both of which keep running
-- whatever the prompt's parent is doing.
function PlacePrompt()
    if not prompt then return end
    local interfaceDown = UIParent and UIParent.IsShown and UIParent:IsShown() == false
    local want = interfaceDown and WorldFrame or UIParent

    if prompt:GetParent() ~= want then
        pcall(prompt.SetParent, prompt, want)
        pcall(prompt.SetFrameStrata, prompt, "FULLSCREEN_DIALOG")
    end

    -- WorldFrame does not carry the player's UI scale, so a prompt parked
    -- there would be drawn at a different size from every other piece of
    -- interface. Under UIParent the scale is inherited and must be left at 1,
    -- or it is applied twice.
    local eff = UIParent and UIParent.GetEffectiveScale and UIParent:GetEffectiveScale()
    pcall(prompt.SetScale, prompt, (interfaceDown and eff and eff > 0) and eff or 1)
end

-- The prompt while it waits for the player to stand still. Same frame, same
-- buttons - Skip still skips - with the countdown replaced by what it is
-- actually waiting for, because "Portrait in 0s" forever is a bug report.
local function PromptWaiting(why)
    local p = BuildPrompt()
    p.why = why
    p.shown = nil
    p:SetScript("OnUpdate", nil)
    p.label:SetText(("|cffffffffPortrait when you stand still|r  |cffaaaaaa%s|r")
        :format(why or ""))
    PlacePrompt()
    p:Show()
end

local function ShowPrompt(why, seconds)
    local p = BuildPrompt()
    p.deadline = GetTime() + seconds
    p.why = why
    p:SetScript("OnUpdate", function(self)
        local left = math.ceil(math.max(0, (self.deadline or 0) - GetTime()))
        -- Only when the number actually changes. Repainting every frame is
        -- ~300 string.format and SetText calls per countdown where five are
        -- needed, on something armed at every login and every gear change.
        if left ~= self.shown then Paint(self, left) end
        if left <= 0 then self:SetScript("OnUpdate", nil) end
    end)
    -- Paint once immediately: with only OnUpdate the frame shows for one frame
    -- with whatever text it had last time, which on the second countdown is the
    -- previous reason.
    Paint(p, seconds)
    PlacePrompt()
    p:Show()
end

function HidePrompt()
    if not prompt then return end
    prompt:SetScript("OnUpdate", nil)
    -- Hidden, and left where it is. A hidden frame draws nothing wherever it
    -- is parented, and putting it back under UIParent only to move it out
    -- again on the next countdown is churn with a state flag attached - which
    -- is what the previous version got wrong.
    prompt:Hide()
end

function StartCountdown(why)
    -- Idempotent. Five of these queued at once is what turned one dismissed
    -- popup into a capture loop.
    if pending or capturing then return end
    -- The chat line no longer explains how to cancel: there is a Skip button on
    -- screen, and two mechanisms for one job is the thing the prompt was added
    -- to stop. It still SAYS what is happening, because chat is the record a
    -- player scrolls back through afterwards.
    Out(("%s - refreshing your portrait in %ds. |cffffff00/asrender auto|r stops it asking.")
        :format(why, WARN_SECONDS))
    ShowPrompt(why, WARN_SECONDS)
    pending = C_Timer.NewTimer(WARN_SECONDS, function()
        pending = nil
        -- Asked again at the moment it fires, not only when it was scheduled.
        -- Cancelling on the /asrender auto path covers the command; this covers
        -- every other way the answer could have changed in those five seconds.
        if not AutoEnabled() then
            HidePrompt()
            Out("auto-capture was turned off - not taking the picture")
            return
        end

        -- Still moving? WAIT, do not drop it.
        --
        -- Dropping the picture here would repeat the mistake the ghost guard
        -- made: refusing consumes the trigger, and the next thing to ask is a
        -- login or the end of a fight. Standing still is a second away, so the
        -- prompt changes what it says and keeps its Skip button, which is the
        -- honest version of "waiting for a good moment".
        if Moving() then
            WaitForStillness(why)
            return
        end

        -- The timer FIRING is the one exit that does not go through
        -- CancelPending, so it hides the prompt itself. Left up, it would sit
        -- there reading "Portrait in 0s" over the capture that already
        -- happened, with a Skip button that skips nothing.
        HidePrompt()
        Capture()
    end)
end

-- How long to keep waiting for somebody to stand still before letting it go.
-- Long enough to cover running back to an inn, short enough that a player who
-- is questing for an hour is not followed around by a prompt.
local STILLNESS_LIMIT = 90

function WaitForStillness(why)
    local waitedUntil = GetTime() + STILLNESS_LIMIT
    PromptWaiting(why)

    local function poll()
        pending = nil
        if not AutoEnabled() then HidePrompt(); return end

        -- Anything ELSE that blocks - a fight started, they died, they zoned
        -- into a dungeon - ends the wait rather than outlasting it. Those have
        -- their own events to bring the trigger back; this one does not.
        local blocked, kind = BlockedReason()
        if blocked and kind ~= "moving" then
            HidePrompt()
            return
        end

        if not blocked then
            HidePrompt()
            Capture()
            return
        end

        if GetTime() >= waitedUntil then
            HidePrompt()
            Out("still moving - portrait postponed, it will ask again later")
            return
        end
        pending = C_Timer.NewTimer(1, poll)
    end

    pending = C_Timer.NewTimer(1, poll)
end

function ConsiderCapture(why)
    if not AutoEnabled() then return end
    if pending or capturing then return end

    -- The snooze is a promise about every trigger, not just the one that was
    -- on screen when it was pressed. Checked against the DEADLINE rather than
    -- the timer, because the timer can be cancelled by combat while the
    -- promise still stands.
    if snoozeUntil and GetTime() < snoozeUntil then return end

    local guid = UnitGUID("player")
    if not guid then return end

    local fp = LookFingerprint(guid)
    if fp == StoredFingerprint(guid) then return end          -- looks the same

    -- Never interrupt a fight to take a photograph, never do it in a dungeon,
    -- and never put a popup on screen during either. Each of these has an
    -- event that brings the trigger back: PLAYER_REGEN_ENABLED after a fight,
    -- PLAYER_UNGHOST / PLAYER_ALIVE after a death, PLAYER_ENTERING_WORLD on
    -- the way out of an instance.
    --
    -- Moving is deliberately NOT one of them. It is over in a second, it has
    -- no event worth waiting on, and the countdown itself handles it: the
    -- prompt waits for the player to stand still rather than dropping the
    -- picture and hoping something asks again.
    -- Name the change. One line, only when something really did change, and it
    -- is the only way the remaining mystery gets solved: the display id has
    -- been ruled out by measurement, so it is a slot, and this says which.
    Out("look changed: " .. FingerprintDiff(StoredFingerprint(guid), fp))

    local blocked, kind = BlockedReason()
    if blocked and kind ~= "moving" then
        if kind == "combat" then
            Out("gear changed - portrait will refresh after combat")
        end
        return
    end

    if Consent() ~= "yes" then
        AltStableProbeDB = AltStableProbeDB or {}
        if Consent() == "never" then return end
        if type(StaticPopup_Show) == "function" and StaticPopupDialogs
            and StaticPopupDialogs[CONSENT_POPUP] then
            -- Once. Asking again while the notice is already up queues a second
            -- copy, and each copy answers itself when the stage hides the UI.
            if type(StaticPopup_Visible) == "function"
                and StaticPopup_Visible(CONSENT_POPUP) then
                return
            end
            StaticPopup_Show(CONSENT_POPUP)
        else
            -- No popup API: say it in chat rather than doing it unannounced.
            Out("AltStable can take a portrait of this character: it hides the UI for ~3s "
                .. "and takes two screenshots. |cffffff00/asrender|r to do it, "
                .. "|cffffff00/asrender auto|r to stop being asked.")
            -- "yes", not "asked": every reader compares against "yes" or
            -- "never", so a third value means this branch is re-entered on
            -- every trigger forever - the same notice after every fight, and a
            -- portrait never taken, because nothing ever records a fingerprint.
            AltStableProbeDB.autoConsent = "yes"
        end
        return
    end

    StartCountdown(why)
end

-- SheetUI's showcase hooks this for the same reason: the engine call is how the
-- player takes their interface back, and it can land in the middle of a
-- capture.
if type(hooksecurefunc) == "function" and type(SetUIVisibility) == "function" then
    hooksecurefunc("SetUIVisibility", function(visible)
        -- FIRST, and regardless of whether a capture is running. This is the
        -- event that tells us the interface went down or came back, and the
        -- showcase uses it every time the sheet opens - so it is how a prompt
        -- shown during an ordinary countdown follows the interface without
        -- depending on updates it stops receiving.
        PlacePrompt()

        if visible and capturing and uiHidden then
            uiHidden = nil          -- they restored it; we no longer own it
            -- Abandon, do not merely mark. Flagging it left the chain running:
            -- the shots were taken through the restored interface and their
            -- records were still written, and the converter reads those records
            -- rather than the fingerprint Finish() withholds. Alt+Z and Escape
            -- now dismiss the stage immediately, which is what pressing them
            -- means.
            AbandonCapture("|cffff8800interface came back mid-capture - "
                .. "portrait discarded, will retry|r", false)
        end
    end)
end

SLASH_ASRENDER1 = "/asrender"
SlashCmdList["ASRENDER"] = function(msg)
    msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()

    if msg == "cancel" then
        -- The player asked, so say something either way.
        if not CancelPending(nil, true) then Out("nothing pending") end
        return
    end
    local deg = msg:match("^facing%s+(%-?%d+%.?%d*)$")
    if deg then
        AltStableProbeDB = AltStableProbeDB or {}
        AltStableProbeDB.facing = tonumber(deg)
        Out(("facing set to %s\194\176 - every capture from now on uses it"):format(deg))
        if previewing then Preview() else Out("  |cffffff00/asrender preview|r to see it") end
        return
    end
    if msg == "facing" then
        local _, d = Facing()
        Out(("facing is %d\194\176 (0 faces you straight on). usage: /asrender facing <deg>"):format(d))
        return
    end
    if msg == "preview" then
        Preview()
        return
    end
    if msg == "forget" or msg == "forget all" then
        AltStableProbeDB = AltStableProbeDB or {}
        if msg == "forget all" then
            AltStableProbeDB.looks = {}
            Out("forgot every stored look - each character re-captures at next login")
        else
            local guid = UnitGUID("player")
            if guid and AltStableProbeDB.looks then AltStableProbeDB.looks[guid] = nil end
            Out("forgot this character's look - it re-captures at next login")
        end
        return
    end
    if msg == "auto" then
        AltStableProbeDB = AltStableProbeDB or {}
        AltStableProbeDB.autoCaptureOn = (not AutoEnabled()) or nil
        Out("auto-capture " .. (AutoEnabled() and "|cff55ff55on|r" or "|cffff5555off|r")
            .. " - the |cffffff00capture button|r on the sheet takes one whenever you like, "
            .. "which is usually what you want: it photographs you as you look NOW.")
        -- Turning it off has to stop what is already coming. Otherwise the
        -- countdown announced a moment ago still fires, and the interface
        -- vanishes for three seconds directly after the player was told
        -- auto-capture is off.
        if not AutoEnabled() then CancelPending("auto-capture turned off", true) end
        return
    end
    if msg == "status" then
        local guid = UnitGUID("player")
        Out("auto-capture " .. (AutoEnabled() and "on" or "off")
            .. " (consent: " .. tostring(Consent() or "not asked yet") .. ")")
        Out("look now    : " .. LookFingerprint())
        Out("last shot   : " .. tostring(guid and StoredFingerprint(guid) or "never"))
        return
    end
    if msg ~= "" then
        Out("usage: /asrender [preview|facing <deg>|cancel|auto|status|forget|forget all]")
        return
    end

    CancelPending()
    -- Doing it by hand answers the question the popup would ask.
    AltStableProbeDB = AltStableProbeDB or {}
    if Consent() ~= "never" then AltStableProbeDB.autoConsent = "yes" end
    Capture()
end

local auto = CreateFrame("Frame")
auto:RegisterEvent("PLAYER_LOGIN")
auto:RegisterEvent("PLAYER_REGEN_ENABLED")
auto:RegisterEvent("PLAYER_REGEN_DISABLED")
-- Dying, and coming back.
--
-- The guards on ConsiderCapture and Capture only look at the moment a capture
-- is asked for. A capture takes about three seconds, and dying inside those
-- three seconds is not exotic on a corpse run: shot one is the character, shot
-- two is a wisp, and the converter pairs them happily into a cutout that
-- overwrites the good portrait.
--
-- PLAYER_UNGHOST / PLAYER_ALIVE re-arm the other half. Refusing while dead
-- CONSUMES the trigger - the combat-settle timer fires during the corpse run,
-- finds the player dead and returns - so without these a genuine gear change
-- that happened to coincide with a death would wait for the next fight or the
-- next login.
auto:RegisterEvent("PLAYER_DEAD")
auto:RegisterEvent("PLAYER_UNGHOST")
auto:RegisterEvent("PLAYER_ALIVE")
-- And on the way out of a dungeon. Refusing inside one CONSUMES the trigger,
-- so without this a gear change made in an instance would wait for the next
-- fight or the next login. Same settle delay as login: zoning is a loading
-- screen, and inventory is not reliably readable the instant it ends.
auto:RegisterEvent("PLAYER_ENTERING_WORLD")
auto:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_ENTERING_WORLD" then
        C_Timer.After(LOGIN_SETTLE, function()
            ConsiderCapture("gear changed since your last portrait")
        end)
        return
    elseif event == "PLAYER_DEAD" then
        CancelPending("you died", nil, true)
        AbandonCapture("|cffff8800you died - portrait abandoned|r", true)
        return
    elseif event == "PLAYER_UNGHOST" or event == "PLAYER_ALIVE" then
        -- Only if there is something to do: ConsiderCapture compares the
        -- fingerprint and returns quietly when the look is unchanged, which
        -- after an ordinary death it is.
        ConsiderCapture("gear changed since your last portrait")
        return
    end

    if event == "PLAYER_REGEN_DISABLED" then
        -- A fight started inside the countdown: hiding the UI for three
        -- seconds mid-pull is the one thing this must never do.
        CancelPending("combat started", nil, true)
        -- Abandon an in-flight capture on EVERY path, not just the fallback.
        -- The engine hide is combat-safe to REVERSE, but leaving it in place
        -- means the player fights the pull with no action bars until the chain
        -- finishes - which is the same harm as the protected-call bug, just
        -- without an error report to show for it.
        AbandonCapture("|cffff8800combat started - portrait abandoned|r", true)
    elseif event == "PLAYER_LOGIN" then
        -- Nothing. Deliberately.
        --
        -- PLAYER_LOGIN fires BEFORE the loading screen ends, so a countdown
        -- armed here burned down while the player was still watching a
        -- progress bar: the five-second warning was over before there was a
        -- screen to show it on, and the capture arrived looking instantaneous
        -- and unannounced. Reported from a live login.
        --
        -- PLAYER_ENTERING_WORLD is the event that means "there is a world on
        -- screen now", it fires on login too, and it already runs the same
        -- settle - so the login case is handled there and does not want a
        -- second, earlier timer racing it.
        --
        -- The registration stays: losing it would make this a silent
        -- behaviour change rather than a stated one, and the branch is where
        -- the reason lives. And it earns its keep with the line below.

        -- The retired key goes, now that nothing reads it.
        --
        -- Its VALUE is deliberately not consulted on the way out - that is the
        -- whole point of having stopped reading it - and nothing is lost either
        -- way: `autoCaptureOff = true` meant "off", which is the new default,
        -- and `false` meant "on", which is now a choice to make once rather
        -- than one an update makes on your behalf. What is gained is that the
        -- file on disk stops carrying a key whose meaning the next reader has
        -- to reconstruct, which is the treatment Config.lua gives its own
        -- retired keys.
        if AltStableProbeDB then AltStableProbeDB.autoCaptureOff = nil end
    else
        -- First, anything we could not give back during the fight.
        if owedRestore then
            owedRestore = nil
            if ShowUI() then Out("interface restored") end
        end
        -- Then wait out the gap between pulls rather than capturing in it. Any
        -- new fight cancels this, so a long chain of pulls never reaches it.
        if combatSettle then combatSettle:Cancel() end
        combatSettle = C_Timer.NewTimer(COMBAT_SETTLE, function()
            combatSettle = nil
            ConsiderCapture("quiet since combat - gear changed since your last portrait")
        end)
    end
end)

-- Test seam (the AltStable._test convention). Everything above is local, so
-- without this the file can be loaded but not driven, and the combat and Alt+Z
-- paths - the two that have produced real bugs - are unreachable from a test.
AltStableProbe = AltStableProbe or {}

-- The two-shot capture, for anything outside this file that wants a portrait.
-- The sheet's button used to take a single plain screenshot of its own, which
-- produced a picture no part of the pipeline reads.
function AltStableProbe.CapturePortrait()
    Capture()
end

AltStableProbe._test = {
    Capture        = function() return Capture() end,
    AbandonCapture = function(m, r) return AbandonCapture(m, r) end,
    Build          = function() return Build() end,
    events         = auto,
    stage          = function() return frame end,
    capturing      = function() return capturing and true or false end,
    token          = function() return captureToken end,
    renderMark     = function() return renderMark end,
    CancelPending  = function(r, a) return CancelPending(r, a) end,
    DeadOrGhost    = function() return DeadOrGhost() end,
    SNOOZE_SECONDS = SNOOZE_SECONDS,
    snoozeUntil    = function() return snoozeUntil end,
    STRAY_FRAMES   = STRAY_FRAMES,
    SuppressStrays = function() return SuppressStrays() end,
    -- Its counterpart. Suppression zeroes real alphas and records them in a
    -- module-local table; a test that calls one without the other leaves those
    -- frames invisible for every assertion after it.
    RestoreStrays  = function() return RestoreStrays() end,
    LookFingerprint = function(g) return LookFingerprint(g) end,
    StoredFingerprint = function(g) return StoredFingerprint(g) end,
    RememberFingerprint = function(g, fp) return RememberFingerprint(g, fp) end,
    ConsiderCapture = function(why) return ConsiderCapture(why) end,
    prompt         = function() return prompt end,
    -- IsVisible, not IsShown. A shown frame under a hidden parent is not on
    -- screen, and a seam that cannot tell them apart let the prompt vanish
    -- behind the showcase with every on-screen assertion still passing.
    PromptText     = function()
        if not prompt or not prompt:IsVisible() then return nil end
        return prompt.label:GetText()
    end,
    PromptShown    = function() return prompt and prompt:IsShown() and true or false end,
    PromptClick    = function(text)
        if not prompt or not prompt:IsShown() then return false end
        for _, b in ipairs({ prompt:GetChildren() }) do
            if b.GetText and b:GetText() == text then
                local fn = b:GetScript("OnClick")
                if fn then fn(b) end
                return true
            end
        end
        return false
    end,
    HideUI         = function() return HideUI() end,
    ShowUI         = function() return ShowUI() end,
    strays         = function() return strays end,
    StartCountdown = function(why) return StartCountdown(why) end,
    pendingKind    = function()
        return (pending and "countdown") or (snoozed and "snooze")
            or (combatSettle and "settle") or nil
    end,
    KEY_DELAY      = KEY_DELAY,
    SHOT_DELAY     = SHOT_DELAY,
    SWAP_DELAY     = SWAP_DELAY,
}
