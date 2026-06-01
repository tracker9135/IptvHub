param(
    [string]$ImageName = "iptv-hub",
    [string]$Tag = "latest",
    [string]$Dockerfile = "Dockerfile.media",
    [string]$OutputDir = "artifacts/synology",
    [string]$OutputTar = "",       # defaults to iptv-hub.tar inside OutputDir
    [switch]$SkipBuild
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $repoRoot

# Read version for labelling
$version = (Get-Content version.json | ConvertFrom-Json).version

if (-not $OutputTar) { $OutputTar = "iptv-hub.tar" }
$outDir  = Join-Path $repoRoot $OutputDir
$tarPath = Join-Path $outDir $OutputTar
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$imageRef = "${ImageName}:${Tag}"

if (-not $SkipBuild) {
    Write-Host "Building $imageRef  (v$version)  using $Dockerfile ..." -ForegroundColor Cyan
    docker build -f $Dockerfile -t $imageRef .
}

Write-Host "Saving $imageRef  →  $tarPath ..." -ForegroundColor Cyan
docker save $imageRef -o $tarPath

# Validate tar contains exactly one image manifest entry.
$manifestJson = tar -xOf $tarPath manifest.json
$manifest = $manifestJson | ConvertFrom-Json
if ($manifest.Count -ne 1) {
    throw "Expected exactly 1 manifest entry in $tarPath, but found $($manifest.Count)."
}

# ── Copy support files ────────────────────────────────────────────────────────
Write-Host "Copying support files to $outDir ..." -ForegroundColor Cyan

Copy-Item -Force "docker-compose.yml"          (Join-Path $outDir "docker-compose.yml")
Copy-Item -Force "SynologyInstallUserGuide.md" (Join-Path $outDir "SynologyInstallUserGuide.md")

# Write a .env.example template if it doesn't exist yet
$envExample = Join-Path $outDir ".env.example"
if (-not (Test-Path $envExample)) {
@"
# Copy this file to .env and adjust values before starting the container.
# These variables are read by docker-compose.yml via \${VAR_NAME} substitution.

# Host port that maps to the container's management UI (port 5000).
# Synology uses 5000/5001 itself, so pick something else e.g. 5045.
IPTV_HUB_PORT=5045

# XMLTV EPG host IP advertised in the M3U/XMLTV URLs served to clients.
# Set this to the LAN IP of your Synology NAS.
IPTV_HUB_EPG_HOST_IP=192.168.1.100
"@ | Set-Content $envExample
    Write-Host "  Created .env.example" -ForegroundColor Yellow
}

$file = Get-Item $tarPath
Write-Host ""
Write-Host "Done.  v$version" -ForegroundColor Green
Write-Host "  Image tar : $($file.FullName)  ($([math]::Round($file.Length/1MB,1)) MB)" -ForegroundColor Green
Write-Host "  Tag       : $($manifest[0].RepoTags -join ', ')" -ForegroundColor Green
Write-Host "  Folder    : $outDir" -ForegroundColor Green
