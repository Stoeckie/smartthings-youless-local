-- Parse YouLess LS110 / LS120 answers into readings. Pure Lua, no SmartThings modules (tested from Python).
--   /e   (LS120 with a P1 smart meter): [{"net":..,"pwr":..,"p1":..,"p2":..,"n1":..,"n2":..,"gas":..}]
--   /a?f=j (optical sensor, LS110 and LS120): {"cnt":" 37420,724","pwr":-510,...}  (comma as decimal sign)
local M = {}

local function num(v)
  if v == nil then return nil end
  local s = tostring(v):gsub("%s", ""):gsub(",", ".")
  return tonumber(s)
end
M.num = num

local function round(x, d)
  local m = 10 ^ (d or 3)
  return math.floor(x * m + 0.5) / m
end

--- readings from /e (table, already decoded) or /a (table): { power = W, import_kwh, export_kwh, gas_m3 }
function M.from_e(e)
  if type(e) == "table" and e[1] ~= nil then e = e[1] end
  if type(e) ~= "table" then return nil end
  local r = { power = num(e.pwr) }
  local p1, p2, n1, n2 = num(e.p1), num(e.p2), num(e.n1), num(e.n2)
  if p1 and p2 then r.import_kwh = round(p1 + p2) end
  if n1 and n2 then r.export_kwh = round(n1 + n2) end
  local gas = num(e.gas)
  if gas and gas > 0 then r.gas_m3 = round(gas) end
  if r.power == nil and r.import_kwh == nil then return nil end
  return r
end

function M.from_a(a)
  if type(a) ~= "table" then return nil end
  local r = { power = num(a.pwr), import_kwh = num(a.cnt) }
  if r.power == nil and r.import_kwh == nil then return nil end
  return r
end

--- a YouLess answers /d with {"model":"LS120","mac":"72:b8:.."}
function M.is_youless(d)
  return type(d) == "table" and type(d.model) == "string" and d.model:match("^LS1") ~= nil
end

-- deadband: power at most once a minute, or after 15 s for a jump of 500 W or more; totals every 5 minutes
function M.power_due(last, v, now)
  if type(last) ~= "table" or last.t == nil then return true end
  local age = now - last.t
  return age >= 60 or (age >= 15 and math.abs(v - (last.v or v)) >= 500)
end

function M.totals_due(last_t, now)
  return last_t == nil or now - last_t >= 300
end

return M
