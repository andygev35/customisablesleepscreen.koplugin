-- Full-screen e-ink flash used to clear ghosting before the sleep screen and
-- the lock screen are drawn.
--
-- Modes:
--   "cycle"  white -> black -> white. Drives every pixel to both extremes and
--            back, which is what actually resets the panel. This is the default.
--   "black"  a single black flash.
--   "white"  a single white flash.

local Blitbuffer = require("ffi/blitbuffer")
local Device     = require("device")
local ffiutil    = require("ffi/util")

local Screen = Device.screen

local M = {}

local SEQUENCES = {
    cycle = { "white", "black", "white" },
    black = { "black" },
    white = { "white" },
}

-- Short pause between flashes. On MXCFB devices (Kobo, Kindle) refreshFull()
-- already blocks until the panel has finished, so this only matters for other
-- framebuffer backends that return early.
local SETTLE_US = 100 * 1000

-- Anything other than an explicit "black" or "white" (including an unset
-- setting) means the full cycle.
function M.resolveMode(value)
    if value == "black" or value == "white" then return value end
    return "cycle"
end

-- Returns true if the screen was flashed.
function M.flash(mode)
    local flashed = false
    pcall(function()
        if not Device:hasEinkScreen() then return end
        local sequence = SEQUENCES[M.resolveMode(mode)]
        for i, colour in ipairs(sequence) do
            Screen.bb:fill(colour == "white" and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK)
            Screen:refreshFull(0, 0, Screen:getWidth(), Screen:getHeight())
            flashed = true
            if i < #sequence then ffiutil.usleep(SETTLE_US) end
        end
    end)
    return flashed
end

return M
