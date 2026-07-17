-- gemini_subs.lua
-- AI subtitles for mpv: cuts the audio ahead of the playback position into
-- chunks, sends each chunk to the Gemini API for transcription (and optional
-- translation), and draws the result as subtitles on the OSD.
--
-- Requires: ffmpeg and curl on PATH (or set ffmpeg_path / curl_path).
-- Config:   script-opts/gemini_subs.conf
-- Toggle:   ctrl+g (or bind `script-binding gemini_subs/toggle`)

local mp = require 'mp'
local msg = require 'mp.msg'
local utils = require 'mp.utils'
local options = require 'mp.options'

local o = {
    api_key = "",               -- falls back to the GEMINI_API_KEY env variable
}

local state = {
    enabled = false,
    generation = 0,             -- bumped on file change; stale callbacks are ignored
    path = nil,
    cues = {},                  -- { start=, stop=, text=, translation= } absolute times
}

-------------------------------------------------------------------------------
-- helpers

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

local function write_file(path, data)
    local f = io.open(path, "wb")
    if not f then return false end
    f:write(data)
    f:close()
    return true
end

local function is_url(path)
    return path:find("^%a[%w+.-]*://") ~= nil
end

local function api_key()
    if o.api_key ~= "" then return o.api_key end
    return os.getenv("GEMINI_API_KEY") or ""
end

local function osd(text, secs)
    mp.osd_message("Gemini subs: " .. text, secs or 3)
end

local function run(args, cb)
    mp.command_native_async({
        name = "subprocess",
        args = args,
        capture_stdout = true,
        capture_stderr = true,
        playback_only = false,
    }, function(success, res, err)
        res = res or {}
        cb(success and res.status == 0, res, err)
    end)
end

