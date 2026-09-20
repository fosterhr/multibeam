<template>
  <div class="mb-root">
    <div class="mb-panel">
      <header class="mb-header">
        <BngButton :accent="ACCENTS.secondary" @click="goBack">Back</BngButton>
        <h1>MultiBeam</h1>
      </header>

      <!-- in a session, or on the way into one -->
      <div v-if="inSession" class="mb-body">
        <section class="mb-box mb-grow">
          <h2>{{ st.server ? st.server.name : "Connecting" }}</h2>
          <p class="mb-dim">{{ st.statusText }}</p>
          <p v-if="st.server" class="mb-dim">
            {{ st.target ? st.target.host + ":" + st.target.port : "" }}, map {{ st.server.map }},
            {{ st.players.length }}/{{ st.server.maxPlayers }} players
          </p>

          <!-- the server has its own mods: the player has to agree before anything on their PC changes -->
          <div v-if="st.modPrompt && st.modPrompt.restart" class="mb-mods">
            <h2>Restart needed</h2>
            <p>The server's mods change how the game itself works, so BeamNG.drive has to be restarted to load them.
              After the restart you join this server again automatically.</p>
            <p class="mb-dim">When you leave the server the mods are put back as they were.</p>
            <div class="mb-row">
              <BngButton :accent="ACCENTS.main" @click="closeGame">Close the game</BngButton>
              <BngButton :accent="ACCENTS.secondary" @click="leave">Cancel</BngButton>
            </div>
          </div>
          <div v-else-if="st.modPrompt" class="mb-mods">
            <h2>This server uses mods</h2>
            <template v-if="st.modPrompt.download && st.modPrompt.download.length">
              <p>To join you need to download ({{ formatSize(st.modPrompt.totalBytes) }}):</p>
              <ul class="mb-modlist">
                <li v-for="m in st.modPrompt.download" :key="m.name">{{ m.name }} <span class="mb-dim">{{ formatSize(m.size) }}</span></li>
              </ul>
            </template>
            <template v-if="st.modPrompt.enable && st.modPrompt.enable.length">
              <p>These mods are installed but switched off. They will be switched on while you play here:</p>
              <ul class="mb-modlist"><li v-for="m in st.modPrompt.enable" :key="m">{{ m }}</li></ul>
            </template>
            <template v-if="st.modPrompt.disable && st.modPrompt.disable.length">
              <p>These mods of yours are not on the server. They will be switched off while you play here:</p>
              <ul class="mb-modlist"><li v-for="m in st.modPrompt.disable" :key="m">{{ m }}</li></ul>
            </template>
            <p class="mb-dim">When you leave the server the downloaded mods are deleted and your own mods are switched back on.</p>
            <div class="mb-row">
              <BngButton :accent="ACCENTS.main" @click="modsAccept">Download and join</BngButton>
              <BngButton :accent="ACCENTS.secondary" @click="modsDecline">Cancel</BngButton>
            </div>
          </div>

          <div class="mb-row mb-end">
            <BngButton :accent="ACCENTS.attention" @click="leave">Disconnect</BngButton>
          </div>
        </section>

        <section class="mb-box mb-side">
          <h2>Players</h2>
          <ul class="mb-players">
            <li v-for="p in st.players" :key="p.id">{{ p.name }}</li>
          </ul>
        </section>
      </div>

      <!-- server list -->
      <div v-else class="mb-body">
        <section class="mb-box mb-grow">
          <div class="mb-row mb-between">
            <h2>Servers</h2>
            <BngButton :accent="ACCENTS.secondary" @click="refresh">Refresh</BngButton>
          </div>

          <p v-if="st.statusText" class="mb-error">{{ st.statusText }}</p>
          <p v-if="!st.servers.length" class="mb-dim">No saved servers.</p>

          <div class="mb-list">
            <div v-for="s in st.servers" :key="s.host + ':' + s.port" class="mb-server">
              <div class="mb-server-main">
                <div class="mb-server-name">{{ infoFor(s)?.name || s.name }}</div>
                <div class="mb-dim">{{ s.host }}:{{ s.port }}</div>
              </div>
              <div class="mb-server-info">
                <span v-if="infoFor(s)?.pending" class="mb-dim">checking</span>
                <span v-else-if="infoFor(s)?.error" class="mb-offline" :title="infoFor(s).error">{{ infoFor(s).error.includes("only allows") ? "needs bridge" : "can't connect" }}</span>
                <span v-else-if="infoFor(s)?.online === false" class="mb-offline">offline</span>
                <span v-else-if="infoFor(s)?.online">
                  {{ infoFor(s).players }}/{{ infoFor(s).maxPlayers }}, {{ infoFor(s).map }}<span v-if="infoFor(s).passworded">, password</span>
                </span>
              </div>
              <BngInput v-if="infoFor(s)?.passworded" v-model="passwords[s.host + ':' + s.port]" type="password" class="mb-pass" placeholder="Password" />
              <BngButton @click="join(s.host, s.port, passwords[s.host + ':' + s.port])">Join</BngButton>
              <BngButton :accent="ACCENTS.secondary" @click="remove(s)">Remove</BngButton>
            </div>
          </div>
        </section>

        <section class="mb-box mb-side">
          <p class="mb-dim">Playing as {{ st.playerName || "your Steam name" }}</p>

          <div v-if="st.modsInstalled" class="mb-mods">
            <h2>Server mods installed</h2>
            <p class="mb-dim">
              {{ st.modsInstalled.downloaded }} downloaded mod(s) are still installed{{ st.modsInstalled.disabled ? ", and " + st.modsInstalled.disabled + " of yours are switched off" : "" }}.
              Joining the same server again reuses them. They are removed when you leave a server, or here.
            </p>
            <BngButton :accent="ACCENTS.secondary" @click="modsRestore">Restore my mods</BngButton>
            <p v-if="st.modsInstalled.code" class="mb-dim">Restart the game afterwards.</p>
          </div>

          <h2>Add server</h2>
          <BngInput v-model="addName" placeholder="Name" />
          <BngInput v-model="addAddress" placeholder="IP:PORT" @enter="addServer" />
          <BngButton @click="addServer">Add</BngButton>

          <h2>Direct connect</h2>
          <BngInput v-model="directAddress" placeholder="IP:PORT" @enter="directJoin" />
          <BngInput v-model="directPassword" type="password" placeholder="Password" @enter="directJoin" />
          <BngButton :accent="ACCENTS.main" @click="directJoin">Connect</BngButton>
        </section>
      </div>
    </div>
  </div>
</template>

<script setup>
import { ref, reactive, computed, onMounted, onBeforeUnmount } from "vue"
import { useBridge } from "@/bridge"
import { BngButton, BngInput, ACCENTS } from "@/common/components/base"

const { api, events, lua } = useBridge()

const st = reactive({
  status: "idle",
  statusText: "",
  connected: false,
  server: null,
  target: null,
  players: [],
  servers: [],
  serverInfo: {},
  playerName: "",
  modPrompt: null,
  modsInstalled: null,
})

const inSession = computed(() => st.status !== "idle")

const addName = ref("")
const addAddress = ref("")
const directAddress = ref("")
const directPassword = ref("")
const passwords = reactive({})

// Arguments travel as hex-encoded JSON so quoting can't break the Lua call.
function toHex(obj) {
  const bytes = new TextEncoder().encode(JSON.stringify(obj || {}))
  let out = ""
  for (const b of bytes) out += b.toString(16).padStart(2, "0")
  return out
}

function call(cmd, args) {
  return new Promise(resolve => {
    api.engineLua(`extensions.multibeam_client.ui("${cmd}", "${toHex(args)}")`, resolve)
  })
}

function applyState(s) {
  if (!s || typeof s !== "object") return
  st.status = s.status || "idle"
  st.statusText = s.statusText || ""
  st.connected = !!s.connected
  st.server = s.server || null
  st.target = s.target || null
  st.players = Array.isArray(s.players) ? s.players : []
  st.servers = Array.isArray(s.servers) ? s.servers : []
  st.serverInfo = s.serverInfo || {}
  st.playerName = s.playerName || ""
  st.modPrompt = s.modPrompt || null
  st.modsInstalled = s.modsInstalled || null
}

function formatSize(bytes) {
  const b = Number(bytes) || 0
  if (b >= 1024 * 1024) return (b / 1024 / 1024).toFixed(1) + " MB"
  return Math.max(1, Math.round(b / 1024)) + " KB"
}

const infoFor = s => st.serverInfo[s.host + ":" + s.port]

function parseAddress(text) {
  const t = (text || "").trim().replace(/^[a-z]+:\/\//i, "")
  if (!t) return null
  const m = t.match(/^(.+?)(?::(\d{1,5}))?$/)
  if (!m) return null
  return { host: m[1], port: m[2] ? parseInt(m[2], 10) : 30814 }
}

const goBack = () => lua.extensions.ui_router.back()
const refresh = () => call("query", {})
const join = (host, port, password) => call("join", { host, port, password: password || "" })
const leave = () => call("leave")
const modsAccept = () => call("modsAccept")
const modsDecline = () => call("modsDecline")
const closeGame = () => call("closeGame")
const modsRestore = () => call("modsRestore")
const remove = s => call("remove", { host: s.host, port: s.port })

function addServer() {
  const a = parseAddress(addAddress.value)
  if (!a) return
  call("add", { name: addName.value, host: a.host, port: a.port }).then(() => {
    addName.value = ""
    addAddress.value = ""
    call("query", { host: a.host, port: a.port })
  })
}

function directJoin() {
  const a = parseAddress(directAddress.value)
  if (!a) return
  join(a.host, a.port, directPassword.value)
}

const onState = s => applyState(s)
let timer = null

onMounted(async () => {
  events.on("MultiBeamState", onState)
  applyState(await call("state"))
  refresh()
  timer = setInterval(() => { if (st.status === "idle") refresh() }, 15000)
})

onBeforeUnmount(() => {
  events.off("MultiBeamState", onState)
  if (timer) clearInterval(timer)
})
</script>

<style lang="scss" scoped>
.mb-root {
  position: absolute;
  inset: 0;
  display: flex;
  justify-content: center;
  align-items: flex-start;
  padding: 6em 2em 4em;
  color: rgba(var(--bng-off-white-rgb), 0.95);
  overflow: auto;
}

.mb-panel {
  width: min(1100px, 100%);
  display: flex;
  flex-direction: column;
  gap: 0.8em;
  background: rgba(var(--bng-off-black-rgb), 0.85);
  padding: 1em 1.2em 1.2em;
}

.mb-header {
  display: flex;
  align-items: center;
  gap: 1em;
  h1 { margin: 0; font-size: 1.6em; font-weight: 600; }
}

.mb-dim { color: rgba(var(--bng-off-white-rgb), 0.6); margin: 0; }

.mb-body { display: flex; gap: 0.8em; align-items: stretch; }

.mb-box {
  background: rgba(var(--bng-off-black-rgb), 0.5);
  padding: 0.8em 1em;
  display: flex;
  flex-direction: column;
  gap: 0.5em;
  h2 { margin: 0.2em 0; font-size: 1.05em; font-weight: 600; }
}

.mb-grow { flex: 1 1 auto; min-width: 0; }
.mb-side { flex: 0 0 21em; }

.mb-row { display: flex; gap: 0.5em; align-items: center; }
.mb-between { justify-content: space-between; }
.mb-end { justify-content: flex-end; margin-top: auto; }
.mb-fill { flex: 1 1 auto; }

.mb-list { display: flex; flex-direction: column; gap: 0.3em; max-height: 26em; overflow-y: auto; }

.mb-server {
  display: flex;
  align-items: center;
  gap: 0.6em;
  padding: 0.4em 0.6em;
  background: rgba(var(--bng-off-white-rgb), 0.06);
}
.mb-server-main { flex: 1 1 auto; min-width: 0; }
.mb-server-name { font-weight: 600; }
.mb-server-info { min-width: 9em; text-align: right; }
.mb-pass { width: 10em; }

.mb-offline { color: #c86464; }
.mb-error { color: #e0a060; margin: 0; }

.mb-mods { display: flex; flex-direction: column; gap: 0.4em; p { margin: 0; } }
.mb-modlist { margin: 0; padding-left: 1.2em; max-height: 9em; overflow-y: auto; }
.mb-players { list-style: none; margin: 0; padding: 0; li { padding: 0.2em 0; } }
</style>
