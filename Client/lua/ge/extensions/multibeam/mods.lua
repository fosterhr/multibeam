-- MultiBeam mod management (client side).
--
-- A server with mod checking on sends the list of its mods (name, size, SHA-1) before the player joins. This makes
-- the player's mods match it exactly:
--   * server mods the player already has (same name, size and SHA-1) are kept, and switched on if they were off
--   * server mods the player lacks are downloaded from the server, after the player agrees
--   * every other mod the player has enabled is switched off
-- Then the client reports which mods are enabled and the server refuses anything but an exact match.
--
-- Mods that contain code or interface files (lua/, scripts/, ui/ folders: total conversions such as career overhauls)
-- cannot be switched on or off in a running game: the game has already loaded its own versions of those files. When
-- one of those is involved the game has to be restarted; after the restart the client joins the server again by
-- itself, with the mods already in place.
--
-- Nothing is permanent. What was changed is written to settings/multibeam_mods.json first, and when the player
-- leaves (or the game starts again after a crash) the downloaded mods are deleted and the mods that were switched
-- off are switched on again. Downloaded mods are stored as mods/mbdl_<name>.zip, so they can never overwrite a mod
-- the player has under the same name.

local mime = require("mime")

local M = {}
local logTag = "multibeam.mods"

local STATE_FILE = "/settings/multibeam_mods.json"
local PREFIX = "mbdl_"
local OWN = "multibeam.zip"     -- this mod is never switched off and never counted
local CHUNK = 48 * 1024         -- as sent by the server
local WINDOW = 8                -- chunks requested ahead

local host = {}                 -- callbacks from client.lua: send(line), progress(text), prompt(table|nil), fail(reason), done(), now()
local manifest = {}
local plan = nil
local phase = "idle"           -- idle | manifest | prompt | working | verifying | reported
local state = nil               -- what has been changed, mirrored in STATE_FILE
local dlQueue, dl = {}, nil
local lastProgress = 0
local verifyStart, lastKick = 0, 0
local serverKeyNow = ""
local changedCode = false      -- this join changed a mod that has code in it (needs a restart)

function M.init(callbacks) host = callbacks end

local function log_(level, msg) log(level, logTag, msg) end

local function fileNameOf(path)
  return (tostring(path):match("([^/\\]+)$") or ""):lower()
end

-- the mods the game knows that can be switched on and off (not unpacked folders, not MultiBeam itself)
local function listLocal()
  local out = {}
  local ok, mods = pcall(function() return core_modmanager.getMods() end)
  if not ok or type(mods) ~= "table" then return out end
  for modname, m in pairs(mods) do
    if type(m) == "table" and m.fullpath and not m.unpackedPath then
      local file = fileNameOf(m.fullpath)
      if file ~= OWN and file:sub(-4) == ".zip" then
        local size = FS:fileSize(m.fullpath)
        out[#out + 1] = { modname = modname, file = file, path = m.fullpath, active = m.active ~= false, size = tonumber(size) or 0 }
      end
    end
  end
  table.sort(out, function(a, b) return a.file < b.file end)
  return out
end

local function baseName(file)
  return (file:gsub("^" .. PREFIX, ""))
end

local function modNameOfFile(file)
  return (file:gsub("%.zip$", ""):lower())
end

-- does this zip contain code or interface files (which the game only picks up when it starts)?
local function hasCode(path)
  local ok, found = pcall(function()
    local z = ZipArchive()
    if not z:openArchiveName(path, "R") then return false end
    for _, f in ipairs(z:getFileList()) do
      local n = tostring(f):lower()
      if n:find("^/?lua/") or n:find("^/?scripts/") or n:find("^/?ui/") then return true end
    end
    return false
  end)
  return ok and found
end

local function sameHash(path, wanted)
  local ok, h = pcall(function() return FS:hashFileSHA1(path) end)
  return ok and type(h) == "string" and h:lower() == wanted
end

-- ---- what was changed ------------------------------------------------------------------------------

local function loadState()
  local s = jsonReadFile(STATE_FILE)
  if type(s) == "table" and (s.downloaded or s.disabled or s.enabled) then return s end
  return nil
end

local function saveState()
  jsonWriteFile(STATE_FILE, state or {}, true)
end

function M.hasState() return loadState() ~= nil end

-- The mods are only put back when the player leaves on purpose (or asks for it), not when the connection drops or
-- the server restarts: rejoining then finds everything in place, with no new download.
function M.markPendingRestore()
  local s = loadState()
  if not s then return false end
  s.pendingRestore = true
  state = s
  saveState()
  return true
end

function M.pendingRestore()
  local s = loadState()
  return s ~= nil and s.pendingRestore == true
end

-- for the menu: are a server's mods still installed?
function M.installed()
  local s = loadState()
  if not s then return nil end
  return { downloaded = #(s.downloaded or {}), disabled = #(s.disabled or {}), code = s.code == true, server = s.server }
end

-- Undo everything: delete the downloaded mods, switch back on what was switched off, switch off what was
-- switched on only for the server.
function M.restore()
  local s = loadState()
  if not s then return false end
  log_("I", "restoring mods after a server session")
  for _, file in ipairs(s.downloaded or {}) do
    local modname = modNameOfFile(file)
    pcall(function()
      if core_modmanager.getModDB(modname) then core_modmanager.deleteMod(modname) end
    end)
    pcall(function() if FS:fileExists("/mods/" .. file) then FS:remove("/mods/" .. file) end end)
    pcall(function() if FS:fileExists("/mods/" .. file .. ".part") then FS:remove("/mods/" .. file .. ".part") end end)
  end
  for _, name in ipairs(s.disabled or {}) do
    pcall(function() core_modmanager.activateMod(name) end)
  end
  for _, name in ipairs(s.enabled or {}) do
    pcall(function() core_modmanager.deactivateMod(name) end)
  end
  state = nil
  jsonWriteFile(STATE_FILE, {}, true)
  return true
end

-- ---- planning ----------------------------------------------------------------------------------------

local function computePlan()
  local locals = listLocal()
  local keep = {}
  plan = { download = {}, disable = {}, enable = {}, pathOf = {} }
  for _, lm in ipairs(locals) do plan.pathOf[lm.modname] = lm.path end
  for _, sm in ipairs(manifest) do
    local wanted = sm.name:lower()
    local match
    for _, lm in ipairs(locals) do
      if baseName(lm.file) == wanted and lm.size == sm.size and sameHash(lm.path, sm.sha1) then match = lm break end
    end
    if match then
      keep[match.modname] = true
      if not match.active then plan.enable[#plan.enable + 1] = match.modname end
    else
      plan.download[#plan.download + 1] = sm
    end
  end
  for _, lm in ipairs(locals) do
    if lm.active and not keep[lm.modname] then plan.disable[#plan.disable + 1] = lm.modname end
  end
end

-- ---- downloading -------------------------------------------------------------------------------------

local function partPath(name) return "mods/" .. PREFIX .. name .. ".part" end
local function finalPath(name) return "mods/" .. PREFIX .. name end

local function fail(reason)
  log_("E", reason)
  M.abort()
  host.fail(reason)
end

local function requestMore()
  while dl and dl.outstanding < WINDOW and dl.nextReq < dl.e.size do
    host.send("Q|G|" .. dl.e.name .. "|" .. dl.nextReq)
    dl.nextReq = dl.nextReq + CHUNK
    dl.outstanding = dl.outstanding + 1
  end
end

local function report()
  local parts = {}
  for _, lm in ipairs(listLocal()) do
    if lm.active then parts[#parts + 1] = baseName(lm.file) .. ":" .. lm.size end
  end
  phase = "reported"
  host.progress("Checking mods with the server...")
  host.send("Q|R|" .. table.concat(parts, ","))
end

local function startNext()
  dl = nil
  local e = table.remove(dlQueue, 1)
  if not e then
    -- everything is downloaded: wait for the game to load the new mods, then report
    phase = "verifying"
    verifyStart, lastKick = host.now(), host.now()
    return
  end
  dl = { e = e, written = 0, nextReq = 0, outstanding = 0, total = #plan.download, index = #plan.download - #dlQueue }
  pcall(function() if FS:fileExists(partPath(e.name)) then FS:remove(partPath(e.name)) end end)
  local f = io.open(partPath(e.name), "wb")
  if not f then fail("Could not write " .. e.name .. " into the mods folder.") return end
  f:close()
  state.downloaded[#state.downloaded + 1] = PREFIX .. e.name
  saveState()
  if e.size == 0 then fail("The server's mod " .. e.name .. " is empty.") return end
  requestMore()
end

local function finishDownload()
  local e = dl.e
  local part, final = partPath(e.name), finalPath(e.name)
  local size = tonumber(FS:fileSize(part)) or -1
  if size ~= e.size or not sameHash(part, e.sha1) then
    fail("The download of " .. e.name .. " is damaged. Try again.")
    return
  end
  if hasCode(part) then changedCode = true; state.code = true; saveState() end
  -- (an older copy of this mod under the same name would be in the way)
  pcall(function()
    local modname = modNameOfFile(PREFIX .. e.name)
    if core_modmanager.getModDB(modname) then core_modmanager.deleteMod(modname) end
  end)
  pcall(function() if FS:fileExists(final) then FS:remove(final) end end)
  local ok = FS:renameFile(part, final)
  if ok ~= 0 and ok ~= true then fail("Could not finish " .. e.name .. ".") return end
  startNext()
end

function M.chunk(name, offset, b64)
  if phase ~= "working" or not dl or dl.e.name ~= name then return end
  offset = tonumber(offset)
  if offset ~= dl.written then fail("The download of " .. name .. " arrived out of order.") return end
  local raw = mime.unb64(b64 or "")
  if not raw then fail("The download of " .. name .. " is damaged.") return end
  local f = io.open(partPath(name), "ab")
  if not f then fail("Could not write " .. name .. " into the mods folder.") return end
  f:write(raw)
  f:close()
  dl.written = dl.written + #raw
  dl.outstanding = dl.outstanding - 1
  if dl.written >= dl.e.size then
    finishDownload()
  else
    requestMore()
  end
end

-- ---- driving it ----------------------------------------------------------------------------------------

-- serverKey = "host:port". Mods changed for this same server (before a restart) stay; anything else left over
-- from an earlier session is undone first.
function M.begin(serverKey)
  local s = loadState()
  if s and s.server ~= serverKey then
    M.restore()
    s = nil
  end
  manifest, plan, dlQueue, dl, state = {}, nil, {}, nil, s
  changedCode = false
  serverKeyNow = serverKey
  if state and state.pendingRestore then state.pendingRestore = nil; saveState() end   -- joining again: the mods are wanted
  phase = "manifest"
end

function M.line(kind, a, b, c, d)
  if kind == "B" then
    M.begin(host.serverKey and host.serverKey() or "")
  elseif kind == "M" then
    if phase == "manifest" then
      manifest[#manifest + 1] = { name = a, size = tonumber(b) or 0, sha1 = tostring(c or ""):lower() }
    end
  elseif kind == "E" then
    if phase ~= "manifest" then return end
    computePlan()
    if #plan.download == 0 and #plan.disable == 0 and #plan.enable == 0 then
      report()   -- already matching
      return
    end
    phase = "prompt"
    local downloads, total = {}, 0
    for _, e in ipairs(plan.download) do
      downloads[#downloads + 1] = { name = e.name, size = e.size }
      total = total + e.size
    end
    host.prompt({ download = downloads, disable = plan.disable, enable = plan.enable, totalBytes = total })
  elseif kind == "D" then
    M.chunk(a, b, c)
  elseif kind == "O" then
    phase = "idle"
    host.done()
  end
end

function M.accept()
  if phase ~= "prompt" or not plan then return end
  host.prompt(nil)
  phase = "working"
  state = state or { downloaded = {}, disabled = {}, enabled = {} }
  state.server = serverKeyNow
  state.disabled, state.enabled, state.downloaded = state.disabled or {}, state.enabled or {}, state.downloaded or {}
  for _, name in ipairs(plan.disable) do
    state.disabled[#state.disabled + 1] = name
    if hasCode(plan.pathOf[name] or "") then changedCode = true; state.code = true end
  end
  for _, name in ipairs(plan.enable) do
    state.enabled[#state.enabled + 1] = name
    if hasCode(plan.pathOf[name] or "") then changedCode = true; state.code = true end
  end
  saveState()   -- written before anything is changed, so a crash can always be undone
  for _, name in ipairs(plan.disable) do
    pcall(function() core_modmanager.deactivateMod(name) end)
  end
  for _, name in ipairs(plan.enable) do
    pcall(function() core_modmanager.activateMod(name) end)
  end
  dlQueue = {}
  for _, e in ipairs(plan.download) do dlQueue[#dlQueue + 1] = e end
  startNext()
end

function M.decline()
  if phase ~= "prompt" then return end
  host.prompt(nil)
  host.send("Q|X")
  phase = "idle"
  host.fail("You need the server's mods to play here.")
end

-- stop an unfinished download (the mods already changed stay recorded and are undone by restore)
function M.abort()
  if dl then
    pcall(function() if FS:fileExists(partPath(dl.e.name)) then FS:remove(partPath(dl.e.name)) end end)
  end
  dl, dlQueue, plan, phase = nil, {}, nil, "idle"
  host.prompt(nil)
end

function M.busy() return phase ~= "idle" end

-- after a restart: the server to join again (once), if the restart was for a server's mods
function M.takeResume()
  local s = loadState()
  if not s or not s.resume then return nil end
  local r = s.resume
  s.resume = nil
  state = s
  saveState()
  return r
end

function M.closeGame()
  pcall(function() Engine.requestShutdown() end)
end

-- called every frame while a session is being set up
function M.tick()
  local now = host.now()
  if phase == "working" and dl then
    if now - lastProgress > 0.3 then
      lastProgress = now
      local pct = dl.e.size > 0 and math.floor(dl.written * 100 / dl.e.size) or 0
      host.progress(string.format("Downloading mods: %s (%d of %d), %d%%", dl.e.name, dl.index, dl.total, pct))
    end
    if dl.outstanding == 0 and dl.written < dl.e.size then requestMore() end
  elseif phase == "verifying" then
    -- the game mounts a new zip by itself once it is in the mods folder; help it if it has not
    local pending = 0
    for _, file in ipairs(state and state.downloaded or {}) do
      local modname = modNameOfFile(file)
      local m = core_modmanager.getModDB(modname)
      if not m then
        pending = pending + 1
        if now - lastKick > 2 then
          pcall(function() core_modmanager.workOffChangedMod("/mods/" .. file, "added") end)
        end
      elseif m.active == false then
        pending = pending + 1
        pcall(function() core_modmanager.activateMod(modname) end)
      end
    end
    if now - lastKick > 2 then lastKick = now end
    if pending == 0 then
      if changedCode then
        -- a mod with code in it was switched or downloaded: the game must be restarted to load it properly
        phase = "restart"
        local h, port = host.target()
        state.resume = { host = h, port = port }
        saveState()
        host.prompt({ restart = true })
        return
      end
      report()
    elseif now - verifyStart > 30 then
      fail("The game could not load the downloaded mods.")
    end
  end
end

return M
