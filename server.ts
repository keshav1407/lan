import express, { Request, Response } from "express";
import path from "node:path";
import fs from "node:fs/promises";
import fsSync from "node:fs";
import os from "node:os";
import { exec } from "node:child_process";
import multer from "multer";

const app = express();
const PORT = parseInt(process.env.PORT || "3000", 10);
const HOST = process.env.HOST || "0.0.0.0";

// Determine wallpaper directory (checks Wallpapers folder first, falls back to public)
const WALLPAPERS_DIR = path.resolve(process.cwd(), "Wallpapers");
const PUBLIC_DIR = process.env.WALLPAPERS_DIR
  ? path.resolve(process.env.WALLPAPERS_DIR)
  : fsSync.existsSync(WALLPAPERS_DIR)
  ? WALLPAPERS_DIR
  : path.resolve(process.cwd(), "public");

// Ensure directory exists on startup
if (!fsSync.existsSync(PUBLIC_DIR)) {
  fsSync.mkdirSync(PUBLIC_DIR, { recursive: true });
}

const IMAGE_EXTENSIONS = /\.(jpg|jpeg|png|gif|webp|avif|bmp|svg)$/i;

// State management
let currentImage: string | null = null;
let slideshowActive = false;
let slideshowIntervalMs = 5000;
let slideshowTimer: NodeJS.Timeout | null = null;
let syncWindowsDesktop = process.platform === "win32";

// Connected SSE clients (Display screens and Controller panels)
const clients = new Set<Response>();

app.disable("x-powered-by");
app.use(express.json({ limit: "2mb" }));

// Prevent browser caching of dynamic API responses and viewer pages
app.use((_req, res, next) => {
  res.setHeader("Cache-Control", "no-store, no-cache, must-revalidate");
  next();
});

// Configure Multer for wallpaper uploads
const storage = multer.diskStorage({
  destination: (_req, _file, cb) => {
    cb(null, PUBLIC_DIR);
  },
  filename: (_req, file, cb) => {
    // Sanitize filename to avoid path traversal
    const safeName = path.basename(file.originalname).replace(/[^a-zA-Z0-9._ -]/g, "_");
    cb(null, safeName);
  },
});

const upload = multer({
  storage,
  limits: { fileSize: 50 * 1024 * 1024 }, // 50MB per file
  fileFilter: (_req, file, cb) => {
    if (IMAGE_EXTENSIONS.test(path.extname(file.originalname))) {
      cb(null, true);
    } else {
      cb(new Error("Only image files are allowed (JPG, PNG, GIF, WEBP, BMP, SVG)."));
    }
  },
});

// Helper: Discover local network IPv4 addresses
function getNetworkIps(): string[] {
  const interfaces = os.networkInterfaces();
  const ips: string[] = [];
  for (const name of Object.keys(interfaces)) {
    for (const iface of interfaces[name] || []) {
      if (iface.family === "IPv4" && !iface.internal) {
        ips.push(iface.address);
      }
    }
  }
  return ips;
}

// Read available images directly from the wallpaper folder
async function getImages(): Promise<string[]> {
  try {
    const entries = await fs.readdir(PUBLIC_DIR, { withFileTypes: true });
    return entries
      .filter((entry) => entry.isFile() && IMAGE_EXTENSIONS.test(entry.name))
      .map((entry) => entry.name)
      .sort((a, b) => a.localeCompare(b));
  } catch (error) {
    console.error("Could not read wallpapers directory:", error);
    return [];
  }
}

function imageUrl(filename: string): string {
  return "/images/" + encodeURIComponent(filename);
}

// Serve images statically with fallback to allow 404 handling
app.use(
  "/images",
  express.static(PUBLIC_DIR, {
    index: false,
    dotfiles: "deny",
    fallthrough: true,
  })
);

// Optional: Apply desktop wallpaper to host Windows PC
function setHostWindowsWallpaper(filename: string): void {
  if (!syncWindowsDesktop || process.platform !== "win32") return;
  const fullPath = path.resolve(PUBLIC_DIR, filename);
  const clientScript = path.resolve(process.cwd(), "Client", "Wallpaper.ps1");

  if (fsSync.existsSync(clientScript)) {
    const script = `& { param([string]$p) . '${clientScript.replace(/'/g, "''")}'; Set-DesktopWallpaper -ImagePath $p } '${fullPath.replace(/'/g, "''")}'`;
    exec(`powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "${script}"`, (err) => {
      if (err) {
        console.warn("Could not set Windows desktop wallpaper:", err.message);
      }
    });
  }
}

// Broadcast current state to all connected SSE clients
function broadcastState(eventType: string = "image"): void {
  const payload = JSON.stringify({
    type: eventType,
    filename: currentImage,
    url: currentImage ? imageUrl(currentImage) : null,
    slideshow: {
      active: slideshowActive,
      interval: slideshowIntervalMs,
    },
    clientCount: clients.size,
    timestamp: Date.now(),
  });

  const message = `data: ${payload}\n\n`;

  for (const client of Array.from(clients)) {
    try {
      client.write(message);
    } catch {
      clients.delete(client);
    }
  }
}

// Slideshow management
async function advanceSlideshow(): Promise<void> {
  const images = await getImages();
  if (images.length === 0) return;

  let nextIndex = 0;
  if (currentImage) {
    const currentIndex = images.indexOf(currentImage);
    if (currentIndex >= 0) {
      nextIndex = (currentIndex + 1) % images.length;
    }
  }

  currentImage = images[nextIndex];
  setHostWindowsWallpaper(currentImage);
  broadcastState("image");
}

function startSlideshow(intervalMs: number): void {
  stopSlideshow();
  slideshowActive = true;
  slideshowIntervalMs = Math.max(1000, intervalMs);
  slideshowTimer = setInterval(advanceSlideshow, slideshowIntervalMs);
  broadcastState("slideshow");
}

function stopSlideshow(): void {
  slideshowActive = false;
  if (slideshowTimer) {
    clearInterval(slideshowTimer);
    slideshowTimer = null;
  }
  broadcastState("slideshow");
}

// ==========================================
// REST APIs
// ==========================================

// API: List wallpapers, selection & slideshow status
app.get("/api/images", async (_req, res) => {
  try {
    const images = await getImages();

    // Auto-select first image if none currently selected
    if (!currentImage && images.length > 0) {
      currentImage = images[0];
    }

    res.json({
      images,
      currentImage,
      slideshow: {
        active: slideshowActive,
        interval: slideshowIntervalMs,
      },
      clientCount: clients.size,
      syncWindowsDesktop,
      directory: PUBLIC_DIR,
    });
  } catch (error) {
    res.status(500).json({ error: "Could not read wallpaper directory." });
  }
});

// API: Select an image for every connected display
app.post("/api/select", async (req, res) => {
  try {
    const filename = req.body?.filename;

    if (typeof filename !== "string" || !filename.trim()) {
      res.status(400).json({ error: "Select a valid image." });
      return;
    }

    const images = await getImages();
    if (!images.includes(filename)) {
      res.status(400).json({
        error: "Image not found. Refresh the image list and try again.",
      });
      return;
    }

    currentImage = filename;
    setHostWindowsWallpaper(currentImage);
    broadcastState("image");

    res.json({
      success: true,
      currentImage,
      url: imageUrl(currentImage),
    });
  } catch (error) {
    res.status(500).json({ error: "Could not select the image." });
  }
});

// API: Toggle or configure Auto-Slideshow
app.post("/api/slideshow", (req, res) => {
  try {
    const { active, interval } = req.body;

    if (active === true) {
      const intervalMs = typeof interval === "number" ? interval : slideshowIntervalMs;
      startSlideshow(intervalMs);
    } else {
      stopSlideshow();
    }

    res.json({
      success: true,
      slideshow: {
        active: slideshowActive,
        interval: slideshowIntervalMs,
      },
    });
  } catch (error) {
    res.status(500).json({ error: "Failed to update slideshow settings." });
  }
});

// API: Upload new wallpapers
app.post("/api/upload", upload.array("wallpapers", 20), async (req, res) => {
  try {
    const files = req.files as Express.Multer.File[];
    if (!files || files.length === 0) {
      res.status(400).json({ error: "No image files uploaded." });
      return;
    }

    const uploadedNames = files.map((f) => f.filename);

    // If no image is currently selected, select the first uploaded image
    if (!currentImage && uploadedNames.length > 0) {
      currentImage = uploadedNames[0];
      setHostWindowsWallpaper(currentImage);
    }

    broadcastState("library");

    res.json({
      success: true,
      uploaded: uploadedNames,
      currentImage,
    });
  } catch (error: any) {
    res.status(500).json({ error: error.message || "Failed to upload image." });
  }
});

// API: Delete a wallpaper
app.delete("/api/images/:filename", async (req, res) => {
  try {
    const rawFilename = req.params.filename;
    const safeFilename = path.basename(rawFilename);
    const filePath = path.join(PUBLIC_DIR, safeFilename);

    if (!fsSync.existsSync(filePath)) {
      res.status(404).json({ error: "File not found." });
      return;
    }

    await fs.unlink(filePath);

    // If deleted image was active, select next available image
    if (currentImage === safeFilename) {
      const remaining = await getImages();
      currentImage = remaining.length > 0 ? remaining[0] : null;
      if (currentImage) setHostWindowsWallpaper(currentImage);
    }

    broadcastState("library");

    res.json({
      success: true,
      deleted: safeFilename,
      currentImage,
    });
  } catch (error) {
    res.status(500).json({ error: "Could not delete wallpaper." });
  }
});

// API: Toggle Windows Desktop Wallpaper synchronization
app.post("/api/sync-desktop", (req, res) => {
  if (typeof req.body.enabled === "boolean") {
    syncWindowsDesktop = req.body.enabled && process.platform === "win32";
    if (syncWindowsDesktop && currentImage) {
      setHostWindowsWallpaper(currentImage);
    }
  }
  res.json({ success: true, syncWindowsDesktop });
});

// Real-time SSE connection for Display screens and Controllers
app.get("/events", (req, res) => {
  res.setHeader("Content-Type", "text/event-stream");
  res.setHeader("Cache-Control", "no-cache, no-transform");
  res.setHeader("Connection", "keep-alive");
  res.setHeader("X-Accel-Buffering", "no");
  res.flushHeaders();

  clients.add(res);

  // Send immediate state payload
  const initialPayload = JSON.stringify({
    type: "init",
    filename: currentImage,
    url: currentImage ? imageUrl(currentImage) : null,
    slideshow: {
      active: slideshowActive,
      interval: slideshowIntervalMs,
    },
    clientCount: clients.size,
    timestamp: Date.now(),
  });
  res.write(`data: ${initialPayload}\n\n`);

  // Heartbeat ping every 20 seconds to keep connection alive through NAT / routers
  const heartbeat = setInterval(() => {
    try {
      res.write(": heartbeat\n\n");
    } catch {
      clearInterval(heartbeat);
      clients.delete(res);
    }
  }, 20000);

  const cleanup = () => {
    clearInterval(heartbeat);
    clients.delete(res);
    broadcastState("clients");
  };

  req.on("close", cleanup);
  req.on("error", cleanup);
  res.on("error", cleanup);

  // Notify controllers of new client count
  broadcastState("clients");
});

// ==========================================
// Frontend: Display Page (/)
// ==========================================
app.get("/", (_req, res) => {
  res.type("html").send(`<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>LAN Dynamic Wallpaper - Display</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    html, body {
      width: 100%;
      height: 100%;
      overflow: hidden;
      background: #000;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    }
    #stage {
      position: relative;
      width: 100%;
      height: 100%;
    }
    .displayImage {
      position: absolute;
      top: 0;
      left: 0;
      width: 100%;
      height: 100%;
      object-fit: contain;
      object-position: center;
      opacity: 0;
      transition: opacity 0.6s cubic-bezier(0.4, 0, 0.2, 1);
    }
    .displayImage.active {
      opacity: 1;
    }
    .displayImage.cover {
      object-fit: cover;
    }
    #hud {
      position: fixed;
      top: 16px;
      right: 16px;
      display: flex;
      align-items: center;
      gap: 8px;
      padding: 8px 14px;
      border-radius: 9999px;
      background: rgba(17, 24, 39, 0.75);
      backdrop-filter: blur(8px);
      border: 1px solid rgba(255, 255, 255, 0.15);
      color: #f3f4f6;
      font-size: 13px;
      z-index: 50;
      opacity: 0;
      pointer-events: none;
      transition: opacity 0.3s ease;
    }
    #hud.visible {
      opacity: 1;
      pointer-events: auto;
    }
    .status-dot {
      width: 8px;
      height: 8px;
      border-radius: 50%;
      background: #10b981;
    }
    .status-dot.reconnecting {
      background: #f59e0b;
      animation: pulse 1.5s infinite;
    }
    @keyframes pulse {
      0%, 100% { opacity: 1; transform: scale(1); }
      50% { opacity: 0.4; transform: scale(0.85); }
    }
    #emptyState {
      position: absolute;
      inset: 0;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      color: #9ca3af;
      text-align: center;
      padding: 24px;
      z-index: 10;
    }
    #emptyState h2 {
      font-size: 24px;
      color: #fff;
      margin-bottom: 8px;
    }
    #emptyState p {
      font-size: 15px;
      max-width: 440px;
      line-height: 1.5;
    }
    #fullscreenTip {
      position: fixed;
      bottom: 16px;
      left: 50%;
      transform: translateX(-50%);
      font-size: 12px;
      color: rgba(255, 255, 255, 0.4);
      padding: 6px 12px;
      background: rgba(0, 0, 0, 0.5);
      border-radius: 20px;
      opacity: 0;
      transition: opacity 0.4s ease;
      pointer-events: none;
      z-index: 40;
    }
    body:hover #fullscreenTip {
      opacity: 1;
    }
  </style>
</head>
<body>
  <div id="hud">
    <span class="status-dot" id="statusDot"></span>
    <span id="statusText">Connected</span>
  </div>

  <div id="stage">
    <div id="emptyState">
      <h2>LAN Dynamic Wallpaper</h2>
      <p id="emptyMsg">Waiting for an image selection from the Controller...</p>
    </div>
    <img id="imgA" class="displayImage" alt="Wallpaper">
    <img id="imgB" class="displayImage" alt="Wallpaper">
  </div>

  <div id="fullscreenTip">Press 'F' for Fullscreen | 'C' to Toggle Fit/Cover</div>

  <script>
    const imgA = document.getElementById("imgA");
    const imgB = document.getElementById("imgB");
    const hud = document.getElementById("hud");
    const statusDot = document.getElementById("statusDot");
    const statusText = document.getElementById("statusText");
    const emptyState = document.getElementById("emptyState");

    let activeSlot = "A";
    let currentShownUrl = "";
    let isCover = false;
    let hudTimeout = null;

    function showHud(text, state = "normal", autoHide = true) {
      statusText.textContent = text;
      statusDot.className = "status-dot" + (state === "warn" ? " reconnecting" : "");
      hud.classList.add("visible");

      if (hudTimeout) clearTimeout(hudTimeout);
      if (autoHide && state === "normal") {
        hudTimeout = setTimeout(() => hud.classList.remove("visible"), 3000);
      }
    }

    function switchWallpaper(url) {
      if (!url) {
        emptyState.style.display = "flex";
        imgA.classList.remove("active");
        imgB.classList.remove("active");
        currentShownUrl = "";
        return;
      }

      if (url === currentShownUrl) return;

      emptyState.style.display = "none";
      const targetImg = activeSlot === "A" ? imgB : imgA;
      const outgoingImg = activeSlot === "A" ? imgA : imgB;

      targetImg.onload = () => {
        targetImg.classList.add("active");
        outgoingImg.classList.remove("active");
        activeSlot = activeSlot === "A" ? "B" : "A";
        currentShownUrl = url;
      };

      // Add cache buster to guarantee fresh asset load
      targetImg.src = url + "?t=" + Date.now();
    }

    function connect() {
      const events = new EventSource("/events");

      events.onopen = () => {
        showHud("Connected", "normal", true);
      };

      events.onmessage = (event) => {
        try {
          const data = JSON.parse(event.data);
          if (data.url !== undefined) {
            switchWallpaper(data.url);
          }
        } catch (e) {
          console.error("Invalid event data:", e);
        }
      };

      events.onerror = () => {
        showHud("Reconnecting...", "warn", false);
      };
    }

    // Toggle Fit (contain) vs Fill (cover)
    window.addEventListener("keydown", (e) => {
      if (e.key === "f" || e.key === "F") {
        if (!document.fullscreenElement) {
          document.documentElement.requestFullscreen().catch(() => {});
        } else {
          document.exitFullscreen().catch(() => {});
        }
      }
      if (e.key === "c" || e.key === "C") {
        isCover = !isCover;
        imgA.classList.toggle("cover", isCover);
        imgB.classList.toggle("cover", isCover);
        showHud(isCover ? "Mode: Fill Screen" : "Mode: Fit (Letterbox)", "normal", true);
      }
    });

    // Double-click to toggle fullscreen
    document.addEventListener("dblclick", () => {
      if (!document.fullscreenElement) {
        document.documentElement.requestFullscreen().catch(() => {});
      } else {
        document.exitFullscreen().catch(() => {});
      }
    });

    connect();
  </script>
</body>
</html>`);
});

// ==========================================
// Frontend: Controller Page (/control)
// ==========================================
app.get("/control", (_req, res) => {
  res.type("html").send(`<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>LAN Dynamic Wallpaper - Controller</title>
  <style>
    :root {
      --primary: #2563eb;
      --primary-hover: #1d4ed8;
      --success: #16a34a;
      --danger: #dc2626;
      --bg: #f8fafc;
      --card-bg: #ffffff;
      --text: #0f172a;
      --text-muted: #64748b;
      --border: #e2e8f0;
    }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      background: var(--bg);
      color: var(--text);
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
      padding: 24px;
      line-height: 1.5;
    }
    .container {
      max-width: 1040px;
      margin: 0 auto;
    }
    header {
      display: flex;
      flex-wrap: wrap;
      align-items: center;
      justify-content: space-between;
      gap: 16px;
      margin-bottom: 24px;
      padding-bottom: 20px;
      border-bottom: 1px solid var(--border);
    }
    .title-group h1 {
      font-size: 26px;
      font-weight: 700;
      color: #0f172a;
    }
    .title-group p {
      color: var(--text-muted);
      font-size: 14px;
      margin-top: 4px;
    }
    .badge-bar {
      display: flex;
      align-items: center;
      gap: 10px;
    }
    .badge {
      display: inline-flex;
      align-items: center;
      gap: 6px;
      padding: 6px 12px;
      background: #e0f2fe;
      color: #0369a1;
      border-radius: 9999px;
      font-size: 13px;
      font-weight: 500;
    }
    .badge.green {
      background: #dcfce7;
      color: #15803d;
    }
    .btn-link {
      display: inline-flex;
      align-items: center;
      gap: 6px;
      padding: 7px 14px;
      background: #ffffff;
      border: 1px solid var(--border);
      border-radius: 8px;
      color: var(--text);
      text-decoration: none;
      font-size: 13px;
      font-weight: 500;
      transition: all 0.2s;
    }
    .btn-link:hover {
      background: #f1f5f9;
      border-color: #cbd5e1;
    }

    /* Control Panel Card */
    .panel {
      background: var(--card-bg);
      border: 1px solid var(--border);
      border-radius: 12px;
      padding: 20px;
      margin-bottom: 24px;
      box-shadow: 0 1px 3px rgba(0,0,0,0.05);
    }
    .toolbar {
      display: flex;
      flex-wrap: wrap;
      align-items: center;
      justify-content: space-between;
      gap: 16px;
    }
    .toolbar-left, .toolbar-right {
      display: flex;
      flex-wrap: wrap;
      align-items: center;
      gap: 12px;
    }
    .btn {
      display: inline-flex;
      align-items: center;
      gap: 8px;
      padding: 9px 16px;
      background: var(--primary);
      color: #fff;
      border: none;
      border-radius: 8px;
      font-size: 14px;
      font-weight: 600;
      cursor: pointer;
      transition: background 0.2s, transform 0.1s;
    }
    .btn:hover { background: var(--primary-hover); }
    .btn:active { transform: translateY(1px); }
    .btn.secondary {
      background: #e2e8f0;
      color: #334155;
    }
    .btn.secondary:hover { background: #cbd5e1; }
    .btn.success {
      background: var(--success);
    }
    .btn.success:hover { background: #15803d; }
    .select-wrap {
      display: flex;
      align-items: center;
      gap: 8px;
      font-size: 14px;
      color: var(--text-muted);
    }
    select {
      padding: 8px 12px;
      border-radius: 8px;
      border: 1px solid var(--border);
      background: #fff;
      font-size: 14px;
      color: var(--text);
      outline: none;
      cursor: pointer;
    }
    .toggle-wrap {
      display: flex;
      align-items: center;
      gap: 8px;
      font-size: 14px;
      color: var(--text-muted);
      cursor: pointer;
      user-select: none;
    }

    /* Upload Dropzone */
    .dropzone {
      border: 2px dashed var(--border);
      border-radius: 10px;
      padding: 20px;
      text-align: center;
      background: #fdfdfd;
      cursor: pointer;
      margin-top: 16px;
      transition: border-color 0.2s, background 0.2s;
    }
    .dropzone.dragover {
      border-color: var(--primary);
      background: #eff6ff;
    }
    .dropzone p {
      font-size: 14px;
      color: var(--text-muted);
    }
    .dropzone span {
      color: var(--primary);
      font-weight: 600;
      text-decoration: underline;
    }
    #fileInput { display: none; }

    /* Gallery */
    .gallery-header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      margin-bottom: 14px;
    }
    .gallery-header h2 {
      font-size: 18px;
      font-weight: 700;
    }
    #statusLine {
      font-size: 14px;
      color: var(--text-muted);
    }
    .gallery-grid {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(210px, 1fr));
      gap: 18px;
    }
    .card {
      position: relative;
      background: #fff;
      border: 2px solid var(--border);
      border-radius: 12px;
      overflow: hidden;
      cursor: pointer;
      display: flex;
      flex-direction: column;
      transition: all 0.2s cubic-bezier(0.4, 0, 0.2, 1);
    }
    .card:hover {
      border-color: #94a3b8;
      box-shadow: 0 4px 12px rgba(0,0,0,0.08);
      transform: translateY(-2px);
    }
    .card.selected {
      border-color: var(--success);
      box-shadow: 0 0 0 3px rgba(22, 163, 74, 0.2), 0 4px 12px rgba(0,0,0,0.08);
    }
    .thumb-wrap {
      width: 100%;
      height: 140px;
      background: #0f172a;
      display: flex;
      align-items: center;
      justify-content: center;
      overflow: hidden;
      position: relative;
    }
    .thumb-wrap img {
      width: 100%;
      height: 100%;
      object-fit: cover;
      transition: transform 0.3s;
    }
    .card:hover .thumb-wrap img {
      transform: scale(1.05);
    }
    .live-badge {
      position: absolute;
      top: 8px;
      left: 8px;
      background: var(--success);
      color: #fff;
      font-size: 11px;
      font-weight: 700;
      text-transform: uppercase;
      padding: 3px 8px;
      border-radius: 9999px;
      letter-spacing: 0.5px;
      display: none;
      box-shadow: 0 2px 4px rgba(0,0,0,0.2);
    }
    .card.selected .live-badge {
      display: block;
    }
    .delete-btn {
      position: absolute;
      top: 8px;
      right: 8px;
      width: 28px;
      height: 28px;
      border-radius: 50%;
      background: rgba(0,0,0,0.6);
      color: #fff;
      border: none;
      cursor: pointer;
      display: flex;
      align-items: center;
      justify-content: center;
      opacity: 0;
      transition: opacity 0.2s, background 0.2s;
    }
    .card:hover .delete-btn {
      opacity: 1;
    }
    .delete-btn:hover {
      background: var(--danger);
    }
    .card-meta {
      padding: 12px;
      flex: 1;
      display: flex;
      flex-direction: column;
      justify-content: space-between;
    }
    .card-title {
      font-size: 13px;
      font-weight: 600;
      color: var(--text);
      word-break: break-word;
      line-height: 1.4;
    }
  </style>
</head>
<body>
  <div class="container">
    <header>
      <div class="title-group">
        <h1>LAN Dynamic Wallpaper Controller</h1>
        <p>Broadcast synchronized wallpapers across all lab and office computer screens in real-time.</p>
      </div>
      <div class="badge-bar">
        <span class="badge green" id="clientBadge">● 0 Screens Connected</span>
        <a class="btn-link" href="/" target="_blank">📺 Open Display Screen ↗</a>
      </div>
    </header>

    <div class="panel">
      <div class="toolbar">
        <div class="toolbar-left">
          <button class="btn" id="slideshowBtn">▶ Start Auto-Slideshow</button>
          <div class="select-wrap">
            <label for="intervalSelect">Interval:</label>
            <select id="intervalSelect">
              <option value="3000">3 Seconds</option>
              <option value="5000" selected>5 Seconds</option>
              <option value="10000">10 Seconds</option>
              <option value="15000">15 Seconds</option>
              <option value="30000">30 Seconds</option>
              <option value="60000">60 Seconds</option>
            </select>
          </div>
        </div>

        <div class="toolbar-right">
          <label class="toggle-wrap">
            <input type="checkbox" id="syncDesktopCheck" checked>
            <span>Sync Host Windows Wallpaper</span>
          </label>
          <button class="btn secondary" id="refreshBtn">⟳ Refresh List</button>
        </div>
      </div>

      <!-- Upload Zone -->
      <div class="dropzone" id="dropzone">
        <p>Drag & drop photos here, or <span>browse from computer</span></p>
        <input type="file" id="fileInput" multiple accept="image/*">
      </div>
    </div>

    <div class="gallery-header">
      <h2>Wallpaper Gallery</h2>
      <div id="statusLine">Loading wallpapers...</div>
    </div>

    <div class="gallery-grid" id="gallery"></div>
  </div>

  <script>
    const gallery = document.getElementById("gallery");
    const statusLine = document.getElementById("statusLine");
    const clientBadge = document.getElementById("clientBadge");
    const slideshowBtn = document.getElementById("slideshowBtn");
    const intervalSelect = document.getElementById("intervalSelect");
    const syncDesktopCheck = document.getElementById("syncDesktopCheck");
    const refreshBtn = document.getElementById("refreshBtn");
    const dropzone = document.getElementById("dropzone");
    const fileInput = document.getElementById("fileInput");

    let images = [];
    let selectedImage = null;
    let slideshowActive = false;
    let renderedFilenames = "";

    async function loadData() {
      try {
        const res = await fetch("/api/images", { cache: "no-store" });
        if (!res.ok) throw new Error("Could not fetch wallpapers");
        const data = await res.json();

        images = data.images || [];
        selectedImage = data.currentImage;
        slideshowActive = data.slideshow?.active || false;
        if (data.slideshow?.interval) {
          intervalSelect.value = String(data.slideshow.interval);
        }
        if (typeof data.syncWindowsDesktop === "boolean") {
          syncDesktopCheck.checked = data.syncWindowsDesktop;
        }

        updateClientCount(data.clientCount || 0);
        updateSlideshowUI();
        renderGallery();
      } catch (err) {
        statusLine.textContent = "Error: " + err.message;
      }
    }

    function updateClientCount(count) {
      clientBadge.textContent = "● " + count + (count === 1 ? " Screen Connected" : " Screens Connected");
    }

    function updateSlideshowUI() {
      if (slideshowActive) {
        slideshowBtn.textContent = "⏸ Pause Auto-Slideshow";
        slideshowBtn.classList.add("success");
      } else {
        slideshowBtn.textContent = "▶ Start Auto-Slideshow";
        slideshowBtn.classList.remove("success");
      }
    }

    function renderGallery() {
      const signature = images.join("|");

      // If the list of files hasn't changed, just update selected class without DOM re-render!
      if (signature === renderedFilenames) {
        for (const card of gallery.querySelectorAll(".card")) {
          const fn = card.getAttribute("data-filename");
          card.classList.toggle("selected", fn === selectedImage);
        }
        statusLine.textContent = selectedImage ? "Currently displaying: " + selectedImage : "Choose an image above.";
        return;
      }

      renderedFilenames = signature;
      gallery.replaceChildren();

      if (images.length === 0) {
        statusLine.textContent = "No wallpapers found. Drop photos into the upload box above!";
        return;
      }

      statusLine.textContent = selectedImage ? "Currently displaying: " + selectedImage : "Choose an image above.";

      for (const filename of images) {
        const card = document.createElement("div");
        card.className = "card" + (filename === selectedImage ? " selected" : "");
        card.setAttribute("data-filename", filename);

        const thumbWrap = document.createElement("div");
        thumbWrap.className = "thumb-wrap";

        const img = document.createElement("img");
        img.src = "/images/" + encodeURIComponent(filename);
        img.alt = filename;
        img.loading = "lazy";

        const badge = document.createElement("span");
        badge.className = "live-badge";
        badge.textContent = "ACTIVE";

        const delBtn = document.createElement("button");
        delBtn.className = "delete-btn";
        delBtn.title = "Delete wallpaper";
        delBtn.innerHTML = "✕";
        delBtn.onclick = (e) => {
          e.stopPropagation();
          deleteWallpaper(filename);
        };

        thumbWrap.append(img, badge, delBtn);

        const meta = document.createElement("div");
        meta.className = "card-meta";
        const title = document.createElement("span");
        title.className = "card-title";
        title.textContent = filename;
        meta.append(title);

        card.append(thumbWrap, meta);
        card.onclick = () => selectWallpaper(filename);

        gallery.append(card);
      }
    }

    async function selectWallpaper(filename) {
      statusLine.textContent = "Switching displays to " + filename + "...";
      try {
        const res = await fetch("/api/select", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ filename })
        });
        const data = await res.json();
        if (!res.ok) throw new Error(data.error || "Selection failed");
        selectedImage = data.currentImage;
        renderGallery();
      } catch (err) {
        alert("Failed to select image: " + err.message);
      }
    }

    async function deleteWallpaper(filename) {
      if (!confirm("Are you sure you want to delete '" + filename + "'?")) return;
      try {
        const res = await fetch("/api/images/" + encodeURIComponent(filename), {
          method: "DELETE"
        });
        const data = await res.json();
        if (!res.ok) throw new Error(data.error || "Failed to delete");
        loadData();
      } catch (err) {
        alert("Could not delete wallpaper: " + err.message);
      }
    }

    // Toggle Auto Slideshow
    slideshowBtn.onclick = async () => {
      const nextActive = !slideshowActive;
      const interval = parseInt(intervalSelect.value, 10);
      try {
        const res = await fetch("/api/slideshow", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ active: nextActive, interval })
        });
        const data = await res.json();
        slideshowActive = data.slideshow.active;
        updateSlideshowUI();
      } catch (err) {
        alert("Failed to update slideshow: " + err.message);
      }
    };

    intervalSelect.onchange = () => {
      if (slideshowActive) {
        slideshowBtn.click(); // toggle off then on with new interval
        slideshowBtn.click();
      }
    };

    syncDesktopCheck.onchange = async () => {
      try {
        await fetch("/api/sync-desktop", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ enabled: syncDesktopCheck.checked })
        });
      } catch (err) {
        console.error("Failed to update desktop sync", err);
      }
    };

    refreshBtn.onclick = loadData;

    // Upload handling
    dropzone.onclick = () => fileInput.click();
    fileInput.onchange = () => uploadFiles(fileInput.files);

    dropzone.ondragover = (e) => {
      e.preventDefault();
      dropzone.classList.add("dragover");
    };
    dropzone.ondragleave = () => dropzone.classList.remove("dragover");
    dropzone.ondrop = (e) => {
      e.preventDefault();
      dropzone.classList.remove("dragover");
      if (e.dataTransfer.files?.length) {
        uploadFiles(e.dataTransfer.files);
      }
    };

    async function uploadFiles(fileList) {
      if (!fileList || fileList.length === 0) return;
      const formData = new FormData();
      for (const file of fileList) {
        formData.append("wallpapers", file);
      }
      statusLine.textContent = "Uploading " + fileList.length + " wallpaper(s)...";

      try {
        const res = await fetch("/api/upload", {
          method: "POST",
          body: formData
        });
        const data = await res.json();
        if (!res.ok) throw new Error(data.error || "Upload failed");
        fileInput.value = "";
        loadData();
      } catch (err) {
        alert("Upload failed: " + err.message);
        loadData();
      }
    }

    // Real-time synchronization with SSE
    const events = new EventSource("/events");
    events.onmessage = (event) => {
      try {
        const data = JSON.parse(event.data);
        if (data.clientCount !== undefined) {
          updateClientCount(data.clientCount);
        }
        if (data.slideshow) {
          slideshowActive = data.slideshow.active;
          updateSlideshowUI();
        }
        if (data.filename !== undefined) {
          selectedImage = data.filename;
          renderGallery();
        }
        if (data.type === "library") {
          loadData();
        }
      } catch (e) {
        console.error("SSE parse error:", e);
      }
    };

    loadData();
  </script>
</body>
</html>`);
});

// ==========================================
// Server Startup
// ==========================================
app.listen(PORT, HOST, async () => {
  const localIps = getNetworkIps();
  const images = await getImages();

  if (!currentImage && images.length > 0) {
    currentImage = images[0];
    setHostWindowsWallpaper(currentImage);
  }

  console.log("\n==================================================================");
  console.log("   LAN DYNAMIC WALLPAPER - WEB DISPLAY & CONTROLLER SERVER");
  console.log("==================================================================");
  console.log(`\n  * Wallpaper Folder: ${PUBLIC_DIR}`);
  console.log(`  * Loaded Images:    ${images.length} available`);
  console.log(`  * Host Desktop Sync: ${syncWindowsDesktop ? "Enabled (Windows Win32)" : "Disabled"}\n`);

  console.log("  Display Screen URLs (open on all client computers/screens):");
  console.log(`    Local:   http://localhost:${PORT}/`);
  for (const ip of localIps) {
    console.log(`    Network: http://${ip}:${PORT}/`);
  }

  console.log("\n  Controller URLs (open on host PC or admin mobile/tablet):");
  console.log(`    Local:   http://localhost:${PORT}/control`);
  for (const ip of localIps) {
    console.log(`    Network: http://${ip}:${PORT}/control`);
  }
  console.log("\n==================================================================\n");
});
