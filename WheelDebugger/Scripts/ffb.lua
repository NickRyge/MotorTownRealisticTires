-- Force-feedback presets (Ctrl+F1 cycles; runtime cvars, reversible). The game's FFB already uses the tyre
-- aligning torque (mh.fFBPhysicsAlignTorque = 1). Stock smoothing (0.8) and power-steering assist (0.5, curve 5)
-- blur the detail that tells you where the grip peak is.
--   stock : FFBSmooth 0.8, PowerSteeringMaxAssistTorque 0.5
--   detail: FFBSmooth 0.4, PowerSteeringMaxAssistTorque 0.25   (default)
--   raw   : FFBSmooth 0.1, PowerSteeringMaxAssistTorque 0.0    (most information, also more ABS shake)
-- Stock values are hardcoded (read from the unmodded game 2026-09-27).

local M = {}

local CV_SMOOTH = "mh.FFBSmooth"
local CV_ASSIST = "mh.fFBPowerSteeringMaxAssistTorque"
local PRESETS = {
    { name = "stock", smooth = 0.8, assist = 0.5 },
    { name = "detail", smooth = 0.4, assist = 0.25 },
    { name = "raw", smooth = 0.1, assist = 0.0 },
}
local index = 2

local function valid(o) return o ~= nil and o:IsValid() end
local function ksl() return StaticFindObject("/Script/Engine.Default__KismetSystemLibrary") end
local function set(pc, name, v) ksl():ExecuteConsoleCommand(pc, string.format("%s %g", name, v), pc) end

function M.apply(pc, log)
    if not valid(pc) then return false end
    local p = PRESETS[index]
    set(pc, CV_SMOOTH, p.smooth)
    set(pc, CV_ASSIST, p.assist)
    if log then
        log("FFB '%s': smooth %.2f, power-steering assist %.2f", p.name,
            ksl():GetConsoleVariableFloatValue(CV_SMOOTH), ksl():GetConsoleVariableFloatValue(CV_ASSIST))
    end
    return true
end

local applied = false
function M.ensure(pc, log) if not applied then applied = M.apply(pc, log) end end

function M.cycle(pc, log)
    index = index % #PRESETS + 1
    M.apply(pc, log)
end

function M.label() return string.format("FFB %s (Ctrl+F1)", PRESETS[index].name) end

return M
