-- Output folders for dumps and recordings.
-- Default: WheelDebugger\output\ (next to Scripts\). To write elsewhere, put a folder path on the first line of
-- WheelDebugger\outdir.txt; telemetry then goes to its telemetry\ subfolder.

local M = {}

local src = (debug.getinfo(1, "S").source:gsub("^@", "")):gsub("/", "\\")
local modDir = src:match("^(.*\\)Scripts\\[^\\]+$") or ".\\"

M.modDir = modDir

local function withSlash(p) return p:sub(-1) == "\\" and p or p .. "\\" end

local base = modDir .. "output\\"
local f = io.open(modDir .. "outdir.txt", "r")
if f then
    local line = (f:read("l") or ""):match("^%s*(.-)%s*$")
    f:close()
    if line ~= "" then base = withSlash((line:gsub("/", "\\"))) end
end

local function ensure(dir)
    local probe = io.open(dir .. ".write_test", "w")
    if probe then probe:close(); os.remove(dir .. ".write_test"); return end
    os.execute('mkdir "' .. dir:sub(1, -2) .. '" 2>nul')
end

-- Folder for sub ("" or "telemetry"), with a trailing backslash; created on first use.
function M.dir(sub)
    local d = sub and sub ~= "" and (base .. sub .. "\\") or base
    ensure(d)
    return d
end

return M
