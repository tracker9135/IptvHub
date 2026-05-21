# IPTV Hub — Quick Start Guide

Get IPTV Hub running and connected to your media player in minutes.

---

## Step 1 — Install

### Option A: Installer (recommended)

**Prerequisites:** [Inno Setup 5](https://jrsoftware.org/isdl.php), .NET 8 SDK, Node.js

**1. Build the release artefacts:**

```powershell
# From the repo root — builds the frontend then publishes the backend
.\installer\build-installer.ps1
```

This script:
- Runs `npm run build` in `src\IptvHub.Web` (outputs to `src\IptvHub.Service\wwwroot`)
- Publishes a self-contained win-x64 backend to `installer\publish`
- Compiles `installer\IptvHub.iss` with Inno Setup 5 (`ISCC.exe`)
- Produces **`installer\IptvHubSetup-1.0.2.exe`**

**2. Run the installer** (`IptvHubSetup-1.0.2.exe`) as Administrator and follow the prompts:

| Installer option | Recommendation |
|---|---|
| **Add Windows Firewall rule (port 8080)** | Check — required for players on other devices |
| **Start service after installation** | Check — starts IPTV Hub immediately |
| **Create desktop icon** | Optional |

The installer registers IPTV Hub as a Windows Service (auto-start) and installs to `C:\Program Files\IptvHub` by default. After installation it offers to open the management UI automatically.

Open the management UI at **http://localhost:5000**.

### Option B: Run from source (development)

**Requirements:** [.NET 8 Runtime](https://dotnet.microsoft.com/download/dotnet/8.0), Node.js

Open two terminals:

**Terminal 1 — Backend:**
```
cd src\IptvHub.Service
dotnet run
```

**Terminal 2 — Frontend:**
```
cd src\IptvHub.Web
npm install
npm run dev
```

Open the management UI at **http://localhost:5173**.

---

## Step 2 — Add a Source

A **source** is an upstream IPTV provider. Go to **Sources → Add Source** and choose your provider type:

| Type | What you need |
|---|---|
| **M3U Playlist** | A `.m3u` or `.m3u8` URL (and optionally an XMLTV EPG URL) |
| **Xtream Codes** | Base URL, username, and password from your provider |
| **Plex** | Your Plex server URL and API token, then click **Browse Libraries** |
| **Enigma2** | Your receiver's web-interface URL, then click **Browse Bouquets** |
| **YouTube** | YouTube channel, stream, or video URLs |
| **M3U Collection** | Multiple M3U URLs merged into one source |

Click **Save**, then click the **test tube icon** next to the source to verify it is reachable.

---

## Step 3 — Create a Server

Go to **Servers → Add Server** and fill in:

| Field | Typical value |
|---|---|
| **Name** | e.g. `My IPTV Server` |
| **Bind Address** | `0.0.0.0` — accept connections from any device on the network |
| **Port** | e.g. `8080` — each server must use a unique port |
| **Enable EPG** | On — if your source has EPG data |
| **Xtream API** | On — required for Tivimate, IPTV Smarters, and similar players |
| **Stream Proxy** | Off (default) — redirect players directly to the upstream stream |

Click **Save**, then **Edit** the server to assign the source you added in Step 2.

---

## Step 4 — Start the Server

On the **Servers** page, click **▶ Start** on your server card.

The status badge turns **🟢 Running** once content has been fetched from your sources. This may take a few seconds to a minute depending on the source size.

---

## Step 5 — Connect Your Media Player

Replace `<host>` with your machine's IP address (or `localhost` for local players) and `<port>` with the port you chose.

If you did not add any users to the server, credentials are not required — use any values or omit them.

### Tivimate / IPTV Smarters / GSE Smart IPTV

Use **Xtream Codes** login:

| Field | Value |
|---|---|
| Server / Host | `http://<host>:<port>` |
| Username | *(your user, or any value if no users configured)* |
| Password | *(your password, or any value if no users configured)* |

Set your EPG source URL to:
```
http://<host>:<port>/xmltv.php?username=<user>&password=<pass>
```

### VLC / Kodi / any M3U player

Use the **M3U playlist URL**:
```
http://<host>:<port>/get.php?username=<user>&password=<pass>&type=m3u_plus&output=ts
```

For Kodi, install the **PVR IPTV Simple Client** add-on and paste the M3U URL into its settings. Add the XMLTV URL for EPG.

---

## Firewall (if players on other devices cannot connect)

The installer adds a firewall rule for port 8080 automatically if you left the **Add Windows Firewall rule** option checked. If you skipped it, or if you use a different port, add a rule manually:

```powershell
New-NetFirewallRule -DisplayName "IPTV Hub" -Direction Inbound -Protocol TCP -LocalPort 8080 -Action Allow
```

Change `8080` to match your server's port.

---

## What's next?

| Task | Where |
|---|---|
| Add more sources or servers | **Sources** / **Servers** pages |
| Add users and set connection limits | **Servers → Edit → Users** |
| Monitor channel live/dead status | **Dashboard** |
| Force an immediate content refresh | **Servers → ↺ Refresh** |
| View logs and errors | **Logs** page |
| Detailed configuration reference | [UserGuide_IptvHub.md](UserGuide_IptvHub.md) |
