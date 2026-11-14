"""Smoke test of src/init.lua with a mocked SmartThings runtime and a mocked YouLess."""
from run_lua import runtime

HARNESS = rb'''
EVENTS = {}
local function capmock(path)
  return setmetatable({}, {
    __index = function(t, k) local v = capmock(path .. "." .. k); rawset(t, k, v); return v end,
    __call = function(_, a) return { path = path, arg = a, capability = { ID = path }, attribute = { NAME = path }, value = a } end })
end
package.loaded["st.capabilities"] = setmetatable({ refresh = { ID = "refresh", commands = { refresh = { NAME = "refresh" } } } },
  { __index = function(t, k) local v = capmock(k); rawset(t, k, v); return v end })
package.loaded["log"] = { info = function() end, warn = function(m) LASTWARN = m end, error = function(m) error(m) end, debug = function() end }
package.loaded["cosock"] = { spawn = function(f) f() end,
  channel = { new = function() local q = {}; return { send = function(_, v) q[#q + 1] = v end,
    receive = function() return table.remove(q, 1) end } end } }
package.loaded["cosock.socket"] = {}
package.loaded["st.driver"] = function(name, tmpl) DRIVER = tmpl; DRVOBJ = { run = function() end,
  environment_info = { hub_ipv4 = "192.168.2.8" }, get_devices = function() return {} end,
  try_create_device = function(_, d) CREATED = d end }; return DRVOBJ end
ANSWERS = {}
package.loaded["youless_api"] = { json = function(host, path)
  local a = ANSWERS[host .. path]; if a then return a end; return nil, "connect: timeout" end }
DEV = { id = "d1", preferences = { ipAddress = "auto", pollInterval = 10 }, fields = {},
  profile = { components = { main = { id = "main" }, export = { id = "export" }, gas = { id = "gas" } } },
  thread = { call_on_schedule = function(_, s, f) TICK = f end, call_with_delay = function(_, s, f) end, cancel_timer = function() end } }
function DEV:get_field(k) return self.fields[k] end
function DEV:set_field(k, v) self.fields[k] = v end
function DEV:online() self.on = true end
function DEV:offline() self.on = false end
function DEV:emit_event(ev) EVENTS[#EVENTS + 1] = { comp = "main", ev = ev } end
function DEV:emit_component_event(c, ev) EVENTS[#EVENTS + 1] = { comp = c.id, ev = ev } end
function DEV:get_latest_state() return nil end
'''


def setup():
    lua = runtime()
    lua.execute(HARNESS)
    lua.execute(b'package.loaded["st.json"] = require("st.json")')
    lua.execute(b'dofile("' + str(__import__("run_lua").SRC / "init.lua").encode() + b'")')
    return lua


def events(lua):
    n = lua.eval(b'#EVENTS')
    return {(lua.eval(b'EVENTS[%d].comp' % i).decode(), lua.eval(b'EVENTS[%d].ev.path' % i).decode()):
            lua.eval(b'EVENTS[%d].ev.arg' % i) for i in range(1, n + 1)}


def test_scan_then_read_p1():
    lua = setup()
    lua.execute(b'''
      ANSWERS["192.168.2.21/d"] = { model = "LS120", mac = "72:b8:ad:14:39:24" }
      ANSWERS["192.168.2.21/e"] = { { pwr = -510, p1 = 100.5, p2 = 200.25, n1 = 10, n2 = 20.5, gas = 1234.567 } }
      DRIVER.lifecycle_handlers.init(DRVOBJ, DEV)
      TICK()
    ''')
    assert lua.eval(b'DEV.fields.ip') == b"192.168.2.21"
    ev = events(lua)
    assert ev[("main", "powerMeter.power")].value == -510
    assert abs(ev[("main", "energyMeter.energy")].value - 300.75) < 1e-9
    assert ev[("export", "energyMeter.energy")].value == 30.5
    assert abs(ev[("gas", "gasMeter.gasMeterVolume")].value - 1234.567) < 1e-9
    assert lua.eval(b'DEV.on') is True
    # a poll right after: nothing new goes out (deadband)
    lua.execute(b'EVENTS = {}; TICK()')
    assert lua.eval(b'#EVENTS') == 0


def test_fallback_to_a_without_p1():
    lua = setup()
    lua.execute(b'''
      DEV.preferences.ipAddress = "10.0.0.5"
      ANSWERS["10.0.0.5/a?f=j"] = { cnt = " 37420,724", pwr = 812 }
      DRIVER.lifecycle_handlers.init(DRVOBJ, DEV)
      TICK()
    ''')
    ev = events(lua)
    assert ev[("main", "powerMeter.power")].value == 812
    assert abs(ev[("main", "energyMeter.energy")].value - 37420.724) < 1e-9


def test_not_found_goes_offline():
    lua = setup()
    lua.execute(b'DRIVER.lifecycle_handlers.init(DRVOBJ, DEV); TICK()')
    assert lua.eval(b'DEV.on') is False
