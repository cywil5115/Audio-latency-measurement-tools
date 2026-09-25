--[[
AudioNet-Gda telemetry logger (TASKS B4)

Companion to the LTC and MLS monitor plugins in this repository
(both publish into gmem namespace "audionet_gda").  Drains the per-value
gmem rings so the FULL 62.5-500 Hz LTC stream is captured, not a subsample,
and appends one CSV row per value with a wall-clock timestamp.

Run from Reaper: Actions -> Show action list -> Load ReaScript -> this file.
A small status window shows the output path and row counts; close the window
or press ESC to stop.  Prompts once for the Dante latency setting and free
notes -- these are repeated verbatim in every row so the analysis never has
to guess the configuration.

gmem schema v1
  [0]    schema version (1)
  LTC scalars @100:  100 seq, 101 rt_ms, 102 rt_samples, 103 reporting,
                     104 samples_per_bit, 105 dropped, 106 rejected_sync,
                     107 frames, 108 phase_corr, 109 srate,
                     110 rejected_outlier, 111 ipdv_ms, 112 block_size
  LTC ring @1000:    1024 entries x 4: [seq, rt_ms, ipdv_ms, rt_samples]
  MLS scalars @200:  200 seq, 201 oneway_ms, 202 rt_samples, 203 locked,
                     204 pb_correction, 205 srate, 206 block_size,
                     207 rejected_outlier, 208 n_updates, 209 rms,
                     210 engine, 211 verify_mismatches
  MLS ring @8000:    512 entries x 3: [seq, oneway_ms, rt_samples]

Ring entries write their seq slot last, so a row is only read once complete.
]]--

local LTC_RING_BASE, LTC_RING_LEN, LTC_ENTRY = 1000, 1024, 4
local MLS_RING_BASE, MLS_RING_LEN, MLS_ENTRY = 8000, 512, 3

reaper.gmem_attach("audionet_gda")

-- ---------------------------------------------------------------- log folder
-- Default preference order: the saved project's own directory; else REAPER's
-- configured default recording path (defrecpath in reaper.ini — NOT
-- GetProjectPath, which for an unsaved project can resolve into a
-- OneDrive-redirected Documents folder); else the resource path.  The prompt
-- below lets the user override it.
local function ini_value(key)
  local ini = reaper.get_ini_file()
  local fh = io.open(ini)
  if not fh then return nil end
  for line in fh:lines() do
    local v = line:match("^" .. key .. "=(.+)$")
    if v and v ~= "" then fh:close(); return v end
  end
  fh:close()
  return nil
end

local function default_log_dir()
  local _, projfn = reaper.EnumProjects(-1, "")
  if projfn and projfn ~= "" then
    local d = projfn:match("^(.*)[/\\]")
    if d then return d end
  end
  return ini_value("defrecpath") or reaper.GetResourcePath()
end

local function is_cloud_synced(path)
  local p = path:lower()
  return p:find("onedrive", 1, true) or p:find("dropbox", 1, true)
      or p:find("google drive", 1, true) or p:find("cloudstorage", 1, true)
end

-- ---------------------------------------------------------------- metadata
-- GetUserInputs has no tooltips and its LABEL COLUMN IS A FIXED WIDTH -- labels
-- past ~30 chars are silently truncated -- so keep labels short and put the
-- source hint in the window TITLE, which has room.
--
-- The Dante latency must be the value the devices actually run at, read from
--   Dante Controller -> Network Status tab -> "Latency Setting" column
-- (identical to Device View -> Device Config -> Device Latency). Never accept
-- the default blindly: an unlogged/incorrect Dante latency is precisely what
-- made the students' 256-sample row uninterpretable.
--
-- Notes should carry what the OTHER columns cannot: the physical signal path
-- and anything unusual about the session. Block size, Dante latency, sample
-- rate, fps mode and engine are all stamped automatically on every row.
--
-- Captions are comma-separated (so no commas inside a label); separator=|
-- applies to the values only, which is why notes may contain commas.
--
-- Every field is remembered between runs (reaper-extstate.ini), so the second
-- run onwards prefills with what you actually typed -- your own last entry
-- becomes the worked example, and a rig that rarely changes needs one OK.
local NS = "AudioNetGda"
local function recall(key, fallback)
  local v = reaper.GetExtState(NS, key)
  return (v ~= "") and v or fallback
end

-- First-run example. Deliberately concrete: it shows the FORM to copy, and it
-- describes the actual deployment, so it is a usable default rather than
-- filler. It carries only what the automatic columns cannot -- rig, signal
-- path, PTP roles. Do NOT restate block size / Dante latency / sample rate /
-- fps mode / engine here: those are stamped on every row already.
-- (No commas: they are converted to semicolons to keep the CSV intact.)
local EXAMPLE_NOTES =
  "live PG-AMuz; Babyface XLR out > 12Mic-KSMM01 > Dante > " ..
  "Digiface-Rezyserka (AMuz standalone Rx>Tx; no host) > 12Mic hp out > " ..
  "Babyface in3; PTP leader=12Mic 8ppm; 48k PCM32"

local ok, csv = reaper.GetUserInputs(
  "AudioNet-Gda logger  (Dante latency: Dante Controller > Network Status)", 3,
  "Dante latency (us),Notes: signal path + rig,Log folder,extrawidth=320,separator=|",
  recall("dante_us", "250") .. "|" ..
  recall("notes", EXAMPLE_NOTES) .. "|" ..
  recall("logdir", default_log_dir()))
if not ok then return end
local dante_latency, notes, dir = csv:match("([^|]*)|([^|]*)|(.*)")
notes = (notes or ""):gsub(",", ";")  -- keep the CSV intact
if not dir or dir == "" then dir = reaper.GetResourcePath() end
reaper.SetExtState(NS, "dante_us", dante_latency or "", true)
reaper.SetExtState(NS, "notes", notes, true)
reaper.SetExtState(NS, "logdir", dir, true)

-- ---------------------------------------------------------------- output file
reaper.RecursiveCreateDirectory(dir, 0)
local cloud_warn = is_cloud_synced(dir)
    and "WARNING: folder is cloud-synced (sync may corrupt or duplicate data)" or ""
local fname = dir .. "/audionet_gda_log_" .. os.date("%Y%m%d_%H%M%S") .. ".csv"
local f = assert(io.open(fname, "w"))
f:write("iso_timestamp,unix_time,method,seq,value_ms,samples,ipdv_ms,",
        "mode_or_engine,dropped,rejected_sync,rejected_outlier,phase_corr,",
        "block_size,srate,dante_latency_us,notes\n")

-- wall clock with sub-second precision: calibrate time_precise to epoch once
local t0_epoch, t0_precise = os.time(), reaper.time_precise()
local function now()
  local t = t0_epoch + (reaper.time_precise() - t0_precise)
  local sec = math.floor(t)
  local ms = math.floor((t - sec) * 1000)
  return string.format("%s.%03d", os.date("%Y-%m-%dT%H:%M:%S", sec), ms), t
end

-- ---------------------------------------------------------------- state
local ltc_last, mls_last = reaper.gmem_read(100), reaper.gmem_read(200)
local rows_ltc, rows_mls, lost = 0, 0, 0

local function drain_ltc()
  local cur = reaper.gmem_read(100)
  if cur < ltc_last then
    -- publisher restarted (plugin reloaded): resync and keep logging
    ltc_last = math.max(0, cur - 1)
  end
  if cur <= ltc_last then return end
  if cur - ltc_last > LTC_RING_LEN then
    lost = lost + (cur - ltc_last - LTC_RING_LEN)
    ltc_last = cur - LTC_RING_LEN
  end
  local iso, unix = now()
  for s = ltc_last + 1, cur do
    local base = LTC_RING_BASE + ((s - 1) % LTC_RING_LEN) * LTC_ENTRY
    if reaper.gmem_read(base) == s then
      local v_ms  = reaper.gmem_read(base + 1)
      local v_smp = reaper.gmem_read(base + 3)
      local v_ipd = reaper.gmem_read(base + 2)
      -- re-verify after reading: the writer may have lapped us mid-row
      if reaper.gmem_read(base) == s then
        f:write(string.format("%s,%.3f,ltc,%d,%.6f,%.1f,%.6f,%d,%d,%d,%d,%d,%d,%d,%s,%s\n",
          iso, unix, s, v_ms, v_smp, v_ipd,
          reaper.gmem_read(104), reaper.gmem_read(105), reaper.gmem_read(106),
          reaper.gmem_read(110), reaper.gmem_read(108), reaper.gmem_read(112),
          reaper.gmem_read(109), dante_latency, notes))
        rows_ltc = rows_ltc + 1
      else
        lost = lost + 1
      end
    else
      lost = lost + 1
    end
  end
  ltc_last = cur
end

local function drain_mls()
  local cur = reaper.gmem_read(200)
  if cur < mls_last then
    mls_last = math.max(0, cur - 1)  -- publisher restarted: resync
  end
  if cur <= mls_last then return end
  if cur - mls_last > MLS_RING_LEN then
    lost = lost + (cur - mls_last - MLS_RING_LEN)
    mls_last = cur - MLS_RING_LEN
  end
  local iso, unix = now()
  for s = mls_last + 1, cur do
    local base = MLS_RING_BASE + ((s - 1) % MLS_RING_LEN) * MLS_ENTRY
    if reaper.gmem_read(base) == s then
      local v_ms  = reaper.gmem_read(base + 1)
      local v_smp = reaper.gmem_read(base + 2)
      if reaper.gmem_read(base) == s then  -- re-verify: writer may lap us
        f:write(string.format("%s,%.3f,mls,%d,%.6f,%.1f,,%d,,,%d,,%d,%d,%s,%s\n",
          iso, unix, s, v_ms, v_smp,
          reaper.gmem_read(210), reaper.gmem_read(207),
          reaper.gmem_read(206), reaper.gmem_read(205), dante_latency, notes))
        rows_mls = rows_mls + 1
      else
        lost = lost + 1
      end
    else
      lost = lost + 1
    end
  end
  mls_last = cur
end

-- ---------------------------------------------------------------- UI + loop
local closed = false
local function cleanup()
  if not closed then
    closed = true
    f:close()
    gfx.quit()
  end
end
reaper.atexit(cleanup)

gfx.init("AudioNet-Gda logger", 460, 110)

local function loop()
  drain_ltc()
  drain_mls()
  f:flush()

  gfx.set(0.07, 0.07, 0.10)
  gfx.rect(0, 0, gfx.w, gfx.h, 1)
  gfx.set(0.8, 0.85, 0.9)
  gfx.x, gfx.y = 10, 10;  gfx.drawstr("Logging to: " .. fname)
  if cloud_warn ~= "" then
    gfx.set(1.0, 0.6, 0.3)
    gfx.x, gfx.y = 10, 22;  gfx.drawstr(cloud_warn)
    gfx.set(0.8, 0.85, 0.9)
  end
  gfx.x, gfx.y = 10, 34
  gfx.drawstr(string.format("LTC rows: %d    MLS rows: %d    lost: %d",
                            rows_ltc, rows_mls, lost))
  gfx.x, gfx.y = 10, 58
  gfx.drawstr(string.format("Dante latency: %s us    notes: %s",
                            dante_latency, notes))
  gfx.x, gfx.y = 10, 82
  gfx.drawstr("Close window or press ESC to stop.")
  gfx.update()

  local ch = gfx.getchar()
  if ch >= 0 and ch ~= 27 then
    reaper.defer(loop)
  else
    cleanup()
  end
end

loop()
