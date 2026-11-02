// docker-port-sync
//
// Makes published container ports behave like on Linux: what your compose file /
// "docker run -p" says is what gets exposed to the network.
//
//   ports: ["80:80"]            -> reachable from the network (TCP)
//   ports: ["53:53/udp"]        -> reachable from the network (UDP)
//   ports: ["127.0.0.1:80:80"]  -> only from this PC
//
// It watches Docker events through \\.\pipe\docker_engine and keeps Windows rules
// in sync. Runs as SYSTEM (a scheduled task), because firewall rules need admin.
//
// Modes
//   mirrored   WSL shares the Windows network. Only Hyper-V firewall rules are needed.
//   portproxy  WSL has its own internal network. TCP is forwarded with Windows
//              "netsh interface portproxy"; UDP is forwarded by this program.
//              Binding a specific host IP ("192.168.1.10:80:80") is not possible in
//              this mode: that IP does not exist inside WSL, so Docker rejects it.
//
// Usage: docker-port-sync.exe --mode mirrored|portproxy --state <dir> [--wsl-ip-file <path>]

using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

class DockerPortSync
{
    const string RulePrefix = "wsl-docker-engine";
    const string WslVmCreatorId = "{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}";

    static string mode = "mirrored";
    static string stateDir;
    static string ipFile;
    static string logPath;
    static readonly object SyncLock = new object();
    static readonly AutoResetEvent Wake = new AutoResetEvent(true);

    // What is currently applied: "tcp/80", "udp/53"
    static HashSet<string> applied = new HashSet<string>();
    static string appliedVmIp = "";
    static string appliedHostIps = "";
    static readonly Dictionary<int, UdpForwarder> udp = new Dictionary<int, UdpForwarder>();
    public static volatile string VmIp = "";

    static int Main(string[] args)
    {
        for (int i = 0; i < args.Length; i++)
        {
            if (args[i] == "--mode" && i + 1 < args.Length) mode = args[++i];
            else if (args[i] == "--state" && i + 1 < args.Length) stateDir = args[++i];
            else if (args[i] == "--wsl-ip-file" && i + 1 < args.Length) ipFile = args[++i];
            else if (args[i] == "--dry-run")
            {
                // Print what would be opened, change nothing
                try
                {
                    var d = Desired();
                    Console.WriteLine(d.Count == 0 ? "(no ports would be opened)" : string.Join(Environment.NewLine, d.OrderBy(x => x)));
                    return 0;
                }
                catch (Exception e) { Console.WriteLine("ERROR: " + e.Message); return 1; }
            }
        }
        if (stateDir == null) stateDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "wsl-docker-engine");
        Directory.CreateDirectory(stateDir);
        logPath = Path.Combine(stateDir, "port-sync.log");

        string lastError = null;
        bool isFirst;
        var mutex = new Mutex(true, @"Global\wsl-docker-engine-port-sync", out isFirst);
        if (!isFirst) return 0;

        LoadState();
        Log("Started in '" + mode + "' mode");

        new Thread(EventsLoop) { IsBackground = true }.Start();
        new Thread(() => { while (true) { Thread.Sleep(10000); if (InputsChanged()) Wake.Set(); } }) { IsBackground = true }.Start();

        while (true)
        {
            Wake.WaitOne(60000);    // event, input change, or periodic full sync
            Thread.Sleep(400);      // debounce bursts of events
            try { Sync(); lastError = null; }
            catch (Exception e)
            {
                // Docker restarting / distro stopped: log each different error once
                if (e.Message != lastError) Log("Sync failed (will retry): " + e.Message);
                lastError = e.Message;
            }
        }
    }

    // ---- Docker API over the named pipe ----------------------------------------

    static Stream OpenDocker(string path)
    {
        var pipe = new NamedPipeClientStream(".", "docker_engine", PipeDirection.InOut);
        pipe.Connect(5000);
        var req = Encoding.ASCII.GetBytes("GET " + path + " HTTP/1.1\r\nHost: docker\r\nConnection: close\r\n\r\n");
        pipe.Write(req, 0, req.Length);
        pipe.Flush();
        return pipe;
    }

    static string DockerGet(string path)
    {
        using (var s = OpenDocker(path))
        {
            var ms = new MemoryStream();
            var buf = new byte[65536];
            try { int n; while ((n = s.Read(buf, 0, buf.Length)) > 0) ms.Write(buf, 0, n); }
            catch (IOException) { } // pipe closed by the relay = end of response
            string raw = Encoding.UTF8.GetString(ms.ToArray());
            int split = raw.IndexOf("\r\n\r\n", StringComparison.Ordinal);
            if (split < 0) throw new Exception("invalid response from Docker");
            string head = raw.Substring(0, split), body = raw.Substring(split + 4);
            if (!head.StartsWith("HTTP/1.1 200") && !head.StartsWith("HTTP/1.0 200"))
                throw new Exception("Docker answered: " + head.Split('\r')[0]);
            if (head.IndexOf("Transfer-Encoding: chunked", StringComparison.OrdinalIgnoreCase) >= 0) body = Unchunk(body);
            return body;
        }
    }

    static string Unchunk(string body)
    {
        var sb = new StringBuilder();
        int pos = 0;
        while (pos < body.Length)
        {
            int eol = body.IndexOf("\r\n", pos, StringComparison.Ordinal);
            if (eol < 0) break;
            int size = Convert.ToInt32(body.Substring(pos, eol - pos).Split(';')[0].Trim(), 16);
            if (size == 0) break;
            sb.Append(body, eol + 2, Math.Min(size, body.Length - eol - 2));
            pos = eol + 2 + size + 2;
        }
        return sb.ToString();
    }

    // Any container event triggers a resync
    static void EventsLoop()
    {
        string filter = Uri.EscapeDataString("{\"type\":[\"container\"]}");
        while (true)
        {
            try
            {
                using (var s = OpenDocker("/events?filters=" + filter))
                {
                    Wake.Set();
                    var buf = new byte[8192];
                    while (s.Read(buf, 0, buf.Length) > 0) Wake.Set();
                }
            }
            catch { }
            Thread.Sleep(5000); // Docker not reachable yet (distro stopped, relay starting...)
        }
    }

    // ---- Desired state ------------------------------------------------------------

    static HashSet<string> Desired()
    {
        var result = new HashSet<string>();
        var json = new JavaScriptSerializer { MaxJsonLength = int.MaxValue };
        var containers = json.DeserializeObject(DockerGet("/containers/json")) as object[];
        if (containers == null) return result;
        foreach (Dictionary<string, object> c in containers)
        {
            object portsObj;
            if (!c.TryGetValue("Ports", out portsObj) || !(portsObj is object[])) continue;
            foreach (Dictionary<string, object> p in (object[])portsObj)
            {
                if (!p.ContainsKey("PublicPort")) continue;
                string ip = p.ContainsKey("IP") ? Convert.ToString(p["IP"]) : "";
                if (ip == "127.0.0.1" || ip == "::1" || ip.StartsWith("127.")) continue;   // local only
                string proto = Convert.ToString(p["Type"]).ToLowerInvariant();
                if (proto != "tcp" && proto != "udp") continue;
                result.Add(proto + "/" + Convert.ToInt32(p["PublicPort"]));
            }
        }
        return result;
    }

    static string ReadVmIp()
    {
        try { return ipFile != null && File.Exists(ipFile) ? File.ReadAllText(ipFile).Trim() : ""; } catch { return ""; }
    }

    static string HostIps()
    {
        var ips = new List<string>();
        foreach (var ni in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (ni.OperationalStatus != OperationalStatus.Up) continue;
            if (ni.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
            if (ni.Name.IndexOf("WSL", StringComparison.OrdinalIgnoreCase) >= 0) continue;
            foreach (var a in ni.GetIPProperties().UnicastAddresses)
                if (a.Address.AddressFamily == AddressFamily.InterNetwork && !a.Address.ToString().StartsWith("169.254."))
                    ips.Add(a.Address.ToString());
        }
        ips.Sort();
        return string.Join(",", ips);
    }

    static bool InputsChanged()
    {
        if (mode != "portproxy") return false;
        return ReadVmIp() != appliedVmIp || HostIps() != appliedHostIps;
    }

    // ---- Apply --------------------------------------------------------------------

    static void Sync()
    {
        lock (SyncLock)
        {
            HashSet<string> desired = Desired();   // throws if Docker is not reachable: keep current rules
            string vmIp = ReadVmIp();
            string hostIps = HostIps();
            VmIp = vmIp;

            bool redoTcp = mode == "portproxy" && (vmIp != appliedVmIp || hostIps != appliedHostIps);
            var remove = applied.Where(k => !desired.Contains(k) || (redoTcp && k.StartsWith("tcp/"))).ToList();
            var add = desired.Where(k => !applied.Contains(k) || (redoTcp && k.StartsWith("tcp/"))).ToList();
            if (mode == "portproxy" && vmIp == "" && add.Count > 0)
            {
                Log("Waiting for the WSL IP before forwarding ports");
                add.Clear();
            }
            if (remove.Count == 0 && add.Count == 0) return;

            var script = new StringBuilder();
            script.AppendLine("$ErrorActionPreference = 'Continue'");
            script.AppendLine("$hv = [bool](Get-Command New-NetFirewallHyperVRule -ErrorAction SilentlyContinue)");
            foreach (var k in remove) script.Append(RemoveScript(k, appliedHostIps));
            foreach (var k in add) script.Append(AddScript(k, vmIp, hostIps));
            string output = RunPowerShell(script.ToString());
            if (output.Trim().Length > 0) Log(output.Trim());

            foreach (var k in remove) { applied.Remove(k); StopUdp(k); }
            foreach (var k in add) { applied.Add(k); StartUdp(k); }
            appliedVmIp = vmIp;
            appliedHostIps = hostIps;
            SaveState();
            Log("Synced. Open: " + (applied.Count == 0 ? "(none)" : string.Join(", ", applied.OrderBy(x => x))) +
                (remove.Count > 0 ? " | closed: " + string.Join(", ", remove) : ""));
        }
    }

    static string RuleName(string key) { return RulePrefix + "-" + key.Replace('/', '-'); }

    static string AddScript(string key, string vmIp, string hostIps)
    {
        string proto = key.Split('/')[0].ToUpperInvariant(), port = key.Split('/')[1], name = RuleName(key);
        var sb = new StringBuilder();
        sb.AppendLine("if ($hv) { Remove-NetFirewallHyperVRule -Name '" + name + "' -ErrorAction SilentlyContinue; " +
                      "New-NetFirewallHyperVRule -Name '" + name + "' -DisplayName '" + name + "' -Direction Inbound " +
                      "-VMCreatorId '" + WslVmCreatorId + "' -Protocol " + proto + " -LocalPorts " + port + " -Action Allow | Out-Null }");
        if (mode == "portproxy")
        {
            sb.AppendLine("Remove-NetFirewallRule -Name '" + name + "' -ErrorAction SilentlyContinue; " +
                          "New-NetFirewallRule -Name '" + name + "' -DisplayName '" + name + "' -Direction Inbound " +
                          "-Protocol " + proto + " -LocalPort " + port + " -Action Allow -Profile Any | Out-Null");
            if (proto == "TCP")
                foreach (var ip in hostIps.Split(new[] { ',' }, StringSplitOptions.RemoveEmptyEntries))
                    sb.AppendLine("netsh interface portproxy add v4tov4 listenaddress=" + ip + " listenport=" + port +
                                  " connectaddress=" + vmIp + " connectport=" + port + " | Out-Null");
        }
        return sb.ToString();
    }

    static string RemoveScript(string key, string hostIps)
    {
        string proto = key.Split('/')[0], port = key.Split('/')[1], name = RuleName(key);
        var sb = new StringBuilder();
        sb.AppendLine("if ($hv) { Remove-NetFirewallHyperVRule -Name '" + name + "' -ErrorAction SilentlyContinue }");
        sb.AppendLine("Remove-NetFirewallRule -Name '" + name + "' -ErrorAction SilentlyContinue");
        if (proto == "tcp")
            foreach (var ip in hostIps.Split(new[] { ',' }, StringSplitOptions.RemoveEmptyEntries))
                sb.AppendLine("netsh interface portproxy delete v4tov4 listenaddress=" + ip + " listenport=" + port + " | Out-Null");
        return sb.ToString();
    }

    static string RunPowerShell(string script)
    {
        var psi = new ProcessStartInfo("powershell.exe", "-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command -")
        {
            UseShellExecute = false,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true
        };
        using (var p = Process.Start(psi))
        {
            var err = new StringBuilder();
            p.ErrorDataReceived += (s, e) => { if (e.Data != null) err.AppendLine(e.Data); };
            p.BeginErrorReadLine();
            p.StandardInput.Write(script);
            p.StandardInput.Close();
            string output = p.StandardOutput.ReadToEnd();
            p.WaitForExit(120000);
            return output + err;
        }
    }

    // ---- UDP forwarding (portproxy mode only) --------------------------------------

    static void StartUdp(string key)
    {
        if (mode != "portproxy" || !key.StartsWith("udp/")) return;
        int port = int.Parse(key.Substring(4));
        if (udp.ContainsKey(port)) return;
        try { udp[port] = new UdpForwarder(port); }
        catch (Exception e) { Log("UDP " + port + ": " + e.Message); }
    }

    static void StopUdp(string key)
    {
        if (!key.StartsWith("udp/")) return;
        int port = int.Parse(key.Substring(4));
        UdpForwarder f;
        if (udp.TryGetValue(port, out f)) { f.Stop(); udp.Remove(port); }
    }

    // ---- State / log ----------------------------------------------------------------

    static void LoadState()
    {
        string f = Path.Combine(stateDir, "applied.txt");
        if (!File.Exists(f)) return;
        foreach (var line in File.ReadAllLines(f))
        {
            if (line.StartsWith("vmip=")) appliedVmIp = line.Substring(5);
            else if (line.StartsWith("hostips=")) appliedHostIps = line.Substring(8);
            else if (line.Contains("/")) applied.Add(line.Trim());
        }
        // UDP forwarders live in this process: start them again
        foreach (var k in applied.ToList()) StartUdp(k);
    }

    static void SaveState()
    {
        var lines = new List<string> { "vmip=" + appliedVmIp, "hostips=" + appliedHostIps };
        lines.AddRange(applied.OrderBy(x => x));
        File.WriteAllLines(Path.Combine(stateDir, "applied.txt"), lines);
    }

    public static void Log(string msg)
    {
        try
        {
            if (File.Exists(logPath) && new FileInfo(logPath).Length > 1024 * 1024) File.Delete(logPath);
            File.AppendAllText(logPath, DateTime.Now.ToString("s") + " " + msg + Environment.NewLine);
        }
        catch { }
    }
}

// Forwards UDP datagrams from 0.0.0.0:<port> on Windows to <WSL IP>:<port>
class UdpForwarder
{
    readonly int port;
    readonly UdpClient listener;
    readonly Dictionary<string, Session> sessions = new Dictionary<string, Session>();
    volatile bool stopped;

    class Session { public UdpClient Upstream; public DateTime LastSeen; }

    public UdpForwarder(int port)
    {
        this.port = port;
        listener = new UdpClient(new IPEndPoint(IPAddress.Any, port));
        new Thread(ReceiveLoop) { IsBackground = true }.Start();
        new Thread(CleanupLoop) { IsBackground = true }.Start();
    }

    void ReceiveLoop()
    {
        while (!stopped)
        {
            try
            {
                var client = new IPEndPoint(IPAddress.Any, 0);
                byte[] data = listener.Receive(ref client);
                string vm = DockerPortSync.VmIp;
                if (vm == "") continue;
                Session s;
                lock (sessions)
                {
                    if (!sessions.TryGetValue(client.ToString(), out s))
                    {
                        s = new Session { Upstream = new UdpClient() };
                        s.Upstream.Connect(IPAddress.Parse(vm), port);
                        sessions[client.ToString()] = s;
                        var c = client; var up = s;
                        new Thread(() => ReplyLoop(c, up)) { IsBackground = true }.Start();
                    }
                    s.LastSeen = DateTime.UtcNow;
                }
                s.Upstream.Send(data, data.Length);
            }
            catch (Exception e) { if (!stopped && !(e is SocketException)) DockerPortSync.Log("UDP " + port + ": " + e.Message); }
        }
    }

    void ReplyLoop(IPEndPoint client, Session s)
    {
        while (!stopped)
        {
            try
            {
                var from = new IPEndPoint(IPAddress.Any, 0);
                byte[] data = s.Upstream.Receive(ref from);
                s.LastSeen = DateTime.UtcNow;
                listener.Send(data, data.Length, client);
            }
            catch { return; } // session closed
        }
    }

    void CleanupLoop()
    {
        while (!stopped)
        {
            Thread.Sleep(30000);
            lock (sessions)
            {
                foreach (var key in sessions.Keys.ToList())
                    if ((DateTime.UtcNow - sessions[key].LastSeen).TotalSeconds > 120)
                    {
                        try { sessions[key].Upstream.Close(); } catch { }
                        sessions.Remove(key);
                    }
            }
        }
    }

    public void Stop()
    {
        stopped = true;
        try { listener.Close(); } catch { }
        lock (sessions)
        {
            foreach (var s in sessions.Values) { try { s.Upstream.Close(); } catch { } }
            sessions.Clear();
        }
    }
}
