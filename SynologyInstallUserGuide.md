# IPTV Hub User Guide: Install from iptv-hub.tar on Synology NAS

This guide is for end users who already have `iptv-hub.tar` and want to run IPTV Hub on Synology DSM using Container Manager.

It covers:
- Uploading `iptv-hub.tar`
- Importing the image
- Creating the container with persistent storage
- Opening the web UI
- First startup checks

---

## 1. Before You Start

### Requirements

- Synology NAS with DSM 7.2+
- Container Manager installed
- NAS model with x86_64 CPU architecture
- The file `iptv-hub.tar` on your PC

### Important port note

DSM uses ports 5000 and 5001 for Synology itself. IPTV Hub also uses port 5000 inside the container.

Use a different host port for IPTV Hub, for example:
- Host `5045` -> Container `5000` (management UI)

You can change this later if needed.

---

## 2. Upload iptv-hub.tar to the NAS

1. Open DSM in your browser.
2. Open **File Station**.
3. Go to a shared folder (example: `docker`).
4. Upload `iptv-hub.tar`.

Recommended location:
- `/volume1/docker/iptv-hub.tar`

---

## 3. Import the Image in Container Manager

1. Open **Container Manager**.
2. Go to **Image**.
3. Click **Add** -> **Import from file**.
4. Select `iptv-hub.tar` from the NAS folder.
5. Wait for import to finish.

After import, you should see image `iptv-hub:latest` (or equivalent tag) in the image list.

---

## 4. Create Persistent Data Folders

Create folders so config/data survive restarts and updates:

1. In **File Station**, create folder:
   - `/volume1/docker/iptv-hub/`
2. Inside it, create:
   - `/volume1/docker/iptv-hub/data`
   - `/volume1/docker/iptv-hub/logs`

---

## 5. Create the Container (DSM UI Method)

1. In **Container Manager** -> **Image**, select `iptv-hub:latest`.
2. Click **Run**.
3. Set container name:
   - `iptv-hub`
4. Enable auto-restart:
   - **Enable auto-restart** (recommended)

### Port mapping

Add these mappings:

| Local Port | Container Port | Protocol | Purpose |
|-----------|---------------|----------|---------|
| `5045` | `5000` | TCP | Management UI |
| `8070` | `8070` | TCP | Stream server 1 |
| `8071` | `8071` | TCP | Stream server 2 |
| `8072` | `8072` | TCP | Stream server 3 |
| `8073` | `8073` | TCP | Stream server 4 |

> You only need to map stream ports you intend to use. Each server you create in IPTV Hub uses one port.

### Volume mapping

Add these mappings:
- Local Folder: `/volume1/docker/iptv-hub/data` -> Mount Path: `/app/data`
- Local Folder: `/volume1/docker/iptv-hub/logs` -> Mount Path: `/app/logs`

5. Save and start the container.

---

## 6. Open IPTV Hub

Open in browser:

- `http://<NAS-IP>:5045`

Example:
- `http://192.168.1.50:5045`

If it loads, installation is complete.

---

## 7. First-Time Setup Checklist

After login/opening UI:

1. Open **Sources** and add your IPTV source.
2. Open **Servers** and create your first server.
3. Choose a stream port for that server (8070, 8071, 8072, or 8073).
4. If clients connect from other devices, ensure NAS firewall allows the stream ports (8070–8073).

---

## 8. Updating to a New iptv-hub.tar

When you receive a newer tar file:

1. Import the new tar in **Container Manager -> Image**.
2. Stop and delete existing `iptv-hub` container.
   - Delete container only, not the `data` and `logs` folders.
3. Recreate container using the same:
   - Port mapping
   - Volume mappings
4. Start container and open UI again.

Your data remains because it is stored in `/volume1/docker/iptv-hub/data`.

---

## 9. Quick Troubleshooting

### UI does not open

- Confirm container is running in Container Manager.
- Confirm port mapping is `5045` -> `5000`.
- Try `http://<NAS-IP>:5045` from another device on the same LAN.
- Check NAS firewall rules.

### Container exits immediately

- Open **Container Manager -> Container -> iptv-hub -> Log**.
- Verify volume paths exist:
  - `/volume1/docker/iptv-hub/data`
  - `/volume1/docker/iptv-hub/logs`

### Port conflict error

- Another app may already use one of the selected local ports.
- Change the conflicting port to a free port (e.g. `5055` instead of `5045`, or `8080` instead of `8070`) and retry.

### Permission denied errors on /app/data

- In DSM, confirm folders exist and are writable.
- If needed, recreate `data` and `logs` folders and re-run container.

---

## 10. Optional: SSH/CLI Install Method

Use this only if you prefer command line.

```bash
# SSH to NAS
ssh admin@<NAS-IP>

# Import image
docker load -i /volume1/docker/iptv-hub.tar

# Create folders
mkdir -p /volume1/docker/iptv-hub/data /volume1/docker/iptv-hub/logs

# Run container
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

Open:
- `http://<NAS-IP>:5045`

---

## 11. You Are Done

You now have IPTV Hub running on Synology from `iptv-hub.tar` with persistent data storage.

If you want a hardened setup next, add:
- HTTPS reverse proxy in DSM
- NAS firewall allow-list rules
- Scheduled backup for `/volume1/docker/iptv-hub/data`
