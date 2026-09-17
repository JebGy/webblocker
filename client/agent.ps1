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
    [int]$SyncBlocklistIntervalSeconds = 10
)

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "================================================================" -ForegroundColor Red
    Write-Host " [ADVERTENCIA] Script ejecutado SIN privilegios de Administrador." -ForegroundColor Yellow
    Write-Host " Para bloquear tráfico en 'hosts' y Firewall de Windows," -ForegroundColor Yellow
    Write-Host " abre PowerShell como Administrador o usa: .\client\install.ps1" -ForegroundColor Yellow
    Write-Host "================================================================" -ForegroundColor Red
}

$HostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
$QueueDir  = "$env:ProgramData\WebBlock"
$QueueFile = "$QueueDir\queue.json"

if (-not (Test-Path $QueueDir)) {
    New-Item -ItemType Directory -Path $QueueDir -Force | Out-Null
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
function Update-HostsBlocklist([string[]]$domains) {
    if (-not (Test-Path $HostsPath)) { return }

    try {
        $content = Get-Content $HostsPath -Raw -ErrorAction Stop
        $startTag = "# --- BEGIN WEBBLOCK ---"
        $endTag   = "# --- END WEBBLOCK ---"

        $pattern = "(?s)$([regex]::Escape($startTag)).*?$([regex]::Escape($endTag))\r?\n?"
        $cleanContent = $content -replace $pattern, ""

        if ($domains.Count -gt 0) {
            $blockLines = @($startTag)
            foreach ($d in $domains) {
                $dClean = $d.Trim().ToLower()
                if ($dClean) {
                    $targets = @($dClean)
                    if (-not $dClean.StartsWith("www.")) { $targets += "www.$dClean" }
                    if (-not $dClean.StartsWith("m."))   { $targets += "m.$dClean" }
                    if ($dClean -eq "youtube.com")       { $targets += "youtu.be", "m.youtube.com", "s.youtube.com", "googlevideo.com" }

                    foreach ($t in ($targets | Select-Object -Unique)) {
                        $blockLines += "0.0.0.0 $t"
                        $blockLines += "::1 $t"
                    }
                }
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

    if (-not $domains -or $domains.Count -eq 0) { return }

    $allIps = @()
    foreach ($d in $domains) {
        $clean = $d.Trim().ToLower()
        if ($clean) {
            try {
                $ips = [System.Net.Dns]::GetHostAddresses($clean) | ForEach-Object { $_.IPAddressToString }
                $allIps += $ips
            } catch {}
            try {
                $ipsWww = [System.Net.Dns]::GetHostAddresses("www.$clean") | ForEach-Object { $_.IPAddressToString }
                $allIps += $ipsWww
            } catch {}
        }
    }

    $uniqueIps = $allIps | Select-Object -Unique
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

# --- Main Runtime Loop ---
Write-Host "Starting WebBlock Agent -> Target Server: $ServerUrl"
$script:DeviceId = $null
$script:LastBlocklist = $null
$lastHeartbeat = [DateTime]::MinValue
$lastBlocklistSync = [DateTime]::MinValue
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
