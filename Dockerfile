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

# Default IPTV streaming server.
# If you configure additional IPTV servers on different ports in the UI,
# add matching EXPOSE lines here and port mappings in docker-compose.yml.
EXPOSE 8080

# Override appsettings.json "Host: http://localhost:5000" so Kestrel binds
# to all interfaces and is reachable from outside the container.
ENV IptvHub__ManagementApi__Host=http://0.0.0.0:5000

ENTRYPOINT ["dotnet", "IptvHub.Service.dll"]
