param(
  [Parameter(Mandatory=$false)][ValidateSet("tcp","udp")]$DestProtocol = "tcp",
  [Parameter(Mandatory=$true)] [string]$DestIP,
  [Parameter(Mandatory=$false)] [int]$DestPort = 5514,
  [Parameter(Mandatory=$false)] [string]$ApiImage = "ghcr.io/migdal1234/cycl-ec-api:latest",
  [Parameter(Mandatory=$false)] [string]$CollectorImage = "fluent/fluent-bit:2.2",
  [Parameter(Mandatory=$false)] [string]$Base = "C:\ProgramData\cycl-ec"
)

$ErrorActionPreference = "Stop"

function Assert-Docker {
  if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Error "Docker Desktop / Engine not found. Please install Docker Desktop and re-run."; exit 1
  }
}

function Ensure-Dirs {
  param([string]$Base)
  New-Item -ItemType Directory -Force -Path $Base, "$Base\db", "$Base\runtime", "$Base\buffers" | Out-Null
}

function Write-Compose {
  param([string]$Path,[string]$ApiImage,[string]$CollectorImage,[string]$DestProtocol,[string]$DestIP,[int]$DestPort)
  $compose = @"
services:
  api:
    image: $ApiImage
    container_name: cycl-ec-api
    restart: unless-stopped
    ports:
      - "8080:8080"
    environment:
      DEST_PROTOCOL: "$DestProtocol"
      DEST_IP: "$DestIP"
      DEST_PORT: "$DestPort"
      DEFAULT_SOURCE_TYPE: "linux"
    volumes:
      - ./db:/app/db
      - ./runtime:/runtime

  collector:
    image: $CollectorImage
    container_name: cycl-ec-collector
    restart: unless-stopped
    depends_on: [api]
    ports:
      - "514:514/udp"
      - "514:514/tcp"
      - "2020:2020"
    volumes:
      - ./runtime:/fluent-bit/etc:ro
      - ./db:/db
      - ./buffers:/buffers
"@
  $compose | Set-Content -Path $Path -Encoding UTF8
}

function Open-Firewall {
  if (-not (Get-NetFirewallRule -DisplayName "CYCL-EC-UI-8080" -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName "CYCL-EC-UI-8080" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 8080 | Out-Null
  }
  if (-not (Get-NetFirewallRule -DisplayName "CYCL-EC-SyslogTCP-514" -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName "CYCL-EC-SyslogTCP-514" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 514 | Out-Null
  }
  if (-not (Get-NetFirewallRule -DisplayName "CYCL-EC-SyslogUDP-514" -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName "CYCL-EC-SyslogUDP-514" -Direction Inbound -Action Allow -Protocol UDP -LocalPort 514 | Out-Null
  }
}

function Docker-Login-GHCR {
  # Only needed for private images; for public images, this silently no-ops.
  if ($env:GHCR_USER -and $env:GHCR_PAT) {
    $p = $env:GHCR_PAT
    $p | docker login ghcr.io -u $env:GHCR_USER --password-stdin | Out-Null
  }
}

function Start-Stack {
  param([string]$Base)
  Push-Location $Base
  docker compose pull
  docker compose up -d
  Pop-Location
}

function Install-CyclEC {
  [CmdletBinding()]
  param(
    [ValidateSet("tcp","udp")]$DestProtocol = "tcp",
    [Parameter(Mandatory=$true)][string]$DestIP,
    [int]$DestPort = 5514,
    [string]$ApiImage = "ghcr.io/migdal1234/cycl-ec-api:latest",
    [string]$CollectorImage = "fluent/fluent-bit:2.2",
    [string]$Base = "C:\ProgramData\cycl-ec"
  )
  Write-Host "[+] Installing CYCL Event Collector to $Base ..." -ForegroundColor Cyan
  Assert-Docker
  Ensure-Dirs -Base $Base
  Write-Compose -Path (Join-Path $Base "docker-compose.yml") -ApiImage $ApiImage -CollectorImage $CollectorImage -DestProtocol $DestProtocol -DestIP $DestIP -DestPort $DestPort
  Open-Firewall
  Docker-Login-GHCR
  Start-Stack -Base $Base
  Write-Host "[✓] Done." -ForegroundColor Green
  Write-Host "    UI:      http://localhost:8080/"
  Write-Host "    Syslog:  UDP/TCP 514 on this host"
  Write-Host "    Forward: $DestProtocol to $DestIP:$DestPort"
  Write-Host ""
  Write-Host "Tip (Windows): after changing destination in UI, run:  docker restart cycl-ec-collector" -ForegroundColor Yellow
}

# Expose function when script is dot-sourced via iwr|iex:
Set-Alias Install-CycleEC Install-CyclEC
