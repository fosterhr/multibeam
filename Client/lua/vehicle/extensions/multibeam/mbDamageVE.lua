-- MultiBeam damage sync (vehicle side).
--
-- The owner's copy of a car is the authority for its damage. Every simulated copy would otherwise crash on its
-- own and end up with different (usually more) damage, so:
--   * the owner reports the beams whose state changed (rest length, broken, deformation), plus the full set of
--     damaged beams now and then so that players who join later catch up (this is what beamstate.save/load
--     record, and what BeamMP's nodesVE.getNodes/applyNodes did before BeamMP switched full sync off);
--   * a remote copy has its beams made effectively unbreakable and non-deforming, so it can never damage itself,
--     and only ever shows the damage the owner sent, applied with the same beam calls beamstate.load uses.
-- Break groups (parts flying off) are synced separately by mbNodesVE, adapted from BeamMP.

local M = {}

local UNBREAKABLE = 1e20        -- stands in for "FLT_MAX" strength / deform limits
local CHECK_EVERY_FULL = 20     -- seconds between full damage sets (for late joiners)
local EPS_LEN = 0.0005
local EPS_DEF = 0.001

local orig = {}         -- cid -> rest length when the car was loaded (undamaged)
local last = {}         -- cid -> {r = rest, b = broken, d = deformation} as of the last delta
local lastDamage = -1
local lastFull = 0
local applied = {}      -- cid -> deformation ratio already applied from the owner (remote copies)

local function round(x, places)
  local m = 10 ^ places
  return math.floor(x * m + 0.5) / m
end

local function beamState(cid)
  return obj:getBeamRestLength(cid), obj:beamIsBroken(cid) and true or false, obj:getBeamDeformation(cid) or 0
end

local function baseline()
  orig, last, applied = {}, {}, {}
  for _, beam in pairs(v.data.beams) do
    local rest, broken, def = beamState(beam.cid)
    orig[beam.cid] = rest
    last[beam.cid] = { r = rest, b = broken, d = def }
  end
  lastDamage = -1
  lastFull = os.clock()
end

-- beams that differ from what we last reported (updates `last`), or every damaged beam when `full`
local function collect(full)
  local list = {}
  for _, beam in pairs(v.data.beams) do
    local cid = beam.cid
    local rest, broken, def = beamState(cid)
    local l = last[cid]
    if full then
      local base = orig[cid]
      if broken or def > EPS_DEF or (base and math.abs(rest - base) > EPS_LEN) then
        list[#list + 1] = { cid, round(rest, 4), broken and 1 or 0, round(def, 3) }
      end
    elseif l and (l.b ~= broken or math.abs(l.r - rest) > EPS_LEN or math.abs(l.d - def) > EPS_DEF) then
      list[#list + 1] = { cid, round(rest, 4), broken and 1 or 0, round(def, 3) }
    end
    if not full then
      if l then l.r, l.b, l.d = rest, broken, def else last[cid] = { r = rest, b = broken, d = def } end
    end
  end
  return list
end

-- called by the game side on a timer, for cars we own
local function check()
  if v.mpVehicleType ~= 'L' then return end
  local damage = beamstate.damage
  local now = os.clock()
  local dueFull = (now - lastFull) >= CHECK_EVERY_FULL
  if damage == lastDamage and not dueFull then return end
  lastDamage = damage

  local delta = collect(false)
  if #delta > 0 then
    obj:queueGameEngineLua("multibeam_client.sendDamage('" .. jsonEncode({ b = delta }) .. "', " .. obj:getID() .. ")")
  end
  if dueFull then
    lastFull = now
    local all = collect(true)
    if #all > 0 then
      obj:queueGameEngineLua("multibeam_client.sendDamageFull('" .. jsonEncode({ b = all }) .. "', " .. obj:getID() .. ")")
    end
  end
end

-- apply damage received from the owner
local function applyDamage(data)
  local d = jsonDecode(data)
  if type(d) ~= "table" or type(d.b) ~= "table" then return end
  for _, e in ipairs(d.b) do
    local cid, rest, broken, def = e[1], e[2], e[3], e[4] or 0
    if type(cid) == "number" and v.data.beams[cid] then
      if broken == 1 then
        if not obj:beamIsBroken(cid) then
          obj:breakBeam(cid)
          beamstate.beamBroken(cid, 1)   -- the engine doesn't call this for breaks made from Lua (see BeamMP nodesVE)
        end
      else
        obj:setBeamLength(cid, rest)
        -- onBeamDeformed also feeds the damage trackers, so only report a deformation once
        if def > 0 and math.abs((applied[cid] or 0) - def) > EPS_DEF then
          applied[cid] = def
          beamstate.onBeamDeformed(cid, def)
        end
      end
    end
  end
end

-- a remote copy must not be able to break or dent on its own physics
local function makeRemote()
  if v.mpSafeRemote then return end
  for _, beam in pairs(v.data.beams) do
    obj:setBeamStrength(beam.cid, UNBREAKABLE)
    obj:setBeamDeform(beam.cid, UNBREAKABLE)
  end
end

local function onReset()
  -- a reset/repair puts every beam back to its original state (including strengths)
  if v.mpVehicleType == 'R' then
    applied = {}
    makeRemote()
  else
    baseline()
  end
end

local function onExtensionLoaded()
  baseline()
end

M.check = check
M.applyDamage = applyDamage
M.makeRemote = makeRemote
M.onReset = onReset
M.onExtensionLoaded = onExtensionLoaded

return M
