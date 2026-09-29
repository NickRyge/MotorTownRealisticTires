-- Brake tweaks (runtime only; stock values are hardcoded because a script reload would otherwise read back
-- modded values and stack them).
--   Ctrl+F6  brake torque: mh.brakeTorqueMultiplayer (sic) x TORQUE_FACTOR, so stock brakes reach the tire limit
--            (stock Neo: 0.59 g at 2-3 % slip; tires peak at ~7 % slip / mu 1.05-1.10). Stock 1.1111.
--   Ctrl+F5  ABS preset: target slip + pump / release speed + latency. Target 10 % sits just above the measured
--            car peak (6.5-8.5 %). Faster pulses = lower latency, release stronger than pump (less overshoot,
--            which is what made the upgraded Neo bounce).

local M = {}

local TORQUE_FACTOR = 1.8
local CV = {
    torque = "mh.brakeTorqueMultiplayer",
    slip = "mh.vehicleABSMaxSlipRatio",
    pump = "mh.vehicleABSPumpSpeed",
    release = "mh.vehicleABSReleaseSpeed",
    latency = "mh.vehicleABSLatency",
}
local STOCK = { torque = 1.1111111, slip = 0.20, pump = 20, release = 10, latency = 0.0625 }

-- "fast" released harder than it reapplied: at full pedal the Neo's front wheels spent much of the stop
-- partly released (0.61 g at 100 % pedal vs 0.75-0.83 g at ~50 % pedal, tel_20260927_205623) and the cycling
-- shook the FFB wheel. "smooth"/"firm" release more gently than they reapply, target 12 % (flat part of curve).
local ABS_PRESETS = {
    { name = "stock", slip = 0.20, pump = 20, release = 10, latency = 0.0625 },
    { name = "fast", slip = 0.10, pump = 30, release = 40, latency = 0.03 },
    { name = "smooth", slip = 0.12, pump = 25, release = 15, latency = 0.03 },
    { name = "firm", slip = 0.12, pump = 35, release = 20, latency = 0.02 },
}

local torqueOn = true
local absIndex = 3          -- default: "smooth"

local function valid(o) return o ~= nil and o:IsValid() end
local function ksl() return StaticFindObject("/Script/Engine.Default__KismetSystemLibrary") end
local function get(name) return ksl():GetConsoleVariableFloatValue(name) end
local function set(pc, name, v) ksl():ExecuteConsoleCommand(pc, string.format("%s %g", name, v), pc) end

function M.apply(pc, log)
    if not valid(pc) then return false end
    local p = ABS_PRESETS[absIndex]
    set(pc, CV.torque, torqueOn and STOCK.torque * TORQUE_FACTOR or STOCK.torque)
    set(pc, CV.slip, p.slip)
    set(pc, CV.pump, p.pump)
    set(pc, CV.release, p.release)
    set(pc, CV.latency, p.latency)
    if log then
        log("brakes: torque %.2f (%s), ABS '%s' slip %.2f pump %g release %g latency %.3f", get(CV.torque),
            torqueOn and "MOD" or "stock", p.name, get(CV.slip), get(CV.pump), get(CV.release), get(CV.latency))
    end
    return true
end

local applied = false
function M.ensure(pc, log) if not applied then applied = M.apply(pc, log) end end

function M.toggle(pc, log)          -- Ctrl+F6
    torqueOn = not torqueOn
    M.apply(pc, log)
end

function M.cycleABS(pc, log)        -- Ctrl+F5
    absIndex = absIndex % #ABS_PRESETS + 1
    M.apply(pc, log)
end

function M.label()
    local p = ABS_PRESETS[absIndex]
    return string.format("brakes %s (Ctrl+F6)  ABS %s %.0f%% (Ctrl+F5)",
        torqueOn and string.format("x%.1f", TORQUE_FACTOR) or "stock", p.name, p.slip * 100)
end

return M
