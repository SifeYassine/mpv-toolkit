-- smart_skip.lua
-- Finds the opening and ending of episodes that carry no chapters, shows them
-- as "Opening"/"Ending" chapters and skips them.
--
-- The audio at the start and end of the file is fingerprinted (Haitsma-Kalker
-- style, 33 bands 300-2000 Hz, ~93 ms steps) and compared with other episodes
-- of the same show: files in the same folder, episodes played earlier (their
-- fingerprints stay cached after the files are deleted), and a library of
-- openings/endings already found. Audio two episodes share is the
-- opening/ending.

local mp = require "mp"
local msg = require "mp.msg"
local utils = require "mp.utils"
local options = require "mp.options"
local ffi = require "ffi"
local bit = require "bit"

local band, bor, bxor, lshift, rshift = bit.band, bit.bor, bit.bxor, bit.lshift, bit.rshift

local o = {
  min_name_similarity = 0.5,
  ffmpeg_path = "",
  ffprobe_path = "",
}
options.read_options(o, "smart_skip")

-------------------------------------------------------------------------------
-- fingerprinting

local SR, N, HOP = 5512, 2048, 512 -- 371 ms frames every 93 ms
local LOG2N = 11
local NB = 33                       -- bands -> 32 bit hashes
local F_LO, F_HI = 300, 2000
local FPS = SR / HOP
local SILENT_MS = 1e-6              -- frame mean square below -60 dBFS
local MATCH_BITS = 10               -- matching frame: <= 10 of 32 bits differ
local HALF_W = 7                    -- run detection window: 15 frames (1.4 s)
local GAP_FRAMES = 20               -- merge runs split by < 1.9 s
local STOP_LIST = 24                -- ignore hash keys this common
local MIN_VOTES = 4
local MAX_PEAKS = 10
local FP_MAGIC = "SSF1"

local rev = ffi.new("int32_t[?]", N)
for i = 0, N - 1 do
  local r, x = 0, i
  for _ = 1, LOG2N do
    r = r * 2 + x % 2
    x = math.floor(x / 2)
  end
  rev[i] = r
end
local tw_re, tw_im = ffi.new("double[?]", N / 2), ffi.new("double[?]", N / 2)
for i = 0, N / 2 - 1 do
  tw_re[i] = math.cos(2 * math.pi * i / N)
  tw_im[i] = -math.sin(2 * math.pi * i / N)
end
local win = ffi.new("double[?]", N)
for i = 0, N - 1 do
  win[i] = 0.5 - 0.5 * math.cos(2 * math.pi * i / (N - 1))
end
local bins = ffi.new("int32_t[?]", NB + 1)
for b = 0, NB do
  bins[b] = math.floor(F_LO * (F_HI / F_LO) ^ (b / NB) * N / SR + 0.5)
end
local PC = ffi.new("uint8_t[65536]")
for i = 1, 65535 do PC[i] = PC[rshift(i, 1)] + band(i, 1) end

local re, im = ffi.new("double[?]", N), ffi.new("double[?]", N)

local function fft()
  for i = 0, N - 1 do
    local j = rev[i]
    if j > i then
      re[i], re[j] = re[j], re[i]
      im[i], im[j] = im[j], im[i]
    end
  end
  local size = 2
  while size <= N do
    local half, step = size / 2, N / size
    for start = 0, N - 1, size do
      local k = 0
      for a = start, start + half - 1 do
        local b = a + half
        local wr, wi = tw_re[k], tw_im[k]
        local tr = re[b] * wr - im[b] * wi
        local ti = re[b] * wi + im[b] * wr
        re[b], im[b] = re[a] - tr, im[a] - ti
        re[a], im[a] = re[a] + tr, im[a] + ti
        k = k + step
      end
    end
    size = size * 2
  end
end

local function new_fp(n)
  return {
    n = n,
    h = ffi.new("int32_t[?]", math.max(n, 1)),
    s = ffi.new("uint8_t[?]", math.max(n, 1)),
  }
end

-- Hash i compares frame i with frame i-1; hash 0 has no predecessor and is
-- flagged silent so it never matches.
local function fingerprint(pcm)
  local ns = math.floor(#pcm / 2)
  local nf = ns >= N and math.floor((ns - N) / HOP) + 1 or 0
  local fp = new_fp(nf)
  if nf == 0 then return fp end
  local x = ffi.cast("const int16_t*", pcm)
  local ea, eb = ffi.new("double[?]", NB), ffi.new("double[?]", NB)
  local prev = ffi.new("double[?]", NB)
  local scale = 1 / (N * 32768 * 32768)

  local function emit(i, e, silent)
    if i > 0 then
      local h = 0
      for m = 0, NB - 2 do
        if (e[m] - e[m + 1]) - (prev[m] - prev[m + 1]) > 0 then
          h = bor(h, lshift(1, m))
        end
      end
      fp.h[i] = h
      fp.s[i] = silent and 1 or 0
    else
      fp.s[0] = 1
    end
    for m = 0, NB - 1 do prev[m] = e[m] end
  end

  -- Two real frames per complex FFT: frame f in re, frame f+1 in im.
  for f = 0, nf - 1, 2 do
    local g = f + 1
    local has_b = g < nf
    local oa, ob = f * HOP, g * HOP
    local sa, sb = 0, 0
    for k = 0, N - 1 do
      local va = x[oa + k]
      sa = sa + va * va
      re[k] = va * win[k]
      if has_b then
        local vb = x[ob + k]
        sb = sb + vb * vb
        im[k] = vb * win[k]
      else
        im[k] = 0
      end
    end
    fft()
    for b = 0, NB - 1 do
      local pa, pb = 0, 0
      for k = bins[b], bins[b + 1] - 1 do
        local zr, zi, zr2, zi2 = re[k], im[k], re[N - k], im[N - k]
        local ar, ai = zr + zr2, zi - zi2
        local br, bi = zi + zi2, zr - zr2
        pa = pa + ar * ar + ai * ai
        pb = pb + br * br + bi * bi
      end
      ea[b], eb[b] = pa, pb
    end
    emit(f, ea, sa * scale < SILENT_MS)
    if has_b then emit(g, eb, sb * scale < SILENT_MS) end
  end
  return fp
end

-------------------------------------------------------------------------------
-- matching

-- 1 = match, 2 = both silent (neutral), 0 = mismatch
local function frame_state(A, i, B, j)
  local as, bs = A.s[i], B.s[j]
  if as == 1 or bs == 1 then
    return (as == 1 and bs == 1) and 2 or 0
  end
  local x = bxor(A.h[i], B.h[j])
  return (PC[band(x, 0xFFFF)] + PC[rshift(x, 16)] <= MATCH_BITS) and 1 or 0
end

-- Matching runs of A against B at offset off (A index = B index + off).
local function runs_at(A, B, off)
  local i0 = math.max(1, off + 1)
  local i1 = math.min(A.n - 1, off + B.n - 1)
  local len = i1 - i0 + 1
  local runs, total = {}, 0
  if len < 2 * HALF_W + 1 then return runs, 0 end
  local st = ffi.new("uint8_t[?]", len)
  local cs = ffi.new("int32_t[?]", len + 1)
  for p = 0, len - 1 do
    local s = frame_state(A, i0 + p, B, i0 + p - off)
    st[p] = s
    cs[p + 1] = cs[p] + (s > 0 and 1 or 0)
    if s == 1 then total = total + 1 end
  end

  local function close(seg_s, seg_e)
    local lo = math.max(0, seg_s - HALF_W)
    local hi = math.min(len - 1, seg_e + HALF_W)
    -- trim to edges that look like real matches, not stray random hits
    local s, e = lo, hi
    while s < hi and not (st[s] == 1 and st[s + 1] > 0) do s = s + 1 end
    while e > s and not (st[e] == 1 and st[e - 1] > 0) do e = e - 1 end
    if e <= s then return end
    -- silence both files share at the edges belongs to the segment
    while s > 0 and st[s - 1] == 2 do s = s - 1 end
    while e < len - 1 and st[e + 1] == 2 do e = e + 1 end
    local ev = 0
    for p = s, e do if st[p] == 1 then ev = ev + 1 end end
    if ev * 2 >= e - s + 1 then
      runs[#runs + 1] = {a_s = i0 + s, a_e = i0 + e,
        b_s = i0 + s - off, b_e = i0 + e - off}
    end
  end

  local seg_s, seg_e
  for p = 0, len - 1 do
    local lo, hi = math.max(0, p - HALF_W), math.min(len - 1, p + HALF_W)
    if (cs[hi + 1] - cs[lo]) * 2 >= hi - lo + 1 then
      if seg_e and p - seg_e <= GAP_FRAMES then
        seg_e = p
      else
        if seg_s then close(seg_s, seg_e) end
        seg_s, seg_e = p, p
      end
    end
  end
  if seg_s then close(seg_s, seg_e) end
  return runs, total
end

-- Offsets voted for by exact matches of either 16-bit half of the hashes are
-- verified frame by frame.
local function find_runs(A, B)
  local n, m = A.n, B.n
  if n < 20 or m < 20 then return {} end
  local idx = {}
  for j = 1, m - 1 do
    if B.s[j] == 0 then
      local h = B.h[j]
      for _, k in ipairs({rshift(h, 16), band(h, 0xFFFF) + 65536}) do
        local l = idx[k]
        if l then l[#l + 1] = j else idx[k] = {j} end
      end
    end
  end
  local votes = ffi.new("int32_t[?]", n + m + 2)
  for i = 1, n - 1 do
    if A.s[i] == 0 then
      local h = A.h[i]
      for _, k in ipairs({rshift(h, 16), band(h, 0xFFFF) + 65536}) do
        local l = idx[k]
        if l and #l <= STOP_LIST then
          for t = 1, #l do
            local v = i - l[t] + m
            votes[v] = votes[v] + 1
          end
        end
      end
    end
  end

  local cand = {}
  for k = 1, n + m do
    local v = votes[k - 1] + votes[k] + votes[k + 1]
    if v >= MIN_VOTES then cand[#cand + 1] = {k = k, v = v} end
  end
  table.sort(cand, function(a, b) return a.v > b.v end)
  local peaks = {}
  for _, c in ipairs(cand) do
    local ok = true
    for _, p in ipairs(peaks) do
      if math.abs(p - c.k) <= 3 then ok = false break end
    end
    if ok then
      peaks[#peaks + 1] = c.k
      if #peaks >= MAX_PEAKS then break end
    end
  end

  local all = {}
  for _, k in ipairs(peaks) do
    local best, best_total = nil, -1
    for d = -1, 1 do
      local runs, total = runs_at(A, B, k - m + d)
      if total > best_total then best, best_total = runs, total end
    end
    for _, r in ipairs(best) do all[#all + 1] = r end
  end
  return all
end

-- time span covered by hashes a..b of a window starting at t0
local function span(t0, a, b)
  return t0 + ((a - 1) * HOP + N / 2) / SR, t0 + (b * HOP + N / 2) / SR
end

-------------------------------------------------------------------------------
-- storage

local cache_dir = mp.command_native({"expand-path", "~~/cache/smart_skip"})
local index_path = utils.join_path(cache_dir, "index.json")
local index = {v = 1, files = {}, library = {}}

local function cache_path(name) return utils.join_path(cache_dir, name) end

local function ensure_cache_dir()
  if utils.file_info(cache_dir) then return end
  local args = package.config:sub(1, 1) == "\\" and
    {"cmd", "/d", "/c", "mkdir", (cache_dir:gsub("/", "\\"))} or
    {"mkdir", "-p", cache_dir}
  mp.command_native({name = "subprocess", args = args, playback_only = false,
    capture_stdout = true, capture_stderr = true})
end

local function load_index()
  local f = io.open(index_path, "rb")
  if not f then return end
  local data = utils.parse_json(f:read("*a") or "")
  f:close()
  if type(data) == "table" and data.v == 1 then
    index = data
    if type(index.files) ~= "table" then index.files = {} end
    if type(index.library) ~= "table" then index.library = {} end
  end
end

local function save_index()
  ensure_cache_dir()
  local json = utils.format_json(index)
  if not json then return end
  local tmp = index_path .. ".tmp"
  local f = io.open(tmp, "wb")
  if not f then return end
  f:write(json)
  f:close()
  os.remove(index_path)
  os.rename(tmp, index_path)
end

local function save_fp(file, fp)
  ensure_cache_dir()
  local f = io.open(file, "wb")
  if not f then return false end
  local n = ffi.new("int32_t[1]", fp.n)
  f:write(FP_MAGIC, ffi.string(n, 4), ffi.string(fp.h, 4 * fp.n),
    ffi.string(fp.s, fp.n))
  f:close()
  return true
end

local function load_fp(file)
  local f = io.open(file, "rb")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  if not data or #data < 8 or data:sub(1, 4) ~= FP_MAGIC then return nil end
  local p = ffi.cast("const uint8_t*", data)
  local n = ffi.cast("const int32_t*", p + 4)[0]
  if n < 0 or #data ~= 8 + 5 * n then return nil end
  local fp = new_fp(n)
  ffi.copy(fp.h, p + 8, 4 * n)
  ffi.copy(fp.s, p + 8 + 4 * n, n)
  return fp
end

local function hash_id(str)
  -- two 32 bit FNV-1a variants; the multiplications are shift-adds so no
  -- precision is lost in doubles
  local h1, h2 = bit.tobit(0x811C9DC5), 0x1B873593
  for i = 1, #str do
    local c = str:byte(i)
    h1 = bxor(h1, c)
    h1 = bit.tobit(h1 + lshift(h1, 1) + lshift(h1, 4) + lshift(h1, 7) +
      lshift(h1, 8) + lshift(h1, 24))
    h2 = bxor(h2, c + i)
    h2 = bit.tobit(h2 + lshift(h2, 5) + lshift(h2, 13) + rshift(h2, 7))
  end
  return bit.tohex(h1) .. bit.tohex(h2)
end

local function file_id(path, info)
  local norm = mp.command_native({"normalize-path", path}) or path
  return hash_id(norm:lower() .. "|" .. tostring(info.size))
end

-------------------------------------------------------------------------------
-- processes

local function find_exe(name, opt)
  if opt ~= "" then return opt end
  for _, dir in ipairs({"~~/../", "~~/"}) do
    local p = mp.command_native({"expand-path", dir .. name .. ".exe"})
    if p and utils.file_info(p) then return p end
  end
  return name
end
local ffmpeg = find_exe("ffmpeg", o.ffmpeg_path)
local ffprobe = find_exe("ffprobe", o.ffprobe_path)

local running = {}

local function resume(co, ...)
  local ok, err = coroutine.resume(co, ...)
  if not ok then msg.error(debug.traceback(co, err)) end
end

local function run(args)
  local co = coroutine.running()
  local id
  id = mp.command_native_async({name = "subprocess", args = args,
    capture_stdout = true, capture_stderr = true, playback_only = false},
    function(ok, res, err)
      running[id] = nil
      resume(co, ok and res or {status = -1, stdout = "", stderr = err or ""})
    end)
  running[id] = true
  return coroutine.yield()
end

local function fmt(x) return string.format("%.3f", x) end

local function probe_duration(path)
  local r = run({ffprobe, "-v", "error", "-show_entries", "format=duration",
    "-of", "default=nw=1:nk=1", path})
  return r.status == 0 and tonumber((r.stdout or ""):match("[%d%.]+")) or nil
end

local function decode(path, amap, ss, len)
  local r = run({ffmpeg, "-nostdin", "-hide_banner", "-v", "error",
    "-ss", fmt(ss), "-t", fmt(len), "-i", path, "-map", amap,
    "-vn", "-sn", "-dn", "-ac", "1", "-ar", tostring(SR), "-f", "s16le", "-"})
  if r.status ~= 0 or #(r.stdout or "") < N * 4 then
    msg.verbose("audio decode failed: " .. path .. " " .. (r.stderr or ""))
    return nil
  end
  return fingerprint(r.stdout)
end


-------------------------------------------------------------------------------
-- candidates

local VIDEO_EXT = {}
for ext in ("mkv mp4 webm avi m4v mov ts m2ts wmv flv mpg mpeg ogv 3gp"):gmatch("%S+") do
  VIDEO_EXT[ext] = true
end

local function tokens(name)
  local set, count = {}, 0
  name = name:lower():gsub("%.[^%.]+$", "")
  for w in name:gmatch("[^%s%p]+") do
    if not w:find("%d") and not set[w] then
      set[w] = true
      count = count + 1
    end
  end
  return set, count
end

local function similarity(a, na, b, nb)
  if na == 0 and nb == 0 then return 1 end
  local inter = 0
  for w in pairs(a) do if b[w] then inter = inter + 1 end end
  return inter / (na + nb - inter)
end

local function numbers(name)
  local list = {}
  for d in name:gmatch("%d+") do list[#list + 1] = tonumber(d) end
  return list
end

-- distance between the first numbers that differ (the episode number, mostly)
local function ep_distance(a, b)
  for i = 1, math.max(#a, #b) do
    if a[i] ~= b[i] then
      if a[i] and b[i] then return math.abs(a[i] - b[i]) end
      return 1000
    end
  end
  return 10000 -- same numbers: likely another copy of the same episode
end

-- Other episodes of the same show: in the folder, and played before.
local function gather_candidates(cur)
  local ta, na = tokens(cur.name)
  local nums = numbers(cur.name)
  local list, seen = {}, {[cur.id] = true}

  local function consider(c)
    local tb, nb = tokens(c.name)
    c.sim = similarity(ta, na, tb, nb)
    if c.sim >= o.min_name_similarity then
      c.dist = ep_distance(nums, numbers(c.name))
      c.cached = index.files[c.id] ~= nil
      list[#list + 1] = c
    end
  end

  for _, f in ipairs(utils.readdir(cur.dir, "files") or {}) do
    local ext = (f:match("%.([^%.]+)$") or ""):lower()
    if VIDEO_EXT[ext] and f ~= cur.name then
      local path = utils.join_path(cur.dir, f)
      local info = utils.file_info(path)
      if info and info.is_file then
        local id = file_id(path, info)
        if not seen[id] then
          seen[id] = true
          local e = index.files[id]
          consider({id = id, path = path, name = f, duration = e and e.duration})
        end
      end
    end
  end
  for id, e in pairs(index.files) do
    if not seen[id] and (e.h or e.t) then
      seen[id] = true
      local path = e.path and utils.file_info(e.path) and e.path or nil
      consider({id = id, path = path, name = e.name or "", duration = e.duration})
    end
  end

  table.sort(list, function(a, b)
    if math.abs(a.sim - b.sim) > 0.05 then return a.sim > b.sim end
    if a.dist ~= b.dist then return a.dist < b.dist end
    return a.cached and not b.cached
  end)
  return list
end

