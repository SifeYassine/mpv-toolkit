-- touch_gestures.lua
-- Mouse wheel / touchpad gestures:
--   Ctrl + scroll up/down           resize the window (animated)
--
-- Touchpads send many small scroll events; resizing and seeking follow their
-- size, so they track the fingers.
--
-- Rebind in input.conf with script-binding touch_gestures/<name>.

local mp = require "mp"

local RESIZE_STEP = 0.05 -- window-scale change per full scroll step
local EASE = 0.6         -- part of the remaining resize done each frame

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

local function bind(key, name, fn)
  mp.add_key_binding(key, name, function(e)
    if e.event ~= "up" then fn(e.scale or 1) end
  end, {complex = true, scalable = true})
end

-- replaces mpv's default Ctrl+scroll video zoom
bind("Ctrl+WHEEL_UP", "grow-window", function(s) resize(s) end)
bind("Ctrl+WHEEL_DOWN", "shrink-window", function(s) resize(-s) end)
