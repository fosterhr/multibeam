-- MultiBeam passenger camera.
--
-- The driver camera of the game, moved to the seat on the other side of the car: it wraps core/cameraModes/driver
-- (so head look, zoom and physics behave exactly like the driver view and follow whatever this game version does)
-- and mirrors the resulting camera position across the vehicle's centre line. That puts the view in the passenger
-- seat of left- and right-hand-drive cars alike. BeamMP has a passenger camera too (a hand-modified copy of an
-- older driver.lua); this one is derived from the installed game's own driver camera instead.

local driverConstructor = require('core/cameraModes/driver')

return function(...)
  local inner = driverConstructor(...)

  -- `proxy` behaves as the driver camera object (all reads and writes go to it), except that update() is ours
  local proxy = setmetatable({}, { __index = inner, __newindex = inner })
  local driverUpdate = inner.update

  -- never offer this in the normal camera cycle; it is only selected when riding in someone else's car
  proxy.disabledByDefault = true

  proxy.update = function(self, data)
    driverUpdate(self, data)

    local veh = data.veh
    local res = data.res
    if not veh or not res or not res.pos then return end

    local center = veh:getSpawnWorldOOBB():getCenter()
    local forward = vec3(veh:getDirectionVector())
    local up = vec3(veh:getDirectionVectorUp())
    local lateral = forward:cross(up):normalized()   -- across the car; which way is "left" doesn't matter for a mirror

    local pos = res.pos
    local offset = (vec3(pos) - center):dot(lateral)
    local mirrored = vec3(pos) - lateral * (2 * offset)
    pos:set(mirrored.x, mirrored.y, mirrored.z)
  end

  return proxy
end
