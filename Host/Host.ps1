# ==============================================================================
# Host/Host.ps1
# LAN Dynamic Wallpaper - Central Management Server & UDP Discovery Daemon
# Pure Windows PowerShell 5.1+ / .NET - Zero-Admin Architecture (No UAC / Elevation Required)
# ==============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = "",
    [Parameter(Mandatory = $false)]
    [int]$Port = 0,
    [Parameter(Mandatory = $false)]
    [switch]$NoLocalSlideshow = $false
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    $PSScriptRoot
} elseif ($null -ne $MyInvocation -and $null -ne $MyInvocation.MyCommand -and ($MyInvocation.MyCommand.PSObject.Properties['Path'])) {
    Split-Path -Parent $MyInvocation.MyCommand.Path
} else {
    (Get-Location).Path
}

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $scriptDir "HostConfig.json"
}
$script:ConfigPath = [System.IO.Path]::GetFullPath($ConfigPath.Trim().Trim('"').Trim("'"))

# Ensure TLS 1.2
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]'Tls12'

# Import Publisher engine
$publisherScript = Join-Path $scriptDir "Publisher.ps1"
if (-not (Test-Path -LiteralPath $publisherScript)) {
    throw "Fatal: Publisher.ps1 not found at $publisherScript"
}
$savedConfig = $script:ConfigPath
$IsImportedModule = $true
. $publisherScript -ConfigPath $savedConfig
$script:ConfigPath = $savedConfig

# Import Wallpaper engine for Host Desktop Slideshow
$wallpaperScript = Join-Path $scriptDir "../Client/Wallpaper.ps1"
if (Test-Path -LiteralPath $wallpaperScript) {
    try {
        . $wallpaperScript
    } catch {}
}

# Compile Zero-Admin C# TCP HTTP Server (Runs without Administrator rights or http.sys URL ACLs)
if (-not ([System.Management.Automation.PSTypeName]'LanHttpServer').Type) {
    Add-Type -TypeDefinition @"
    using System;
    using System.IO;
    using System.Net;
    using System.Net.Sockets;
    using System.Text;
    using System.Threading;
    using System.Collections.Concurrent;

    public class ClientTelemetry {
        public string ClientId;
        public string Hostname;
        public string IpAddress;
        public string MacAddress;
        public string ClientVersion;
        public DateTime RegisteredAt;
        public DateTime LastSeenAt;
        public string Status;
        public string CurrentHash;
    }

    public class LanHttpServer {
        private TcpListener _listener;
        private volatile bool _running;
        private string _publishedDir;
        private string _scriptDir;
        public ConcurrentDictionary<string, ClientTelemetry> Clients = new ConcurrentDictionary<string, ClientTelemetry>();
        public string HostIp = "0.0.0.0";
        public int Port = 8765;
        public int DefaultInterval = 5;
        public DateTime StartTime = DateTime.UtcNow;

        public void Start(int port, string publishedDir, string scriptDir, string hostIp, int defaultInterval) {
            Port = port;
            _publishedDir = publishedDir;
            _scriptDir = scriptDir;
            HostIp = hostIp;
            DefaultInterval = defaultInterval;
            _listener = new TcpListener(IPAddress.Any, port);
            _listener.Start(128);
            _running = true;
            ThreadPool.QueueUserWorkItem(ListenLoop);
        }

        public void Stop() {
            _running = false;
            try { _listener.Stop(); } catch {}
        }

        private void ListenLoop(object state) {
            while (_running) {
                try {
                    TcpClient client = _listener.AcceptTcpClient();
                    ThreadPool.QueueUserWorkItem(HandleClient, client);
                } catch {
                    if (!_running) break;
                }
            }
        }

        private void HandleClient(object state) {
            using (TcpClient client = (TcpClient)state) {
                try {
                    client.ReceiveTimeout = 15000;
                    client.SendTimeout = 15000;
                    using (NetworkStream stream = client.GetStream()) {
                        StreamReader reader = new StreamReader(stream, Encoding.UTF8);
                        string reqLine = reader.ReadLine();
                        if (string.IsNullOrEmpty(reqLine)) return;

                        string[] parts = reqLine.Split(' ');
                        if (parts.Length < 2) return;
                        string method = parts[0].ToUpperInvariant();
                        string fullPath = parts[1];
                        string path = fullPath;
                        int qIdx = path.IndexOf('?');
                        if (qIdx >= 0) path = path.Substring(0, qIdx);

                        // Read Headers
                        int contentLength = 0;
                        string line;
                        while (!string.IsNullOrEmpty(line = reader.ReadLine())) {
                            if (line.StartsWith("Content-Length:", StringComparison.OrdinalIgnoreCase)) {
                                int.TryParse(line.Substring(15).Trim(), out contentLength);
                            }
                        }

                        // Read Body
                        string body = "";
                        if (contentLength > 0 && contentLength < 10485760) {
                            char[] buf = new char[contentLength];
                            int totalRead = 0;
                            while (totalRead < contentLength) {
                                int r = reader.Read(buf, totalRead, contentLength - totalRead);
                                if (r <= 0) break;
                                totalRead += r;
                            }
                            body = new string(buf, 0, totalRead);
                        }

                        string remoteIp = ((IPEndPoint)client.Client.RemoteEndPoint).Address.ToString();

                        // --------------------------------------------------
                        // Route 1: GET /api/v1/health
                        // --------------------------------------------------
                        if (method == "GET" && path == "/api/v1/health") {
                            string manifestPath = Path.Combine(_publishedDir, "manifest.json");
                            string colVer = "none";
                            int imgCount = 0;
                            if (File.Exists(manifestPath)) {
                                try {
                                    string txt = File.ReadAllText(manifestPath, Encoding.UTF8);
                                    int vIdx = txt.IndexOf("\"collectionVersion\":\"");
                                    if (vIdx >= 0) {
                                        int endV = txt.IndexOf('"', vIdx + 21);
                                        if (endV > vIdx) colVer = txt.Substring(vIdx + 21, endV - (vIdx + 21));
                                    }
                                    int cIdx = txt.IndexOf("\"totalImages\":");
                                    if (cIdx >= 0) {
                                        int endC = txt.IndexOfAny(new char[] { ',', '}', '\r', '\n' }, cIdx + 14);
                                        if (endC > cIdx) int.TryParse(txt.Substring(cIdx + 14, endC - (cIdx + 14)).Trim(), out imgCount);
                                    }
                                } catch {}
                            }
                            long uptime = (long)(DateTime.UtcNow - StartTime).TotalSeconds;
                            string json = string.Format(
                                "{{\"status\":\"ok\",\"service\":\"LAN-Dynamic-Wallpaper-Host\",\"version\":\"1.0.0\",\"uptimeSeconds\":{0},\"hostIp\":\"{1}\",\"collectionVersion\":\"{2}\",\"totalImages\":{3},\"registeredClients\":{4}}}",
                                uptime, HostIp, colVer, imgCount, Clients.Count
                            );
                            SendJsonResponse(stream, 200, json);
                            return;
                        }

                        // --------------------------------------------------
                        // Route 2: GET /api/v1/manifest
                        // --------------------------------------------------
                        if (method == "GET" && path == "/api/v1/manifest") {
                            string manifestPath = Path.Combine(_publishedDir, "manifest.json");
                            if (File.Exists(manifestPath)) {
                                byte[] raw = File.ReadAllBytes(manifestPath);
                                SendBytesResponse(stream, 200, "application/json; charset=utf-8", raw);
                            } else {
                                SendJsonResponse(stream, 404, "{\"error\":\"Manifest not found\"}");
                            }
                            return;
                        }

                        // --------------------------------------------------
                        // Route 3: GET /api/v1/wallpaper/{filename}
                        // --------------------------------------------------
                        if (method == "GET" && path.StartsWith("/api/v1/wallpaper/")) {
                            string rawName = Uri.UnescapeDataString(path.Substring("/api/v1/wallpaper/".Length));
                            string safeName = Path.GetFileName(rawName);
                            string filePath = Path.Combine(_publishedDir, safeName);
                            if (!File.Exists(filePath)) {
                                SendJsonResponse(stream, 404, "{\"error\":\"File not found\"}");
                                return;
                            }

                            string ext = Path.GetExtension(filePath).ToLowerInvariant();
                            string mime = "application/octet-stream";
                            if (ext == ".jpg" || ext == ".jpeg") mime = "image/jpeg";
                            else if (ext == ".png") mime = "image/png";
                            else if (ext == ".bmp") mime = "image/bmp";
                            else if (ext == ".gif") mime = "image/gif";
                            else if (ext == ".webp") mime = "image/webp";

                            SendFileResponse(stream, filePath, mime);
                            return;
                        }

                        // --------------------------------------------------
                        // Route 4: POST /api/v1/auth/register
                        // --------------------------------------------------
                        if (method == "POST" && path == "/api/v1/auth/register") {
                            string cid = "CLT-" + Guid.NewGuid().ToString("N").Substring(0, 12).ToUpperInvariant();
                            string hostname = "PC-" + remoteIp;
                            if (!string.IsNullOrEmpty(body)) {
                                int hIdx = body.IndexOf("\"hostname\":\"");
                                if (hIdx >= 0) {
                                    int endH = body.IndexOf('"', hIdx + 12);
                                    if (endH > hIdx) hostname = body.Substring(hIdx + 12, endH - (hIdx + 12));
                                }
                            }

                            ClientTelemetry t = new ClientTelemetry {
                                ClientId = cid,
                                Hostname = hostname,
                                IpAddress = remoteIp,
                                RegisteredAt = DateTime.UtcNow,
                                LastSeenAt = DateTime.UtcNow,
                                Status = "ONLINE",
                                CurrentHash = ""
                            };
                            Clients[cid] = t;

                            string json = string.Format(
                                "{{\"clientId\":\"{0}\",\"status\":\"ENROLLED\",\"slideshowInterval\":{1}}}",
                                cid, DefaultInterval
                            );
                            SendJsonResponse(stream, 200, json);
                            return;
                        }

                        // --------------------------------------------------
                        // Route 5: POST /api/v1/heartbeat
                        // --------------------------------------------------
                        if (method == "POST" && path == "/api/v1/heartbeat") {
                            if (!string.IsNullOrEmpty(body)) {
                                string cid = "";
                                int cIdx = body.IndexOf("\"clientId\":\"");
                                if (cIdx >= 0) {
                                    int endC = body.IndexOf('"', cIdx + 12);
                                    if (endC > cIdx) cid = body.Substring(cIdx + 12, endC - (cIdx + 12));
                                }
                                if (!string.IsNullOrEmpty(cid) && Clients.ContainsKey(cid)) {
                                    Clients[cid].LastSeenAt = DateTime.UtcNow;
                                    Clients[cid].IpAddress = remoteIp;
                                    Clients[cid].Status = "ONLINE";
                                }
                            }
                            SendJsonResponse(stream, 200, "{\"status\":\"ACK\"}");
                            return;
                        }

                        // --------------------------------------------------
                        // Route 6: Automated Zero-Setup Client Deployment Scripts
                        // --------------------------------------------------
                        if (method == "GET" && (path == "/setup" || path == "/setup.ps1")) {
                            string setupScript = GenerateClientSetupScript();
                            byte[] raw = Encoding.UTF8.GetBytes(setupScript);
                            SendBytesResponse(stream, 200, "text/plain; charset=utf-8", raw);
                            return;
                        }

                        if (method == "GET" && (path == "/client.ps1" || path == "/client")) {
                            string cScript = Path.Combine(_scriptDir, "../Client/Client.ps1");
                            if (File.Exists(cScript)) {
                                byte[] raw = File.ReadAllBytes(cScript);
                                SendBytesResponse(stream, 200, "text/plain; charset=utf-8", raw);
                                return;
                            }
                        }

                        if (method == "GET" && path == "/Wallpaper.ps1") {
                            string wScript = Path.Combine(_scriptDir, "../Client/Wallpaper.ps1");
                            if (File.Exists(wScript)) {
                                byte[] raw = File.ReadAllBytes(wScript);
                                SendBytesResponse(stream, 200, "text/plain; charset=utf-8", raw);
                                return;
                            }
                        }

                        SendJsonResponse(stream, 404, "{\"error\":\"Endpoint not found\"}");
                    }
                } catch {}
            }
        }

        private string GenerateClientSetupScript() {
            return string.Format(
                "# LAN Dynamic Wallpaper Client Automated Setup\r\n" +
                "`$destDir = Join-Path `$env:LOCALAPPDATA 'LAN-Dynamic-Wallpaper'\r\n" +
                "`$clientDir = Join-Path `$destDir 'Client'\r\n" +
                "`$cacheDir = Join-Path `$destDir 'Cache'\r\n" +
                "New-Item -ItemType Directory -Path `$clientDir -Force | Out-Null\r\n" +
                "New-Item -ItemType Directory -Path `$cacheDir -Force | Out-Null\r\n" +
                "Invoke-WebRequest -Uri 'http://{0}:{1}/client.ps1' -OutFile (Join-Path `$clientDir 'Client.ps1') -UseBasicParsing\r\n" +
                "Invoke-WebRequest -Uri 'http://{0}:{1}/Wallpaper.ps1' -OutFile (Join-Path `$clientDir 'Wallpaper.ps1') -UseBasicParsing\r\n" +
                "`$cfgJson = '@{{\"\"Connection\"\":{{\"\"HostAddress\"\":\"\"{0}\"\",\"\"HostPort\"\":{1},\"\"DiscoveryPort\"\":8766,\"\"EnableDiscovery\"\":true,\"\"PollIntervalSeconds\"\":4}},\"\"Slideshow\"\":{{\"\"IntervalSeconds\"\":{2}}}}}'\r\n" +
                "Set-Content -Path (Join-Path `$clientDir 'ClientConfig.json') -Value `$cfgJson -Encoding UTF8\r\n" +
                "Write-Host 'Client installed successfully. Launching background slideshow agent...' -ForegroundColor Green\r\n" +
                "Start-Process powershell.exe -ArgumentList '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File \"' + (Join-Path `$clientDir 'Client.ps1') + '\"'\r\n",
                HostIp, Port, DefaultInterval
            );
        }

        private void SendJsonResponse(NetworkStream stream, int status, string json) {
            byte[] body = Encoding.UTF8.GetBytes(json);
            SendBytesResponse(stream, status, "application/json; charset=utf-8", body);
        }

        private void SendBytesResponse(NetworkStream stream, int status, string contentType, byte[] body) {
            string statusText = (status == 200) ? "200 OK" : (status == 404 ? "404 Not Found" : status + " Status");
            string header = string.Format(
                "HTTP/1.1 {0}\r\nContent-Type: {1}\r\nContent-Length: {2}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n",
                statusText, contentType, body.Length
            );
            byte[] hBytes = Encoding.UTF8.GetBytes(header);
            stream.Write(hBytes, 0, hBytes.Length);
            stream.Write(body, 0, body.Length);
            stream.Flush();
        }

        private void SendFileResponse(NetworkStream stream, string filePath, string contentType) {
            using (FileStream fs = File.OpenRead(filePath)) {
                long len = fs.Length;
                string header = string.Format(
                    "HTTP/1.1 200 OK\r\nContent-Type: {0}\r\nContent-Length: {1}\r\nCache-Control: public, max-age=86400\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n",
                    contentType, len
                );
                byte[] hBytes = Encoding.UTF8.GetBytes(header);
                stream.Write(hBytes, 0, hBytes.Length);
                byte[] buf = new byte[65536];
                int read;
                while ((read = fs.Read(buf, 0, buf.Length)) > 0) {
                    stream.Write(buf, 0, read);
                }
                stream.Flush();
            }
        }
    }
"@ -ErrorAction Stop
}

# Application State
$script:Running = $true
$script:StartTime = [DateTime]::UtcNow
$script:Server = $null
$script:HostMutex = $null
$script:LogLock = New-Object System.Object
$script:LogDirectory = $null

function Write-HostLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR", "DEBUG", "AUDIT")]
        [string]$Level = "INFO",
        [string]$ClientIp = "-"
    )

    $timestamp = [DateTime]::UtcNow.ToString("yyyy-MM-dd HH:mm:ss.fff")
    $logLine = "[$timestamp] [$Level] [$ClientIp] $Message"

    switch ($Level) {
        "INFO"  { Write-Host $logLine -ForegroundColor Gray }
        "AUDIT" { Write-Host $logLine -ForegroundColor Cyan }
        "WARN"  { Write-Host $logLine -ForegroundColor Yellow }
        "ERROR" { Write-Host $logLine -ForegroundColor Red }
        "DEBUG" { Write-Host $logLine -ForegroundColor DarkGray }
    }

    try {
        [System.Threading.Monitor]::Enter($script:LogLock)
        $logDir = if ($null -ne $script:LogDirectory -and -not [string]::IsNullOrWhiteSpace($script:LogDirectory)) {
            $script:LogDirectory
        } else {
            [System.IO.Path]::GetFullPath((Join-Path $scriptDir "../Logs"))
        }
        if (-not (Test-Path -LiteralPath $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        $logFile = Join-Path $logDir ("host-{0}.log" -f [DateTime]::UtcNow.ToString("yyyy-MM-dd"))
        [System.IO.File]::AppendAllText($logFile, "$logLine`r`n", [System.Text.Encoding]::UTF8)
    }
    catch {}
    finally {
        [System.Threading.Monitor]::Exit($script:LogLock)
    }
}

function Get-ActiveLanIp {
    <#
    .SYNOPSIS
    Discovers the active LAN IPv4 address (Ethernet or Wi-Fi with active gateway).
    #>
    try {
        # Check routing table for primary route to gateway
        $defaultRoute = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
            Sort-Object RouteMetric | Select-Object -First 1

        if ($null -ne $defaultRoute) {
            $ipObj = Get-NetIPAddress -InterfaceIndex $defaultRoute.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*" } |
                Select-Object -First 1
            if ($null -ne $ipObj) {
                return $ipObj.IPAddress
            }
        }

        # Fallback: scan all active physical IPv4 adapters
        $adapters = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*" }

        $preferred = $adapters | Where-Object {
            $alias = (Get-NetAdapter -InterfaceIndex $_.InterfaceIndex -ErrorAction SilentlyContinue).InterfaceAlias
            $alias -like "*Ethernet*" -or $alias -like "*Wi-Fi*" -or $alias -like "*LAN*"
        } | Select-Object -First 1

        if ($null -ne $preferred) {
            return $preferred.IPAddress
        }

        if ($adapters.Count -gt 0) {
            return $adapters[0].IPAddress
        }
    }
    catch {
        Write-HostLog "LAN adapter detection warning: $($_.Exception.Message)" -Level WARN
    }

    return "127.0.0.1"
}

function Start-UdpDiscoveryServer {
    param(
        [int]$Port = 8766,
        [int]$HttpPort = 8765,
        [string]$HostIp
    )

    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.Open()

    $powershell = [System.Management.Automation.PowerShell]::Create()
    $powershell.Runspace = $runspace

    [void]$powershell.AddScript({
        param($Port, $HttpPort, $HostIp, $HostName)
        try {
            $udp = New-Object System.Net.Sockets.UdpClient($Port)
            $udp.EnableBroadcast = $true
            $endpoint = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)

            while ($true) {
                $receiveBytes = $udp.Receive([ref]$endpoint)
                $requestMsg = [System.Text.Encoding]::UTF8.GetString($receiveBytes).Trim()

                if ($requestMsg -eq "LAN_WALLPAPER_DISCOVER_REQ") {
                    $responseObj = @{
                        service   = "LAN_WALLPAPER_HOST"
                        version   = "1.0.0"
                        ip        = $HostIp
                        port      = $HttpPort
                        hostname  = $HostName
                        timestamp = [DateTime]::UtcNow.ToString("o")
                    }
                    $json = ($responseObj | ConvertTo-Json -Compress)
                    $respBytes = [System.Text.Encoding]::UTF8.GetBytes($json)
                    $udp.Send($respBytes, $respBytes.Length, $endpoint) | Out-Null
                }
            }
        }
        catch {}
        finally {
            if ($null -ne $udp) { $udp.Close() }
        }
    }).AddArgument($Port).AddArgument($HttpPort).AddArgument($HostIp).AddArgument([System.Environment]::MachineName)

    $handle = $powershell.BeginInvoke()
    return @{ PowerShell = $powershell; Runspace = $runspace; Handle = $handle }
}

function Start-HostServer {
    [CmdletBinding()]
    param(
        [string]$ConfigFilePath = $script:ConfigPath,
        [int]$PortOverride = 0,
        [switch]$NoLocalSlideshow = $false
    )

    $ConfigFilePath = [System.IO.Path]::GetFullPath($ConfigFilePath.Trim().Trim('"').Trim("'"))
    $cfg = Get-PublisherConfig -Path $ConfigFilePath
    $port = if ($PortOverride -gt 0) { $PortOverride } else { $cfg.Server.Port }
    $discPort = $cfg.Server.DiscoveryPort
    $maxImageBytes = $cfg.Security.MaxImageSizeBytes
    $allowedExts = $cfg.Security.AllowedExtensions
    $defaultInterval = $cfg.Slideshow.DefaultIntervalSeconds

    # Enforce Single-Instance Host Mutex per Port
    $createdNewHost = $false
    try {
        $script:HostMutex = New-Object System.Threading.Mutex($true, "Global\LAN_Dynamic_Wallpaper_Host_Port_$port", [ref]$createdNewHost)
        if (-not $createdNewHost) {
            Write-HostLog "Another instance of Host Server is already running on port $port." -Level WARN
        }
    } catch {}

    $configDir = Split-Path $ConfigFilePath -Parent
    $wallpapersDir = [System.IO.Path]::GetFullPath((Join-Path $configDir $cfg.Paths.WallpapersDir))
    $publishedDir = [System.IO.Path]::GetFullPath((Join-Path $configDir $cfg.Paths.PublishedDir))
    $script:LogDirectory = [System.IO.Path]::GetFullPath((Join-Path $configDir $cfg.Paths.LogsDir))

    foreach ($dir in @($wallpapersDir, $publishedDir, $script:LogDirectory)) {
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }

    # Initial sync and publication
    Write-HostLog "Synchronizing wallpaper directory: $wallpapersDir" -Level INFO
    $initialManifest = Sync-WallpaperCollection -SourceDir $wallpapersDir -TargetDir $publishedDir `
        -MaxSizeBytes $maxImageBytes -AllowedExts $allowedExts -SlideshowInterval $defaultInterval

    # Continuous FileSystemWatcher for instant photo updates
    Start-WallpaperWatcher -SourceDir $wallpapersDir -TargetDir $publishedDir `
        -MaxSizeBytes $maxImageBytes -AllowedExts $allowedExts -SlideshowInterval $defaultInterval

    # Detect Host IP
    $hostIp = Get-ActiveLanIp

    # Start Zero-Admin TCP HTTP Server
    $server = New-Object LanHttpServer
    $server.Start($port, $publishedDir, $scriptDir, $hostIp, $defaultInterval)
    $script:Server = $server

    # Start UDP Discovery Server
    $udpWorker = $null
    if ($cfg.Server.EnableDiscovery) {
        $udpWorker = Start-UdpDiscoveryServer -Port $discPort -HttpPort $port -HostIp $hostIp
    }

    Write-Host ""
    Write-Host "==============================================================================" -ForegroundColor Green
    Write-Host "  LAN DYNAMIC WALLPAPER SLIDESHOW - HOST CONTROLLER" -ForegroundColor Green
    Write-Host "==============================================================================" -ForegroundColor Green
    Write-Host "  [WALLPAPERS FOLDER] DROP PHOTOS HERE TO ROTATE ON ALL PCs:" -ForegroundColor Yellow
    Write-Host "     $wallpapersDir" -ForegroundColor Cyan
    Write-Host "------------------------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "  [NETWORK]  Host IPv4 Address : $hostIp (Port: $port | Discovery: $discPort)" -ForegroundColor Green
    Write-Host "  [ROTATION] Synchronized Timer: $defaultInterval Seconds (Exact-second sync on all PCs)" -ForegroundColor Yellow
    Write-Host "  [ASSETS]   Published Assets  : $(if ($initialManifest) { $initialManifest.totalImages } else { 0 }) images ready on LAN" -ForegroundColor White
    Write-Host "------------------------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "  [HOW TO CONNECT CLIENT WORKSTATIONS OVER LAN]:" -ForegroundColor Yellow
    Write-Host "  Option A: On any client PC, double-click '2-Start-Client.bat'" -ForegroundColor White
    Write-Host "  Option B: Or open PowerShell on client PC and run 1-click command:" -ForegroundColor Cyan
    Write-Host "            irm http://$hostIp`:$port/setup | iex" -ForegroundColor Cyan
    Write-Host "==============================================================================" -ForegroundColor Green
    Write-Host ""

    # Synchronized Slideshow Loop for Host Desktop
    $lastAppliedSlot = [ref][int64]-1
    $localImageFiles = New-Object System.Collections.Generic.List[string]

    $refreshHostSlideshow = {
        $localImageFiles.Clear()
        if (Test-Path -LiteralPath $publishedDir) {
            $pFiles = Get-ChildItem -LiteralPath $publishedDir -File |
                Where-Object { $_.Name -ne "manifest.json" -and -not $_.Name.EndsWith(".pubtmp") -and -not $_.Name.EndsWith(".tmp") } |
                Sort-Object Name
            foreach ($pf in $pFiles) {
                $localImageFiles.Add($pf.FullName)
            }
        }
    }

    & $refreshHostSlideshow

    try {
        while ($script:Running) {
            # Synchronized exact-slot rotation for Host desktop
            if (-not $NoLocalSlideshow -and ([System.Management.Automation.PSTypeName]'Win32WallpaperEngine').Type) {
                try {
                    & $refreshHostSlideshow
                    if ($localImageFiles.Count -gt 0) {
                        $res = Step-SynchronizedWallpaperRotation -ImageFiles $localImageFiles `
                            -IntervalSeconds $defaultInterval `
                            -LastAppliedSlot $lastAppliedSlot

                        if ($null -ne $res) {
                            Write-HostLog "Desktop wallpaper synchronized: $([System.IO.Path]::GetFileName($res.Path)) (Slot: $($res.Slot))" -Level INFO
                        }
                    }
                } catch {
                    Write-HostLog "Desktop wallpaper warning: $($_.Exception.Message)" -Level WARN
                }
            }

            Start-Sleep -Milliseconds 500
        }
    }
    finally {
        Write-HostLog "Host server shutting down..." -Level INFO
        Stop-WallpaperWatcher
        if ($null -ne $script:Server) {
            $script:Server.Stop()
        }
        if ($null -ne $udpWorker) {
            $udpWorker.PowerShell.Stop()
            $udpWorker.PowerShell.Dispose()
            $udpWorker.Runspace.Close()
            $udpWorker.Runspace.Dispose()
        }
        if ($null -ne $script:HostMutex) {
            try { $script:HostMutex.ReleaseMutex() } catch {}
            $script:HostMutex.Dispose()
            $script:HostMutex = $null
        }
    }
}

# Run Host Server
Start-HostServer -ConfigFilePath $script:ConfigPath -PortOverride $Port -NoLocalSlideshow:$NoLocalSlideshow
