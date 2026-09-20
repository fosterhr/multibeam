-- MultiBeam client: multiplayer for BeamNG.drive. Servers are addressed as IP:PORT.
-- The game only lets Lua talk to this PC, so remote servers are reached through the local
-- multibeam-bridge (see transport.lua). Extension name: multibeam_client

local M = {}
local logTag = "multibeam"

local transport = require("ge/extensions/multibeam/transport")
local mods = require("ge/extensions/multibeam/mods")

local PROTOCOL = 5
local SETTINGS_FILE = "/settings/multibeam.json"
local PING_INTERVAL = 4
local CONNECT_TIMEOUT = 15         -- covers a bridge dialling the remote server, and the login reply

-- persisted data
local data = { servers = {}, lastServer = "" }

-- connection
local sock = nil
local status = "idle"      -- idle | connecting | handshake | modsync | loading | connected
local modPrompt = nil       -- the mod changes the player is asked to agree to (shown by the menu)
local leftOnPurpose = false      -- the player chose to leave (as opposed to losing the connection)
local resumeJoin = nil          -- {host, port}: join this server as soon as the game is ready (after a restart for its mods)
local modsRestorePending = false   -- mods were changed for a session and still have to be put back
local statusText = ""
local connectStart = 0
local recvBuf = ""
local sendBuf = ""
local pendingLines = {}    -- lines received while the level is still loading
local pingTimer = 0
local clock = 0
local server = nil         -- welcome info {id, name, map, motd, ...}
local target = nil         -- {host, port, password}
local players = {}         -- pid -> name
local controlling = {}     -- pid -> vid of the vehicle that player is controlling (their avatar on foot, else their car)
local queryProbes = {}     -- "host:port" -> {sock, start, host, port}
local serverInfo = {}      -- "host:port" -> last info reply / error

-- vehicles
local localVehicles = {}   -- gameId -> {vid = "12", spawnTimer = t}
local remoteVehicles = {}  -- "pid:vid" -> {gameId, pid, vid, tgt = {...}}
local remoteByGameId = {}  -- gameId -> "pid:vid"
local spawningRemote = false
local careerMode = false    -- this server runs everyone in their own career save
local reactivate = nil          -- {id, at}: put the player back into this vehicle of theirs and switch it on
local appliedTraffic, appliedParked = nil, nil   -- the AI amounts last set on the traffic system
local hostCheckAt = 0          -- next time the traffic host tidies up the AI system (see onUpdate)
local safeModels = { unicycle = true }   -- car models whose copies start in safe mode (the on-foot avatar always does)
local moduleTimer = 0        -- seconds since the sync modules were last checked in every car
local paintTimer = 0         -- seconds since our cars' colours were last compared with what we sent
local trafficPlayers = 1    -- players in the world; each game runs its share of the AI traffic (career servers)
local trafficCheckAt = 0    -- next time a non-host clears its own AI cars
local uploadAt = nil        -- clock time at which to send the career save even without a fresh save
local careerEnterAt = nil  -- clock time at which to enter the world once the career has finished starting
local ridingId = nil       -- game id of the remote car we are riding in as a passenger
local lastPlayerVeh = nil -- the car we were controlling when we last told the server (for the saved progress)

-- forward declarations
local processLine, sendSpawn, disconnect

-- The player's name is always their Steam name.
local function getPlayerName()
  local ok, steamName = pcall(function()
    return OnlineServiceProvider and OnlineServiceProvider.isWorking and OnlineServiceProvider.playerName or nil
  end)
  if ok and type(steamName) == "string" and steamName ~= "" then
    return (steamName:gsub("[|%c]", ""):sub(1, 24))
  end
  return "Player"
end

-- 64-bit Steam ID as a string, or "" when the game isn't running through Steam.
local function getSteamId()
  local ok, id = pcall(function()
    if OnlineServiceProvider and OnlineServiceProvider.isWorking and OnlineServiceProvider.accountID then
      return tostring(OnlineServiceProvider.accountID)
    end
  end)
  if ok and id and id:match("^%d+$") then return id end
  return ""
end

-- ---------------------------------------------------------------------------------------------
-- persistence
-- ---------------------------------------------------------------------------------------------

local function saveData()
  jsonWriteFile(SETTINGS_FILE, data, true)
end

local function loadData()
  local d = jsonReadFile(SETTINGS_FILE)
  if type(d) == "table" then
    data.servers = type(d.servers) == "table" and d.servers or {}
    data.lastServer = type(d.lastServer) == "string" and d.lastServer or ""
  end
end

-- ---------------------------------------------------------------------------------------------
-- UI plumbing
-- ---------------------------------------------------------------------------------------------

local function uiState()
  local list = {}
  for pid, name in pairs(players) do list[#list + 1] = { id = pid, name = name } end
  table.sort(list, function(a, b) return a.id < b.id end)
  local infos = {}
  for k, v in pairs(serverInfo) do infos[k] = v end
  return {
    status = status,
    statusText = statusText,
    connected = status == "connected",
    server = server and { name = server.name, map = server.map, motd = server.motd, maxPlayers = server.maxPlayers } or nil,
    target = target and { host = target.host, port = target.port } or nil,
    players = list,
    servers = data.servers,
    serverInfo = infos,
    playerName = getPlayerName(),
    lastServer = data.lastServer,
    modPrompt = modPrompt,
    modsInstalled = status == "idle" and mods.installed() or nil,
  }
end

local function pushUI()
  guihooks.trigger("MultiBeamState", uiState())
end

local function setStatus(s, text)
  status = s
  statusText = text or ""
  pushUI()
end

local function toast(kind, title, msg)
  guihooks.trigger("toastrMsg", { type = kind, title = title, msg = msg })
end

-- server / mod notices (there is no chat)
local function notify(text)
  log("I", logTag, text)
  toast("info", "MultiBeam", text)
end

-- ---------------------------------------------------------------------------------------------
-- socket helpers (non-blocking)
-- ---------------------------------------------------------------------------------------------

local function sendLine(line)
  if sock and (status == "handshake" or status == "modsync" or status == "loading" or status == "connected") then
    sendBuf = sendBuf .. line .. "\n"
  end
end

local function flushSend()
  if not sock or sendBuf == "" then return end
  local n, err = sock:send(sendBuf)
  if not n then
    log("E", logTag, "send failed: " .. tostring(err))
    disconnect("Connection lost (" .. tostring(err) .. ")")
    return
  end
  if n > 0 then sendBuf = sendBuf:sub(n + 1) end
  if #sendBuf > 8 * 1024 * 1024 then disconnect("Send buffer overflow") end
end

local MAX_LINES_PER_FRAME = 500

local function pumpReceive()
  if not sock then return end
  for _ = 1, 16 do
    local chunk, err = sock:recv()
    if #chunk > 0 then recvBuf = recvBuf .. chunk end
    if err == "closed" then
      disconnect("Server closed the connection")
      return
    elseif err then
      disconnect("Connection error: " .. tostring(err))
      return
    end
    if #chunk == 0 then break end
  end
  -- Walk the buffer with an index and cut it once at the end. (Chopping each line off the front of a big string
  -- copies the whole remainder every time, which after a stall turns into a very long frame.) A cap on lines per
  -- frame spreads a large backlog over a few frames; the rest stays in the buffer for the next one.
  local pos, handled = 1, 0
  while handled < MAX_LINES_PER_FRAME do
    local nl = recvBuf:find("\n", pos, true)
    if not nl then break end
    local line = recvBuf:sub(pos, nl - 1)
    pos = nl + 1
    handled = handled + 1
    if line ~= "" then
      if status == "loading" then
        -- position updates are stale by the time the level has loaded, and would arrive as one big burst
        if line:sub(1, 2) == "C|" or line:sub(1, 2) == "T|" then
          processLine(line)   -- our career save / who hosts the AI cars: needed before the career starts
        elseif not line:find("^Y|[^|]*|[^|]*|p|") then
          pendingLines[#pendingLines + 1] = line
        end
      else
        processLine(line)
      end
    end
    if not sock then return end
  end
  if pos > 1 then recvBuf = recvBuf:sub(pos) end
end

-- ---------------------------------------------------------------------------------------------
-- vehicle helpers
-- ---------------------------------------------------------------------------------------------

local function isEligible(veh)
  if not veh then return false end
  if veh.playerUsable == false then return false end
  local ok, isTraffic = pcall(function()
    if extensions.gameplay_traffic and extensions.gameplay_traffic.getTrafficData then
      return extensions.gameplay_traffic.getTrafficData()[veh:getID()] ~= nil
    end
    return false
  end)
  if ok and isTraffic then return false end
  return true
end

-- flatten the parts tree into a simple slot -> part map (same as the game's own .pc format 2 save)
local function simplifyConfig(cfg)
  local out = {}
  for k, v in pairs(cfg) do
    if k ~= "partsTree" and k ~= "partConfigFilename" then out[k] = v end
  end
  if cfg.partsTree then
    local map, simple = {}, {}
    local function walk(node)
      if not node then return end
      for _, child in pairs(node.children or {}) do
        map[child.path] = { slotId = child.id, path = child.path, part = child.chosenPartName }
        walk(child)
      end
    end
    walk(cfg.partsTree)
    for path, s in pairs(map) do
      if not simple[s.slotId] then
        simple[s.slotId] = s
      else
        local prev = simple[s.slotId]
        if prev ~= "COLLISION" then simple[prev.path] = prev; simple[s.slotId] = "COLLISION" end
        simple[s.path] = s
      end
    end
    local parts = {}
    for key, s in pairs(simple) do
      if s ~= "COLLISION" then parts[key] = s.part end
    end
    out.parts = parts
  end
  return out
end

local function vehRotation(veh)
  return quatFromDir(-vec3(veh:getDirectionVector()), vec3(veh:getDirectionVectorUp()))
end

local function currentPaints(veh)
  local ok, paints = pcall(function()
    local md = veh:getMetallicPaintData()
    return {
      createVehiclePaint(veh.color, md[1]),
      createVehiclePaint(veh.colorPalette0, md[2]),
      createVehiclePaint(veh.colorPalette1, md[3]),
    }
  end)
  return ok and paints or nil
end

sendSpawn = function(gameId)
  local veh = be:getObjectByID(gameId)
  local lv = localVehicles[gameId]
  if not veh or not lv then return false end
  local vd = extensions.core_vehicle_manager.getVehicleData(gameId)
  if not vd or not vd.config then return false end

  local cfg = simplifyConfig(deepcopy(vd.config))
  cfg.paints = currentPaints(veh) or cfg.paints
  lv.paintSig = jsonEncode(cfg.paints)   -- (a later change is sent as a "c" update, see tickOwnVehicles)
  local plate = veh:getDynDataFieldbyName("licenseText", 0)
  if plate and plate ~= "" then cfg.licenseName = plate end

  local pos = veh:getPosition()
  local rot = quat(veh:getRotation())
  local payload = {
    model = veh:getJBeamFilename(),
    config = cfg,
    pos = { pos.x, pos.y, pos.z },
    rot = { rot.x, rot.y, rot.z, rot.w },
    ign = settings.getValue("spawnVehicleIgnitionLevel") or 3, -- ignition state, so remote engines start like the original
  }
  if lv.ai then
    -- a taxi can be ridden in; the other AI cars cannot be entered
    local ok, isTaxi = pcall(function()
      local td = extensions.gameplay_traffic.getTrafficData()[gameId]
      return td.isTaxi or (td.role and td.role.name == "taxi")
    end)
    if ok and isTaxi then payload.taxi = true end
  end
  sendLine("S|" .. lv.vid .. "|" .. jsonEncode(payload))
  log("I", logTag, "sent vehicle " .. lv.vid .. " (" .. tostring(payload.model) .. ")")
  return true
end

-- In a career the player's own cars are the on-foot avatar and the vehicles of their inventory.
-- (isEligible is not used here: in a career the player's own vehicle is registered as traffic data, which would
-- make it look like an AI car.)
-- whether this server has shared AI traffic at all (older servers do not say, and have it)
local function trafficOn()
  return not (server and server.traffic == false)
end

-- Returns "own" for the player's avatar and inventory cars, "ai" for career traffic and parked cars (which are
-- shared too, with their own limit and lighter sync), or nil.
local function careerSyncable(gameId)
  local veh = be:getObjectByID(gameId)
  if not veh then return nil end
  if veh:getJBeamFilename() == "unicycle" then return "own" end
  local inv = extensions.career_modules_inventory
  if inv ~= nil and inv.getInventoryIdFromVehicleId ~= nil and inv.getInventoryIdFromVehicleId(gameId) ~= nil then
    return "own"
  end
  local ok, isAi = pcall(function()
    local traffic = extensions.gameplay_traffic and extensions.gameplay_traffic.getTrafficData()
    local parked = extensions.gameplay_parking and extensions.gameplay_parking.getParkedCarsData()
    return (traffic and traffic[gameId] ~= nil) or (parked and parked[gameId] ~= nil)
  end)
  if ok and isAi then return "ai" end
  return nil
end

local function localVehicleAdded(gameId)
  local veh = be:getObjectByID(gameId)
  if not careerMode and not isEligible(veh) then return end   -- (careers filter later, see careerSyncable)
  if not veh then return end
  if not localVehicles[gameId] then
    localVehicles[gameId] = { vid = tostring(gameId) }
  end
  localVehicles[gameId].spawnTimer = 0       -- try to send once config data is available
  localVehicles[gameId].sent = false
  localVehicles[gameId].tries = 0
end

-- ---------------------------------------------------------------------------------------------
-- remote vehicles
-- ---------------------------------------------------------------------------------------------

local function removeRemote(key)
  local rv = remoteVehicles[key]
  if not rv then return end
  remoteVehicles[key] = nil
  if rv.gameId then
    remoteByGameId[rv.gameId] = nil
    local veh = be:getObjectByID(rv.gameId)
    if veh then
      spawningRemote = true
      veh:delete()
      spawningRemote = false
    end
  end
end

-- Model shown for other players on foot. The game has three unicycle configs: snowman.pc (the game's default
-- avatar: a snowman), with_mesh.pc (a plain capsule with a direction arrow) and without_mesh.pc (invisible).
local AVATAR_CONFIG = "vehicles/unicycle/snowman.pc"

local function spawnRemote(pid, vid, payload)
  local key = pid .. ":" .. vid
  local model, cfg = payload.model, payload.config
  if type(model) ~= "string" or type(cfg) ~= "table" then return end

  local existing = remoteVehicles[key]
  local ownerName = players[pid] or ("Player " .. pid)

  -- where to put it: the last position received from its owner if we have one, otherwise where it spawned
  local pp, pr = payload.pos, payload.rot
  if existing and existing.position and existing.rotation then pp, pr = existing.position, existing.rotation end
  local pos = vec3(pp[1], pp[2], pp[3])
  local rot = quat(0, 0, 1, 0) * quat(pr[1], pr[2], pr[3], pr[4]) -- vehicles spawn turned 180 degrees

  -- In a career the on-foot avatar has no mesh (the player is only a camera). Other players should still be seen,
  -- so their avatar copy always gets the simple snowman model.
  local cfgArg = model == "unicycle" and AVATAR_CONFIG or serialize(cfg)

  spawningRemote = true
  local ok, err = pcall(function()
    local veh = existing and existing.gameId and be:getObjectByID(existing.gameId)
    if veh then
      veh:setDynDataFieldbyName("autoEnterVehicle", 0, "false")   -- a rebuilt car must not pull the player in either
      spawn.setVehicleObject(veh, { model = model, config = cfgArg, pos = pos, rot = rot, cling = true, autoEnterVehicle = false })
      existing.payload = payload
      existing.model = model
      existing.ign = payload.ign
    else
      veh = spawn.spawnVehicle(model, cfgArg, pos, rot, { autoEnterVehicle = false, vehicleName = "multibeam_remote", cling = true })
      if not veh then error("spawn failed (is '" .. model .. "' installed?)") end
      local id = veh:getID()
      remoteVehicles[key] = {
        gameId = id, pid = pid, vid = vid, name = ownerName, model = model, payload = payload, ign = payload.ign,
        position = existing and existing.position, rotation = existing and existing.rotation,
        spawnedAt = clock, safeMode = safeModels[model] or nil,
      }
      remoteByGameId[id] = key
      if cfg.licenseName == nil or cfg.licenseName == "" then
        pcall(function() core_vehicles.setPlateText(ownerName, id) end)
      end
    end
  end)
  spawningRemote = false
  if not ok then
    log("E", logTag, "could not spawn " .. tostring(model) .. " for " .. ownerName .. ": " .. tostring(err))
    toast("warning", "MultiBeam", "Could not spawn " .. ownerName .. "'s " .. tostring(model) .. ". Is it installed?")
  else
    log("I", logTag, "spawned " .. tostring(model) .. " for " .. ownerName)
  end
end

-- ---------------------------------------------------------------------------------------------
-- Vehicle sync. This follows BeamMP (https://github.com/BeamMP/BeamMP, AGPL-3.0-or-later): every car
-- gets the mb*VE modules (lua/vehicle/extensions/multibeam, ported from BeamMP's *VE modules) loaded into
-- it. The owner's copy samples position, inputs, electrics, powertrain and broken parts on timers and sends
-- them; the receiving side applies them to a PHYSICALLY SIMULATED copy, so collisions and damage happen
-- for real. The VE position code nudges the copy toward the received state with per-physics-step forces.
-- Wire format: "Y|<vid>|<kind>|<json>" up, "Y|<pid>|<vid>|<kind>|<json>" down.
-- ---------------------------------------------------------------------------------------------

local mime = require("mime")

local VE_DIR = "lua/vehicle/extensions/multibeam"

-- how often each kind of data is sampled (seconds), same rates as BeamMP's MPUpdatesGE
local TICKS = {
  { name = "position",   every = 0.020,  cmd = "mbPositionVE.getVehicleRotation()" },
  { name = "inputs",     every = 1 / 30, cmd = "mbInputsVE.getInputs()" },
  { name = "electrics",  every = 1 / 15, cmd = "mbElectricsVE.check()" },
  { name = "powertrain", every = 1 / 10, cmd = "mbPowertrainVE.check()" },
  { name = "nodes",      every = 1 / 15, cmd = "mbNodesVE.getBreakGroups()" },
  { name = "damage",     every = 0.25,   cmd = "mbDamageVE.check()" },  -- MultiBeam: beam damage, owner is the authority
}
-- A car's own Lua can be reloaded (repairs, tuning, the RLS mod's maintenance): the sync modules are then gone and the
-- car silently stops reporting its position. The sampling commands only run when their module exists, and
-- ensureModules (below) puts the modules back.
for _, tick in ipairs(TICKS) do
  local mod = tick.cmd:match("^(%w+)%.")
  if mod then tick.cmd = "if " .. mod .. " then " .. tick.cmd .. " end" end
end
local tickTimers = {}

-- what to call on the vehicle for each received kind (position is handled separately)
local VE_CALLS = {
  i = "mbInputsVE.applyInputs",
  e = "mbElectricsVE.applyElectrics",
  l = "mbPowertrainVE.applyLivePowertrain",
  g = "mbPowertrainVE.applyEngineData",
  b = "mbNodesVE.applyBreakGroups",
  d = "mbDamageVE.applyDamage",       -- beams that changed
  df = "mbDamageVE.applyDamage",      -- every damaged beam (sent now and then, and saved with the profile)
}

local actualSimSpeed = 1
local restoreDamage = {}   -- gameId -> saved damage (json) to apply once a restored car's modules are loaded

local function loadVehicleModules(veh)
  if veh then veh:queueLuaCommand("extensions.loadModulesInDirectory('" .. VE_DIR .. "')") end
end

-- same, but only when the modules are missing (a car whose Lua was reloaded)
local function ensureModules(veh)
  if veh then veh:queueLuaCommand("if not mbVehicleVE then extensions.loadModulesInDirectory('" .. VE_DIR .. "') end") end
end

local function sendSync(kind, data, gameId)
  local lv = localVehicles[gameId]
  if lv and lv.sent and status == "connected" then
    sendLine("Y|" .. lv.vid .. "|" .. kind .. "|" .. data)
  end
end

-- ---- callbacks the vehicle-side modules use to hand us data (names as in the ported VE code) --------

-- BeamMP positionGE.sendVehiclePosRot
function M.sendVehiclePosRot(data, gameVehicleID)
  local decoded = jsonDecode(data)
  if type(decoded) ~= "table" or type(decoded.vel) ~= "table" or type(decoded.rvel) ~= "table" then return end
  local simspeedReal = simTimeAuthority.getReal()

  decoded.isTransitioning = (simTimeAuthority.get() ~= simspeedReal) or nil

  simspeedReal = simTimeAuthority.getPause() and 0 or simspeedReal -- set velocities to 0 if game is paused

  for k, v in pairs(decoded.vel) do decoded.vel[k] = v * simspeedReal end
  for k, v in pairs(decoded.rvel) do decoded.rvel[k] = v * simspeedReal end

  sendSync("p", jsonEncode(decoded), gameVehicleID)
end

function M.sendInputs(data, gameVehicleID) sendSync("i", data, gameVehicleID) end
function M.sendLivePowertrain(data, gameVehicleID) sendSync("l", data, gameVehicleID) end
function M.sendEngineData(data, gameVehicleID) sendSync("g", data, gameVehicleID) end
function M.sendBreakGroups(data, gameVehicleID) sendSync("b", data, gameVehicleID) end
function M.sendDamage(data, gameVehicleID) sendSync("d", data, gameVehicleID) end
function M.sendDamageFull(data, gameVehicleID) sendSync("df", data, gameVehicleID) end
function M.sendNodes() end -- full node sync is not used (BeamMP has it disabled too)

function M.sendElectrics(data, gameVehicleID)
  local lv = localVehicles[gameVehicleID]
  if lv and data ~= lv.lastElectrics then
    sendSync("e", data, gameVehicleID)
    lv.lastElectrics = data
  end
end

-- BeamMP positionGE.setActualSimSpeed / getActualSimSpeed
function M.setActualSimSpeed(speed)
  actualSimSpeed = speed * (1 / simTimeAuthority.getReal())
end

function M.getActualSimSpeed()
  return actualSimSpeed
end

-- BeamMP positionGE.setPositionRotationVelocity (this is done here because setting velocity and rotation
-- in GE doesn't damage vehicles)
function M.setPositionRotationVelocity(gameVehicleID, positionData)
  local pos = positionData.pos
  local newRot = positionData.rot
  local vel = positionData.vel
  local rvel = positionData.rvel
  local veh = be:getObjectByID(gameVehicleID)
  if not veh then return end

  local localVel = veh:getVelocity()
  local vehVel = positionData.vehVel

  if math.abs(localVel.x) + math.abs(localVel.y) + math.abs(localVel.z) > (math.abs(vehVel.x) + math.abs(vehVel.y) + math.abs(vehVel.z)) * 5 then -- detect if velocity was a teleport
    return
  end

  local refNodeID = veh:getRefNodeId()
  local vehRot = quatFromDir(-veh:getDirectionVector(), veh:getDirectionVectorUp())
  local rot = vehRot:inversed() * newRot
  veh:setClusterPosRelRot(refNodeID, pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, rot.w)

  vel = vel - localVel:rotated(rot) -- setClusterPosRelRot also rotates the velocity so we have to do that as well
  veh:applyClusterVelocityScaleAdd(refNodeID, 1, vel.x, vel.y, vel.z) -- setting velocity with the GE command doesn't destroy vehicles so we set most of the velocity here

  local noCounterVelocity = positionData.noCounter or 0
  local onlyAngularVelocity = 1

  -- but since it doesn't do rotational velocity we still need to use VE
  -- apparently GE to VE queues are really fast, so we don't need any extra prediction with this queue
  veh:queueLuaCommand("mbVelocityVE.setAngularVelocity(" .. vel.x .. ", " .. vel.y .. ", " .. vel.z .. ", " .. rvel.x .. ", " .. rvel.y .. ", " .. rvel.z .. "," .. onlyAngularVelocity .. "," .. noCounterVelocity .. ")")
end

-- a copy of one of another player's AI cars that cannot be entered (taxis can)
local function isAiCopy(rv)
  return rv ~= nil and tostring(rv.vid):sub(1, 1) == "t" and not (rv.payload and rv.payload.taxi)
end

-- BeamMP positionGE.setPing: the round trip time feeds the position prediction on every car
local function setPing(pingMs)
  local p = pingMs / 1000
  for i = 0, be:getObjectCount() - 1 do
    local veh = be:getObject(i)
    if veh then veh:queueLuaCommand("mbPositionVE.setPing(" .. p .. ")") end
  end
end

-- a vehicle's extension modules finished loading (BeamMP MPVehicleGE.onVehicleReady)
function M.onVehicleReady(gameVehicleID)
  local veh = be:getObjectByID(gameVehicleID)
  if not veh then return end
  local key = remoteByGameId[gameVehicleID]
  local rv = key and remoteVehicles[key]
  if rv then
    veh:queueLuaCommand("mbVehicleVE.setVehicleType('R'" .. (rv.safeMode and ", true" or "") .. ")")
    veh:queueLuaCommand("hydros.onFFBConfigChanged(nil)")
    veh:queueLuaCommand("mbPowertrainVE.setIgnitionState(" .. tostring(rv.ign or 3) .. ")")
    if rv.active == false then veh:setActive(0) end   -- e.g. an avatar whose owner is in a car
    if isAiCopy(rv) then
      -- AI cars cannot be entered (as in single player, where the walking system keeps traffic off limits), except
      -- taxis, which are how a player rides in AI traffic
      pcall(function() gameplay_walk.addVehicleToBlacklist(gameVehicleID) end)
      veh.playerUsable = false
    end
  end
  -- a car restored from our saved progress gets its saved damage back
  local damage = restoreDamage[gameVehicleID]
  if damage then
    restoreDamage[gameVehicleID] = nil
    veh:queueLuaCommand("mbDamageVE.applyDamage(mime.unb64('" .. mime.b64(damage) .. "'))")
  end
end

-- ---- receiving -------------------------------------------------------------------------------------

-- BeamMP positionGE.applyPos
local snapRemote   -- (defined below: puts a copy at a given place and speed)

local function applyPos(decoded, rv)
  local simspeedFraction = 1
  local gameSpeed = simTimeAuthority.getReal()
  if gameSpeed > 0 then
    simspeedFraction = 1 / gameSpeed
    for k, v in pairs(decoded.vel) do decoded.vel[k] = v * simspeedFraction end
    for k, v in pairs(decoded.rvel) do decoded.rvel[k] = v * simspeedFraction end
  end

  decoded.localSimspeed = simspeedFraction

  local veh = rv.gameId and be:getObjectByID(rv.gameId)
  -- (remembered first: the avatar path below uses them)
  rv.position = decoded.pos
  rv.rotation = decoded.rot
  rv.velocity = decoded.vel
  rv.posTime = clock
  if veh then -- vehicle already spawned, send data
    if not rv.typeSet then
      veh:queueLuaCommand("mbVehicleVE.setVehicleType('R'" .. (rv.safeMode and ", true" or "") .. ")")
      rv.typeSet = true
    end
    if rv.model == "unicycle" then
      -- The on-foot avatar is very light and stands upright by itself, so the forces the position modules use to
      -- ease a car into place make it go unstable. It is simply put where its owner is instead.
      snapRemote(rv, veh, vec3(decoded.pos[1], decoded.pos[2], decoded.pos[3]), vec3(decoded.vel[1], decoded.vel[2], decoded.vel[3]))
    else
      veh:queueLuaCommand("mbPositionVE.setVehiclePosRot(mime.unb64('" .. mime.b64(jsonEncode(decoded)) .. "'))")
    end
  end
end

local function applySync(rv, kind, payload)
  if kind == "r" then
    -- the owner reset or repaired the car (BeamMP MPVehicleGE.onServerVehicleResetted): repeat it here
    if clock - (rv.lastReset or -1) <= 0.2 then return end   -- ignore duplicates
    rv.lastReset = clock
    local veh = rv.gameId and be:getObjectByID(rv.gameId)
    if not veh then return end
    local pr = jsonDecode(payload)
    if type(pr) == "table" and type(pr.pos) == "table" and type(pr.rot) == "table" then
      -- setPositionRotation resets the vehicle (repairing the damage) but not the flex mesh, so do that too
      veh:setPositionRotation(pr.pos.x, pr.pos.y, pr.pos.z, pr.rot.x, pr.rot.y, pr.rot.z, pr.rot.w)
      veh:resetBrokenFlexMesh()
      rv.position = { pr.pos.x, pr.pos.y, pr.pos.z }
      rv.rotation = { pr.rot.x, pr.rot.y, pr.rot.z, pr.rot.w }
    else
      veh:reset()
    end
    return
  end
  if kind == "a" then
    -- the owner switched this car off/on (the on-foot avatar is inactive while they are driving)
    rv.active = payload == "1"
    local veh = rv.gameId and be:getObjectByID(rv.gameId)
    if veh then veh:setActive(rv.active and 1 or 0) end
    return
  end
  if kind == "c" then
    -- the owner's car changed colour (traffic gets repainted when it is recycled)
    local veh = rv.gameId and be:getObjectByID(rv.gameId)
    local paints = jsonDecode(payload)
    if veh and type(paints) == "table" then
      for i = 1, 3 do
        if type(paints[i]) == "table" then
          pcall(function() extensions.core_vehicle_manager.liveUpdateVehicleColors(veh:getID(), veh, i, paints[i]) end)
        end
      end
    end
    return
  end
  if kind == "p" then
    local d = jsonDecode(payload)
    if type(d) == "table" and type(d.pos) == "table" and type(d.rot) == "table" and type(d.vel) == "table" and type(d.rvel) == "table" then
      applyPos(d, rv)
    end
    return
  end
  if rv.safeMode and (kind == "d" or kind == "df") then return end   -- safe mode: no damage sync (see onInstabilityDetected)
  local call = VE_CALLS[kind]
  local veh = rv.gameId and be:getObjectByID(rv.gameId)
  if call and veh then
    veh:queueLuaCommand(call .. "(mime.unb64('" .. mime.b64(payload) .. "'))")
  end
end

-- Watchdog for remote cars. The position modules ease a copy toward the owner's position and only teleport it
-- for big errors, but a copy is a physical object: other cars push it, it snags on things, it lands differently.
-- If it stays clearly away from where its owner says it is (or clearly turned differently), put it back.
local RESYNC_DISTANCE = 3.0     -- metres of error tolerated at rest (more when the car is fast)
local RESYNC_INSTANT = 25       -- metres of error that is fixed at once
local RESYNC_ANGLE = 0.9        -- radians of orientation error tolerated (about 50 degrees)
local RESYNC_AFTER = 1.5        -- how long a smaller error may last before it is fixed (seconds)
local RESYNC_STALE = 1.0        -- ignore the owner's data when it is older than this (they paused / lag)

snapRemote = function(rv, veh, pos, vel)
  local refNodeID = veh:getRefNodeId()
  local curVel = vec3(veh:getVelocity())
  local curRot = quatFromDir(-veh:getDirectionVector(), veh:getDirectionVectorUp())
  local r = rv.rotation
  local rel = curRot:inversed() * quat(r[1], r[2], r[3], r[4])   -- rotation still needed, relative to the car
  -- same pair of calls the game's own teleport and BeamMP's position code use
  veh:setClusterPosRelRot(refNodeID, pos.x, pos.y, pos.z, rel.x, rel.y, rel.z, rel.w)
  local dv = vel - curVel:rotated(rel)   -- the teleport also turned the velocity
  veh:applyClusterVelocityScaleAdd(refNodeID, 1, dv.x, dv.y, dv.z)
end

-- Throw a remote copy away and build a new one where its owner is (the spawn queue's normal path).
-- This only asks for it: the deleting happens from onUpdate. Deleting a car from inside the game's instability
-- callback (which is where this is usually requested) crashed the game.
local function rebuildRemote(rv, delay)
  rv.rebuildPending = true
  rv.rebuildDelay = delay
end

local function performRebuild(rv)
  rv.rebuildPending = nil
  local veh = rv.gameId and be:getObjectByID(rv.gameId)
  if rv.gameId then remoteByGameId[rv.gameId] = nil end
  rv.gameId, rv.typeSet = nil, false
  rv.respawnAt = clock + (rv.rebuildDelay or 0.3)
  rv.rebuildDelay = nil
  if veh then
    spawningRemote = true
    veh:delete()
    spawningRemote = false
  end
end

local function watchRemote(rv, dt)
  if rv.model == "unicycle" then return end   -- avatars are put in place by every update, there is nothing to correct
  local veh = rv.gameId and be:getObjectByID(rv.gameId)
  if rv.respawns and rv.spawnedAt and clock - rv.spawnedAt > 120 then rv.respawns = 0 end   -- it has been fine for a while
  if not veh or not veh:getActive() or not rv.position or not rv.rotation or not rv.posTime then
    rv.badFor = 0
    return
  end
  local age = clock - rv.posTime
  if age > RESYNC_STALE then rv.badFor = 0 return end
  if rv.snapAt and clock - rv.snapAt < 2 then return end   -- let the last correction take effect first
  if rv.spawnedAt and clock - rv.spawnedAt < 2.5 then rv.badFor = 0 return end   -- a new copy is still settling

  local vel = rv.velocity and vec3(rv.velocity[1], rv.velocity[2], rv.velocity[3]) or vec3(0, 0, 0)
  local target = vec3(rv.position[1], rv.position[2], rv.position[3]) + vel * math.min(age, 0.3)
  local speed = vel:length()
  local distance = (vec3(veh:getPosition()) - target):length()

  local r = rv.rotation
  local wanted = quat(r[1], r[2], r[3], r[4])
  local current = quatFromDir(-veh:getDirectionVector(), veh:getDirectionVectorUp())
  local dot = math.abs(wanted.x * current.x + wanted.y * current.y + wanted.z * current.z + wanted.w * current.w)
  local angle = 2 * math.acos(math.min(1, dot))

  if distance > RESYNC_INSTANT + speed * 0.5 then
    rv.badFor = RESYNC_AFTER
  elseif distance > RESYNC_DISTANCE + speed * 0.35 or angle > RESYNC_ANGLE then
    rv.badFor = (rv.badFor or 0) + dt
  else
    rv.badFor = 0
  end

  if rv.badFor >= RESYNC_AFTER then
    rv.badFor = 0
    -- Correcting again and again without the car ever arriving means the copy is broken (stuck, frozen, or never
    -- loaded properly). After two misses in a row, throw it away and build a new one where its owner is.
    if rv.snapAt and clock - rv.snapAt < 8 and distance > RESYNC_INSTANT then
      rv.failedSnaps = (rv.failedSnaps or 0) + 1
    else
      rv.failedSnaps = 0
    end
    rv.snapAt = clock
    local here = vec3(veh:getPosition())
    log("W", logTag, string.format("remote vehicle %s:%s (%s) drifted %.1f m / %.0f deg from its owner, resyncing (copy at %.0f,%.0f,%.0f, target %.0f,%.0f,%.0f, %d misses)",
      tostring(rv.pid), tostring(rv.vid), tostring(rv.model), distance, math.deg(angle), here.x, here.y, here.z, target.x, target.y, target.z, rv.failedSnaps))
    if rv.failedSnaps >= 2 and (rv.respawns or 0) < 5 then
      rv.failedSnaps = 0
      log("W", logTag, "remote vehicle " .. tostring(rv.pid) .. ":" .. tostring(rv.vid) .. " cannot be moved into place, rebuilding it")
      rebuildRemote(rv)
    else
      snapRemote(rv, veh, target, vel)
    end
  end
end

-- The game found a remote car unstable. Stop its motion (the position code puts it back on track).
local function recoverRemote(rv)
  local veh = rv.gameId and be:getObjectByID(rv.gameId)
  if not veh then return end
  veh:applyClusterVelocityScaleAdd(veh:getRefNodeId(), 0, 0, 0, 0)
end


-- ---------------------------------------------------------------------------------------------
-- protocol
-- ---------------------------------------------------------------------------------------------

-- ---- keeping frames short --------------------------------------------------------------------------------
-- Two things make a game hitch when other players are around, and both are spread out here:
--  * Position updates come at 50 Hz per car. After any stall there is a backlog of them, and applying every one
--    floods the vehicle with commands. Only the newest per car matters (the position code works out speed and
--    acceleration from consecutive packets, so it copes with a longer gap), so they are kept and applied once a frame.
--  * Loading a car takes a while (the game parses the whole vehicle). Remote spawns are queued and done one at a
--    time with a gap, and held back while the player is driving fast, so the hitch lands when it matters less.
--    (BeamMP holds spawns for the same reason.)
local SPAWN_GAP = 0.5           -- seconds between two remote spawns
local SPAWN_MAX_SPEED = 8       -- m/s (about 29 km/h): faster than this, spawns wait...
local SPAWN_MAX_WAIT = 8        -- ...for at most this many seconds

local pendingPos = {}           -- "pid:vid" -> newest position payload not applied yet
local spawnQueue = {}           -- entries {key, pid, vid, payload, queuedAt}, oldest first
local queuedByKey = {}          -- key -> entry (a newer config for a queued car replaces the older one)
local queuedSync = {}           -- key -> sync messages that arrived before the car was spawned
local nextSpawnAt = 0

local function queueRemoteSpawn(pid, vid, payload)
  local key = pid .. ":" .. vid
  local entry = queuedByKey[key]
  if entry then
    entry.payload = payload
    return
  end
  entry = { key = key, pid = pid, vid = vid, payload = payload, queuedAt = clock }
  queuedByKey[key] = entry
  spawnQueue[#spawnQueue + 1] = entry
  queuedSync[key] = {}
end

local function cancelQueuedSpawn(key)
  local entry = queuedByKey[key]
  if not entry then return end
  queuedByKey[key] = nil
  queuedSync[key] = nil
  for i, e in ipairs(spawnQueue) do
    if e == entry then table.remove(spawnQueue, i) break end
  end
end

local function clearQueues()
  pendingPos, spawnQueue, queuedByKey, queuedSync = {}, {}, {}, {}
end

local function processSpawnQueue()
  local entry = spawnQueue[1]
  if not entry or clock < nextSpawnAt then return end

  local playerVeh = be:getPlayerVehicle(0)
  local speed = playerVeh and vec3(playerVeh:getVelocity()):length() or 0
  if speed > SPAWN_MAX_SPEED and clock - entry.queuedAt < SPAWN_MAX_WAIT then return end

  table.remove(spawnQueue, 1)
  queuedByKey[entry.key] = nil
  local early = queuedSync[entry.key]
  queuedSync[entry.key] = nil

  -- the spawn data can be old (the owner has driven off, traffic has been moved): put the car where the newest
  -- position update says it is, so it does not start far from where it belongs and need a big correction
  local newest = pendingPos[entry.key]
  if newest then
    local d = jsonDecode(newest)
    if type(d) == "table" and type(d.pos) == "table" and d.pos[1] then entry.payload.pos = d.pos end
  end
  spawnRemote(entry.pid, entry.vid, entry.payload)
  nextSpawnAt = clock + SPAWN_GAP

  -- data for this car that arrived while it waited (avatar on/off, damage, ...)
  local rv = remoteVehicles[entry.key]
  if rv and early then
    for _, msg in ipairs(early) do applySync(rv, msg.kind, msg.payload) end
  end
end

local function flushPendingPositions()
  if next(pendingPos) == nil then return end
  local batch = pendingPos
  pendingPos = {}
  for key, payload in pairs(batch) do
    local rv = remoteVehicles[key]
    if rv then applySync(rv, "p", payload) end
  end
end

local function splitN(s, n)
  -- split on '|' into at most n fields (last field keeps remaining text)
  local out, pos = {}, 1
  for _ = 1, n - 1 do
    local i = s:find("|", pos, true)
    if not i then break end
    out[#out + 1] = s:sub(pos, i - 1)
    pos = i + 1
  end
  out[#out + 1] = s:sub(pos)
  return out
end

local function levelPathForMap(map)
  local level = core_levels.getLevelByName(map)
  if level then return level end
  -- accept "levels/x/info.json" style names too
  local short = tostring(map):match("levels/([^/]+)") or map
  return core_levels.getLevelByName(short)
end

local function currentLevelName()
  local ok, name = pcall(function()
    local f = getMissionFilename and getMissionFilename() or ""
    return f:match("levels/([^/]+)")
  end)
  return ok and name or nil
end

local function enterWorld()
  setStatus("connected", "Connected to " .. tostring(server.name))
  if server.motd and server.motd ~= "" then notify(server.motd) end

  -- Saved progress: the server is about to give back the cars we had. The car or avatar the level spawned
  -- by default would only duplicate them, so remove it first.
  if (server.restore or 0) > 0 then
    local stale = {}
    for i = 0, be:getObjectCount() - 1 do
      local veh = be:getObject(i)
      if veh and not remoteByGameId[veh:getID()] then stale[#stale + 1] = veh end
    end
    for _, veh in ipairs(stale) do
      localVehicles[veh:getID()] = nil
      veh:delete()
    end
    log("I", logTag, "restoring " .. tostring(server.restore) .. " saved vehicle(s)")
  end
  lastPlayerVeh = nil

  -- announce our vehicles, then process everything that arrived while loading
  for gameId in pairs(localVehicles) do localVehicleAdded(gameId) end
  local queued = pendingLines
  pendingLines = {}
  for _, line in ipairs(queued) do processLine(line) end
  -- vehicles that already exist in the level (e.g. the one we spawned with)
  local n = be:getObjectCount()
  for i = 0, n - 1 do
    local veh = be:getObject(i)
    if veh and not remoteByGameId[veh:getID()] then
      loadVehicleModules(veh)   -- cars that were already there before the session began
      localVehicleAdded(veh:getID())
    end
  end
end

-- Career mode: the game's own career runs locally, in a save named after the player's Steam ID, on the server's map.
-- The save is a normal one (Steam ID keeps it apart from the player's single-player careers); the world around it
-- is shared through the usual vehicle sync.
local function setCareerDefaultLevel(name)
  if career_career and career_career.setDefaultLevel then career_career.setDefaultLevel(name) return true end
  return false   -- needs the career.lua override that ships with this mod
end

-- The career save lives on the server. The game needs it as files while it runs, so it is unpacked into a working
-- copy when joining, packed and uploaded after every save, and the working copy is removed again on a clean leave.
local SAVE_ROOT = "settings/cloud/saves/"
local SAVE_SKIP = {   -- big files the game regenerates by itself (shop offers, delivery jobs)
  ["career/logisticsDatabase.json"] = true,
  ["career/vehicleShop.json"] = true,
}
local careerUploaded = false   -- the final save of a clean leave has been sent
local leaving = nil            -- {deadline = t, sent = bool} while a clean leave waits for the last save

local function bare(p)
  return (tostring(p):gsub("\\", "/"):gsub("^/+", ""))
end

-- Which career the game is running: the base game's, or the RLS Career Overhaul (which has its own save format and
-- refuses saves of the other kind). A server's career save is only used by the same kind, and each kind has its own
-- local profile name, so they can never be mixed up.
local function careerFlavor()
  if extensions.overhaul_extensionManager or extensions.career_saveMigration then return "rls" end
  return "base"
end

local function careerProfileName()
  local digits = getSteamId():gsub("%D", "")
  return "multibeam" .. (careerFlavor() == "rls" and "rls" or "") .. (digits ~= "" and digits or "player")
end

-- reads a save folder into {date, files = {relative path = text}, total bytes}
local function packSave(folder)
  folder = bare(folder)
  local info = jsonReadFile(folder .. "/info.json")
  if type(info) ~= "table" or not info.date or info.corrupted then return nil end
  local files, total = {}, 0
  for _, full in ipairs(FS:findFiles("/" .. folder, "*", -1, true, false)) do
    local f = bare(full)
    local rel = f:sub(1, #folder) == folder and f:sub(#folder + 2) or ""
    -- (only the json files: a save also has thumbnails, and those are binary)
    if rel ~= "" and not SAVE_SKIP[rel] and rel:find("%.json$") then
      local content = readFile(full)
      if content then files[rel] = content; total = total + #content end
    end
  end
  return info.date, files, total
end

local function uploadCareer()
  if not (careerMode and sock and status == "connected" and career_saveSystem) then return false end
  local _, folder = career_saveSystem.getCurrentProfile()
  if not folder or folder == "" then return false end
  local date, files, total = packSave(folder)
  if not date or total == 0 then return false end
  sendLine("C|" .. date .. "|" .. jsonEncode({ files = files, flavor = careerFlavor() }))
  log("I", logTag, "uploaded career save (" .. math.floor(total / 1024) .. " KB)")
  return true
end

local function localSaveDate(profile)
  local folder = career_saveSystem.getNewestSave(SAVE_ROOT .. profile)
  if not folder or folder == "" then return "0" end
  local info = jsonReadFile(bare(folder) .. "/info.json")
  return (type(info) == "table" and info.date and not info.corrupted) and info.date or "0"
end

local function unpackSave(profile, files)
  local dir = SAVE_ROOT .. profile .. "/autosave1/"
  local made = {}
  for rel, content in pairs(files) do
    if type(rel) == "string" and type(content) == "string" and not rel:find("%.%.") and not rel:find("^[/\\]")
        and not rel:find('[<>:"|?*\\]') then
      local parent = (dir .. rel):match("^(.*)/[^/]*$")
      if parent and not made[parent] then
        made[parent] = true
        pcall(function() FS:directoryCreate(parent, true) end)
      end
      writeFile(dir .. rel, content)
    end
  end
end

local startCareer

-- the server's copy of our save arrived: "date|json" (date "0" = none yet)
local function receiveCareerSave(data)
  if not (server and server.career) or careerMode then return end
  if not (career_career and career_saveSystem) then
    disconnect("This game version has no career mode.")
    return
  end
  local profile = careerProfileName()
  local sep = data:find("|", 1, true) or 1
  local serverDate, json = data:sub(1, sep - 1), data:sub(sep + 1)
  local decoded = json ~= "" and jsonDecode(json) or nil
  local files = type(decoded) == "table" and decoded.files or nil
  if files and (decoded.flavor or "base") ~= careerFlavor() then
    -- saved by the other kind of career (e.g. before the server had the RLS mod): it cannot be loaded, so this
    -- starts a new career here, and the next save replaces the server's old one
    log("W", logTag, "the server's career save is a " .. tostring(decoded.flavor or "base") .. " career; starting a new " .. careerFlavor() .. " career")
    files, serverDate = nil, "0"
  end

  if type(files) == "table" and serverDate > localSaveDate(profile) then
    FS:directoryRemove(SAVE_ROOT .. profile)   -- the server's copy is the real one
    unpackSave(profile, files)
    log("I", logTag, "loaded career save from the server (" .. serverDate .. ")")
  elseif localSaveDate(profile) ~= "0" then
    -- a copy on this PC is newer than the server's (the last session ended without reaching the server): keep it
    -- and send it up once we are in
    log("W", logTag, "local career save is newer than the server's; keeping it")
    uploadAt = clock + 20
  else
    FS:directoryRemove(SAVE_ROOT .. profile)   -- new career
    -- The game starts every new career on west_coast_usa. On another map, write the first save by hand so it
    -- already says which map to start on.
    local map = tostring(server.map)
    if map:lower() ~= "west_coast_usa" and careerFlavor() == "base" then   -- (RLS is told the map directly, below)
      local stamp = os.date("!%Y-%m-%dT%H:%M:%SZ")
      local dir = SAVE_ROOT .. profile .. "/autosave1/"
      pcall(function() FS:directoryCreate(dir .. "career", true) end)
      jsonWriteFile(dir .. "info.json", {
        version = career_saveSystem.getSaveSystemVersion(), date = stamp, creationDate = stamp, displayName = profile,
      }, true)
      jsonWriteFile(dir .. "career/general.json", {
        level = map, startingOptions = { startMode = "multibeam" }, boughtStarterVehicle = false,
      }, true)
    end
  end
  startCareer(profile)
end

startCareer = function(profile)
  if not (career_career and career_saveSystem) then
    disconnect("This game version has no career mode.")
    return
  end
  local mapName = tostring(server.map)
  setCareerDefaultLevel(mapName)   -- (only has an effect where the game exposes it; see receiveCareerSave)
  -- a save made on another server/map moves to this map (positions of cars in the inventory are re-derived)
  if career_saveSystem.setProfile(profile) then
    local _, savePath = career_saveSystem.getCurrentProfile()
    local file = tostring(savePath) .. "/career/general.json"
    local saved = jsonReadFile(file)
    if type(saved) == "table" and saved.level and string.lower(saved.level) ~= string.lower(mapName) then
      saved.level = mapName
      jsonWriteFile(file, saved, true)
    end
  end
  setStatus("loading", "Starting career on " .. mapName .. "...")
  careerMode = true
  log("I", logTag, "starting career profile " .. profile .. " on " .. mapName)
  -- (careerStartMode and startingMap are what the RLS Career Overhaul reads; the base game reads startMode)
  if not career_career.createOrLoadCareerAndStart(profile, nil, { startMode = "multibeam", careerStartMode = "career", startingMap = mapName }) then
    disconnect("Could not start the career save.")
  end
end

local function startLevelLoad()
  if server.career then
    setStatus("loading", "Loading your career...")   -- the save arrives next (C line), then the career starts
    return
  end
  local wanted = server.map
  if currentLevelName() and wanted and string.lower(currentLevelName()) == string.lower(wanted) then
    enterWorld()
    return
  end
  local level = levelPathForMap(wanted)
  if not level then
    local msg = "This server uses the map '" .. tostring(wanted) .. "', which you don't have."
    toast("error", "MultiBeam", msg)
    disconnect(msg)
    return
  end
  setStatus("loading", "Loading " .. tostring(level.title or wanted) .. "...")
  -- leave any running level cleanly; vehicles of the old session are gone with it.
  -- With saved vehicles to restore, don't let the level spawn its default one.
  spawn.preventPlayerSpawning = (server.restore or 0) > 0 or nil
  freeroam_freeroam.startFreeroam(level)
end

processLine = function(line)
  local t = line:sub(1, 1)
  if t == "W" then
    local info = jsonDecode(line:sub(3))
    if type(info) ~= "table" then disconnect("Bad reply from server") return end
    server = info
    players[info.id] = info.you or getPlayerName()   -- the server may have made the name unique
    log("I", logTag, "joined '" .. tostring(info.name) .. "' as player #" .. tostring(info.id) .. ", map " .. tostring(info.map))
    startLevelLoad()
  elseif t == "E" then
    local msg = line:sub(3)
    toast("error", "MultiBeam", msg)
    disconnect(msg)
  elseif t == "J" then
    local f = splitN(line:sub(3), 2)
    players[tonumber(f[1])] = f[2]
    pushUI()
  elseif t == "L" then
    local pid = tonumber(line:sub(3))
    players[pid] = nil
    controlling[pid] = nil
    for key, rv in pairs(remoteVehicles) do
      if rv.pid == pid then removeRemote(key) end
    end
    local waiting = {}
    for _, entry in ipairs(spawnQueue) do
      if entry.pid == pid then waiting[#waiting + 1] = entry.key end
    end
    for _, key in ipairs(waiting) do cancelQueuedSpawn(key) end
    pushUI()
  elseif t == "S" then
    local f = splitN(line:sub(3), 3)
    local pid, vid = tonumber(f[1]), f[2]
    local payload = jsonDecode(f[3] or "")
    if pid and vid and type(payload) == "table" and type(payload.pos) == "table" and type(payload.rot) == "table" then
      queueRemoteSpawn(pid, vid, payload)
    end
  elseif t == "D" then
    local f = splitN(line:sub(3), 2)
    local key = f[1] .. ":" .. tostring(f[2])
    cancelQueuedSpawn(key)
    pendingPos[key] = nil
    removeRemote(key)
  elseif t == "F" then
    -- which vehicle a player is controlling now: pid|vid
    local f = splitN(line:sub(3), 2)
    local pid = tonumber(f[1])
    if pid and f[2] then controlling[pid] = f[2] end
  elseif t == "Y" then
    -- synced vehicle data from another player: pid|vid|kind|json
    local f = splitN(line:sub(3), 4)
    local key = f[1] .. ":" .. tostring(f[2])
    local kind, payload = f[3], f[4]
    if kind == "p" then
      pendingPos[key] = payload   -- only the newest position per car is applied (see flushPendingPositions)
    elseif kind and payload then
      local rv = remoteVehicles[key]
      if rv then
        applySync(rv, kind, payload)
      elseif queuedByKey[key] then
        local early = queuedSync[key]   -- the car is still waiting in the spawn queue: keep its data for later
        if early and #early < 300 then early[#early + 1] = { kind = kind, payload = payload } end
      end
    end
  elseif t == "K" then
    -- pong: the token is the local clock in ms when the ping left
    local sent = tonumber(line:sub(3))
    if sent then
      local rtt = math.floor(clock * 1000) - sent
      if rtt >= 0 and rtt < 5000 then setPing(rtt) end
    end
  elseif t == "Q" then
    -- mod management: Q|B|count, Q|M|name|size|sha1, Q|E, Q|D|name|offset|data, Q|O
    local f = splitN(line:sub(3), 5)
    if f[1] == "B" then setStatus("modsync", "Checking the server's mods...") end
    mods.line(f[1], f[2], f[3], f[4], f[5])
  elseif t == "C" then
    receiveCareerSave(line:sub(3))
  elseif t == "T" then
    trafficPlayers = tonumber(line:sub(3)) or 1   -- how many players share the world's traffic
  elseif t == "M" then
    notify(line:sub(3))
  elseif t == "R" then
    -- saved progress: R|active|current|state|payload. Spawn the car as our own where we left it, switched off
    -- if it was (the on-foot avatar while driving), and get back into the one we were controlling.
    local f = splitN(line:sub(3), 5)   -- active | current | state | damage | payload
    local isActive, isCurrent = f[1] ~= "0", f[2] == "1"
    local st = jsonDecode(f[3] or "")
    local savedDamage = f[4] ~= "0" and f[4] or nil
    local payload = jsonDecode(f[5] or "")
    if type(payload) == "table" and type(st) == "table" and type(st.pos) == "table" and type(st.rot) == "table"
        and type(payload.config) == "table" then
      local pos = vec3(st.pos[1], st.pos[2], st.pos[3])
      local rot = quat(0, 0, 1, 0) * quat(st.rot[1], st.rot[2], st.rot[3], st.rot[4])
      local ok, err = pcall(function()
        local veh = spawn.spawnVehicle(payload.model, serialize(payload.config), pos, rot,
          { autoEnterVehicle = isCurrent, vehicleName = "multibeam_local", cling = true })
        if veh and not isActive then veh:setActive(0) end
        if veh and savedDamage then restoreDamage[veh:getID()] = savedDamage end
      end)
      if not ok then log("E", logTag, "could not restore vehicle: " .. tostring(err)) end
    end
  elseif t == "X" then
    -- server refused this vehicle (limit reached): remove it locally
    local id = tonumber(line:sub(3))
    local veh = id and be:getObjectByID(id)
    if veh then localVehicles[id] = nil; veh:delete() end
  end
end

-- ---------------------------------------------------------------------------------------------
-- connection management
-- ---------------------------------------------------------------------------------------------

local function closeSocket()
  if sock then pcall(function() sock:close() end) end
  sock = nil
  recvBuf, sendBuf = "", ""
end

-- Ends the session. If we were in the server's world (or loading into it) the game goes back to the title screen,
-- since what is left is a level with no server behind it (server closed, connection lost, kicked, or the player
-- chose to disconnect). `stay` skips that, for callers where the level is already going away or a new join follows.
disconnect = function(reason, stay)
  local wasConnected = status ~= "idle"
  local wasInWorld = status == "connected" or status == "loading"
  if careerMode then
    -- leave the career cleanly: keep the progress, and don't leave career modules running on the title screen
    careerMode, careerEnterAt, uploadAt, leaving, trafficPlayers = false, nil, nil, nil, 1
    appliedTraffic, appliedParked = nil, nil
    pcall(function()
      if career_career and career_career.isActive() then
        -- when the last save did not reach the server, keep a fresh one on this PC; it is used next time (see
        -- receiveCareerSave). After a clean leave the server has everything and the working copy is removed.
        if not careerUploaded then career_saveSystem.saveCurrent() end
        career_career.deactivateCareer()
        if careerUploaded then
          career_saveSystem.setProfile(nil)
          FS:directoryRemove(SAVE_ROOT .. careerProfileName())
        end
      end
    end)
    careerUploaded = false
  end
  closeSocket()
  mods.abort()
  modPrompt = nil
  -- The mods are put back (once the game is out of the level, see onUpdate) only when the player left on purpose. A
  -- dropped connection or a restarted server leaves them in place so that rejoining needs no new download.
  if leftOnPurpose then
    leftOnPurpose = false
    modsRestorePending = mods.markPendingRestore()
  end
  for key in pairs(remoteVehicles) do removeRemote(key) end
  remoteVehicles, remoteByGameId = {}, {}
  clearQueues()
  pendingLines = {}
  players = {}
  controlling = {}
  server = nil
  if wasConnected then
    for _, lv in pairs(localVehicles) do lv.sent = false end
    if reason and reason ~= "" then
      statusText = reason
      log("I", logTag, "disconnected: " .. reason)
    end
    status = "idle"
    pushUI()
  end
  if wasInWorld and not stay then
    spawn.preventPlayerSpawning = nil
    if reason and reason ~= "" then toast("warning", "MultiBeam", reason) end
    returnToMainMenu()
  end
end

function M.join(host, port, password)
  host = tostring(host or ""):gsub("^%s+", ""):gsub("%s+$", "")
  port = tonumber(port) or 30814
  if host == "" then setStatus("idle", "Enter an IP address.") return false end
  if status ~= "idle" then disconnect(nil, true) end   -- switching servers: no trip to the title screen

  local s, err = transport.open(host, port)
  if not s then
    setStatus("idle", tostring(err))
    return false
  end
  log("I", logTag, "connecting to " .. host .. ":" .. port)
  sock = s
  target = { host = host, port = port, password = password or "" }
  data.lastServer = host .. ":" .. port
  saveData()
  connectStart = clock
  setStatus("connecting", "Connecting to " .. host .. ":" .. port .. "...")
  return true
end

function M.leave()
  if status == "idle" then return end
  leftOnPurpose = true
  -- a career gets one last save, sent to the server, before leaving
  if careerMode and status == "connected" and not leaving and career_career and career_career.isActive() then
    leaving = { deadline = clock + 10 }
    career_saveSystem.saveCurrent()
    return
  end
  disconnect("Left the server")
  -- back to a normal single-player session state
  spawn.preventPlayerSpawning = false
end

-- ---------------------------------------------------------------------------------------------
-- server list (favourites) + status probes
-- ---------------------------------------------------------------------------------------------

function M.getServers() return data.servers end
function M.getState() return uiState() end

function M.addServer(name, host, port)
  host = tostring(host or ""):gsub("^%s+", ""):gsub("%s+$", "")
  port = tonumber(port) or 30814
  if host == "" then return false end
  for _, s in ipairs(data.servers) do
    if s.host == host and s.port == port then
      s.name = (name and name ~= "") and name or s.name
      saveData(); pushUI()
      return true
    end
  end
  data.servers[#data.servers + 1] = { name = (name and name ~= "") and name or (host .. ":" .. port), host = host, port = port }
  saveData()
  pushUI()
  return true
end

function M.removeServer(host, port)
  for i, s in ipairs(data.servers) do
    if s.host == host and s.port == tonumber(port) then
      table.remove(data.servers, i)
      break
    end
  end
  saveData()
  pushUI()
end

-- Pings one server (or all favourites when called without args) for name / player count / map.
function M.query(host, port)
  local function start(h, p)
    local key = h .. ":" .. p
    if queryProbes[key] then return end
    local s, err = transport.open(h, p)
    if not s then
      serverInfo[key] = { online = false, error = tostring(err) }
      return
    end
    serverInfo[key] = { online = nil, pending = true }
    queryProbes[key] = { sock = s, start = clock, host = h, port = p, buf = "", sent = false }
  end
  if host then
    start(tostring(host), tonumber(port) or 30814)
  else
    for _, s in ipairs(data.servers) do start(s.host, s.port) end
  end
  pushUI()
end

local function updateProbes()
  local changed = false
  for key, p in pairs(queryProbes) do
    local done = false
    if clock - p.start > 4 then
      serverInfo[key] = { online = false }
      done = true
    else
      if not p.sent then
        local state = p.sock:poll()
        if state == "ok" then
          p.sock:send("I\n")
          p.sent = true
        elseif state == "fail" then
          serverInfo[key] = { online = false }
          done = true
        end
      end
      if p.sent then
        local chunk, err = p.sock:recv()
        if #chunk > 0 then p.buf = p.buf .. chunk end
        local nl = p.buf:find("\n", 1, true)
        if nl then
          local line = p.buf:sub(1, nl - 1)
          local info = line:sub(1, 2) == "I|" and jsonDecode(line:sub(3)) or nil
          if type(info) == "table" then
            info.online = true
            serverInfo[key] = info
          else
            serverInfo[key] = { online = false }
          end
          done = true
        elseif err then
          serverInfo[key] = { online = false }
          done = true
        end
      end
    end
    if done then
      p.sock:close()
      queryProbes[key] = nil
      changed = true
    end
  end
  if changed then pushUI() end
end

-- ---------------------------------------------------------------------------------------------
-- game hooks
-- ---------------------------------------------------------------------------------------------

local function checkConnecting()
  if not sock then return end
  local state, perr = sock:poll()
  if state == "ok" then
    sendBuf = ""
    recvBuf = ""
    status = "handshake"
    sendLine(string.format("H|%d|%s|%s|%s", PROTOCOL, getPlayerName(), target.password or "", getSteamId()))
    setStatus("handshake", "Logging in...")
    return
  elseif state == "fail" then
    local msg = "Could not connect to " .. target.host .. ":" .. target.port .. " (" .. tostring(perr) .. ")"
    toast("error", "MultiBeam", msg)
    disconnect(msg)
    return
  end
  if clock - connectStart > CONNECT_TIMEOUT then
    local msg = "Connection to " .. target.host .. ":" .. target.port .. " timed out"
    toast("error", "MultiBeam", msg)
    disconnect(msg)
  end
end

-- sample our own cars on the BeamMP timers (MPUpdatesGE); the vehicle modules reply through the M.send* callbacks
local function tickOwnVehicles(dt)
  -- which of our cars we are controlling (the server saves it, so we are put back in the same one)
  local controlled = be:getPlayerVehicleID(0)
  if controlled ~= lastPlayerVeh then
    local lv = localVehicles[controlled]
    if lv and lv.sent then
      lastPlayerVeh = controlled
      sendLine("F|" .. lv.vid)
    end
  end

  -- put the sync modules back into any car that lost them
  moduleTimer = moduleTimer + dt
  if moduleTimer >= 2 then
    moduleTimer = 0
    for gameId, lv in pairs(localVehicles) do
      if lv.sent then ensureModules(be:getObjectByID(gameId)) end
    end
    for gameId in pairs(remoteByGameId) do ensureModules(be:getObjectByID(gameId)) end
  end

  -- colour changes (traffic is repainted when it is recycled, players repaint their cars): send the new paint
  paintTimer = paintTimer + dt
  if paintTimer >= 2 then
    paintTimer = 0
    for gameId, lv in pairs(localVehicles) do
      if lv.sent and lv.paintSig then
        local veh = be:getObjectByID(gameId)
        local paints = veh and currentPaints(veh)
        local sig = paints and jsonEncode(paints)
        if sig and sig ~= lv.paintSig then
          lv.paintSig = sig
          sendSync("c", sig, gameId)
        end
      end
    end
  end

  -- the game switches the on-foot avatar off when its owner gets into a car and on again when they get out
  -- (gameplay_walk: setActive). Tell everyone, or their copy of the avatar keeps standing where it was.
  for gameId, lv in pairs(localVehicles) do
    if lv.sent then
      local veh = be:getObjectByID(gameId)
      if veh then
        local active = veh:getActive() and "1" or "0"
        if active ~= lv.active then
          lv.active = active
          sendSync("a", active, gameId)
        end
      end
    end
  end

  for _, tick in ipairs(TICKS) do
    local t = (tickTimers[tick.name] or 0) + dt
    if t >= tick.every then
      t = (t - tick.every) % tick.every
      for gameId, lv in pairs(localVehicles) do
        -- AI cars only send position (a fifth as often) and damage: no inputs, electrics or powertrain
        local due = lv.sent
        if due and lv.ai then
          if tick.name == "position" then
            lv.posTicks = (lv.posTicks or 0) + 1
            due = lv.posTicks % 5 == 0
          else
            due = tick.name == "damage"
          end
        end
        if due then
          local veh = be:getObjectByID(gameId)
          if veh then veh:queueLuaCommand(tick.cmd) end
        end
      end
    end
    tickTimers[tick.name] = t
  end
end


-- ---------------------------------------------------------------------------------------------
-- Player indicators. Every other player is shown in three places, all from the same list:
--   in the world   a black bar over their head/car: "<name> - <distance> mi"
--   minimap        a small dot (drawn from the game's onDrawOnMinimap hook)
--   big map        the same dot, drawn in the map view (debugDrawer, like the game's own route lines)
-- The indicator belongs to the player, not to every car they own: their avatar while on foot, the car while they
-- drive it. Parked cars and the switched-off avatar get none. (Until we hear what a player controls, whatever
-- is active is labelled.)
-- ---------------------------------------------------------------------------------------------

local tagTextColor = ColorF(1, 1, 1, 1)
local tagBackColor = ColorI(0, 0, 0, 230)
local dotFill, dotStroke = ColorI(255, 255, 255, 255), ColorI(0, 0, 0, 255)
local miniFill, miniStroke   -- (made on first use, see onDrawOnMinimap)
local mapDotFill, mapDotStroke = ColorF(1, 1, 1, 1), ColorF(0, 0, 0, 1)
local tagErrorLogged = false

local function formatMiles(meters)
  return string.format("%.2f mi", meters / 1609.344)
end

-- where we are, for distances: the player's own vehicle or avatar, else the camera
local function ownPosition()
  local mine = be:getPlayerVehicle(0)
  if mine then return vec3(mine:getPosition()) end
  return vec3(core_camera.getPosition())
end

-- players other than us that have something visible, with a position for each
local function playerIndicators()
  -- One indicator per player: the vehicle they are controlling if we know it and it is in play; otherwise their
  -- on-foot avatar if that is in play (when someone climbs out, the update saying so can arrive after the avatar
  -- switched on); otherwise any car of theirs that is in play. AI cars are not players.
  local best = {}
  for _, rv in pairs(remoteVehicles) do
    local veh = rv.gameId and be:getObjectByID(rv.gameId)
    if veh and veh:getActive() and tostring(rv.vid):sub(1, 1) ~= "t" then
      local score = (controlling[rv.pid] == rv.vid) and 3 or (rv.model == "unicycle" and 2 or 1)
      if not best[rv.pid] or score > best[rv.pid].score then best[rv.pid] = { rv = rv, veh = veh, score = score } end
    end
  end
  local list = {}
  for pid, b in pairs(best) do
    local rv = b.rv
    -- from the position the owner reported, carried forward by their speed (the copy itself can lag)
    local pos = vec3(b.veh:getPosition())
    if rv.position and rv.posTime then
      local age = math.min(clock - rv.posTime, 0.5)
      local v = rv.velocity or { 0, 0, 0 }
      pos = vec3(rv.position[1] + (v[1] or 0) * age, rv.position[2] + (v[2] or 0) * age, rv.position[3] + (v[3] or 0) * age)
    end
    list[#list + 1] = { rv = rv, veh = b.veh, pos = pos, name = players[pid] or ("Player " .. tostring(pid)) }
  end
  return list
end
-- ---- name tags ---------------------------------------------------------------------------------------------
-- The tag is a billboard from the game's own multiplayer name-tag system (render/playerTags.lua, the same "Skia
-- billboard" renderer the game uses for split-screen player tags): a picture of the label, drawn in the world,
-- always facing the camera, centred exactly on the point it is given. Nothing else is drawn, so there is no
-- line to the car. (The text call used before draws a leader line from the label to its anchor.)
-- The label is a plain black bar with white text: "<name> - <distance> mi".

local TAG_DESIGN = {
  name = "MultiBeam name tag", type = "mptag", size = { 512, 96 },
  root = { children = {
    { type = "box", radius = 14, color = "#000000f2", style = { position = "absolute", left = 0, top = 0, right = 0, bottom = 0 } },
    { type = "group", style = { flexDirection = "row", alignItems = "center", justifyContent = "center", width = "100%", height = "100%", paddingLeft = 16, paddingRight = 16 },
      children = {
        { type = "text", text = "{label}", fontSize = 52, color = "#ffffff", fit = "shrink", textAlign = "center", style = { width = "100%", height = 60 } },
      } },
  } },
}

local tagRenderer = nil      -- the game's billboard renderer object
local tags = {}              -- player id -> {id = billboard id, text = what it shows, at = when it was made}
local billboardsFailed = false

local function tagRendererObject()
  if tagRenderer and tagRenderer.create then return tagRenderer end
  if scenetree and scenetree.multibeamNameTags then tagRenderer = scenetree.multibeamNameTags return tagRenderer end
  if not (WorldBillboardRenderer and scenetree and scenetree.MissionGroup) then return nil end
  local r = WorldBillboardRenderer()
  if not r then return nil end
  r:registerObject("multibeamNameTags")
  scenetree.MissionGroup:addObject(r)
  tagRenderer = r
  return r
end

-- forget every tag (the level is going away, or we are disconnecting)
local function destroyTags()
  if tagRenderer then
    for _, t in pairs(tags) do pcall(function() tagRenderer:destroy(t.id) end) end
  end
  tags = {}
  tagRenderer = nil
end

local function drawNameTags()
  local list = playerIndicators()
  local me = ownPosition()
  local r = not billboardsFailed and tagRendererObject()
  if not r then return end
  if not extensions.core_skiaTemplate then extensions.load("core_skiaTemplate") end
  local skia = extensions.core_skiaTemplate
  if not skia then return end

  local cam = vec3(core_camera.getPosition())
  local seen = {}
  for _, p in ipairs(list) do
    local pid = p.rv.pid
    seen[pid] = true
    local text = p.name .. " - " .. formatMiles((p.pos - me):length())
    local tag = tags[pid]
    -- the picture is drawn once, so it is made again when the words change (the distance, twice a second at most)
    if not tag or (tag.text ~= text and clock - tag.at > 0.5) then
      local resolved = skia.resolveTemplate(TAG_DESIGN, { label = text })
      local id = resolved and r:create(jsonEncode(resolved), false)
      if id and id ~= 0 then
        r:render(id, "{}")
        if tag then pcall(function() r:destroy(tag.id) end) end
        tag = { id = id, text = text, at = clock }
        tags[pid] = tag
      end
    end
    if tag then
      local box = p.veh:getSpawnWorldOOBB()
      local head = box:getCenter()
      head.z = head.z + box:getHalfExtents().z + 0.45   -- just above the roof / head
      -- bigger with distance so it stays readable from far away
      r:update(tag.id, head, clamp((cam - head):length() * 0.04, 0.45, 5), true)
    end
  end
  for pid, tag in pairs(tags) do
    if not seen[pid] then
      pcall(function() r:destroy(tag.id) end)
      tags[pid] = nil
    end
  end
end
-- big map: a dot per player, sized by how far the map camera is so it stays small on screen
local function drawBigMapDots()
  local bm = freeroam_bigMapMode
  if not (bm and bm.bigMapActive and bm.bigMapActive()) then return end
  local cam = vec3(core_camera.getPosition())
  for _, p in ipairs(playerIndicators()) do
    local radius = math.max(1.5, (cam - p.pos):length() * 0.006)
    debugDrawer:drawSphere(p.pos, radius * 1.35, mapDotStroke)
    debugDrawer:drawSphere(p.pos, radius, mapDotFill)
  end
end

-- minimap: the game calls this while drawing the minimap
local minimapErrorLogged = false

function M.onDrawOnMinimap()
  if status ~= "connected" then return end
  local utils = ui_apps_minimap_utils
  if not (utils and utils.simpleCircle) then return end
  -- The minimap draws with the game's own colour type, color(r, g, b, a) (its other markers are made that way);
  -- a ColorI is not accepted there and drew nothing.
  miniFill = miniFill or (color and color(255, 255, 255, 255)) or dotFill
  miniStroke = miniStroke or (color and color(0, 0, 0, 255)) or dotStroke
  local ok, err = pcall(function()
    for _, p in ipairs(playerIndicators()) do
      utils.simpleCircle(p.pos, miniFill, miniStroke, 5)
    end
  end)
  if not ok and not minimapErrorLogged then
    minimapErrorLogged = true
    log("E", logTag, "could not draw players on the minimap: " .. tostring(err))
  end
end

function M.onUpdate(dt)
  clock = clock + dt
  if status ~= "connected" and tagRenderer then destroyTags() end   -- (name tags only exist while playing on a server)
  if modsRestorePending and status == "idle" and not getCurrentLevelIdentifier() and core_modmanager and core_modmanager.isReady() then
    modsRestorePending = false
    mods.restore()
  end
  if status == "modsync" then mods.tick() end
  if resumeJoin and status == "idle" and clock > 6 and not getCurrentLevelIdentifier() and core_modmanager and core_modmanager.isReady() then
    local r = resumeJoin
    resumeJoin = nil
    log("I", logTag, "rejoining " .. tostring(r.host) .. ":" .. tostring(r.port) .. " after the restart")
    M.join(r.host, r.port, "")
  end
  updateProbes()
  if status == "idle" then return end

  if status == "connecting" then
    checkConnecting()
    flushSend()
    return
  end

  pumpReceive()
  if not sock then return end
  flushPendingPositions()

  if leaving then
    -- finished once the last save is sent and out of the buffer (plus a moment for the bridge), or after a timeout
    if leaving.sent and sendBuf == "" then
      leaving.drained = leaving.drained or (clock + 1)
    end
    if (leaving.drained and clock >= leaving.drained) or clock >= leaving.deadline then
      leaving = nil
      disconnect("Left the server")
      spawn.preventPlayerSpawning = false
      return
    end
  end
  if uploadAt and clock >= uploadAt and status == "connected" then
    uploadAt = nil
    uploadCareer()
  end

  if reactivate and clock >= reactivate.at then
    local back = be:getObjectByID(reactivate.id)
    reactivate = nil
    if back then
      back:setActive(1)
      if be:getPlayerVehicleID(0) ~= back:getID() then be:enterVehicle(0, back) end
    end
  end

  if careerEnterAt and clock >= careerEnterAt then
    careerEnterAt = nil
    if status == "loading" and server then enterWorld() end
  end

  if status == "handshake" and clock - connectStart > CONNECT_TIMEOUT then
    local msg = "No reply from " .. target.host .. ":" .. target.port
    toast("error", "MultiBeam", msg)
    disconnect(msg)
    return
  end

  if status == "connected" then
    -- announce new / changed local vehicles once their config data is ready
    for gameId, lv in pairs(localVehicles) do
      if not lv.sent then
        lv.spawnTimer = (lv.spawnTimer or 0) + dt
        if lv.spawnTimer > 0.25 then
          lv.spawnTimer = 0
          lv.tries = (lv.tries or 0) + 1
          local kind = careerMode and careerSyncable(gameId) or nil
          if careerMode and kind == "ai" and not trafficOn() then
            localVehicles[gameId] = nil   -- this server has no AI traffic; the game's own is removed (below)
          elseif careerMode and kind == "ai" then
            -- AI cars (career traffic and parked cars) are shared under their own limit; their ids start with "t"
            local shared = 0
            for _, other in pairs(localVehicles) do if other.sent and other.ai then shared = shared + 1 end end
            local aiVeh = be:getObjectByID(gameId)
            if not (aiVeh and aiVeh:getActive()) then
              lv.tries = 0        -- pooled cars that are switched off are not shared until they are in play
              lv.spawnTimer = -1
            elseif shared >= (server and server.maxTraffic or 0) * 2 then
              lv.tries = 0
              lv.spawnTimer = -2   -- over the limit: look again in a couple of seconds
            else
              lv.ai = true
              lv.vid = "t" .. gameId
              if sendSpawn(gameId) then lv.sent = true end
            end
          elseif careerMode and not kind then
            -- not the player's and not AI: nothing to share
            if lv.tries > 40 then
              local dropped = be:getObjectByID(gameId)
              log("I", logTag, "not sharing vehicle " .. tostring(gameId) .. " (" .. tostring(dropped and dropped:getJBeamFilename()) .. "): not part of the career inventory or traffic")
              localVehicles[gameId] = nil
            end
          elseif sendSpawn(gameId) then
            lv.sent = true
          elseif lv.tries > 20 then
            localVehicles[gameId] = nil
          end
        end
      end
    end

    if careerMode and not trafficOn() and clock >= trafficCheckAt then
      -- the server has no AI traffic, so remove what the career spawned
      trafficCheckAt = clock + 3
      pcall(function()
        if gameplay_traffic then gameplay_traffic.setActiveAmount(0); gameplay_traffic.deleteVehicles() end
        if gameplay_parking then gameplay_parking.setActiveAmount(0); gameplay_parking.deleteVehicles() end
      end)
    end

    if careerMode and trafficOn() and clock >= hostCheckAt then
      -- Every game simulates the AI cars around its own player (so taxis, police and the rest work here as in
      -- single player) and the others show copies. The server sets how much traffic the world has; this game runs
      -- its share of it. Every other player's car is also registered with the traffic system as a real vehicle
      -- (the copies are physical objects here already; this makes police, traffic rules and the rest of the AI
      -- count them too).
      hostCheckAt = clock + 2
      pcall(function()
        local n = math.max(1, trafficPlayers)
        local moving = math.max(1, math.ceil((server.trafficAmount or 6) / n))
        local parked = math.max(1, math.ceil((server.parkedAmount or 4) / n))
        -- (setting these makes the traffic system re-plan its vehicles, so only when the numbers changed)
        if moving ~= appliedTraffic or parked ~= appliedParked then
          appliedTraffic, appliedParked = moving, parked
          gameplay_traffic.setActiveAmount(moving)
          gameplay_parking.setActiveAmount(parked)
        end
        local data = gameplay_traffic.getTrafficData()
        for _, rv in pairs(remoteVehicles) do
          if rv.gameId and tostring(rv.vid):sub(1, 1) ~= "t" and clock - (rv.spawnedAt or 0) > 2 and not data[rv.gameId] then
            gameplay_traffic.insertTraffic(rv.gameId, true)
          end
        end
      end)
    end

    tickOwnVehicles(dt)
    processSpawnQueue()
    pcall(drawBigMapDots)

    local drew, err = pcall(drawNameTags)
    if not drew and not tagErrorLogged then
      tagErrorLogged = true
      billboardsFailed = true   -- (no fallback: a label with a line is what was asked to go away)
      pcall(destroyTags)
      log("E", logTag, "could not draw name tags: " .. tostring(err))
    end

    for key, rv in pairs(remoteVehicles) do
      if rv.gameId and rv.rebuildPending then
        performRebuild(rv)
      elseif rv.gameId then
        local ok, err = pcall(watchRemote, rv, dt)
        if not ok and not rv.watchErrored then
          rv.watchErrored = true
          log("E", logTag, "resync check failed for " .. key .. ": " .. tostring(err))
        end
      elseif rv.respawnAt and clock >= rv.respawnAt then
        -- the game removed this car (or it never spawned): rebuild it where it was last seen
        rv.respawnAt = nil
        rv.respawns = (rv.respawns or 0) + 1
        if rv.payload and rv.respawns <= 5 then
          local keep = { respawns = rv.respawns, safeMode = rv.safeMode, instRebuilds = rv.instRebuilds, lastInstRebuild = rv.lastInstRebuild }
          spawnRemote(rv.pid, rv.vid, rv.payload)
          if remoteVehicles[key] then for k, val in pairs(keep) do remoteVehicles[key][k] = val end end
        end
      end
    end
  end

  pingTimer = pingTimer + dt
  if pingTimer >= PING_INTERVAL then
    pingTimer = 0
    sendLine("K|" .. tostring(math.floor(clock * 1000)))
  end
  flushSend()
end

function M.onVehicleSpawned(gameId)
  -- every car in a session (ours and remote) gets the sync modules, like BeamMP does
  if status == "loading" or status == "handshake" or status == "connected" then
    loadVehicleModules(be:getObjectByID(gameId))
  end
  if spawningRemote or remoteByGameId[gameId] then return end
  -- when not connected yet, still remember it so it is announced if we join later
  localVehicleAdded(gameId)
end

-- One of OUR cars was reset or repaired (R, recover, repair...): send where it is now so everyone else's
-- copy is reset/repaired too. Resets of remote copies (which we cause ourselves) are not in localVehicles.
function M.onVehicleResetted(gameId)
  local lv = localVehicles[gameId]
  if not lv or not lv.sent or status ~= "connected" then return end
  if clock - (lv.lastReset or -1) <= 0.2 then return end   -- one reset can fire more than once
  lv.lastReset = clock
  local veh = be:getObjectByID(gameId)
  if not veh then return end
  local pos = veh:getPosition()
  local rot = quatFromDir(-vec3(veh:getDirectionVector()), vec3(veh:getDirectionVectorUp()))
  sendSync("r", jsonEncode({
    pos = { x = pos.x, y = pos.y, z = pos.z },
    rot = { x = rot.x, y = rot.y, z = rot.z, w = rot.w },
  }), gameId)
end

-- The game moves the player's control onto cars in some situations (a car spawns while you have none, your car
-- is removed...). That must never land on another player's car, or you would be driving a copy of it, so put
-- control back on one of ours (BeamMP's onVehicleSwitched does the same).
function M.onVehicleSwitched(oldId, newId)
  if ridingId and newId ~= ridingId then ridingId = nil end
  if status ~= "connected" and status ~= "loading" then return end
  if not newId or newId < 0 or not remoteByGameId[newId] then return end

  -- Walking up to another player's car and getting in makes you a passenger (BeamMP does the same): you keep
  -- control of that car's object, but its inputs are the owner's alone (see mbInputsVE), and the camera moves to
  -- the passenger seat. Switches that are not that, like the game moving you onto a car that just spawned, are
  -- still refused below.
  local rv = remoteVehicles[remoteByGameId[newId]]
  local carVeh = be:getObjectByID(newId)
  local aiCopy = isAiCopy(rv)   -- AI cars cannot be entered: no passenger seat, and control goes back
  local previous = oldId and oldId >= 0 and not remoteByGameId[oldId] and be:getObjectByID(oldId) or nil
  if rv and carVeh and previous and not aiCopy and previous:getJBeamFilename() == "unicycle"
      and clock - (rv.spawnedAt or 0) > 3
      and (vec3(previous:getPosition()) - vec3(carVeh:getPosition())):length() < 12 then
    ridingId = newId
    core_camera.setByName(0, "mbPassenger")
    notify("You are riding with " .. tostring(players[rv.pid] or "another player") .. ".")
    log("I", logTag, "entered remote vehicle " .. tostring(remoteByGameId[newId]) .. " as a passenger")
    return
  end

  local target = nil
  if previous then
    target = previous
  else
    for gameId in pairs(localVehicles) do
      local veh = be:getObjectByID(gameId)
      if veh and veh:getActive() then target = veh break end
    end
  end

  if not target then
    -- any car or avatar of ours, even a switched-off one (an inactive on-foot avatar is the usual case)
    for i = 0, be:getObjectCount() - 1 do
      local veh = be:getObject(i)
      if veh and not remoteByGameId[veh:getID()] then
        if veh:getJBeamFilename() == "unicycle" or not target then target = veh end
      end
    end
    if target then target:setActive(1) end
  end

  if target then
    be:enterVehicle(0, target)
    -- the walking code switches the avatar off right after getting into the car we just refused, so switch it back on
    reactivate = { id = target:getID(), at = clock + 0.2 }
  else
    -- Nothing of ours to go back to. Leaving the player without a vehicle makes the game's walking code fail (it
    -- needs a vehicle to step out of), so only do it when there really is nothing.
    be:exitVehicle(0)
  end
end

-- Cycling the camera and coming back lands on the normal driver view, which sits in the driver's seat. While we
-- are riding in someone else's car that view is always swapped for the passenger one.
function M.onCameraModeChanged(camName)
  if ridingId and camName == "driver" and be:getPlayerVehicleID(0) == ridingId then
    core_camera.setByName(0, "mbPassenger")
  end
end

function M.onVehicleDestroyed(gameId)
  if ridingId == gameId then ridingId = nil end
  if remoteByGameId[gameId] then
    -- the game or the user removed a remote car (removeRemote clears the mapping first, so this is not us).
    -- Keep the record and rebuild the car shortly; it is only really gone when its owner deletes it.
    local key = remoteByGameId[gameId]
    remoteByGameId[gameId] = nil
    local rv = remoteVehicles[key]
    if rv then
      rv.gameId = nil
      rv.respawnAt = clock + 1.0
      log("W", logTag, "remote vehicle " .. key .. " was removed, rebuilding it")
    end
    return
  end
  local lv = localVehicles[gameId]
  if lv then
    if lv.sent and status == "connected" then sendLine("D|" .. lv.vid) end
    localVehicles[gameId] = nil
  end
end

-- The game calls this when a car goes unstable. By default it ghosts and teleports the car and DELETES it on
-- the second instability. Remote cars are ours to manage: report it handled and stop the car.
function M.onInstabilityDetected(gameId, result)
  local key = remoteByGameId[gameId]
  if not key then return end
  result.instabilityHandled = true
  local rv = remoteVehicles[key]
  if not rv or rv.rebuildPending then return end
  -- An unstable car raises this again every physics step (the game logs three lines and shows a message each time),
  -- which is what makes the game stutter. So the first report switches the copy off, ending the storm at once,
  -- and it is replaced by a fresh one. If that keeps happening the copy is left out for a minute, then tried again.
  -- From the second time on the new copy is built in safe mode (no unbreakable beams, no damage sync).
  local veh = be:getObjectByID(gameId)
  if veh then veh:setActive(0) end
  if rv.lastInstRebuild and clock - rv.lastInstRebuild > 60 then rv.instRebuilds = 0 end
  rv.instRebuilds = (rv.instRebuilds or 0) + 1
  rv.lastInstRebuild = clock
  if rv.instRebuilds >= 2 then rv.safeMode = true; if rv.model then safeModels[rv.model] = true end end
  if rv.instRebuilds > 4 then
    log("W", logTag, "remote vehicle " .. key .. " (" .. tostring(rv.model) .. ") keeps going unstable; leaving it out for a minute")
    rv.instRebuilds = 0
    rebuildRemote(rv, 60)
  else
    log("W", logTag, "remote vehicle " .. key .. " (" .. tostring(rv.model) .. ") went unstable, rebuilding it" .. (rv.safeMode and " in safe mode" or ""))
    rebuildRemote(rv)
  end
end

-- level finished loading: if we came here because of a server, enter it
function M.onClientPostStartMission()
  if status == "loading" and server and not careerMode then
    enterWorld()
  end
end

-- a career save just finished writing: it goes to the server
function M.onSaveFinished()
  if not careerMode or status ~= "connected" then return end
  uploadAt = nil
  if uploadCareer() and leaving then
    leaving.sent = true
    careerUploaded = true
    leaving.deadline = clock + 10   -- the upload is a few hundred KB; give it time to drain before closing
  end
end

-- the career finished setting itself up (level loaded, modules running, player and cars placed)
function M.onCareerActive(active)
  if active and careerMode and status == "loading" and server then
    careerEnterAt = clock + 2
  end
end

function M.onClientEndMission()
  destroyTags()   -- the level, and the tag renderer with it, is going away
  -- level unloaded (main menu / another level): drop remote cars, keep the connection only while loading
  if status == "connected" then
    disconnect("Left the level", true)   -- the level is already being unloaded
  elseif status ~= "loading" then
    localVehicles = {}
  end
end

function M.onExit()
  closeSocket()
end

function M.onExtensionLoaded()
  setExtensionUnloadMode(M, "manual")
  mods.init({
    send = sendLine,
    progress = function(text) statusText = text; pushUI() end,
    prompt = function(p) modPrompt = p; pushUI() end,
    fail = function(reason) toast("error", "MultiBeam", reason); disconnect(reason) end,
    done = function() setStatus("modsync", "Mods match the server. Joining...") end,
    now = function() return clock end,
    target = function() return target and target.host or "", target and target.port or 0 end,
    serverKey = function() return target and (target.host .. ":" .. tostring(target.port)) or "" end,
  })
  -- After a restart that was needed for a server's mods, join that server again (once, when the game is ready).
  -- Otherwise the last session ended without putting the mods back: do that now.
  resumeJoin = mods.takeResume()
  modsRestorePending = not resumeJoin and mods.pendingRestore()   -- (a restore that was interrupted)
  loadData()
  log("I", logTag, "MultiBeam client loaded")
end

-- Entry point for the Vue UI. Arguments are hex-encoded JSON to avoid any quoting problems.
local function unhex(s)
  return (s:gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end))
end

function M.ui(cmd, hexArgs)
  local args = hexArgs and hexArgs ~= "" and jsonDecode(unhex(hexArgs)) or {}
  args = type(args) == "table" and args or {}
  if cmd == "state" then
    return uiState()
  elseif cmd == "join" then
    return M.join(args.host, args.port, args.password)
  elseif cmd == "leave" then
    return M.leave()
  elseif cmd == "modsAccept" then
    return mods.accept()
  elseif cmd == "modsDecline" then
    return mods.decline()
  elseif cmd == "modsRestore" then
    if status == "idle" then
      modsRestorePending = mods.markPendingRestore()
      pushUI()
    end
    return true
  elseif cmd == "closeGame" then
    return mods.closeGame()
  elseif cmd == "add" then
    return M.addServer(args.name, args.host, args.port)
  elseif cmd == "remove" then
    return M.removeServer(args.host, args.port)
  elseif cmd == "query" then
    return M.query(args.host, args.port)
  end
end

return M
