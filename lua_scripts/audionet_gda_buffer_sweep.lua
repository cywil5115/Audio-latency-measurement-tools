--[[
AudioNet-Gda buffer-sweep harness (TASKS C3)

Semi-automated block-size sweep with MANDATORY Dante-latency capture. In the
single-Reaper loop the round trip contains exactly two buffer crossings, so
one-way latency must change by exactly 1 sample per sample of Reaper block
size (round-trip by 2). A point that breaks that line almost always means the
Dante device latency setting was changed and not recorded -- the exact failure
that produced the students' uninterpretable 256-sample row.
This harness makes that impossible to repeat: it refuses to record a point
without a Dante-latency value.

Whether Reaper's audio block size can be set programmatically is host/driver
dependent (SWS SNM_SetIntConfigVar does not reliably drive the ASIO/CoreAudio
buffer), so the sweep is driven MANUALLY: you change the block size in
Preferences -> Audio -> Device (or Buffering), and the harness detects the
change from the monitor's telemetry (block size is published to gmem), waits
for the reading to settle, prompts once for the Dante latency at that point,
and records the row. Repeat for each block size. Close the window to finish;
the fit is then run by a separate R script.

Requires a live v2.2 monitor (MLS or LTC) as for the linearity harness.
]]--

reaper.gmem_attach("audionet_gda")

local function seq_ltc() return reaper.gmem_read(100) end
local function seq_mls() return reaper.gmem_read(200) end
local function detect()
  local l0, m0 = seq_ltc(), seq_mls()
  local t = reaper.time_precise(); while reaper.time_precise() - t < 0.35 do end
  local l1, m1 = seq_ltc(), seq_mls()
  if l1 > l0 and m1 <= m0 then return "ltc" end
  if m1 > m0 and l1 <= l0 then return "mls" end
  if m1 > m0 and l1 > l0 then return "both" end
  return nil
end

local method = detect()
if not method then
  reaper.MB("No live monitor telemetry. Start a monitor and let it lock.",
            "AudioNet-Gda buffer sweep", 0); return
end
if method == "both" then method = "mls" end

local SEQ   = (method == "ltc") and 100 or 200
local RT    = (method == "ltc") and 102 or 202
local ONEW  = (method == "ltc") and 101 or 201
local BS    = (method == "ltc") and 112 or 206
local SRATE = reaper.gmem_read((method == "ltc") and 109 or 205)
if SRATE < 1 then SRATE = 48000 end

-- ---------------------------------------------------------------- output file
local function default_dir()
  local _, projfn = reaper.EnumProjects(-1, "")
  if projfn and projfn ~= "" then return projfn:match("^(.*)[/\\]") end
  local ini = reaper.get_ini_file(); local fh = io.open(ini)
  if fh then for l in fh:lines() do
    local v = l:match("^defrecpath=(.+)$"); if v and v ~= "" then fh:close(); return v end
  end; fh:close() end
  return reaper.GetResourcePath()
end

local function is_cloud_synced(path)
  local p = path:lower()
  return p:find("onedrive", 1, true) or p:find("dropbox", 1, true)
      or p:find("google drive", 1, true) or p:find("cloudstorage", 1, true)
end

-- Ask where the log goes, exactly as the telemetry logger does: an unsaved
-- project has no path and REAPER's defrecpath may be unset, so the silent
-- fallback is the resource path -- almost never where the data should live.
-- shared with the logger: remembered between runs (reaper-extstate.ini)
local NS = "AudioNetGda"
local function recall(key, fallback)
  local v = reaper.GetExtState(NS, key)
  return (v ~= "") and v or fallback
end

local ok_dir, dir = reaper.GetUserInputs(
  "AudioNet-Gda buffer sweep (" .. method:upper() ..
  ")  — step the block size in Preferences; a row is captured per size", 1,
  "Log folder,extrawidth=320", recall("logdir", default_dir()))
if not ok_dir then return end
if dir == "" then dir = reaper.GetResourcePath() end
reaper.SetExtState(NS, "logdir", dir, true)
reaper.RecursiveCreateDirectory(dir, 0)
local cloud_warn = is_cloud_synced(dir)
    and "WARNING: folder is cloud-synced (sync may corrupt or duplicate data)" or ""

local fname = dir .. "/audionet_gda_buffersweep_" .. method .. "_" ..
              os.date("%Y%m%d_%H%M%S") .. ".csv"
local f = assert(io.open(fname, "w"))
f:write("method,block_size,dante_latency_us,rt_samples_median,rt_samples_sd,",
        "oneway_ms_median,n_captured,srate\n")

local function median(t)
  if #t == 0 then return 0 end
  local s = {}; for i = 1, #t do s[i] = t[i] end; table.sort(s)
  local n = #s
  return (n % 2 == 1) and s[(n + 1) // 2] or 0.5 * (s[n // 2] + s[n // 2 + 1])
end
local function sd(t, m)
  if #t < 2 then return 0 end
  local a = 0; for i = 1, #t do a = a + (t[i] - m) ^ 2 end
  return math.sqrt(a / (#t - 1))
end

-- ---------------------------------------------------------------- state machine
local S_WATCH, S_SETTLE, S_COLLECT = 1, 2, 3
local state, t_state = S_WATCH, 0
local settle_s, collect_s = 1.5, 3.0
local recorded = {}          -- block sizes already captured
local cur_bs, last_seq, rt_buf, ms_buf = 0, 0, {}, {}
local rows = {}

local function loop()
  local now = reaper.time_precise()
  local bs = reaper.gmem_read(BS)

  if state == S_WATCH then
    if bs > 0 and not recorded[bs] then
      cur_bs = bs; t_state = now; state = S_SETTLE
    end

  elseif state == S_SETTLE then
    if bs ~= cur_bs then          -- block size changed again mid-settle
      cur_bs = bs; t_state = now
    elseif now - t_state >= settle_s then
      rt_buf, ms_buf = {}, {}; last_seq = reaper.gmem_read(SEQ)
      t_state = now; state = S_COLLECT
    end

  elseif state == S_COLLECT then
    if bs ~= cur_bs then
      state = S_WATCH          -- block size moved mid-collect: abandon, restart
    else
    local seq = reaper.gmem_read(SEQ)
    if seq > last_seq then
      last_seq = seq
      rt_buf[#rt_buf + 1] = reaper.gmem_read(RT)
      ms_buf[#ms_buf + 1] = reaper.gmem_read(ONEW)
    end
    if now - t_state >= collect_s then
      local rtm = median(rt_buf)
      -- MANDATORY Dante latency capture -- no row without it
      -- Source hint goes in the TITLE: the label column is a fixed width and
      -- truncates past ~30 chars.
      local ok, dl = reaper.GetUserInputs(
        "Block size " .. cur_bs .. "  (read: Dante Controller > Network Status)", 1,
        "Dante latency (us),extrawidth=200", recall("dante_us", "250"))
      if ok then
        local dlv = tonumber((dl:gsub("[^%d%.%-]", ""))) or -1
        reaper.SetExtState(NS, "dante_us", tostring(dlv), true)
        f:write(string.format("%s,%d,%.0f,%.3f,%.4f,%.6f,%d,%.0f\n",
          method, cur_bs, dlv, rtm, sd(rt_buf, rtm), median(ms_buf),
          #rt_buf, SRATE))
        f:flush()
        recorded[cur_bs] = true
        rows[#rows + 1] = { bs = cur_bs, dl = dlv, rt = rtm, n = #rt_buf }
      end
      state = S_WATCH
    end
    end
  end

  gfx.set(0.07, 0.07, 0.10); gfx.rect(0, 0, gfx.w, gfx.h, 1)
  gfx.set(0.85, 0.88, 0.92)
  gfx.x, gfx.y = 10, 10
  gfx.drawstr(string.format("Buffer sweep (%s) — current block size %d",
                            method:upper(), bs))
  gfx.x, gfx.y = 10, 30
  gfx.drawstr("Change block size in Preferences; a row is captured per size.")
  gfx.x, gfx.y = 10, 50
  gfx.drawstr("state: " .. ({ "WATCH", "SETTLE", "COLLECT" })[state] ..
              "   (ESC or close window to finish)")
  if cloud_warn ~= "" then
    gfx.set(1.0, 0.6, 0.3); gfx.x, gfx.y = 10, 68; gfx.drawstr(cloud_warn)
    gfx.set(0.85, 0.88, 0.92)
  end
  local yy = 90
  for i = 1, #rows do
    gfx.x, gfx.y = 10, yy
    gfx.drawstr(string.format("  bs %d, Dante %.0f us -> RT %.1f smp (n=%d)",
      rows[i].bs, rows[i].dl, rows[i].rt, rows[i].n))
    yy = yy + 18
  end
  gfx.update()

  local ch = gfx.getchar()
  if ch >= 0 and ch ~= 27 then reaper.defer(loop) else finish() end  -- 27 = ESC
end

function finish()
  f:close()
  reaper.ShowConsoleMsg(string.format(
    "\nWrote %s (%d rows)\nFit it:  run the buffer-sweep analysis script on '%s'\n",
    fname, #rows, fname))
  gfx.quit()
end

reaper.atexit(function() pcall(function() f:close() end) end)
gfx.init("AudioNet-Gda buffer sweep", 560, 320)
reaper.ShowConsoleMsg("AudioNet-Gda buffer sweep started (" .. method:upper() ..
  "). Step the block size in Preferences.\n")
loop()
