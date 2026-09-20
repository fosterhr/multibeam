// MultiBeam - adds a "MultiBeam" entry to the main menu (under More) that opens the server browser.
import { useBridge } from "@/bridge"
import MultiBeamScreen from "./MultiBeamScreen.vue"

const sourceId = "multibeam.routes"
const routes = [
  {
    path: "/multibeam",
    name: "menu.multibeam",
    component: MultiBeamScreen,
    meta: {
      infoBar: { visible: true, showSysInfo: false },
      uiApps: { shown: false },
      topBar: { visible: true },
      luaRoute: {
        title: "MultiBeam",
        backTarget: "menu",
      },
    },
  },
]

function toLuaRoutes(records) {
  return records.map(record => ({
    name: record.name,
    path: record.path,
    meta: record.meta,
    ...(record.children ? { children: toLuaRoutes(record.children) } : {}),
  }))
}

function addMenuButton(addButton) {
  addButton({
    title: "MultiBeam",
    iconId: "gamepad",
    action: "menu.multibeam",
  })
}

export async function onLoad() {
  const { lua, events } = useBridge()
  window.bngRoutes.add([{ path: sourceId, routes }])
  const result = await lua.extensions.ui_router_routeManager.registerModRoutes(sourceId, toLuaRoutes(routes))
  if (!result?.success) {
    window.bngRoutes.remove([sourceId])
    console.error("MultiBeam: failed to register routes", result?.errors)
    return
  }
  events.on("MainMenuButtons", addMenuButton)
  events.emit("BroadcastMainMenuButtons")
}

export async function onUnload() {
  const { lua, events } = useBridge()
  events.off("MainMenuButtons", addMenuButton)
  window.bngRoutes.remove([sourceId])
  await lua.extensions.ui_router_routeManager.unregisterModRoutes(sourceId, { fallbackRoute: "menu" })
}
