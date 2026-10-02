-- Wheel telemetry overlay and recorder, driven by one 20 Hz loop (see telemetry.lua for the data source).
-- Per wheel: lateral / longitudinal grip G (-force / load) with maxima, load, slip angle, slip ratio.
-- Car: speed, lateral / longitudinal G (sum of forces / sum of loads) with maxima, steering.

local telemetry = require("telemetry")
local peak = require("peak")

local M = {}

local HOST_CLASS = "/Script/MotorTown.TireForceGraphWidget" -- concrete UserWidget subclass we can instantiate
local TICK_MS = 50        -- sampling / recording rate (20 Hz)
local UI_EVERY = 2        -- overlay refresh every 2nd tick (10 Hz)

local function valid(o) return o ~= nil and o:IsValid() end

local ui = nil
local maxes, carMax = {}, { lat = 0, accel = 0, brake = 0, corner = 0 }
local loopRunning, tick = false, 0
-- Car weight (N) as a slow average of the total wheel load (~5 s at 20 Hz), so bumps don't inflate car G.
local weightN = nil
local WEIGHT_ALPHA = 0.01

local lastVehicle = nil

function M.resetMax()
    peak.reset()
    maxes = {}
    carMax = { lat = 0, accel = 0, brake = 0, corner = 0 }
end

local function newText(tree, canvas, x, y, w, h, size)
    local tb = StaticConstructObject(StaticFindObject("/Script/UMG.TextBlock"), tree)
    local border = StaticConstructObject(StaticFindObject("/Script/UMG.Border"), tree)
    pcall(function() border:SetBrushColor({ R = 0.0, G = 0.0, B = 0.0, A = 0.6 }) end)
    pcall(function() border:SetPadding({ Left = 10, Top = 6, Right = 10, Bottom = 6 }) end)
    border:SetContent(tb)
    local slot = canvas:AddChildToCanvas(border)
    slot:SetPosition({ X = x, Y = y })
    slot:SetSize({ X = w, Y = h })
    pcall(function()
        local f = tb.Font
        f.Size = size
        tb:SetFont(f)
    end)
    return tb
end

-- Wheels in a 2x2 grid as seen from above, the car panel between them.
local L = { x = 30, y = 140, cw = 250, ch = 150, gap = 10, midW = 230 }

local function build(pc)
    local w = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(pc, StaticFindObject(HOST_CLASS), pc)
    local tree = w.WidgetTree
    local canvas = StaticConstructObject(StaticFindObject("/Script/UMG.CanvasPanel"), tree)
    tree.RootWidget = canvas
    local x2 = L.x + L.cw + L.gap + L.midW + L.gap
    local blocks = {
        FL = newText(tree, canvas, L.x, L.y, L.cw, L.ch, 12),
        FR = newText(tree, canvas, x2, L.y, L.cw, L.ch, 12),
        RL = newText(tree, canvas, L.x, L.y + L.ch + L.gap, L.cw, L.ch, 12),
        RR = newText(tree, canvas, x2, L.y + L.ch + L.gap, L.cw, L.ch, 12),
        C = newText(tree, canvas, L.x + L.cw + L.gap, L.y, L.midW, 2 * L.ch + L.gap, 12),
    }
    w:AddToViewport(100)
    return { widget = w, blocks = blocks }
end

local function fmtG(v) return string.format("%+5.2f", v) end

-- Maxima are tracked every tick (20 Hz) even when the text only refreshes at 10 Hz.
local function track(s)
    local sumFx, sumFy, sumLoad = 0, 0, 0
    local per = {}
    for _, w in ipairs(s.wheels) do
        sumFx, sumFy, sumLoad = sumFx - w.fx, sumFy - w.fy, sumLoad + w.load
        local gLong, gLat = 0, 0
        if w.load > 50 then gLong, gLat = -w.fx / w.load, -w.fy / w.load end
        local m = maxes[w.slot] or { lat = 0, accel = 0, brake = 0 }
        if math.abs(gLat) > m.lat then m.lat = math.abs(gLat) end
        if gLong > m.accel then m.accel = gLong end
        if gLong < m.brake then m.brake = gLong end
        maxes[w.slot] = m
        per[w.slot] = { w = w, gLat = gLat, gLong = gLong }
    end
    if sumLoad > 50 then
        weightN = weightN and (weightN + (sumLoad - weightN) * WEIGHT_ALPHA) or sumLoad
    end
    local cLat, cLong = 0, 0
    if weightN and weightN > 50 then cLat, cLong = sumFy / weightN, sumFx / weightN end
    if math.abs(cLat) > carMax.lat then carMax.lat = math.abs(cLat) end
    if cLong > carMax.accel then carMax.accel = cLong end
    if cLong < carMax.brake then carMax.brake = cLong end
    -- Cornering G from motion alone: measured sideways acceleration of the body (telemetry.kinematics).
    local corner = s.accLat
    if math.abs(corner) > carMax.corner then carMax.corner = math.abs(corner) end
    return per, cLat, cLong, corner
end

local function render(s, per, cLat, cLong, corner)
    if #s.wheels == 0 then
        ui.blocks.C:SetText(FText("No wheels.\nGet in a vehicle."))
        return
    end
    for slot, tb in pairs(ui.blocks) do
        local p = per[slot]
        if p then
            local w, m = p.w, maxes[slot]
            local sa, sr = 0, 0
            if math.abs(w.vx) > 1e-3 then
                sa = math.deg(math.atan(w.vy, math.abs(w.vx)))
                sr = w.surf / w.vx - 1
            end
            tb:SetText(FText(string.format(
                "%s   load %5.0f N%s\nLat   %s g   max %4.2f\nLong  %s g   max +%4.2f / %4.2f\nSlip angle %+5.1f°\nSlip ratio %+5.2f",
                slot, w.load, w.load <= 50 and "  (air)" or "",
                fmtG(p.gLat), m.lat, fmtG(p.gLong), m.accel, m.brake, sa, sr)))
        end
    end
    -- Turn radius from v^2 / a_lat; shown only when actually turning.
    local radius = "-"
    if math.abs(corner) > 0.05 and s.speedMs > 2 then
        radius = string.format("%.0f m %s", s.speedMs ^ 2 / math.abs(corner * 9.81), corner > 0 and "R" or "L")
    end
    ui.blocks.C:SetText(FText(string.format(
        "CAR  %3.0f km/h\n\nCornering %s g\n  max %4.2f\n  radius %s\nTire lat  %s g\n  max %4.2f\nLong      %s g\n  max +%4.2f / %4.2f\n\nSteer %+5.1f°\n(input %+4.2f × %.0f°)\n%s\nF9 reset max",
        s.speed, fmtG(corner), carMax.corner, radius, fmtG(cLat), carMax.lat, fmtG(cLong), carMax.accel, carMax.brake,
        s.steer * s.maxSteer, s.steer, s.maxSteer, M.status()) .. "\n\nPeak slip angle\n" .. peak.lines() .. "\n" .. require("assist").label() .. "\n" .. require("brakes").label() .. "  " .. require("tirecvars").label() .. "  " .. require("ffb").label() .. "\n" .. require("tc").label()))
end

local visual = require("visual")
local steerprobe = require("steerprobe")
local brakepanel = require("brakepanel")

-- What's running, shown on screen: REC (telemetry recording) / PROBE (steering probe).
function M.status()
    local parts = {}
    if telemetry.recording() then parts[#parts + 1] = "● REC" end
    if steerprobe.active() then parts[#parts + 1] = "● PROBE" end
    return table.concat(parts, " ")
end
local ownerPC = nil

local function ensureLoop(getVehicle, log)
    if loopRunning then return end
    loopRunning = true
    require("loop").every(TICK_MS, function()
        if not ui and not visual.wanted() and not brakepanel.wanted() and not steerprobe.active() and not telemetry.recording() then
            loopRunning = false; return true
        end
        do
            local ok, err = pcall(function()
                local veh = getVehicle()
                local s = telemetry.sample(veh)
                if s.vehicleKey ~= lastVehicle then lastVehicle = s.vehicleKey; M.resetMax() end
                peak.add(s)
                local per, cLat, cLong, corner = track(s)
                telemetry.record(s, log)
                tick = tick + 1
                if ui and tick % UI_EVERY == 0 then render(s, per, cLat, cLong, corner) end
                if visual.wanted() then visual.update(ownerPC, s, M.status(), tick % 20 == 0 and peak.lines() or nil) end
                steerprobe.record(veh, telemetry.currentWheels(), s, log)
                brakepanel.add(s)
                if brakepanel.wanted() and tick % 4 == 0 then brakepanel.update(ownerPC, s, veh) end
            end)
            if not ok then
                log("telemetry tick failed, stopping: %s", tostring(err))
                telemetry.stopRecording(log)
                if ui then pcall(function() ui.widget:RemoveFromParent() end); ui = nil end
                visual.setWanted(false)
                brakepanel.setWanted(false)
            end
        end
        return false
    end)
end

-- Removes overlay host widgets on screen except the ones in `keep`, including orphans left by a script
-- reload (a reload forgets its widgets, but they stay in the viewport, frozen). Nothing else in the game uses this class.
function M.clearAll(log, keep)
    local keepAddr = {}
    for _, k in ipairs(keep or {}) do if valid(k) then keepAddr[k:GetAddress()] = true end end
    local n = 0
    for _, w in ipairs(FindAllOf("TireForceGraphWidget") or {}) do
        if valid(w) and not keepAddr[w:GetAddress()] then
            local ok = pcall(function() w:RemoveFromParent() end)
            if ok then n = n + 1 end
        end
    end
    if n > 0 and log then log("removed %d overlay widget(s)", n) end
end

local function others(exceptText)
    local k = {}
    if not exceptText and ui then k[#k + 1] = ui.widget end
    if visual.widget() then k[#k + 1] = visual.widget() end
    if brakepanel.widget() then k[#k + 1] = brakepanel.widget() end
    return k
end

function M.toggle(pc, getVehicle, log)
    telemetry.register()
    ownerPC = pc
    if ui then
        pcall(function() ui.widget:RemoveFromParent() end)
        ui = nil
        log("overlay hidden")
        return
    end
    M.clearAll(log, others(true))
    ui = build(pc)
    log("overlay shown")
    ensureLoop(getVehicle, log)
end

function M.toggleVisual(pc, getVehicle, log)
    telemetry.register()
    ownerPC = pc
    if visual.wanted() then
        visual.setWanted(false)
        log("wheel view hidden")
        return
    end
    M.clearAll(log, others(false))
    visual.setWanted(true)
    log("wheel view shown")
    ensureLoop(getVehicle, log)
end

function M.toggleBrakes(pc, getVehicle, log)
    telemetry.register()
    ownerPC = pc
    if brakepanel.wanted() then brakepanel.setWanted(false); log("brake panel hidden"); return end
    M.clearAll(log, others(false))
    brakepanel.setWanted(true)
    log("brake panel shown")
    ensureLoop(getVehicle, log)
end

function M.steerProbe(getVehicle, log)
    telemetry.register()
    steerprobe.start(log)
    ensureLoop(getVehicle, log)
end

function M.record(getVehicle, log)
    telemetry.register()
    if telemetry.recording() then telemetry.stopRecording(log); return end
    telemetry.startRecording(30, 1000 / TICK_MS, log)
    ensureLoop(getVehicle, log)
end

return M
