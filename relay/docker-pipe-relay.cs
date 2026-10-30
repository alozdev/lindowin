// docker-pipe-relay
//
// Exposes the Docker Engine running inside a WSL distro on \\.\pipe\docker_engine,
// the same endpoint Docker Desktop uses, so the Windows docker.exe works with no
// DOCKER_HOST and no TCP port.
//
// Usage: docker-pipe-relay.exe [--distro <name>] [--no-keepalive] [--wsl-ip-file <path>]
//
// Security
//  - Only the current Windows user, members of the local "docker-users" group and
//    SYSTEM (used by the port sync service) can connect; remote clients are rejected.
//  - If another program already owns \\.\pipe\docker_engine, the relay refuses to start
//    (prevents something else from impersonating Docker).
//
// Speed
//  - Starting wsl.exe takes ~700 ms, so a few connections are pre-opened.
//    Dead ones are only replaced when a new client connects, so
//    "wsl --terminate <distro>" keeps the distro stopped.
//
// Keep-alive
//  - On start, a "sleep infinity" process keeps the distro (and Docker) running.
//    It is started once and not restarted if you stop the distro yourself.
//
// WSL IP
//  - With --wsl-ip-file, the distro's internal IP is written to that file while the
//    distro runs. The port sync service uses it to forward ports in "portproxy" mode.

using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Threading;
using Microsoft.Win32.SafeHandles;

class DockerPipeRelay
{
    const string PipeName = "docker_engine";
    const int PoolSize = 3;

    static string distro = "docker";
    static string wslArgs;
    static readonly object PoolLock = new object();
    static readonly Queue<Process> Pool = new Queue<Process>();
    static int refilling = 0;
    static string logPath;

    static int Main(string[] args)
    {
        bool keepAlive = true;
        string ipFile = null;
        for (int i = 0; i < args.Length; i++)
        {
            if (args[i] == "--distro" && i + 1 < args.Length) distro = args[++i];
            else if (args[i] == "--no-keepalive") keepAlive = false;
            else if (args[i] == "--wsl-ip-file" && i + 1 < args.Length) ipFile = args[++i];
        }
        wslArgs = "-d " + distro + " -u root -- socat -t 5 - UNIX-CONNECT:/var/run/docker.sock";

        bool isFirst;
        var mutex = new Mutex(true, @"Local\docker-pipe-relay", out isFirst);
        if (!isFirst) return 0;

        logPath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "docker-pipe-relay.log");

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

        if (ipFile != null) StartIpWriter(ipFile);

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
                    Log("Another program already owns \\\\.\\pipe\\docker_engine (Docker Desktop, Podman, Rancher Desktop...). Relay not started. " + e.Message);
                    return 1;
                }
                Log("Could not create pipe instance: " + e.Message);
                Thread.Sleep(1000);
                continue;
            }
            if (first)
            {
                first = false;
                if (keepAlive) StartKeepAlive();
                RefillAsync();
            }

            pipe.WaitForConnection();
            new Thread(() => Handle(pipe)) { IsBackground = true }.Start();
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    struct SECURITY_ATTRIBUTES { public int nLength; public IntPtr lpSecurityDescriptor; public int bInheritHandle; }

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern SafePipeHandle CreateNamedPipe(string name, uint openMode, uint pipeMode,
        uint maxInstances, uint outBuffer, uint inBuffer, uint timeout, ref SECURITY_ATTRIBUTES sa);

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
                    string running = RunWsl("--list --running --quiet");
                    bool isRunning = false;
                    foreach (var line in running.Split('\n'))
                        if (line.Trim() == distro) isRunning = true;
                    if (isRunning)
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

    static void StartKeepAlive()
    {
        try { StartHidden("-d " + distro + " -u root -- sleep infinity", false); }
        catch (Exception e) { Log("Could not start keep-alive: " + e.Message); }
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

    // Refills the pool in the background (one refill task at a time).
    static void RefillAsync()
    {
        if (Interlocked.Exchange(ref refilling, 1) == 1) return;
        new Thread(() =>
        {
            try
            {
                while (true)
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
                    lock (PoolLock) Pool.Enqueue(fresh);
                }
            }
            catch (Exception e) { Log("Could not pre-open connections: " + e.Message); }
            finally { Interlocked.Exchange(ref refilling, 0); }
        }) { IsBackground = true }.Start();
    }

    static void Handle(NamedPipeServerStream pipe)
    {
        Process wsl = null;
        try
        {
            wsl = TakeWsl();
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
            try { Pump(fromDocker, pipe); } catch { }
        }
        catch (Exception e) { Log("Connection error: " + e.Message); }
        finally
        {
            // Close without Disconnect(): the client then sees end-of-stream, not an error.
            try { if (pipe.IsConnected) pipe.WaitForPipeDrain(); } catch { }
            try { pipe.Dispose(); } catch { }
            try { if (wsl != null && !wsl.HasExited) wsl.Kill(); } catch { }
            try { if (wsl != null) wsl.Dispose(); } catch { }
        }
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

    static void Log(string msg)
    {
        try { File.AppendAllText(logPath, DateTime.Now.ToString("s") + " " + msg + Environment.NewLine); } catch { }
    }
}
