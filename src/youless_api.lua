-- Plain HTTP GET to a YouLess on the LAN (it has no login and no TLS).
local socket = require "cosock.socket"
local json = require "st.json"

local M = {}
local TIMEOUT = 5

function M.get(host, path, timeout)
  local sock, err = socket.tcp()
  if not sock then return nil, "tcp: " .. tostring(err) end
  sock:settimeout(timeout or TIMEOUT)
  local ok, cerr = sock:connect(host, 80)
  if not ok then sock:close(); return nil, "connect: " .. tostring(cerr) end
  local sent, serr = sock:send("GET " .. path .. " HTTP/1.0\r\nHost: " .. host .. "\r\nConnection: close\r\n\r\n")
  if not sent then sock:close(); return nil, "send: " .. tostring(serr) end
  local data, rerr, partial = sock:receive("*a")
  sock:close()
  data = data or partial
  if not data or data == "" then return nil, "receive: " .. tostring(rerr) end
  local status = tonumber(data:match("^HTTP/%d%.?%d?%s+(%d+)"))
  local body = data:match("\r\n\r\n(.*)$") or ""
  return status, body
end

function M.json(host, path, timeout)
  local status, body = M.get(host, path, timeout)
  if not status then return nil, body end
  if status ~= 200 then return nil, "HTTP " .. tostring(status) .. " on " .. path end
  local ok, data = pcall(json.decode, body)
  if not ok or type(data) ~= "table" then return nil, "invalid JSON on " .. path end
  return data
end

return M
