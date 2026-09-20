-- Non-blocking TCP transport for MultiBeam (LuaSocket).
--
-- BeamNG only lets mods connect to this PC ("connect restricted"). Remote servers are reached through
-- the MultiBeam bridge, which listens on 127.0.0.1 and forwards to the real server, so from here
-- every server is just an address on this PC.
--
-- handle:poll()        -> "pending" | "ok" | "fail", err
-- handle:send(str)     -> bytesSent (may be 0) | nil, err
-- handle:recv()        -> data ("" when nothing is available), err ("closed" or a message when the link is dead)
-- handle:close()

local M = {}

local socket = require("socket")

local H = {}
H.__index = H

-- Returns handle   or   nil, errorText
function M.open(host, port)
  local s = socket.tcp()
  s:settimeout(0)
  pcall(s.setoption, s, "tcp-nodelay", true)
  local ok, err = s:connect(host, port)
  if not ok and err ~= "timeout" and err ~= "Operation already in progress" then
    s:close()
    if tostring(err):find("restricted", 1, true) then
      return nil, "BeamNG only allows connections to this PC. For a remote server, run the MultiBeam Bridge and add 127.0.0.1:<bridge port> instead."
    end
    return nil, "Could not connect: " .. tostring(err)
  end
  return setmetatable({ s = s }, H)
end

function H:poll()
  local _, w = socket.select(nil, { self.s }, 0)
  if w and w[1] then
    if self.s:getpeername() then return "ok" end
    return "fail", "connection refused"
  end
  return "pending"
end

function H:send(data)
  local sent, err, partial = self.s:send(data)
  if sent then return sent end
  if err == "timeout" then return partial or 0 end
  return nil, err
end

function H:recv()
  local chunk, err, partial = self.s:receive(65536)
  chunk = chunk or partial or ""
  if err == "closed" then return chunk, "closed" end
  if err and err ~= "timeout" then return chunk, err end
  return chunk
end

function H:close()
  pcall(function() self.s:close() end)
end

return M
