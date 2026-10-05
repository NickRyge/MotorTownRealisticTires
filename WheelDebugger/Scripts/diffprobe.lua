-- Differential recon (Ctrl+F2), read only: nothing is written to the game.
--   1. diff_<car>_<time>.txt: every reflected property (name, type, offset, value) of the vehicle's differential and
--      drive-shaft components and the LSD data assets they point to, plus the drive/torque-related wheel properties.
--   2. diff_<car>_<time>.csv: 10 s recording at frame rate of every numeric property found in (1), plus a raw scan of
--      each differential component's memory as floats (4-byte steps from its first own property to 0x100 past its last),
--      to catch unreflected per-tick state (current lock torque, output torques ...). Drive a corner exit on full
--      throttle and a few launches while it records.
-- Values are only read for plain types (number, bool, enum, name, object path); structs are read one level deep,
-- numeric members only. A generic dump of exotic property types crashed once (dump.lua).

local M = {}

local OUT_DIR = require("paths").dir("")
local SECONDS = 10
local COMP_PATTERN = { "Differential", "DriveShaft" }
local WHEEL_CLASS = "/Script/MotorTown.MHWheelComponent"
local WHEEL_NAMES = { "Torque", "Angular", "Omega", "Rpm", "RPM", "Spin", "Drive", "Diff", "Inertia", "Ratio", "Lock" }
local STOP_AT = { Object = true, ActorComponent = true, SceneComponent = true, Actor = true, Pawn = true,
    DataAsset = true, PrimaryDataAsset = true }
local NUMERIC = { FloatProperty = true, DoubleProperty = true, IntProperty = true, Int64Property = true,
    UInt32Property = true, Int16Property = true, BoolProperty = true, ByteProperty = true, EnumProperty = true }

local function valid(o) return o ~= nil and o:IsValid() end

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

-- Reflected properties of obj's class chain (most derived first), stopping at engine base classes.
local function properties(obj)
    local out = {}
    local cls = obj:GetClass()
    while valid(cls) do
        local cname = cls:GetFName():ToString()
        if STOP_AT[cname] then break end
        cls:ForEachProperty(function(prop)
            local off = -1
            pcall(function() off = prop:GetOffset_Internal() end)
            out[#out + 1] = { name = prop:GetFName():ToString(), type = prop:GetClass():GetFName():ToString(),
                offset = off, owner = cname, prop = prop }
        end)
        cls = cls:GetSuperStruct()
    end
    return out
end

local function fmtValue(obj, p)
    local ok, v = pcall(function() return obj[p.name] end)
    if not ok then return "?" end
    if NUMERIC[p.type] or p.type == "StrProperty" then return tostring(v) end
    if p.type == "NameProperty" then
        local ok2, s = pcall(function() return v:ToString() end)
        return ok2 and s or "?"
    end
    if p.type == "ObjectProperty" or p.type == "SoftObjectProperty" then
        local ok2, s = pcall(function() return valid(v) and v:GetFullName() or "None" end)
        return ok2 and s or "?"
    end
    if p.type == "ArrayProperty" then
        local ok2, n = pcall(function() return v:GetArrayNum() end)
        return ok2 and ("[" .. tostring(n) .. "]") or "[?]"
    end
    if p.type == "StructProperty" then
        local parts = {}
        pcall(function()
            p.prop:GetStruct():ForEachProperty(function(inner)
                local iname, itype = inner:GetFName():ToString(), inner:GetClass():GetFName():ToString()
                if NUMERIC[itype] then
                    local ok3, iv = pcall(function() return v[iname] end)
                    parts[#parts + 1] = iname .. "=" .. (ok3 and tostring(iv) or "?")
                else
                    parts[#parts + 1] = iname .. ":" .. itype
                end
            end)
        end)
        return "{" .. table.concat(parts, ", ") .. "}"
    end
    return "(" .. p.type .. ")"
end

local function dumpObject(f, obj, label, filter)
    f:write(string.format("== %s  %s\n", label, obj:GetFullName()))
    local props = properties(obj)
    for _, p in ipairs(props) do
        local hit = not filter
        if filter then for _, s in ipairs(filter) do if p.name:find(s) then hit = true end end end
        if hit then
            f:write(string.format("  0x%04X  %-22s %-40s %s   [%s]\n", p.offset, p.type, p.name, fmtValue(obj, p), p.owner))
        end
    end
    return props
end

local rec = nil

-- Raw float slots registered on the differential class: dp_XXXX at offset 0xXXXX.
local rawRegistered = {}
local function rawSlots(comp, props)
    local cname = comp:GetClass():GetFName():ToString()
    local lo, hi = nil, 0
    for _, p in ipairs(props) do
        if p.owner == cname and p.offset >= 0 then
            lo = lo and math.min(lo, p.offset) or p.offset
            hi = math.max(hi, p.offset)
        end
    end
    if not lo then return {} end
    lo = lo - lo % 4
    hi = hi + 0x100
    local clsPath = comp:GetClass():GetFullName():match("^%S+%s+(.+)$")
    if not clsPath then return {} end
    local slots = {}
    for off = lo, hi, 4 do
        local name = string.format("dp_%04X", off)
        if not rawRegistered[clsPath .. name] then
            local ok = pcall(RegisterCustomProperty, { Name = name, Type = PropertyTypes.FloatProperty,
                BelongsToClass = clsPath, OffsetInternal = off })
            rawRegistered[clsPath .. name] = ok
        end
        if rawRegistered[clsPath .. name] then slots[#slots + 1] = name end
    end
    return slots
end

local function readNum(obj, name)
    local ok, v = pcall(function() return obj[name] end)
    if not ok then return "" end
    if type(v) == "boolean" then return v and "1" or "0" end
    if type(v) == "number" then return string.format("%.6g", v) end
    return ""
end

function M.run(veh, log)
    if rec then log("diff probe: still recording (%d/%d)", rec.n, rec.max); return end
    if not valid(veh) then log("diff probe: not in a vehicle"); return end
    local car = veh:GetClass():GetFName():ToString()
    local stamp = os.date("%Y%m%d_%H%M%S")
    local base = OUT_DIR .. "diff_" .. car .. "_" .. stamp
    local f = io.open(base .. ".txt", "w")
    if not f then log("diff probe: can't write %s.txt", base); return end
    f:write(string.format("Vehicle %s\n\n", veh:GetFullName()))

    -- Components whose class name matches, found through ActorComponent so we don't depend on exact class paths.
    local cols, sources = {}, {}
    local assets = {}
    for _, c in ipairs(components(veh, "/Script/Engine.ActorComponent")) do
        local cname = c:GetClass():GetFName():ToString()
        local hit = false
        for _, s in ipairs(COMP_PATTERN) do if cname:find(s) then hit = true end end
        if hit then
            local label = c:GetFName():ToString()
            local props = dumpObject(f, c, cname, nil)
            for _, p in ipairs(props) do
                if NUMERIC[p.type] then
                    cols[#cols + 1] = label .. "." .. p.name; sources[#sources + 1] = { c, p.name }
                elseif p.type == "ObjectProperty" then
                    local ok, o = pcall(function() return c[p.name] end)
                    if ok and valid(o) then
                        local ocls = o:GetClass():GetFName():ToString()
                        if ocls:find("LSD") or ocls:find("Diff") then assets[o:GetFullName()] = o end
                    end
                end
            end
            if cname:find("Differential") then
                for _, s in ipairs(rawSlots(c, props)) do
                    cols[#cols + 1] = label .. "." .. s; sources[#sources + 1] = { c, s }
                end
            end
            f:write("\n")
        end
    end
    for _, o in pairs(assets) do dumpObject(f, o, "asset", nil); f:write("\n") end

    local wheels = components(veh, WHEEL_CLASS)
    for i, w in ipairs(wheels) do
        local label = "W" .. i .. "_" .. w:GetFName():ToString()
        local props = dumpObject(f, w, label, WHEEL_NAMES)
        for _, p in ipairs(props) do
            local hit = false
            for _, s in ipairs(WHEEL_NAMES) do if p.name:find(s) then hit = true end end
            if hit and NUMERIC[p.type] then cols[#cols + 1] = label .. "." .. p.name; sources[#sources + 1] = { w, p.name } end
        end
        f:write("\n")
    end
    f:close()

    local csv = io.open(base .. ".csv", "w")
    if not csv then log("diff probe: can't write %s.csv", base); return end
    csv:write("t,throttle,brake,steer,speed_kph," .. table.concat(cols, ",") .. "\n")
    rec = { f = csv, n = 0, max = 0, sources = sources, veh = veh, t0 = os.clock() }
    log("diff probe: %s.txt written, recording %d columns for %d s", base, #cols, SECONDS)
    local function tick()
        if not rec then return true end
        local t = os.clock() - rec.t0
        if t > SECONDS or not valid(rec.veh) then
            rec.f:close()
            log("diff probe: recording finished (%d frames)", rec.n)
            rec = nil
            return true
        end
        local v = rec.veh:GetVelocity()
        local row = { string.format("%.4f", t), readNum(rec.veh, "Throttle"), readNum(rec.veh, "Brake"), readNum(rec.veh, "Steer"),
            string.format("%.2f", math.sqrt(v.X * v.X + v.Y * v.Y) * 0.036) }
        for _, s in ipairs(rec.sources) do row[#row + 1] = valid(s[1]) and readNum(s[1], s[2]) or "" end
        rec.f:write(table.concat(row, ",") .. "\n")
        rec.n = rec.n + 1
    end
    local loop = require("loop")
    if not loop.frames(1, tick) then loop.every(16, tick) end
end

return M
