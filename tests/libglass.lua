------------------------------------------------------------
-- libglass.lua - load the glass material the way the client does (#184)
--
-- The TOC's first line is Libs\LibGlass-1.0\LibGlass-1.0.xml. Libs/LibGlass-1.0
-- is gitignored (the packager fills it), so the tests read the library from a
-- checkout: $LIBGLASS, else ../LibGlass - the same rule as GlassUnitFrames'
-- harness. No checkout, or a file its XML lists missing, fails the run
-- LOUDLY: a silently skipped library would test nothing.
--
--   dofile("tests/libglass.lua"); LoadGlass()
--
-- runs every <Script file> of the XML, in order, with the addon's name, then
-- Glass.lua - after wow_stubs.lua and Compat.lua, as before.
------------------------------------------------------------

LIBGLASS_XML = "Libs\\LibGlass-1.0\\LibGlass-1.0.xml"

function LibGlassRoot()
    local root = (os.getenv("LIBGLASS") or "../LibGlass"):gsub("\\", "/"):gsub("/$", "")
    local f = io.open(root .. "/LibGlass-1.0.xml", "rb")
    if not f then
        error("LibGlass checkout not found at " .. root .. " (no LibGlass-1.0.xml): clone "
              .. "github.com/Spotnick2/LibGlass there or set LIBGLASS", 0)
    end
    f:close()
    return root
end

-- The Lua files the library's XML loads, as paths, in order.
function LibGlassScripts()
    local root = LibGlassRoot()
    local f = assert(io.open(root .. "/LibGlass-1.0.xml", "rb"))
    local xml = f:read("*a"):gsub("<!%-%-.-%-%->", "")   -- listed in a comment is not loaded
    f:close()
    local files = {}
    for file in xml:gmatch('<Script%s+file="([^"]+)"') do
        local path = root .. "/" .. file:gsub("\\", "/")
        local src = io.open(path, "rb")
        if not src then error("LibGlass checkout at " .. root .. " is missing " .. file, 0) end
        src:close()
        files[#files + 1] = path
    end
    if #files == 0 then error("LibGlass-1.0.xml at " .. root .. " lists no Script files", 0) end
    return files
end

function LoadGlass(addon)
    addon = addon or "AltStable"
    local ns = {}
    for _, path in ipairs(LibGlassScripts()) do
        assert(loadfile(path))(addon, ns)
    end
    assert(loadfile("Glass.lua"))(addon, ns)
    return AltStable.Glass
end
