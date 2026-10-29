-- touch_gestures.lua
-- Mouse wheel / touchpad gestures:
--   Ctrl + scroll up/down           resize the window (animated)
--   two-finger swipe left/right     seek forward/back
--   Ctrl + two-finger swipe         next/previous video (once per swipe)
--
-- Touchpads send many small scroll events; resizing and seeking follow their
-- size, so they track the fingers.
--
-- Rebind in input.conf with script-binding touch_gestures/<name>.

local mp = require "mp"

local RESIZE_STEP = 0.05 -- window-scale change per full scroll step
local EASE = 0.6         -- part of the remaining resize done each frame
local SEEK_STEP = 5      -- seconds per full scroll step
local QUIET = 0.4        -- seconds without events that end a swipe

-- Window resize: scrolling moves a target size, a 60 fps timer eases the
-- window towards it.
local size, target
local anim
anim = mp.add_periodic_timer(1 / 60, function()
  size = size + (target - size) * EASE
  if math.abs(target - size) < 0.001 then
    size = target
    anim:kill()
  end
  mp.set_property_number("window-scale", size)
end)
anim:kill()

local function resize(amount)
  if not anim:is_enabled() then
    -- the window's real scale: window-scale stays 1 when autofit sized it
    size = mp.get_property_number("current-window-scale") or
      mp.get_property_number("window-scale", 1)
    target = size
    anim:resume()
  end
  target = math.max(0.1, target + RESIZE_STEP * amount)
end

-- A swipe sends a burst of wheel events; act on the first one only, and again
-- once the touchpad has been quiet for QUIET seconds.
local quiet = mp.add_timeout(QUIET, function() end)
quiet:kill()

local function once_per_swipe(command)
  return function()
    if not quiet:is_enabled() then mp.command(command) end
    quiet:kill()
    quiet:resume()
  end
end

local function bind(key, name, fn)
  mp.add_key_binding(key, name, function(e)
    if e.event ~= "up" then fn(e.scale or 1) end
  end, {complex = true, scalable = true})
end

-- replaces mpv's default Ctrl+scroll video zoom
bind("Ctrl+WHEEL_UP", "grow-window", function(s) resize(s) end)
bind("Ctrl+WHEEL_DOWN", "shrink-window", function(s) resize(-s) end)
bind("WHEEL_LEFT", "seek-forward", function(s) mp.commandv("seek", SEEK_STEP * s) end)
bind("WHEEL_RIGHT", "seek-back", function(s) mp.commandv("seek", -SEEK_STEP * s) end)
bind("Ctrl+WHEEL_LEFT", "next", once_per_swipe("playlist-next"))
bind("Ctrl+WHEEL_RIGHT", "prev", once_per_swipe("playlist-prev"))
