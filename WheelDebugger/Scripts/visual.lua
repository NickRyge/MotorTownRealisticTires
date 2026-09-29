-- Top-down wheel view: every wheel at its real position, rotated by its steering angle,
-- coloured by grip used (combined G / tire static mu), with a force arrow and a small label.
-- Fed by the same samples as the text overlay (telemetry.lua).

local gmeter = require("gmeter")

local M = {}

local HOST_CLASS = "/Script/MotorTown.TireForceGraphWidget" -- concrete UserWidget subclass we can instantiate
local P = { x = 1000, y = 120, w = 360, h = 480, margin = 60 } -- panel on screen (px)
local TIRE_W, TIRE_H = 16, 38                                  -- tire rectangle (px)
local ARROW_PX_PER_G = 55                                      -- arrow length per 1 g of tire force
local ARROW_THICK = 4

local function valid(o) return o ~= nil and o:IsValid() end
local function cls(path) return StaticFindObject(path) end

local vis = nil -- { widget, canvas, tree, n, wheels = { {tire, tireSlot, arrow, arrowSlot, label, labelSlot} }, header, body, bodySlot }

local function newBorder(tree, canvas, r, g, b, a)
    local bd = StaticConstructObject(cls("/Script/UMG.Border"), tree)
    pcall(function() bd:SetBrushColor({ R = r, G = g, B = b, A = a }) end)
    local slot = canvas:AddChildToCanvas(bd)
    return bd, slot
end

local function newLabel(tree, canvas, size)
    local tb = StaticConstructObject(cls("/Script/UMG.TextBlock"), tree)
    local slot = canvas:AddChildToCanvas(tb)
    pcall(function() slot:SetAutoSize(true) end)
    pcall(function() local f = tb.Font; f.Size = size; tb:SetFont(f) end)
    return tb, slot
end

local function build(pc, n)
    local w = cls("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(pc, cls(HOST_CLASS), pc)
    local tree = w.WidgetTree
    local canvas = StaticConstructObject(cls("/Script/UMG.CanvasPanel"), tree)
    tree.RootWidget = canvas
    local v = { widget = w, tree = tree, canvas = canvas, n = n, wheels = {} }
    local bg, bgSlot = newBorder(tree, canvas, 0, 0, 0, 0.55)
    bgSlot:SetPosition({ X = P.x, Y = P.y }); bgSlot:SetSize({ X = P.w, Y = P.h })
    v.body, v.bodySlot = newBorder(tree, canvas, 0.35, 0.38, 0.42, 0.35)
    v.header, v.headerSlot = newLabel(tree, canvas, 11)
    v.headerSlot:SetPosition({ X = P.x + 10, Y = P.y + 6 })
    v.peak, v.peakSlot = newLabel(tree, canvas, 9)
    v.peakSlot:SetPosition({ X = P.x + 10, Y = P.y + P.h - 70 })
    v.legend, v.legendSlot = newLabel(tree, canvas, 9)
    v.legendSlot:SetPosition({ X = P.x + 10, Y = P.y + P.h - 22 })
    v.legend:SetText(FText("colour = grip used (green < 60% < yellow < 90% < red)   arrow = tire force"))
    for i = 1, n do
        local e = {}
        e.arrow, e.arrowSlot = newBorder(tree, canvas, 1, 1, 1, 0.85)
        e.tire, e.tireSlot = newBorder(tree, canvas, 0.2, 0.8, 0.2, 0.9)
        e.tireSlot:SetSize({ X = TIRE_W, Y = TIRE_H })
        pcall(function() e.tire:SetRenderTransformPivot({ X = 0.5, Y = 0.5 }) end)
        pcall(function() e.arrow:SetRenderTransformPivot({ X = 0.5, Y = 0.5 }) end)
        e.label, e.labelSlot = newLabel(tree, canvas, 9)
        v.wheels[i] = e
    end
    -- G-meter in the middle of the car (drawn before the wheels so arrows stay on top).
    v.gm = gmeter.buildInto(tree, canvas, P.x + P.w / 2, P.y + P.h / 2, 50)
    w:AddToViewport(99)
    return v
end

-- Steering angle per wheel (deg, + = right). Uses the component's own yaw if the game rotates it;
-- otherwise Ackermann from input x max angle, blended by ParallelSteering (1 = parallel, 0 = full Ackermann).
local function steerAngles(s)
    local out, source = {}, "none"
    -- Actual per-wheel angle from the game's wheel quaternion (wheel+0x880), when the game provides one.
    local haveReal = false
    for _, w in ipairs(s.wheels) do
        if w.steerYaw and math.abs(w.steerYaw) > 0.05 then haveReal = true end
    end
    if haveReal or math.abs(s.steer) < 0.01 then
        for i, w in ipairs(s.wheels) do out[i] = w.steerYaw or 0 end
        return out, "actual"
    end
    local delta = s.steer * s.maxSteer
    local rearX, nRear, frontX, nFront = 0, 0, 0, 0
    for _, w in ipairs(s.wheels) do
        if w.canSteer and not w.reverseSteer then frontX, nFront = frontX + w.x, nFront + 1
        else rearX, nRear = rearX + w.x, nRear + 1 end
    end
    if nFront == 0 then for i = 1, #s.wheels do out[i] = 0 end; return out, "no steering wheels" end
    rearX = nRear > 0 and rearX / nRear or 0
    frontX = frontX / nFront
    local L = math.abs(frontX - rearX)
    for i, w in ipairs(s.wheels) do
        if not w.canSteer then out[i] = 0
        else
            local a = delta
            if math.abs(delta) > 0.05 and L > 1 then
                local R = L / math.tan(math.rad(delta))          -- signed turn radius to the rear-axle line (cm)
                local Li = math.abs(w.x - rearX)
                local ack = math.deg(math.atan(Li, R - w.y))
                if ack > 90 then ack = ack - 180 end
                if delta < 0 and ack > 0 then ack = ack - 180 end
                a = s.parallel * delta + (1 - s.parallel) * ack
            end
            out[i] = w.reverseSteer and -a or a
        end
    end
    return out, string.format("computed (input x %.0f°, parallel %.2f)", s.maxSteer, s.parallel)
end

local function gripColor(u)
    if u <= 0.6 then return 0.15, 0.8, 0.25 end
    if u <= 0.9 then local t = (u - 0.6) / 0.3; return 0.15 + 0.85 * t, 0.8 + 0.05 * t, 0.25 - 0.15 * t end
    local t = math.min(1, (u - 0.9) / 0.1); return 1.0, 0.85 - 0.7 * t, 0.1
end

function M.update(pc, s, status, peakLines)
    local n = #s.wheels
    if n == 0 then
        if vis then vis.header:SetText(FText("No wheels. Get in a vehicle.")) end
        return
    end
    if not vis or vis.n ~= n then
        if vis then pcall(function() vis.widget:RemoveFromParent() end) end
        vis = build(pc, n)
    end
    -- Fit wheel positions (X forward -> screen up, Y right -> screen right) into the panel.
    local minX, maxX, minY, maxY = math.huge, -math.huge, math.huge, -math.huge
    for _, w in ipairs(s.wheels) do
        minX, maxX = math.min(minX, w.x), math.max(maxX, w.x)
        minY, maxY = math.min(minY, w.y), math.max(maxY, w.y)
    end
    local spanX, spanY = math.max(maxX - minX, 1), math.max(maxY - minY, 1)
    local scale = math.min((P.h - 2 * P.margin - 30) / spanX, (P.w - 2 * P.margin) / spanY)
    local cx, cy = P.x + P.w / 2, P.y + P.h / 2
    local midX, midY = (minX + maxX) / 2, (minY + maxY) / 2
    local function toScreen(x, y) return cx + (y - midY) * scale, cy - (x - midX) * scale end

    local bx, by = toScreen(maxX, minY)
    vis.bodySlot:SetPosition({ X = bx - 18, Y = by - 30 })
    vis.bodySlot:SetSize({ X = spanY * scale + 36, Y = spanX * scale + 60 })

    local angles, source = steerAngles(s)
    local frontSteer = 0
    for i, w in ipairs(s.wheels) do if w.canSteer and not w.reverseSteer then frontSteer = angles[i]; break end end
    vis.header:SetText(FText(string.format("Steer %+5.1f°  [%s]  %s\n%d wheels   %3.0f km/h", frontSteer, source, status or "", n, s.speed)))
    if peakLines then vis.peak:SetText(FText("Peak slip angle\n" .. peakLines)) end
    gmeter.update(vis.gm, s)

    for i, w in ipairs(s.wheels) do
        local e = vis.wheels[i]
        local px, py = toScreen(w.x, w.y)
        e.tireSlot:SetPosition({ X = px - TIRE_W / 2, Y = py - TIRE_H / 2 })
        e.tire:SetRenderTransformAngle(angles[i])

        local air = w.load <= 50
        local gLong, gLat = 0, 0
        if not air then gLong, gLat = -w.fx / w.load, -w.fy / w.load end
        local g = math.sqrt(gLong * gLong + gLat * gLat)
        local u = (w.mu and w.mu > 0) and g / w.mu or g
        if air then e.tire:SetBrushColor({ R = 0.5, G = 0.5, B = 0.5, A = 0.6 })
        else local r, gg, b = gripColor(u); e.tire:SetBrushColor({ R = r, G = gg, B = b, A = 0.95 }) end

        -- Force arrow: direction of the tire force on the car (forward = up, right = right), length ~ g.
        local len = math.max(2, g * ARROW_PX_PER_G)
        local dx, dy = gLat, -gLong
        local ang = (g > 1e-3) and math.deg(math.atan(dx, -dy)) or 0
        local ux, uy = 0, -1
        if g > 1e-3 then ux, uy = dx / g, dy / g end
        e.arrowSlot:SetSize({ X = ARROW_THICK, Y = len })
        e.arrowSlot:SetPosition({ X = px + ux * len / 2 - ARROW_THICK / 2, Y = py + uy * len / 2 - len / 2 })
        e.arrow:SetRenderTransformAngle(ang)

        local labelX = (w.y >= midY) and (px + TIRE_W / 2 + 6) or (px - TIRE_W / 2 - 62)
        e.labelSlot:SetPosition({ X = labelX, Y = py - 14 })
        e.label:SetText(FText(air and "air" or string.format("%3.0f%%\nstick %3.0f%%", u * 100, w.stick * 100)))
    end
end

function M.visible() return vis ~= nil end
function M.widget() return vis and vis.widget or nil end

function M.hide()
    if vis then pcall(function() vis.widget:RemoveFromParent() end) end
    vis = nil
end

-- Marks the panel as wanted; it is built on the next update (needs a sample to know the wheel count).
local wanted = false
function M.setWanted(on) wanted = on; if not on then M.hide() end end
function M.wanted() return wanted end

return M
