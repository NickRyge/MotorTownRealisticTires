-- Tyre model switches (runtime cvars, reversible).
--   Ctrl+F3  mh.tire.useSlidingMuClamp 0 <-> 1 (stock 0).
--            Hypothesis: with it off, sliding bristles keep static mu, which gives the flat plateau measured past
--            the peak (97-99 % of peak out to 26° / 35 % slip). On, they are clamped to SlidingMu -> grip should fall
--            from StaticMu towards SlidingMu past the peak (a drop-off). Verify with an F10 recording.
--   Ctrl+F8  mh.tire.useCircleFriction 0 <-> 1 (stock 0).
--            Off, lateral and longitudinal grip are limited separately, so wheelspin doesn't cost side grip and the
--            throttle can't balance a drift. On, both share one friction circle: spinning the rears should reduce
--            their lateral grip (throttle steers the rear), and braking in a corner should cost grip too.
-- Friction circle is on by default, drop-off off. Stock values are hardcoded (0); a script reload re-applies the defaults.

local M = {}

local switches = {
    dropoff = { cv = "mh.tire.useSlidingMuClamp", name = "drop-off", key = "Ctrl+F3", enabled = false },
    circle  = { cv = "mh.tire.useCircleFriction", name = "friction circle", key = "Ctrl+F8", enabled = true },  -- on by default: confirmed better (2026-09-30)
}
local order = { "dropoff", "circle" }

local function valid(o) return o ~= nil and o:IsValid() end
local function ksl() return StaticFindObject("/Script/Engine.Default__KismetSystemLibrary") end

local function applyOne(pc, s, log)
    ksl():ExecuteConsoleCommand(pc, string.format("%s %d", s.cv, s.enabled and 1 or 0), pc)
    if log then log("tyre %s (%s) %s: cvar now %s", s.name, s.cv, s.enabled and "ON" or "off (stock)", tostring(ksl():GetConsoleVariableFloatValue(s.cv))) end
end

function M.apply(pc, log)
    if not valid(pc) then return false end
    for _, id in ipairs(order) do applyOne(pc, switches[id], log) end
    return true
end

local applied = false
function M.ensure(pc, log) if not applied then applied = M.apply(pc, log) end end

-- id: "dropoff" or "circle"
function M.toggle(pc, log, id)
    local s = switches[id or "dropoff"]
    s.enabled = not s.enabled
    if valid(pc) then applyOne(pc, s, log) end
end

function M.label()
    local parts = {}
    for _, id in ipairs(order) do
        local s = switches[id]
        parts[#parts + 1] = string.format("%s %s (%s)", s.name, s.enabled and "ON" or "off", s.key)
    end
    return table.concat(parts, "  ")
end

return M
