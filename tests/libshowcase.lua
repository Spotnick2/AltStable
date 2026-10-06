------------------------------------------------------------
-- libshowcase.lua - load the camera showcase the way the client does
--
-- The TOC loads Libs\LibShowcase-1.0\LibShowcase-1.0.xml right after
-- LibGlass's. Libs/LibShowcase-1.0 is gitignored (the packager fills it), so
-- the tests read the library from a checkout: $LIBSHOWCASE, else
-- ../LibShowcase - the same rule as tests/libglass.lua. No checkout, or a file
-- its XML lists missing, fails the run LOUDLY: a silently skipped library
-- would test nothing.
--
--   dofile("tests/libshowcase.lua"); LoadShowcase()
--
-- runs every <Script file> of the XML, in order, with the addon's name -
-- after LoadGlass, before SheetUI.lua.
------------------------------------------------------------

function LibShowcaseRoot()
    local root = (os.getenv("LIBSHOWCASE") or "../LibShowcase"):gsub("\\", "/"):gsub("/$", "")
    local f = io.open(root .. "/LibShowcase-1.0.xml", "rb")
    if not f then
        error("LibShowcase checkout not found at " .. root .. " (no LibShowcase-1.0.xml): clone "
              .. "github.com/Spotnick2/LibShowcase there or set LIBSHOWCASE", 0)
    end
    f:close()
    return root
end

-- The Lua files the library's XML loads, as paths, in order.
function LibShowcaseScripts()
    local root = LibShowcaseRoot()
    local f = assert(io.open(root .. "/LibShowcase-1.0.xml", "rb"))
    local xml = f:read("*a"):gsub("<!%-%-.-%-%->", "")   -- listed in a comment is not loaded
    f:close()
    local files = {}
    for file in xml:gmatch('<Script%s+file="([^"]+)"') do
        local path = root .. "/" .. file:gsub("\\", "/")
        local src = io.open(path, "rb")
        if not src then error("LibShowcase checkout at " .. root .. " is missing " .. file, 0) end
        src:close()
        files[#files + 1] = path
    end
    if #files == 0 then error("LibShowcase-1.0.xml at " .. root .. " lists no Script files", 0) end
    return files
end

function LoadShowcase(addon)
    addon = addon or "AltStable"
    local ns = {}
    for _, path in ipairs(LibShowcaseScripts()) do
        assert(loadfile(path))(addon, ns)
    end
    return LibStub("LibShowcase-1.0")
end
