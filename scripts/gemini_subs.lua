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
    model = "gemini-2.5-flash",
    fallback_models = "gemini-2.5-flash-lite", -- comma-separated, used in order once a model's daily quota is used up
    target_lang = "",           -- e.g. "English", "Vietnamese"; empty = no translation
    source_lang = "",           -- optional hint, e.g. "Japanese"; empty = auto-detect
    thinking_budget = 0,        -- 0 = no thinking (fastest); -1 = don't send the setting
    curl_path = "curl",
}

local state = {
    enabled = false,
    generation = 0,             -- bumped on file change; stale callbacks are ignored
    path = nil,
    cues = {},                  -- { start=, stop=, text=, translation= } absolute times
    models = {},                -- o.model followed by o.fallback_models
    model_idx = 1,
}

local tmpdir = os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp"
local session_id = tostring(os.time()) .. "_" .. tostring(math.random(100000, 999999))

-------------------------------------------------------------------------------
-- helpers

local B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local b64lut = {}
for i = 1, 64 do b64lut[i - 1] = B64:sub(i, i) end

local function base64(data)
    local out, n = {}, #data
    local floor = math.floor
    for i = 1, n - 2, 3 do
        local a, b, c = data:byte(i, i + 2)
        local v = a * 65536 + b * 256 + c
        out[#out + 1] = b64lut[floor(v / 262144)] .. b64lut[floor(v / 4096) % 64]
            .. b64lut[floor(v / 64) % 64] .. b64lut[v % 64]
    end
    local rem = n % 3
    if rem == 1 then
        local v = data:byte(n) * 65536
        out[#out + 1] = b64lut[floor(v / 262144)] .. b64lut[floor(v / 4096) % 64] .. "=="
    elseif rem == 2 then
        local a, b = data:byte(n - 1, n)
        local v = a * 65536 + b * 256
        out[#out + 1] = b64lut[floor(v / 262144)] .. b64lut[floor(v / 4096) % 64]
            .. b64lut[floor(v / 64) % 64] .. "="
    end
    return table.concat(out)
end

local function json_str(s)
    return utils.format_json(s)
end

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

local function build_model_list()
    state.models = { o.model }
    for m in o.fallback_models:gmatch("[^,%s]+") do
        if m ~= o.model then state.models[#state.models + 1] = m end
    end
    state.model_idx = 1
end

local function current_model()
    return state.models[state.model_idx]
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

-------------------------------------------------------------------------------
-- gemini request

local function build_prompt(len)
    local p = {
        string.format("You are a professional subtitler. Transcribe all spoken dialogue in this %d-second audio clip.", math.floor(len + 0.5)),
    }
    if o.source_lang ~= "" then
        p[#p + 1] = "The spoken language is " .. o.source_lang .. "."
    end
    p[#p + 1] = [[
Rules:
- Return a JSON array of subtitle cues in chronological order.
- "start" and "end" are timestamps relative to the beginning of THIS clip, formatted MM:SS.mmm (e.g. 00:07.250). They must never exceed the clip length.
- Timestamps must match exactly when the words are spoken.
- Each cue is one sentence or phrase: at most 2 short lines (~80 characters), 1-7 seconds long. Split long speech at natural pauses.
- "text" is the verbatim transcription in the original language. Omit music, sound effects and filler noises.
- The clip may start or end mid-sentence; transcribe what is audible.
- If there is no speech, return an empty array [].]]
    if o.target_lang ~= "" then
        p[#p + 1] = "- \"translation\" is a natural, fluent " .. o.target_lang
            .. " translation of that cue's text, suitable for subtitles."
    end
    return table.concat(p, "\n")
end

local function build_body(audio_b64, len)
    local translate = o.target_lang ~= ""
    local props = '"start":{"type":"STRING"},"end":{"type":"STRING"},"text":{"type":"STRING"}'
    local required = '"start","end","text"'
    if translate then
        props = props .. ',"translation":{"type":"STRING"}'
        required = required .. ',"translation"'
    end
    local schema = '{"type":"ARRAY","items":{"type":"OBJECT","properties":{' .. props
        .. '},"required":[' .. required .. '],"propertyOrdering":[' .. required .. ']}}'

    local gen = '"temperature":0,"responseMimeType":"application/json","responseSchema":' .. schema
    if o.thinking_budget >= 0 then
        gen = gen .. ',"thinkingConfig":{"thinkingBudget":' .. string.format("%d", o.thinking_budget) .. '}'
    end

    return '{"contents":[{"parts":[{"inline_data":{"mime_type":"audio/mp3","data":"'
        .. audio_b64 .. '"}},{"text":' .. json_str(build_prompt(len)) .. '}]}],'
        .. '"generationConfig":{' .. gen .. '}}'
end

local function request_gemini(i, start, len, audio_file, gen)
    local data = read_file(audio_file)
    os.remove(audio_file)
    if not data or #data == 0 then
        return chunk_failed(i, "ffmpeg produced no audio")
    end

    local req_file = utils.join_path(tmpdir, string.format("gemini_subs_%s_%d.json", session_id, i))
    if not write_file(req_file, build_body(base64(data), len)) then
        return chunk_failed(i, "could not write " .. req_file)
    end

    local model = current_model()
    local url = "https://generativelanguage.googleapis.com/v1beta/models/" .. model .. ":generateContent"
    run({
        o.curl_path, "-sS", "--max-time", "180", "-X", "POST",
        "-H", "Content-Type: application/json",
        "-H", "x-goog-api-key: " .. api_key(),
        "--data-binary", "@" .. req_file,
        "-w", "\n__HTTP_STATUS__%{http_code}",
        url,
    }, function(_, res)
        os.remove(req_file)
        if gen ~= state.generation then return end
        handle_response(i, start, len, res, model)
    end)
end

