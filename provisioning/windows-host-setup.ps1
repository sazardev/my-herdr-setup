#Requires -Version 5.1
<#
  windows-host-setup.ps1
  Provisioning idempotente del host Windows para gm-erp2:
  features de WSL, Nerd Fonts, CachyOS-WSL, .wslconfig, Alacritty, Claude Code (Windows).

  Version: 1.0.0
  Uso:
    .\windows-host-setup.ps1
    .\windows-host-setup.ps1 -Force                  # re-ejecuta todos los pasos aunque ya estén hechos
    .\windows-host-setup.ps1 -Only InstallCachyOS     # corre solo un paso
    .\windows-host-setup.ps1 -WslMemoryGB 20 -WslProcessors 18 -WslSwapGB 0
#>

[CmdletBinding()]
param(
    [string]   $CachyOSUsername   = "omar",
    [SecureString] $CachyOSPassword,
    [string[]] $NerdFonts         = @("CascadiaCode", "Meslo"),
    [int]      $WslMemoryGB       = 20,
    [int]      $WslProcessors     = 18,
    [int]      $WslSwapGB         = 0,   # 0 a propósito: el swap real vive dentro de CachyOS (provision-cachyos.sh)
    [switch]   $Force,
    [string]   $Only,
    [switch]   $InstallClaudeOnWindows = $true
)

$Script:Version   = "1.0.0"
$Script:StateDir  = Join-Path $env:ProgramData "gm-erp2-setup"
$Script:StateFile = Join-Path $Script:StateDir "state.json"
$Script:LogDir    = Join-Path $Script:StateDir "logs"
$Script:LogFile   = Join-Path $Script:LogDir ("setup-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
$Script:Results   = New-Object System.Collections.Generic.List[object]

# ---------- logging ----------
function Write-Log {
    param([string]$Message, [ValidateSet("INFO","OK","WARN","ERROR")]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    $color = switch ($Level) { "OK" {"Green"} "WARN" {"Yellow"} "ERROR" {"Red"} default {"Gray"} }
    Write-Host $line -ForegroundColor $color
    Add-Content -Path $Script:LogFile -Value $line -Encoding UTF8
}

# ---------- elevación ----------
function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host "Re-lanzando elevado..." -ForegroundColor Yellow
        $argList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"")
        foreach ($k in $PSBoundParameters.Keys) {
            $v = $PSBoundParameters[$k]
            if ($v -is [switch]) { if ($v) { $argList += "-$k" } }
            else { $argList += "-$k"; $argList += "`"$v`"" }
        }
        Start-Process powershell -Verb RunAs -ArgumentList $argList
        exit 0
    }
}

# ---------- estado (idempotencia + reporte) ----------
function Get-State {
    if (Test-Path $Script:StateFile) {
        try { return (Get-Content $Script:StateFile -Raw | ConvertFrom-Json -AsHashtable) } catch { return @{} }
    }
    return @{}
}
function Save-State($state) {
    New-Item -ItemType Directory -Path $Script:StateDir -Force | Out-Null
    $state | ConvertTo-Json -Depth 5 | Set-Content -Path $Script:StateFile -Encoding UTF8
}
$Script:State = Get-State

function Invoke-Step {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Action
    )
    if ($Only -and $Only -ne $Name) { return }
    if ($Script:State.ContainsKey($Name) -and $Script:State[$Name].status -eq "OK" -and -not $Force) {
        Write-Log "SKIP  $Name (ya completado el $($Script:State[$Name].when))" "INFO"
        $Script:Results.Add([pscustomobject]@{ Step=$Name; Status="SKIP"; Detail="ya hecho" })
        return
    }
    Write-Log "-> $Name" "INFO"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        & $Action
        $sw.Stop()
        Write-Log "OK    $Name ($($sw.Elapsed))" "OK"
        $Script:Results.Add([pscustomobject]@{ Step=$Name; Status="OK"; Detail="$($sw.Elapsed)" })
        $Script:State[$Name] = @{ status = "OK"; when = (Get-Date -Format "s") }
    }
    catch {
        $sw.Stop()
        Write-Log "FAIL  $Name : $($_.Exception.Message)" "ERROR"
        $Script:Results.Add([pscustomobject]@{ Step=$Name; Status="FAIL"; Detail=$_.Exception.Message })
        $Script:State[$Name] = @{ status = "FAIL"; when = (Get-Date -Format "s"); error = $_.Exception.Message }
    }
    Save-State $Script:State
}

# ---------- pasos ----------

function Step-EnableWslFeatures {
    $features = @("Microsoft-Windows-Subsystem-Linux", "VirtualMachinePlatform")
    $needsRestart = $false
    foreach ($f in $features) {
        $state = (Get-WindowsOptionalFeature -Online -FeatureName $f).State
        if ($state -ne "Enabled") {
            $r = Enable-WindowsOptionalFeature -Online -FeatureName $f -All -NoRestart
            if ($r.RestartNeeded) { $needsRestart = $true }
        }
    }
    if ($needsRestart) {
        Write-Log "Se habilitaron features nuevas; puede requerir reinicio de Windows antes de continuar." "WARN"
    }
    wsl --set-default-version 2 | Out-Null
}

function Step-UpdateWsl {
    wsl --update 2>&1 | Out-Null
    $v = wsl --version 2>&1
    Write-Log "wsl --version:`n$v" "INFO"
}

function Step-InstallNerdFonts {
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/ryanoasis/nerd-fonts/releases/latest"
    $tmp = Join-Path $env:TEMP "gm-erp2-nerdfonts"
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null

    $shell = New-Object -ComObject Shell.Application
    $fontsFolder = $shell.Namespace(0x14) # CSIDL_FONTS

    foreach ($fontName in $NerdFonts) {
        $already = Get-ChildItem "$env:windir\Fonts" -Filter "*$fontName*" -ErrorAction SilentlyContinue
        if ($already -and -not $Force) {
            Write-Log "  Nerd Font '$fontName' ya instalada, se omite." "INFO"
            continue
        }
        $asset = $release.assets | Where-Object { $_.name -eq "$fontName.zip" }
        if (-not $asset) {
            Write-Log "  No se encontró asset '$fontName.zip' en el release de nerd-fonts; ajusta el nombre." "WARN"
            continue
        }
        $zipPath = Join-Path $tmp "$fontName.zip"
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath
        $extractDir = Join-Path $tmp $fontName
        Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force
        $ttfs = Get-ChildItem $extractDir -Include *.ttf, *.otf -Recurse
        foreach ($f in $ttfs) {
            $fontsFolder.CopyHere($f.FullName, 0x10) # 0x10 = no dialogs
        }
        Write-Log "  Instalada Nerd Font: $fontName ($($ttfs.Count) archivos)" "OK"
    }
}

function Step-InstallCachyOS {
    $existing = (wsl -l -q 2>$null) | ForEach-Object { $_ -replace "`0","" }
    if ($existing -contains "cachyos" -and -not $Force) {
        Write-Log "  Distro 'cachyos' ya existe, se omite instalación (usa -Force para re-hacer)." "INFO"
        return
    }

    $downloadDir = Join-Path $env:LOCALAPPDATA "gm-erp2-setup\downloads"
    New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null

    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/dwalleck/cachyos-wsl/releases/latest"
    $asset   = $release.assets | Where-Object { $_.name -eq "cachyos-v3.wsl" }
    $sha256  = $release.assets | Where-Object { $_.name -eq "cachyos-v3.wsl.sha256" }
    if (-not $asset) { throw "No se encontró asset cachyos-v3.wsl en el release $($release.tag_name)" }

    $wslFile = Join-Path $downloadDir "cachyos-v3.wsl"
    $shaFile = Join-Path $downloadDir "cachyos-v3.wsl.sha256"
    Invoke-WebRequest -Uri $asset.browser_download_url  -OutFile $wslFile
    Invoke-WebRequest -Uri $sha256.browser_download_url -OutFile $shaFile

    $expected = (Get-Content $shaFile).Split(" ")[0].Trim().ToLower()
    $actual   = (Get-FileHash $wslFile -Algorithm SHA256).Hash.ToLower()
    if ($expected -ne $actual) { throw "Checksum mismatch descargando cachyos-v3.wsl (release $($release.tag_name))" }
    Write-Log "  Checksum verificado ($($release.tag_name))" "OK"

    if ($existing -contains "cachyos") {
        wsl --unregister cachyos | Out-Null
    }
    wsl --install --from-file $wslFile
    Start-Sleep -Seconds 5

    if (-not $CachyOSPassword) {
        $CachyOSPassword = Read-Host -AsSecureString "Password para el usuario '$CachyOSUsername' en CachyOS"
    }
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($CachyOSPassword)
    $plainPw = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)

    $bashProvision = @'
set -euo pipefail
USERNAME="$1"
id -u "$USERNAME" >/dev/null 2>&1 || useradd -m -G wheel -s /usr/bin/zsh "$USERNAME"
echo "$USERNAME:$CACHYOS_PW" | chpasswd
echo '%wheel ALL=(ALL:ALL) ALL' | tee /etc/sudoers.d/wheel >/dev/null
chmod 440 /etc/sudoers.d/wheel
visudo -c

UID_NUM=$(id -u "$USERNAME")
systemctl unmask "user@${UID_NUM}.service" 2>/dev/null || true
loginctl enable-linger "$USERNAME" 2>/dev/null || true

cat > /etc/wsl.conf <<EOF
[boot]
systemd = true

[network]
generateHosts = true
generateResolvConf = true

[interop]
enabled = true
appendWindowsPath = false

[user]
default = $USERNAME
EOF
echo "provision-user: OK"
'@

    try {
        $env:CACHYOS_PW = $plainPw
        $env:WSLENV = "CACHYOS_PW"
        $bashProvision | wsl -d cachyos -u root -- bash -s -- $CachyOSUsername
        if ($LASTEXITCODE -ne 0) { throw "El script de provisión de usuario terminó con código $LASTEXITCODE" }
    }
    finally {
        Remove-Item Env:\CACHYOS_PW -ErrorAction SilentlyContinue
        $plainPw = $null
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }

    wsl --shutdown
    Start-Sleep -Seconds 3
    $who = (wsl -d cachyos -- whoami).Trim()
    if ($who -ne $CachyOSUsername) { throw "Usuario default esperado '$CachyOSUsername', se obtuvo '$who'" }
    Write-Log "  Usuario '$CachyOSUsername' verificado como default en cachyos." "OK"
}

function Step-WriteWslConfig {
    $path = Join-Path $env:UserProfile ".wslconfig"
    if (Test-Path $path) {
        Copy-Item $path "$path.bak.$([int](Get-Date -UFormat %s))" -Force
    }
    $content = @"
[wsl2]
memory=${WslMemoryGB}GB
processors=$WslProcessors
swap=${WslSwapGB}GB
localhostForwarding=true
networkingMode=mirrored

[experimental]
sparseVhd=true
autoMemoryReclaim=gradual
"@
    Set-Content -Path $path -Value $content -Encoding ASCII
    Write-Log "  .wslconfig escrito en $path (swap=$WslSwapGB GB a propósito: el swap real va dentro de CachyOS)" "OK"
    wsl --shutdown
}

function Step-InstallAlacritty {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "winget no está disponible en este host; instálalo manualmente (App Installer desde Microsoft Store) y reintenta."
    }
    $installed = winget list --id Alacritty.Alacritty -e 2>$null | Select-String "Alacritty"
    if (-not $installed -or $Force) {
        winget install --id Alacritty.Alacritty -e --silent --accept-package-agreements --accept-source-agreements | Out-Null
    }

    $cfgDir  = Join-Path $env:APPDATA "alacritty"
    $cfgPath = Join-Path $cfgDir "alacritty.toml"
    New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null
    if (Test-Path $cfgPath) { Copy-Item $cfgPath "$cfgPath.bak.$([int](Get-Date -UFormat %s))" -Force }

    $primaryFont = $NerdFonts[0]
    $config = @"
[shell]
program = "wsl.exe"
args = ["-d", "cachyos"]

[font.normal]
family = "$primaryFont Nerd Font"

[font]
size = 11
"@
    Set-Content -Path $cfgPath -Value $config -Encoding UTF8
    $ver = & alacritty --version 2>$null
    Write-Log "  Alacritty instalado: $ver ; config en $cfgPath" "OK"
}

function Step-InstallClaudeWindows {
    if (-not $InstallClaudeOnWindows) { return }
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
        winget install --id OpenJS.NodeJS.LTS -e --silent --accept-package-agreements --accept-source-agreements | Out-Null
        # refresca PATH de la sesión actual sin reabrir la terminal
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
    }
    npm install -g @anthropic-ai/claude-code 2>&1 | Out-Null
    $ver = & claude --version 2>$null
    Write-Log "  Claude Code (Windows nativo): $ver" "OK"
}

function Step-ValidateAll {
    $report = [ordered]@{
        "wsl --version"        = (wsl --version 2>&1 | Select-Object -First 1)
        "distro cachyos"       = ((wsl -l -v 2>&1) -join " | ")
        "alacritty --version"  = (& alacritty --version 2>$null)
        "claude --version (win)" = (& claude --version 2>$null)
        ".wslconfig existe"    = (Test-Path (Join-Path $env:UserProfile ".wslconfig"))
    }
    foreach ($k in $report.Keys) { Write-Log ("  {0,-28}: {1}" -f $k, $report[$k]) "INFO" }
}

# ---------- main ----------
Assert-Admin
New-Item -ItemType Directory -Path $Script:LogDir -Force | Out-Null
Write-Log "=== windows-host-setup.ps1 v$Script:Version ===" "INFO"

Invoke-Step -Name "EnableWslFeatures" -Action { Step-EnableWslFeatures }
Invoke-Step -Name "UpdateWsl"         -Action { Step-UpdateWsl }
Invoke-Step -Name "InstallNerdFonts" -Action { Step-InstallNerdFonts }
Invoke-Step -Name "InstallCachyOS"   -Action { Step-InstallCachyOS }
Invoke-Step -Name "WriteWslConfig"   -Action { Step-WriteWslConfig }
Invoke-Step -Name "InstallAlacritty" -Action { Step-InstallAlacritty }
Invoke-Step -Name "InstallClaudeWin" -Action { Step-InstallClaudeWindows }
Invoke-Step -Name "ValidateAll"      -Action { Step-ValidateAll }

Write-Host "`n=== RESUMEN ===" -ForegroundColor Cyan
$Script:Results | Format-Table -AutoSize
$fails = $Script:Results | Where-Object Status -eq "FAIL"
Write-Log "Log completo en: $Script:LogFile" "INFO"
if ($fails.Count -gt 0) {
    Write-Log "$($fails.Count) paso(s) fallaron." "ERROR"
    exit 1
}
exit 0
