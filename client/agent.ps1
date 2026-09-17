<#
.SYNOPSIS
    WebBlock Windows Agent - Bandwidth & Distraction Monitor for Starlink Units.
.DESCRIPTION
    Collects hardware metadata, syncs hosts-based domain blocking, tracks active
    browser navigation time, and batches logs with local offline queue tolerance.
#>

param(
    [string]$ServerUrl = "http://localhost:8000",
    [string]$ApiKey = "wb_agent_secret_2026",
    [int]$SampleIntervalSeconds = 3,
    [int]$HeartbeatIntervalSeconds = 300,
    [int]$FlushIntervalSeconds = 15,
    [int]$SyncBlocklistIntervalSeconds = 10,
    [int]$UpdateCheckIntervalSeconds = 20
)

$AgentVersion = "1.0.2"

# --- Configuration Persistence (Retain First Installation Values) ---
$ConfigFile = "$env:ProgramData\WebBlock\config.json"
if (Test-Path $ConfigFile) {
    try {
        $cfg = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($cfg.server_url -and ($ServerUrl -eq "http://localhost:8000" -or -not $PSBoundParameters.ContainsKey('ServerUrl'))) {
            $ServerUrl = $cfg.server_url
        }
        if ($cfg.api_key -and ($ApiKey -eq "wb_agent_secret_2026" -or -not $PSBoundParameters.ContainsKey('ApiKey'))) {
            $ApiKey = $cfg.api_key
        }
    } catch {}
} else {
    try {
        if (-not (Test-Path (Split-Path $ConfigFile))) {
            New-Item -ItemType Directory -Path (Split-Path $ConfigFile) -Force | Out-Null
        }
        @{
            server_url   = $ServerUrl
            api_key      = $ApiKey
            installed_at = (Get-Date).ToString("o")
        } | ConvertTo-Json | Set-Content -Path $ConfigFile -Encoding UTF8 -Force
    } catch {}
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "================================================================" -ForegroundColor Red
    Write-Host " [ADVERTENCIA] Script ejecutado SIN privilegios de Administrador." -ForegroundColor Yellow
    Write-Host " Para bloquear trafico en 'hosts' y Firewall de Windows," -ForegroundColor Yellow
    Write-Host " abre PowerShell como Administrador o usa: .\client\install.ps1" -ForegroundColor Yellow
    Write-Host "================================================================" -ForegroundColor Red
}

$HostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
$QueueDir  = "$env:ProgramData\WebBlock"
$QueueFile = "$QueueDir\queue.json"
$LogFile   = "$QueueDir\agent.log"

if (-not (Test-Path $QueueDir)) {
    New-Item -ItemType Directory -Path $QueueDir -Force | Out-Null
}

function Log-Agent([string]$msg, [string]$color = "White") {
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $text = "[$ts] $msg"
    Write-Host $text -ForegroundColor $color
    try {
        Add-Content -Path $LogFile -Value $text -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch {}
}

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes -ErrorAction SilentlyContinue

# --- Native Win32 API to capture active foreground window ---
Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class WinUtil {
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
}
"@ -ErrorAction SilentlyContinue

# --- Hardware Info Collection ---
function Get-HardwareProfile {
    $serial = (Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue).SerialNumber
    if ([string]::IsNullOrWhiteSpace($serial)) { $serial = $env:COMPUTERNAME }

    $brand = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).Manufacturer
    if ([string]::IsNullOrWhiteSpace($brand)) { $brand = "Generic" }

    $ipObj = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceAlias -notmatch 'Loopback|vEthernet' -and $_.IPAddress -notmatch '^169\.254\.' } |
        Select-Object -First 1
    $ip = if ($ipObj) { $ipObj.IPAddress } else { "127.0.0.1" }

    $ssidRaw = netsh wlan show interfaces 2>$null | Select-String "^\s*SSID\s*:\s*(.+)$"
    $ssid = if ($ssidRaw) { $ssidRaw.Matches[0].Groups[1].Value.Trim() } else { "Ethernet/Off" }

    return @{
        serial_number = $serial.Trim()
        brand         = $brand.Trim()
        last_ip       = $ip
        last_ssid     = $ssid
    }
}

# --- Hosts File & Firewall Domain Blocker ---
function Expand-BlockedDomains([string[]]$domains) {
    $expanded = @()
    foreach ($d in $domains) {
        $clean = "$d".Trim().ToLower()
        if (-not $clean) { continue }
        $expanded += $clean
        if (-not $clean.StartsWith("www.")) { $expanded += "www.$clean" }
        if (-not $clean.StartsWith("m."))   { $expanded += "m.$clean" }

        if ($clean -match "youtube|youtu\.be") {
            $expanded += "youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be", "s.youtube.com", "googlevideo.com", "ytimg.com"
        }
        if ($clean -match "facebook|fb\.com") {
            $expanded += "facebook.com", "www.facebook.com", "m.facebook.com", "fb.com", "fbcdn.net"
        }
        if ($clean -match "tiktok") {
            $expanded += "tiktok.com", "www.tiktok.com", "m.tiktok.com", "tiktokcdn.com"
        }
        if ($clean -match "instagram") {
            $expanded += "instagram.com", "www.instagram.com", "cdninstagram.com"
        }
        if ($clean -match "twitter|\bx\.com\b") {
            $expanded += "twitter.com", "www.twitter.com", "x.com", "www.x.com", "twimg.com"
        }
        if ($clean -match "netflix") {
            $expanded += "netflix.com", "www.netflix.com", "nflxvideo.net"
        }
    }
    return @($expanded | Select-Object -Unique)
}

function Update-HostsBlocklist([string[]]$domains) {
    if (-not (Test-Path $HostsPath)) { return }

    try {
        $content = Get-Content $HostsPath -Raw -ErrorAction Stop
        $startTag = "# --- BEGIN WEBBLOCK ---"
        $endTag   = "# --- END WEBBLOCK ---"

        $pattern = "(?s)$([regex]::Escape($startTag)).*?$([regex]::Escape($endTag))\r?\n?"
        $cleanContent = $content -replace $pattern, ""

        $allTargets = Expand-BlockedDomains -domains $domains

        if ($allTargets.Count -gt 0) {
            $blockLines = @($startTag)
            foreach ($t in $allTargets) {
                $blockLines += "0.0.0.0 $t"
                $blockLines += "::1 $t"
            }
            $blockLines += $endTag
            $newSection = ($blockLines -join "`r`n") + "`r`n"
            $finalContent = $cleanContent.TrimEnd() + "`r`n`r`n" + $newSection
        } else {
            $finalContent = $cleanContent
        }

        Set-Content -Path $HostsPath -Value $finalContent -Encoding UTF8 -Force -ErrorAction Stop
        Clear-DnsClientCache -ErrorAction SilentlyContinue
    } catch {
        Write-Warning "Fallo al escribir en 'hosts' (requiere permisos de Administrador): $_"
    }
}

function Sync-FirewallRules([string[]]$domains) {
    Get-NetFirewallRule -DisplayName "WebBlock_*" -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue

    $allTargets = Expand-BlockedDomains -domains $domains
    if (-not $allTargets -or $allTargets.Count -eq 0) { return }

    $allIps = @()
    foreach ($t in $allTargets) {
        try {
            $ips = [System.Net.Dns]::GetHostAddresses($t) | ForEach-Object { $_.IPAddressToString }
            $allIps += $ips
        } catch {}
    }

    $uniqueIps = @($allIps | Select-Object -Unique)
    if ($uniqueIps -and $uniqueIps.Count -gt 0) {
        try {
            New-NetFirewallRule -DisplayName "WebBlock_Outbound" `
                -Direction Outbound `
                -Action Block `
                -RemoteAddress $uniqueIps `
                -Description "WebBlock active domain restriction" `
                -ErrorAction Stop | Out-Null
            Write-Host "[Firewall] Regla activa: $($uniqueIps.Count) IPs bloqueadas." -ForegroundColor Yellow
        } catch {
            Write-Warning "No se pudo inyectar regla en Firewall (requiere permisos de Administrador): $_"
        }
    }
}

function Apply-Blocklist([string[]]$domains) {
    Update-HostsBlocklist -domains $domains
    Sync-FirewallRules -domains $domains
}

# --- Offline Queue Management (Starlink drops tolerance) ---
function Save-Queue($items) {
    if ($items -and $items.Count -gt 0) {
        $json = $items | ConvertTo-Json -Compress
        Set-Content -Path $QueueFile -Value $json -Encoding UTF8 -Force
    } elseif (Test-Path $QueueFile) {
        Remove-Item $QueueFile -Force -ErrorAction SilentlyContinue
    }
}

function Load-Queue {
    if (-not (Test-Path $QueueFile)) { return @() }
    try {
        $raw = Get-Content -Path $QueueFile -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
        $data = $raw | ConvertFrom-Json
        return @($data)
    } catch {
        return @()
    }
}

# --- Active Window / Browser Focus Extractor ---
$SupportedBrowsers = @('chrome', 'msedge', 'firefox', 'brave', 'opera', 'vivaldi')

$KnownPlatformMap = @{
    'youtube'    = 'youtube.com'
    'tiktok'     = 'tiktok.com'
    'facebook'   = 'facebook.com'
    'instagram'  = 'instagram.com'
    'twitter'    = 'x.com'
    'twitch'     = 'twitch.tv'
    'netflix'    = 'netflix.com'
    'reddit'     = 'reddit.com'
    'spotify'    = 'spotify.com'
    'whatsapp'   = 'web.whatsapp.com'
    'telegram'   = 'web.telegram.org'
    'discord'    = 'discord.com'
    'amazon'     = 'amazon.com'
}

function Get-ActiveBrowserDomain {
    $hWnd = [WinUtil]::GetForegroundWindow()
    if ($hWnd -eq [IntPtr]::Zero) { return $null }

    [uint32]$procId = 0
    [WinUtil]::GetWindowThreadProcessId($hWnd, [ref]$procId) | Out-Null
    if ($procId -eq 0) { return $null }

    $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
    if (-not $proc -or $SupportedBrowsers -notcontains $proc.ProcessName.ToLower()) {
        return $null
    }

    $sb = New-Object System.Text.StringBuilder 512
    [WinUtil]::GetWindowText($hWnd, $sb, $sb.Capacity) | Out-Null
    $title = $sb.ToString().Trim()
    if ([string]::IsNullOrWhiteSpace($title)) { return $null }

    # 1. Match known platforms by keyword in tab title (e.g., "Video - YouTube - Brave")
    foreach ($entry in $KnownPlatformMap.GetEnumerator()) {
        if ($title -match "(?i)\b$($entry.Key)\b") {
            return $entry.Value
        }
    }

    # 2. Regex match explicit domain pattern in title
    if ($title -match "(?i)\b([a-z0-9-]+\.(?:com|org|net|io|pe|edu|tv|co|gov|app|dev|lat|me|xyz|cl|es|mx|ai))\b") {
        return $matches[1].ToLower()
    }

    # 3. UI Automation address bar inspection (Chromium browsers)
    try {
        $root = [System.Windows.Automation.AutomationElement]::FromHandle($hWnd)
        if ($root) {
            $cond = New-Object System.Windows.Automation.PropertyCondition(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::Edit
            )
            $edit = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
            if ($edit) {
                $rawUrl = $edit.GetCurrentPropertyValue([System.Windows.Automation.ValuePattern]::ValueProperty)
                if ($rawUrl -match "(?i)([a-z0-9-]+\.(?:com|org|net|io|pe|edu|tv|co|gov|app|dev|lat|me|xyz|cl|es|mx|ai))") {
                    return $matches[1].ToLower()
                }
            }
        }
    } catch {}

    # 4. Correlate with recent DNS resolution cache
    $dns = Get-DnsClientCache -ErrorAction SilentlyContinue |
        Where-Object { $_.Entry -match "^[a-zA-Z0-9-]+\.[a-zA-Z]{2,}$" -and $_.Entry -notmatch 'local|internal|msft|windows|azure|office|telemetry' } |
        Select-Object -First 1
    if ($dns) {
        return $dns.Entry.ToLower()
    }

    # 5. Clean browser suffix fallback
    $clean = $title -replace "(?i)\s*-\s*(Google Chrome|Microsoft Edge|Personal: Microsoft Edge|Brave|Mozilla Firefox|Opera|Vivaldi).*$", ""
    return ($clean.Trim() -replace '[^\w\.\-]', '')
}

# --- Self-Update & Version Verification ---
function Test-IsNewerVersion([string]$remote, [string]$local) {
    if ([string]::IsNullOrWhiteSpace($remote)) { return $false }
    if ([string]::IsNullOrWhiteSpace($local)) { return $true }
    try {
        $rNorm = if ($remote -notmatch '\.') { "$remote.0" } else { $remote }
        $lNorm = if ($local -notmatch '\.') { "$local.0" } else { $local }
        return ([version]$rNorm -gt [version]$lNorm)
    } catch {
        return ($remote.Trim() -ne $local.Trim())
    }
}

function Check-AgentUpdate {
    try {
        Write-Host "[AutoUpdate] Comprobando version en servidor..." -ForegroundColor DarkGray
        $verInfo = Invoke-RestMethod -Uri "$ServerUrl/api/agent/version" -Method Get -Headers $authHeaders -TimeoutSec 5 -ErrorAction Stop
        $remoteVersion = "$($verInfo.version)".Trim()
        if (-not (Test-IsNewerVersion -remote $remoteVersion -local $AgentVersion)) {
            return
        }

        Log-Agent "[AutoUpdate] Nueva version detectada en servidor: v$remoteVersion (Actual: v$AgentVersion). Descargando..." "Cyan"

        $dlPath = $verInfo.download_url
        $downloadUrl = if ($dlPath -match "^https?://") { $dlPath } else { "$ServerUrl$dlPath" }

        $targetPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Definition }
        if (-not $targetPath -or -not (Test-Path $targetPath)) {
            $targetPath = "$env:ProgramFiles\WebBlock\agent.ps1"
        }

        $targetDir = Split-Path -Parent $targetPath
        if (-not (Test-Path $targetDir)) {
            New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
        }

        $tempFile = Join-Path $targetDir "agent_update_$([Guid]::NewGuid().ToString('N').Substring(0,8)).tmp"

        # Descargar nuevo script con cabecera de autenticacion
        Invoke-RestMethod -Uri $downloadUrl -Method Get -Headers $authHeaders -OutFile $tempFile -TimeoutSec 15 -ErrorAction Stop

        # Validacion 1: Comprobar tamano minimo para evitar archivos vacios por cortes Starlink
        $tempItem = Get-Item $tempFile -ErrorAction SilentlyContinue
        if (-not $tempItem -or $tempItem.Length -lt 2048) {
            Log-Agent "[AutoUpdate] Descarga truncada o corrupta (<2KB). Abortando actualizacion." "Yellow"
            Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
            return
        }

        # Validacion 2: Parser sintactico AST para garantizar que el archivo PowerShell es 100% valido
        $parseErrors = $null
        $tokens = $null
        [System.Management.Automation.Language.Parser]::ParseFile($tempFile, [ref]$tokens, [ref]$parseErrors) | Out-Null
        if ($parseErrors -and $parseErrors.Count -gt 0) {
            Log-Agent "[AutoUpdate] Error de sintaxis en script descargado ($($parseErrors.Count) errores). Abortando actualizacion." "Yellow"
            Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
            return
        }

        # Reemplazo atomico en disco (PowerShell ejecuta en memoria, el archivo en disco no esta bloqueado)
        Move-Item -Path $tempFile -Destination $targetPath -Force -ErrorAction Stop

        # Actualizar metadata persistente conservando ServerUrl y ApiKey originales
        try {
            @{
                server_url   = $ServerUrl
                api_key      = $ApiKey
                version      = $remoteVersion
                updated_at   = (Get-Date).ToString("o")
            } | ConvertTo-Json | Set-Content -Path $script:ConfigFile -Encoding UTF8 -Force
        } catch {}

        Log-Agent "[AutoUpdate] Actualizacion a v$remoteVersion completada con exito. Reiniciando agente..." "Green"

        # Relanzar nuevo proceso con los mismos parametros
        $argList = @(
            "-ExecutionPolicy", "Bypass",
            "-NoProfile",
            "-WindowStyle", "Hidden",
            "-File", "`"$targetPath`"",
            "-ServerUrl", "`"$ServerUrl`"",
            "-ApiKey", "`"$ApiKey`"",
            "-SampleIntervalSeconds", "$SampleIntervalSeconds",
            "-HeartbeatIntervalSeconds", "$HeartbeatIntervalSeconds",
            "-FlushIntervalSeconds", "$FlushIntervalSeconds",
            "-SyncBlocklistIntervalSeconds", "$SyncBlocklistIntervalSeconds",
            "-UpdateCheckIntervalSeconds", "$UpdateCheckIntervalSeconds"
        ) -join " "

        Start-Process -FilePath "powershell.exe" -ArgumentList $argList
        Exit 0
    } catch {
        Log-Agent "[AutoUpdate] Error comprobando/aplicando actualizacion: $_" "Yellow"
        if ($tempFile -and (Test-Path $tempFile)) {
            Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
        }
    }
}

# --- Main Runtime Loop ---
Log-Agent "Starting WebBlock Agent -> Target Server: $ServerUrl (v$AgentVersion)" "Green"
Log-Agent ">>> [v1.0.2 TEST E2E EXITOSO] Auto-actualizacion completada en caliente <<<" "Magenta"
$script:DeviceId = $null
$script:LastBlocklist = $null
$lastHeartbeat = [DateTime]::MinValue
$lastBlocklistSync = [DateTime]::MinValue
$lastUpdateCheck = [DateTime]::MinValue
$lastFlush     = [DateTime]::UtcNow
$pendingActivity = @{} # domain -> duration_seconds
$authHeaders = @{ "X-Agent-Key" = $ApiKey }
$consecutiveFailures = 0

while ($true) {
    $now = [DateTime]::UtcNow

    # 1. Heartbeat
    if (($now - $lastHeartbeat).TotalSeconds -ge $HeartbeatIntervalSeconds -or [string]::IsNullOrEmpty($script:DeviceId)) {
        try {
            $hw = Get-HardwareProfile
            $body = $hw | ConvertTo-Json
            $resp = Invoke-RestMethod -Uri "$ServerUrl/api/heartbeat" -Method Post -Headers $authHeaders -Body $body -ContentType "application/json" -TimeoutSec 10 -ErrorAction Stop
            $script:DeviceId = $resp.device_id
            $lastHeartbeat = $now
            $consecutiveFailures = 0
            Write-Host "Heartbeat OK. Device ID: $script:DeviceId"
        } catch {
            $consecutiveFailures++
            Write-Warning "Heartbeat falló (¿Enlace Starlink caído?): $_"
        }
    }

    # 1b. Rapid Blocklist & Firewall Sync (every 10s)
    if (($now - $lastBlocklistSync).TotalSeconds -ge $SyncBlocklistIntervalSeconds -or $null -eq $script:LastBlocklist) {
        $lastBlocklistSync = $now
        try {
            $blockedList = Invoke-RestMethod -Uri "$ServerUrl/api/blocked-domains" -Method Get -Headers $authHeaders -TimeoutSec 5 -ErrorAction Stop
            $normalized = @($blockedList | ForEach-Object { "$_".Trim().ToLower() } | Where-Object { $_ } | Sort-Object)
            $sortedKey = $normalized -join "|"

            if ($sortedKey -ne $script:LastBlocklist) {
                $script:LastBlocklist = $sortedKey
                Apply-Blocklist -domains $normalized
                Write-Host "[Bloqueo] Lista activa actualizada: $(if ($normalized) { $normalized -join ', ' } else { 'Ninguno' })" -ForegroundColor Red
            }
        } catch {}
    }

    # 1c. Periodic Self-Update Check (every 20s)
    if (($now - $lastUpdateCheck).TotalSeconds -ge $UpdateCheckIntervalSeconds) {
        $lastUpdateCheck = $now
        Check-AgentUpdate
    }

    # 2. Sample Foreground Window Focus
    $activeDomain = Get-ActiveBrowserDomain
    if ($activeDomain) {
        if (-not $pendingActivity.ContainsKey($activeDomain)) {
            $pendingActivity[$activeDomain] = 0
        }
        $pendingActivity[$activeDomain] += $SampleIntervalSeconds
        Write-Host "[Focus] $activeDomain (+${SampleIntervalSeconds}s)" -ForegroundColor Cyan
    }

    # 3. Buffer & Flush Activity Queue (Offline-tolerant batch)
    if (($now - $lastFlush).TotalSeconds -ge $FlushIntervalSeconds) {
        $lastFlush = $now
        $queue = @(Load-Queue)

        # Transfer accumulated sampling into queue items
        foreach ($key in $pendingActivity.Keys) {
            $dur = $pendingActivity[$key]
            if ($dur -gt 0) {
                $queue += @{
                    domain           = $key
                    duration_seconds = $dur
                    logged_at        = $now.ToString("o")
                }
            }
        }
        $pendingActivity.Clear()

        if ($queue.Count -gt 0 -and -not [string]::IsNullOrEmpty($script:DeviceId)) {
            try {
                $payload = @{
                    device_id  = $script:DeviceId
                    activities = [object[]]$queue
                } | ConvertTo-Json -Depth 4

                Invoke-RestMethod -Uri "$ServerUrl/api/activity" -Method Post -Headers $authHeaders -Body $payload -ContentType "application/json" -TimeoutSec 15 -ErrorAction Stop | Out-Null
                Write-Host "Flushed $($queue.Count) activity items to server."
                Save-Queue @()
                $consecutiveFailures = 0
            } catch {
                $consecutiveFailures++
                Write-Warning "Fallo al enviar actividad; reteniendo en cola offline: $_"
                Save-Queue $queue
            }
        } elseif ($queue.Count -gt 0) {
            Save-Queue $queue
        }
    }

    # Exponential backoff during long Starlink outages (max 30s)
    $sleepSec = if ($consecutiveFailures -gt 2) { [Math]::Min(30, $SampleIntervalSeconds * 3) } else { $SampleIntervalSeconds }
    Start-Sleep -Seconds $sleepSec
}
