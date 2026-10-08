------------------------------------------------------------
-- libaccountsync.lua - load the own-account sync the way the client does
--
-- The TOC loads Libs\LibAccountSync-1.0\LibAccountSync-1.0.xml right after
-- LibShowcase's. Libs/LibAccountSync-1.0 is gitignored (the packager fills it), so
-- the tests read the library from a checkout: $LIBACCOUNTSYNC, else
-- ../LibAccountSync - the same rule as tests/libglass.lua. No checkout, or a file
-- its XML lists missing, fails the run LOUDLY: a silently skipped library
-- would test nothing.
--
--   dofile("tests/libaccountsync.lua"); LoadAccountSync()
--
-- runs every <Script file> of the XML, in order, with the addon's name -
-- before Core.lua, which builds the instance at load.
------------------------------------------------------------

function LibAccountSyncRoot()
    local root = (os.getenv("LIBACCOUNTSYNC") or "../LibAccountSync"):gsub("\\", "/"):gsub("/$", "")
    local f = io.open(root .. "/LibAccountSync-1.0.xml", "rb")
    if not f then
        error("LibAccountSync checkout not found at " .. root .. " (no LibAccountSync-1.0.xml): clone "
              .. "github.com/Spotnick2/LibAccountSync there or set LIBACCOUNTSYNC", 0)
    end
    f:close()
    return root
end

-- The Lua files the library's XML loads, as paths, in order.
function LibAccountSyncScripts()
    local root = LibAccountSyncRoot()
    local f = assert(io.open(root .. "/LibAccountSync-1.0.xml", "rb"))
    local xml = f:read("*a"):gsub("<!%-%-.-%-%->", "")   -- listed in a comment is not loaded
    f:close()
    local files = {}
    for file in xml:gmatch('<Script%s+file="([^"]+)"') do
        local path = root .. "/" .. file:gsub("\\", "/")
        local src = io.open(path, "rb")
        if not src then error("LibAccountSync checkout at " .. root .. " is missing " .. file, 0) end
        src:close()
        files[#files + 1] = path
    end
    if #files == 0 then error("LibAccountSync-1.0.xml at " .. root .. " lists no Script files", 0) end
    return files
end

function LoadAccountSync(addon)
    addon = addon or "AltStable"
    local ns = {}
    for _, path in ipairs(LibAccountSyncScripts()) do
        assert(loadfile(path))(addon, ns)
    end
    return LibStub("LibAccountSync-1.0")
end
