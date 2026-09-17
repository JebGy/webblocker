# WebBlock Enterprise Installer - Interfaz Grafica y Modo Silencioso.
param(
    [string]$ServerUrl = "http://localhost:8000",
    [string]$ApiKey = "wb_agent_secret_2026",
    [switch]$Silent
)

# 1. Verificar privilegios de Administrador
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show(
        "Este instalador requiere ejecutarse como Administrador.`nPor favor abre PowerShell como Administrador.",
        "Permisos Insuficientes",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    )
    exit 1
}

$ConfigFile = "$env:ProgramData\WebBlock\config.json"
if (Test-Path $ConfigFile) {
    try {
        $cfg = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($cfg.server_url -and ($ServerUrl -eq "http://localhost:8000" -or -not $PSBoundParameters.ContainsKey('ServerUrl'))) { $ServerUrl = $cfg.server_url }
        if ($cfg.api_key -and ($ApiKey -eq "wb_agent_secret_2026" -or -not $PSBoundParameters.ContainsKey('ApiKey'))) { $ApiKey = $cfg.api_key }
    } catch {}
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# 2. Si no es modo silencioso, mostrar el Panel Grafico de Configuracion
if (-not $Silent) {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "WebBlock Enterprise - Instalador de Agente"
    $form.Size = New-Object System.Drawing.Size(460, 360)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.TopMost = $true
    $form.BackColor = [System.Drawing.Color]::FromArgb(245, 247, 250)
    $form.Font = New-Object System.Drawing.Font("Segoe UI", 9)

    # Encabezado
    $lblHeader = New-Object System.Windows.Forms.Label
    $lblHeader.Text = "Configuracion de Terminal Minera"
    $lblHeader.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
    $lblHeader.ForeColor = [System.Drawing.Color]::FromArgb(20, 24, 33)
    $lblHeader.Location = New-Object System.Drawing.Point(20, 15)
    $lblHeader.Size = New-Object System.Drawing.Size(400, 25)
    $form.Controls.Add($lblHeader)

    $lblSub = New-Object System.Windows.Forms.Label
    $lblSub.Text = "Define el servidor central y la clave de autenticacion para este equipo."
    $lblSub.ForeColor = [System.Drawing.Color]::FromArgb(100, 110, 125)
    $lblSub.Location = New-Object System.Drawing.Point(20, 42)
    $lblSub.Size = New-Object System.Drawing.Size(400, 20)
    $form.Controls.Add($lblSub)

    # Campo Servidor
    $lblServer = New-Object System.Windows.Forms.Label
    $lblServer.Text = "URL del Servidor Central:"
    $lblServer.Location = New-Object System.Drawing.Point(20, 75)
    $lblServer.Size = New-Object System.Drawing.Size(400, 18)
    $form.Controls.Add($lblServer)

    $txtServer = New-Object System.Windows.Forms.TextBox
    $txtServer.Text = $ServerUrl
    $txtServer.Location = New-Object System.Drawing.Point(20, 95)
    $txtServer.Size = New-Object System.Drawing.Size(400, 25)
    $form.Controls.Add($txtServer)

    # Campo API Key
    $lblKey = New-Object System.Windows.Forms.Label
    $lblKey.Text = "Clave de Agente (API Key):"
    $lblKey.Location = New-Object System.Drawing.Point(20, 130)
    $lblKey.Size = New-Object System.Drawing.Size(400, 18)
    $form.Controls.Add($lblKey)

    $txtKey = New-Object System.Windows.Forms.TextBox
    $txtKey.Text = $ApiKey
    $txtKey.Location = New-Object System.Drawing.Point(20, 150)
    $txtKey.Size = New-Object System.Drawing.Size(400, 25)
    $form.Controls.Add($txtKey)

    # Estado de la conexion
    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Text = "Haz clic en 'Probar Conexion' o procede a instalar."
    $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(120, 120, 120)
    $lblStatus.Location = New-Object System.Drawing.Point(20, 185)
    $lblStatus.Size = New-Object System.Drawing.Size(400, 35)
    $form.Controls.Add($lblStatus)

    # Boton Probar Conexion
    $btnTest = New-Object System.Windows.Forms.Button
    $btnTest.Text = "Probar Conexion"
    $btnTest.Location = New-Object System.Drawing.Point(20, 225)
    $btnTest.Size = New-Object System.Drawing.Size(120, 32)
    $btnTest.Cursor = [System.Windows.Forms.Cursors]::Hand
    $btnTest.Add_Click({
        $lblStatus.Text = "Verificando enlace con el servidor..."
        $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(40, 40, 40)
        $form.Refresh()
        try {
            $url = $txtServer.Text.Trim().TrimEnd('/')
            $key = $txtKey.Text.Trim()
            $resp = Invoke-RestMethod -Uri "$url/api/blocked-domains" -Method Get -Headers @{ "X-Agent-Key" = $key } -TimeoutSec 5 -ErrorAction Stop
            $lblStatus.Text = "Conexion exitosa con el servidor WebBlock!"
            $lblStatus.ForeColor = [System.Drawing.Color]::ForestGreen
        } catch {
            $lblStatus.Text = "Fallo de conexion: $($_.Exception.Message)"
            $lblStatus.ForeColor = [System.Drawing.Color]::Firebrick
        }
    })
    $form.Controls.Add($btnTest)

    # Boton Instalar
    $btnInstall = New-Object System.Windows.Forms.Button
    $btnInstall.Text = "Instalar Servicio"
    $btnInstall.BackColor = [System.Drawing.Color]::FromArgb(16, 185, 129)
    $btnInstall.ForeColor = [System.Drawing.Color]::White
    $btnInstall.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnInstall.Location = New-Object System.Drawing.Point(260, 265)
    $btnInstall.Size = New-Object System.Drawing.Size(160, 35)
    $btnInstall.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $btnInstall.Cursor = [System.Windows.Forms.Cursors]::Hand
    $btnInstall.Add_Click({
        $script:ConfirmedUrl = $txtServer.Text.Trim().TrimEnd('/')
        $script:ConfirmedKey = $txtKey.Text.Trim()
        $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $form.Close()
    })
    $form.Controls.Add($btnInstall)

    # Boton Cancelar
    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancelar"
    $btnCancel.Location = New-Object System.Drawing.Point(150, 265)
    $btnCancel.Size = New-Object System.Drawing.Size(100, 35)
    $btnCancel.Cursor = [System.Windows.Forms.Cursors]::Hand
    $btnCancel.Add_Click({
        $form.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $form.Close()
    })
    $form.Controls.Add($btnCancel)

    $result = $form.ShowDialog()
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) {
        Write-Host "Instalacion cancelada por el usuario." -ForegroundColor Yellow
        exit 0
    }

    $ServerUrl = $script:ConfirmedUrl
    $ApiKey    = $script:ConfirmedKey
}

# --- Proceso de Instalacion en el Sistema ---
$InstallDir   = "$env:ProgramFiles\WebBlock"
$TargetScript = "$InstallDir\agent.ps1"
$TaskName     = "WebBlockAgent"

Write-Host "Configurando WebBlock en esta terminal..." -ForegroundColor Cyan

# 3. Directorio protegido en Program Files
if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
} else {
    # Desbloquear temporalmente para permitir sobreescritura de actualizaciones
    takeown /f "$InstallDir" /r /d y 2>$null | Out-Null
    icacls "$InstallDir" /grant "$($env:USERNAME):(F)" /t /Q 2>$null | Out-Null
}
Copy-Item -Path "$PSScriptRoot\agent.ps1" -Destination $TargetScript -Force

# Persistir configuracion inicial de instalacion
$ConfigDir = "$env:ProgramData\WebBlock"
if (-not (Test-Path $ConfigDir)) { New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null }
@{
    server_url   = $ServerUrl
    api_key      = $ApiKey
    installed_at = (Get-Date).ToString("o")
} | ConvertTo-Json | Set-Content -Path "$ConfigDir\config.json" -Encoding UTF8 -Force

# 4. Anti-Tamper: Restringir permisos NTFS (Solo Administradores pueden editar o borrar)
$adminSid = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")
$adminGroup = $adminSid.Translate([System.Security.Principal.NTAccount]).Value
$usersSid = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-545")
$usersGroup = $usersSid.Translate([System.Security.Principal.NTAccount]).Value

try {
    icacls "$InstallDir" /inheritance:r /grant:r "SYSTEM:(OI)(CI)F" "${adminGroup}:(OI)(CI)F" "${usersGroup}:(OI)(CI)RX" /Q | Out-Null
} catch {}

# 5. Directiva corporativa: Deshabilitar DoH (DNS-over-HTTPS) para evitar fugas en navegadores
$Policies = @(
    "HKLM:\SOFTWARE\Policies\Google\Chrome",
    "HKLM:\SOFTWARE\Policies\Microsoft\Edge",
    "HKLM:\SOFTWARE\Policies\BraveSoftware\Brave"
)
foreach ($pol in $Policies) {
    try {
        if (-not (Test-Path $pol)) { New-Item -Path $pol -Force | Out-Null }
        Set-ItemProperty -Path $pol -Name "DnsOverHttpsMode" -Value "off" -Force
    } catch {}
}

# 6. Registrar Tarea Programada de Inicio Automatico
Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

$Arguments = "-ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File `"$TargetScript`" -ServerUrl `"$ServerUrl`" -ApiKey `"$ApiKey`""
$Action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $Arguments
$Trigger = New-ScheduledTaskTrigger -AtLogOn

$Settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -RestartCount 5 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit 0

$registered = $false
try {
    $Principal = New-ScheduledTaskPrincipal -GroupId "S-1-5-32-544" -RunLevel Highest
    Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Principal $Principal -Settings $Settings -Description "WebBlock Enterprise Agent" -ErrorAction Stop | Out-Null
    $registered = $true
} catch {}

if (-not $registered) {
    try {
        $Principal = New-ScheduledTaskPrincipal -UserId "$env:USERNAME" -RunLevel Highest
        Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Principal $Principal -Settings $Settings -Description "WebBlock Enterprise Agent" -ErrorAction Stop | Out-Null
        $registered = $true
    } catch {
        Write-Warning "Fallo al registrar la tarea: $_"
    }
}

Start-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue

if (-not $Silent) {
    [System.Windows.Forms.MessageBox]::Show(
        "WebBlock Agent se ha instalado e iniciado correctamente.`n`nServidor: $ServerUrl`nTarea: $TaskName",
        "Instalacion Exitosa",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    )
}
Write-Host "Servicio WebBlock instalado e iniciado exitosamente." -ForegroundColor Green
