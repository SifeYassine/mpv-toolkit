-- Permanently delete the currently playing file (Shift+Del).
-- The file is unloaded first (skips to next playlist entry), then deleted.
local utils = require "mp.utils"

local pending = nil

mp.register_event("end-file", function()
    if not pending then return end
    local path = pending
    pending = nil
    local ok, err = os.remove(path)
    if ok then
        mp.osd_message("Deleted: " .. path, 3)
    else
        mp.osd_message("Delete failed: " .. tostring(err), 5)
    end
end)

mp.add_key_binding("Shift+DEL", "delete-current-file", function()
    local path = mp.get_property("path")
    if not path or path:find("://") then
        mp.osd_message("Nothing deletable is playing")
        return
    end
    pending = utils.join_path(mp.get_property("working-directory"), path)
    mp.commandv("playlist-remove", "current")
end)
