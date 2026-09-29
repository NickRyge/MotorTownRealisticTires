-- Shared wheel telemetry: one sampling loop feeding the overlay and the CSV recorder.
-- Offsets (NOTES.md §10), all on MHWheelComponent:
--   0x6B8 double tire force X (longitudinal) N   | 0x6C0 double tire force Y (lateral) N
--   0x704 float  wheel load N                    | 0x708/0x710 double contact-patch velocity X/Y
--   0x718 float  wheel surface speed (omega*R, same units as 0x708)
-- Force sign is opposite to the car's acceleration, so grip G = -F / load.

local M = {}

local WHEEL_CLASS = "/Script/MotorTown.MHWheelComponent"
local OUT_DIR = "C:\\Users\\Ryge\\MotorTownTools\\research\\telemetry\\"

local function valid(o) return o ~= nil and o:IsValid() end
local function asDouble(i) return string.unpack("<d", string.pack("<i8", i)) end

local registered = false
function M.register()
    if registered then return end
    local props = {
        { "wd_fx", 0x6B8, PropertyTypes.Int64Property }, { "wd_fy", 0x6C0, PropertyTypes.Int64Property },
        { "wd_load", 0x704, PropertyTypes.FloatProperty },
        { "wd_vx", 0x708, PropertyTypes.Int64Property }, { "wd_vy", 0x710, PropertyTypes.Int64Property },
        { "wd_surf", 0x718, PropertyTypes.FloatProperty },
        -- Wheel rotation relative to the vehicle as a quaternion (x, y, z, w) of doubles; yaw = steering angle.
        { "wd_qx", 0x880, PropertyTypes.Int64Property }, { "wd_qy", 0x888, PropertyTypes.Int64Property },
        { "wd_qz", 0x890, PropertyTypes.Int64Property }, { "wd_qw", 0x898, PropertyTypes.Int64Property },
    }
    for _, p in ipairs(props) do
        pcall(RegisterCustomProperty, { Name = p[1], Type = p[3], BelongsToClass = WHEEL_CLASS, OffsetInternal = p[2] })
    end
    registered = true
end

-- Wheels of one vehicle, asked from the vehicle itself; cached until the vehicle changes or a wheel dies.
local cache = { vehAddr = nil, wheels = {}, slots = {} }

local function slotNames(wheels)
    local sx = 0
    for _, w in ipairs(wheels) do sx = sx + w.RelativeLocation.X end
    local cx = #wheels > 0 and sx / #wheels or 0
    local out = {}
    for i, w in ipairs(wheels) do
        local loc = w.RelativeLocation
        out[i] = (loc.X >= cx and "F" or "R") .. (loc.Y < 0 and "L" or "R")
    end
    return out
end

local function wheelsOf(veh)
    if not valid(veh) then cache.vehAddr = nil; cache.wheels = {}; cache.slots = {}; return cache.wheels, cache.slots end
    local addr = veh:GetAddress()
    local stale = addr ~= cache.vehAddr
    for _, w in ipairs(cache.wheels) do if not valid(w) then stale = true end end
    if stale then
        local cls = StaticFindObject(WHEEL_CLASS)
        local list = {}
        -- UE4SS returns function-result arrays as a plain Lua table; a TArray (with ForEach) is handled too.
        local arr = veh:K2_GetComponentsByClass(cls)
        local function add(e)
            if type(e) == "userdata" and e.get and not e.IsValid then e = e:get() end
            if valid(e) then list[#list + 1] = e end
        end
        if type(arr) == "table" then
            for _, e in ipairs(arr) do add(e) end
        elseif arr and arr.ForEach then
            arr:ForEach(function(_, e) add(e:get()) end)
        end
        -- Static per-wheel info, read once per vehicle: position (cm, X forward / Y right), steering flags, tire mu.
        local info = {}
        for i, w in ipairs(list) do
            local loc = w.RelativeLocation
            local it = { x = loc.X, y = loc.Y, steer = false, reverse = false, mu = 1.0, muSliding = 0.9 }
            pcall(function() it.steer = w.bSteer; it.reverse = w.bReverseSteer end)
            pcall(function() it.mu = w.TirePhysicsData.TirePhysicsParams.StaticMu end)
            pcall(function() it.muSliding = w.TirePhysicsData.TirePhysicsParams.SlidingMu end)
            info[i] = it
        end
        cache.vehAddr, cache.wheels, cache.slots, cache.info = addr, list, slotNames(list), info
    end
    return cache.wheels, cache.slots, cache.info
end

-- Body acceleration from the velocity vector: dv/dt over game time, smoothed, split into the vehicle's
-- forward / right axes. (The engine's physics angular velocity is always 0: Motor Town runs its own physics.)
local kin = { t = nil, vx = 0, vy = 0, aLong = 0, aLat = 0 }
local ACC_ALPHA = 0.35     -- smoothing per 50 ms tick
local gameplayStatics = nil

local function gameTime(veh)
    if not valid(gameplayStatics) then gameplayStatics = StaticFindObject("/Script/Engine.Default__GameplayStatics") end
    return gameplayStatics:GetTimeSeconds(veh)
end

local function kinematics(veh, s, v)
    local t = gameTime(veh)
    local vx, vy = v.X / 100, v.Y / 100                               -- m/s, world XY
    if kin.t and t > kin.t then
        local dt = t - kin.t
        local ax, ay = (vx - kin.vx) / dt, (vy - kin.vy) / dt
        local f = veh:GetActorForwardVector()
        local fl = math.sqrt(f.X * f.X + f.Y * f.Y)
        s.yaw = math.deg(math.atan(f.Y, f.X))                         -- heading, deg (UE: + = clockwise from above)
        if fl > 1e-3 then
            local fx, fy = f.X / fl, f.Y / fl
            local long = ax * fx + ay * fy
            local lat = -ax * fy + ay * fx                            -- + = rightward (UE: X forward, Y right)
            kin.aLong = kin.aLong + (long - kin.aLong) * ACC_ALPHA
            kin.aLat = kin.aLat + (lat - kin.aLat) * ACC_ALPHA
        end
    end
    kin.t, kin.vx, kin.vy = t, vx, vy
    s.t, s.velX, s.velY = t, vx, vy
    s.accLong, s.accLat = kin.aLong / 9.81, kin.aLat / 9.81           -- in g
end

-- One sample: per wheel {slot, fx, fy, load, vx, vy, surf} plus vehicle {steer, maxSteer, speed, t, accLat, accLong}.
function M.sample(veh)
    local wheels, slots, info = wheelsOf(veh)
    local s = { vehicleKey = cache.vehAddr, wheels = {}, steer = 0, maxSteer = 0, parallel = 1, speed = 0, speedMs = 0, t = 0, velX = 0, velY = 0, accLat = 0, accLong = 0 }
    if valid(veh) then
        s.steer = veh.Steer
        s.maxSteer = veh.MaxSteeringAngleDegree
        pcall(function() s.brake = veh.Brake; s.throttle = veh.Throttle end)
        pcall(function() s.parallel = veh.ParallelSteering end)
        local v = veh:GetVelocity()                                   -- cm/s
        s.speedMs = math.sqrt(v.X * v.X + v.Y * v.Y) / 100
        s.speed = s.speedMs * 3.6
        local ok, err = pcall(kinematics, veh, s, v)
        if not ok and not kin.warned then kin.warned = true; print("[WheelDebugger] kinematics failed: " .. tostring(err) .. "\n") end
    end
    for i, w in ipairs(wheels) do
        if valid(w) then
            local it = info[i]
            local e = {
                slot = slots[i], fx = asDouble(w.wd_fx), fy = asDouble(w.wd_fy), load = w.wd_load,
                vx = asDouble(w.wd_vx), vy = asDouble(w.wd_vy), surf = w.wd_surf,
                x = it.x, y = it.y, canSteer = it.steer, reverseSteer = it.reverse, mu = it.mu, muSliding = it.muSliding,
                relYaw = 0, stick = 1, steerYaw = 0,
            }
            -- Actual steering angle (deg, + = right) from the wheel quaternion at 0x880.
            pcall(function()
                local x, y, z, q = asDouble(w.wd_qx), asDouble(w.wd_qy), asDouble(w.wd_qz), asDouble(w.wd_qw)
                if math.abs(x) + math.abs(y) + math.abs(z) + math.abs(q) > 0.5 then
                    e.steerYaw = math.deg(math.atan(2 * (q * z + x * y), 1 - 2 * (y * y + z * z)))
                end
            end)
            -- The component's own yaw relative to the vehicle (0 if the game steers only inside its physics).
            pcall(function() e.relYaw = w.RelativeRotation.Yaw end)
            -- Share of the contact patch still sticking (1 = full grip, 0 = whole patch sliding).
            pcall(function()
                local b = w.BrushTirePhysics
                if b.ContactPatchLength > 1e-4 then e.stick = b.ContactPatchStaticLength / b.ContactPatchLength end
            end)
            s.wheels[#s.wheels + 1] = e
        end
    end
    return s
end

-- Wheel components behind the last sample (same order as sample.wheels while all are valid).
function M.currentWheels() return cache.wheels end

-- CSV recorder fed from the same samples.
local rec = nil
function M.recording() return rec ~= nil end

function M.startRecording(seconds, hz, log)
    if rec then log("already recording"); return end
    local path = OUT_DIR .. os.date("tel_%Y%m%d_%H%M%S.csv")
    local f = io.open(path, "w")
    if not f then log("can't write %s", path); return end
    f:write("n,t,slot,speed_kph,vel_x,vel_y,acc_lat_g,acc_long_g,steer,max_steer,fx,fy,load,vx,vy,surf,rel_yaw,stick,steer_yaw,brake,throttle,yaw,wx,wy\n")
    rec = { f = f, n = 0, max = seconds * hz, path = path }
    log("recording %ds at %dHz to %s", seconds, hz, path)
end

function M.record(s, log)
    if not rec then return end
    rec.n = rec.n + 1
    local lines = {}
    for _, w in ipairs(s.wheels) do
        lines[#lines + 1] = string.format("%d,%.4f,%s,%.2f,%.3f,%.3f,%.3f,%.3f,%.4f,%.1f,%.1f,%.1f,%.1f,%.6g,%.6g,%.6g,%.3f,%.3f,%.3f,%.3f,%.3f,%.4f,%.1f,%.1f",
            rec.n, s.t, w.slot, s.speed, s.velX, s.velY, s.accLat, s.accLong, s.steer, s.maxSteer,
            w.fx, w.fy, w.load, w.vx, w.vy, w.surf, w.relYaw, w.stick, w.steerYaw, s.brake or 0, s.throttle or 0,
            s.yaw or 0, w.x, w.y)
    end
    rec.f:write(table.concat(lines, "\n") .. "\n")
    if rec.n >= rec.max then
        rec.f:close()
        log("recording finished (%d samples): %s", rec.n, rec.path)
        rec = nil
    end
end

function M.stopRecording(log)
    if rec then rec.f:close(); log("recording stopped (%d samples)", rec.n); rec = nil end
end

return M
