-- Adapted for MultiBeam from BeamMP (https://github.com/BeamMP/BeamMP), MPVehicleVE.lua.
-- BeamMP is licensed AGPL-3.0-or-later; this file stays under that license.
-- Copyright (C) 2024 BeamMP Ltd., BeamMP team and contributors.

-- Per-vehicle state shared by the other mb*VE modules: is this car ours ("L") or someone else's ("R")?
local M = {}

v.mpVehicleType = "L" -- we assume vehicles are local (they're set to remote once position data from the server arrives)

-- safe: this copy is shown without the unbreakable beams (used for a copy whose physics kept going unstable)
local function setVehicleType(x, safe)
  v.mpVehicleType = x
  v.mpSafeRemote = safe and true or nil
  if x == 'R' and mbDamageVE and not safe then
    mbDamageVE.makeRemote() -- remote copies show the owner's damage instead of making their own
  end
end

local function updateGFX(dtReal)
  if v.mpVehicleType == 'R' and hydros.enableFFB then -- disable ffb if it got enabled by a reset
    -- trigger a check that will set FFBID to -1
    hydros.enableFFB = false
    hydros.onFFBConfigChanged()
  end
end

local function onExtensionLoaded()
  obj:queueGameEngineLua("multibeam_client.onVehicleReady("..obj:getID()..")")
end

M.updateGFX = updateGFX
M.onExtensionLoaded = onExtensionLoaded
M.setVehicleType = setVehicleType

return M
