local mp = require 'mp'
local utils = require 'mp.utils'
local msg = require 'mp.msg'

local dir = mp.command_native({"expand-path", "~~/colors"})
local profiles = {}
local index = 1

local function scan_profiles()
    profiles = {}

    local files = utils.readdir(dir, "files")
    if not files then
        msg.warn("Could not read directory: " .. dir)
        return
    end

    for _, file in ipairs(files) do
        if file:match("%.icm$") then
            table.insert(profiles, utils.join_path(dir, file))
        end
    end

    local function sort(a, b)
        return a:lower() < b:lower()
    end    

    table.sort(profiles, sort)
end

scan_profiles()

local function apply_profile(profile)
    mp.set_property("icc-profile", profile)

    local name = profile:match("^.+[/\\](.-)$") or profile
    mp.osd_message(name, 3)
end

local function next_profile()
    if #profiles == 0 then
        mp.osd_message("No ICC profiles found!")
        return
    end

    index = index + 1
    if index > #profiles then
        index = 1
    end

    apply_profile(profiles[index])
end

mp.add_key_binding("Ctrl+i", "next-icc", next_profile)