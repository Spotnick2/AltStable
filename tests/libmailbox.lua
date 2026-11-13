------------------------------------------------------------
-- libmailbox.lua - load the mailbox reader the way the client does
--
-- The TOC loads Libs\LibMailbox-1.0\LibMailbox-1.0.xml right after
-- LibAccountSync's. Libs/LibMailbox-1.0 is gitignored (the packager fills it), so
-- the tests read the library from a checkout: $LIBMAILBOX, else
-- ../LibMailbox - the same rule as tests/libglass.lua. No checkout, or a file
-- its XML lists missing, fails the run LOUDLY: a silently skipped library
-- would test nothing.
--
--   dofile("tests/libmailbox.lua"); LoadMailbox()
--
-- runs every <Script file> of the XML, in order, with the addon's name.
-- Core.lua looks the library up when ScanMail runs, so a test that scans mail
-- loads it before that; the others needn't (ScanMail then writes nothing).
------------------------------------------------------------

function LibMailboxRoot()
    local root = (os.getenv("LIBMAILBOX") or "../LibMailbox"):gsub("\\", "/"):gsub("/$", "")
    local f = io.open(root .. "/LibMailbox-1.0.xml", "rb")
    if not f then
        error("LibMailbox checkout not found at " .. root .. " (no LibMailbox-1.0.xml): clone "
              .. "github.com/Spotnick2/LibMailbox there or set LIBMAILBOX", 0)
    end
    f:close()
    return root
end

-- The Lua files the library's XML loads, as paths, in order.
function LibMailboxScripts()
    local root = LibMailboxRoot()
    local f = assert(io.open(root .. "/LibMailbox-1.0.xml", "rb"))
    local xml = f:read("*a"):gsub("<!%-%-.-%-%->", "")   -- listed in a comment is not loaded
    f:close()
    local files = {}
    for file in xml:gmatch('<Script%s+file="([^"]+)"') do
        local path = root .. "/" .. file:gsub("\\", "/")
        local src = io.open(path, "rb")
        if not src then error("LibMailbox checkout at " .. root .. " is missing " .. file, 0) end
        src:close()
        files[#files + 1] = path
    end
    if #files == 0 then error("LibMailbox-1.0.xml at " .. root .. " lists no Script files", 0) end
    return files
end

function LoadMailbox(addon)
    addon = addon or "AltStable"
    local ns = {}
    for _, path in ipairs(LibMailboxScripts()) do
        assert(loadfile(path))(addon, ns)
    end
    return LibStub("LibMailbox-1.0")
end
