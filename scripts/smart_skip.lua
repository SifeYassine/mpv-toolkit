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
local options = require "mp.options"
local ffi = require "ffi"
local bit = require "bit"

local band, bor, bxor, lshift, rshift = bit.band, bit.bor, bit.bxor, bit.lshift, bit.rshift

local o = {
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

