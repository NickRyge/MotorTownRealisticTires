-- Tyre model switches (runtime cvars, reversible).
--   Ctrl+F3  mh.tire.useSlidingMuClamp 0 <-> 1 (stock 0).
--            Hypothesis: with it off, sliding bristles keep static mu, which gives the flat plateau measured past
--            the peak (97-99 % of peak out to 26° / 35 % slip). On, they are clamped to SlidingMu -> grip should fall
--            from StaticMu towards SlidingMu past the peak (a drop-off). Verify with an F10 recording.
-- Stock value is hardcoded (0); a script reload re-applies the current choice.

local M = {}

local CV = "mh.tire.useSlidingMuClamp"
local enabled = false   -- off by default: compare stock plateau vs clamp by pressing Ctrl+F3

local function valid(o) return o ~= nil and o:IsValid() end
local function ksl() return StaticFindObject("/Script/Engine.Default__KismetSystemLibrary") end

function M.apply(pc, log)
    if not valid(pc) then return false end
    ksl():ExecuteConsoleCommand(pc, string.format("%s %d", CV, enabled and 1 or 0), pc)
    if log then log("tyre drop-off (%s) %s: cvar now %s", CV, enabled and "ON" or "off (stock)", tostring(ksl():GetConsoleVariableFloatValue(CV))) end
    return true
end

local applied = false
function M.ensure(pc, log) if not applied then applied = M.apply(pc, log) end end

function M.toggle(pc, log)
    enabled = not enabled
    M.apply(pc, log)
end

function M.label() return string.format("drop-off %s (Ctrl+F3)", enabled and "ON" or "off") end

return M
