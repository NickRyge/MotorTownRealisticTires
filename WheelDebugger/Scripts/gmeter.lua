-- G-meter drawn into another widget's canvas (used in the middle of the wheel view).
-- Rings at 0.5 / 1.0 / 1.5 g, crosshair, current-G dot with a fading trail, numbers below.
-- Uses the measured body acceleration (telemetry.kinematics). The dot shows the acceleration direction:
-- left turn -> dot left, braking -> dot down (same convention as the wheel view's force arrows).

local M = {}

local TRAIL = 24         -- one dot per tick = ~1.2 s at 20 Hz
local RING_DOTS = 40

local function cls(path) return StaticFindObject(path) end

local function dot(tree, canvas, size, r, g, b, a)
    local bd = StaticConstructObject(cls("/Script/UMG.Border"), tree)
    pcall(function() bd:SetBrushColor({ R = r, G = g, B = b, A = a }) end)
    local slot = canvas:AddChildToCanvas(bd)
    slot:SetSize({ X = size, Y = size })
    return bd, slot
end

local function label(tree, canvas, text, x, y, size)
    local tb = StaticConstructObject(cls("/Script/UMG.TextBlock"), tree)
    local slot = canvas:AddChildToCanvas(tb)
    pcall(function() slot:SetAutoSize(true) end)
    pcall(function() local f = tb.Font; f.Size = size; tb:SetFont(f) end)
    slot:SetPosition({ X = x, Y = y })
    if text then tb:SetText(FText(text)) end
    return tb, slot
end

-- Builds the meter centred at (cx, cy) with `pxPerG` pixels per g. Returns a handle for M.update.
function M.buildInto(tree, canvas, cx, cy, pxPerG)
    local h = { cx = cx, cy = cy, k = pxPerG, trail = {}, pts = {} }
    for _, ring in ipairs({ { 0.5, 0.3 }, { 1.0, 0.65 }, { 1.5, 0.18 } }) do
        local rad = ring[1] * pxPerG
        for i = 0, RING_DOTS - 1 do
            local a = 2 * math.pi * i / RING_DOTS
            local _, s = dot(tree, canvas, 2, 1, 1, 1, ring[2])
            s:SetPosition({ X = cx + rad * math.cos(a) - 1, Y = cy + rad * math.sin(a) - 1 })
        end
    end
    local _, hl = dot(tree, canvas, 1, 1, 1, 1, 0.25); hl:SetSize({ X = 3 * pxPerG, Y = 1 }); hl:SetPosition({ X = cx - 1.5 * pxPerG, Y = cy })
    local _, vl = dot(tree, canvas, 1, 1, 1, 1, 0.25); vl:SetSize({ X = 1, Y = 3 * pxPerG }); vl:SetPosition({ X = cx, Y = cy - 1.5 * pxPerG })
    label(tree, canvas, "1g", cx + pxPerG + 2, cy - 13, 8)
    for i = 1, TRAIL do
        local fade = 1 - (i - 1) / TRAIL
        local bd, s = dot(tree, canvas, 5, 1.0, 0.75, 0.2, 0.5 * fade)
        h.trail[i] = s
    end
    h.dot, h.dotSlot = dot(tree, canvas, 10, 1.0, 0.3, 0.2, 1.0)
    h.text = label(tree, canvas, nil, cx - 58, cy + 1.5 * pxPerG + 4, 9)
    return h
end

function M.update(h, s)
    local lat, long = s.accLat or 0, s.accLong or 0
    local x, y = h.cx + lat * h.k, h.cy - long * h.k
    table.insert(h.pts, 1, { x = x, y = y })
    if #h.pts > TRAIL then h.pts[#h.pts] = nil end
    for i, slot in ipairs(h.trail) do
        local p = h.pts[i] or h.pts[#h.pts]
        slot:SetPosition({ X = p.x - 2.5, Y = p.y - 2.5 })
    end
    h.dotSlot:SetPosition({ X = x - 5, Y = y - 5 })
    h.text:SetText(FText(string.format("lat %+4.2f  long %+4.2f g", lat, long)))
end

return M
