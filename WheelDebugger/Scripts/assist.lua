-- Steering-assist target: the game aims the assist at 20° slip angle (cvar mh.steeringAssistOptimalSlipAngle and
-- each vehicle's OptimalSlipAngleDegree), tuned for the stock ~45° tire peak. With the step-2 tires (~8° peak)
-- we aim it at TARGET instead. Ctrl+F7 toggles between TARGET and the stock values; re-applied on vehicle change.
-- Runtime only: nothing is saved; restarting without the mod restores stock behaviour.

local M = {}

local TARGET = 9.0
local CVAR = "mh.steeringAssistOptimalSlipAngle"

local enabled = false   -- off by default: for wheel users (assist is for keyboard / gamepad)
-- Fixed stock value (a script reload would otherwise read back the modded 9 as "stock").
local stockCvar = 20.0
local vehStock = {}      -- vehicle address -> original OptimalSlipAngleDegree
local lastVeh = nil

local function valid(o) return o ~= nil and o:IsValid() end
local function ksl() return StaticFindObject("/Script/Engine.Default__KismetSystemLibrary") end

local function setCvar(pc, value)
    ksl():ExecuteConsoleCommand(pc, string.format("%s %g", CVAR, value), pc)
    return ksl():GetConsoleVariableFloatValue(CVAR)
end

local function applyVehicle(veh)
    if not valid(veh) then return end
    local addr = veh:GetAddress()
    if vehStock[addr] == nil then
        local v = veh.OptimalSlipAngleDegree
        -- Already at TARGET means a previous script instance set it; the stock value is 20 on 160/166 vehicles.
        vehStock[addr] = (math.abs(v - TARGET) < 1e-3) and stockCvar or v
    end
    veh.OptimalSlipAngleDegree = enabled and TARGET or vehStock[addr]
end

function M.apply(pc, veh, log)
    if not valid(pc) then return end
    local now = setCvar(pc, enabled and TARGET or stockCvar)
    applyVehicle(veh)
    lastVeh = valid(veh) and veh:GetAddress() or nil
    if log then
        log("steering assist target %s: cvar now %.1f, vehicle %s", enabled and "MOD" or "stock", now,
            valid(veh) and tostring(veh.OptimalSlipAngleDegree) or "-")
    end
end

-- Called every tick from the shared loop or the watcher: re-apply when the player switches vehicles.
function M.check(pc, veh, log)
    local addr = valid(veh) and veh:GetAddress() or nil
    if addr ~= lastVeh then M.apply(pc, veh, log) end
end

function M.toggle(pc, veh, log)
    enabled = not enabled
    M.apply(pc, veh, log)
end

function M.label()
    return enabled and string.format("assist target %g° (Ctrl+F7: stock)", TARGET)
        or string.format("assist target stock %g° (Ctrl+F7: %g°)", stockCvar or 20, TARGET)
end

return M
