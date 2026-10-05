-- Active differential: the game's clutch-pack LSD, with its lock set every frame from the driving situation.
-- No brakes, no throttle: only the diff's own lock torque. Works on open, clutch-pack and lockable (unlocked) diffs;
-- locked diffs (a Locked part, or a lockable diff the driver has locked) are left alone.
--
-- How the game's diff works (NOTES.md, "Torque vectoring recon"): BeginPlay copies the LSD part into the diff component,
-- +0x158 type (byte: 0 open, 1 locked, 2 clutch pack, 3 lockable), +0x15C lock coefficient under power, +0x160 lock
-- coefficient on the overrun. A per-step solver callback reads those three live from the component on every physics
-- step, for every diff whatever its type, and only part swaps and the diff-lock toggle write them. So writing them each
-- frame from Lua is a real electronically controlled LSD. The lock is torque sensing: each step it removes
-- |coef × input torque| of energy from the left/right speed difference; which coefficient applies follows the sign of
-- the input torque (power vs. overrun). The stock 1-way part is 50 / 0, the 1.5-way 50 / 30, the 2-way 100 / 100.
--
-- Dials, per car (carprefs.lua), numpad:
--   7 / 1   POWER lock 0..11 (0 open, 11 locked), scaled with the throttle pedal.
--   9 / 3   COAST lock 0..11 (overrun and braking; turn-in stability vs. rotation).
--   *       active diff on / off (off = the car's own LSD part, restored).
-- On top of the dials:
--   understeer on power (yaw rate well below what the steering asks for) opens the power lock, down to 30 %, so the
--   car can rotate; oversteer (yaw rate above it) raises the coast lock up to 2×, which damps the yaw; at parking
--   speeds with a lot of steering both open (no tyre scrub, no crabbing trucks).

local M = {}

local DIFF_CLASS = "/Script/MotorTown.MTDifferentialComponent"
local WHEEL_CLASS = "/Script/MotorTown.MHWheelComponent"
local DEFAULT_POWER, DEFAULT_COAST = 4, 2
local function coef(n)                       -- dial -> lock coefficient (stock parts: 50 / 30 / 100)
    if n <= 0 then return 0 elseif n >= 11 then return 1e6 end
    return 20 * n
end
local PEDAL_BASE = 0.3                       -- power lock at a feathered pedal, as a share of the dial
local US_LO, US_HI = 0.4, 0.75               -- yaw-rate ratio (actual / kinematic) where the power lock is fully / not opened
local US_MIN = 0.3                           -- power lock share left in full understeer
local OS_HI = 1.25                           -- yaw-rate ratio above which the coast lock is raised
local OS_GAIN = 2.0                          -- coast lock factor at ratio OS_HI + 0.5
local LOW_KPH_LO, LOW_KPH_HI = 3, 20         -- tight-turn opening fades out between these speeds
local LOW_MIN = 0.15
local LOW_STEER = 15                         -- degrees of road-wheel angle for the full tight-turn opening
local MIN_SPEED = 8                          -- m/s; below this the yaw comparison isn't used

local enabled, powerLevel, coastLevel = false, DEFAULT_POWER, DEFAULT_COAST
local st = {
    vehAddr = nil, car = nil, diffs = {}, wheelbase = 2.6, maxSteer = 35, written = false,
    lastT = nil, lastYaw = nil, yawRate = 0, ratio = 1, signAcc = 0,
    power = 0, coast = 0, usF = 1, osF = 1, lowF = 1, showUntil = 0,
}

local function valid(o) return o ~= nil and o:IsValid() end
local function num(x) if type(x) == "number" then return x end end
local function clamp(x, lo, hi) return math.max(lo, math.min(hi, x)) end

local registered = false
local function register()
    if registered then return end
    registered = true
    for _, p in ipairs({ { "ad_type", 0x158, PropertyTypes.ByteProperty }, { "ad_accel", 0x15C, PropertyTypes.FloatProperty },
                         { "ad_brake", 0x160, PropertyTypes.FloatProperty } }) do
        pcall(RegisterCustomProperty, { Name = p[1], Type = p[3], BelongsToClass = DIFF_CLASS, OffsetInternal = p[2] })
    end
end

local function components(veh, clsPath)
    local out = {}
    local arr = veh:K2_GetComponentsByClass(StaticFindObject(clsPath))
    local function add(e)
        if type(e) == "userdata" and e.get and not e.IsValid then e = e:get() end
        if valid(e) then out[#out + 1] = e end
    end
    if type(arr) == "table" then for _, e in ipairs(arr) do add(e) end
    elseif arr and arr.ForEach then arr:ForEach(function(_, e) add(e:get()) end) end
    return out
end

local gs = nil
local function gameTime(veh)
    if not valid(gs) then gs = StaticFindObject("/Script/Engine.Default__GameplayStatics") end
    return gs:GetTimeSeconds(veh)
end

-- The car's own LSD part back on every diff we may have written (locked diffs untouched).
local function restore()
    for _, d in ipairs(st.diffs) do
        if valid(d.comp) and num(d.comp.ad_type) ~= 1 then
            d.comp.ad_type = d.type
            d.comp.ad_accel = d.accel
            d.comp.ad_brake = d.brake
        end
    end
    st.written = false
end

local function discover(veh, log)
    st.diffs = {}
    local names = {}
    for _, c in ipairs(components(veh, DIFF_CLASS)) do
        local asset = c.DataAsset
        local d = { comp = c, name = c:GetFName():ToString(), type = 0, accel = 0, brake = 0 }
        if valid(asset) then
            d.type = num(asset.LSDType) or 0
            d.accel = num(asset.ClutchPackAccel) or 0
            d.brake = num(asset.ClutchPackBrake) or 0
        end
        st.diffs[#st.diffs + 1] = d
        names[#names + 1] = string.format("%s type %d %g/%g", d.name, d.type, d.accel, d.brake)
    end
    -- Wheelbase from the wheel positions along the car (cm -> m).
    local f = veh:GetActorForwardVector()
    local lo, hi = nil, nil
    for _, w in ipairs(components(veh, WHEEL_CLASS)) do
        local p = w:K2_GetComponentLocation()
        local x = p.X * f.X + p.Y * f.Y + p.Z * f.Z
        lo, hi = lo and math.min(lo, x) or x, hi and math.max(hi, x) or x
    end
    st.wheelbase = (lo and hi - lo > 100) and (hi - lo) / 100 or 2.6
    st.maxSteer = num(veh.MaxSteeringAngleDegree) or 35
    log("AD: %s, wheelbase %.2f m, max steer %.0f deg, diffs: %s", st.car, st.wheelbase, st.maxSteer,
        #names > 0 and table.concat(names, ", ") or "none")
end

local function selectCar(veh, log)
    st.car = veh:GetClass():GetFName():ToString()
    local c = require("carprefs").get(st.car)
    enabled = c ~= nil and c.ad == 1
    powerLevel = c and c.adp and clamp(c.adp, 0, 11) or DEFAULT_POWER
    coastLevel = c and c.adc and clamp(c.adc, 0, 11) or DEFAULT_COAST
    st.signAcc, st.lastYaw, st.lastT, st.yawRate = 0, nil, nil, 0
    discover(veh, log)
    if not enabled then restore() end              -- also undoes writes left over from a script reload
    if #st.diffs > 0 then st.showUntil = os.clock() + 3 end
end

function M.step(veh, log)
    if not valid(veh) then return end
    register()
    local addr = veh:GetAddress()
    if addr ~= st.vehAddr then
        if st.written then pcall(restore) end      -- the previous car gets its own part back
        st.vehAddr = addr
        local ok, err = pcall(selectCar, veh, log)
        if not ok then log("AD: car setup failed: %s", tostring(err)); st.diffs = {} end
    end
    if #st.diffs == 0 then return end
    if not enabled then
        if st.written then restore() end
        return
    end

    local t = gameTime(veh)
    if st.lastT and t == st.lastT then return end
    local dt = st.lastT and (t - st.lastT) or 0
    st.lastT = t

    local v = veh:GetVelocity()
    local speed = math.sqrt(v.X * v.X + v.Y * v.Y) / 100
    local f = veh:GetActorForwardVector()
    local yaw = math.atan(f.Y, f.X)
    if st.lastYaw and dt > 1e-4 and dt < 0.25 then
        local d = yaw - st.lastYaw
        if d > math.pi then d = d - 2 * math.pi elseif d < -math.pi then d = d + 2 * math.pi end
        st.yawRate = st.yawRate + (d / dt - st.yawRate) * math.min(1, dt / 0.05)
    end
    st.lastYaw = yaw

    local pedal = num(veh.Throttle) or 0
    local delta = math.rad((num(veh.Steer) or 0) * st.maxSteer)

    -- Yaw rate against the kinematic (no-slip) yaw rate the steering asks for. The sign convention between Steer and
    -- the yaw angle is learned from the driving, so a flipped axis can't read as permanent understeer.
    st.usF, st.osF = 1, 1
    if speed > MIN_SPEED and math.abs(delta) > math.rad(2) then
        local ref = speed * math.tan(delta) / st.wheelbase
        if math.abs(st.yawRate) > 0.05 then
            st.signAcc = clamp(st.signAcc + ((st.yawRate * ref > 0) and 1 or -1), -50, 50)
        end
        local sign = st.signAcc >= 0 and 1 or -1
        st.ratio = sign * st.yawRate / ref
        st.usF = US_MIN + (1 - US_MIN) * clamp((st.ratio - US_LO) / (US_HI - US_LO), 0, 1)
        st.osF = 1 + (OS_GAIN - 1) * clamp((st.ratio - OS_HI) / 0.5, 0, 1)
    else
        st.ratio = 1
    end
    local kph = speed * 3.6
    local steerW = clamp(math.abs(math.deg(delta)) / LOW_STEER, 0, 1)
    st.lowF = 1 - (1 - clamp((kph - LOW_KPH_LO) / (LOW_KPH_HI - LOW_KPH_LO), LOW_MIN, 1)) * steerW

    local pc = coef(powerLevel)
    st.power = powerLevel >= 11 and pc or pc * (PEDAL_BASE + (1 - PEDAL_BASE) * clamp(pedal, 0, 1)) * st.usF * st.lowF
    st.coast = coastLevel >= 11 and coef(coastLevel) or coef(coastLevel) * st.osF * st.lowF

    for _, d in ipairs(st.diffs) do
        local c = d.comp
        if d.type ~= 1 and valid(c) and num(c.ad_type) ~= 1 then
            if c.ad_type ~= 2 then c.ad_type = 2 end
            c.ad_accel = st.power
            c.ad_brake = st.coast
        end
    end
    st.written = true
end

local function changed(log)
    st.showUntil = os.clock() + 3
    require("carprefs").put(st.car, { ad = enabled and 1 or 0, adp = powerLevel, adc = coastLevel }, log)
    if not enabled then log("AD off (car's own LSD part)")
    else log("AD POWER %d (coef %g), COAST %d (coef %g)", powerLevel, coef(powerLevel), coastLevel, coef(coastLevel)) end
end

function M.toggle(log) enabled = not enabled; changed(log) end
function M.powerUp(log) powerLevel = math.min(11, powerLevel + 1); changed(log) end
function M.powerDown(log) powerLevel = math.max(0, powerLevel - 1); changed(log) end
function M.coastUp(log) coastLevel = math.min(11, coastLevel + 1); changed(log) end
function M.coastDown(log) coastLevel = math.max(0, coastLevel - 1); changed(log) end

-- One HUD line for the TC box (tc.lua), shown for 3 s after a change or a car switch.
function M.hudWanted(now) return now < st.showUntil end
function M.hudLine()
    if #st.diffs == 0 then return "AD: no diff" end
    if not enabled then return "AD OFF" end
    return string.format("AD P%d C%d", powerLevel, coastLevel)
end

-- Values for the CSV recorder.
function M.sample()
    return { on = enabled and 1 or 0, power = st.power, coast = st.coast, ratio = st.ratio, yawRate = st.yawRate }
end

return M
