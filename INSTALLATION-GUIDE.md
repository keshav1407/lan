# 📖 LAN Dynamic Wallpaper: Installation & Deployment Guide

This guide details the complete deployment lifecycle for the LAN Dynamic Wallpaper Slideshow System across 1 Host Administrator PC and 30–100 Client Workstations on a local wired Ethernet LAN.

---

## 📋 System Prerequisites

### Host PC
- **Operating System**: Windows 11 (21H2 or newer) or Windows 10 (1809 or newer), Pro / Enterprise / Education / Home.
- **PowerShell**: Windows PowerShell 5.1 (built-in) or PowerShell 7.x.
- **Permissions**: Administrator privileges required on initial launch to bind the HTTP port, configure firewall rules, and register the URL ACL.
- **Network**: Static IPv4 address or DHCP reservation recommended on the wired Ethernet adapter.
- **Port Availability**:
  - `TCP 8765`: HTTP API and image streaming endpoint.
  - `UDP 8766`: Automated discovery responder.

### Client PCs (30–100 Workstations)
- **Operating System**: Windows 11 or Windows 10.
- **PowerShell**: Windows PowerShell 5.1 (built-in).
- **Permissions**: Standard User session permissions. **Does NOT require administrative rights to update the user's desktop wallpaper**.
- **Network**: Wired Ethernet connection on the same subnet as the Host (or routable LAN with static IP configuration).

---

## ⚡ Quick Run Architecture (Zero Administrator Required)

The system is streamlined into self-contained launchers that handle setup and execution completely automatically without requiring administrator rights:

1. **On Host PC**: Double-click **`1-Start-Host.bat`**
   - Runs instantly under standard user session (NO "Run as Administrator" needed).
   - Starts pure-socket TCP HTTP server on port `8765` and UDP Discovery on `8766`.
   - Opens the `Wallpapers/` drop folder in Windows Explorer.
   - Synchronously rotates Host desktop wallpaper in unison with all client PCs.

2. **On Client PCs**: Connect via either option (Zero manual setup):
   - **Option A (Batch File)**: Double-click **`2-Start-Client.bat`**.
   - **Option B (1-Line Command)**: Open PowerShell on any client PC and run:
     `irm http://<HOST_IP>:8765/setup | iex`
   - Client automatically discovers Host on LAN via UDP and subnet sweep.
   - Downloads all wallpapers and synchronizes the desktop background at the EXACT SAME SECOND as Host.
   - Automatically registers in user startup (`HKCU Run`) so it persists on future reboots.

3. **Automated Verification**: Double-click **`3-Test-System.bat`**
   - Executes all 5 enterprise verification suites (57 automated tests + 100-client load benchmark).

---

## 🖥️ Part 1: Host PC Setup & Slideshow Launch

### Step 1.1: Launch Host Controller
1. Double-click **`1-Start-Host.bat`**.
2. If prompted by Windows User Account Control (UAC), click **Yes** to allow Administrator privileges.
3. The host manager will execute:
   - **Network Port Check & Binding**: Binds HTTP service to port `8765` and UDP discovery to port `8766`.
   - **Firewall Configuration**: Adds scoped rules allowing inbound TCP 8765 and UDP 8766 on Private/Domain networks.
   - **URL ACL Reservation**: Adds `http://+:8765/` to HTTP.sys reservations for unrestricted LAN binding.
   - **Secret Initialization**: If `HostConfig.json` lacks an `AuthSecret`, generates a secure 256-bit cryptographic secret and saves it with restricted ACLs.
   - **Folder Access**: Automatically creates and opens the `Wallpapers/` folder on your screen.

### Step 1.2: Host Console Status
Upon launch, the Host PC console displays:
```
==============================================================================
  LAN DYNAMIC WALLPAPER SLIDESHOW - HOST MANAGER & SERVER
==============================================================================
  [WALLPAPERS FOLDER] UPLOAD / DROP YOUR PHOTOS & VIDEOS HERE:
     C:\Users\...\LAN-Dynamic-Wallpaper\Wallpapers
------------------------------------------------------------------------------
  [FORMATS]  Supported : JPG, PNG, BMP, GIF, WEBP, HEIC, TIFF, MP4, MOV, WMV
  [TIMER]    Slideshow : 5 SECONDS (Rotates Host & Clients every 5s)
  [CAPACITY] Max Fleet : Up to 10,000 photos (100 MB per file limit)
  [NETWORK]  Host IPv4 : 192.168.31.20 (HTTP: 8765 | UDP Discovery: 8766)
  [SECURITY] Client Token: a8f9... (Saved in HostConfig.json)
  [PUBLISHED] Active   : 12 assets ready on LAN
==============================================================================
```
Keep this window open or minimized while the slideshow is active.

---

## 🖼️ Part 2: Dynamic Wallpaper Management

Managing wallpapers is completely dynamic and requires zero server restarts:

### Adding New Wallpapers
1. Copy any image or video file into the `Wallpapers/` folder on the Host PC.
2. The background `Publisher.ps1` file watcher automatically:
   - Validates that the file copy is complete and unlocked.
   - Inspects binary magic numbers (rejecting fake or disguised files).
   - Computes the SHA-256 cryptographic hash.
   - Generates an updated `Wallpapers\manifest.json` with a new `collectionVersion`.
3. All client computers detect the new collection on their next check (within 10 seconds) and download the new wallpaper automatically.

### Replacing an Existing Wallpaper
1. Overwrite an existing image in `Wallpapers/` with a new file using the same filename.
2. The publisher detects the modified SHA-256 hash, increments the collection version, and clients update seamlessly.

### Deleting a Wallpaper
1. Delete the file from `Wallpapers/`.
2. The publisher updates the manifest, clients prune the deleted file from their local cache, and advance smoothly to the next image.

---

## 💻 Part 3: Client PC Deployment (30–100 PCs)

### Deployment Method A: Manual / USB Drive / Network Share
1. Copy the `LAN-Dynamic-Wallpaper` folder (or outer folder with batch files) to the client machine via USB or LAN share.
2. Double-click **`2-Start-Client.bat`**.
3. The client agent will:
   - Discover the Host PC IP automatically via UDP broadcast or subnet sweep.
   - If the Host requires authentication and this is a first-time connection from a new PC, enter the `Client Token` displayed on the Host console.
   - Synchronize all wallpapers into `Cache/`.
   - Apply the initial desktop wallpaper via Win32 `SystemParametersInfoW`.
   - Register auto-start at Windows user logon in `HKCU:\Software\Microsoft\Windows\CurrentVersion\Run`.

### Deployment Method B: Centralized Enterprise Distribution
For large computer labs or Active Directory domains:
1. Place the repository folder on a read-only network share: `\\Server\Share\LAN-Dynamic-Wallpaper`.
2. Create a Group Policy Logon Script or shortcut executing:
   ```cmd
   powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "\\Server\Share\LAN-Dynamic-Wallpaper\Client\Client.ps1"
   ```
3. Because the client requires zero administrative rights, it runs smoothly in all interactive student/employee sessions.

---

## 🧪 Part 4: Automated Verification & Testing

To verify the system end-to-end at any time, run:
```cmd
3-Test-System.bat
```
This executes all 5 automated test suites:
- **Suite 1: Publisher Engine** — Tests file copy locks, magic-byte validation, format conversion, SHA-256 hashing, and atomic manifest publishing.
- **Suite 2: Client Engine** — Tests Win32 P/Invoke desktop wallpaper application, deterministic rotation cycling, cache reconciliation, and single-instance mutex locks.
- **Suite 3: Host Server & RBAC** — Tests HTTP listener, health probes, client registration, authenticated manifest delivery, binary asset streaming, and heartbeat telemetry.
- **Suite 4: Security Penetration** — Tests path traversal attacks (`..`, `%2e%2e`, `/`), authentication bypass, privilege escalation, and zero-information leakage.
- **Suite 5: 100-Client Concurrency Load Benchmark** — Simulates 100 concurrent client nodes issuing 400 requests simultaneously to prove fleet stability and throughput.

---

## 🔒 Part 5: Security Architecture

- **Zero Hardcoded Secrets**: Secrets are never hardcoded in git-tracked code or batch scripts.
- **Cryptographic Authentication**: Every manifest and wallpaper request requires the 256-bit `X-Auth-Token`.
- **Strict Path Traversal Protection**: Request URIs are canonicalized and verified to reside strictly inside `Wallpapers/`.
- **Session-Scoped Mutex**: Prevents duplicate client processes per user desktop session (`Local\LAN_Dynamic_Wallpaper_Client_$userSid`).
- **Zero Remote Execution**: Downloaded content is strictly handled as binary images; no remote scripts or commands are ever executed.
