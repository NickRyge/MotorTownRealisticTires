-- Brake panel (F6): per-wheel brake contribution + automatic brake test in R13-H terms.
--
-- Live, per wheel (while braking):
--   force    braking force at the tyre, N (-fx; only counted while decelerating)
--   share    this wheel's part of the total braking force  -> brake contribution
--   load     this wheel's part of the total load            -> what it *should* carry for ideal balance
--   f        adhesion used = braking force / wheel load (R13-H Annex 5 "f_i")
--   slip     slip ratio (negative = braking); ABS% = share of the stop spent beyond the ABS target
--   temp     brake surface temperature (vehicle state)
-- Per axle: f_front vs f_rear vs z (braking rate). R13-H Annex 5: rear must not use more adhesion than front.
-- Ideal balance: front brake share = front load share under braking (both axles at the same f).
--
-- Brake test (automatic): starts at brake pedal > 0.8 above 40 km/h, ends below 3 km/h or pedal release.
--   MFDD = (vb^2 - ve^2) / (25.92 (se - sb)), vb = 0.8 v0, ve = 0.1 v0 (km/h, m)   [R13-H Annex 3]
--   stopping distance, peak g, epsilon ~ MFDD / (g * mean tyre static mu)          [Annex 6 idea]
--   EU check: MFDD >= 6.43 m/s^2 (cars), 5.0 (trucks, from 60 km/h)

local M = {}

local HOST_CLASS = "/Script/MotorTown.TireForceGraphWidget"
local P = { x = 30, y = 470, w = 760, h = 300 }
local ABS_SLIP = 0.12     -- matches brakes.lua "smooth"/"firm" target; used only to count ABS-active time

local function valid(o) return o ~= nil and o:IsValid() end
local function cls(p) return StaticFindObject(p) end

local ui = nil
local wanted = false
local test = nil          -- running brake test
local last = nil          -- last finished test result
local live = {}           -- smoothed live per-wheel values

local function build(pc)
    local w = cls("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(pc, cls(HOST_CLASS), pc)
    local tree = w.WidgetTree
    local canvas = StaticConstructObject(cls("/Script/UMG.CanvasPanel"), tree)
    tree.RootWidget = canvas
    local border = StaticConstructObject(cls("/Script/UMG.Border"), tree)
    pcall(function() border:SetBrushColor({ R = 0, G = 0, B = 0, A = 0.6 }) end)
    pcall(function() border:SetPadding({ Left = 10, Top = 6, Right = 10, Bottom = 6 }) end)
    local tb = StaticConstructObject(cls("/Script/UMG.TextBlock"), tree)
    pcall(function() local f = tb.Font; f.Size = 11; tb:SetFont(f) end)
    border:SetContent(tb)
    local slot = canvas:AddChildToCanvas(border)
    slot:SetPosition({ X = P.x, Y = P.y }); slot:SetSize({ X = P.w, Y = P.h })
    w:AddToViewport(97)
    return { widget = w, text = tb }
end

local function slipOf(w)
    if math.abs(w.vx) < 1e-4 then return 0 end
    return w.surf / w.vx - 1
end

-- Brake temperatures per wheel index from the vehicle's replicated state (same order as the wheel list).
local function brakeTemps(veh)
    local out = {}
    pcall(function()
        veh.NetLC_VehicleState.Wheels:ForEach(function(i, e)
            local st = e:get()
            out[i] = st.BrakeTemperature
        end)
    end)
    return out
end

local function startTest(s)
    test = { v0 = s.speed, t0 = s.t, tPrev = s.t, dist = 0, peakG = 0, samples = {}, wheels = {}, n = 0,
        muSum = 0, muN = 0 }
end

local function finishTest(s)
    local tr = test
    test = nil
    if #tr.samples < 5 then return end
    local vb, ve = 0.8 * tr.v0, 0.1 * tr.v0
    local sb, se
    for _, p in ipairs(tr.samples) do
        if not sb and p.v <= vb then sb = p.d end
        if not se and p.v <= ve then se = p.d end
    end
    local r = { v0 = tr.v0, dist = tr.dist, peakG = tr.peakG, wheels = {} }
    if sb and se and se > sb then
        r.mfdd = (vb * vb - ve * ve) / (25.92 * (se - sb))
    end
    local muAvg = tr.muN > 0 and tr.muSum / tr.muN or nil
    if r.mfdd and muAvg then r.eps = r.mfdd / (9.81 * muAvg) end
    local totF = 0
    for _, a in pairs(tr.wheels) do totF = totF + a.f end
    for slot, a in pairs(tr.wheels) do
        r.wheels[slot] = { share = totF > 0 and a.f / totF or 0, loadShare = a.loadShare / math.max(1, a.n),
            adh = a.adh / math.max(1, a.n), abs = a.abs / math.max(1, a.n), slip = a.slip / math.max(1, a.n) }
    end
    last = r
end

-- Called every tick with the telemetry sample (s.t = game time, s.brake = pedal 0..1).
function M.add(s)
    local braking = (s.brake or 0) > 0.8
    if not test and braking and s.speed > 40 then startTest(s) end
    local totLoad, totF = 0, 0
    for _, w in ipairs(s.wheels) do
        totLoad = totLoad + w.load
        totF = totF + math.max(0, -w.fx)
    end
    -- live values (smoothed) for the panel
    for _, w in ipairs(s.wheels) do
        local f = math.max(0, -w.fx)
        local l = live[w.slot] or { force = 0, share = 0, load = 0, adh = 0, slip = 0 }
        local a = 0.3
        l.force = l.force + (f - l.force) * a
        l.share = l.share + ((totF > 0 and f / totF or 0) - l.share) * a
        l.load = l.load + ((totLoad > 0 and w.load / totLoad or 0) - l.load) * a
        l.adh = l.adh + ((w.load > 50 and f / w.load or 0) - l.adh) * a
        l.slip = l.slip + (slipOf(w) - l.slip) * a
        live[w.slot] = l
    end
    if not test then return end
    local dt = math.max(0, s.t - test.tPrev)
    test.tPrev = s.t
    test.dist = test.dist + s.speed / 3.6 * dt
    test.samples[#test.samples + 1] = { v = s.speed, d = test.dist }
    if -s.accLong > test.peakG then test.peakG = -s.accLong end
    for _, w in ipairs(s.wheels) do
        local a = test.wheels[w.slot] or { f = 0, loadShare = 0, adh = 0, abs = 0, slip = 0, n = 0 }
        local f = math.max(0, -w.fx)
        a.f = a.f + f
        a.loadShare = a.loadShare + (totLoad > 0 and w.load / totLoad or 0)
        a.adh = a.adh + (w.load > 50 and f / w.load or 0)
        local k = slipOf(w)
        a.slip = a.slip + k
        if k < -ABS_SLIP then a.abs = a.abs + 1 end
        a.n = a.n + 1
        test.wheels[w.slot] = a
        if w.mu then test.muSum = test.muSum + w.mu; test.muN = test.muN + 1 end
    end
    if s.speed < 3 or (s.brake or 0) < 0.3 then finishTest(s) end
end

local ORDER = { "FL", "FR", "RL", "RR" }

local function axleF(tbl, key, weightKey)
    local f, r, nf, nr = 0, 0, 0, 0
    for slot, v in pairs(tbl) do
        if slot:sub(1, 1) == "F" then f, nf = f + v[key], nf + 1 else r, nr = r + v[key], nr + 1 end
    end
    return nf > 0 and f / nf or 0, nr > 0 and r / nr or 0
end

local function balanceAdvice(frontShare, frontLoad, fF, fR)
    if fR > fF * 1.02 then return "REAR uses more grip than front -> move bias FORWARD (unstable, fails R13-H)" end
    local d = frontShare - frontLoad
    if d > 0.05 then return string.format("front-biased by %.0f%% -> move bias REARWARD for shorter stops", d * 100) end
    if d < -0.02 then return string.format("rear-biased by %.0f%% -> move bias FORWARD", -d * 100) end
    return "balance close to ideal (front share ~ front load share)"
end

local function render(s, veh)
    local lines = {}
    local temps = brakeTemps(veh)
    lines[#lines + 1] = string.format("BRAKES   pedal %3.0f%%   decel %4.2f g   %s", (s.brake or 0) * 100,
        math.max(0, -s.accLong), test and "● TEST RUNNING" or "")
    lines[#lines + 1] = "wheel   force N   share   load   adhesion f   slip    temp"
    for i, slot in ipairs(ORDER) do
        local l = live[slot]
        if l then
            local ti = nil
            for j, w in ipairs(s.wheels) do if w.slot == slot then ti = temps[j] end end
            lines[#lines + 1] = string.format("%-5s  %7.0f   %4.0f%%   %4.0f%%     %4.2f      %+5.2f   %s",
                slot, l.force, l.share * 100, l.load * 100, l.adh, l.slip, ti and string.format("%3.0f°", ti) or "-")
        end
    end
    local fF, fR = axleF(live, "adh")
    local fs, _ = 0, 0
    local frontShare, frontLoad = 0, 0
    for slot, l in pairs(live) do
        if slot:sub(1, 1) == "F" then frontShare, frontLoad = frontShare + l.share, frontLoad + l.load end
    end
    lines[#lines + 1] = string.format("axles   front f %.2f  rear f %.2f   front share %2.0f%% vs front load %2.0f%%",
        fF, fR, frontShare * 100, frontLoad * 100)
    if (s.brake or 0) > 0.3 and s.speed > 10 then lines[#lines + 1] = "        " .. balanceAdvice(frontShare, frontLoad, fF, fR) end
    if last then
        lines[#lines + 1] = ""
        local eu = last.mfdd and (last.mfdd >= 6.43 and "PASS" or "FAIL") or "?"
        lines[#lines + 1] = string.format("LAST STOP from %3.0f km/h: %.1f m   MFDD %s   peak %.2f g   ε %s   EU car (≥6.43): %s",
            last.v0, last.dist, last.mfdd and string.format("%.2f m/s² (%.2f g)", last.mfdd, last.mfdd / 9.81) or "-",
            last.peakG, last.eps and string.format("%.2f", last.eps) or "-", eu)
        local parts = {}
        for _, slot in ipairs(ORDER) do
            local w = last.wheels[slot]
            if w then parts[#parts + 1] = string.format("%s %2.0f%%/%2.0f%% f%.2f ABS%2.0f%%", slot, w.share * 100, w.loadShare * 100, w.adh, w.abs * 100) end
        end
        lines[#lines + 1] = "  share/load: " .. table.concat(parts, "  ")
        local fsh, flo = 0, 0
        for slot, w in pairs(last.wheels) do if slot:sub(1, 1) == "F" then fsh, flo = fsh + w.share, flo + w.loadShare end end
        local lf, lr = axleF(last.wheels, "adh")
        lines[#lines + 1] = "  " .. balanceAdvice(fsh, flo, lf, lr)
    else
        lines[#lines + 1] = ""
        lines[#lines + 1] = "Brake test: full pedal (>80%) from above 40 km/h to a stop."
    end
    ui.text:SetText(FText(table.concat(lines, "\n")))
end

function M.update(pc, s, veh)
    if not ui then ui = build(pc) end
    render(s, veh)
end

function M.widget() return ui and ui.widget or nil end
function M.wanted() return wanted end
function M.setWanted(on)
    wanted = on
    if not on and ui then pcall(function() ui.widget:RemoveFromParent() end); ui = nil end
end

return M
