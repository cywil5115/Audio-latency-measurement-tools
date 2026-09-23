--[[
AudioNet-Gda injection-linearity harness (TASKS C2)

Automates the known-injection validation: step an exact
sample delay through a set of values, record the monitor's round-trip reading
at each, and write a CSV that is later fitted to a line
(slope must be 1.000 samples per sample of injection).

Requires, running in Reaper:
  - one monitor plugin producing telemetry (MLS or LTC v2.2, gmem namespace "audionet_gda"), locked
    and reporting;
  - one injection_delay.jsfx inserted in the measurement loop (traversed once
    per round trip); parameter 0 = delay in samples.

The harness sets the delay parameter, waits for the reading to settle, and
takes the MEDIAN round-trip over a collection window (robust to the outlier
gate's re-baseline transient after each step). It reads the applied delay back
from gmem[300] to confirm the parameter landed.

Run: Actions -> Load ReaScript -> this file. It prompts for the injection list
and timing, runs unattended, and writes the CSV next to the other logs.

NOTE: MLS order 12 caps the unambiguous round trip at 4095 samples (~85 ms).
The harness warns and skips any injection whose baseline+injection would wrap.
LTC has no such limit (its payload is an absolute counter).
]]--

reaper.gmem_attach("audionet_gda")

-- ---------------------------------------------------------------- detect monitor
-- Watch the two sequence counters; whichever advances is the live monitor.
local function seq_ltc() return reaper.gmem_read(100) end
local function seq_mls() return reaper.gmem_read(200) end

local function detect_method()
  local l0, m0 = seq_ltc(), seq_mls()
  local t = reaper.time_precise()
  while reaper.time_precise() - t < 0.35 do end  -- brief busy wait (pre-loop)
  local l1, m1 = seq_ltc(), seq_mls()
  local ltc_live, mls_live = (l1 > l0), (m1 > m0)
  if ltc_live and not mls_live then return "ltc" end
  if mls_live and not ltc_live then return "mls" end
  if mls_live and ltc_live then return "both" end
  return nil
end

-- ---------------------------------------------------------------- find injection FX
local function find_injection_fx()
  local function scan(tr)
    if not tr then return nil end
    for fx = 0, reaper.TrackFX_GetCount(tr) - 1 do
      local _, nm = reaper.TrackFX_GetFXName(tr, fx, "")
      if nm:find("Injection Delay", 1, true) then return tr, fx end
    end
    return nil
  end
  local tr, fx = scan(reaper.GetMasterTrack(0))
  if tr then return tr, fx end
  for i = 0, reaper.CountTracks(0) - 1 do
    tr, fx = scan(reaper.GetTrack(0, i))
    if tr then return tr, fx end
  end
  return nil
end

local inj_tr, inj_fx = find_injection_fx()
if not inj_tr then
  reaper.MB("No 'Injection Delay' JSFX found on any track.\n" ..
            "Insert injection_delay.jsfx into the measurement loop first.",
            "AudioNet-Gda linearity", 0)
  return
end

local method = detect_method()
if not method then
  reaper.MB("No live monitor telemetry (neither MLS nor LTC sequence is " ..
            "advancing).\nStart a monitor and let it lock before running.",
            "AudioNet-Gda linearity", 0)
  return
end
if method == "both" then method = "mls" end  -- MLS rt_samples is exact-integer

local SEQ   = (method == "ltc") and 100 or 200
local RT    = (method == "ltc") and 102 or 202   -- round-trip in samples
local ONEW  = (method == "ltc") and 101 or 201   -- displayed ms (rt or one-way)
local SRATE = reaper.gmem_read((method == "ltc") and 109 or 205)
if SRATE < 1 then SRATE = 48000 end

-- ---------------------------------------------------------------- parameters
local function default_dir()
  local _, projfn = reaper.EnumProjects(-1, "")
  if projfn and projfn ~= "" then return projfn:match("^(.*)[/\\]") end
  local ini = reaper.get_ini_file(); local fh = io.open(ini)
  if fh then for l in fh:lines() do
    local v = l:match("^defrecpath=(.+)$"); if v and v ~= "" then fh:close(); return v end
  end; fh:close() end
  return reaper.GetResourcePath()
end

-- separator=| for the VALUES lets the injection list keep its commas in one
-- field (captions stay comma-separated, so no commas inside a label)
local default_list = (method == "ltc") and "0,1,10,100,1000" or "0,0.5,1,2,5,20,50"
-- shared with the logger: remembered between runs (reaper-extstate.ini)
local NS = "AudioNetGda"
local function recall(key, fallback)
  local v = reaper.GetExtState(NS, key)
  return (v ~= "") and v or fallback
end

-- Short labels: the label column is a fixed width and truncates past ~30 chars.
local ok, csv = reaper.GetUserInputs(
  "AudioNet-Gda linearity (" .. method:upper() ..
  ")  — needs injection_delay.jsfx in the loop", 4,
  "Injections (ms comma-sep),Settle per step (s),Collect per step (s),Log folder,extrawidth=320,separator=|",
  recall("inj_" .. method, default_list) .. "|2.5|3.0|" .. recall("logdir", default_dir()))
if not ok then return end
local list_s, settle_str, collect_str, dir = csv:match("([^|]*)|([^|]*)|([^|]*)|(.*)")
local settle_s  = tonumber(settle_str) or 2.5
local collect_s = tonumber(collect_str) or 3.0
if not dir or dir == "" then dir = reaper.GetResourcePath() end
reaper.SetExtState(NS, "logdir", dir, true)
reaper.SetExtState(NS, "inj_" .. method, list_s or "", true)
reaper.RecursiveCreateDirectory(dir, 0)
local inj_ms = {}
for p in ((list_s or "") .. ","):gmatch("([^,]*),") do
  local v = tonumber(p); if v then inj_ms[#inj_ms + 1] = v end
end
if #inj_ms == 0 then return end

-- baseline round-trip (for the MLS wrap guard)
local baseline_rt = reaper.gmem_read(RT)
local steps = {}
for _, ms in ipairs(inj_ms) do
  local smp = math.floor(ms / 1000 * SRATE + 0.5)
  if method == "mls" and (baseline_rt + smp) >= 4090 then
    reaper.ShowConsoleMsg(string.format(
      "SKIP %.3f ms (%d smp): baseline %d + injection would wrap MLS order 12 (4095)\n",
      ms, smp, baseline_rt))
  else
    steps[#steps + 1] = { ms = ms, smp = smp }
  end
end
if #steps == 0 then
  reaper.MB("Every injection would wrap the MLS range. Use smaller values " ..
            "or the LTC monitor.", "AudioNet-Gda linearity", 0)
  return
end

-- ---------------------------------------------------------------- output file
-- (dir came from the prompt above)
local fname = dir .. "/audionet_gda_linearity_" .. method .. "_" ..
              os.date("%Y%m%d_%H%M%S") .. ".csv"
local f = assert(io.open(fname, "w"))
f:write("method,injection_ms,injection_samples,rt_samples_median,rt_samples_sd,",
        "displayed_ms_median,n_captured,srate\n")

-- ---------------------------------------------------------------- helpers
local function median(t)
  if #t == 0 then return 0 end
  local s = {}; for i = 1, #t do s[i] = t[i] end; table.sort(s)
  local n = #s
  if n % 2 == 1 then return s[(n + 1) // 2] end
  return 0.5 * (s[n // 2] + s[n // 2 + 1])
end
local function sd(t, m)
  if #t < 2 then return 0 end
  local a = 0; for i = 1, #t do a = a + (t[i] - m) ^ 2 end
  return math.sqrt(a / (#t - 1))
end

-- ---------------------------------------------------------------- state machine
local S_SET, S_SETTLE, S_COLLECT, S_DONE = 1, 2, 3, 4
local state, idx, t_state = S_SET, 1, 0
local last_seq, rt_buf, ms_buf = 0, {}, {}
local results = {}

local function set_param(smp)
  reaper.TrackFX_SetParam(inj_tr, inj_fx, 0, smp)
end

local function finish()
  f:close()
  reaper.ShowConsoleMsg(string.format(
    "\nWrote %s\nFit it:  run the linearity analysis script on '%s'\n",
    fname, fname))
  gfx.quit()
end

local function loop()
  local now = reaper.time_precise()

  if state == S_SET then
    set_param(steps[idx].smp)
    last_seq = reaper.gmem_read(SEQ)
    rt_buf, ms_buf = {}, {}
    t_state = now
    state = S_SETTLE

  elseif state == S_SETTLE then
    -- confirm the parameter landed, then wait out the settle window
    if now - t_state >= settle_s then
      state = S_COLLECT; t_state = now; last_seq = reaper.gmem_read(SEQ)
    end

  elseif state == S_COLLECT then
    local seq = reaper.gmem_read(SEQ)
    if seq > last_seq then
      last_seq = seq
      rt_buf[#rt_buf + 1] = reaper.gmem_read(RT)
      ms_buf[#ms_buf + 1] = reaper.gmem_read(ONEW)
    end
    if now - t_state >= collect_s then
      local rtm = median(rt_buf)
      local applied = reaper.gmem_read(300)
      f:write(string.format("%s,%.6f,%d,%.3f,%.4f,%.6f,%d,%.0f\n",
        method, steps[idx].ms, steps[idx].smp, rtm, sd(rt_buf, rtm),
        median(ms_buf), #rt_buf, SRATE))
      f:flush()
      results[idx] = { ms = steps[idx].ms, smp = steps[idx].smp,
                       rt = rtm, n = #rt_buf, applied = applied }
      idx = idx + 1
      state = (idx > #steps) and S_DONE or S_SET
    end

  elseif state == S_DONE then
    finish(); return
  end

  -- status
  gfx.set(0.07, 0.07, 0.10); gfx.rect(0, 0, gfx.w, gfx.h, 1)
  gfx.set(0.85, 0.88, 0.92)
  gfx.x, gfx.y = 10, 10
  gfx.drawstr(string.format("Linearity sweep (%s) — step %d/%d",
                            method:upper(), math.min(idx, #steps), #steps))
  gfx.x, gfx.y = 10, 32
  gfx.drawstr(string.format("state: %s   injection: %.3f ms (%d smp)",
    ({ "SET", "SETTLE", "COLLECT", "DONE" })[state],
    steps[math.min(idx, #steps)].ms, steps[math.min(idx, #steps)].smp))
  gfx.x, gfx.y = 10, 52
  gfx.drawstr("ESC or close window to abort (partial CSV is kept)")
  local yy = 76
  for i = 1, #results do
    gfx.x, gfx.y = 10, yy
    gfx.drawstr(string.format("  %.3f ms -> RT %.1f smp (n=%d, applied %d)",
      results[i].ms, results[i].rt, results[i].n, results[i].applied))
    yy = yy + 18
  end
  gfx.update()

  -- Without this the sweep could not be stopped at all: it deferred
  -- unconditionally, so neither ESC nor closing the window ended it.
  local ch = gfx.getchar()
  if ch >= 0 and ch ~= 27 then reaper.defer(loop) else finish() end  -- 27 = ESC
end

reaper.atexit(function() pcall(function() f:close() end) end)
gfx.init("AudioNet-Gda linearity", 560, 300)
reaper.ShowConsoleMsg("AudioNet-Gda linearity sweep started (" ..
  method:upper() .. ", " .. #steps .. " steps)\n")
loop()
