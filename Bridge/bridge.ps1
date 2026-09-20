# MultiBeam bridge (Windows, PowerShell 5.1+).
# BeamNG only lets mods connect to this PC. This script listens on 127.0.0.1 and relays everything to the
# remote MultiBeam server set in config.yml. In the game, add 127.0.0.1:<listen port> as the server.
# On each connection it first sends "G|1" so the server can log that the player came in through a bridge.

$ErrorActionPreference = 'Stop'
$configPath = Join-Path $PSScriptRoot 'config.yml'
$connectTimeout = 8   # seconds

function Log($message) { Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $message) }

function Fail($message) {
    Log $message
    exit 1
}

# ---- config -----------------------------------------------------------------------------------
if (-not (Test-Path $configPath)) {
    @(
        '# MultiBeam bridge configuration (YAML)'
        '# The remote MultiBeam server this bridge connects you to, as IP:PORT'
        'server: '
        '# Local port the game connects to. In the game, add 127.0.0.1:<this port> as a server.'
        'listen: 30800'
    ) | Set-Content -Path $configPath -Encoding ASCII
}

$server = ''
$listenPort = 30800
foreach ($raw in Get-Content $configPath) {
    $line = $raw.Trim()
    if ($line -eq '' -or $line.StartsWith('#')) { continue }
    $colon = $line.IndexOf(':')
    if ($colon -lt 0) { continue }
    $key = $line.Substring(0, $colon).Trim().ToLowerInvariant()
    $value = $line.Substring($colon + 1).Trim()
    if ($value.StartsWith('"') -or $value.StartsWith("'")) {
        $q = $value[0]
        $end = $value.IndexOf($q, 1)
        $value = if ($end -gt 0) { $value.Substring(1, $end - 1) } else { $value.Substring(1) }
    } else {
        $hash = $value.IndexOf(' #')
        if ($hash -ge 0) { $value = $value.Substring(0, $hash).Trim() }
    }
    if ($key -eq 'server') { $server = $value }
    elseif ($key -eq 'listen') {
        $n = 0
        if ([int]::TryParse($value, [ref]$n) -and $n -gt 0 -and $n -lt 65536) { $listenPort = $n }
    }
}

if ($server -eq '') { Fail 'No server set. Open config.yml and set  server: IP:PORT  (the MultiBeam server to bridge to).' }
$lastColon = $server.LastIndexOf(':')
$serverPort = 0
if ($lastColon -le 0 -or -not [int]::TryParse($server.Substring($lastColon + 1), [ref]$serverPort) -or $serverPort -lt 1 -or $serverPort -gt 65535) {
    Fail "Invalid server `"$server`" in config.yml. Use the form  server: IP:PORT  (e.g. 203.0.113.5:30814)."
}
$serverHost = $server.Substring(0, $lastColon).Trim()

# ---- listen (loopback only: nothing outside this PC can use the bridge) ----------------------------
$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $listenPort)
try { $listener.Start() } catch {
    Fail "Could not listen on 127.0.0.1:$listenPort ($($_.Exception.Message)). Is another bridge using this port? Change  listen:  in config.yml."
}
Log "Bridge running: 127.0.0.1:$listenPort  ->  ${serverHost}:$serverPort"
Log "In BeamNG, add the server 127.0.0.1:$listenPort and leave this window open."

$hello = [System.Text.Encoding]::UTF8.GetBytes("G|1`n")
$buffer = New-Object byte[] 65536
$pending = New-Object System.Collections.ArrayList   # game connections still waiting for the server
$pairs = New-Object System.Collections.ArrayList     # established game <-> server relays
$owner = @{}                                          # socket -> pair

function Close-Socket($socket) { try { $socket.Close() } catch { } }

function Close-Pair($pair) {
    if ($pair.Closed) { return }
    $pair.Closed = $true
    $owner.Remove($pair.Game.Client)
    $owner.Remove($pair.Remote.Client)
    Close-Socket $pair.Game
    Close-Socket $pair.Remote
    $pairs.Remove($pair)
    Log "Connection closed ($($pairs.Count) active)"
}

function Refuse($p, $why) {
    Log "Could not reach ${serverHost}:$serverPort ($why)"
    try {
        $msg = [System.Text.Encoding]::UTF8.GetBytes("E|Could not reach ${serverHost}:$serverPort ($why). Check the address and that the port is forwarded.`n")
        $p.Game.GetStream().Write($msg, 0, $msg.Length)
    } catch { }
    Close-Socket $p.Game
    Close-Socket $p.Remote
}

try {
    while ($true) {
        # wait until something can be read (or 20 ms passes, to check pending connects)
        $readable = New-Object System.Collections.ArrayList
        [void]$readable.Add($listener.Server)
        foreach ($pair in $pairs) { [void]$readable.Add($pair.Game.Client); [void]$readable.Add($pair.Remote.Client) }
        [System.Net.Sockets.Socket]::Select($readable, $null, $null, 20000)

        foreach ($s in @($readable)) {
            if ([object]::ReferenceEquals($s, $listener.Server)) {
                while ($listener.Pending()) {
                    $game = $listener.AcceptTcpClient()
                    $game.NoDelay = $true
                    $remote = New-Object System.Net.Sockets.TcpClient
                    $remote.NoDelay = $true
                    $ar = $remote.BeginConnect($serverHost, $serverPort, $null, $null)
                    [void]$pending.Add(@{ Game = $game; Remote = $remote; Ar = $ar; Started = Get-Date })
                }
                continue
            }
            $pair = $owner[$s]
            if ($null -eq $pair -or $pair.Closed) { continue }
            $other = if ([object]::ReferenceEquals($s, $pair.Game.Client)) { $pair.Remote.Client } else { $pair.Game.Client }
            try {
                $n = $s.Receive($buffer, 0, $buffer.Length, [System.Net.Sockets.SocketFlags]::None)
                if ($n -le 0) { Close-Pair $pair; continue }
                $sent = 0
                while ($sent -lt $n) { $sent += $other.Send($buffer, $sent, $n - $sent, [System.Net.Sockets.SocketFlags]::None) }
            } catch { Close-Pair $pair }
        }

        # connections to the server that are still being made
        foreach ($p in @($pending)) {
            $timedOut = ((Get-Date) - $p.Started).TotalSeconds -gt $connectTimeout
            if ($p.Ar.IsCompleted) {
                [void]$pending.Remove($p)
                try {
                    $p.Remote.EndConnect($p.Ar)
                    $p.Remote.GetStream().Write($hello, 0, $hello.Length)
                    $pair = @{ Game = $p.Game; Remote = $p.Remote; Closed = $false }
                    [void]$pairs.Add($pair)
                    $owner[$p.Game.Client] = $pair
                    $owner[$p.Remote.Client] = $pair
                    Log "Game connected, relaying to ${serverHost}:$serverPort ($($pairs.Count) active)"
                } catch {
                    $reason = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
                    Refuse $p $reason
                }
            } elseif ($timedOut) {
                [void]$pending.Remove($p)
                Refuse $p 'no response'
            }
        }
    }
} finally {
    $listener.Stop()
}
