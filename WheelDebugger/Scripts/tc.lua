-- Traction control, GT3 style: two dials, throttle cut only (no brake or diff intervention).
--   TC  (1..11, 0 = off)  slip threshold: higher = less wheelspin allowed before it cuts.
--                         The allowed slip shrinks with lateral G (a spinning tyre mid-corner costs side grip on
--                         the friction circle) and has a slip-speed floor so pulling away doesn't bog.
--   CUT (1..11)           intervention strength: how hard the throttle is cut per unit of excess slip.
-- Slip per wheel = (|surface speed| - |ground speed|) from the contact-patch fields (telemetry.lua offsets), so it is
-- exact on any drivetrain: no undriven reference wheel needed. The worst wheel drives the controller.
--
-- Keys, numpad (temporary until there is an options-menu entry):
--   8 / 2   TC  up / down        6 / 4   CUT up / down        5   TC on / off (keeps the level)
--   0       actuator: vehicle Throttle / hook on SetThrottle (registered on first pick) / engine SetThrottle / both
--   .       actuator test: fixed 50 % throttle cut while the pedal is down (TC logic bypassed)
--
-- Unverified: whether a throttle written from Lua reaches the physics before the input overwrites it. The loop
-- checks itself: it shows the rate it runs at, and stops writing if a written value is never overwritten by the
-- input (we'd lose the pedal and could not give the throttle back).

local M = {}

local WHEEL_CLASS = "/Script/MotorTown.MHWheelComponent"

-- Dial maps. TC n -> slip ratio allowed in a straight line; CUT n -> controller gains.
local function slipTarget(n) return 0.25 - (n - 1) * 0.02 end      -- 1: 25 % ... 6: 15 % ... 11: 5 %
local function gains(n) return 0.15 * n, 1.2 * n end               -- P (cut per unit excess), I (per unit per s)
local LAT_SHAPE = 0.5      -- at 1 g cornering only half the straight-line slip is allowed
local DV_MIN = 1.0         -- m/s of wheelspin always allowed (launch floor)
local RELEASE = 1.5        -- cut given back per second once slip is under the target
local MAX_CUT = 0.95
local MIN_PEDAL = 0.05

local tcLevel, cutLevel = 6, 5
local registerHook          -- defined near the end (needs the controller state)
-- hook: pre-hook on MTEngineComponent:SetThrottle scales the argument (works only if the game calls it through
-- reflection; the panel shows calls/s). vehicle: write vehicle Throttle. engine: call SetThrottle ourselves.
local ACTUATORS = { "vehicle", "hook", "engine", "both" }
local actuator = 1
local testCut = false

local st = {
    i = 0, cut = 0, pedal = 0, out = 0, target = 0, dvMax = 0, allowed = 0, latG = 0,
    unit = nil, lastT = nil, lastYaw = nil, hz = 0, nRuns = 0, hzT0 = nil,
    lastWritten = nil, genuine = 0, stuck = 0, disabled = nil, engine = nil, vehAddr = nil, wheels = {},
    found = {}, showUntil = 0, ui = nil, hookCalls = 0, hookHz = 0, hookIn = nil, selfCall = false,
}

local function valid(o) return o ~= nil and o:IsValid() end
local function num(x) if type(x) == "number" then return x end end
local function asDouble(i) return string.unpack("<d", string.pack("<i8", i)) end
local gs = nil
local function gameTime(veh)
    if not valid(gs) then gs = StaticFindObject("/Script/Engine.Default__GameplayStatics") end
    return gs:GetTimeSeconds(veh)
end

-- Components of the vehicle, and once per vehicle a log of every reflected function with "Throttle" in its name
-- (on the vehicle class chain and on its components), so we know what else could take a throttle value.
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

local function throttleFunctions(obj)
    local names = {}
    local cls = obj:GetClass()
    while valid(cls) do
        local cname = cls:GetFName():ToString()
        if cname == "Actor" or cname == "ActorComponent" or cname == "Object" then break end
        cls:ForEachFunction(function(fn)
            local n = fn:GetFName():ToString()
            if n:find("Throttle") or n:find("TractionControl") or n:find("TCS") then names[#names + 1] = cname .. ":" .. n end
        end)
        cls = cls:GetSuperStruct()
    end
    return names
end

-- Numeric reflected properties of an object's class chain, read one by one (no struct/object reads: a generic vehicle
-- dump crashed once). `filter` = list of substrings a name must contain, nil = all.
local NUMERIC = { FloatProperty = true, DoubleProperty = true, IntProperty = true, BoolProperty = true, ByteProperty = true }
local function logNumeric(obj, label, filter, log)
    local parts = {}
    local cls = obj:GetClass()
    while valid(cls) do
        local cname = cls:GetFName():ToString()
        if cname == "Actor" or cname == "Pawn" or cname == "ActorComponent" or cname == "SceneComponent" or cname == "Object" then break end
        cls:ForEachProperty(function(prop)
            local name = prop:GetFName():ToString()
            if not NUMERIC[prop:GetClass():GetFName():ToString()] then return end
            if filter then
                local hit = false
                for _, f in ipairs(filter) do if name:find(f) then hit = true end end
                if not hit then return end
            end
            local ok, v = pcall(function() return obj[name] end)
            parts[#parts + 1] = name .. "=" .. (ok and tostring(v) or "?")
        end)
        cls = cls:GetSuperStruct()
    end
    log("TC: %s props: %s", label, #parts > 0 and table.concat(parts, ", ") or "none")
end

local function discover(veh, log)
    st.engine, st.found = nil, {}
    for _, n in ipairs(throttleFunctions(veh)) do st.found[#st.found + 1] = n end
    for _, c in ipairs(components(veh, "/Script/Engine.ActorComponent")) do
        local fns = throttleFunctions(c)
        for _, n in ipairs(fns) do
            st.found[#st.found + 1] = n
            if n:match(":SetThrottle$") and not st.engine then st.engine = c end
        end
    end
    log("TC: throttle functions on %s: %s", veh:GetClass():GetFName():ToString(),
        #st.found > 0 and table.concat(st.found, ", ") or "none")
    log("TC: engine SetThrottle target: %s", st.engine and st.engine:GetFullName() or "none")
    if valid(st.engine) then logNumeric(st.engine, "engine", nil, log) end
    logNumeric(veh, "vehicle", { "Throttle", "Torque", "TCS", "Traction", "Rpm", "RPM", "Power", "Limit" }, log)
end

-- Worst wheelspin over the wheels on the ground, in m/s. The contact-patch speed units are converted with the ratio
-- of the body speed to the mean |vx|, learned while rolling (≈ 179 in the 2026-09-27 recordings).
local function wheelspin(wheels, speedMs)
    local sumVx, n, worst = 0, 0, -1e9
    local raw = {}
    for _, w in ipairs(wheels) do
        if valid(w) then
            local load = w.wd_load
            if type(load) == "number" and load > 50 then
                local vx, surf = asDouble(w.wd_vx), w.wd_surf
                sumVx, n = sumVx + math.abs(vx), n + 1
                raw[#raw + 1] = math.abs(surf) - math.abs(vx)
            end
        end
    end
    if n == 0 then return nil end
    if speedMs > 3 and sumVx > 1e-6 then
        local u = speedMs / (sumVx / n)
        st.unit = st.unit and (st.unit + (u - st.unit) * 0.05) or u
    end
    local unit = st.unit or 179
    for _, d in ipairs(raw) do if d * unit > worst then worst = d * unit end end
    return worst
end

-- Lateral acceleration in g from speed × yaw rate (cheap, no extra state from telemetry.lua).
local function lateralG(veh, dt, speedMs)
    local f = veh:GetActorForwardVector()
    local yaw = math.atan(f.Y, f.X)
    local g = st.latG
    if st.lastYaw and dt > 1e-4 then
        local d = yaw - st.lastYaw
        if d > math.pi then d = d - 2 * math.pi elseif d < -math.pi then d = d + 2 * math.pi end
        local a = math.abs(speedMs * d / dt) / 9.81
        g = g + (a - g) * math.min(1, dt / 0.1)        -- ~0.1 s smoothing
    end
    st.lastYaw = yaw
    st.latG = g
    return g
end

local function write(veh, value)
    local a = ACTUATORS[actuator]
    if a == "vehicle" or a == "both" then veh.Throttle = value; st.lastWritten = value end
    if (a == "engine" or a == "both") and valid(st.engine) then
        st.selfCall = true
        pcall(function() st.engine:SetThrottle(value) end)
        st.selfCall = false
    end
end

local function reset()
    st.cut, st.i = 0, 0
end

-- One controller step. Called from the game thread as often as UE4SS lets us.
function M.step(veh, log)
    if not valid(veh) then return end
    local addr = veh:GetAddress()
    local stale = addr ~= st.vehAddr
    for _, w in ipairs(st.wheels) do if not valid(w) then stale = true end end
    if stale then
        if addr ~= st.vehAddr then
            st.lastWritten, st.stuck, st.disabled, st.unit, st.lastYaw = nil, 0, nil, nil, nil
            reset()
            pcall(discover, veh, log)
        end
        st.vehAddr, st.wheels = addr, components(veh, WHEEL_CLASS)
    end
    local wheels = st.wheels
    local t = gameTime(veh)
    if st.lastT and t == st.lastT then
        -- Another run in the same game tick: the input may have been applied since, so assert the cut again.
        if st.cut > 0.005 and not st.disabled then write(veh, st.out) end
        return
    end
    local dt = st.lastT and (t - st.lastT) or 0
    st.lastT = t
    if dt <= 0 or dt > 0.25 then return end           -- first run, paused or a hitch
    st.nRuns = st.nRuns + 1
    if not st.hzT0 then st.hzT0 = t elseif t - st.hzT0 >= 1 then
        st.hz = st.nRuns / (t - st.hzT0); st.hookHz = st.hookCalls / (t - st.hzT0)
        st.nRuns, st.hookCalls, st.hzT0 = 0, 0, t
    end

    local pedal = num(veh.Throttle) or 0
    -- Self-check: if the vehicle Throttle still holds exactly what we wrote last tick, the input didn't overwrite
    -- it, so what we read back isn't the pedal. After ~1 s of that, stop writing and restore the last real pedal.
    if st.lastWritten then
        if math.abs(pedal - st.lastWritten) < 1e-7 then
            st.stuck = st.stuck + 1
            pedal = st.genuine
        else
            st.stuck = 0
        end
        if st.stuck > math.max(30, st.hz) and not st.disabled then
            st.disabled = "vehicle Throttle keeps our value (input not re-read); writes stopped"
            log("TC: %s", st.disabled)
            veh.Throttle = st.genuine
        end
    end
    if st.stuck == 0 then st.genuine = pedal end
    st.lastWritten = nil
    st.pedal = pedal

    local v = veh:GetVelocity()
    local speedMs = math.sqrt(v.X * v.X + v.Y * v.Y) / 100
    local latG = lateralG(veh, dt, speedMs)
    local brake = num(veh.Brake) or 0
    local dv = wheelspin(wheels, speedMs)

    local active = (tcLevel > 0 or testCut) and not st.disabled
    if not active or pedal < MIN_PEDAL or brake > 0.1 or dv == nil then
        reset()
        st.out, st.dvMax = pedal, dv or 0
        return
    end

    if testCut then
        st.cut = 0.5
    else
        local kappa = slipTarget(tcLevel) * (1 - LAT_SHAPE * math.min(1, latG))
        local allowed = math.max(kappa * speedMs, DV_MIN)
        local e = (dv - allowed) / math.max(allowed, 0.5)          -- excess slip, relative
        local kp, ki = gains(cutLevel)
        if e > 0 then st.i = math.min(MAX_CUT, st.i + ki * e * dt)
        else st.i = math.max(0, st.i - RELEASE * dt) end
        st.cut = math.max(0, math.min(MAX_CUT, kp * math.max(e, 0) + st.i))
        st.target, st.allowed = kappa, allowed
    end
    st.dvMax = dv
    st.out = pedal * (1 - st.cut)
    if st.cut > 0.005 then write(veh, st.out) end
end

-- Small HUD box: dial values for 3 s after a change, and while the TC is cutting.
local function ensureUI(pc)
    if st.ui and valid(st.ui.widget) then return st.ui end
    local host = StaticFindObject("/Script/MotorTown.TireForceGraphWidget")
    local w = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(pc, host, pc)
    local tree = w.WidgetTree
    local canvas = StaticConstructObject(StaticFindObject("/Script/UMG.CanvasPanel"), tree)
    tree.RootWidget = canvas
    local tb = StaticConstructObject(StaticFindObject("/Script/UMG.TextBlock"), tree)
    local border = StaticConstructObject(StaticFindObject("/Script/UMG.Border"), tree)
    pcall(function() border:SetBrushColor({ R = 0, G = 0, B = 0, A = 0.6 }) end)
    pcall(function() border:SetPadding({ Left = 12, Top = 6, Right = 12, Bottom = 6 }) end)
    border:SetContent(tb)
    local slot = canvas:AddChildToCanvas(border)
    slot:SetPosition({ X = 860, Y = 40 })
    slot:SetSize({ X = 260, Y = 64 })
    pcall(function() local f = tb.Font; f.Size = 16; tb:SetFont(f) end)
    w:AddToViewport(101)
    st.ui = { widget = w, text = tb, shown = true, last = nil }
    return st.ui
end

local function bar(x)
    local n = math.floor(x * 10 + 0.5)
    return string.rep("|", n) .. string.rep(".", 10 - n)
end

function M.hud(pc, now)
    if not valid(pc) then return end
    local cutting = st.cut > 0.02
    local want = now < st.showUntil or cutting or st.disabled ~= nil
    if not want then
        if st.ui and valid(st.ui.widget) and st.ui.shown then st.ui.widget:SetVisibility(1); st.ui.shown = false end
        return
    end
    local ui = ensureUI(pc)
    if not ui.shown then ui.widget:SetVisibility(4); ui.shown = true end           -- 4 = SelfHitTestInvisible
    local line1 = tcLevel == 0 and "TC OFF" or string.format("TC %d   CUT %d", tcLevel, cutLevel)
    if testCut then line1 = "TC TEST 50 % cut" end
    local line2 = st.disabled and "TC writes stopped (see log)" or ((cutting and "● " or "  ") .. bar(st.cut))
    local s = line1 .. "\n" .. line2
    if s ~= ui.last then ui.text:SetText(FText(s)); ui.last = s end
end

local function changed(log)
    st.showUntil = os.clock() + 3
    if tcLevel == 0 then log("TC off")
    else log("TC %d (slip %.0f %%), CUT %d (P %.2f, I %.1f)", tcLevel, slipTarget(tcLevel) * 100, cutLevel, gains(cutLevel)) end
end

local savedLevel = tcLevel
function M.tcUp(log) tcLevel = math.min(11, tcLevel + 1); changed(log) end
function M.toggle(log)
    if tcLevel > 0 then savedLevel, tcLevel = tcLevel, 0 else tcLevel = savedLevel > 0 and savedLevel or 6 end
    changed(log)
end
function M.tcDown(log) tcLevel = math.max(0, tcLevel - 1); changed(log) end
function M.cutUp(log) cutLevel = math.min(11, cutLevel + 1); changed(log) end
function M.cutDown(log) cutLevel = math.max(1, cutLevel - 1); changed(log) end

function M.cycleActuator(log)
    actuator = actuator % #ACTUATORS + 1
    if ACTUATORS[actuator] == "hook" then registerHook(log) end
    st.disabled, st.stuck, st.lastWritten = nil, 0, nil
    st.showUntil = os.clock() + 3
    log("TC actuator: %s%s", ACTUATORS[actuator],
        (ACTUATORS[actuator] ~= "vehicle" and not valid(st.engine)) and " (no engine SetThrottle found on this vehicle)" or "")
end

function M.toggleTest(log)
    testCut = not testCut
    st.showUntil = os.clock() + 3
    log("TC actuator test %s (actuator %s)", testCut and "ON: 50 % cut while the pedal is down" or "off", ACTUATORS[actuator])
end

-- Values for the F8 panel and the CSV recorder.
function M.sample() return { pedal = st.pedal, out = st.out, cut = st.cut, dv = st.dvMax, allowed = st.allowed, latG = st.latG } end

function M.label()
    local head = tcLevel == 0 and "TC off" or string.format("TC %d CUT %d", tcLevel, cutLevel)
    return string.format("%s%s  [%s, %s %.0f Hz]\n  pedal %.2f -> %.2f\n  spin %.1f / %.1f m/s\n  SetThrottle %.0f/s%s%s",
        head, testCut and " TEST" or "", ACTUATORS[actuator], st.phase or "-", st.hz, st.pedal, st.out, st.dvMax, st.allowed,
        st.hookHz, st.hookIn and string.format(" (in %.2f)", st.hookIn) or "",
        st.disabled and ("\n  " .. st.disabled) or "")
end

-- Throttle hook, registered the first time the "hook" actuator is picked (opt-in, so a crash can be pinned on it).
-- Counts calls (panel: SetThrottle n/s) and scales the argument while the TC is cutting.
local hookRegistered = false
registerHook = function(log)
    if hookRegistered then return end
    hookRegistered = true
    local ok, err = pcall(RegisterHook, "/Script/MotorTown.MTEngineComponent:SetThrottle", function(ctx, inThrottle)
        st.hookCalls = st.hookCalls + 1
        if st.selfCall then return end
        pcall(function()
            local v = inThrottle:get()
            st.hookIn = v
            if ACTUATORS[actuator] == "hook" and st.cut > 0.005 and not st.disabled then inThrottle:set(v * (1 - st.cut)) end
        end)
    end)
    log("TC: SetThrottle hook %s", ok and "registered" or ("failed: " .. tostring(err)))
end

-- Where the controller step runs. A per-frame loop runs at the start of the engine tick, before the input: the input
-- then overwrites the throttle we wrote, so nothing reaches the physics (seen 2026-10-02). The player controller's
-- Blueprint ReceiveTick (MotorTownPlayerControllerBP implements it) runs after the controller has processed input,
-- and the pawn (the vehicle) ticks after its controller: a pre-hook there writes between input and physics.
-- The frame loop keeps the HUD going and steps the TC itself only while that hook isn't firing.
local running, started = false, false
local pcHook = { registered = false, calls = 0, lastClock = 0, tried = false }

local function stepSafe(getVehicle, log, where)
    local ok, err = pcall(function()
        local veh = getVehicle()
        if valid(veh) then M.step(veh, log) end
    end)
    if not ok and not st.warned then st.warned = true; log("TC step (%s) failed: %s", where, tostring(err)) end
end

local function tryPCHook(pc, getVehicle, log)
    if pcHook.tried or not valid(pc) then return end
    pcHook.tried = true
    local clsPath = pc:GetClass():GetFullName():match("^%S+%s+(.+)$")         -- "BlueprintGeneratedClass /Game/..._C"
    local fnPath = clsPath and (clsPath .. ":ReceiveTick")
    if not fnPath or not valid(StaticFindObject(fnPath)) then
        log("TC: no Blueprint ReceiveTick on %s; stepping from the frame loop", tostring(clsPath)); return
    end
    local ok, err = pcall(RegisterHook, fnPath, function()
        pcHook.calls = pcHook.calls + 1
        pcHook.lastClock = os.clock()
        st.phase = "controller tick"
        stepSafe(getVehicle, log, "controller tick")
    end)
    pcHook.registered = ok
    log("TC: controller tick hook on %s: %s", fnPath, ok and "registered" or ("failed: " .. tostring(err)))
end

local function body(getPC, getVehicle, log)
    if not started then started = true; log("TC: loop running (%s)", st.mode) end
    local pc = getPC()
    pcall(tryPCHook, pc, getVehicle, log)
    if os.clock() - pcHook.lastClock > 0.25 then
        st.phase = "frame loop"
        stepSafe(getVehicle, log, "frame loop")
    end
    local ok, err = pcall(M.hud, pc, os.clock())
    if not ok and not st.hudWarned then st.hudWarned = true; log("TC hud failed: %s", tostring(err)) end
end

function M.start(getPC, getVehicle, log)
    if running then return end
    running = true
    require("telemetry").register()
    local loop = require("loop")
    local h, mode = loop.frames(1, function() body(getPC, getVehicle, log) end)
    if not h then _, mode = loop.every(16, function() body(getPC, getVehicle, log) end) end
    st.mode = mode
end

return M
