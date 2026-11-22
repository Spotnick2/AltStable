------------------------------------------------------------
-- checkouts.lua - where a sibling checkout (a library, ForeverProbe) is (#477)
--
-- The tests load the embedded libraries from their own checkouts, not from
-- Libs/ (the packager fills that). In order:
--   1. the environment variable (LIBGLASS, ...), as before;
--   2. the folder next to this repo (../LibGlass), as before;
--   3. the folder next to the MAIN checkout, for a git worktree kept elsewhere
--      (a scratch folder has no ../LibGlass): git rev-parse --git-common-dir
--      names the main checkout's .git.
-- None found: the neighbour path, so the loader's own "not found" error
-- names it as before.
--
--   dofile("tests/checkouts.lua")
--   local root = CheckoutRoot("LIBGLASS", "LibGlass", "LibGlass-1.0.xml")
--
-- `marker` is a file the checkout must have (a directory can't be opened).
------------------------------------------------------------

local function Clean(path) return (path:gsub("\\", "/"):gsub("/$", "")) end

local function Has(root, marker)
    local f = io.open(root .. "/" .. marker, "rb")
    if f then f:close() return true end
    return false
end

-- The folder holding the main checkout, or nil (no git, not a repository).
local mainParent
local function MainParent()
    if mainParent ~= nil then return mainParent or nil end
    mainParent = false
    local null = package.config:sub(1, 1) == "\\" and "nul" or "/dev/null"
    local ok, p = pcall(io.popen, "git rev-parse --path-format=absolute --git-common-dir 2>" .. null)
    if ok and p then
        local dir = p:read("*l")
        p:close()
        if dir and dir ~= "" then
            -- <main>/.git -> <main> -> its parent.
            local main = Clean(dir):match("^(.*)/[^/]+$")
            mainParent = main and main:match("^(.*)/[^/]+$") or false
        end
    end
    return mainParent or nil
end

function CheckoutRoot(envName, folder, marker)
    local env = os.getenv(envName)
    if env and env ~= "" then return Clean(env) end
    local beside = "../" .. folder
    if Has(beside, marker) then return beside end
    local parent = MainParent()
    if parent and Has(parent .. "/" .. folder, marker) then return parent .. "/" .. folder end
    return beside
end
