-- cache_cleaner.lua
-- Fills material-osc's right-click menu with a submenu listing each sub-folder
-- inside ~~/cache.  Selecting an entry deletes all files in that folder.
--
-- input.conf entry required:
--   _   ignore   #menu: Tools > Cache Cleaner   #@cache_cleaner

local mp    = require 'mp'
local utils = require 'mp.utils'

local cache_dir = mp.command_native({"expand-path", "~~/cache"})

local MENU_SCRIPT    = 'material_osc'   -- updated to real name on menu-ready
local KEYWORD     = 'cache_cleaner'
local menu_ready   = false
local folder_list = {}           -- kept in sync so delete can address by index

-- ── helpers ──────────────────────────────────────────────────────────────────

local function get_folders()
    local dirs = utils.readdir(cache_dir, "dirs")
    if not dirs then return {} end
    table.sort(dirs)
    return dirs
end

-- ── menu builder ─────────────────────────────────────────────────────────────

local function push_menu()
    if not menu_ready then return end

    folder_list = get_folders()
    local submenu = {}

    if #folder_list == 0 then
        submenu[#submenu + 1] = { title = "No cache folders found", cmd = "ignore" }
    else
        for i, folder in ipairs(folder_list) do
            -- Count files so the user knows what they are about to delete.
            local files = utils.readdir(cache_dir .. "/" .. folder, "files") or {}
            local label = #files > 0
                and string.format("Clear: %s\t%d file(s)", folder, #files)
                or  string.format("Clear: %s\t(empty)", folder)

            submenu[#submenu + 1] = {
                title = label,
                -- Use index rather than folder name to avoid quoting problems.
                cmd   = "script-message cache_delete " .. tostring(i),
            }
        end
    end

    mp.commandv("script-message-to", MENU_SCRIPT, "update", KEYWORD,
        utils.format_json({
            type    = "submenu",
            title   = "Cache Cleaner",
            submenu = submenu,
        }))
end

-- ── script messages ──────────────────────────────────────────────────────────

mp.register_script_message("cache_delete", function(idx_str)
    local folder = folder_list[tonumber(idx_str)]
    if not folder then return end

    local full_path = cache_dir .. "/" .. folder
    local files     = utils.readdir(full_path, "files")

    if not files or #files == 0 then
        mp.osd_message("Nothing to delete in /" .. folder)
        push_menu()   -- refresh to show (empty) label
        return
    end

    local deleted, failed = 0, 0
    for _, file in ipairs(files) do
        local ok, err = os.remove(full_path .. "/" .. file)
        if ok then
            deleted = deleted + 1
        else
            failed = failed + 1
            mp.msg.warn("Failed to delete " .. file .. ": " .. tostring(err))
        end
    end

    if failed > 0 then
        mp.osd_message(string.format("Deleted %d file(s) from /%s  (%d failed)", deleted, folder, failed))
    else
        mp.osd_message(string.format("Deleted %d file(s) from /%s", deleted, folder))
    end

    push_menu()   -- refresh the menu so file counts update
end)

-- ── initialisation ───────────────────────────────────────────────────────────

mp.register_script_message("menu-ready", function(name)
    MENU_SCRIPT  = name
    menu_ready = true
    push_menu()
end)