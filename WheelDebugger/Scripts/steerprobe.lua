-- One-off experiment to find where the game stores each wheel's actual steering angle.
-- Records raw floats of MHWheelComponent (0x580..0x9FC, known doubles excluded) for the steering wheels
-- and one rear wheel, plus the yaw of each wheel's child components, to output	elemetrysteer_*.csv (paths.lua).
-- Only plain float reads of the player's own wheels.

local M = {}

local WHEEL_CLASS = "/Script/MotorTown.MHWheelComponent"
local FROM, TO = 0x580, 0x9FC
local SKIP = { [0x6B8] = 1, [0x6BC] = 1, [0x6C0] = 1, [0x6C4] = 1, [0x6C8] = 1, [0x6CC] = 1, [0x6D0] = 1, [0x6D4] = 1,
    [0x6D8] = 1, [0x6DC] = 1, [0x6E0] = 1, [0x6E4] = 1, [0x708] = 1, [0x70C] = 1, [0x710] = 1, [0x714] = 1, [0x900] = 1, [0x904] = 1 }
local OUT_DIR = require("paths").dir("telemetry")

local cols = nil
local function register()
    if cols then return end
    cols = {}
    for off = FROM, TO, 4 do
        if not SKIP[off] then
            local name = string.format("sp_%X", off)
            pcall(RegisterCustomProperty, { Name = name, Type = PropertyTypes.FloatProperty, BelongsToClass = WHEEL_CLASS, OffsetInternal = off })
            cols[#cols + 1] = name
        end
    end
end

local rec = nil
function M.active() return rec ~= nil end

function M.start(log)
    if rec then log("steer probe already running"); return end
    register()
    local path = OUT_DIR .. os.date("steer_%Y%m%d_%H%M%S.csv")
    local f = io.open(path, "w")
    if not f then log("can't write %s", path); return end
    f:write("n,slot,can_steer,speed_kph,steer,brake,throttle,rel_yaw,child_yaw1,child_yaw2," .. table.concat(cols, ",") .. "\n")
    rec = { f = f, n = 0, max = 400, path = path }
    log("field probe (steering / brake / throttle): 20 s to %s", path)
end

-- Called from the shared loop with the vehicle and the telemetry sample's wheel components.
function M.record(veh, wheels, s, log)
    if not rec then return end
    rec.n = rec.n + 1
    for i, w in ipairs(wheels) do
        local e = s.wheels[i]
        if e and w:IsValid() then           -- all wheels (brake torque needs every wheel)
            local cy = { 0, 0 }
            pcall(function()
                local kids = w:GetChildrenComponents(false)
                local k = 0
                for _, c in ipairs(kids) do
                    if k >= 2 then break end
                    if type(c) == "userdata" and c.get and not c.IsValid then c = c:get() end
                    if c:IsValid() then k = k + 1; cy[k] = c.RelativeRotation.Yaw end
                end
            end)
            local row = { rec.n, e.slot, e.canSteer and 1 or 0, string.format("%.2f", s.speed), string.format("%.4f", s.steer), string.format("%.3f", s.brake or 0), string.format("%.3f", s.throttle or 0),
                string.format("%.3f", e.relYaw), string.format("%.3f", cy[1]), string.format("%.3f", cy[2]) }
            for _, c in ipairs(cols) do
                local ok, v = pcall(function() return w[c] end)
                row[#row + 1] = ok and string.format("%.6g", v) or "nan"
            end
            rec.f:write(table.concat(row, ",") .. "\n")
        end
    end
    if rec.n >= rec.max then
        rec.f:close()
        log("steer probe finished: %s", rec.path)
        rec = nil
    end
end

return M
