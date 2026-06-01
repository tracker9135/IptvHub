# IPTV Hub â€” Synology NAS Install Guide

This guide covers installing IPTV Hub on a Synology NAS using **Container Manager** (DSM 7.2 or later). It includes image transfer, container deployment, firewall setup, HTTPS reverse proxy, media server integration, and troubleshooting.

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Port planning](#2-port-planning)
3. [Step 1 â€” Prepare the Docker image](#step-1--prepare-the-docker-image)
4. [Step 2 â€” Create the data folders](#step-2--create-the-data-folders)
5. [Step 3 â€” Deploy the container](#step-3--deploy-the-container)
6. [Step 4 â€” Open the firewall](#step-4--open-the-firewall-port-if-applicable)
7. [Step 5 â€” Access the Management UI](#step-5--access-the-management-ui)
8. [Step 6 â€” First-time setup](#step-6--first-time-setup)
9. [Updating IPTV Hub](#updating-iptv-hub)
10. [Persistence and Backup](#persistence--backup)
11. [Adding more IPTV streaming servers](#adding-more-iptv-streaming-servers)
12. [Reverse proxy (HTTPS)](#reverse-proxy-https-access-via-application-portal)
13. [Remote access via Synology DDNS](#remote-access-via-synology-ddns)
14. [Media server integration](#media-server-integration)
15. [Resource limits and performance](#resource-limits-and-performance)
16. [Troubleshooting](#troubleshooting)

---

## 1. Prerequisites

### DSM version

Go to **DSM main menu (top-left) â†’ Control Panel â†’ Info Center**. The **DSM version** is shown on the General tab.

You need **DSM 7.2 or later**. Earlier versions have an older version of Container Manager (formerly called Docker) that may not support all compose features.

### NAS architecture

IPTV Hub requires an **x86_64 (amd64)** NAS. Most Synology units from 2017 onwards with an Intel Celeron or Core processor qualify. ARM-based models (most J-series and some entry-level models) are **not supported**.

To verify your NAS architecture:

1. Open a browser and go to:  
   `https://www.synology.com/en-us/compatibility?search_by=products&model=<your-model>`  
   (replace `<your-model>` with your NAS model, e.g. `DS923+`)
2. Look for **CPU Architecture** in the specifications â€” it must say `x86_64`.

Alternatively, SSH into the NAS and run:

```bash
uname -m
```

Output must be `x86_64`.

### Install Container Manager

If Container Manager is not already installed:

1. Open **Package Center** from the DSM desktop
2. Search for **Container Manager**
3. Click **Install** and accept the default install location
4. Wait for the install to complete; the Container Manager icon appears on the desktop

### Shared folder

You need a shared folder named `docker` (or any name you prefer) to store persistent data.

**If the `docker` folder doesn't exist:**

1. Open **File Station**
2. Click **Create â†’ Create New Shared Folder**
3. **Folder name:** `docker`
4. Leave encryption off unless you specifically need it
5. Click **Next** â†’ **Apply**

> **Note:** By default, shared folders live on your primary storage volume (`/volume1`). If your NAS has multiple volumes and you want to use a different one, select it during shared folder creation. All paths below use `/volume1/docker` â€” adjust if you chose a different volume.

---

## 2. Port planning

DSM's own web interface listens on **port 5000** (HTTP) and **5001** (HTTPS) by default. Since IPTV Hub's management API also runs internally on port 5000, you must map it to a different **host** port to avoid a conflict.

This guide uses the following port assignments â€” adjust freely to match your environment:

| Service | Host port | Container port | Notes |
|---|---|---|---|
| IPTV Hub Management UI | **5055** | 5000 | Any free host port; avoid 5000/5001 |
| IPTV streaming server (default) | **8080** | 8080 | Add more rows for each extra server |

To check which ports are already in use on your NAS:

```bash
ssh admin@<NAS-IP>
sudo netstat -tlnp | grep LISTEN
```

Pick host ports that don't appear in the output.

### Changing DSM's default port (optional)

If you specifically want to use port 5000 for the management UI, you can move DSM to a different port instead:

**Control Panel â†’ Network â†’ DSM Settings â†’ DSM port** â€” change from 5000 to e.g. 5010, then **Apply**.

---

## Step 1 â€” Prepare the Docker image

Choose one of the two options below.

### Option A â€” Export from your Windows machine (no registry required)

On the Windows machine where you built the image, run:

```powershell
docker save iptv-hub:latest -o iptv-hub.tar
```

This creates a `iptv-hub.tar` file (typically 100â€“200 MB depending on the .NET runtime). Transfer it to the NAS using one of these methods:

**Method 1 â€” File Station drag-and-drop**

1. Open **File Station** in a browser
2. Navigate to `/docker` (or another location you prefer for the tarball)
3. Drag `iptv-hub.tar` from Windows Explorer into the File Station window
4. Wait for the upload to complete (progress bar at the bottom)

**Method 2 â€” scp (requires SSH enabled on the NAS)**

From a PowerShell window on Windows:

```powershell
scp iptv-hub.tar admin@<NAS-IP>:/volume1/docker/iptv-hub.tar
```

Enter your admin password when prompted. The transfer rate is limited by your LAN â€” typically 30â€“60 seconds on gigabit Ethernet.

**Method 3 â€” Synology Drive / Cloud Station**

If you have Synology Drive installed, place `iptv-hub.tar` in a synced folder and let it sync to the NAS automatically.

---

**Import the image in Container Manager:**

1. Open **Container Manager** â†’ **Image**
2. Click **Add** â†’ **Import from file**
3. Browse to the location of `iptv-hub.tar` on the NAS
4. Click **Select** and wait for the import to finish (the progress dialog shows a spinning indicator)
5. The image `iptv-hub:latest` appears in the Image list once done

Skip to [Step 2](#step-2--create-the-data-folders).

---

### Option B â€” Push to Docker Hub, pull on Synology

This method requires a Docker Hub account (free tier is sufficient for one private image, or use a public image).

**On your Windows machine:**

```powershell
# Log in to Docker Hub (one-time)
docker login

# Tag and push â€” replace <yourusername> with your Docker Hub username
docker tag iptv-hub:latest <yourusername>/iptv-hub:latest
docker push <yourusername>/iptv-hub:latest
```

The push transfers the image layers to Docker Hub. This may take several minutes depending on your upload speed.

**On the Synology (Container Manager):**

1. Open **Container Manager** â†’ **Image**
2. Click **Add** â†’ **Add from URL**
3. Enter the image name: `<yourusername>/iptv-hub:latest`
4. If the repository is private, click **Log in** and enter your Docker Hub credentials
5. Click **Apply** to start the pull

---

## Step 2 â€” Create the data folders

IPTV Hub needs two host folders for persistent storage:

| Host path | Purpose |
|---|---|
| `/volume1/docker/iptv-hub/data` | LiteDB database files (config, channel lists, EPG) |
| `/volume1/docker/iptv-hub/logs` | Rolling daily log files |

### Creating folders via File Station

1. Open **File Station**
2. Navigate to `docker` (the shared folder you created earlier)
3. Click **Create Folder** â†’ name it `iptv-hub` â†’ click **OK**
4. Open the new `iptv-hub` folder
5. Create two sub-folders: `data` and `logs`

### Creating folders via SSH

```bash
ssh admin@<NAS-IP>
sudo mkdir -p /volume1/docker/iptv-hub/data
sudo mkdir -p /volume1/docker/iptv-hub/logs
```

### Permissions

Docker containers on Synology typically run as **root (UID 0)** by default, which means they can write to any folder the Docker daemon can reach. No special `chown` is needed for the default configuration.

If you run the container as a non-root user (see [Resource limits and performance](#resource-limits-and-performance)), set the folder owner to match:

```bash
# Example: run as UID 1000 / GID 1000
sudo chown -R 1000:1000 /volume1/docker/iptv-hub/data
sudo chown -R 1000:1000 /volume1/docker/iptv-hub/logs
```

> If your main storage volume is not `volume1`, check **Storage Manager â†’ Volumes** in DSM to find the correct volume name and adjust the paths accordingly.

---

## Step 3 â€” Deploy the container

Two methods are available. **Method A** (Projects / docker compose) is recommended â€” it stores your configuration in a text file, makes updates trivial, and survives Container Manager restarts cleanly. **Method B** (GUI wizard) requires no SSH.

---

### Method A â€” Container Manager Projects (recommended)

#### 3A-1. Enable SSH (if not already enabled)

1. **Control Panel** â†’ **Terminal & SNMP**
2. Check **Enable SSH service**
3. Set the port (default 22 is fine for home use; change to something like 2222 for public-facing NAS)
4. Click **Apply**

#### 3A-2. SSH into the NAS and create the project folder

```bash
ssh admin@<NAS-IP>
# If you changed the SSH port:
# ssh -p 2222 admin@<NAS-IP>

sudo mkdir -p /volume1/docker/iptv-hub/project
```

#### 3A-3. Create `docker-compose.yml`

```bash
sudo nano /volume1/docker/iptv-hub/project/docker-compose.yml
```

Paste the following content (use `Ctrl+Shift+V` to paste in most SSH clients):

```yaml
g
```

Save and exit: press `Ctrl+X`, then `Y`, then `Enter`.

> **Why no environment variable for the bind address?** The container's internal Kestrel server is pre-configured to listen on `0.0.0.0:5000` inside the container. The `ports` mapping takes care of exposing the correct host port. No additional environment variable is required.

#### 3A-4. Import the project in Container Manager

1. Open **Container Manager** â†’ **Project**
2. Click **Create**
3. **Project name:** `iptv-hub`
4. **Path:** click the folder icon and browse to `/volume1/docker/iptv-hub/project`
5. Container Manager detects and previews the `docker-compose.yml` automatically
6. Click **Next** â†’ review the port and volume summary â†’ click **Done**
7. The project status changes to **Running** within a few seconds

To check logs immediately:  
**Container Manager â†’ Project â†’ iptv-hub â†’ Container list â†’ iptv-hub â†’ Details â†’ Log**

---

### Method B â€” Container Manager GUI wizard (no SSH)

1. Open **Container Manager** â†’ **Container** â†’ **Create**
2. **Image:** select `iptv-hub:latest` from the list
3. **Container name:** `iptv-hub`
4. **Enable auto-restart:** toggle on

**Port Settings** tab â€” click **Add** for each row:

| Local port | Container port | Protocol |
|---|---|---|
| 5055 | 5000 | TCP |
| 8080 | 8080 | TCP |

**Volume Settings** tab â€” click **Add Folder** for each row:

| Host folder | Mount path | Purpose |
|---|---|---|
| `/volume1/docker/iptv-hub/data` | `/app/data` | Database |
| `/volume1/docker/iptv-hub/logs` | `/app/logs` | Log files |

To add a host folder: click **Add Folder** â†’ browse to the folder in the file picker â†’ type the container mount path manually in the right column.

Click **Done**. The container starts automatically.

---

### Method C â€" SSH `docker run` (simplest, recommended for updates)

If SSH is enabled on the NAS, this single command replaces both the GUI wizard and the compose project. Run it once after importing each new tar:

```bash
docker run -d \
    --name iptv-hub \
    --restart unless-stopped \
    -p 5045:5000 \
    -p 8070:8070 \
    -p 8071:8071 \
    -p 8072:8072 \
    -p 8073:8073 \
    -v /volume1/docker/iptv-hub/data:/app/data \
    -v /volume1/docker/iptv-hub/logs:/app/logs \
    iptv-hub:latest
```

Port mapping summary for this command:

| Host port | Container port | Purpose |
|---|---|---|
| 5045 | 5000 | Management UI |
| 8070â€"8073 | 8070â€"8073 | IPTV streaming servers (set matching ports in the UI) |

To **update** to a new image (stop the old container, load the new tar, start fresh):

```bash
# Stop and remove the old container (data is safe — stored in the volume)
docker stop iptv-hub && docker rm iptv-hub

# (Now import the new iptv-hub.tar in Container Manager → Image → Add → Import from file)

# Start the new container with the same command as above
docker run -d \
    --name iptv-hub \
    --restart unless-stopped \
    -p 5045:5000 \
    -p 8070:8070 \
    -p 8071:8071 \
    -p 8072:8072 \
    -p 8073:8073 \
    -v /volume1/docker/iptv-hub/data:/app/data \
    -v /volume1/docker/iptv-hub/logs:/app/logs \
    iptv-hub:latest
```

> **First run:** On a brand-new installation the `/volume1/docker/iptv-hub/data` folder is empty, so the app shows a **"This is your first time opening IPTV Hub"** screen. This is normal â€" set an admin password, then add your sources and servers. On all subsequent updates your configuration is preserved automatically via the volume mount.

---
## Step 4 â€" Open the firewall port (if applicable)
If your Synology firewall is enabled (**Control Panel â†’ Security â†’ Firewall** â€” if the toggle is on, it's active):

1. **Control Panel** â†’ **Security** â†’ **Firewall**
2. Click **Edit Rules** next to the profile in use (usually "All interfaces" or a specific interface)
3. Click **Create** to add a rule

Add one rule for each port you need:

| Field | Value |
|---|---|
| Ports | **Custom** â†’ TCP â†’ enter `5055` |
| Source IP | All (or restrict to your LAN subnet, e.g. `192.168.1.0/24`) |
| Action | Allow |

Repeat for port `8080` (and any additional IPTV server ports).

4. Click **OK** â†’ **Apply**

> **Tip:** If you're not sure whether the firewall is blocking access, temporarily disable it (**Security â†’ Firewall â†’ disable the toggle**), test connectivity, then re-enable it with the correct rules.

---

## Step 5 â€” Access the Management UI

Open a browser on any device on your network and go to:

```
http://<NAS-IP>:5055
```

Replace `<NAS-IP>` with your NAS's local IP address. You can find it in **DSM â†’ Control Panel â†’ Network â†’ Network Interface** â€” look for the IP shown next to `eth0` (or the interface connected to your LAN).

The IPTV Hub management interface loads immediately â€” no login is required.

The IPTV streaming endpoint (for media players) is at:

```
http://<NAS-IP>:8080
```

> **Container Manager shows the container as running but the browser can't connect?**  
> Wait 10â€“15 seconds after the container starts â€” .NET needs a moment to initialize. If still unreachable, check [Troubleshooting](#troubleshooting).

---

## Step 6 â€” First-time setup

After loading the UI for the first time, follow these steps to get content streaming.

### 6-1. Add a source

1. Click **Sources** in the left sidebar
2. Click **Add Source**
3. Choose a source type (M3U Playlist, Xtream Codes, Enigma2, etc.)
4. Fill in the URL, credentials, and refresh interval
5. Click **Save**
6. Click the **test tube icon** next to the new source â€” a green tick confirms it is reachable

### 6-2. Create a streaming server

1. Click **Servers** in the left sidebar
2. Click **Add Server**
3. Fill in:
   - **Name** â€” e.g. "My IPTV Server"
   - **Bind Address** â€” `0.0.0.0` (to accept connections from any device on your network)
   - **Port** â€” `8080` (must match the container port mapping you configured)
4. Click **Save**

### 6-3. Link the source to the server

1. Click the **edit (pencil) icon** on the server you just created
2. Under **Sources**, tick the source(s) you want this server to serve
3. Click **Save**

### 6-4. Start the server

Click the **â–¶ Start** button on the server card. The status badge changes to **Refreshing** (content is being fetched from upstream) then **Running**. The first fetch may take 30â€“120 seconds depending on the size of the playlist.

### 6-5. Verify

In a browser or VLC, open the M3U playlist URL:

```
http://<NAS-IP>:8080/get.php?username=<user>&password=<pass>&type=m3u_plus
```

If the server has no users configured, omit the username and password:

```
http://<NAS-IP>:8080/get.php?type=m3u_plus
```

---

## Updating IPTV Hub

### If using a .tar image (Option A)

1. Build the new image on your Windows machine:
   ```powershell
   cd d:\source\repos\IPTV_Hub
   docker build -t iptv-hub:latest .
   ```
2. Export the new image:
   ```powershell
   docker save iptv-hub:latest -o iptv-hub.tar
   ```
3. Copy `iptv-hub.tar` to the NAS (File Station drag-drop or scp)
4. In **Container Manager â†’ Image**, click **Add â†’ Import from file** and select the new `.tar`
   - Container Manager replaces the existing `iptv-hub:latest` image in-place
5. **Stop** the running container/project, then **Start** it again:
   - **Projects:** Container Manager â†’ Project â†’ iptv-hub â†’ Stop â†’ Start
   - **Method B:** Container Manager â†’ Container â†’ select `iptv-hub` â†’ Action â†’ Stop â†’ then Start

> **Your data is safe** â€" *provided you have volume mounts configured* (Step 2 + Step 3 above). The database files live on the host at `/volume1/docker/iptv-hub/data`, not inside the container, so they survive image updates, container restarts, and container deletion.

> âš ï¸ **No volume mounts = data inside the container.** If you skipped Step 2 or the Volume Settings tab in Step 3, your database is stored inside the containerâ€™s writable layer. Importing a new image causes Container Manager to recreate the container from the new image, which wipes that internal storage. See **Recovering data after an accidental wipe** below if this happened to you.

### Recovering data after an accidental wipe

When Container Manager recreates a container it usually leaves the *old* container in a stopped state â€" its internal filesystem is still intact until it is explicitly deleted.

1. SSH into the NAS:
   ```bash
   ssh admin@<NAS-IP>
   ```
2. List all containers (including stopped ones):
   ```bash
   sudo docker ps -a
   ```
   Look for a container whose image is listed as `iptv-hub:latest` or a hash (`sha256:â€¦`). It will have an **Exited** status and a name like `iptv-hub` or `iptv-hub_1`.
3. Copy the data out of the old stopped container:
   ```bash
   sudo docker cp <old-container-name-or-id>:/app/data /volume1/docker/iptv-hub/data
   ```
   Confirm the files are there:
   ```bash
   ls /volume1/docker/iptv-hub/data
   # Should list: management.db  <server-id>.db  images/ â€¦
   ```
4. Stop and delete the current (empty) container in Container Manager.
5. Recreate the container **with volume mounts** as described in Step 3 (Volume Settings tab), mapping `/app/data` â†' `/volume1/docker/iptv-hub/data`. Start it â€" your configuration and channel data will be restored.
6. Once confirmed working, delete the old stopped container:
   ```bash
   sudo docker rm <old-container-name-or-id>
   ```

If no old stopped container is visible, the data was not recoverable from the container layer and configuration will need to be re-entered manually.

---

### If using Docker Hub (Option B)

```bash
ssh admin@<NAS-IP>
docker pull <yourusername>/iptv-hub:latest
```

Then restart the container or project in Container Manager (Stop â†’ Start). The new image is used on the next start.

---

## Persistence & Backup

All application state is stored in `/volume1/docker/iptv-hub/data/`:

| File | Contents |
|---|---|
| `management.db` | Server configurations, IPTV sources, user accounts |
| `<server-id>.db` | Channel lists, VOD catalogue, EPG data (one file per server) |
| `images/` | Cached channel logos and cover artwork |

Log files are in `/volume1/docker/iptv-hub/logs/` â€” rotated daily, 14 days retained.

### Backup with Hyper Backup

Synology **Hyper Backup** is the recommended way to back up the `data/` folder:

1. Open **Hyper Backup** from the DSM desktop (install from Package Center if absent)
2. Click **+** â†’ **Data backup task**
3. Choose a backup destination (external USB, another NAS, Synology C2, cloud provider, etc.)
4. In the **Folders** step, select the `docker/iptv-hub/data` sub-folder
5. Set a schedule (daily is recommended)
6. Click **Apply**

Hyper Backup creates versioned, incremental backups. The `data/` folder is typically a few MB to a few hundred MB.

### Manual backup via File Station

For a quick one-off backup, right-click the `iptv-hub` folder in File Station â†’ **Compress to** â†’ save the resulting zip to another location.

### Exporting configuration from the UI

IPTV Hub also has a built-in configuration export:

1. Open the management UI â†’ **Settings**
2. Click **Export Configuration**
3. Save the `iptvhub-backup-<timestamp>.json` file

This JSON file contains all server and source definitions and can be used to restore after a fresh install via **Settings â†’ Restore Configuration**.

---

## Adding more IPTV streaming servers

Each server you add in the IPTV Hub UI listens on its own port. If you add a server on port 8081:

1. **Stop** the container/project in Container Manager
2. **Edit** the compose file or port settings to add the new mapping:
   - **Method A (compose):** add `- "8081:8081"` under `ports:` in `docker-compose.yml`, save the file, then re-deploy in Container Manager (Project â†’ iptv-hub â†’ Action â†’ Stop â†’ Start)
   - **Method B (GUI):** edit the container's port settings to add a new row: local `8081` â†’ container `8081`
3. **Start** the container/project again
4. If your firewall is enabled, add an allow rule for port 8081 (see [Step 4](#step-4--open-the-firewall-port-if-applicable))

---

## Reverse proxy (HTTPS access via Application Portal)

Synology's built-in **Application Portal** (also called **Reverse Proxy**) lets you put the IPTV Hub management UI behind HTTPS without any extra software.

### Create the reverse proxy entry

1. **Control Panel** â†’ **Login Portal** â†’ **Advanced** tab â†’ **Reverse Proxy**
2. Click **Create**

| Field | Value |
|---|---|
| Reverse proxy name | `IPTV Hub` |
| Protocol (source) | `HTTPS` |
| Hostname (source) | Your NAS hostname or domain (e.g. `nas.example.com`) or `*` to match any hostname |
| Port (source) | `443` (or any port you like, e.g. `5056`) |
| Protocol (destination) | `HTTP` |
| Hostname (destination) | `localhost` |
| Port (destination) | `5055` |

3. Click **Save**

IPTV Hub's management UI is now accessible at `https://nas.example.com` (or the source hostname/port you configured).

> **The IPTV streaming port (8080) does not go through this proxy.** Media players connect directly by IP:port. Only put the management UI behind HTTPS unless your players support HTTPS streaming URLs.

### Enable Let's Encrypt (automatic TLS certificate)

If your NAS has a public domain name (either your own or a Synology DDNS name â€” see next section):

1. **Control Panel** â†’ **Security** â†’ **Certificate**
2. Click **Add** â†’ **Get a certificate from Let's Encrypt**
3. Enter your domain name and an email address for expiry notifications
4. Click **Done**

Synology auto-renews the certificate 30 days before expiry. Once the certificate is issued, assign it to your `IPTV Hub` reverse proxy entry.

---

## Remote access via Synology DDNS

To reach your NAS (and IPTV Hub) from outside your home network without a static IP:

### Enable Synology DDNS

1. **Control Panel** â†’ **External Access** â†’ **DDNS**
2. Click **Add**
3. **Service provider:** `Synology`
4. **Hostname:** choose a subdomain (e.g. `myname.synology.me`)
5. Click **Test Connection** â†’ **OK**

Your NAS now has a stable hostname like `myname.synology.me` that always resolves to your current public IP.

### Port-forward on your router

For external access to work, forward the ports from your router to your NAS's internal IP:

| External port | Internal port | Protocol |
|---|---|---|
| 443 | 443 | TCP |
| 8080 | 8080 | TCP |

Log into your router's admin interface (usually `192.168.1.1` or `192.168.0.1`) and look for **Port Forwarding**, **Virtual Servers**, or **NAT** settings. The exact steps vary by router model.

After forwarding:
- Management UI: `https://myname.synology.me` (via the reverse proxy + Let's Encrypt certificate)
- IPTV streaming: `http://myname.synology.me:8080`

> **Synology QuickConnect** does not support arbitrary container ports and cannot be used to reach IPTV Hub. Use DDNS + port-forwarding or a VPN instead.

---

## Media server integration

Use the IPTV Hub streaming server endpoints (port 8080 by default) in your media server.

Replace `<NAS-IP>`, `<port>`, `<username>`, and `<password>` with your actual values. Credentials are configured per-server in the IPTV Hub Management UI under **Servers â†’ Edit â†’ Users**.

### M3U playlist URL

```
http://<NAS-IP>:8080/get.php?username=<username>&password=<password>&type=m3u_plus
```

Add `&filter=ok` to serve only channels that passed the last link scan (removes dead streams from the playlist).

If no users are configured, the server is open and credentials can be omitted:

```
http://<NAS-IP>:8080/get.php?type=m3u_plus
```

### EPG (XMLTV) URLs

Per-server EPG (from one streaming server):

```
http://<NAS-IP>:8080/xmltv.php?username=<username>&password=<password>
http://<NAS-IP>:8080/epg.xml
http://<NAS-IP>:8080/epg.xml.gz      â† gzip-compressed, smaller download
```

Aggregated EPG across **all** running servers (de-duplicated by `tvg-id`):

```
http://<NAS-IP>:5055/api/epg/xmltv
http://<NAS-IP>:5055/api/epg/xmltv?gz=true
```

Use the aggregated URL in Plex, Emby, or Jellyfin so a single EPG source covers all content.

### Xtream Codes API

For players and media servers that support the Xtream Codes API:

```
Server URL:  http://<NAS-IP>:8080
Username:    <username>
Password:    <password>
```

### Plex DVR / Live TV

1. In Plex, go to **Settings â†’ Live TV & DVR â†’ Set Up Plex DVR**
2. **Channel source:** enter the M3U playlist URL above
3. **XMLTV guide data:** enter the aggregated EPG URL (`http://<NAS-IP>:5055/api/epg/xmltv`)
4. Follow the Plex DVR setup wizard to match channels to guide data

### Emby / Jellyfin Live TV

1. **Dashboard â†’ Live TV â†’ +** (add tuner device)
2. **Tuner type:** M3U Tuner
3. **Data URL:** M3U playlist URL above
4. **Max streaming bitrate:** leave blank (use source bitrate)
5. Add a separate **TV Guide Data Provider** â†’ **XMLTV** pointing to the EPG URL (`http://<NAS-IP>:5055/api/epg/xmltv`)

### Tivimate

1. **Add Playlist â†’ Xtream Codes**
2. Server URL: `http://<NAS-IP>:8080`
3. Username and Password as configured
4. In playlist settings, set EPG URL to `http://<NAS-IP>:8080/xmltv.php?username=<username>&password=<password>`

### Kodi (PVR IPTV Simple Client)

1. Install the **PVR IPTV Simple Client** add-on
2. Set **M3U playlist URL** to the M3U URL above
3. Set **XMLTV EPG URL** to the per-server or aggregated EPG URL
4. Restart Kodi

---

## Resource limits and performance

Synology NAS units have limited RAM and CPU compared to a desktop. Consider setting resource limits in your compose file to prevent IPTV Hub from consuming more than it needs during large playlist refreshes:

```yaml
services:
  iptv-hub:
    # ... other settings ...
    mem_limit: 512m        # hard memory cap (adjust up to 1g if you have many sources)
    mem_reservation: 128m  # soft reservation
    cpus: "1.0"            # allow up to 1 full CPU core
```

### Typical resource usage

| Activity | CPU | RAM |
|---|---|---|
| Idle (serving requests) | < 1% | ~80 MB |
| Playlist refresh (M3U) | 5â€“20% | ~150 MB |
| Link scan (testing all channels) | 20â€“60% | ~200 MB |
| Stream proxy active (1 stream) | 10â€“30% | ~100 MB extra |

### Disk usage

| Folder | Typical size |
|---|---|
| `data/management.db` | < 1 MB |
| `data/<server-id>.db` | 5â€“50 MB per server (EPG + channel metadata) |
| `data/images/` | 50â€“500 MB (channel logos, VOD artwork â€” grows over time) |
| `logs/` | 1â€“5 MB (14 days of logs) |

The `data/images/` cache grows as more channels and VOD covers are requested. If disk space is tight, you can periodically clear it â€” Hub will re-cache images on demand.

### Link scanning on NAS

Link scanning (testing every channel URL) sends hundreds of HTTP requests in parallel. On a NAS with a slow CPU, this can spike CPU usage for several minutes. Consider:

- **Disabling auto-scan** (turn off **Scan on Refresh** in the server settings) and running scans manually during off-peak hours
- **Increasing the scan interval** so it doesn't run too frequently

---

## Troubleshooting

### Container does not start

Check the container logs in Container Manager:  
**Container Manager â†’ Container (or Project) â†’ select container â†’ Details â†’ Log**

Common causes:

| Symptom | Likely cause | Fix |
|---|---|---|
| `address already in use :5055` | Another process is using that host port | Change the host port in compose/settings |
| `address already in use :8080` | Port 8080 is in use (e.g. Synology Web Station) | Change the IPTV server port in the IPTV Hub UI and update port mapping |
| Image not found | Image import did not complete | Re-import the `.tar` file or re-pull from Docker Hub |
| `permission denied on /app/data` | Volume path doesn't exist or wrong permissions | Create the host folders; if running non-root, chown them |
| Container exits immediately | Application crash on startup | Read the last lines of the log for the exception message |

### Management UI loads but shows a blank/error page

The React frontend is embedded in the Docker image. If you see a blank page:
- Hard-refresh the browser (`Ctrl+Shift+R` or `Cmd+Shift+R`)
- Check the browser console (F12) for any 404 errors â€” this usually means the UI assets weren't included in the build

### Management UI loads but IPTV endpoints return 403

Credentials are required when the server has a user list. Ensure you're passing `?username=<user>&password=<pass>` matching a user in the server's **Users** tab. If the user list is empty, the server is open and no credentials are needed.

### Players can connect but stream immediately stops

- Check if **Stream Proxy** is enabled on the server. If so, the NAS must be able to reach the upstream provider
- Verify the upstream stream URL is actually reachable from the NAS:
  ```bash
  ssh admin@<NAS-IP>
  curl -I "http://your-upstream-stream-url"
  ```
- If Stream Proxy is disabled, the player receives a redirect â€” confirm your player follows HTTP 302 redirects

### Cannot reach the NAS from outside the home network

- Confirm your router has port-forwarding configured for the relevant ports (5055, 8080)
- Check your ISP doesn't block inbound connections on those ports (some mobile ISPs do)
- Synology **QuickConnect** does not work for arbitrary container ports â€” use DDNS + port-forwarding or a VPN

### Channels are missing after container restart

All data is persisted in the `data/` volume. If channels disappear after a restart, confirm:
1. The volume mount is still present (`/volume1/docker/iptv-hub/data:/app/data`)
2. The `management.db` file exists and is non-zero:
   ```bash
   ls -lh /volume1/docker/iptv-hub/data/
   ```
3. The server is **Started** in the management UI (servers must be started manually after the service restarts â€” they don't auto-start themselves)

### Checking live logs via SSH

```bash
ssh admin@<NAS-IP>
docker logs iptv-hub --follow
# or, if using Projects with the default container name:
docker logs iptv_hub-iptv-hub-1 --follow
```

Press `Ctrl+C` to stop following.

To find the exact container name:

```bash
docker ps
```

Look for the container using the `iptv-hub:latest` image and note its name in the far-right column.

### Database locked error in logs

LiteDB (the embedded database) allows only one process to open the database at a time. If you see `LiteDB.LiteException: database is locked`, there is another process (or a second container instance) already holding the file lock. Fix:

```bash
docker ps   # identify any duplicate iptv-hub containers
docker stop <duplicate-container-name>
docker rm   <duplicate-container-name>
```

Then restart the main container.
