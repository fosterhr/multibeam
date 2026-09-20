-- Starting mode used by MultiBeam servers that run in career mode: the "Open World" start (money, no tutorial),
-- but it works on any map. It only moves the player to the dealership area on west_coast_usa; everywhere else the
-- player starts where the level puts them.
return {
  id = "multibeam",
  order = 900,
  tier = "minor",
  title = "MultiBeam",
  description = "Start used for MultiBeam servers running career mode. Works on any map.",
  initPlayerAttributes = function(playerAttributes)
    playerAttributes.setAttributes({money = 10000}, {label = "Starting Capital"})
  end,
  setupInventory = function()
    if getCurrentLevelIdentifier() == "west_coast_usa" then
      spawn.safeTeleport(getPlayerVehicle(0), vec3(905.54, -542.39, 164.31))
      gameplay_walk.setRot(vec3(-1, 1.5, 0.75), vec3(0, 0, 1))
    end
  end,
}
