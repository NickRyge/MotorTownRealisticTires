-- Settings per car model, shared by the traction control and the active diff. Each car model is its own Blueprint
-- class (Neo_C, Tuscan_C, ...), so the class name is the key: every car of a model shares one setting.
-- File: WheelDebugger\car_settings.txt, one line per car: "Class key=value key=value ...", rewritten on every change.
-- The older tc_cars.txt ("Class tc cut saved") is read once if car_settings.txt doesn't exist yet.

local M = {}

local dir = require("paths").modDir
local FILE = dir .. "car_settings.txt"
local OLD_FILE = dir .. "tc_cars.txt"
local cars = nil

local function load()
    cars = {}
    local f = io.open(FILE, "r")
    if f then
        for line in f:lines() do
            local k, rest = line:match("^(%S+)%s+(.*)$")
            if k then
                local t = {}
                for key, v in rest:gmatch("(%w+)=(%-?[%d%.]+)") do t[key] = tonumber(v) end
                cars[k] = t
            end
        end
        f:close()
        return
    end
    f = io.open(OLD_FILE, "r")
    if not f then return end
    for line in f:lines() do
        local k, a, b, c = line:match("^(%S+)%s+(%d+)%s+(%d+)%s+(%d+)")
        if k then cars[k] = { tc = tonumber(a), cut = tonumber(b), saved = tonumber(c) } end
    end
    f:close()
end

local function save(log)
    local keys = {}
    for k in pairs(cars) do keys[#keys + 1] = k end
    table.sort(keys)
    local f, err = io.open(FILE, "w")
    if not f then log("can't save %s: %s", FILE, tostring(err)); return end
    for _, k in ipairs(keys) do
        local parts = {}
        for key, v in pairs(cars[k]) do parts[#parts + 1] = string.format("%s=%s", key, tostring(v)) end
        table.sort(parts)
        f:write(k .. " " .. table.concat(parts, " ") .. "\n")
    end
    f:close()
end

-- The stored values for a car (nil when the car isn't in the file). Read only: change them with put().
function M.get(car)
    if not cars then load() end
    return cars[car]
end

-- Merge `values` into the car's entry and write the file.
function M.put(car, values, log)
    if not car then return end
    if not cars then load() end
    local t = cars[car] or {}
    for k, v in pairs(values) do t[k] = v end
    cars[car] = t
    local ok, err = pcall(save, log)
    if not ok then log("car settings save failed: %s", tostring(err)) end
end

return M
