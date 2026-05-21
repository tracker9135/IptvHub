# Docker Conversion Plan — IPTV Hub

**Date:** 2026-05-21

---

## Overview

Containerize the IPTV Hub app (ASP.NET Core 8 backend + embedded React frontend) into a single Linux Docker image using a multi-stage build. One code change is required. Three new files are created.

The app is already well-suited for containerization:
- Single deployable unit — React is built and served as static files by the .NET process
- LiteDB — embedded file-based database, no external DB dependency
- Relative file paths throughout (`data/`, `logs/`)
- No Windows-only APIs beyond `UseWindowsService()`, which is a graceful no-op on Linux

---

## Phase 1 — Code Change

### Step 1: Retarget the framework

**File:** `src/IptvHub.Service/IptvHub.Service.csproj`

Change:
```xml
<TargetFramework>net8.0-windows</TargetFramework>
```
To:
```xml
<TargetFramework>net8.0</TargetFramework>
```

**Why this is safe:**

| Concern | Assessment |
|---|---|
| `UseWindowsService()` | Provided by `Microsoft.Extensions.Hosting.WindowsServices`. On Linux it is a no-op — the app starts normally as a console process. |
| `CreateNoWindow` in `ProcessStartInfo` (YoutubeHelper) | Silently ignored on Linux, not an error. |
| Any other Windows-specific APIs | None found in the codebase. |
| Windows installer build | Unaffected. `dotnet publish -r win-x64 --self-contained true` works with `net8.0` TFM. |

---

## Phase 2 — New Files

### Step 2: `.dockerignore` (repo root)

Excludes build artifacts and stale pre-built frontend assets. The Docker Stage 1 always builds the frontend fresh from source.

```
# .NET build artifacts
**/bin/
**/obj/

# Node.js
**/node_modules/

# Pre-built frontend (rebuilt in Docker Stage 1)
src/IptvHub.Service/wwwroot/

# Windows publish/installer artifacts
installer/publish/
installer/*.exe

# IDE and VCS
.vs/
.git/
*.user
```

---

### Step 3: `Dockerfile` (repo root)

Multi-stage build — three stages.

**Stage 1 `frontend-builder`** — `node:20-alpine`

Builds the React app. Vite's `outDir` is `../IptvHub.Service/wwwroot` (relative to the web project), so the compiled assets land at `src/IptvHub.Service/wwwroot` inside the build container — exactly where the .NET publish expects them.

**Stage 2 `backend-builder`** — `mcr.microsoft.com/dotnet/sdk:8.0`

Restores NuGet packages (layer-cached), copies source, copies the wwwroot output from Stage 1, then publishes the .NET app.

**Stage 3 `runtime`** — `mcr.microsoft.com/dotnet/aspnet:8.0`

Minimal final image. Contains only the published output. Kestrel is configured to bind on all interfaces via the `IptvHub__ManagementApi__Host` environment variable (overrides the `http://localhost:5000` default in `appsettings.json`).

```dockerfile
# ── Stage 1: Build React frontend ──────────────────────────────────────────────
FROM node:20-alpine AS frontend-builder

WORKDIR /repo

# Copy manifests first for layer caching
COPY src/IptvHub.Web/package.json src/IptvHub.Web/package-lock.json \
     src/IptvHub.Web/

# Install dependencies
WORKDIR /repo/src/IptvHub.Web
RUN npm ci

# Copy source and build
# Vite outDir "../IptvHub.Service/wwwroot" → /repo/src/IptvHub.Service/wwwroot
COPY src/IptvHub.Web/ .
RUN npm run build


# ── Stage 2: Build .NET backend ────────────────────────────────────────────────
FROM mcr.microsoft.com/dotnet/sdk:8.0 AS backend-builder

WORKDIR /repo

# Copy solution + project file first for NuGet restore layer caching
COPY IptvHub.sln .
COPY src/IptvHub.Service/IptvHub.Service.csproj src/IptvHub.Service/
RUN dotnet restore src/IptvHub.Service/IptvHub.Service.csproj

# Copy backend source
COPY src/IptvHub.Service/ src/IptvHub.Service/

# Overlay the frontend build from Stage 1
COPY --from=frontend-builder /repo/src/IptvHub.Service/wwwroot \
     src/IptvHub.Service/wwwroot/

# Publish
RUN dotnet publish src/IptvHub.Service/IptvHub.Service.csproj \
    -c Release \
    -o /out \
    --no-restore


# ── Stage 3: Runtime image ─────────────────────────────────────────────────────
FROM mcr.microsoft.com/dotnet/aspnet:8.0 AS runtime

WORKDIR /app

COPY --from=backend-builder /out .

# Management UI / REST API
EXPOSE 5000

# Default IPTV streaming server
# If you configure additional IPTV servers on different ports in the UI,
# add matching EXPOSE lines here and port mappings in docker-compose.yml.
EXPOSE 8080

# Override appsettings.json "Host: http://localhost:5000" so Kestrel binds
# to all interfaces and is reachable from outside the container.
ENV IptvHub__ManagementApi__Host=http://0.0.0.0:5000

ENTRYPOINT ["dotnet", "IptvHub.Service.dll"]
```

---

### Step 4: `docker-compose.yml` (repo root)

Handles port mapping and persistent storage via named Docker volumes.

```yaml
services:
  iptv-hub:
    build: .
    ports:
      - "5000:5000"   # Management UI + embedded React app
      - "8080:8080"   # Default IPTV streaming server
      # If you add more IPTV servers in the UI on different ports, expose them here:
      # - "8081:8081"
    volumes:
      - iptv-data:/app/data   # LiteDB database files (management.db, server DBs)
      - iptv-logs:/app/logs   # NLog rotating log files
    environment:
      - IptvHub__ManagementApi__Host=http://0.0.0.0:5000
    restart: unless-stopped

volumes:
  iptv-data:
  iptv-logs:
```

---

## File Summary

| File | Action | Notes |
|---|---|---|
| `src/IptvHub.Service/IptvHub.Service.csproj` | Edit | `net8.0-windows` → `net8.0` |
| `src/IptvHub.Service/appsettings.json` | No change | `localhost:5000` is overridden at runtime via env var |
| `installer/build-installer.ps1` | No change | `-r win-x64 --self-contained` unaffected by TFM change |
| `.dockerignore` | Create | Repo root |
| `Dockerfile` | Create | Repo root, multi-stage |
| `docker-compose.yml` | Create | Repo root |

---

## Verification Checklist

1. `docker build -t iptv-hub .` — multi-stage build succeeds
2. `docker compose up` — Management UI reachable at http://localhost:5000
3. IPTV streaming endpoint reachable at http://localhost:8080
4. `docker compose down && docker compose up` — LiteDB data and logs persist via named volumes
5. Run `installer/build-installer.ps1` on Windows — Windows installer build still works

---

## Notes

### CORS
`AllowedOrigins: ["http://localhost:5173"]` in `appsettings.json` is development-only (Vite dev server). In Docker, the React app and the API are served from the same origin (`http://localhost:5000`), so CORS is never exercised. No change required.

### yt-dlp (YouTube stream support)
Not included in the image. Users who need YouTube stream parsing can install `yt-dlp` into the container at build time by adding to the Dockerfile:

```dockerfile
RUN apt-get update && apt-get install -y python3 curl \
 && curl -L https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp \
    -o /usr/local/bin/yt-dlp \
 && chmod +x /usr/local/bin/yt-dlp
```

### Multiple IPTV streaming servers
Each server configured in the UI listens on its own port. If you add servers beyond the default port 8080, add the corresponding `ports` entries to `docker-compose.yml` and `EXPOSE` lines to the `Dockerfile`.

### Windows installer
The Windows installer (`IptvHubSetup-*.exe`) and its build script continue to work unchanged. They publish with `-r win-x64 --self-contained true`, which produces a Windows-specific binary regardless of the TFM being `net8.0`.
