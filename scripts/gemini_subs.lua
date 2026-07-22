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
    show_original = false,      -- when translating, also show the original line
    chunk_seconds = 30,
    overlap_seconds = 5,        -- extra audio sent on each side so boundary sentences aren't split
    thinking_budget = 0,        -- 0 = no thinking (fastest); -1 = don't send the setting
    ffmpeg_path = "ffmpeg",
    curl_path = "curl",
    font_size = 40,
}

local state = {
    enabled = false,
    generation = 0,             -- bumped on file change; stale callbacks are ignored
    path = nil,
    cues = {},                  -- { start=, stop=, text=, translation= } absolute times
    chunks = {},                -- [index] = { status = "pending"|"done"|"failed", s=, e=, fails=, retry_at= }
    inflight = 0,
    backoff_until = 0,
    last_ass = nil,
    models = {},                -- o.model followed by o.fallback_models
    model_idx = 1,
}

local OWN_TOLERANCE = 1.0      -- seconds a cue may start outside its chunk and still be kept

local tmpdir = os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp"
local session_id = tostring(os.time()) .. "_" .. tostring(math.random(100000, 999999))
local overlay = mp.create_osd_overlay("ass-events")

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

-- Accepts "MM:SS.mmm", "HH:MM:SS.mmm", "SS.mmm", "MM:SS,mmm" or a number.
local function parse_ts(s)
    if type(s) == "number" then return s end
    if type(s) ~= "string" then return nil end
    s = s:gsub(",", "."):gsub("%s", "")
    local t, count = 0, 0
    for part in s:gmatch("[^:]+") do
        local v = tonumber(part)
        if not v then return nil end
        t = t * 60 + v
        count = count + 1
    end
    if count == 0 then return nil end
    return t
end

local function ass_escape(s)
    s = s:gsub("\\", "\\\239\187\191"):gsub("{", "\\{")
    return (s:gsub("\r?\n", "\\N"))
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
-- subtitle output

local function display_text(cue)
    if o.target_lang ~= "" and cue.translation and cue.translation ~= "" then
        if o.show_original then
            return ass_escape(cue.translation) .. "\\N{\\fscx80\\fscy80\\1c&HC8C8C8&}"
                .. ass_escape(cue.text)
        end
        return ass_escape(cue.translation)
    end
    return ass_escape(cue.text)
end

local function chunk_index(t)
    return math.floor(t / o.chunk_seconds)
end

local function render()
    if not state.enabled then
        if state.last_ass then
            overlay:remove()
            state.last_ass = nil
        end
        return
    end
    local pos = mp.get_property_number("time-pos")
    if not pos then return end

    local lines = {}
    for _, cue in ipairs(state.cues) do
        if cue.start > pos then break end
        if pos < cue.stop then lines[#lines + 1] = display_text(cue) end
    end

    local style = string.format("{\\an2\\fs%d\\bord2.5\\shad1\\1c&HFFFFFF&\\3c&H000000&}", o.font_size)
    local events = {}
    if #lines > 0 then
        -- keep at most the two newest overlapping cues
        local from = math.max(1, #lines - 1)
        events[#events + 1] = style .. table.concat(lines, "\\N", from)
    end
    local c = state.chunks[chunk_index(pos)]
    if not c or c.status ~= "done" then
        events[#events + 1] = "{\\an9\\fs18\\bord1.5\\1c&HB0E0FF&}Gemini: transcribing..."
    end

    local ass = table.concat(events, "\n")
    if ass ~= state.last_ass then
        overlay.data = ass
        overlay:update()
        state.last_ass = ass
    end
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

local function extract_json_array(text)
    local arr = utils.parse_json(text)
    if type(arr) == "table" then return arr end
    local s, e = text:find("%[.*%]")
    if s then return utils.parse_json(text:sub(s, e)) end
    return nil
end

local function chunk_done(i, cues)
    local c = state.chunks[i]
    c.status = "done"
    state.inflight = state.inflight - 1
    add_cues(cues, c.s, c.e)
end

local function chunk_failed(i, err, opts)
    opts = opts or {}
    local c = state.chunks[i]
    c.status = "failed"
    if not opts.no_count then c.fails = c.fails + 1 end
    c.retry_at = mp.get_time() + (opts.delay or 5)
    state.inflight = state.inflight - 1
    msg.error(string.format("chunk %d: %s", i, err))
    if not opts.quiet then osd(err, 5) end
end

-- A 429 can mean "too many per minute" (wait) or "daily quota used up" (switch model).
local function is_daily_quota(resp)
    local err = resp.error or {}
    for _, d in ipairs(err.details or {}) do
        for _, v in ipairs(d.violations or {}) do
            if tostring(v.quotaId or ""):find("PerDay") then return true end
        end
    end
    local m = (err.message or ""):lower()
    return m:find("per day") ~= nil or m:find("perday") ~= nil
end

local function fatal(i, err)
    chunk_failed(i, err)
    state.chunks[i].fails = 99
    state.enabled = false
    render()
    osd(err .. " — disabled", 8)
end

local function handle_response(i, start, len, res, model)
    local out = res.stdout or ""
    local body, code = out:match("^(.*)\n__HTTP_STATUS__(%d+)%s*$")
    code = tonumber(code)
    if not code then
        return chunk_failed(i, "curl failed: " .. ((res.stderr or ""):gsub("%s+$", "")))
    end
    local resp = utils.parse_json(body) or {}

    if code ~= 200 then
        local emsg = (resp.error and resp.error.message) or ("HTTP " .. code)
        if code == 429 and is_daily_quota(resp) then
            -- several in-flight requests may report this; only the first one switches
            if model == current_model() then
                if state.model_idx >= #state.models then
                    return fatal(i, "daily quota used up for " .. table.concat(state.models, ", "))
                end
                state.model_idx = state.model_idx + 1
                osd(string.format("daily quota used up for %s, switching to %s", model, current_model()), 6)
            end
            return chunk_failed(i, "daily quota used up for " .. model,
                { delay = 0, no_count = true, quiet = true })
        elseif code == 429 then
            local delay = 30
            for _, d in ipairs(resp.error and resp.error.details or {}) do
                local s = d.retryDelay and tonumber(tostring(d.retryDelay):match("[%d.]+"))
                if s then delay = s + 1 end
            end
            state.backoff_until = mp.get_time() + delay
            return chunk_failed(i, string.format("rate limited, retrying in %ds", delay),
                { delay = delay, no_count = true })
        elseif code >= 500 then
            return chunk_failed(i, "server error (" .. code .. "), retrying", { delay = 10 })
        end
        return fatal(i, emsg:sub(1, 200))
    end

    local text = {}
    local cand = resp.candidates and resp.candidates[1]
    for _, part in ipairs(cand and cand.content and cand.content.parts or {}) do
        if part.text and not part.thought then text[#text + 1] = part.text end
    end
    text = table.concat(text)
    if text == "" then
        local reason = (cand and cand.finishReason)
            or (resp.promptFeedback and resp.promptFeedback.blockReason) or "empty response"
        return chunk_failed(i, "no transcript (" .. tostring(reason) .. ")")
    end

    local arr = extract_json_array(text)
    if type(arr) ~= "table" then
        return chunk_failed(i, "could not parse response JSON")
    end

    -- keep cues starting inside this chunk's own range; the tolerance lets a
    -- boundary cue survive if both neighbours time it slightly differently
    -- (add_cues drops the resulting duplicate)
    local chunk = state.chunks[i]
    local own_from, own_to = chunk.s - OWN_TOLERANCE, chunk.e + OWN_TOLERANCE
    if chunk.s <= 0 then own_from = -math.huge end

    local cues = {}
    for _, item in ipairs(arr) do
        local s, e = parse_ts(item.start), parse_ts(item["end"])
        local t = type(item.text) == "string" and item.text:gsub("^%s+", ""):gsub("%s+$", "") or ""
        if s and t ~= "" and s <= len + 1 and start + s >= own_from and start + s < own_to then
            s = math.max(0, s)
            if not e or e <= s then e = s + 2 end
            e = math.min(e, len + 0.5)
            cues[#cues + 1] = {
                start = start + s,
                stop = start + e,
                text = t,
                translation = type(item.translation) == "string" and item.translation or nil,
            }
        end
    end
    msg.info(string.format("chunk %d (%.0fs-%.0fs, clip %.0fs-%.0fs): %d cues",
        i, chunk.s, chunk.e, start, start + len, #cues))
    chunk_done(i, cues)
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

-------------------------------------------------------------------------------
-- chunk pipeline

-- state.source = { input = <file or stream url>, map = <ffmpeg -map>, pre = { ffmpeg input options } }

local function local_source()
    local track = mp.get_property_native("current-tracks/audio")
    if track and track.external and track["external-filename"] then
        return { input = track["external-filename"], map = "0:a:0", pre = {} }
    end
    if track and track["ff-index"] then
        return { input = state.path, map = "0:" .. track["ff-index"], pre = {} }
    end
    return { input = state.path, map = "0:a:0?", pre = {} }
end

local function chunk_bounds(i)
    local s = i * o.chunk_seconds
    local e = s + o.chunk_seconds
    local dur = mp.get_property_number("duration")
    if dur then e = math.min(e, dur) end
    return s, e
end

local function process_chunk(i)
    local gen = state.generation
    local s, e = chunk_bounds(i)
    local c = state.chunks[i] or { fails = 0 }
    c.status, c.s, c.e = "pending", s, e
    state.chunks[i] = c
    state.inflight = state.inflight + 1

    -- The clip sent to Gemini overlaps its neighbours, so sentences crossing a
    -- chunk boundary are heard in full; handle_response keeps only the cues
    -- that start inside [s, e).
    local start = math.max(0, s - o.overlap_seconds)
    local stop = e + o.overlap_seconds
    local dur = mp.get_property_number("duration")
    if dur then stop = math.min(stop, dur) end
    local len = stop - start

    local src = state.source
    local audio_file = utils.join_path(tmpdir, string.format("gemini_subs_%s_%d.mp3", session_id, i))
    local args = { o.ffmpeg_path, "-nostdin", "-hide_banner", "-loglevel", "error", "-y" }
    for _, a in ipairs(src.pre) do args[#args + 1] = a end
    for _, a in ipairs({
        "-ss", string.format("%.3f", start), "-t", string.format("%.3f", len),
        "-i", src.input, "-map", src.map, "-vn", "-sn", "-dn",
        "-ac", "1", "-ar", "16000", "-c:a", "libmp3lame", "-b:a", "32k",
        audio_file,
    }) do args[#args + 1] = a end

    run(args, function(ok, res, err)
        if gen ~= state.generation then
            os.remove(audio_file)
            return
        end
        if not ok then
            local detail = (res.stderr or err or ""):gsub("%s+$", "")
            if res.error_string == "init" then detail = "ffmpeg not found (set ffmpeg_path)" end
            -- stream URLs expire after a few hours; fetch a fresh one on retry
            if src.remote and state.source == src then state.source = nil end
            if src.ytdl and detail:find("403") then
                detail = "stream refused (403) — yt-dlp is probably outdated, run: yt-dlp -U"
            end
            return chunk_failed(i, "ffmpeg: " .. detail:sub(1, 200))
        end
        request_gemini(i, start, len, audio_file, gen)
    end)
end

mp.observe_property("time-pos", "number", render)
