# STRATA payment demo — start everything on the laptop side.
#
#   powershell -ExecutionPolicy Bypass -File host_node\scripts\demo_payment_up.ps1
#
# Needs: Pi connected by Ethernet with Windows Internet Connection Sharing on,
# SSH key %USERPROFILE%\.ssh\strata_pi, and the Pi's .env in chain mode.
# Opens two windows (blockchain + tunnel) — keep both open during the demo.
param([string]$PiIp = "192.168.137.189")

$ErrorActionPreference = "Stop"
$repo   = Resolve-Path "$PSScriptRoot\..\.."
$key    = "$env:USERPROFILE\.ssh\strata_pi"
$python = "$repo\host_node\.venv\Scripts\python.exe"

Write-Host "Waiting for the Pi ($PiIp) to finish booting (can take 1-2 minutes)..."
$piUp = $false
$ErrorActionPreference = "Continue"   # ssh writes to stderr while the Pi boots
for ($i = 0; $i -lt 60; $i++) {
  ssh -i $key -o BatchMode=yes -o ConnectTimeout=3 strata@$PiIp true 2>$null
  if ($LASTEXITCODE -eq 0) { $piUp = $true; break }
  Start-Sleep 3
}
$ErrorActionPreference = "Stop"
if (-not $piUp) {
  Write-Host "Pi not reachable at $PiIp. Check: Pi has power, Ethernet cable plugged in, Wi-Fi sharing (ICS) on." -ForegroundColor Red
  exit 1
}
Write-Host "Pi is up."

$chainUp = $false
try {
  Invoke-RestMethod -Uri http://127.0.0.1:8545 -Method Post -ContentType "application/json" `
    -Body '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' -TimeoutSec 3 | Out-Null
  $chainUp = $true
} catch {}

if ($chainUp) {
  # Deploying again would put the contracts at new addresses the app doesn't know.
  Write-Host "1/4 + 2/4 Blockchain already running - keeping it (no redeploy)."
} else {
  Write-Host "1/4 Starting local blockchain (Hardhat) in a new window..."
  Start-Process powershell -ArgumentList "-NoExit", "-Command",
    "`$Host.UI.RawUI.WindowTitle = 'STRATA BLOCKCHAIN - keep open'; Set-Location '$repo\contracts'; node node_modules/hardhat/internal/cli/bootstrap.js node"
  for ($i = 0; $i -lt 60; $i++) {
    try {
      Invoke-RestMethod -Uri http://127.0.0.1:8545 -Method Post -ContentType "application/json" `
        -Body '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' | Out-Null
      break
    } catch { Start-Sleep 1 }
  }

  Write-Host "2/4 Deploying contracts..."
  Push-Location "$repo\host_node\scripts"
  & $python -c "import sys; sys.path[:0]=['.','../src']; from iter3_local_chain_e2e import _deploy, _must_connect; _deploy(_must_connect())"
  Pop-Location
}

$tunnelOpen = Get-Process powershell -ErrorAction SilentlyContinue |
  Where-Object { $_.MainWindowTitle -eq 'STRATA TUNNEL - keep open' }
if ($tunnelOpen) {
  Write-Host "3/4 Tunnel window already open - keeping it."
} else {
  Write-Host "3/4 Opening tunnel to the Pi ($PiIp) in a new window..."
  # Reconnects by itself if the Pi reboots or the cable is pulled.
  Start-Process powershell -ArgumentList "-NoExit", "-Command",
    "`$Host.UI.RawUI.WindowTitle = 'STRATA TUNNEL - keep open'; while (`$true) { Write-Host ('[' + (Get-Date -Format HH:mm:ss) + '] tunnel connecting...'); ssh -i '$key' -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes -N -R 127.0.0.1:8545:127.0.0.1:8545 strata@$PiIp; Write-Host 'tunnel lost - retrying in 3 s'; Start-Sleep 3 }"
  Start-Sleep 4
}

Write-Host "4/4 Restarting the router so it follows the fresh chain..."
ssh -i $key -o BatchMode=yes strata@$PiIp 'sudo systemctl restart strata-host; sleep 10; systemctl is-active strata-host; curl -s http://127.0.0.1:8080/host/info'

Write-Host ""
Write-Host "Ready if above shows 'active' and ""chain_enabled"":true."
Write-Host "Guest wallet for the app (import): test test test test test test test test test test test junk"
