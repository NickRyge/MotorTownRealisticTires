-- One-shot dump of the game's tire / driver-aid settings (Ctrl+F9) to the output folder (paths.lua), game_dump_*.txt:
--   1. tire and aid console variables (value via KismetSystemLibrary.GetConsoleVariableFloatValue)
--   2. every loaded PhysicalMaterial: numeric properties (friction etc.)
--   3. every loaded vehicle type: numeric MTVehicle properties (steering, OptimalSlipAngleDegree, ...) + tire asset
-- Reads plain numbers / names only (a generic dump of exotic property types crashed once).

local M = {}

local OUT_DIR = require("paths").dir("")
local CVARS = {
    "mh.fFBPhysicsAlignTorque",
    "mh.ffbStrength",
    "mh.FFBPhysicsDamping",
    "mh.FFBSmooth",
    "mh.fFBPowerSteeringMaxAssistTorque",
    "mh.fFBPowerSteeringMaxAssistTorquePow",
    "mh.fFBLowSpeedDamping",
    "mh.fFBLowSpeedDampingSmooth",
    "mh.fFBLowSpeedDampingSpeedKPH",
    "mh.fFBLowSpeedMultiplier",
    "mh.fFBFadeInSeconds",
    "mh.useFFBThread",
    "mh.brakeTorqueMultiplayer",
    "mh.vehicleABSMaxSlipRatio",
    "mh.vehicleABSPumpSpeed",
    "mh.vehicleABSReleaseSpeed",
    "mh.vehicleABSLatency",
    "mh.escYawD",
    "mh.escYawP",
    "mh.escYawSpeed",
    "mh.steeringAssistCounterDeadZone",
    "mh.steeringAssistCounterSpeed",
    "mh.steeringAssistCounterSpeedRate",
    "mh.steeringAssistOptimalSlipAngle",
    "mh.steeringAssistSpeedMin",
    "mh.steeringAssistSpeedRate",
    "mh.steeringAssistUserSpeed",
    "mh.tCSOffThrottleMinSpeed",
    "mh.tcsBodySlipAngle",
    "mh.tcsBodySlipAngleTCSOff",
    "mh.tcsMinWheelSpeed",
    "mh.tcsSlipRatioD",
    "mh.tcsSlipRatioI",
    "mh.tcsSlipRatioP",
    "mh.tcsThrottleD",
    "mh.tcsThrottleP",
    "mh.tire.useCircleFriction",
    "mh.tire.useDistanceBasedDistortion",
    "mh.tire.useSlidingMuClamp",
    "mh.tireCamberThrustMultiplier",
    "mh.tireCooldownByWetnessMultiplier",
    "mh.tireCooldownMultiplier",
    "mh.tireDampingOnLowSpeedMsec",
    "mh.tireDampingXOnLowSpeed",
    "mh.tireDampingYOnLowSpeed",
    "mh.tireHeatUpMultiplier",
    "mh.tirePunctureFriction",
    "mh.tirePunctureRollingResistanceMultiplier",
    "mh.tireTemperatureCoreMassInv",
    "mh.tireTemperatureCoreTransferRate",
    "mh.tireTemperatureFrictionChangeRatio",
    "mh.tireWearByWeightMax",
    "mh.tireWearByWeightPower",
    "mh.tireWearFriction",
    "mh.tireWearMultiplier",
    "mh.tireWeightFrictionRatio",
    "mh.tireWeightRatioDecreaseSpeed",
    "mh.tireWeightRatioIncreaseSpeed",
    "mh.tireWetCooldownMultiplier",
    "mh.tireWetFriction",
    "mh.useMultithreadTire",
    "mh.vehicleABSLatency",
    "mh.vehicleABSMaxG",
    "mh.vehicleABSMaxSlipRatio",
    "mh.vehicleABSPumpSpeed",
    "mh.vehicleABSReleaseSpeed",
    "mh.vehicleFireDamageTireRate",
    "mh.vehicleLOD1TireFrictionLerp",
    "mh.vehicleLOD1TireFrictionLerpOffSpeed",
    "mh.vehiclePhysicsUseCylinderTyre",
    "mh.vehicleTireD",
    "mh.vehicleTireK",
    "mh.vehicleTireMass",
    "mh.vehicleTirePhysicsContactLocationBased",
    "mh.vehicleTirePhysicsScrubRotation",
    "mh.vehicleTireShakingMass",
    "mh.vehicleTireShakingMassSpeed",
    "mh.vehicleWheelDampedSpeed",
    "mh.wheelMassOverrideByVerticalForceRatio",
}

local NUMERIC = { FloatProperty = true, DoubleProperty = true, IntProperty = true, BoolProperty = true,
    ByteProperty = true, EnumProperty = true, UInt32Property = true, Int64Property = true, UInt16Property = true }

local function valid(o) return o ~= nil and o:IsValid() end

-- Numeric properties of obj's class chain, stopping at (not including) the class named `stopAt`.
local function numericProps(obj, stopAt)
    local out = {}
    local cls = obj:GetClass()
    while valid(cls) do
        local cname = cls:GetFName():ToString()
        if cname == stopAt or cname == "Object" then break end
        cls:ForEachProperty(function(prop)
            local ptype = prop:GetClass():GetFName():ToString()
            if NUMERIC[ptype] then
                local name = prop:GetFName():ToString()
                local ok, v = pcall(function() return obj[name] end)
                if ok and (type(v) == "number" or type(v) == "boolean") then out[#out + 1] = { cname, name, tostring(v) } end
            end
        end)
        cls = cls:GetSuperStruct()
    end
    return out
end

-- Numeric / vector fields of every struct-valued property on obj's class (e.g. MTVehiclePhysicsSettings).
local function structProps(f, obj, onlyStructs)
    local cls = obj:GetClass()
    while valid(cls) do
        local cname = cls:GetFName():ToString()
        if cname == "Pawn" or cname == "Actor" or cname == "Object" then break end
        cls:ForEachProperty(function(prop)
            if prop:GetClass():GetFName():ToString() ~= "StructProperty" then return end
            local ok, st = pcall(function() return prop:GetStruct() end)
            if not ok or not valid(st) then return end
            local sname = st:GetFName():ToString()
            if onlyStructs and not onlyStructs[sname] then return end
            local pname = prop:GetFName():ToString()
            local okv, sv = pcall(function() return obj[pname] end)
            if not okv then return end
            f:write(string.format("  %s (%s)\n", pname, sname))
            st:ForEachProperty(function(fp)
                local fname = fp:GetFName():ToString()
                local ftype = fp:GetClass():GetFName():ToString()
                local s = nil
                if NUMERIC[ftype] then
                    local o2, v = pcall(function() return sv[fname] end)
                    if o2 then s = tostring(v) end
                elseif ftype == "StructProperty" then
                    local o2, v = pcall(function() local x = sv[fname]; return string.format("(%g, %g, %g)", x.X, x.Y, x.Z or 0) end)
                    if o2 then s = v end
                end
                if s then f:write(string.format("      %-36s %s\n", fname, s)) end
            end)
        end)
        cls = cls:GetSuperStruct()
    end
end

function M.run(log, playerVehicle)
    local path = OUT_DIR .. os.date("game_dump_%Y%m%d_%H%M%S.txt")
    local f = io.open(path, "w")
    if not f then log("can't write %s", path); return end

    -- Player vehicle: physics / control settings structs, body mass and inertia (for yaw-response analysis).
    if valid(playerVehicle) then
        f:write("== PLAYER VEHICLE " .. playerVehicle:GetFullName() .. "\n")
        pcall(structProps, f, playerVehicle, { MTVehiclePhysicsSettings = true, MTVehicleControlSettings = true })
        pcall(function()
            local body = playerVehicle.Body
            f:write(string.format("  Body mass (GetMass)                  %s kg\n", tostring(body:GetMass())))
            local it = body:GetInertiaTensor(FName("None"))
            f:write(string.format("  Body inertia tensor (kg*cm^2)        (%g, %g, %g)\n", it.X, it.Y, it.Z))
            local com = body:GetCenterOfMass(FName("None"))
            f:write(string.format("  Body centre of mass (world, cm)      (%g, %g, %g)\n", com.X, com.Y, com.Z))
            local loc = playerVehicle:K2_GetActorLocation()
            f:write(string.format("  Actor location (world, cm)           (%g, %g, %g)\n", loc.X, loc.Y, loc.Z))
        end)
        f:write("\n")
    end

    f:write("== CVARS\n")
    local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    for _, name in ipairs(CVARS) do
        local ok, v = pcall(function() return ksl:GetConsoleVariableFloatValue(name) end)
        f:write(string.format("%-48s %s\n", name, ok and tostring(v) or "?"))
    end

    f:write("\n== PHYSICAL MATERIALS\n")
    local seen = {}
    for _, pm in ipairs(FindAllOf("PhysicalMaterial") or {}) do
        if valid(pm) then
            local full = pm:GetFullName()
            if not seen[full] then
                seen[full] = true
                f:write(full .. "\n")
                for _, p in ipairs(numericProps(pm, "Object")) do f:write(string.format("    %-24s %-34s %s\n", p[1], p[2], p[3])) end
            end
        end
    end

    f:write("\n== VEHICLE TYPES (loaded instances, one per class)\n")
    local classes = {}
    for _, veh in ipairs(FindAllOf("MTVehicle") or {}) do
        if valid(veh) then
            local cname = veh:GetClass():GetFName():ToString()
            if not classes[cname] then
                classes[cname] = true
                f:write(cname .. "\n")
                local ok, props = pcall(numericProps, veh, "Pawn")
                if ok then
                    for _, p in ipairs(props) do
                        if p[1] == "MTVehicle" then f:write(string.format("    %-34s %s\n", p[2], p[3])) end
                    end
                end
                pcall(function()
                    local wheels = veh:K2_GetComponentsByClass(StaticFindObject("/Script/MotorTown.MHWheelComponent"))
                    local n, tires = 0, {}
                    for _, w in ipairs(wheels) do
                        if type(w) == "userdata" and w.get and not w.IsValid then w = w:get() end
                        if valid(w) then
                            n = n + 1
                            local t = w.TirePhysicsData
                            if valid(t) then tires[t:GetFName():ToString()] = true end
                        end
                    end
                    local tl = {}
                    for k in pairs(tires) do tl[#tl + 1] = k end
                    f:write(string.format("    %-34s %d\n    %-34s %s\n", "(wheels)", n, "(tires)", table.concat(tl, ", ")))
                end)
            end
        end
    end
    f:close()
    log("dump written: %s", path)
end

return M
