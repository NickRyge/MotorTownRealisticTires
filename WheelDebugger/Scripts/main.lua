-- WheelDebugger: revives Motor Town's unused developer widget UTireForceGraphWidget.
--   F8  show / hide the tire graph for the current wheel
--   F9  next wheel on the vehicle you're driving
--   F10 print diagnostics (classes, wheels found) to UE4SS.log / console
-- Everything is wrapped in pcall; failures are logged, never thrown into the game.

local UEHelpers = require("UEHelpers")

local TAG = "[WheelDebugger] "
local function log(fmt, ...) print(TAG .. string.format(fmt, ...) .. "\n") end

local WIDGET_CLASS_PATH = "/Script/MotorTown.TireForceGraphWidget"

local state = { widget = nil, wheels = {}, index = 1, wheelClassName = nil }

local function valid(o) return o ~= nil and o:IsValid() end

-- The wheel component class is whatever SetWheelComponent takes as its parameter.
local function resolveWheelClassName()
    if state.wheelClassName then return state.wheelClassName end
    local fn = StaticFindObject(WIDGET_CLASS_PATH .. ":SetWheelComponent")
    if not valid(fn) then log("SetWheelComponent UFunction not found"); return nil end
    fn:ForEachProperty(function(prop)
        local ok, cls = pcall(function() return prop:GetPropertyClass() end)
        if ok and valid(cls) then
            state.wheelClassName = cls:GetFName():ToString()
            log("parameter %s -> wheel class %s", prop:GetFName():ToString(), state.wheelClassName)
        end
    end)
    return state.wheelClassName
end

-- The actor the player is driving: the controller's pawn, or what that pawn is attached to / sitting in.
local function playerVehicleCandidates()
    local out = {}
    local pc = UEHelpers.GetPlayerController()
    if not valid(pc) then return out end
    local pawn = pc.Pawn
    if valid(pawn) then
        out[#out + 1] = pawn
        local ok, parent = pcall(function() return pawn:GetAttachParentActor() end)
        if ok and valid(parent) then out[#out + 1] = parent end
    end
    return out
end

local function isOwnedBy(comp, actors)
    local ok, owner = pcall(function() return comp:GetOwner() end)
    if not ok or not valid(owner) then return false end
    for _, a in ipairs(actors) do
        if owner:GetAddress() == a:GetAddress() then return true end
    end
    return false
end

local function collectWheels()
    state.wheels = {}
    local cls = resolveWheelClassName()
    if not cls then return end
    local all = FindAllOf(cls) or {}
    local actors = playerVehicleCandidates()
    for _, w in ipairs(all) do
        if valid(w) and isOwnedBy(w, actors) then state.wheels[#state.wheels + 1] = w end
    end
    log("%d %s total, %d on the player's vehicle", #all, cls, #state.wheels)
    if state.index > #state.wheels then state.index = 1 end
end

local function currentWheel()
    if #state.wheels == 0 then collectWheels() end
    return state.wheels[state.index]
end

-- Screen layout for the graph (viewport pixels at 1080p; UMG scales with DPI).
local LAYOUT = { x = 40, y = 160, w = 720, h = 460, textH = 40 }

-- Class of a property on the widget class (e.g. Plot -> CartesianPlot), read from reflection.
local function propertyClass(ownerClass, propName)
    local found
    ownerClass:ForEachProperty(function(prop)
        if prop:GetFName():ToString() == propName then
            local ok, c = pcall(function() return prop:GetPropertyClass() end)
            if ok and valid(c) then found = c end
        end
    end)
    return found
end

local function dumpClassProps(cls)
    log("class %s", cls:GetFullName())
    cls:ForEachProperty(function(prop)
        log("  prop %-28s %s", prop:GetFName():ToString(), prop:GetClass():GetFName():ToString())
    end)
    cls:ForEachFunction(function(fn) log("  func %s", fn:GetFName():ToString()) end)
end

-- The shipped game has no Blueprint layout for this widget, so build the one its C++ expects:
-- a CanvasPanel root holding the CartesianPlot ("Plot") and a TextBlock ("PeakTextBlock").
local function buildLayout(w, cls)
    local tree = w.WidgetTree
    local plotClass = propertyClass(cls, "Plot")
    local canvasClass = StaticFindObject("/Script/UMG.CanvasPanel")
    local textClass = StaticFindObject("/Script/UMG.TextBlock")
    if not (valid(tree) and valid(plotClass) and valid(canvasClass) and valid(textClass)) then
        log("layout: missing tree/classes (tree %s, plot %s)", tostring(valid(tree)), tostring(valid(plotClass)))
        return false
    end
    if not state.dumpedPlot then dumpClassProps(plotClass); state.dumpedPlot = true end

    local canvas = StaticConstructObject(canvasClass, tree)
    local plot = StaticConstructObject(plotClass, tree)
    local text = StaticConstructObject(textClass, tree)
    tree.RootWidget = canvas

    local ps = canvas:AddChildToCanvas(plot)
    ps:SetPosition({ X = LAYOUT.x, Y = LAYOUT.y + LAYOUT.textH })
    ps:SetSize({ X = LAYOUT.w, Y = LAYOUT.h })
    local ts = canvas:AddChildToCanvas(text)
    ts:SetPosition({ X = LAYOUT.x, Y = LAYOUT.y })
    ts:SetSize({ X = LAYOUT.w, Y = LAYOUT.textH })

    w.Plot = plot
    w.PeakTextBlock = text
    log("layout built: %s + %s", plot:GetFullName(), text:GetFullName())
    return true
end

local function createWidget()
    local cls = StaticFindObject(WIDGET_CLASS_PATH)
    if not valid(cls) then log("widget class not found: %s", WIDGET_CLASS_PATH); return nil end
    local pc = UEHelpers.GetPlayerController()
    local lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    if not valid(pc) or not valid(lib) then log("no player controller / WidgetBlueprintLibrary"); return nil end
    local w = lib:Create(pc, cls, pc)
    if not valid(w) then log("WidgetBlueprintLibrary.Create returned nothing"); return nil end
    local ok, err = pcall(buildLayout, w, cls)
    if not ok then log("layout failed: %s", tostring(err)) end
    w:AddToViewport(100)
    log("widget created: %s", w:GetFullName())
    return w
end

local function attach()
    local wheel = currentWheel()
    if not valid(wheel) then log("no wheel found; get in a vehicle and press F8 again"); return end
    state.widget:SetWheelComponent(wheel)
    log("showing wheel %d/%d: %s", state.index, #state.wheels, wheel:GetFName():ToString())
end

local function toggle()
    if valid(state.widget) then
        state.widget:RemoveFromParent()
        state.widget = nil
        log("hidden")
        return
    end
    collectWheels()
    state.widget = createWidget()
    if valid(state.widget) then attach() end
end

local function nextWheel()
    collectWheels()
    if #state.wheels == 0 then log("no wheels on the player's vehicle"); return end
    state.index = state.index % #state.wheels + 1
    if valid(state.widget) then
        pcall(function() state.widget:ClearGraph() end)
        attach()
    else
        log("selected wheel %d/%d (press F8 to show)", state.index, #state.wheels)
    end
end

-- Lists the widget class's own reflected properties and, if a widget exists, their current values.
local function dumpWidgetClass()
    local cls = StaticFindObject(WIDGET_CLASS_PATH)
    if not valid(cls) then return end
    local super = cls:GetSuperStruct()
    log("class %s, super %s", cls:GetFullName(), valid(super) and super:GetFullName() or "?")
    cls:ForEachProperty(function(prop)
        local name = prop:GetFName():ToString()
        local ptype = prop:GetClass():GetFName():ToString()
        local extra = ""
        local ok, pc = pcall(function() return prop:GetPropertyClass() end)
        if ok and valid(pc) then extra = " -> " .. pc:GetFName():ToString() end
        local value = ""
        if valid(state.widget) then
            local okv, v = pcall(function() return state.widget[name] end)
            if okv then
                if type(v) == "userdata" and v.IsValid then
                    value = v:IsValid() and (" = " .. v:GetFullName()) or " = (null)"
                else
                    value = " = " .. tostring(v)
                end
            end
        end
        log("  prop %-28s %s%s%s", name, ptype, extra, value)
    end)
    cls:ForEachFunction(function(fn) log("  func %s", fn:GetFName():ToString()) end)
    if valid(state.widget) then
        local okt, tree = pcall(function() return state.widget.WidgetTree end)
        log("  WidgetTree: %s", okt and valid(tree) and tree:GetFullName() or "(none)")
        if okt and valid(tree) then
            local okr, root = pcall(function() return tree.RootWidget end)
            log("  RootWidget: %s", okr and valid(root) and root:GetFullName() or "(none)")
        end
        local okvis, vis = pcall(function() return state.widget:GetVisibility() end)
        log("  visibility: %s, in viewport: %s", tostring(okvis and vis), tostring(state.widget:IsInViewport()))
    end
end

-- Every reflected property of an object's class chain with its current value (numbers, bools, names, objects).
local function dumpObject(obj, label)
    if not valid(obj) then return end
    log("==== %s: %s", label, obj:GetFullName())
    local cls = obj:GetClass()
    while valid(cls) do
        local cname = cls:GetFName():ToString()
        if cname == "ActorComponent" or cname == "Actor" or cname == "Object" then break end
        cls:ForEachProperty(function(prop)
            local name = prop:GetFName():ToString()
            local ptype = prop:GetClass():GetFName():ToString()
            local okv, v = pcall(function() return obj[name] end)
            local s = "?"
            if okv then
                if type(v) == "number" or type(v) == "boolean" then s = tostring(v)
                elseif type(v) == "userdata" then
                    local okn, str = pcall(function() return v:ToString() end)
                    if okn and type(str) == "string" then s = str
                    else
                        local okx, x = pcall(function() return string.format("(%.3f, %.3f, %.3f)", v.X, v.Y, v.Z) end)
                        if okx then s = x
                        else
                            local oko, full = pcall(function() return v:IsValid() and v:GetFullName() or "(null)" end)
                            s = oko and full or ptype
                        end
                    end
                else s = tostring(v) end
            end
            log("  [%s] %-34s %-16s %s", cname, name, ptype, s)
        end)
        cls = cls:GetSuperStruct()
    end
end

-- Fields of a struct-valued property, e.g. wheel.BrushTirePhysics, using the UScriptStruct's reflection.
local function dumpStruct(obj, propName, structPath)
    local st = StaticFindObject(structPath)
    if not valid(obj) or not valid(st) then log("struct %s not found", structPath); return end
    local okv, sv = pcall(function() return obj[propName] end)
    if not okv then log("can't read %s", propName); return end
    log("==== %s.%s (%s)", obj:GetFName():ToString(), propName, structPath)
    st:ForEachProperty(function(prop)
        local name = prop:GetFName():ToString()
        local ptype = prop:GetClass():GetFName():ToString()
        local s = ptype
        if ptype == "FloatProperty" or ptype == "DoubleProperty" or ptype == "IntProperty" or ptype == "BoolProperty"
            or ptype == "ByteProperty" or ptype == "UInt32Property" then
            local ok, v = pcall(function() return sv[name] end)
            s = ok and tostring(v) or "?"
        elseif ptype == "StructProperty" then
            local ok, v = pcall(function() local x = sv[name]; return string.format("(%.3f, %.3f, %.3f)", x.X, x.Y, x.Z or 0) end)
            if ok then s = v end
        end
        log("  %-34s %-16s %s", name, ptype, s)
    end)
end

-- Value of a numeric/vector field as text.
local function fieldText(sv, name, ptype)
    if ptype == "StructProperty" then
        local ok, v = pcall(function() local x = sv[name]; return string.format("(%.4f, %.4f, %.4f)", x.X, x.Y, x.Z or 0) end)
        return ok and v or ptype
    end
    local ok, v = pcall(function() return sv[name] end)
    return ok and tostring(v) or "?"
end

-- Elements of an array-of-struct property: finds the inner struct via reflection and prints the first `limit` entries.
local function dumpArrayOfStruct(container, containerStruct, arrayName, limit)
    local inner
    containerStruct:ForEachProperty(function(prop)
        if prop:GetFName():ToString() == arrayName then
            local ok, ip = pcall(function() return prop:GetInner() end)
            if ok and ip then
                local oks, st = pcall(function() return ip:GetStruct() end)
                if oks and valid(st) then inner = st end
            end
        end
    end)
    if not inner then log("  %s: no struct inner type", arrayName); return end
    local arr = container[arrayName]
    local n = 0
    pcall(function() n = arr:GetArrayNum() end)
    log("  %s: %d x %s", arrayName, n, inner:GetFullName())
    local fields = {}
    inner:ForEachProperty(function(prop) fields[#fields + 1] = { prop:GetFName():ToString(), prop:GetClass():GetFName():ToString() } end)
    local count = 0
    arr:ForEach(function(index, elem)
        count = count + 1
        if count > limit then return true end
        local e = elem:get()
        local parts = {}
        for _, f in ipairs(fields) do parts[#parts + 1] = f[1] .. "=" .. fieldText(e, f[1], f[2]) end
        log("    [%d] %s", index, table.concat(parts, "  "))
    end)
end

local function diagnostics()
    collectWheels()
    local brushStruct = StaticFindObject("/Script/MotorTown.MHBrushTirePhysics")
    for i = 1, math.min(2, #state.wheels) do
        log("==== wheel %d brushes", i)
        dumpArrayOfStruct(state.wheels[i].BrushTirePhysics, brushStruct, "Brushes", 12)
    end
    local actors = playerVehicleCandidates()
    local vs = StaticFindObject("/Script/MotorTown.MTVehicleState")
    log("==== vehicle state wheels")
    dumpArrayOfStruct(actors[#actors].NetLC_VehicleState, vs, "Wheels", 4)
    if true then return end
    dumpObject(state.wheels[1], "wheel 1")
    dumpWidgetClass()
    log("widget class: %s", tostring(valid(StaticFindObject(WIDGET_CLASS_PATH))))
    log("wheel class: %s", tostring(resolveWheelClassName()))
    for i, a in ipairs(playerVehicleCandidates()) do log("candidate actor %d: %s", i, a:GetFullName()) end
    collectWheels()
    for i, w in ipairs(state.wheels) do log("  wheel %d: %s", i, w:GetFullName()) end
end

local function safe(name, f)
    return function()
        ExecuteInGameThread(function()
            local ok, err = pcall(f)
            if not ok then log("%s failed: %s", name, tostring(err)) end
        end)
    end
end

local overlay = require("overlay")
local function overlayVehicle() local a = playerVehicleCandidates(); return a[#a] end

RegisterKeyBind(Key.F8, safe("overlay", function() overlay.toggle(UEHelpers.GetPlayerController(), overlayVehicle, log) end))
RegisterKeyBind(Key.F7, safe("wheelView", function() overlay.toggleVisual(UEHelpers.GetPlayerController(), overlayVehicle, log) end))
RegisterKeyBind(Key.F10, { ModifierKey.CONTROL }, safe("steerProbe", function() overlay.steerProbe(overlayVehicle, log) end))
local assist = require("assist")
RegisterKeyBind(Key.F7, { ModifierKey.CONTROL }, safe("assist", function()
    assist.toggle(UEHelpers.GetPlayerController(), overlayVehicle(), log)
end))
local brakes = require("brakes")
RegisterKeyBind(Key.F6, { ModifierKey.CONTROL }, safe("brakes", function()
    brakes.toggle(UEHelpers.GetPlayerController(), log)
end))
RegisterKeyBind(Key.F5, { ModifierKey.CONTROL }, safe("abs", function()
    brakes.cycleABS(UEHelpers.GetPlayerController(), log)
end))
local tirecvars = require("tirecvars")
RegisterKeyBind(Key.F3, { ModifierKey.CONTROL }, safe("dropoff", function()
    tirecvars.toggle(UEHelpers.GetPlayerController(), log, "dropoff")
end))
RegisterKeyBind(Key.F8, { ModifierKey.CONTROL }, safe("frictionCircle", function()
    tirecvars.toggle(UEHelpers.GetPlayerController(), log, "circle")
end))
local ffb = require("ffb")
RegisterKeyBind(Key.F1, { ModifierKey.CONTROL }, safe("ffb", function()
    ffb.cycle(UEHelpers.GetPlayerController(), log)
end))
-- Keep the assist target applied across vehicle switches, even with no panel open (1 s watcher).
LoopAsync(1000, function()
    ExecuteInGameThread(function()
        pcall(assist.check, UEHelpers.GetPlayerController(), overlayVehicle(), log)
        pcall(brakes.ensure, UEHelpers.GetPlayerController(), log)
        pcall(tirecvars.ensure, UEHelpers.GetPlayerController(), log)
        pcall(ffb.ensure, UEHelpers.GetPlayerController(), log)
    end)
    return false
end)
local dump = require("dump")
RegisterKeyBind(Key.F9, { ModifierKey.CONTROL }, safe("dump", function() dump.run(log, overlayVehicle()) end))
RegisterKeyBind(Key.F6, safe("brakePanel", function() overlay.toggleBrakes(UEHelpers.GetPlayerController(), overlayVehicle, log) end))
RegisterKeyBind(Key.F9, safe("resetMax", function() overlay.resetMax(); log("maxima reset") end))
RegisterKeyBind(Key.F10, safe("record", function() overlay.record(overlayVehicle, log) end))
-- A reload leaves the previous overlay on screen; clear it so F8 starts clean.
ExecuteInGameThread(function() pcall(overlay.clearAll, log) end)
log("loaded. F6 brake panel, F7 wheel view + G-meter, F8 overlay, F9 reset max, F10 record 30 s telemetry (press again to stop), Ctrl+F10 steering probe, Ctrl+F9 settings dump, Ctrl+F7 assist, Ctrl+F6 brakes, Ctrl+F5 ABS preset, Ctrl+F3 tyre drop-off, Ctrl+F1 FFB preset")
