// MultiBeam dedicated server.
// Build: run "Run Server.bat" (compiles with the C# compiler that ships with Windows).
//
// Protocol: newline-delimited text over TCP. Each line is "TYPE|field|field|...|payload".
// The server never parses vehicle JSON; it only relays it, which keeps it fast and version-proof.
//
// Client -> server            Server -> client
//   H|ver|name|password|steamid W|json                 welcome (id, name, map, motd, ...)
//                               R|vid|spawn|state      restore a saved vehicle (from the player's profile)
//   S|vid|json   spawn/update   E|reason               rejected / kicked
//   D|vid        delete         J|pid|name             player joined
//   Y|vid|kind|json  sync data  L|pid                  player left
//                               S|pid|vid|json         vehicle spawned/updated
//   K|token      ping           D|pid|vid              vehicle deleted
//   I            info query     Y|pid|vid|kind|json    sync data (p position, i inputs, e electrics,
//                                                       l/g powertrain, b broken parts, a active 1/0,
//                                                       d damage changes, df full damage set, r reset)
//   F|vid  the vehicle the player is controlling (saved with the profile; sent on as F|pid|vid)
//                               M|text                 server message
//                               K|token                pong
//                               I|json                 info reply
//   (a bridge may send G|version before anything else to announce itself)

using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Threading;

namespace MultiBeam
{
    class Config
    {
        public string Name = "MultiBeam Server";
        public int Port = 30814;
        public int MaxPlayers = 16;
        public int MaxVehicles = 4;
        public bool Traffic = true;      // career worlds: shared AI traffic on/off
        public int TrafficAmount = 6;    // moving AI cars in the world (simulated by the traffic host)
        public int ParkedAmount = 4;     // parked AI cars in the world
        public int MaxTraffic { get { return Traffic ? TrafficAmount + ParkedAmount : 0; } }
        public string Map = "gridmap_v2";
        public string Password = "";
        public string Motd = "Welcome to MultiBeam!";
        public bool RequireSteam = true;
        public bool Career = false;
        public bool ModSync = true;      // players must run exactly the mods in the server's mods folder

        public static Config Load(string path)
        {
            Config c = new Config();
            if (!File.Exists(path))
            {
                File.WriteAllText(path,
                    "# MultiBeam server configuration (YAML). Restart the server after editing.\r\n" +
                    "name: " + c.Name + "\r\n" +
                    "port: " + c.Port + "\r\n" +
                    "maxplayers: " + c.MaxPlayers + "\r\n" +
                    "maxvehicles: " + c.MaxVehicles + "   # per player\r\n" +
                    "# career mode traffic: the server decides how much there is; one player's game (the host, chosen by the server)\r\n" +
                    "# simulates it and everyone else sees the same cars\r\n" +
                    "traffic: true\r\n" +
                    "trafficamount: " + c.TrafficAmount + "\r\n" +
                    "parkedamount: " + c.ParkedAmount + "\r\n" +
                    "# level folder name, e.g. gridmap_v2, west_coast_usa, italy, east_coast_usa, utah\r\n" +
                    "map: " + c.Map + "\r\n" +
                    "# leave empty for a public server\r\n" +
                    "password: \"\"\r\n" +
                    "motd: " + c.Motd + "\r\n" +
                    "# players are identified by Steam ID; their profile is saved in the players folder\r\n" +
                    "requiresteam: true\r\n" +
                    "# true = every player plays their own career save, stored here on the server (players folder, by Steam ID)\r\n" +
                    "# in this world. Works on maps that have career content, e.g. west_coast_usa.\r\n" +
                    "career: false\r\n" +
                    "# mods: put .zip mods in the mods folder next to this file. Players are asked to download the ones they\r\n" +
                    "# lack, all their other mods are switched off while they play here (and back on when they leave), and\r\n" +
                    "# nobody can join with more or fewer mods than the server has. false = no mod checking at all.\r\n" +
                    "modsync: true\r\n");
                Log("Created default config: " + path);
                return c;
            }
            foreach (string raw in File.ReadAllLines(path))
            {
                string line = raw.Trim();
                if (line.Length == 0 || line[0] == '#') continue;
                int eq = line.IndexOf(':');
                if (eq < 0) continue;
                string k = line.Substring(0, eq).Trim().ToLowerInvariant();
                string v = line.Substring(eq + 1).Trim();
                if (v.Length > 0 && (v[0] == '"' || v[0] == '\''))
                {
                    int close = v.IndexOf(v[0], 1);
                    v = close > 0 ? v.Substring(1, close - 1) : v.Substring(1);
                }
                else
                {
                    int hash = v.IndexOf(" #");   // strip trailing comment
                    if (hash >= 0) v = v.Substring(0, hash).Trim();
                }
                int n;
                switch (k)
                {
                    case "name": c.Name = v; break;
                    case "port": if (int.TryParse(v, out n) && n > 0 && n < 65536) c.Port = n; break;
                    case "maxplayers": if (int.TryParse(v, out n) && n > 0) c.MaxPlayers = n; break;
                    case "maxvehicles": if (int.TryParse(v, out n) && n > 0) c.MaxVehicles = n; break;
                    case "traffic": c.Traffic = v.ToLowerInvariant() != "false"; break;
                    case "trafficamount": if (int.TryParse(v, out n) && n >= 0) c.TrafficAmount = n; break;
                    case "parkedamount": if (int.TryParse(v, out n) && n >= 0) c.ParkedAmount = n; break;
                    case "maxtraffic": break;   // (old setting, now trafficamount + parkedamount)
                    case "map": c.Map = v; break;
                    case "password": c.Password = v; break;
                    case "motd": c.Motd = v; break;
                    case "requiresteam": c.RequireSteam = v.ToLowerInvariant() != "false"; break;
                    case "career": c.Career = v.ToLowerInvariant() == "true"; break;
                    case "modsync": c.ModSync = v.ToLowerInvariant() != "false"; break;
                }
            }
            return c;
        }

        static void Log(string s) { Server.Log(s); }
    }

    class Client
    {
        public int Id;
        public string Name;
        public TcpClient Tcp;
        public NetworkStream Stream;
        public bool Ready;                 // finished handshake
        public volatile bool Dead;
        public readonly object SendLock = new object();
        // vehicle id (client-local) -> last spawn payload, so late joiners can be sent existing cars
        public readonly Dictionary<string, string> Vehicles = new Dictionary<string, string>();
        public string Address;
        public bool ViaBridge;     // connected through a MultiBeam bridge
        public string SteamId = "";
        public bool HadVehicle;    // spawned at least one car this session; otherwise keep the saved ones
        public DateTime JoinedAt;
        // vehicle id -> latest state line payload (position etc.), saved with the profile
        public readonly Dictionary<string, string> LastState = new Dictionary<string, string>();
        // vehicle id -> "1"/"0": whether the car is in play (the on-foot avatar is switched off while its owner drives)
        public readonly Dictionary<string, string> LastActive = new Dictionary<string, string>();
        public string Current;     // id of the vehicle the player is controlling right now (F messages)
        // vehicle id -> the owner's latest full damage set (json), for late joiners and the saved profile
        public readonly Dictionary<string, string> LastDamage = new Dictionary<string, string>();
    }

    // Per-player save data, keyed by Steam ID. Plain "key=value" lines in players/<steamid>.profile.
    class Profile
    {
        public string SteamId, Name = "", Map = "";
        public string FirstSeen = "", LastSeen = "";
        public long PlaytimeSeconds;
        public int Joins;
        // {spawnPayload, lastState, active "1"/"0", current "1"/"0", damage json or "0"}; current = the vehicle the player was controlling
        public List<string[]> Vehicles = new List<string[]>();

        public static string PathFor(string dir, string steamId) { return Path.Combine(dir, steamId + ".profile"); }

        public static Profile Load(string dir, string steamId)
        {
            Profile p = new Profile();
            p.SteamId = steamId;
            string path = PathFor(dir, steamId);
            if (!File.Exists(path)) return p;
            foreach (string line in File.ReadAllLines(path, Encoding.UTF8))
            {
                int eq = line.IndexOf('=');
                if (eq < 0) continue;
                string k = line.Substring(0, eq), v = line.Substring(eq + 1);
                long n;
                switch (k)
                {
                    case "name": p.Name = v; break;
                    case "map": p.Map = v; break;
                    case "first": p.FirstSeen = v; break;
                    case "last": p.LastSeen = v; break;
                    case "playtime": if (long.TryParse(v, out n)) p.PlaytimeSeconds = n; break;
                    case "joins": if (long.TryParse(v, out n)) p.Joins = (int)n; break;
                    case "vehicle":
                        // payload \t state [\t active \t current]   (older profiles only have the first two)
                        string[] f = v.Split('\t');
                        if (f.Length >= 2)
                            p.Vehicles.Add(new string[] { f[0], f[1], f.Length > 2 ? f[2] : "1", f.Length > 3 ? f[3] : "0", f.Length > 4 ? f[4] : "0" });
                        break;
                }
            }
            return p;
        }

        public void Save(string dir)
        {
            Directory.CreateDirectory(dir);
            StringBuilder sb = new StringBuilder();
            sb.Append("steamid=").Append(SteamId).Append("\n");
            sb.Append("name=").Append(Name).Append("\n");
            sb.Append("map=").Append(Map).Append("\n");
            sb.Append("first=").Append(FirstSeen).Append("\n");
            sb.Append("last=").Append(LastSeen).Append("\n");
            sb.Append("playtime=").Append(PlaytimeSeconds).Append("\n");
            sb.Append("joins=").Append(Joins).Append("\n");
            foreach (string[] v in Vehicles)
                sb.Append("vehicle=").Append(v[0]).Append('\t').Append(v[1]).Append('\t').Append(v[2]).Append('\t').Append(v[3])
                  .Append('\t').Append(v[4]).Append("\n");
            string path = PathFor(dir, SteamId);
            File.WriteAllText(path + ".tmp", sb.ToString(), new UTF8Encoding(false));
            if (File.Exists(path)) File.Delete(path);
            File.Move(path + ".tmp", path);
        }
    }

    class Server
    {
        const int ProtocolVersion = 5;
        // A client pings every few seconds, but not while its game is loading a level, and a big career (the RLS
        // Career Overhaul map takes over two minutes) freezes it for that long. A connection that is really gone
        // is normally noticed by the network anyway; this only matters for one that goes silent.
        const int ClientTimeoutMs = 15 * 60 * 1000;
        static readonly object ProfileLock = new object();
        static string ProfileDir;
        const int MaxLine = 4 * 1024 * 1024;   // vehicle configs can be big
        static Config cfg;
        static readonly object Lock = new object();
        static readonly Dictionary<int, Client> Clients = new Dictionary<int, Client>();
        static int nextId = 1;
        static volatile bool running = true;
        static readonly UTF8Encoding Utf8 = new UTF8Encoding(false);

        public static void Log(string s)
        {
            Console.WriteLine("[" + DateTime.Now.ToString("HH:mm:ss") + "] " + s);
        }

        static int Main(string[] args)
        {
            Console.Title = "MultiBeam Server";
            string dir = AppDomain.CurrentDomain.BaseDirectory;
            cfg = Config.Load(Path.Combine(dir, "config.yml"));
            if (args.Length > 0)
            {
                int p;
                if (int.TryParse(args[0], out p) && p > 0 && p < 65536) cfg.Port = p;
            }

            TcpListener listener;
            try
            {
                listener = new TcpListener(IPAddress.Any, cfg.Port);
                listener.Start();
            }
            catch (Exception e)
            {
                Log("Could not listen on port " + cfg.Port + ": " + e.Message);
                Console.WriteLine("Press Enter to exit.");
                Console.ReadLine();
                return 1;
            }

            Log("MultiBeam server \"" + cfg.Name + "\" running on port " + cfg.Port + " (map: " + cfg.Map + ", max players: " + cfg.MaxPlayers + ")");
            Log("Players join with  <your-ip>:" + cfg.Port + ".  Forward TCP port " + cfg.Port + " on your router for internet play.");
            Log("Type 'help' for commands.");

            ProfileDir = Path.Combine(dir, "players");
            ModDir = Path.Combine(dir, "mods");
            if (cfg.ModSync)
            {
                try { Directory.CreateDirectory(ModDir); } catch (Exception) { }
                List<ModFile> found = ScanMods();
                Log("Mod checking is on: " + found.Count + " mod(s) in the mods folder" + (found.Count == 0 ? " (players will run without mods)" : "") + ".");
                foreach (ModFile m in found) Log("  " + m.Name + "  " + (m.Size / 1024) + " KB");
            }
            // Ctrl+C or closing the window: save everyone first
            Console.CancelKeyPress += delegate (object s, ConsoleCancelEventArgs e) { running = false; SaveAll(); };
            AppDomain.CurrentDomain.ProcessExit += delegate (object s, EventArgs e) { SaveAll(); };
            Thread saver = new Thread(AutoSave);
            saver.IsBackground = true;
            saver.Start();

            Thread accept = new Thread(delegate ()
            {
                while (running)
                {
                    try
                    {
                        TcpClient tc = listener.AcceptTcpClient();
                        Thread t = new Thread(delegate () { HandleClient(tc); });
                        t.IsBackground = true;
                        t.Start();
                    }
                    catch (Exception) { if (!running) break; }
                }
            });
            accept.IsBackground = true;
            accept.Start();

            // console commands
            while (running)
            {
                string line = Console.ReadLine();
                if (line == null) { Thread.Sleep(Timeout.Infinite); }
                Command(line.Trim());
            }
            listener.Stop();
            return 0;
        }

        static void Command(string line)
        {
            if (line.Length == 0) return;
            string[] parts = line.Split(new char[] { ' ' }, 2);
            string cmd = parts[0].ToLowerInvariant();
            string arg = parts.Length > 1 ? parts[1].Trim() : "";
            switch (cmd)
            {
                case "help":
                    Console.WriteLine("  list            show connected players");
                    Console.WriteLine("  kick <name>     remove a player");
                    Console.WriteLine("  stop            shut the server down");
                    break;
                case "list":
                    lock (Lock)
                    {
                        Console.WriteLine("Players (" + CountReady() + "/" + cfg.MaxPlayers + "):");
                        foreach (Client c in Clients.Values)
                            if (c.Ready) Console.WriteLine("  #" + c.Id + " " + c.Name + "  steam " + (c.SteamId.Length > 0 ? c.SteamId : "-") + "  " + c.Address + "  vehicles: " + c.Vehicles.Count);
                    }
                    break;
                case "kick":
                    Client target = null;
                    lock (Lock)
                        foreach (Client c in Clients.Values)
                            if (c.Ready && string.Equals(c.Name, arg, StringComparison.OrdinalIgnoreCase)) target = c;
                    if (target == null) Console.WriteLine("No such player.");
                    else { Send(target, "E|You were kicked from the server."); Drop(target, "kicked"); }
                    break;
                case "stop":
                case "exit":
                case "quit":
                    Log("Saving players and shutting down.");
                    running = false;
                    SaveAll();
                    Environment.Exit(0);
                    break;
                default:
                    Console.WriteLine("Unknown command. Type 'help'.");
                    break;
            }
        }

        static int CountReady()
        {
            int n = 0;
            foreach (Client c in Clients.Values) if (c.Ready) n++;
            return n;
        }

        static string Clean(string s)
        {
            StringBuilder sb = new StringBuilder();
            foreach (char ch in s)
                if (ch >= ' ' && ch != '|' && ch != '') sb.Append(ch);
            return sb.ToString();
        }

        static string JsonStr(string s)
        {
            StringBuilder sb = new StringBuilder("\"");
            foreach (char ch in s)
            {
                if (ch == '"') sb.Append("\\\"");
                else if (ch == '\\') sb.Append("\\\\");
                else if (ch < ' ') sb.Append(' ');
                else sb.Append(ch);
            }
            return sb.Append('"').ToString();
        }

        static string InfoJson()
        {
            int n;
            lock (Lock) n = CountReady();
            return "{\"name\":" + JsonStr(cfg.Name) + ",\"players\":" + n + ",\"maxPlayers\":" + cfg.MaxPlayers +
                   ",\"map\":" + JsonStr(cfg.Map) + ",\"passworded\":" + (cfg.Password.Length > 0 ? "true" : "false") +
                   ",\"career\":" + (cfg.Career ? "true" : "false") + ",\"protocol\":" + ProtocolVersion + "}";
        }

        // ---- networking -----------------------------------------------------------------------

        static void Send(Client c, string line)
        {
            if (c.Dead) return;
            if (line.StartsWith("E|")) Log((c.ViaBridge ? "[bridge] " : "") + "Refused " + c.Address + ": " + line.Substring(2));
            try
            {
                byte[] data = Utf8.GetBytes(line + "\n");
                lock (c.SendLock) c.Stream.Write(data, 0, data.Length);
            }
            catch (Exception) { c.Dead = true; try { c.Tcp.Close(); } catch (Exception) { } }
        }

        static void Broadcast(string line, Client except)
        {
            List<Client> targets = new List<Client>();
            lock (Lock)
                foreach (Client c in Clients.Values)
                    if (c.Ready && c != except) targets.Add(c);
            foreach (Client c in targets) Send(c, line);
        }

        // Returns null on disconnect / oversize line.
        static string ReadLine(NetworkStream s, byte[] buf, ref int have, ref int start)
        {
            // buf holds unread bytes in [start, start+have)
            MemoryStream acc = null;
            while (true)
            {
                for (int i = start; i < start + have; i++)
                {
                    if (buf[i] == (byte)'\n')
                    {
                        int len = i - start;
                        string result;
                        if (acc == null) result = Utf8.GetString(buf, start, len);
                        else { acc.Write(buf, start, len); result = Utf8.GetString(acc.ToArray()); }
                        int consumed = len + 1;
                        start += consumed; have -= consumed;
                        return result.TrimEnd('\r');
                    }
                }
                if (acc == null) acc = new MemoryStream();
                acc.Write(buf, start, have);
                if (acc.Length > MaxLine) return null;
                start = 0; have = 0;
                int n = s.Read(buf, 0, buf.Length);
                if (n <= 0) return null;
                have = n;
            }
        }

        static void HandleClient(TcpClient tc)
        {
            Client me = new Client();
            me.Tcp = tc;
            me.Address = tc.Client.RemoteEndPoint.ToString();
            try
            {
                tc.NoDelay = true;
                tc.ReceiveTimeout = ClientTimeoutMs;
                tc.SendTimeout = 10000;
                me.Stream = tc.GetStream();
                byte[] buf = new byte[65536];
                int have = 0, start = 0;

                // first line decides: info query or handshake. A bridge announces itself first with "G|version".
                string first = ReadLine(me.Stream, buf, ref have, ref start);
                if (first != null && first.StartsWith("G|"))
                {
                    me.ViaBridge = true;
                    Log("[bridge] connected from " + me.Address + " (bridge " + Clean(first.Substring(2)) + ")");
                    first = ReadLine(me.Stream, buf, ref have, ref start);
                }
                if (first == null)
                {
                    Log((me.ViaBridge ? "[bridge] " : "") + "Connection from " + me.Address + " closed without sending anything");
                    return;
                }
                if (first == "I")
                {
                    Log((me.ViaBridge ? "[bridge] " : "") + "Status query from " + me.Address);
                    Send(me, "I|" + InfoJson());
                    return;
                }
                Log((me.ViaBridge ? "[bridge] " : "") + "Connection from " + me.Address);
                if (!Handshake(me, first, buf, ref have, ref start)) return;

                while (!me.Dead)
                {
                    string line = ReadLine(me.Stream, buf, ref have, ref start);
                    if (line == null) break;
                    Process(me, line);
                }
            }
            catch (Exception) { }
            finally
            {
                Drop(me, "disconnected");
            }
        }

        // ---- mod management ------------------------------------------------------------------------
        // The server has a mods folder. Before a player joins, the server sends the list (name, size, SHA-1); the
        // client makes its own mods match (downloading from here what it lacks) and reports what it then has
        // enabled; anything but an exact match is refused.

        class ModFile { public string Name, Path, Sha1; public long Size; public long Stamp; }
        const int ModChunk = 48 * 1024;
        static readonly Dictionary<string, ModFile> modCache = new Dictionary<string, ModFile>();
        static string ModDir;

        static List<ModFile> ScanMods()
        {
            List<ModFile> list = new List<ModFile>();
            if (!Directory.Exists(ModDir)) return list;
            lock (modCache)
            {
                foreach (string f in Directory.GetFiles(ModDir, "*.zip"))
                {
                    FileInfo fi = new FileInfo(f);
                    if (fi.Name.IndexOf('|') >= 0 || fi.Name.ToLowerInvariant() == "multibeam.zip") continue;
                    ModFile m;
                    if (!modCache.TryGetValue(f, out m) || m.Size != fi.Length || m.Stamp != fi.LastWriteTimeUtc.Ticks)
                    {
                        m = new ModFile();
                        m.Name = fi.Name; m.Path = f; m.Size = fi.Length; m.Stamp = fi.LastWriteTimeUtc.Ticks;
                        using (FileStream fs = new FileStream(f, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                        using (SHA1 sha = SHA1.Create())
                        {
                            byte[] h = sha.ComputeHash(fs);
                            StringBuilder sb = new StringBuilder();
                            foreach (byte b in h) sb.Append(b.ToString("x2"));
                            m.Sha1 = sb.ToString();
                        }
                        modCache[f] = m;
                    }
                    list.Add(m);
                }
            }
            list.Sort(delegate (ModFile a, ModFile b) { return string.Compare(a.Name, b.Name, StringComparison.OrdinalIgnoreCase); });
            return list;
        }

        // returns false when the player must not join (declined, wrong mods, connection lost)
        static bool ModPhase(Client me, byte[] buf, ref int have, ref int start)
        {
            List<ModFile> mods = ScanMods();
            Send(me, "Q|B|" + mods.Count);
            foreach (ModFile m in mods) Send(me, "Q|M|" + m.Name + "|" + m.Size + "|" + m.Sha1);
            Send(me, "Q|E");
            Dictionary<string, FileStream> open = new Dictionary<string, FileStream>();
            me.Tcp.ReceiveTimeout = 30 * 60 * 1000;   // the player is asked first, then downloads
            try
            {
                byte[] chunk = new byte[ModChunk];
                while (true)
                {
                    string l = ReadLine(me.Stream, buf, ref have, ref start);
                    if (l == null) return false;
                    if (!l.StartsWith("Q|")) continue;
                    string[] f = l.Split(new char[] { '|' }, 4);
                    if (f.Length < 2) continue;
                    if (f[1] == "G" && f.Length >= 4)
                    {
                        ModFile m = null;
                        foreach (ModFile x in mods) if (x.Name == f[2]) m = x;
                        long off;
                        if (m == null || !long.TryParse(f[3], out off) || off < 0 || off >= m.Size) continue;
                        FileStream fs;
                        if (!open.TryGetValue(m.Name, out fs))
                        {
                            fs = new FileStream(m.Path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
                            open[m.Name] = fs;
                            Log(me.Address + " is downloading " + m.Name);
                        }
                        fs.Seek(off, SeekOrigin.Begin);
                        int n = fs.Read(chunk, 0, (int)Math.Min((long)ModChunk, m.Size - off));
                        Send(me, "Q|D|" + m.Name + "|" + off + "|" + Convert.ToBase64String(chunk, 0, n));
                    }
                    else if (f[1] == "X")
                    {
                        Send(me, "E|You need the server's mods to play here.");
                        return false;
                    }
                    else if (f[1] == "R")
                    {
                        // the client's enabled mods: name:size,name:size  (MultiBeam itself is not counted)
                        Dictionary<string, long> theirs = new Dictionary<string, long>();
                        if (f.Length >= 3)
                            foreach (string item in f[2].Split(new char[] { ',' }, StringSplitOptions.RemoveEmptyEntries))
                            {
                                int c = item.LastIndexOf(':');
                                long size;
                                if (c <= 0 || !long.TryParse(item.Substring(c + 1), out size)) continue;
                                string name = item.Substring(0, c).ToLowerInvariant();
                                if (name != "multibeam.zip") theirs[name] = size;
                            }
                        List<string> problems = new List<string>();
                        foreach (ModFile m in mods)
                        {
                            long size;
                            if (!theirs.TryGetValue(m.Name.ToLowerInvariant(), out size)) problems.Add("missing " + m.Name);
                            else if (size != m.Size) problems.Add("different version of " + m.Name);
                        }
                        foreach (string name in theirs.Keys)
                        {
                            bool known = false;
                            foreach (ModFile m in mods) if (m.Name.ToLowerInvariant() == name) known = true;
                            if (!known) problems.Add("extra mod " + name);
                        }
                        if (problems.Count > 0)
                        {
                            string why = "Your mods do not match the server's: " + string.Join("; ", problems.ToArray());
                            Send(me, "E|" + why);
                            return false;
                        }
                        Send(me, "Q|O");
                        return true;
                    }
                }
            }
            catch (Exception e) { Log("Mod check failed: " + e.Message); return false; }
            finally
            {
                foreach (FileStream fs in open.Values) fs.Close();
                try { me.Tcp.ReceiveTimeout = ClientTimeoutMs; } catch (Exception) { }
            }
        }

        static bool Handshake(Client me, string line, byte[] buf, ref int have, ref int start)
        {
            string[] p = line.Split(new char[] { '|' }, 5);
            if (p.Length < 2 || p[0] != "H") { Send(me, "E|Not a MultiBeam client."); return false; }
            int ver;
            if (!int.TryParse(p[1], out ver) || ver != ProtocolVersion)
            {
                Send(me, "E|Version mismatch. Server protocol " + ProtocolVersion + ", client " + p[1] + ". Update your MultiBeam mod / server (restart the game after installing the mod).");
                return false;
            }
            if (p.Length < 5) { Send(me, "E|Malformed handshake."); return false; }
            string name = Clean(p[2]).Trim();
            if (name.Length > 24) name = name.Substring(0, 24);
            if (name.Length == 0) { Send(me, "E|Invalid player name."); return false; }
            if (cfg.Password.Length > 0 && p[3] != cfg.Password) { Send(me, "E|Wrong password."); return false; }

            string steamId = p[4].Trim();
            bool validId = steamId.Length >= 15 && steamId.Length <= 20;
            foreach (char ch in steamId) if (ch < '0' || ch > '9') validId = false;
            if (!validId)
            {
                if (cfg.RequireSteam) { Send(me, "E|This server requires a Steam account. Start BeamNG.drive through Steam."); return false; }
                steamId = "";
            }

            if (cfg.ModSync && !ModPhase(me, buf, ref have, ref start)) return false;

            // one session per Steam ID: a new login replaces a stale one
            if (steamId.Length > 0)
            {
                Client old = null;
                lock (Lock)
                    foreach (Client c in Clients.Values)
                        if (c.Ready && c.SteamId == steamId) old = c;
                if (old != null) { Send(old, "E|You logged in from another location."); Drop(old, "replaced by a new login"); }
            }

            List<string> existing = new List<string>();
            Profile profile = null;
            if (steamId.Length > 0)
            {
                lock (ProfileLock)
                {
                    profile = Profile.Load(ProfileDir, steamId);
                    string now = DateTime.UtcNow.ToString("u");
                    if (profile.FirstSeen.Length == 0) profile.FirstSeen = now;
                    profile.LastSeen = now;
                    profile.Joins++;
                    profile.Name = name;
                    try { profile.Save(ProfileDir); } catch (Exception e) { Log("Could not save profile: " + e.Message); }
                }
            }
            lock (Lock)
            {
                if (CountReady() >= cfg.MaxPlayers) { Send(me, "E|Server is full."); return false; }
                // Steam names aren't unique: "Sam", "Sam (2)", ...
                string baseName = name;
                for (int n = 2; ; n++)
                {
                    bool taken = false;
                    foreach (Client c in Clients.Values)
                        if (c.Ready && string.Equals(c.Name, name, StringComparison.OrdinalIgnoreCase)) taken = true;
                    if (!taken) break;
                    string suffix = " (" + n + ")";
                    name = (baseName.Length + suffix.Length > 24 ? baseName.Substring(0, 24 - suffix.Length) : baseName) + suffix;
                }

                me.Id = nextId++;
                me.Name = name;
                me.SteamId = steamId;
                me.JoinedAt = DateTime.UtcNow;
                // snapshot of the world for the newcomer
                foreach (Client c in Clients.Values)
                {
                    if (!c.Ready) continue;
                    existing.Add("J|" + c.Id + "|" + c.Name);
                    foreach (KeyValuePair<string, string> v in c.Vehicles)
                    {
                        existing.Add("S|" + c.Id + "|" + v.Key + "|" + v.Value);
                        string active, damage;
                        if (c.LastActive.TryGetValue(v.Key, out active))
                            existing.Add("Y|" + c.Id + "|" + v.Key + "|a|" + active);
                        if (c.LastDamage.TryGetValue(v.Key, out damage))
                            existing.Add("Y|" + c.Id + "|" + v.Key + "|df|" + damage);
                    }
                    if (c.Current != null) existing.Add("F|" + c.Id + "|" + c.Current);
                }
                me.Ready = true;
                Clients[me.Id] = me;
            }

            // Saved progress: the vehicles the player had when they last left this map, where they were, whether the
            // on-foot avatar was switched off, and which one they were controlling. The client puts them back.
            List<string> restore = new List<string>();
            if (profile != null && profile.Map == cfg.Map && !cfg.Career)   // career saves keep the cars themselves
            {
                bool anyCurrent = false;
                foreach (string[] v in profile.Vehicles) if (v[1].Length > 0 && v[3] == "1") anyCurrent = true;
                foreach (string[] v in profile.Vehicles)
                {
                    if (v[1].Length == 0 || restore.Count >= cfg.MaxVehicles) continue;
                    string current = v[3];
                    if (!anyCurrent && restore.Count == 0) current = "1";   // nothing was marked: first one gets the driver's seat
                    // R|active|current|state|damage|payload  (payload last: it is the only field that may contain '|')
                    restore.Add("R|" + v[2] + "|" + current + "|" + v[1] + "|" + v[4] + "|" + v[0]);
                }
            }

            Send(me, "W|{\"id\":" + me.Id + ",\"you\":" + JsonStr(me.Name) + ",\"name\":" + JsonStr(cfg.Name) + ",\"map\":" + JsonStr(cfg.Map) +
                     ",\"motd\":" + JsonStr(cfg.Motd) + ",\"maxPlayers\":" + cfg.MaxPlayers + ",\"maxVehicles\":" + cfg.MaxVehicles + ",\"maxTraffic\":" + cfg.MaxTraffic + ",\"traffic\":" + (cfg.Traffic ? "true" : "false") + ",\"trafficAmount\":" + cfg.TrafficAmount + ",\"parkedAmount\":" + cfg.ParkedAmount +
                     ",\"restore\":" + restore.Count + ",\"career\":" + (cfg.Career ? "true" : "false") + "}");
            if (cfg.Career) Send(me, "C|" + LoadCareer(steamId));   // the player's career save (date|json), before anything else
            foreach (string s in existing) Send(me, s);
            foreach (string r in restore) Send(me, r);
            if (restore.Count > 0) Log("Restoring " + restore.Count + " saved vehicle(s) for " + me.Name);
            Broadcast("J|" + me.Id + "|" + me.Name, me);
            if (cfg.Career)
            {
                UpdateTrafficHost();
                Send(me, "T|" + TrafficPlayers);   // (the broadcast above only goes out when the count changes)
            }
            Log(me.Name + " joined" + (me.ViaBridge ? " via bridge" : "") + " from " + me.Address + " (#" + me.Id + ", steam " + (steamId.Length > 0 ? steamId : "none") + ")");
            return true;
        }

        // ---- career saves: one file per Steam ID, "date|json" (the client's packed save folder) ----------

        static string CareerPath(string steamId)
        {
            return Path.Combine(ProfileDir, steamId + ".career");
        }

        static string LoadCareer(string steamId)
        {
            if (steamId.Length == 0) return "0|";
            lock (ProfileLock)
            {
                try
                {
                    string p = CareerPath(steamId);
                    if (File.Exists(p)) return File.ReadAllText(p, Encoding.UTF8);
                }
                catch (Exception e) { Log("Could not read career save: " + e.Message); }
            }
            return "0|";
        }

        static void StoreCareer(Client me, string data)
        {
            if (!cfg.Career || me.SteamId.Length == 0 || data.IndexOf('|') < 1) return;
            lock (ProfileLock)
            {
                try
                {
                    string p = CareerPath(me.SteamId);
                    File.WriteAllText(p + ".tmp", data, new UTF8Encoding(false));
                    if (File.Exists(p)) File.Delete(p);
                    File.Move(p + ".tmp", p);
                }
                catch (Exception e) { Log("Could not save career for " + me.Name + ": " + e.Message); return; }
            }
            Log("Saved career of " + me.Name + " (" + (data.Length / 1024) + " KB)");
        }

        static void Process(Client me, string line)
        {
            if (line.Length == 0) return;
            char type = line[0];
            switch (type)
            {
                case 'K':
                    Send(me, line);   // echo token back as pong
                    break;
                case 'C':
                    StoreCareer(me, line.Substring(Math.Min(2, line.Length)));
                    break;
                case 'S':
                {
                    string[] p = line.Split(new char[] { '|' }, 3);
                    if (p.Length < 3 || p[1].Length == 0 || p[1].Length > 16) return;
                    lock (Lock)
                    {
                        // AI cars use ids starting with "t" and have their own limit; players' cars use MaxVehicles
                        bool ai = p[1][0] == 't';
                        int have = 0;
                        foreach (string k in me.Vehicles.Keys) if ((k[0] == 't') == ai) have++;
                        // AI cars are limited by the server's settings (a game also has pooled cars that are switched off,
                        // so the limit per player is generous; the games themselves keep the active number to their share)
                        if (ai && (!cfg.Traffic || (!me.Vehicles.ContainsKey(p[1]) && have >= cfg.MaxTraffic * 2)))
                        {
                            Send(me, "X|" + p[1]);   // quietly refused
                            return;
                        }
                        if (!me.Vehicles.ContainsKey(p[1]) && !ai && have >= cfg.MaxVehicles)
                        {
                            Send(me, "M|Vehicle limit reached (" + cfg.MaxVehicles + ").");
                            Send(me, "X|" + p[1]);   // tell client to remove that car
                            return;
                        }
                        me.Vehicles[p[1]] = p[2];
                        me.HadVehicle = true;
                    }
                    Broadcast("S|" + me.Id + "|" + p[1] + "|" + p[2], me);
                    break;
                }
                case 'D':
                {
                    string[] p = line.Split(new char[] { '|' }, 2);
                    if (p.Length < 2) return;
                    bool had;
                    lock (Lock)
                    {
                        had = me.Vehicles.Remove(p[1]);
                        me.LastState.Remove(p[1]); me.LastActive.Remove(p[1]); me.LastDamage.Remove(p[1]);
                    }
                    if (had) Broadcast("D|" + me.Id + "|" + p[1], me);
                    break;
                }
                case 'Y':
                {
                    // synced vehicle data: Y|vid|kind|json. kinds: p position, i inputs, e electrics,
                    // l/g powertrain, b broken parts. Relayed untouched to everyone else; only the owner's car counts.
                    string[] p = line.Split(new char[] { '|' }, 4);
                    if (p.Length < 4 || p[2].Length == 0 || p[2].Length > 4) return;
                    bool owns;
                    lock (Lock)
                    {
                        owns = me.Vehicles.ContainsKey(p[1]);
                        if (owns && p[2] == "p") me.LastState[p[1]] = p[3];   // saved with the profile
                        if (owns && p[2] == "a") me.LastActive[p[1]] = p[3];  // replayed to players who join later
                        if (owns && p[2] == "df") me.LastDamage[p[1]] = p[3]; // full damage set: joiners + profile
                        if (owns && p[2] == "r") me.LastDamage.Remove(p[1]);  // reset/repair: no damage any more
                    }
                    if (owns) Broadcast("Y|" + me.Id + "|" + p[1] + "|" + p[2] + "|" + p[3], me);
                    break;
                }
                case 'F':
                {
                    // F|vid: the vehicle this player is controlling now. Saved so they are put back in it, and told to
                    // everyone else (F|pid|vid) so name tags go on the player: on foot the avatar, otherwise the car.
                    string[] p = line.Split(new char[] { '|' }, 2);
                    if (p.Length < 2) return;
                    bool owns;
                    lock (Lock)
                    {
                        owns = me.Vehicles.ContainsKey(p[1]);
                        if (owns) me.Current = p[1];
                    }
                    if (owns) Broadcast("F|" + me.Id + "|" + p[1], me);
                    break;
                }
            }
        }

        // Writes the player's profile: identity, playtime and the vehicles they currently have out.
        static void SaveProfile(Client c)
        {
            if (c.SteamId.Length == 0) return;
            lock (ProfileLock)
            {
                try
                {
                    Profile p = Profile.Load(ProfileDir, c.SteamId);
                    DateTime now = DateTime.UtcNow;
                    p.SteamId = c.SteamId;
                    p.Name = c.Name;
                    p.Map = cfg.Map;
                    p.LastSeen = now.ToString("u");
                    p.PlaytimeSeconds += (long)(now - c.JoinedAt).TotalSeconds;
                    c.JoinedAt = now;
                    if (c.HadVehicle)
                    {
                        p.Vehicles.Clear();
                        lock (Lock)
                            foreach (KeyValuePair<string, string> v in c.Vehicles)
                            {
                                if (v.Key[0] == 't') continue;   // AI cars are not part of a player's saved progress
                                string st, act, dmg;
                                c.LastState.TryGetValue(v.Key, out st);
                                if (!c.LastActive.TryGetValue(v.Key, out act)) act = "1";
                                if (!c.LastDamage.TryGetValue(v.Key, out dmg)) dmg = "0";
                                if (st != null)
                                    p.Vehicles.Add(new string[] { v.Value, st, act, v.Key == c.Current ? "1" : "0", dmg });
                            }
                    }
                    p.Save(ProfileDir);
                }
                catch (Exception e) { Log("Could not save profile for " + c.Name + ": " + e.Message); }
            }
        }

        static void SaveAll()
        {
            List<Client> all = new List<Client>();
            lock (Lock) foreach (Client c in Clients.Values) if (c.Ready) all.Add(c);
            foreach (Client c in all) SaveProfile(c);
        }

        // progress is saved every few seconds, when a player leaves, and when the server shuts down
        static void AutoSave()
        {
            while (running)
            {
                Thread.Sleep(15000);
                SaveAll();
            }
        }

        // Career traffic: every player's game simulates AI cars around that player, and the others show copies of
        // them, so everyone has their own objects and there is one combined world. The server sets how much traffic
        // the world has; each game runs its share of it (the total divided by the number of players), which the
        // players are told here.
        static int TrafficPlayers = 0;

        static void UpdateTrafficHost()
        {
            if (!cfg.Career) return;
            int n;
            bool changed;
            lock (Lock)
            {
                n = CountReady();
                changed = n != TrafficPlayers;
                TrafficPlayers = n;
            }
            if (changed) Broadcast("T|" + n, null);
        }
        static void Drop(Client c, string why)
        {
            bool wasReady;
            lock (Lock)
            {
                wasReady = c.Ready && Clients.ContainsKey(c.Id);
                if (wasReady) Clients.Remove(c.Id);
            }
            c.Dead = true;
            try { c.Tcp.Close(); } catch (Exception) { }
            if (wasReady)
            {
                SaveProfile(c);
                Broadcast("L|" + c.Id, null);
                UpdateTrafficHost();
                Log(c.Name + " " + why + (c.ViaBridge ? " (bridge link closed)" : "") + ".");
            }
        }
    }
}

