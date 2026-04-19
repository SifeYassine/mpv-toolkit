local mp = require "mp"

local state = false
local shader = "~~/shaders/hflip.glsl"

local function toggle()
    state = not state

    if state then
        mp.command("change-list glsl-shaders append " .. shader)
        mp.osd_message("hflip: On")
    else
        mp.command("change-list glsl-shaders remove " .. shader)
        mp.osd_message("hflip: Off")
    end
end

mp.register_script_message("hflip_toggle", toggle)