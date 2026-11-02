// docker-pipe-relay
//
// Exposes the Docker Engine running inside a WSL distro on \\.\pipe\docker_engine,
// the same endpoint Docker Desktop uses, so the Windows docker.exe works with no
// DOCKER_HOST and no TCP port.
//
// Usage: docker-pipe-relay.exe [--distro <name>] [--config <config.json>]
//                              [--wsl-ip-file <path>] [--log <path>] [--no-keepalive]
//
// Security
//  - Only the current Windows user, members of the local "docker-users" group and
//    SYSTEM (used by the port sync service) can connect; remote clients are rejected.
//  - If another program already owns \\.\pipe\docker_engine, the relay refuses to start
//    (prevents something else from impersonating Docker).
//
// Speed
//  - Starting wsl.exe takes ~600 ms, so a few connections are kept pre-opened.
//
// Keep-alive and idle sleep
//  - A "sleep infinity" process keeps the distro (and Docker) running.
//  - Idle sleep (config "idleSleepMinutes" > 0): when no container has been running and
//    no client has used Docker for that long, the relay lets go of the distro, so WSL
//    stops the Linux VM and its memory goes back to Windows. The next docker command
//    starts it again (a few seconds), with a Windows notification if "notify" is true.
//  - The port sync service never wakes the distro: its connections are refused while
//    the distro is stopped.
//
// Ports on a specific IP
//  - Without mirrored networking, "192.168.1.20:80:80" cannot work (that IP does not exist
//    inside Linux) and Docker fails with "cannot assign requested address". The relay adds
//    one line to that error explaining how to fix it; if it cannot do it safely, it shows
//    a Windows notification instead. Every other response passes through untouched.
//
// Other warnings
//  - "address already in use" because a Windows program uses that port: the error gets
//    one more line naming the program.
//  - WSL started without network (mirrored networking can fail, e.g. with some VPNs):
//    the relay restarts WSL once by itself when nothing is running, otherwise it warns.
//  - "network ... does not exist / not found": Docker lost a network's setup; the error
//    says how to recreate the containers.
//  - "invalid mode": usually a Windows path in "docker run -v C:\\..."; the error shows
//    the /c/... form.
//  - Less than 2 GB free on the drive that holds Docker's disk: a notification (once a day).
//  - Once a day: new lindowin / Docker CLI versions, and unused space in Docker's disk
//    worth giving back ("lindowin compact"). A notification once per finding.
//  - Another program owns \\.\pipe\docker_engine (Docker Desktop...): it says which one.
//  - The state is kept in relay-status.txt next to the log, for "lindowin status".
//
// WSL IP
//  - With --wsl-ip-file and config "networkMode": "portproxy", the distro's internal IP
//    is written to that file while it runs (the port sync service needs it).

using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Management;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using Microsoft.Win32.SafeHandles;

class DockerPipeRelay
{
    const string PipeName = "docker_engine";
    const int PoolSize = 3;     // "docker run" opens several connections at once

    static string distro = "docker";
    static string wslArgs;
    static string logPath;
    static string configPath;

    static readonly object PoolLock = new object();
    static readonly Queue<Process> Pool = new Queue<Process>();
    static int refilling = 0;

    // Settings (re-read from config.json while running)
    static int idleSleepMinutes = 0;
    static bool notify = false;
    static string networkMode = "";
    static string portHint = null;    // extra line for "cannot assign requested address", null in mirrored mode

    // Idle tracking
    static readonly object StateLock = new object();
    static int clientConnections = 0;                 // open connections from real Docker clients
    static DateTime lastActivity = DateTime.UtcNow;
    static bool sleeping = false;
    static bool keepAliveWanted = true;
    static Process keepAlive;
    static readonly List<Process> BackgroundWsl = new List<Process>();   // port sync connections

    static int Main(string[] args)
    {
        string ipFile = null;
        for (int i = 0; i < args.Length; i++)
        {
            if (args[i] == "--distro" && i + 1 < args.Length) distro = args[++i];
            else if (args[i] == "--no-keepalive") keepAliveWanted = false;
            else if (args[i] == "--wsl-ip-file" && i + 1 < args.Length) ipFile = args[++i];
            else if (args[i] == "--config" && i + 1 < args.Length) configPath = args[++i];
            else if (args[i] == "--log" && i + 1 < args.Length) logPath = args[++i];
        }
        wslArgs = "-d " + distro + " -u root -- socat -t 5 - UNIX-CONNECT:/var/run/docker.sock";

        bool isFirst;
        var mutex = new Mutex(true, @"Local\docker-pipe-relay", out isFirst);
        if (!isFirst) return 0;

        if (logPath == null) logPath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "docker-pipe-relay.log");
        LoadConfig();

        var security = new PipeSecurity();
        security.AddAccessRule(new PipeAccessRule(
            new SecurityIdentifier(WellKnownSidType.NetworkSid, null),
            PipeAccessRights.FullControl, AccessControlType.Deny));
        security.AddAccessRule(new PipeAccessRule(
            WindowsIdentity.GetCurrent().User, PipeAccessRights.FullControl, AccessControlType.Allow));
        security.AddAccessRule(new PipeAccessRule(
            new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null),
            PipeAccessRights.ReadWrite, AccessControlType.Allow));
        try
        {
            var group = (SecurityIdentifier)new NTAccount("docker-users").Translate(typeof(SecurityIdentifier));
            security.AddAccessRule(new PipeAccessRule(group, PipeAccessRights.ReadWrite, AccessControlType.Allow));
        }
        catch { } // group does not exist: only the current user and SYSTEM

        bool first = true;
        while (true)
        {
            NamedPipeServerStream pipe;
            try
            {
                pipe = CreatePipe(security, first);
            }
            catch (Exception e)
            {
                if (first)
                {
                    LoadStatus();
                    string owner = PipeOwnerName();
                    Log("Another program already owns \\\\.\\pipe\\docker_engine (" + owner + "). Relay not started. " + e.Message);
                    SetStatus("pipe_owner", owner);
                    DateTime last;
                    bool recent = DateTime.TryParse(GetStatus("pipe_notified"), out last) && (DateTime.Now - last).TotalMinutes < 30;
                    if (notify && !recent)
                    {
                        SetStatus("pipe_notified", DateTime.Now.ToString("s"));
                        ShowNotification("lindowin could not start", owner + " is using the Docker pipe. Quit it, then run: lindowin start");
                        Thread.Sleep(3000);   // let the notification process start before exiting
                    }
                    return 1;
                }
                Log("Could not create pipe instance: " + e.Message);
                Thread.Sleep(1000);
                continue;
            }
            if (first)
            {
                first = false;
                KillStrayWsl();
                LoadStatus();
                SetStatus("pipe_owner", "");
                StartKeepAlive();
                RefillAsync();
                if (ipFile != null) StartIpWriter(ipFile);
                StartIdleMonitor();
                StartDailyChecks();
            }

            try
            {
                pipe.WaitForConnection();
            }
            catch (IOException e)
            {
                // ERROR_PIPE_CONNECTED (535): a client connected before we started waiting.
                // Anything else, e.g. a client that connected and left while the relay was
                // starting up ("the pipe is being closed"): drop this instance, keep serving.
                if ((e.HResult & 0xFFFF) != 535)
                {
                    try { pipe.Dispose(); } catch { }
                    continue;
                }
            }
            new Thread(() => Handle(pipe)) { IsBackground = true }.Start();
        }
    }

    // ---- Settings -------------------------------------------------------------------

    static void LoadConfig()
    {
        if (configPath == null || !File.Exists(configPath)) return;
        try
        {
            string json = File.ReadAllText(configPath);
            Match m = Regex.Match(json, "\"idleSleepMinutes\"\\s*:\\s*(\\d+)");
            idleSleepMinutes = m.Success ? int.Parse(m.Groups[1].Value) : 0;
            notify = Regex.IsMatch(json, "\"notify\"\\s*:\\s*true");
            m = Regex.Match(json, "\"networkMode\"\\s*:\\s*\"(\\w+)\"");
            networkMode = m.Success ? m.Groups[1].Value : "";
            m = Regex.Match(json, "\"networkChoice\"\\s*:\\s*\"(\\w+)\"");
            string choice = m.Success ? m.Groups[1].Value : "auto";
            bool mirroredFailed = Regex.IsMatch(json, "\"mirroredFailed\"\\s*:\\s*true");
            bool mirroredSupported = !Regex.IsMatch(json, "\"mirroredSupported\"\\s*:\\s*false");
            portHint = PortHint(choice, mirroredFailed, mirroredSupported);
        }
        catch (Exception e) { Log("Could not read settings: " + e.Message); }
    }

    static string PortHint(string choice, bool mirroredFailed, bool mirroredSupported)
    {
        if (networkMode == "mirrored" || networkMode == "") return null;
        if (!mirroredSupported)
            return "lindowin: this Windows version cannot publish ports on a specific IP. Use \"80:80\" and limit who can connect with the Windows firewall.";
        if (choice == "auto" && mirroredFailed)
            return "lindowin: ports on a specific IP need mirrored networking. It was turned off because it broke WSL's internet on this PC (often a VPN). To try it again: lindowin config network mirrored";
        return "lindowin: ports on a specific IP need mirrored networking. Run: lindowin config network mirrored";
    }

    // ---- Named pipe -------------------------------------------------------------------

    [StructLayout(LayoutKind.Sequential)]
    struct SECURITY_ATTRIBUTES { public int nLength; public IntPtr lpSecurityDescriptor; public int bInheritHandle; }

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern SafePipeHandle CreateNamedPipe(string name, uint openMode, uint pipeMode,
        uint maxInstances, uint outBuffer, uint inBuffer, uint timeout, ref SECURITY_ATTRIBUTES sa);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetNamedPipeClientProcessId(SafePipeHandle pipe, out uint clientProcessId);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetNamedPipeServerProcessId(SafePipeHandle pipe, out uint serverProcessId);

    // Friendly name of the program that owns \\.\pipe\docker_engine
    static string PipeOwnerName()
    {
        try
        {
            using (var c = new NamedPipeClientStream(".", PipeName, PipeDirection.InOut))
            {
                c.Connect(2000);
                uint pid;
                if (GetNamedPipeServerProcessId(c.SafePipeHandle, out pid))
                {
                    using (var p = Process.GetProcessById((int)pid))
                    {
                        string n = p.ProcessName.ToLowerInvariant();
                        if (n.StartsWith("com.docker") || n.StartsWith("docker desktop")) return "Docker Desktop";
                        if (n.Contains("podman")) return "Podman";
                        if (n.Contains("rancher")) return "Rancher Desktop";
                        return p.ProcessName;
                    }
                }
            }
        }
        catch { }
        return "Another program (Docker Desktop, Podman, Rancher Desktop...)";
    }

    const uint PIPE_ACCESS_DUPLEX = 0x3, FILE_FLAG_OVERLAPPED = 0x40000000, FILE_FLAG_FIRST_PIPE_INSTANCE = 0x80000;
    const uint PIPE_TYPE_MESSAGE = 0x4, PIPE_READMODE_MESSAGE = 0x2, PIPE_REJECT_REMOTE_CLIENTS = 0x8;

    // Message mode (like Docker Desktop): the client signals "end of input" with an
    // empty message, which closes socat's stdin (needed for "docker run -i").
    // The first instance uses FIRST_PIPE_INSTANCE: it fails if someone else owns the name.
    static NamedPipeServerStream CreatePipe(PipeSecurity security, bool first)
    {
        byte[] sd = security.GetSecurityDescriptorBinaryForm();
        GCHandle h = GCHandle.Alloc(sd, GCHandleType.Pinned);
        try
        {
            var sa = new SECURITY_ATTRIBUTES
            {
                nLength = Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES)),
                lpSecurityDescriptor = h.AddrOfPinnedObject(),
                bInheritHandle = 0
            };
            uint openMode = PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED | (first ? FILE_FLAG_FIRST_PIPE_INSTANCE : 0);
            uint pipeMode = PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_REJECT_REMOTE_CLIENTS;
            SafePipeHandle handle = CreateNamedPipe(@"\\.\pipe\" + PipeName, openMode, pipeMode,
                255, 65536, 65536, 0, ref sa);
            if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
            return new NamedPipeServerStream(PipeDirection.InOut, true, false, handle);
        }
        finally { h.Free(); }
    }

    // The port sync service (runs as SYSTEM) is a background client: it must never keep
    // the distro awake or wake it up.
    static string ClientName(NamedPipeServerStream pipe)
    {
        try
        {
            uint pid;
            if (!GetNamedPipeClientProcessId(pipe.SafePipeHandle, out pid)) return "";
            using (var p = Process.GetProcessById((int)pid)) return p.ProcessName;
        }
        catch { return ""; }
    }

    static string lastClient = "";
    static DateTime lastClientLog = DateTime.MinValue;

    // ---- WSL processes --------------------------------------------------------------

    static Process StartHidden(string arguments, bool redirect)
    {
        var p = Process.Start(new ProcessStartInfo("wsl.exe", arguments)
        {
            UseShellExecute = false,
            RedirectStandardInput = redirect,
            RedirectStandardOutput = redirect,
            RedirectStandardError = redirect,
            CreateNoWindow = true
        });
        if (redirect)
        {
            p.ErrorDataReceived += (s, e) => { };
            p.BeginErrorReadLine();
        }
        return p;
    }

    static string RunWsl(string arguments)
    {
        var psi = new ProcessStartInfo("wsl.exe", arguments)
        {
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true
        };
        psi.EnvironmentVariables["WSL_UTF8"] = "1";
        using (var p = Process.Start(psi))
        {
            p.ErrorDataReceived += (s, e) => { };
            p.BeginErrorReadLine();
            string output = p.StandardOutput.ReadToEnd();
            p.WaitForExit(15000);
            return output.Replace("\0", "");
        }
    }

    // Does not start the distro
    static bool DistroRunning()
    {
        try
        {
            foreach (var line in RunWsl("--list --running --quiet").Split('\n'))
                if (line.Trim() == distro) return true;
        }
        catch { }
        return false;
    }

    static void StartKeepAlive()
    {
        if (!keepAliveWanted) return;
        lock (StateLock)
        {
            if (keepAlive != null && !keepAlive.HasExited) return;
            try { keepAlive = StartHidden("-d " + distro + " -u root -- sleep infinity", false); ScheduleNetworkCheck(); }
            catch (Exception e) { Log("Could not start keep-alive: " + e.Message); }
        }
    }

    static Process TakeWsl()
    {
        lock (PoolLock)
        {
            while (Pool.Count > 0)
            {
                var p = Pool.Dequeue();
                if (!p.HasExited) return p;
                p.Dispose();
            }
        }
        return StartHidden(wslArgs, true);
    }

    // Refills the pool in the background (one refill task at a time). Never while sleeping.
    static void RefillAsync()
    {
        if (sleeping) return;
        if (Interlocked.Exchange(ref refilling, 1) == 1) return;
        new Thread(() =>
        {
            try
            {
                while (!sleeping)
                {
                    lock (PoolLock)
                    {
                        int n = Pool.Count;
                        for (int i = 0; i < n; i++)
                        {
                            var p = Pool.Dequeue();
                            if (p.HasExited) p.Dispose(); else Pool.Enqueue(p);
                        }
                        if (Pool.Count >= PoolSize) break;
                    }
                    var fresh = StartHidden(wslArgs, true);
                    if (sleeping) { try { fresh.Kill(); } catch { } break; }   // went to sleep meanwhile
                    lock (PoolLock) Pool.Enqueue(fresh);
                }
            }
            catch (Exception e) { Log("Could not pre-open connections: " + e.Message); }
            finally { Interlocked.Exchange(ref refilling, 0); }
        }) { IsBackground = true }.Start();
    }

    // ---- Connections ----------------------------------------------------------------

    static void Handle(NamedPipeServerStream pipe)
    {
        string client = ClientName(pipe);
        bool background = string.Equals(client, "docker-port-sync", StringComparison.OrdinalIgnoreCase);
        Process wsl = null;
        try
        {
            if (background)
            {
                // The port sync service only reads Docker's state: do not wake a stopped distro for it
                if (sleeping || !DistroRunning()) return;
            }
            else
            {
                lock (StateLock) { clientConnections++; lastActivity = DateTime.UtcNow; lastClient = client; }
                if (sleeping) Wake();
                else StartKeepAlive();   // e.g. after "wsl --terminate": a docker command starts it again
            }

            wsl = TakeWsl();
            if (background) lock (StateLock) BackgroundWsl.Add(wsl);
            RefillAsync();

            Stream toDocker = wsl.StandardInput.BaseStream;
            Stream fromDocker = wsl.StandardOutput.BaseStream;

            // Client -> Docker. When the client finishes sending, close socat's stdin.
            new Thread(() =>
            {
                try { Pump(pipe, toDocker); } catch { }
                try { toDocker.Close(); } catch { }
            }) { IsBackground = true }.Start();

            // Docker -> client.
            try { PumpResponses(fromDocker, pipe); } catch { }
        }
        catch (Exception e) { Log("Connection error: " + e.Message); }
        finally
        {
            if (!background) lock (StateLock) { clientConnections--; lastActivity = DateTime.UtcNow; }
            if (background && wsl != null) lock (StateLock) BackgroundWsl.Remove(wsl);
            // Close without Disconnect(): the client then sees end-of-stream, not an error.
            try { if (pipe.IsConnected) pipe.WaitForPipeDrain(); } catch { }
            try { pipe.Dispose(); } catch { }
            try { if (wsl != null && !wsl.HasExited) wsl.Kill(); } catch { }
            try { if (wsl != null) wsl.Dispose(); } catch { }
        }
    }

    static readonly byte[] BindError = Encoding.ASCII.GetBytes("cannot assign requested address");
    static readonly byte[] InUseError = Encoding.ASCII.GetBytes("address already in use");
    static readonly byte[] NetworkError = Encoding.ASCII.GetBytes("container networking: ");
    static readonly byte[] ModeError = Encoding.ASCII.GetBytes("invalid mode: ");

    const string WindowsPathHint =
        "lindowin: if you used a Windows path, write it as /c/Users/you/folder instead of C:\\Users\\you\\folder " +
        "(for example -v /c/Users/you/project:/app). docker compose converts it for you.";

    // "failed to create endpoint x on network y: network 1a2b... does not exist" (or "not found")
    static string NetworkLostHint(string text)
    {
        if (!Regex.IsMatch(text, "network [0-9a-f]{12,64} (does not exist|not found)")) return null;
        return "lindowin: Docker lost this network's setup. If it is a compose project, recreate its containers " +
               "(volumes and folders are kept): docker compose up -d --force-recreate";
    }

    // "listen tcp4 0.0.0.0:5432: bind: address already in use": which Windows program has it?
    static string PortInUseHint(string text)
    {
        try
        {
            // Docker 29: "failed to bind host port 0.0.0.0:5480/tcp: address already in use"
            // older:     "listen tcp4 0.0.0.0:5480: bind: address already in use"
            string proto, port;
            Match m = Regex.Match(text, "bind host port \\S*:(\\d+)/(tcp|udp): address already in use", RegexOptions.IgnoreCase);
            if (m.Success) { port = m.Groups[1].Value; proto = m.Groups[2].Value.ToUpperInvariant(); }
            else
            {
                m = Regex.Match(text, "listen (tcp|udp)\\d?\\s+\\S*:(\\d+): bind: address already in use", RegexOptions.IgnoreCase);
                if (!m.Success) return null;
                proto = m.Groups[1].Value.ToUpperInvariant();
                port = m.Groups[2].Value;
            }
            var psi = new ProcessStartInfo("netstat.exe", "-ano -p " + proto)
            {
                UseShellExecute = false, RedirectStandardOutput = true, CreateNoWindow = true
            };
            string table;
            using (var p = Process.Start(psi)) { table = p.StandardOutput.ReadToEnd(); p.WaitForExit(5000); }
            foreach (string line in table.Split('\n'))
            {
                string[] f = line.Trim().Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries);
                // TCP  0.0.0.0:5432  0.0.0.0:0  LISTENING  4120      UDP  0.0.0.0:5353  *:*  1234
                if (f.Length < 4 || !f[0].Equals(proto, StringComparison.OrdinalIgnoreCase)) continue;
                if (!f[1].EndsWith(":" + port)) continue;
                if (proto == "TCP" && (f.Length < 5 || f[3] != "LISTENING")) continue;
                int pid;
                if (!int.TryParse(f[f.Length - 1], out pid) || pid <= 4) continue;
                string name = "PID " + pid;
                try { using (var proc = Process.GetProcessById(pid)) name = proc.ProcessName + ".exe (PID " + pid + ")"; } catch { }
                return "lindowin: port " + port + " is already used on Windows by " + name +
                       ". Stop that program, or publish a different host port.";
            }
        }
        catch { }
        return null;   // not a Windows program: Docker's own message is enough
    }
    static readonly Dictionary<string, DateTime> lastPortWarning = new Dictionary<string, DateTime>();

    // Docker -> client. Same as Pump, except for the "specific IP" error (see header).
    static void PumpResponses(Stream from, Stream to)
    {
        var buffer = new byte[65536];
        int n;
        while ((n = from.Read(buffer, 0, buffer.Length)) > 0)
        {
            byte[] outBuf = buffer;
            int outLen = n;
            string hint = null;
            if (portHint != null && IndexOf(buffer, n, BindError) >= 0) hint = portHint;
            else if (IndexOf(buffer, n, InUseError) >= 0) hint = PortInUseHint(Encoding.UTF8.GetString(buffer, 0, n));
            else if (IndexOf(buffer, n, NetworkError) >= 0) hint = NetworkLostHint(Encoding.UTF8.GetString(buffer, 0, n));
            else if (IndexOf(buffer, n, ModeError) >= 0) hint = WindowsPathHint;
            if (hint != null)
            {
                byte[] changed = AddHintToError(buffer, n, hint);
                if (changed != null) { outBuf = changed; outLen = changed.Length; }
                PortWarning(hint, changed == null);
            }
            to.Write(outBuf, 0, outLen);
            to.Flush();
        }
    }

    static int IndexOf(byte[] data, int length, byte[] pattern)
    {
        for (int i = 0; i + pattern.Length <= length; i++)
        {
            int j = 0;
            while (j < pattern.Length && data[i + j] == pattern[j]) j++;
            if (j == pattern.Length) return i;
        }
        return -1;
    }

    // Rewrites one complete JSON error response ({"message":"..."}) sent with Content-Length.
    // Returns null when the data is not exactly that (then nothing is changed).
    static byte[] AddHintToError(byte[] data, int length, string hint)
    {
        try
        {
            string text = Encoding.UTF8.GetString(data, 0, length);
            if (!text.StartsWith("HTTP/1.")) return null;
            int headerEnd = text.IndexOf("\r\n\r\n", StringComparison.Ordinal);
            if (headerEnd < 0) return null;
            string head = text.Substring(0, headerEnd);
            if (Regex.IsMatch(head, "Transfer-Encoding", RegexOptions.IgnoreCase)) return null;
            Match cl = Regex.Match(head, "\r\nContent-Length:\\s*(\\d+)", RegexOptions.IgnoreCase);
            if (!cl.Success) return null;
            int bodyLen = int.Parse(cl.Groups[1].Value);
            int headBytes = Encoding.UTF8.GetByteCount(text.Substring(0, headerEnd + 4));
            if (length - headBytes < bodyLen) return null;          // body not complete in this read

            string body = Encoding.UTF8.GetString(data, headBytes, bodyLen);
            int msg = body.IndexOf("\"message\":\"", StringComparison.Ordinal);
            int end = body.LastIndexOf("\"}", StringComparison.Ordinal);
            if (msg < 0 || end < msg) return null;
            string escaped = hint.Replace("\\", "\\\\").Replace("\"", "\\\"");
            string newBody = body.Insert(end, "\\n" + escaped);
            string newHead = head.Substring(0, cl.Index) + "\r\nContent-Length: " + Encoding.UTF8.GetByteCount(newBody) +
                             head.Substring(cl.Index + cl.Length);

            var output = new MemoryStream();
            byte[] part = Encoding.UTF8.GetBytes(newHead + "\r\n\r\n" + newBody);
            output.Write(part, 0, part.Length);
            int rest = headBytes + bodyLen;
            output.Write(data, rest, length - rest);                // anything after it, unchanged
            return output.ToArray();
        }
        catch { return null; }
    }

    static void PortWarning(string hint, bool notifyToo)
    {
        // At most once a minute for the same message (a compose file can hit it several times)
        lock (lastPortWarning)
        {
            DateTime last;
            if (lastPortWarning.TryGetValue(hint, out last) && (DateTime.UtcNow - last).TotalSeconds < 60) return;
            lastPortWarning[hint] = DateTime.UtcNow;
        }
        Log("Port warning: " + hint);
        if (notifyToo && notify) ShowNotification("Docker reported a problem", hint.Replace("lindowin: ", ""));
    }

    static void Pump(Stream from, Stream to)
    {
        var buffer = new byte[65536];
        int n;
        while ((n = from.Read(buffer, 0, buffer.Length)) > 0)
        {
            to.Write(buffer, 0, n);
            to.Flush();
        }
    }

    // ---- Idle sleep -----------------------------------------------------------------

    static void StartIdleMonitor()
    {
        new Thread(() =>
        {
            while (true)
            {
                Thread.Sleep(30000);
                try
                {
                    LoadConfig();
                    if (idleSleepMinutes <= 0 || sleeping) continue;
                    if (!DistroRunning())
                    {
                        // Stopped from outside (e.g. "wsl --terminate"): just remember it
                        lock (StateLock) { if (clientConnections == 0) sleeping = true; }
                        continue;
                    }
                    lock (StateLock)
                    {
                        if (clientConnections > 0) continue;
                        if ((DateTime.UtcNow - lastActivity).TotalMinutes < idleSleepMinutes)
                        {
                            // Once every 10 minutes at most: who keeps Docker busy (e.g. an editor polling it)
                            if ((DateTime.UtcNow - lastClientLog).TotalMinutes >= 10 && lastClient != "" &&
                                (DateTime.UtcNow - lastActivity).TotalMinutes < 1)
                            {
                                Log("Idle sleep waits: Docker was used recently by '" + lastClient + "'.");
                                lastClientLog = DateTime.UtcNow;
                            }
                            continue;
                        }
                    }
                    int running = RunningContainers();
                    if (running != 0)
                    {
                        // Containers running (or Docker not answering): stay awake, check again later
                        if (running < 0 && (DateTime.UtcNow - lastClientLog).TotalMinutes >= 10)
                        {
                            Log("Idle sleep waits: could not ask Docker for running containers.");
                            lastClientLog = DateTime.UtcNow;
                        }
                        lock (StateLock) lastActivity = DateTime.UtcNow;
                        continue;
                    }
                    GoToSleep();
                }
                catch (Exception e) { Log("Idle check failed: " + e.Message); }
            }
        }) { IsBackground = true }.Start();
    }

    // Number of running containers, or -1 if Docker did not answer
    static int RunningContainers()
    {
        Process wsl = null;
        try
        {
            wsl = TakeWsl();
            byte[] req = Encoding.ASCII.GetBytes("GET /containers/json HTTP/1.0\r\nHost: docker\r\n\r\n");
            wsl.StandardInput.BaseStream.Write(req, 0, req.Length);
            wsl.StandardInput.BaseStream.Flush();
            wsl.StandardInput.Close();
            string raw = wsl.StandardOutput.ReadToEnd();
            int split = raw.IndexOf("\r\n\r\n", StringComparison.Ordinal);
            if (split < 0 || !raw.StartsWith("HTTP/1.")) return -1;
            if (raw.IndexOf(" 200 ", 0, split, StringComparison.Ordinal) < 0) return -1;
            string body = raw.Substring(split + 4).Trim();
            if (body == "[]") return 0;
            return Regex.Matches(body, "\"Id\"\\s*:").Count;
        }
        catch { return -1; }
        finally
        {
            try { if (wsl != null && !wsl.HasExited) wsl.Kill(); } catch { }
            try { if (wsl != null) wsl.Dispose(); } catch { }
            RefillAsync();
        }
    }

    // wsl.exe processes started by any relay for this distro (keep-alive and pre-opened
    // connections). A relay that was killed leaves them behind, and they would keep the
    // distro running forever. Only this user's processes can be stopped.
    static void KillStrayWsl()
    {
        string keep = "-d " + distro + " -u root -- sleep infinity";
        string conn = "-d " + distro + " -u root -- socat -t 5 - UNIX-CONNECT:/var/run/docker.sock";
        var active = new HashSet<int>();
        lock (StateLock) { if (keepAlive != null && !sleeping) try { active.Add(keepAlive.Id); } catch { } }
        try
        {
            using (var q = new ManagementObjectSearcher("SELECT ProcessId, CommandLine FROM Win32_Process WHERE Name = 'wsl.exe'"))
            foreach (ManagementObject o in q.Get())
            {
                string cmd = o["CommandLine"] as string;
                if (cmd == null || !(cmd.Contains(keep) || cmd.Contains(conn))) continue;
                int pid = Convert.ToInt32(o["ProcessId"]);
                if (active.Contains(pid)) continue;
                if (cmd.Contains(conn) && clientConnections > 0) continue;    // could be serving a client
                try { using (var p = Process.GetProcessById(pid)) p.Kill(); } catch { }
            }
        }
        catch (Exception e) { Log("Could not clean up old wsl.exe processes: " + e.Message); }
    }

    // Lets go of the distro: WSL then stops it and, when nothing else uses WSL, the VM.
    static void GoToSleep()
    {
        var toKill = new List<Process>();
        lock (StateLock)
        {
            if (clientConnections > 0 || sleeping) return;
            sleeping = true;
            if (keepAlive != null) toKill.Add(keepAlive);
            keepAlive = null;
            toKill.AddRange(BackgroundWsl);
        }
        lock (PoolLock) { while (Pool.Count > 0) toKill.Add(Pool.Dequeue()); }
        foreach (var p in toKill)
        {
            try { if (!p.HasExited) p.Kill(); } catch { }
        }
        KillStrayWsl();
        Log("Idle sleep: no containers running for " + idleSleepMinutes + " min, letting WSL stop the VM to free memory.");
    }

    static void Wake()
    {
        lock (StateLock)
        {
            if (!sleeping) return;
            sleeping = false;
        }
        Log("Waking up Docker.");
        if (notify) ShowNotification("Starting Docker...", "It was sleeping to save memory. This takes a few seconds.");
        StartKeepAlive();
        RefillAsync();
    }

    // Windows notification (no window, no tray icon). The installer registers the
    // "lindowin" app id so Windows shows the name and logo.
    static string XmlText(string s)
    {
        // XML text inside a single-quoted PowerShell string
        return s.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;").Replace("'", "''");
    }

    static void ShowNotification(string title, string text)
    {
        try
        {
            string script =
                "[void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime];" +
                "[void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime];" +
                "$x = New-Object Windows.Data.Xml.Dom.XmlDocument;" +
                "$x.LoadXml('<toast duration=\"short\"><visual><binding template=\"ToastGeneric\">" +
                "<text>" + XmlText(title) + "</text><text>" + XmlText(text) + "</text>" +
                "</binding></visual><audio silent=\"true\"/></toast>');" +
                "$t = New-Object Windows.UI.Notifications.ToastNotification $x;" +
                "$t.ExpirationTime = [DateTimeOffset]::Now.AddSeconds(30);" +
                "[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('lindowin').Show($t)";
            string encoded = Convert.ToBase64String(Encoding.Unicode.GetBytes(script));
            Process.Start(new ProcessStartInfo("powershell.exe",
                "-NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand " + encoded)
            {
                UseShellExecute = false,
                CreateNoWindow = true
            });
        }
        catch (Exception e) { Log("Could not show notification: " + e.Message); }
    }

    // ---- WSL IP (portproxy mode only) -----------------------------------------------

    // Writes the distro's internal IPv4 address to a file while it runs
    // (never starts the distro by itself).
    static void StartIpWriter(string path)
    {
        new Thread(() =>
        {
            string last = null;
            while (true)
            {
                try
                {
                    if (networkMode == "portproxy" && !sleeping && DistroRunning())
                    {
                        var ips = RunWsl("-d " + distro + " -u root -- hostname -I")
                            .Split(new[] { ' ', '\t', '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries);
                        string ip = ips.Length > 0 ? ips[0] : null;
                        if (ip != null && ip != last)
                        {
                            File.WriteAllText(path, ip);
                            last = ip;
                        }
                    }
                }
                catch (Exception e) { Log("Could not read the WSL IP: " + e.Message); }
                Thread.Sleep(20000);
            }
        }) { IsBackground = true }.Start();
    }

    // ---- Status file for "lindowin status" ---------------------------------------------

    static readonly Dictionary<string, string> Status = new Dictionary<string, string>();

    static string StatusPath() { return Path.Combine(Path.GetDirectoryName(logPath), "relay-status.txt"); }

    static void LoadStatus()
    {
        lock (Status)
        {
            try
            {
                if (!File.Exists(StatusPath())) return;
                foreach (string line in File.ReadAllLines(StatusPath()))
                {
                    int eq = line.IndexOf('=');
                    if (eq > 0) Status[line.Substring(0, eq)] = line.Substring(eq + 1);
                }
            }
            catch { }
        }
    }

    static string GetStatus(string key)
    {
        lock (Status) { string v; return Status.TryGetValue(key, out v) ? v : ""; }
    }

    static void SetStatus(string key, string value)
    {
        lock (Status)
        {
            Status[key] = value;
            Status[key + "_time"] = DateTime.Now.ToString("s");
            try
            {
                var lines = new List<string>();
                foreach (var kv in Status) lines.Add(kv.Key + "=" + kv.Value);
                File.WriteAllLines(StatusPath(), lines.ToArray());
            }
            catch { }
        }
    }

    // ---- Network check (WSL can start without network) -------------------------------

    static DateTime lastNetworkRecovery = DateTime.MinValue;

    // ---- Disk space ------------------------------------------------------------------

    static void CheckDiskSpace()
    {
        try
        {
            string folder = null;
            using (var lxss = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Lxss"))
            {
                if (lxss == null) return;
                foreach (string id in lxss.GetSubKeyNames())
                    using (var k = lxss.OpenSubKey(id))
                        if (k != null && (k.GetValue("DistributionName") as string) == distro) folder = k.GetValue("BasePath") as string;
            }
            if (folder == null) return;
            if (folder.StartsWith(@"\\?\")) folder = folder.Substring(4);
            var drive = new DriveInfo(Path.GetPathRoot(folder));
            double freeGb = drive.AvailableFreeSpace / 1073741824.0;
            if (freeGb >= 2) { SetStatus("disk_low", ""); return; }
            string gb = freeGb.ToString("0.0");
            SetStatus("disk_low", gb + " GB free on " + drive.Name);
            Log("Disk warning: only " + gb + " GB free on " + drive.Name + " (Docker's disk lives there).");
            DateTime last;
            bool recent = DateTime.TryParse(GetStatus("disk_notified"), out last) && (DateTime.Now - last).TotalHours < 24;
            if (notify && !recent)
            {
                SetStatus("disk_notified", DateTime.Now.ToString("s"));
                ShowNotification("Low disk space", "Only " + gb + " GB free on " + drive.Name +
                    ". Downloads and builds may fail. Free some space, or remove unused images: docker system prune");
            }
        }
        catch (Exception e) { Log("Disk check failed: " + e.Message); }
    }

    // ---- Daily checks: updates and disk space worth giving back -----------------------

    static void StartDailyChecks()
    {
        new Thread(() =>
        {
            Thread.Sleep(120000);   // not during start-up
            while (true)
            {
                try
                {
                    DateTime last;
                    if (!DateTime.TryParse(GetStatus("checked_time"), out last) || (DateTime.Now - last).TotalHours >= 24)
                    {
                        CheckUpdates();
                        if (!sleeping && DistroRunning()) CheckCompact();
                        SetStatus("checked", "yes");
                    }
                }
                catch (Exception e) { Log("Daily check failed: " + e.Message); }
                Thread.Sleep(3600000);  // look again in an hour; work only once a day
            }
        }) { IsBackground = true }.Start();
    }

    static string HttpGet(string url, bool followRedirect)
    {
        System.Net.ServicePointManager.SecurityProtocol |= System.Net.SecurityProtocolType.Tls12;
        var req = (System.Net.HttpWebRequest)System.Net.WebRequest.Create(url);
        req.AllowAutoRedirect = followRedirect;
        req.Timeout = 10000;
        req.UserAgent = "lindowin";
        using (var resp = (System.Net.HttpWebResponse)req.GetResponse())
        {
            if (!followRedirect) return resp.Headers["Location"] ?? "";
            using (var r = new StreamReader(resp.GetResponseStream())) return r.ReadToEnd();
        }
    }

    static Version ParseVersion(string v)
    {
        Version x;
        return Version.TryParse((v ?? "").Trim().TrimStart('v'), out x) ? x : null;
    }

    static void CheckUpdates()
    {
        var found = new List<string>();

        // lindowin: github.com/<repo>/releases/latest redirects to .../tag/vX.Y.Z
        string mine = "";
        try { Match m = Regex.Match(File.ReadAllText(configPath), "\"version\"\\s*:\\s*\"([^\"]+)\""); if (m.Success) mine = m.Groups[1].Value; } catch { }
        Match tag = Regex.Match(HttpGet("https://github.com/alozdev/lindowin/releases/latest", false), "/tag/v?([0-9][^/]*)$");
        Version latest = tag.Success ? ParseVersion(tag.Groups[1].Value) : null, current = ParseVersion(mine);
        string newLindowin = (latest != null && current != null && latest > current) ? latest.ToString() : "";
        SetStatus("update_lindowin", newLindowin);
        if (newLindowin != "") found.Add("lindowin " + newLindowin);

        // Docker CLI for Windows (Docker Engine inside Linux updates by itself)
        string listing = HttpGet("https://download.docker.com/win/static/stable/x86_64/", true);
        Version newest = null;
        foreach (Match m in Regex.Matches(listing, "docker-(\\d+\\.\\d+\\.\\d+)\\.zip"))
        {
            Version v = ParseVersion(m.Groups[1].Value);
            if (v != null && (newest == null || v > newest)) newest = v;
        }
        string cli = RunProgram(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "docker.exe"), "--version");
        Match cm = Regex.Match(cli, "version (\\d+\\.\\d+\\.\\d+)");
        Version have = cm.Success ? ParseVersion(cm.Groups[1].Value) : null;
        string newCli = (newest != null && have != null && newest > have) ? newest.ToString() : "";
        SetStatus("update_docker", newCli);
        if (newCli != "") found.Add("Docker CLI " + newCli);

        if (found.Count == 0) return;
        string what = string.Join(" and ", found.ToArray());
        Log("Updates available: " + what + ".");
        if (notify && GetStatus("update_notified") != what)
        {
            SetStatus("update_notified", what);
            ShowNotification("Update available", what + (found.Count > 1 ? " are" : " is") + " available. Run: lindowin update");
        }
    }

    static string RunProgram(string file, string args)
    {
        try
        {
            var psi = new ProcessStartInfo(file, args) { UseShellExecute = false, RedirectStandardOutput = true, CreateNoWindow = true };
            using (var p = Process.Start(psi)) { string o = p.StandardOutput.ReadToEnd(); p.WaitForExit(10000); return o; }
        }
        catch { return ""; }
    }

    // Space the virtual disk takes on Windows but Linux does not use (deleted images, old builds)
    static void CheckCompact()
    {
        string folder = DistroFolder();
        if (folder == null) return;
        var vhdx = new DirectoryInfo(folder).GetFiles("*.vhdx");
        if (vhdx.Length == 0) return;
        long fileBytes = vhdx[0].Length;
        long used;
        string[] df = RunWsl("-d " + distro + " -u root -- df -B1 --output=used /").Split('\n');
        if (df.Length < 2 || !long.TryParse(df[1].Trim(), out used)) return;
        // The file is always ~1.3 GB bigger than what Linux uses (file system structures)
        double spare = (fileBytes - used) / 1073741824.0 - 1.3;
        if (spare < 5) { SetStatus("compact_gb", ""); return; }
        int gb = (int)spare;
        SetStatus("compact_gb", gb.ToString());
        Log("Disk: about " + gb + " GB of Docker's disk is unused. \"lindowin compact\" gives it back to Windows.");
        int lastGb;
        int.TryParse(GetStatus("compact_notified"), out lastGb);
        if (notify && gb >= lastGb + 5)
        {
            SetStatus("compact_notified", gb.ToString());
            ShowNotification("Free up " + gb + " GB", "Docker's disk has about " + gb + " GB of unused space. Run: lindowin compact");
        }
    }

    static string DistroFolder()
    {
        using (var lxss = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Lxss"))
        {
            if (lxss == null) return null;
            foreach (string id in lxss.GetSubKeyNames())
                using (var k = lxss.OpenSubKey(id))
                    if (k != null && (k.GetValue("DistributionName") as string) == distro)
                    {
                        string f = k.GetValue("BasePath") as string;
                        return f != null && f.StartsWith(@"\\?\") ? f.Substring(4) : f;
                    }
        }
        return null;
    }

    static int networkCheckPending = 0;

    // Runs once, a few seconds after Linux starts (relay start, wake-up, restart)
    static void ScheduleNetworkCheck()
    {
        if (Interlocked.Exchange(ref networkCheckPending, 1) == 1) return;
        new Thread(() =>
        {
            try { Thread.Sleep(10000); if (!sleeping) { CheckNetwork(); CheckDiskSpace(); } }
            catch (Exception e) { Log("Network check failed: " + e.Message); }
            finally { Interlocked.Exchange(ref networkCheckPending, 0); }
        }) { IsBackground = true }.Start();
    }

    static bool OnlyOurDistroRunning()
    {
        foreach (var line in RunWsl("--list --running --quiet").Split('\n'))
        {
            string d = line.Trim();
            if (d != "" && d != distro) return false;
        }
        return true;
    }

    static void CheckNetwork()
    {
        string route = RunWsl("-d " + distro + " -u root -- sh -c \"ip -4 route show default | head -n 1\"").Trim();
        if (route != "")
        {
            if (GetStatus("network") == "none") Log("Network is back.");
            SetStatus("network", "ok");
            return;
        }
        Log("Network warning: WSL started without network (" + networkMode + " networking).");

        // Nothing running and no other WSL distro in use: restart WSL once, quietly
        if ((DateTime.UtcNow - lastNetworkRecovery).TotalMinutes > 10 && RunningContainers() == 0 && OnlyOurDistroRunning())
        {
            lastNetworkRecovery = DateTime.UtcNow;
            Log("Restarting WSL once to get the network back.");
            RunWsl("--shutdown");
            Thread.Sleep(3000);
            lock (StateLock) keepAlive = null;
            StartKeepAlive();
            RefillAsync();
            // Check again once it is up. No second restart: if it still has no network, warn.
            Thread.Sleep(10000);
            CheckNetwork();
            return;
        }

        SetStatus("network", "none");
        string fix = networkMode == "mirrored"
            ? "WSL could not set up mirrored networking (often a VPN). Run: lindowin stop, then any docker command. If it keeps happening: lindowin config network nat"
            : "Run: lindowin stop, then any docker command.";
        Log("Network warning: " + fix);
        if (notify) ShowNotification("Docker has no network", fix);
    }

    static void Log(string msg)
    {
        try { File.AppendAllText(logPath, DateTime.Now.ToString("s") + " " + msg + Environment.NewLine); } catch { }
    }
}
