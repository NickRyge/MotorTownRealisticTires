-- Repeating work on the game thread. LoopAsync runs its callback on UE4SS's async thread, and Lua running there while
-- the game thread runs Lua too (the per-frame traction control) races on the shared Lua state: two UE4SS crashes
-- (abort / access violation inside the Lua runtime, 2026-10-02). LoopInGameThreadWithDelay / AfterFrames keep all of
-- it on the game thread. fn returns true to stop, like LoopAsync.

local M = {}

local function cancel(handle) if handle then pcall(CancelDelayedAction, handle) end end

local function run(starter, n, fn)
    local handle
    handle = starter(n, function()
        local ok, stop = pcall(fn)
        if ok and stop == true then cancel(handle) end
    end)
    return handle
end

-- Every `ms` milliseconds.
function M.every(ms, fn)
    if type(LoopInGameThreadWithDelay) == "function" then return run(LoopInGameThreadWithDelay, ms, fn), "game thread" end
    LoopAsync(ms, function()
        local stop = false
        ExecuteInGameThread(function() local ok, s = pcall(fn); if ok and s == true then stop = true end end)
        return stop
    end)
    return nil, "async fallback"
end

-- Every `frames` frames (needs UE4SS's EngineTick hook). Returns nil when unavailable.
function M.frames(frames, fn)
    if type(LoopInGameThreadAfterFrames) ~= "function" then return nil end
    local ok, h = pcall(run, LoopInGameThreadAfterFrames, frames, fn)
    if ok then return h, "every frame" end
end

return M
