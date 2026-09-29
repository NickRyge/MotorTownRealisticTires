-- Live peak-slip-angle tracker, per axle (front = wheels ahead of the vehicle's wheel centre, rear = behind).
--   measured : slip angle where the achieved lateral grip envelope (90th percentile of |Fy|/load per 1° bin)
--              tops out; marked confirmed once bins beyond the peak show grip falling >= 3 %.
--   predicted: brush-model peak from the small-slip cornering stiffness (slope of mu_y vs tan(alpha) below 3°),
--              tan(alpha_peak) = u* / Ky with Ky = 2 x slope and u* from StaticMu / SlidingMu (tire_math.py).
-- Samples used: load > 500 N, speed > 15 km/h, |slip ratio| < 0.03 (mostly pure cornering).

local M = {}

local BIN_DEG, MAX_DEG = 1, 40
local RING = 120          -- samples kept per bin
local MIN_N = 10
local SMALL_TAN = math.tan(math.rad(3))

local axles = {}          -- "F"/"R" -> { bins = {i -> {vals, pos}}, sxx, sxy, n, mu = {s, k} }
local ustarCache = {}

local function newAxle() return { bins = {}, sxx = 0, sxy = 0, n = 0 } end

function M.reset() axles = {} end

-- u* = normalized stiffness x slip at the brush-model force peak (same formula as tire_math.brush_force).
local function ustar(ms, mk)
    local key = string.format("%.3f/%.3f", ms, mk)
    if ustarCache[key] then return ustarCache[key] end
    local best, bu = -1, 0
    for i = 1, 3000 do
        local u = 6 * ms * i / 3000
        local xb = 1 - u / (6 * ms)
        local f = xb > 0 and (u * xb * xb / 2 + mk * (1 - 3 * xb * xb + 2 * xb ^ 3)) or mk
        if f > best then best, bu = f, u end
    end
    ustarCache[key] = bu
    return bu
end

function M.add(s)
    if s.speed < 15 then return end
    for _, w in ipairs(s.wheels) do
        if w.load > 500 and math.abs(w.vx) > 1e-4 then
            local kappa = w.surf / w.vx - 1
            if math.abs(kappa) < 0.03 then
                local ax = w.slot:sub(1, 1)
                local a = axles[ax] or newAxle()
                axles[ax] = a
                a.ms, a.mk = w.mu or 1.0, w.muSliding or 0.9
                local tanA = math.abs(w.vy) / math.abs(w.vx)
                local deg = math.deg(math.atan(tanA))
                local mu = math.abs(w.fy) / w.load
                local bi = math.floor(deg / BIN_DEG)
                if bi < MAX_DEG / BIN_DEG then
                    local b = a.bins[bi] or { vals = {}, pos = 0 }
                    a.bins[bi] = b
                    b.pos = b.pos % RING + 1
                    b.vals[b.pos] = mu
                end
                if tanA < SMALL_TAN then                 -- least squares through the origin: mu = slope * tanA
                    a.sxx, a.sxy, a.n = a.sxx + tanA * tanA, a.sxy + tanA * mu, a.n + 1
                end
            end
        end
    end
end

local function p90(vals)
    local t = {}
    for _, v in ipairs(vals) do t[#t + 1] = v end
    table.sort(t)
    return t[math.max(1, math.floor(#t * 0.9))]
end

-- Summary per axle: { measured = deg|nil, mu, confirmed, maxSeen, predicted = deg|nil }
function M.summary()
    local out = {}
    for ax, a in pairs(axles) do
        local r = {}
        local best, bestMu, maxSeen = nil, -1, 0
        local env = {}
        for bi, b in pairs(a.bins) do
            if #b.vals >= MIN_N then
                local v = p90(b.vals)
                env[bi] = v
                if bi * BIN_DEG + BIN_DEG > maxSeen then maxSeen = bi * BIN_DEG + BIN_DEG end
                if v > bestMu then best, bestMu = bi, v end
            end
        end
        if best then
            r.measured = (best + 0.5) * BIN_DEG
            r.mu = bestMu
            r.maxSeen = maxSeen
            for bi, v in pairs(env) do
                if bi >= best + 2 and v <= 0.97 * bestMu then r.confirmed = true end
            end
        end
        if a.n >= 30 and a.sxx > 0 then
            local ky = 2 * a.sxy / a.sxx
            if ky > 0 then r.predicted = math.deg(math.atan(ustar(a.ms, a.mk) / ky)) end
        end
        out[ax] = r
    end
    return out
end

-- One text line per axle, e.g. "F  meas 12.5° μ1.05 ✓   pred 13.8°"
function M.lines()
    local s = M.summary()
    local lines = {}
    for _, ax in ipairs({ "F", "R" }) do
        local r = s[ax]
        if r then
            local meas = "meas  –"
            if r.measured then
                meas = r.confirmed and string.format("meas %4.1f° μ%.2f ✓", r.measured, r.mu)
                    or string.format("meas ≥%2.0f° so far", r.maxSeen)
            end
            local pred = r.predicted and string.format("pred %4.1f°", r.predicted) or "pred –"
            lines[#lines + 1] = string.format("%s  %s  %s", ax, meas, pred)
        end
    end
    return #lines > 0 and table.concat(lines, "\n") or "no data yet (drive > 15 km/h)"
end

return M
