--[[
    ForeverAPIDump — write this client's whole API surface to disk.

    Why this exists: three separate "that API is gone" conclusions in one
    evening turned out to be probes asking the wrong question. A name can live
    as a global, as a member of a C_* namespace, as a widget method, or on an
    internal event system, and `type(Name)` only ever asks about the first.

    Forever ships Blizzard_APIDocumentation, so the client will describe
    itself: signatures, argument order, which arguments are optional, return
    values, event payloads. That beats any website, because it is THIS build
    rather than whatever Retail looked like when the page was written.

    Four passes, because no single one is complete:

      documented  - APIDocumentation: signatures and types, but only for APIs
                    Blizzard documents. Legacy globals like GetCVar are absent.
      globals     - a _G walk: everything actually callable, no signatures.
      namespaces  - every C_* table's members, same trade-off.
      widgets     - methods off each widget type's metatable. This is the pass
                    that would have answered "does TryOn exist" correctly; the
                    global check says nil on a client where it works fine.

    SavedVariables are WRITTEN correctly on this client even though they are
    never read back (#23), so this path is unaffected by that bug. The file
    lands on /reload or logout:

        WTF\Account\<id>\SavedVariables\ForeverAPIDump.lua

    Output is flat arrays of strings rather than nested tables: greppable from
    outside the game, and far smaller than the structured form.

    RUN IT, THEN /reload. Walking every global and creating two dozen widgets
    is a taint risk: the first run opened the character sheet by itself and
    left CTRL-A behaving like a movement binding, which is the usual shape of
    tainted execution reaching the secure UI. A /reload clears it. This is a
    dev tool for a beta client, not something to leave running during play -
    which is also why it no longer builds at login.
]]

ForeverAPIDumpDB = ForeverAPIDumpDB or {}

local function Out(msg)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff[APIDump]|r " .. tostring(msg))
    end
end

------------------------------------------------------------
-- Formatting
------------------------------------------------------------

-- "name:type" per parameter, with Nilable surfaced as `optional` the way /api
-- prints it. The type matters more than it looks: a struct-returning
-- replacement for a tuple-returning global is the failure mode that records
-- nothing and raises no error.
local function FormatParams(list)
    if type(list) ~= "table" then return "" end
    local parts = {}
    for _, p in ipairs(list) do
        if type(p) == "table" then
            local name = tostring(p.Name or "?")
            if p.Nilable then name = "optional " .. name end
            if p.Type then name = name .. ":" .. tostring(p.Type) end
            if p.Default ~= nil then name = name .. "=" .. tostring(p.Default) end
            parts[#parts + 1] = name
        end
    end
    return table.concat(parts, ", ")
end

local function SortedKeys(t)
    local keys = {}
    for k in pairs(t) do
        if type(k) == "string" then keys[#keys + 1] = k end
    end
    table.sort(keys)
    return keys
end

------------------------------------------------------------
-- Pass 1: Blizzard_APIDocumentation
------------------------------------------------------------

-- The documentation is load-on-demand, and APIDocumentation_LoadUI is the
-- supported way in. LoadAddOn("Blizzard_APIDocumentation") does NOT do it on
-- this client: the first run reported 0 documented functions while /api worked
-- perfectly, because /api calls the stub and we did not.
local function LoadDocs()
    if type(APIDocumentation_LoadUI) == "function" then
        pcall(APIDocumentation_LoadUI)
    end
    if type(APIDocumentation) ~= "table" then
        local loader = (C_AddOns and C_AddOns.LoadAddOn) or LoadAddOn
        if loader then
            pcall(loader, "Blizzard_APIDocumentation")
            pcall(loader, "Blizzard_APIDocumentationGenerated")
        end
    end
    return APIDocumentation
end

local function DumpDocumented(out)
    local doc = LoadDocs()
    if type(doc) ~= "table" or type(doc.systems) ~= "table" then
        Out("|cffff5555APIDocumentation unavailable|r - /api may still work, the table does not")
        return 0, 0, 0
    end

    local nFunc, nEvent, nTable = 0, 0, 0

    for _, sys in ipairs(doc.systems) do
        local ns = sys.Namespace
        local sysName = sys.Name or ns or "?"
        local prefix = ns and (ns .. ".") or ""

        for _, fn in ipairs(sys.Functions or {}) do
            local line = prefix .. tostring(fn.Name)
                .. "(" .. FormatParams(fn.Arguments) .. ")"
            local rets = FormatParams(fn.Returns)
            if rets ~= "" then line = line .. " -> " .. rets end
            out.documented[#out.documented + 1] = line
            nFunc = nFunc + 1
        end

        for _, ev in ipairs(sys.Events or {}) do
            -- LiteralName is the RegisterEvent string; Name is the Event.X.Y
            -- form. Keep both: one is what you register, the other is what the
            -- documentation calls it.
            local line = tostring(ev.LiteralName or ev.Name)
            if ev.Name and ev.LiteralName then
                line = line .. "  (Event." .. sysName .. "." .. tostring(ev.Name) .. ")"
            end
            local payload = FormatParams(ev.Payload)
            if payload ~= "" then line = line .. " -> " .. payload end
            out.events[#out.events + 1] = line
            nEvent = nEvent + 1
        end

        for _, tbl in ipairs(sys.Tables or {}) do
            local kind = tostring(tbl.Type or "Table")
            local name = tostring(tbl.Name)
            if tbl.Values then
                -- Enumerations: the values are the point. Enum.BagIndex moving
                -- is exactly the kind of thing this catches.
                local vals = {}
                for _, v in ipairs(tbl.Values) do
                    vals[#vals + 1] = tostring(v.Name) .. "=" .. tostring(v.EnumValue)
                end
                out.tables[#out.tables + 1] =
                    kind .. " " .. name .. " { " .. table.concat(vals, ", ") .. " }"
            elseif tbl.Fields then
                out.tables[#out.tables + 1] =
                    kind .. " " .. name .. " { " .. FormatParams(tbl.Fields) .. " }"
            else
                out.tables[#out.tables + 1] = kind .. " " .. name
            end
            nTable = nTable + 1
        end
    end

    table.sort(out.documented)
    table.sort(out.events)
    table.sort(out.tables)
    return nFunc, nEvent, nTable
end

------------------------------------------------------------
-- Passes 2 and 3: what is actually callable
--
-- The documentation covers what Blizzard documents. GetCVar, SetCVar,
-- CreateFrame and most of the legacy surface are not in it, and are exactly
-- what a port needs to check.
------------------------------------------------------------

local function DumpRuntime(out)
    local nGlobal, nNs, nNsFunc = 0, 0, 0

    for _, name in ipairs(SortedKeys(_G)) do
        local ok, v = pcall(function() return _G[name] end)
        if ok then
            if type(v) == "function" then
                out.globals[#out.globals + 1] = name
                nGlobal = nGlobal + 1
            elseif type(v) == "table" and name:find("^C_") then
                nNs = nNs + 1
                local found = 0
                for _, k in ipairs(SortedKeys(v)) do
                    local ok2, m = pcall(function() return v[k] end)
                    if ok2 and type(m) == "function" then
                        found = found + 1
                        out.namespaces[#out.namespaces + 1] = name .. "." .. k
                        nNsFunc = nNsFunc + 1
                    end
                end
                if found == 0 then
                    out.namespaces[#out.namespaces + 1] = name .. "  (no function members)"
                end
            end
        end
    end

    return nGlobal, nNs, nNsFunc
end

------------------------------------------------------------
-- Pass 4: widget methods
--
-- The pass that matters most for porting UI code, and the one no _G walk can
-- give you. TryOn is a DressUpModel method; probing type(TryOn) reports nil on
-- a perfectly healthy client, which is how the Roster port came to be deferred
-- on a blocker that did not exist (#15).
------------------------------------------------------------

-- NOT in this list, on purpose:
--   Minimap - a singleton. CreateFrame("Minimap") raises "Unable to create
--             frame type: Minimap" as a Lua WARNING, which surfaces to the
--             player in an error window even though pcall catches the error.
--             Its methods are readable off the existing Minimap object below
--             instead, which costs nothing and breaks nothing.
local WIDGET_TYPES = {
    "Frame", "Button", "CheckButton", "EditBox", "Slider", "StatusBar",
    "ScrollFrame", "GameTooltip", "MessageFrame", "SimpleHTML", "ColorSelect",
    "Cooldown", "Model", "PlayerModel", "DressUpModel",
    "CinematicModel", "ModelScene", "Browser", "MovieFrame", "OffScreenFrame",
    "ScrollingMessageFrame", "TabardModel", "UnitPositionFrame",
}

-- Existing objects whose methods we read rather than create. Anything that is
-- a singleton, or that has side effects on creation, belongs here.
local WIDGET_SINGLETONS = {
    Minimap = Minimap,
    UIParent = UIParent,
}

-- Widget methods hang off the metatable chain, not the object, so walk
-- __index until it runs out.
local function MethodNames(widget)
    local seen, names = {}, {}
    local mt = getmetatable(widget)
    local idx = mt and mt.__index
    while type(idx) == "table" do
        for _, k in ipairs(SortedKeys(idx)) do
            if not seen[k] then
                local ok, m = pcall(function() return idx[k] end)
                if ok and type(m) == "function" then
                    seen[k] = true
                    names[#names + 1] = k
                end
            end
        end
        local nextMt = getmetatable(idx)
        idx = nextMt and nextMt.__index
    end
    table.sort(names)
    return names
end

local function DumpWidgets(out)
    local nTypes, nMethods = 0, 0

    -- Everything is parented to a hidden frame and then hidden again itself,
    -- so nothing this pass creates can take keyboard focus, draw, or react to
    -- input. An EditBox defaults to autoFocus, which is reason enough.
    local holder = CreateFrame("Frame")
    holder:Hide()

    local function Record(label, widget)
        nTypes = nTypes + 1
        local names = MethodNames(widget)
        for _, k in ipairs(names) do
            out.widgets[#out.widgets + 1] = label .. ":" .. k
            nMethods = nMethods + 1
        end
        if #names == 0 then
            out.widgets[#out.widgets + 1] = label .. "  (no methods found)"
        end
    end

    for _, widgetType in ipairs(WIDGET_TYPES) do
        local ok, widget = pcall(CreateFrame, widgetType, nil, holder)
        if not ok or not widget then
            out.widgets[#out.widgets + 1] = widgetType .. "  (CANNOT CREATE)"
        else
            if widget.Hide then pcall(widget.Hide, widget) end
            if widget.ClearFocus then pcall(widget.ClearFocus, widget) end
            Record(widgetType, widget)
        end
    end

    for _, label in ipairs(SortedKeys(WIDGET_SINGLETONS)) do
        local obj = WIDGET_SINGLETONS[label]
        if type(obj) == "table" then
            Record(label, obj)
        else
            out.widgets[#out.widgets + 1] = label .. "  (not present)"
        end
    end

    return nTypes, nMethods
end

------------------------------------------------------------
-- Driver
------------------------------------------------------------

local function BuildDump()
    local out = {
        documented = {}, events = {}, tables = {},
        globals = {}, namespaces = {}, widgets = {},
    }

    local version, build, buildDate, tocVersion = GetBuildInfo()
    out.client = {
        version    = version,
        build      = build,
        buildDate  = buildDate,
        tocVersion = tocVersion,
        projectID  = WOW_PROJECT_ID,
        generated  = date("%Y-%m-%d %H:%M:%S"),
    }

    local nFunc, nEvent, nTable = DumpDocumented(out)
    local nGlobal, nNs, nNsFunc = DumpRuntime(out)
    local nWidgetTypes, nWidgetMethods = DumpWidgets(out)

    out.counts = {
        documentedFunctions = nFunc,
        documentedEvents    = nEvent,
        documentedTables    = nTable,
        globals             = nGlobal,
        namespaces          = nNs,
        namespaceFunctions  = nNsFunc,
        widgetTypes         = nWidgetTypes,
        widgetMethods       = nWidgetMethods,
    }

    ForeverAPIDumpDB = out

    Out(("build %s.%s (toc %s)"):format(tostring(version), tostring(build), tostring(tocVersion)))
    Out(("documented: %d functions, %d events, %d tables"):format(nFunc, nEvent, nTable))
    Out(("runtime:    %d globals, %d C_ namespaces, %d namespace functions")
        :format(nGlobal, nNs, nNsFunc))
    Out(("widgets:    %d types, %d methods"):format(nWidgetTypes, nWidgetMethods))
    Out("|cff55ff55Now /reload|r to flush it to SavedVariables.")
end

SLASH_FOREVERAPIDUMP1 = "/apidump"
SLASH_FOREVERAPIDUMP2 = "/fadump"
SlashCmdList["FOREVERAPIDUMP"] = function()
    BuildDump()
end

-- Deliberately NOT run at login. The widget pass creates two dozen frames and
-- walks every global; that is fine when asked for and rude as a side effect of
-- logging in. Run /apidump, then /reload to flush the file.
