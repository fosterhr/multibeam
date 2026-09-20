# MultiBeam

A native multiplayer mod for **BeamNG.drive 0.39**. You install a mod, run a small dedicated server, and join by
`IP:PORT` from an in-game menu. There is no separate launcher, no account and no chat.

MultiBeam is built in three separate parts. Each one is its own folder with its own launcher and config:

| Folder | What it is | Who needs it |
| --- | --- | --- |
| [`Server/`](Server) | The dedicated server (C#, compiled by the compiler that ships with Windows) | Whoever hosts |
| [`Client/`](Client) | The game mod (Lua + Vue) and the script that packs it | Every player |
| [`Bridge/`](Bridge) | A tiny local relay (PowerShell on Windows, Python on Linux) | Players joining a server that is **not** on their own PC |

> **Status: experimental.** A lot of MultiBeam has been exercised against a real server and real clients, but this is a
> hobby-scale project and large parts (career mode, AI traffic sharing, mod management) are new. See
> [Known limitations](#known-limitations). Expect rough edges and read the logs when something misbehaves.

---

## Contents

- [Features](#features)
- [How it works](#how-it-works)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Server](#server) — [configuration](#server-configuration-reference), [console commands](#console-commands), [player data](#player-data)
- [Client](#client)
- [Bridge](#bridge)
- [Career mode](#career-mode)
- [AI traffic](#ai-traffic)
- [Mod management](#mod-management)
- [Player indicators](#player-indicators)
- [Vehicle synchronisation](#vehicle-synchronisation)
- [Wire protocol](#wire-protocol)
- [Troubleshooting](#troubleshooting)
- [Known limitations](#known-limitations)
- [Project layout](#project-layout)
- [Credits and licensing](#credits-and-licensing)

---

## Features

**Multiplayer core**
- Dedicated server, joined by `IP:PORT`. No launcher and no account: your **Steam name** is your player name (it cannot be changed in the mod).
- In-game menu: **Main menu → More → MultiBeam**. Save servers, see who is online, and direct-connect.
- Physically simulated remote cars (collisions and damage are real), remote copies of on-foot avatars, passenger seats, repairs and resets, damage matching between clients, and automatic resync when a copy drifts.
- Players are identified by **Steam ID**. The server keeps a profile per player and restores their progress (position, vehicles, current vehicle, avatar state, damage) on join.
- Returns you to the title screen when the server closes or you lose the connection.
- Name tags and map indicators for other players.

**Career mode**
- Enable the game's own career on any map that has career content, with **one save per player kept on the server** (not on their PC).
- Works with the base game's career and the **RLS Career Overhaul** mod.

**AI traffic**
- AI traffic and parked cars are shared so every player sees the same cars, with the total set by the server and split between players. Other players' AI cars cannot be entered (taxis excepted).

**Mod management**
- Put mods in the server's `mods` folder. Players are asked to download what they lack, their other mods are switched off while they play, and everything is put back when they leave. Nobody can join with more or fewer mods than the server has.

---

## How it works

```
   your PC                                               server PC (or the same PC)
 +--------------------+     +----------------+         +--------------------------+
 | BeamNG.drive       |     | Bridge         |  TCP    | MultiBeam server         |
 |  MultiBeam mod     |<--->| 127.0.0.1:30800|<------->| 0.0.0.0:30814            |
 |  (Lua, GE + vehicle)|     | (relay script) |         | relays, stores, saves    |
 +--------------------+     +----------------+         +--------------------------+
        loopback only            only for remote servers
```

BeamNG's Lua sandbox only allows mods to open sockets to **this PC** (`connect restricted` for anything else — an
FFI workaround was tried and does not work either). So the mod always connects to a loopback address:

- **Server on the same PC:** connect to `localhost:30814` directly.
- **Server elsewhere:** run the **Bridge** on your PC. It listens on `127.0.0.1:<listen>` and relays everything to the server you set in its `config.yml`. You add `127.0.0.1:30800` as the server in the game.

The server does not understand vehicle data; it relays and stores it. Every client runs the real physics for its own
cars and shows physically simulated copies of everyone else's. The server is the authority for who is in the world,
the settings, player profiles, career saves, the mod list and the AI traffic budget.

---

## Requirements

- **BeamNG.drive 0.39** (Windows). The mod is written against 0.39's Vue UI and Lua APIs.
- **Server:** Windows with .NET Framework 4 (already part of Windows 10/11; `Run Server.bat` uses the built-in `csc.exe`). Port **30814/TCP** (configurable) forwarded on your router for internet play.
- **Bridge:** Windows PowerShell 5.1+ (included in Windows), or Python 3 on Linux.
- Players need a **Steam** login (the server identifies players by Steam ID; `requiresteam: false` allows non-Steam clients without saved progress).

---

## Quick start

### 1. Run a server

1. Copy the `Server` folder anywhere.
2. Double-click **`Run Server.bat`**. It compiles `MultiBeamServer.cs` to `multibeam-server.exe` and starts it. A default `config.yml` is written on first run.
3. Edit `config.yml` (see the [reference](#server-configuration-reference)) and restart the server.
4. For internet play, forward TCP port `30814` to this PC.

### 2. Install the mod (every player)

1. Copy the `Client` folder anywhere.
2. **Close BeamNG.drive**, then double-click **`Build Mod.bat`**. It packs `lua/`, `scripts/` and `ui/` into `multibeam.zip` and copies it to  
   `%LOCALAPPDATA%\BeamNG\BeamNG.drive\current\mods\`.
3. Start the game.

> **Never build/install while the game is running.** BeamNG keeps the zip mounted; replacing it underneath a running game breaks the mod for the rest of that session. `Build Mod.bat` builds the zip but skips the copy while the game is open, and tells you.

### 3. Join

- **Server on your own PC:** in the game open **Main menu → More → MultiBeam**, add `localhost:30814` (or use *Direct connect*) and press **Join**.
- **Server on another PC:** run the [Bridge](#bridge) first, then add `127.0.0.1:30800` (the bridge's `listen` port) in the menu and join.

---

## Server

### Server configuration reference

`Server/config.yml` (created with defaults on first start; restart the server after editing). Comments start with `#`.

| Key | Default | Meaning |
| --- | --- | --- |
| `name` | `MultiBeam Server` | Name shown in the server list and the menu |
| `port` | `30814` | TCP port. Can also be given as the first command-line argument |
| `maxplayers` | `16` | Player limit |
| `maxvehicles` | `4` | Vehicles **per player**. Extra spawns are removed and the player is told |
| `map` | `gridmap_v2` | Level folder name, e.g. `gridmap_v2`, `west_coast_usa`, `italy`, `east_coast_usa`, `utah` |
| `password` | `""` | Leave empty for a public server |
| `motd` | `Welcome to MultiBeam!` | Message shown when a player joins |
| `requiresteam` | `true` | Players must play through Steam (needed for saved progress) |
| `career` | `false` | Run everyone in the game's career mode, saves stored on the server ([details](#career-mode)) |
| `traffic` | `true` | Career only: shared AI traffic on/off ([details](#ai-traffic)) |
| `trafficamount` | `6` | Career only: moving AI cars in the world (total for all players) |
| `parkedamount` | `4` | Career only: parked AI cars in the world (total for all players) |
| `modsync` | `true` | Enforce the server's `mods` folder ([details](#mod-management)). `false` disables all mod checking |

The map must exist on every player's PC (a map that ships as a mod is downloaded by [mod management](#mod-management)).

### Console commands

Type in the server window:

| Command | Effect |
| --- | --- |
| `help` | List the commands |
| `list` | Connected players: id, name, Steam ID, address, vehicle count |
| `kick <name>` | Remove a player |
| `stop` (or `exit`, `quit`) | Save everyone's profile and shut down. Ctrl+C and closing the window also save |

The log also shows joins and leaves, refusals (with the reason), and `[bridge]` lines when a player connects through a bridge.

### Player data

Everything is stored next to the server in `players/`:

| File | Content |
| --- | --- |
| `<steamid>.profile` | Name, first/last seen, playtime, joins, and the player's vehicles (config, last position, whether the avatar is switched on, which car they were driving, damage) |
| `<steamid>.career` | The player's career save (career servers only) |

Profiles are saved every 15 seconds, when a player leaves, and on shutdown. On join the client puts the vehicles back where they were and re-enters the car the player was driving.

One session per Steam ID: a second login replaces the first. Names are made unique (`Sam`, `Sam (2)`).

---

## Client

The mod lives in `Client/`:

- `lua/ge/extensions/multibeam/client.lua` — the main game-side extension: connection, sync, spawning, indicators, career and traffic logic.
- `lua/ge/extensions/multibeam/transport.lua` — non-blocking LuaSocket wrapper.
- `lua/ge/extensions/multibeam/mods.lua` — mod management.
- `lua/vehicle/extensions/multibeam/mb*VE.lua` — modules loaded into **every** vehicle (position, velocity, inputs, electrics, powertrain, damage, breakgroups).
- `lua/ge/extensions/core/cameraModes/mbPassenger.lua` — the passenger-seat camera.
- `lua/ge/extensions/career/startingModes/multibeam.lua` — the career starting mode used on career servers.
- `ui/ui-vue/mods/multibeam/` — the menu.
- `scripts/multibeam/modScript.lua` — loads the extension when the game starts.

Client settings (saved servers, last server) are stored in the game's `settings/multibeam.json`.

**Building without the game closed?** Run `Build Mod.bat` anyway: it produces `Client/multibeam.zip` and exits without installing. Close the game, run it again to install.

---

## Bridge

Needed **only** when the server is not on your own PC.

1. Open `Bridge/config.yml` and set the server:
   ```yaml
   server: 203.0.113.10:30814   # the remote MultiBeam server, IP:PORT
   listen: 30800                # local port the game connects to
   ```
2. Run it:
   - **Windows:** double-click `Run Bridge.bat` (runs `bridge.ps1` with PowerShell).
   - **Linux:** `bash run-bridge.sh` (needs Python 3; runs `bridge.py`).
3. In the game add `127.0.0.1:30800` (your `listen` port) as a server and join.

The bridge listens on loopback only, connects to the configured server (8-second timeout), announces itself so the
server log can show `[bridge]` connections, and gives readable errors when the server is unset or unreachable. It is
a plain script on purpose: no compiled binary to trust or rebuild.

---

## Career mode

Set `career: true` and `map:` to a level with career content (`west_coast_usa` is the reference).

- **The game's own career runs locally** for each player, on the server's map, in a save named after their Steam ID (`multibeam<steamid>`, or `multibeamrls<steamid>` when the RLS mod is active).
- **The server holds the save.** After every game save the client uploads it (all `.json` files of the save, minus two large regenerated ones: `vehicleShop.json` and `logisticsDatabase.json`). When a player joins, the server's copy is unpacked into a working copy, the career starts, and on a deliberate disconnect the client saves once more, uploads, and deletes the working copy.
- **Crash safety:** if a session ends without reaching the server, the newer local copy is kept and sent up after the next join.
- **Save kinds:** a base-game save and an RLS save are different formats. A server save is only loaded by the same kind; otherwise a new career starts and the next save replaces the server's copy.
- Career traffic and parked cars are not treated as player vehicles; only the player's avatar and inventory cars are shared as theirs.
- **Starting mode:** a `multibeam` starting mode (10,000 starting money, no tutorial, dealership start on `west_coast_usa`). New careers on other maps are started on the server's map.

### RLS Career Overhaul

RLS replaces the game's career modules while the game loads them, so it only works when it is active **from game start**.
MultiBeam handles that in [mod management](#mod-management): when a mod that contains game code is switched on or off, the
game must be restarted; after the restart the client rejoins the same server by itself. With RLS on the server's mod
list this means: first join → download → *Restart needed* → restart → automatic rejoin.

---

## AI traffic

In a career world the game spawns AI traffic and parked cars around the local player. MultiBeam makes that one shared set:

- **Every player's game simulates the AI cars around that player** (so taxis, police and traffic behave as in single player, and hailing a taxi works), and shares them with the others as copies. Everyone sees the combined set.
- **The server decides how much traffic exists** (`trafficamount`, `parkedamount`). Each game runs its share: the total divided by the number of players (told to clients whenever someone joins or leaves).
- Other players' AI cars are ordinary physical objects here. Every other player's car is also registered with the local traffic system as a real vehicle so traffic and police treat it as a road user.
- AI cars send position (about 10 per second) and damage only — no inputs/electrics/powertrain — and their paint changes are synced.
- **You cannot enter another player's AI car.** Taxis are the exception (their copies stay enterable; the game's taxi flag is used to tell).
- `traffic: false` removes AI traffic entirely.

Copies that turn out to be physically unstable are switched off at the first report and rebuilt; a model that keeps
failing starts in a *safe mode* (no unbreakable beams, no damage sync) and, if it keeps failing, is left out for a minute.

---

## Mod management

Give the server a `mods` folder (created automatically) and drop `.zip` mods into it. With `modsync: true`:

1. **On join** the server sends its mod list (name, size, SHA-1). Your client compares it with your mods.
2. **A prompt** lists what will happen:
   - server mods you lack → **downloaded** from the server (stored as `mods/mbdl_<name>.zip`, so they never overwrite a mod you own with the same name),
   - server mods you have but switched off → switched on while you play,
   - your other enabled mods → **switched off** while you play.
3. **Verification.** The client reports the mods it now has enabled and the server refuses anything but an exact match (naming the extra, missing or different mods). MultiBeam itself is never counted or disabled. An empty `mods` folder means players play with no other mods.
4. **Leaving on purpose** (Disconnect button, Cancel on the restart prompt) deletes the downloaded mods and switches your own mods back on. A **dropped connection or a restarted server does not**: the mods stay, so rejoining needs no new download. If you want them removed without joining, the server list shows a **Server mods installed → Restore my mods** box.
5. **Crash safety.** What was changed is written to `settings/multibeam_mods.json` *before* anything is changed.

Mods that contain **code or interface files** (`lua/`, `scripts/` or `ui/` folders — total conversions such as career
overhauls) cannot be loaded into a running game. When one is involved the client shows **Restart needed**, and after you
restart it rejoins the same server automatically (a password is not stored, so a passworded server needs a manual rejoin).

Downloads go through the same connection (and the bridge, if you use one) in 48 KB chunks with a small request window;
large mods take a while and the menu shows progress. The server trusts the client's report of its mods (it cannot
inspect a PC), so this is a consistency tool, not anti-cheat.

---

## Player indicators

- **In the world:** a black bar with white text — `<name> - <distance> mi` — centred just above the player's head or car. It is drawn with the game's own multiplayer name-tag billboard renderer, so it faces the camera with no line to the car. Distance is measured from your own vehicle/avatar.
- **Minimap:** a small white dot with a black outline for every other player.
- **Big map:** the same dot, drawn in the map view.
- One indicator per player: the vehicle they are controlling, otherwise their on-foot avatar. AI cars never get one.

---

## Vehicle synchronisation

Modelled on BeamMP: remote vehicles are **physically simulated copies**, nudged toward the owner's reported state.

- Sampling rates (per owned vehicle): position 50 Hz, inputs 30, electrics 15, powertrain 10, breakgroups 15, damage 4.
- **Position/velocity/inputs/electrics/powertrain** are ported from BeamMP's vehicle-side modules (`mbPositionVE`, `mbVelocityVE`, `mbInputsVE`, `mbElectricsVE`, `mbPowertrainVE`, `mbNodesVE`).
- **Damage** (`mbDamageVE`) is MultiBeam's own: the owner is the authority; copies are built unbreakable and receive the owner's damage as deltas, with periodic full sets; repairs and resets are repeated on every client.
- **Watchdog:** a copy that stays clearly away from where its owner says it is (or turned wrongly) is teleported back; one that cannot be moved is rebuilt.
- **On-foot avatars** are placed directly on every update (they are too light for the force-based correction) and drawn with the game's snowman config.
- **Spawn queue:** remote spawns are done one at a time, half a second apart, and held back (up to 8 s) while you are driving fast, so the unavoidable load hitch lands when it matters less. Position updates are coalesced to the newest per car once per frame.
- **Passengers:** walking up to another player's car and getting in puts you in the passenger seat (a mirrored driver camera); the owner alone controls the car.
- Cars whose own Lua was reloaded (repairs, tuning) get the sync modules put back within a couple of seconds.
- The game's instability handler is taken over for copies (the default ghosts the car and deletes it on the second instability).

---

## Wire protocol

Newline-delimited text over TCP; each line is `TYPE|field|field|…|payload`. The server never parses vehicle JSON.
Current **protocol version: 5** (client and server must match).

Client → server:

```
H|ver|name|password|steamid    login
S|vid|json                     spawn / update one of my vehicles
D|vid                          delete one
Y|vid|kind|json                sync data for one of my vehicles
F|vid                          the vehicle I am controlling now
K|token                        ping
I                              info query (server list)
C|date|json                    career save upload
Q|G|name|offset                request a chunk of a server mod
Q|R|name:size,name:size,...    report my enabled mods
Q|X                            decline the server's mods
```

Server → client:

```
W|json                         welcome (id, name, map, motd, limits, career/traffic settings)
J|pid|name   L|pid             a player joined / left
S|pid|vid|json                 a player's vehicle           D|pid|vid   deleted
Y|pid|vid|kind|json            sync data                    F|pid|vid   who controls what
R|active|current|state|damage|payload   restore one of my saved vehicles
C|date|json                    my career save ("0|" = none yet)
T|n                            players sharing the world's traffic
Q|B|count  Q|M|name|size|sha1  Q|E     mod manifest (begin / entry / end)
Q|D|name|offset|base64         a chunk of a mod             Q|O   mod list accepted
M|text                         server message               X|vid   vehicle refused
K|token                        pong                         I|json  info reply
E|reason                       error / refused / kicked
```

`Y` kinds: `p` position, `i` inputs, `e` electrics, `l`/`g` powertrain, `b` breakgroups, `a` avatar/vehicle in play,
`d`/`df` damage (changes / full set), `r` reset/repair, `c` paint. AI cars use vehicle ids starting with `t`.

A bridge sends `G|1` before anything else; the server uses that only for its log.

---
## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| **"connect restricted"** / "needs bridge" in the server list | The game only allows connections to this PC. Run the [Bridge](#bridge) and join `127.0.0.1:<listen>`. |
| **"Not a MultiBeam client" / "Version mismatch … restart the game"** | Server and client protocol versions differ, or the game was not restarted after installing the mod. Update both, restart BeamNG. |
| **Blank menu / mod does nothing** after building | The zip was replaced while the game ran. Close the game, run `Build Mod.bat` again, start the game. |
| **Disconnected while loading a big level** | A client sends no pings while its game is loading. The server tolerates up to 15 minutes of silence; make sure you are running a current server build (restart it). |
| **Grey screen after joining a server with RLS** | A code-replacing mod was switched on in a running game. Follow the *Restart needed* prompt; the client rejoins by itself. |
| **"Your mods do not match the server's"** | The message lists what differs. Accept the download prompt, or (if it says an extra mod) let MultiBeam switch it off. |
| **Other players' cars vanish / stutter** | A copy that keeps going unstable is rebuilt automatically. The game logs `Instability detected for vehicle …`; `beamng.log` lines tagged `multibeam` show what was done. |
| **Traffic looks doubled near another player** | Each game runs its own share of the traffic. Lower `trafficamount` / `parkedamount`. |

**Logs.** Client: `%LOCALAPPDATA%\BeamNG\BeamNG.drive\current\beamng.log` — filter for `multibeam`. Note the game keeps only the
first ~15,000 lines of a session, so a flood of errors can hide later events. Server: the console window.

---

## Known limitations

- **Experimental.** Career mode, AI traffic sharing and mod management in particular are recent and have had limited testing across machines.
- **Windows-first.** The server compiles with the .NET Framework compiler that ships with Windows; the Linux bridge script is provided but has not been tested.
- **Traffic only exists around the players.** You cannot hail a taxi that is another player's copy, and two players close together each add their share of traffic.
- **Some cars do not copy well.** A few models go physically unstable as remote copies (a `utv` and `wigeon` were seen); safe mode and rebuilds contain it but it is not fully solved.
- **Mods with game code need a restart** to be switched on or off, and removing them on leaving is done live at the main menu (a restart afterwards may be needed to fully unload them).
- **Trust model.** The server trusts the mod report of a client and the vehicle/save data it uploads. It is a friends-and-community tool, not a hardened anti-cheat.
- **Overriding game files does not work.** Replacing a base-game Lua file from a mod is not picked up; MultiBeam only adds new files and hooks (this is why some things — for example the minimap marker — use the game's extension hooks instead).
- Passwords are sent in clear text; do not reuse a password you care about.

---

## Project layout

```
MultiBeam/
├── README.md
├── Server/
│   ├── Run Server.bat          compile + run
│   ├── MultiBeamServer.cs      the whole server
│   ├── config.yml              settings (created on first run)
│   ├── mods/                   mods players must run (created on first run)
│   └── players/                profiles and career saves (created on first run)
├── Client/
│   ├── Build Mod.bat           pack + install the mod
│   ├── build-mod.ps1
│   ├── lua/  scripts/  ui/     the mod
│   └── multibeam.zip           build output
└── Bridge/
    ├── Run Bridge.bat          Windows launcher (bridge.ps1)
    ├── bridge.ps1
    ├── run-bridge.sh           Linux launcher (bridge.py)
    ├── bridge.py
    └── config.yml              which server to relay to
```

---

## Credits and licensing

- **BeamMP** — the vehicle-side synchronisation modules (`mbPositionVE`, `mbVelocityVE`, `mbInputsVE`, `mbElectricsVE`, `mbPowertrainVE`, `mbNodesVE`) are ported from [BeamMP](https://github.com/BeamMP/BeamMP), which is licensed **AGPL-3.0-or-later**; those files keep that license and a header saying so. If you publish MultiBeam, the repository as a whole must comply with the AGPL-3.0 (e.g. by licensing it AGPL-3.0-or-later).
- **CareerMP** (StanleyDudek) — the idea of running the game's career per player in a multiplayer world came from it; no code was taken.
- **BeamNG.drive** code that MultiBeam talks to is under BeamNG's bCDDL; nothing of it is redistributed here.
- The RLS Career Overhaul is a third-party mod; it is not part of this repository and you need to supply your own copy of it (and permission to redistribute it) if you put it in a server's `mods` folder.

*MultiBeam is an unofficial project and is not affiliated with BeamNG GmbH or BeamMP.*
