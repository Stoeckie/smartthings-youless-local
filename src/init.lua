-- SmartThings Edge driver: YouLess LS110 / LS120 energy monitor, read directly over the LAN (no cloud, no bridge).
-- One device: power now (W, negative while returning to the grid), energy used (kWh), a component "Returned to
-- grid" (kWh) and, with a P1 meter that reads gas, a component "Gas" (m3).
local Driver = require "st.driver"
local capabilities = require "st.capabilities"

-- Connection status as a capability, so routines can notify when this device loses its connection
-- (SmartThings itself has no "device offline" trigger for routines).
-- Short drops (a reconnect, one missed poll) are ignored: Offline is only emitted after the "Offline after" setting (default 5 min) down.
-- Every drop is remembered (time, duration, reason) and shown as "Last drop" once the connection is back.
local conn_cap = capabilities["silvervalley08660.connectionStatus"]
local drop_cap = capabilities["silvervalley08660.connectionLog"]
local CONN_GRACE = 300
local function conn_grace(dev)
  -- setting "Offline after (minutes)": a router or network update at night takes a few minutes
  local m = tonumber(dev.preferences and dev.preferences.offlineAfter)
  if m and m >= 1 then return math.floor(m * 60) end
  return CONN_GRACE
end
local function emit_conn(dev, v)
  if dev:get_field("conn_status") == v then return end
  local ok = pcall(function() dev:emit_event(conn_cap.status(v)) end)
  if ok then dev:set_field("conn_status", v) end
end
local function fmt_secs(s)
  if s < 120 then return string.format("%d s", s) end
  if s < 7200 then return string.format("%d min", s // 60) end
  return string.format("%.1f h", s / 3600)
end
local function note_drop(dev, reason)
  if dev:get_field("conn_drop") then return end
  dev:set_field("conn_drop", { at = os.time(), reason = tostring(reason or "unknown"):sub(1, 120) }, { persist = true })
end
local function report_drop(dev)
  local d = dev:get_field("conn_drop")
  if type(d) ~= "table" or not d.at then return end
  dev:set_field("conn_drop", nil, { persist = true })
  local txt = string.format("%s UTC, %s: %s", os.date("!%Y-%m-%d %H:%M:%S", d.at), fmt_secs(math.max(0, os.time() - d.at)), tostring(d.reason))
  require("log").info("[conn] " .. tostring(dev.label) .. " back after drop at " .. txt)
  pcall(function() dev:emit_event(drop_cap.lastDrop(txt:sub(1, 200))) end)
end
local function set_conn(dev, up, reason)
  if up then
    dev:set_field("conn_down_since", nil)
    if not dev:get_field("drop_seen") then
      -- the app wants a value for every attribute ("not all status information updated yet" otherwise)
      dev:set_field("drop_seen", true)
      local ok, v = pcall(dev.get_latest_state, dev, "main", drop_cap.ID, "lastDrop")
      if ok and v == nil and not dev:get_field("conn_drop") then
        pcall(function() dev:emit_event(drop_cap.lastDrop("No drops yet")) end)
      end
    end
    report_drop(dev)
    emit_conn(dev, "online")
    return
  end
  note_drop(dev, reason)
  if dev:get_field("conn_down_since") then return end
  local since = os.time()
  dev:set_field("conn_down_since", since)
  local ok = pcall(function()
    dev.thread:call_with_delay(conn_grace(dev), function()
      if dev:get_field("conn_down_since") == since then emit_conn(dev, "offline") end
    end)
  end)
  if not ok then emit_conn(dev, "offline") end
end
local log = require "log"
local cosock = require "cosock"
local api = require "youless_api"
local model = require "youless_model"
local emitq = require "emitq"  -- only changed values go to the hub (see emitq.lua)

local BUILD = "2026-11-14c"
local state = {} -- device.id -> { timer, busy, host, has_e, err, last_ok }

local function clean(s) return (tostring(s or ""):gsub("%s", "")) end

local function probe(host, timeout)
  local d = api.json(host, "/d", timeout)
  return model.is_youless(d) and d or nil
end

-- search the hub's /24 for a YouLess (it answers /d with its model); 32 addresses at a time, 1.5 s each
local function scan(driver)
  local hub = driver.environment_info and driver.environment_info.hub_ipv4
  local net = hub and hub:match("^(%d+%.%d+%.%d+)%.%d+$")
  if not net then return nil end
  local found
  for start = 1, 254, 32 do
    local pending = 0
    local tx, rx = cosock.channel.new()   -- cosock returns a sender and a receiver
    for i = start, math.min(254, start + 31) do
      pending = pending + 1
      cosock.spawn(function()
        local ip = net .. "." .. i
        local ok, d = pcall(probe, ip, 1.5)
        tx:send(ok and d and ip or false)
      end, "youless-scan")
    end
    for _ = 1, pending do
      local ip = rx:receive()
      if ip and not found then found = ip end
    end
    if found then break end
  end
  return found
end

local function host_of(dev)
  local p = clean((dev.preferences or {}).ipAddress)
  if p ~= "" and p ~= "auto" then return p end
  return dev:get_field("ip")
end

local function emit(dev, r)
  local now = os.time()
  if r.power then
    local v = math.floor(r.power + 0.5)
    if model.power_due(dev:get_field("db_power"), v, now) then
      emitq.try(dev, capabilities.powerMeter.power({ value = v, unit = "W" }))
      dev:set_field("db_power", { v = v, t = now })
    end
  end
  if model.totals_due(dev:get_field("db_totals"), now) then
    dev:set_field("db_totals", now)
    local comps = dev.profile and dev.profile.components or {}
    if r.import_kwh then emitq.try(dev, capabilities.energyMeter.energy({ value = r.import_kwh, unit = "kWh" })) end
    if r.export_kwh and comps.export then
      emitq.try(dev, capabilities.energyMeter.energy({ value = r.export_kwh, unit = "kWh" }), comps.export)
    end
    if r.gas_m3 and comps.gas then
      emitq.try(dev, capabilities.gasMeter.gasMeterVolume({ value = r.gas_m3, unit = "m^3" }), comps.gas)
    end
  end
end

local function poll_once(driver, dev, st)
  local host = host_of(dev)
  if not host then
    host = scan(driver)
    if not host then
      st.err = "YouLess not found (set its IP in the device settings)"
      log.warn("[youless] " .. st.err)
      set_conn(dev, false, st.err); dev:offline()
      return
    end
    dev:set_field("ip", host, { persist = true })
    log.info("[youless] found at " .. host)
  end
  local r, err
  -- /e (P1 meter: used, returned, gas) first; without a P1 meter /a (optical sensor) and stay on /a
  if st.has_e ~= false then
    local e
    e, err = api.json(host, "/e")
    r = e and model.from_e(e)
    if r then st.has_e = true end
  end
  if not r and st.has_e ~= true then
    local a, aerr = api.json(host, "/a?f=j")
    r = a and model.from_a(a)
    if r then st.has_e = false else err = err or aerr end
  end
  if not r then
    st.err = tostring(err or "no readings")
    log.warn("[youless] " .. host .. ": " .. st.err)
    set_conn(dev, false, st.err); dev:offline()
    -- an automatically found address can change: search again after a few failures
    st.fails = (st.fails or 0) + 1
    if st.fails >= 6 and clean((dev.preferences or {}).ipAddress) == "auto" then
      dev:set_field("ip", nil, { persist = true }); st.fails = 0; st.has_e = nil
    end
    return
  end
  st.err, st.last_ok, st.fails = nil, os.time(), 0
  dev:online(); set_conn(dev, true)
  emit(dev, r)
end

local function poll(driver, dev)
  local st = state[dev.id]
  if not st or st.busy then return end
  st.busy = true
  local ok, err = pcall(poll_once, driver, dev, st)
  st.busy = false
  if not ok then log.error("[youless] poll error: " .. tostring(err)) end
end

local function schedule(driver, dev)
  local st = state[dev.id]
  if st.timer then dev.thread:cancel_timer(st.timer) end
  local interval = tonumber((dev.preferences or {}).pollInterval) or 10
  if interval < 5 then interval = 5 end
  st.timer = dev.thread:call_on_schedule(interval, function() poll(driver, dev) end, "youless-poll")
  dev.thread:call_with_delay(2, function() poll(driver, dev) end)
end

local function handle_refresh(driver, dev)
  -- a manual refresh shows the current values: skip the deadband once
  dev:set_field("db_power", nil); dev:set_field("db_totals", nil)
  poll(driver, dev)
end

local function device_init(driver, dev)
  state[dev.id] = state[dev.id] or {}
  schedule(driver, dev)
end

local function info_changed(driver, dev)
  local st = state[dev.id]
  if not st then return end
  st.has_e = nil
  schedule(driver, dev)
end

local function device_removed(driver, dev)
  emitq.forget(dev)
  local st = state[dev.id]
  if st and st.timer then dev.thread:cancel_timer(st.timer) end
  state[dev.id] = nil
end

local function discovery(driver, opts, should_continue, only_if_found)
  local known = {}
  for _, d in ipairs(driver:get_devices()) do known[d.device_network_id or ""] = true end
  local ip = scan(driver)
  local d = ip and probe(ip)
  local mac = d and tostring(d.mac or ""):gsub(":", ""):lower() or ""
  local dni = "youless-" .. (mac ~= "" and mac or "1")
  if known[dni] then return end
  if only_if_found and not ip then log.info("[youless] auto-add: no YouLess found on the LAN"); return end
  log.info("[youless] discovery: " .. tostring(ip or "not found, device created anyway (set its IP)"))
  driver:try_create_device({ type = "LAN", device_network_id = dni, label = "YouLess",
    profile = "youless-meter", manufacturer = "YouLess", model = d and d.model or "LS120",
    vendor_provided_label = "YouLess" })
end

local driver = Driver("youless-local", {
  discovery = discovery,
  lifecycle_handlers = { init = device_init, added = device_init, infoChanged = info_changed, removed = device_removed },
  capability_handlers = {
    [capabilities.refresh.ID] = { [capabilities.refresh.commands.refresh.NAME] = handle_refresh },
  },
})

-- Auto-add: when the driver starts without any device and finds a YouLess on the LAN, it creates the device itself,
-- Note: the hub only starts a driver that has devices or is scanning, so for a new install "Scan nearby" is still needed;
-- this helps when the driver restarts (update, hub reboot) after its device was removed.
driver:call_with_delay(20, function()
  if #driver:get_devices() == 0 then discovery(driver, {}, function() return true end, true) end
end, "youless auto-add")

log.info("[youless] YouLess (local) driver starting, build " .. BUILD)
driver:run()
