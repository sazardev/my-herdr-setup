#Requires -Version 5.1
<#
  windows-host-setup.ps1
  Provisioning idempotente del host Windows para gm-erp2:
  features de WSL, Nerd Fonts, CachyOS-WSL, .wslconfig, Alacritty, Claude Code (Windows).

  Version: 1.1.0
  Uso:
    .\windows-host-setup.ps1
    .\windows-host-setup.ps1 -Force                  # re-ejecuta todos los pasos aunque ya estén hechos
    .\windows-host-setup.ps1 -Only InstallCachyOS     # corre solo un paso
    .\windows-host-setup.ps1 -WslMemoryGB 20 -WslProcessors 18 -WslSwapGB 0
    .\windows-host-setup.ps1 -CachyOSUsername jdoe    # fuerza un usuario Linux distinto al detectado

  Script genérico para cualquier dev: por defecto, $CachyOSUsername NO está fijo a una persona --
  se deriva del usuario de Windows que corre el script ($env:USERNAME), saneado a un username
  Linux válido. Cada quien obtiene su propio usuario dentro de CachyOS con su propio nombre.
#>

[CmdletBinding()]
param(
    [string]   $CachyOSUsername   = (($env:USERNAME) -replace '[^a-zA-Z0-9]', '').ToLower(),
    [SecureString] $CachyOSPassword,
    [string[]] $NerdFonts         = @("JetBrainsMono"),
    [int]      $WslMemoryGB       = 20,
    [int]      $WslProcessors     = 18,
    [int]      $WslSwapGB         = 0,   # 0 a propósito: el swap real vive dentro de CachyOS (provision-cachyos.sh)
    [switch]   $Force,
    [string]   $Only,
    [switch]   $InstallClaudeOnWindows = $true
)

$Script:Version   = "1.1.0"
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

# ---------- helpers de ejecución/diagnóstico ----------
function Invoke-LoggedNative {
    # Corre un comando nativo, loguea cada línea de su salida (stdout+stderr) EN VIVO (streaming,
    # no bufereada) con un prefijo, y lanza si el exit code no es 0. Evita los "| Out-Null" que
    # ocultan fallas silenciosas.
    #
    # Además corre un heartbeat en un runspace separado (mismo proceso, por eso sí se ve en la
    # consola real) que imprime "sigue en ejecución" cada $HeartbeatSeconds si el comando no ha
    # producido salida nueva. Comandos como 'wsl --install --from-file' o 'winget install' pueden
    # quedarse varios minutos sin imprimir nada mientras extraen/descargan -- sin esto parece que
    # el script se congeló y el usuario cancela con Ctrl+C justo antes de que termine.
    param(
        [Parameter(Mandatory)][string]$Prefix,
        [Parameter(Mandatory)][scriptblock]$Command,
        [switch]$IgnoreExitCode,
        [int]$HeartbeatSeconds = 15
    )
    Write-Log "  >> $Prefix" "INFO"

    $hbRunspace = [runspacefactory]::CreateRunspace()
    $hbRunspace.Open()
    $hbPs = [powershell]::Create()
    $hbPs.Runspace = $hbRunspace
    [void]$hbPs.AddScript({
        param($Prefix, $HeartbeatSeconds, $LogFile)
        $elapsed = 0
        while ($true) {
            Start-Sleep -Seconds $HeartbeatSeconds
            $elapsed += $HeartbeatSeconds
            $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            $line = "[$ts] [INFO]     ... $Prefix sigue en ejecución (${elapsed}s sin salida nueva; normal en descargas/instalaciones grandes, no canceles)"
            Write-Host $line -ForegroundColor DarkGray
            Add-Content -Path $LogFile -Value $line -Encoding UTF8
        }
    }).AddArgument($Prefix).AddArgument($HeartbeatSeconds).AddArgument($Script:LogFile)
    [void]$hbPs.BeginInvoke()

    $lineCount = 0
    try {
        & $Command 2>&1 | ForEach-Object {
            $lineCount++
            Write-Log "    [$Prefix] $_" "INFO"
        }
        $code = $LASTEXITCODE
    }
    finally {
        $hbPs.Stop()
        $hbPs.Dispose()
        $hbRunspace.Close()
        $hbRunspace.Dispose()
    }

    if ($lineCount -eq 0) {
        Write-Log "    [$Prefix] (sin salida)" "INFO"
    }
    Write-Log "  << $Prefix (exit code: $code)" "INFO"
    if (-not $IgnoreExitCode -and $code -ne 0) {
        throw "$Prefix terminó con exit code $code"
    }
}

function Invoke-WithRetry {
    # Reintenta $Action hasta $MaxAttempts veces con espera $DelaySeconds entre intentos.
    # Pensado para llamadas de red (GitHub API / descargas) que pueden fallar de forma transitoria
    # en un AVD (throttling, DNS, hipo de red) -- sin esto, un solo hipo tira todo el paso a la basura.
    param(
        [Parameter(Mandatory)][string]$Prefix,
        [Parameter(Mandatory)][scriptblock]$Action,
        [int]$MaxAttempts = 3,
        [int]$DelaySeconds = 10
    )
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            return & $Action
        } catch {
            if ($attempt -ge $MaxAttempts) {
                Write-Log "  $Prefix : falló tras $attempt intento(s), no quedan reintentos -- $($_.Exception.Message)" "ERROR"
                throw
            }
            Write-Log "  $Prefix : falló (intento $attempt/$MaxAttempts) -- $($_.Exception.Message). Reintentando en ${DelaySeconds}s..." "WARN"
            Start-Sleep -Seconds $DelaySeconds
        }
    }
}

function Get-CachyDistroName {
    # WSL registra el nombre tal cual viene del paquete .wsl (p.ej. "CachyOS"), no necesariamente
    # en minúsculas. Buscamos el nombre real registrado en vez de asumir "cachyos" a pelo.
    $names = (wsl -l -q 2>$null) | ForEach-Object { $_ -replace "`0","" } | Where-Object { $_ -ne "" }
    Write-Log "  Distros registradas actualmente: $($names -join ', ')" "INFO"
    $match = $names | Where-Object { $_ -ieq "cachyos" } | Select-Object -First 1
    if ($match) { return $match }
    return "cachyos"
}

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

function Step-Preflight {
    # Diagnóstico exhaustivo del entorno ANTES de tocar nada. No decide si continuar o no,
    # solo deja evidencia en el log de todo lo que podría explicar un fallo silencioso más
    # adelante (permisos, virtualización deshabilitada, wsl.exe viejo, instalación corrupta previa).
    Write-Log "===== PRE-FLIGHT: diagnóstico de entorno =====" "INFO"

    try {
        $cs = Get-ComputerInfo -Property OsName, OsBuildNumber, OsVersion, HyperVisorPresent, HyperVRequirementVirtualizationFirmwareEnabled -ErrorAction Stop
        Write-Log "  OS: $($cs.OsName) build $($cs.OsBuildNumber) ($($cs.OsVersion))" "INFO"
        Write-Log "  Hypervisor activo (HyperVisorPresent): $($cs.HyperVisorPresent)" "INFO"
        Write-Log "  Virtualización habilitada en firmware: $($cs.HyperVRequirementVirtualizationFirmwareEnabled)" "INFO"
        if ($cs.HyperVRequirementVirtualizationFirmwareEnabled -eq $false) {
            Write-Log "  ADVERTENCIA: VT-x/AMD-V parece deshabilitado en BIOS/UEFI. WSL2 no puede arrancar la VM subyacente sin esto -- esto por sí solo puede explicar que CachyOS 'abra' una ventana pero no llegue a registrarse." "WARN"
        }
    } catch {
        Write-Log "  No se pudo leer Get-ComputerInfo: $($_.Exception.Message)" "WARN"
    }

    foreach ($f in @("Microsoft-Windows-Subsystem-Linux", "VirtualMachinePlatform")) {
        try {
            $st = (Get-WindowsOptionalFeature -Online -FeatureName $f -ErrorAction Stop).State
            Write-Log "  Feature '$f': $st" "INFO"
            if ($st -ne "Enabled") {
                Write-Log "  ADVERTENCIA: feature '$f' no está habilitada todavía; se intentará habilitar en el paso EnableWslFeatures (puede requerir reinicio)." "WARN"
            }
        } catch {
            Write-Log "  No se pudo consultar feature '$f': $($_.Exception.Message)" "WARN"
        }
    }

    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        Write-Log "  CRÍTICO: wsl.exe no está en PATH. WSL no está instalado en este host." "ERROR"
    } else {
        $verRaw = (wsl --version 2>&1) -join "`n"
        Write-Log "  wsl --version:`n$verRaw" "INFO"
    }

    $names = (wsl -l -q 2>$null) | ForEach-Object { $_ -replace "`0","" } | Where-Object { $_ -ne "" }
    Write-Log "  Distros reportadas por 'wsl -l -q' ahora mismo: $(if ($names) { $names -join ', ' } else { '(ninguna)' })" "INFO"

    $lxssPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss"
    if (Test-Path $lxssPath) {
        $entries = Get-ChildItem $lxssPath -ErrorAction SilentlyContinue
        Write-Log "  Entradas existentes en registro Lxss para este usuario: $($entries.Count)" "INFO"
        foreach ($key in $entries) {
            $props = Get-ItemProperty $key.PSPath -ErrorAction SilentlyContinue
            $bp = $props.BasePath
            $vhdOk = if ($bp -and $props.VhdFileName) { Test-Path (Join-Path $bp $props.VhdFileName) } else { $false }
            Write-Log "    - '$($props.DistributionName)' State=$($props.State) BasePath='$bp' vhdx_existe=$vhdOk" "INFO"
            if ($bp -and -not $vhdOk) {
                Write-Log "  ADVERTENCIA: '$($props.DistributionName)' está en el registro pero su vhdx NO existe en disco -- instalación previa corrupta/incompleta." "WARN"
            }
        }
    } else {
        Write-Log "  No existe todavía la clave de registro Lxss para el usuario '$($env:USERNAME)' (ninguna distro registrada aún bajo este perfil)." "INFO"
    }

    foreach ($dir in @($env:LOCALAPPDATA, $env:APPDATA, $env:UserProfile, $Script:StateDir)) {
        try {
            $testFile = Join-Path $dir (".gm-erp2-write-test-{0}" -f (Get-Random))
            New-Item -ItemType File -Path $testFile -Force -ErrorAction Stop | Out-Null
            Remove-Item $testFile -Force -ErrorAction SilentlyContinue
            Write-Log "  Permiso de escritura OK en: $dir" "INFO"
        } catch {
            Write-Log "  ADVERTENCIA: SIN permiso de escritura en '$dir' -- $($_.Exception.Message). Esto puede romper la descarga/instalación silenciosamente." "WARN"
        }
    }

    try {
        $mp = Get-MpComputerStatus -ErrorAction Stop
        Write-Log "  Windows Defender - RealTimeProtectionEnabled: $($mp.RealTimeProtectionEnabled)" "INFO"
    } catch {
        Write-Log "  No se pudo consultar el estado de Windows Defender (puede haber otro antivirus activo, o no hay permisos para consultarlo)." "INFO"
    }

    try {
        Invoke-WebRequest -Uri "https://api.github.com" -Method Head -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop | Out-Null
        Write-Log "  Conectividad a api.github.com: OK" "INFO"
    } catch {
        Write-Log "  ADVERTENCIA: sin conectividad a api.github.com ($($_.Exception.Message)). Las descargas de CachyOS/Nerd Fonts/Alacritty van a fallar." "WARN"
    }

    Write-Log "===== FIN PRE-FLIGHT =====" "INFO"
}

function Step-EnableWslFeatures {
    $features = @("Microsoft-Windows-Subsystem-Linux", "VirtualMachinePlatform")
    $needsRestart = $false
    foreach ($f in $features) {
        $state = (Get-WindowsOptionalFeature -Online -FeatureName $f).State
        Write-Log "  Feature '$f' estado actual: $state" "INFO"
        if ($state -ne "Enabled") {
            Write-Log "  Habilitando feature '$f'..." "INFO"
            $r = Enable-WindowsOptionalFeature -Online -FeatureName $f -All -NoRestart
            Write-Log "  Feature '$f' -> RestartNeeded=$($r.RestartNeeded)" "INFO"
            if ($r.RestartNeeded) { $needsRestart = $true }
        }
    }
    if ($needsRestart) {
        Write-Log "Se habilitaron features nuevas; puede requerir reinicio de Windows antes de continuar." "WARN"
    }
    Invoke-LoggedNative -Prefix "wsl --set-default-version 2" -Command { wsl --set-default-version 2 }
}

function Step-UpdateWsl {
    Invoke-LoggedNative -Prefix "wsl --update" -Command { wsl --update } -IgnoreExitCode
    $v = wsl --version 2>&1
    Write-Log "wsl --version:`n$v" "INFO"
}

function Step-InstallNerdFonts {
    Write-Log "  Consultando último release de ryanoasis/nerd-fonts..." "INFO"
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/ryanoasis/nerd-fonts/releases/latest"
    Write-Log "  Release encontrado: $($release.tag_name)" "INFO"
    $tmp = Join-Path $env:TEMP "gm-erp2-nerdfonts"
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null

    $shell = New-Object -ComObject Shell.Application
    $fontsFolder = $shell.Namespace(0x14) # CSIDL_FONTS

    foreach ($fontName in $NerdFonts) {
        $already = Get-ChildItem "$env:windir\Fonts" -Filter "*$fontName*" -ErrorAction SilentlyContinue
        if ($already -and -not $Force) {
            Write-Log "  Nerd Font '$fontName' ya instalada ($($already.Count) archivo(s) encontrados), se omite." "INFO"
            continue
        }
        $asset = $release.assets | Where-Object { $_.name -eq "$fontName.zip" }
        if (-not $asset) {
            Write-Log "  No se encontró asset '$fontName.zip' en el release de nerd-fonts; ajusta el nombre." "WARN"
            continue
        }
        $zipPath = Join-Path $tmp "$fontName.zip"
        Write-Log "  Descargando $($asset.browser_download_url) -> $zipPath" "INFO"
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath
        $sizeMB = [Math]::Round((Get-Item $zipPath).Length / 1048576, 1)
        Write-Log "  Descarga completa ($sizeMB MB), extrayendo..." "INFO"
        $extractDir = Join-Path $tmp $fontName
        Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force
        $ttfs = Get-ChildItem $extractDir -Include *.ttf, *.otf -Recurse
        Write-Log "  $($ttfs.Count) archivo(s) de fuente encontrados, copiando a $env:windir\Fonts..." "INFO"
        foreach ($f in $ttfs) {
            $fontsFolder.CopyHere($f.FullName, 0x10) # 0x10 = no dialogs
        }
        Write-Log "  Instalada Nerd Font: $fontName ($($ttfs.Count) archivos)" "OK"
    }
}

function Test-CachyOSRegistered {
    # Verdad de campo: ¿existe realmente y coincide lo que reporta 'wsl -l' con lo que hay en el registro y en disco?
    param([switch]$Quiet)
    $names = (wsl -l -q 2>$null) | ForEach-Object { $_ -replace "`0","" } | Where-Object { $_ -ne "" }
    $wslMatch = $names | Where-Object { $_ -ieq "cachyos" } | Select-Object -First 1

    $lxssPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss"
    $regMatch = $null
    $regBasePath = $null
    $regVhdExists = $false
    if (Test-Path $lxssPath) {
        foreach ($key in Get-ChildItem $lxssPath -ErrorAction SilentlyContinue) {
            $props = Get-ItemProperty $key.PSPath -ErrorAction SilentlyContinue
            if ($props.DistributionName -ieq "cachyos") {
                $regMatch = $props.DistributionName
                $regBasePath = $props.BasePath
                if ($regBasePath -and $props.VhdFileName) {
                    $regVhdExists = Test-Path (Join-Path $regBasePath $props.VhdFileName)
                }
                break
            }
        }
    }

    if (-not $Quiet) {
        Write-Log "  Verificación cruzada: 'wsl -l -q' -> $(if ($wslMatch) { "'$wslMatch'" } else { 'NO aparece' })" "INFO"
        Write-Log "  Verificación cruzada: registro Lxss  -> $(if ($regMatch) { "'$regMatch' (BasePath=$regBasePath, vhdx existe=$regVhdExists)" } else { 'NO hay entrada' })" "INFO"
        if ($regMatch -and -not $wslMatch) {
            Write-Log "  DIAGNÓSTICO: hay entrada en el registro pero 'wsl -l' no la reporta -> instalación corrupta o servicio LxssManager con estado inconsistente. Prueba 'wsl --shutdown' y reintenta, o borra la clave y reinstala con -Force." "WARN"
        }
        if ($regMatch -and $regBasePath -and -not $regVhdExists) {
            Write-Log "  DIAGNÓSTICO: el registro apunta a '$regBasePath' pero el .vhdx no existe en disco -> instalación incompleta (falló a medias, o algo borró la carpeta). Antivirus/Defender puede haber puesto en cuarentena el vhdx recién creado." "WARN"
        }
        if (-not $regMatch -and -not $wslMatch) {
            Write-Log "  DIAGNÓSTICO: no hay ni entrada de registro ni reporte de 'wsl -l' -> 'wsl --install --from-file' no llegó a registrar nada. Revisa el bloque anterior de este log (exit code y salida de ese comando) para la causa exacta." "WARN"
        }
    }
    return [pscustomobject]@{ WslName = $wslMatch; RegName = $regMatch; RegBasePath = $regBasePath; VhdExists = $regVhdExists }
}

function ConvertTo-NativeLastLine {
    # 'comando_nativo 2>&1' devuelve una MEZCLA de [string] (stdout) y [ErrorRecord] (stderr);
    # ErrorRecord no tiene .Trim(), así que sin esto cualquier warning benigno en stderr durante
    # un arranque en frío de WSL rompe el script con "does not contain a method named 'Trim'".
    param([Parameter(ValueFromPipeline)]$InputObject)
    begin { $lines = [System.Collections.Generic.List[string]]::new() }
    process { if ($null -ne $InputObject) { $lines.Add($InputObject.ToString()) } }
    end {
        $nonEmpty = $lines | Where-Object { $_.Trim() -ne "" }
        if ($nonEmpty.Count -eq 0) { return "" }
        return ($nonEmpty | Select-Object -Last 1).Trim()
    }
}

function Repair-CachyOSDefaultUser {
    # Falla conocida de las imágenes .wsl empaquetadas: el DefaultUid que queda en el registro
    # de Windows (Lxss) a veces gana sobre el '[user] default' de /etc/wsl.conf tras reinicios o
    # reintentos de instalación, y 'wsl -d Distro' termina abriendo como root en vez del usuario
    # provisionado. Se repara reescribiendo wsl.conf y, si el cliente wsl lo soporta, forzando el
    # default vía 'wsl --manage --set-default-user'.
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [Parameter(Mandatory)][string]$Username
    )
    Write-Log "  Usuario default incorrecto; se reescribe /etc/wsl.conf y se reintenta..." "WARN"

    $fixConf = @'
set -euo pipefail
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
default = $1
EOF
echo "wsl.conf reescrito con [user] default = $1"
'@
    $out = $fixConf | wsl -d $DistroName -u root -- bash -s -- $Username 2>&1
    $out | ForEach-Object { Write-Log "    [repair-wsl.conf] $($_.ToString())" "INFO" }

    Invoke-LoggedNative -Prefix "wsl --manage $DistroName --set-default-user $Username (best-effort, puede no existir en este cliente wsl)" -Command {
        wsl --manage $DistroName --set-default-user $Username
    } -IgnoreExitCode

    Invoke-LoggedNative -Prefix "wsl --shutdown" -Command { wsl --shutdown } -IgnoreExitCode
    Start-Sleep -Seconds 5
}

function Test-CachyOSHealthy {
    # Verificación de campo de que CachyOS no solo "está registrada" sino que funciona:
    # arranca, systemd corre, y el usuario quedó con el grupo/shell que el provisioning debía darle.
    # Se usa tanto después de una instalación nueva como al detectar que ya existía (idempotencia real,
    # no solo "wsl -l la reporta").
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [Parameter(Mandatory)][string]$Username
    )
    $reg = Test-CachyOSRegistered
    if (-not $reg.WslName) {
        throw "CachyOS no aparece registrada en 'wsl -l -q' -- revisa el DIAGNÓSTICO impreso arriba."
    }

    $who = wsl -d $DistroName -- whoami 2>&1 | ConvertTo-NativeLastLine
    Write-Log "  Usuario default reportado por 'wsl -d $DistroName -- whoami': '$who'" "INFO"
    if ($who -ne $Username) {
        Repair-CachyOSDefaultUser -DistroName $DistroName -Username $Username
        $who = wsl -d $DistroName -- whoami 2>&1 | ConvertTo-NativeLastLine
        Write-Log "  Usuario default reportado tras reparación: '$who'" "INFO"
        if ($who -ne $Username) {
            throw "Usuario default esperado '$Username' en '$DistroName', se obtuvo '$who' (incluso tras reescribir wsl.conf y reintentar)."
        }
    }
    Write-Log "  Usuario '$Username' verificado como default en '$DistroName'." "OK"

    $sysState = wsl -d $DistroName -u root -- systemctl is-system-running 2>&1 | ConvertTo-NativeLastLine
    Write-Log "  Estado de systemd ('systemctl is-system-running'): '$sysState'" "INFO"
    if ($sysState -in @("running", "degraded")) {
        Write-Log "  systemd operativo dentro de '$DistroName' (estado: $sysState; 'degraded' es normal y no bloquea nada)." "OK"
    } else {
        Write-Log "  ADVERTENCIA: systemd no reporta 'running'/'degraded' sino '$sysState' -- '[boot] systemd=true' puede no haber tomado efecto. Prueba 'wsl --shutdown' y vuelve a abrir la distro; si persiste, revisa 'wsl -d $DistroName -u root -- systemctl --failed'." "WARN"
    }

    $idOut = wsl -d $DistroName -- id $Username 2>&1 | ConvertTo-NativeLastLine
    Write-Log "  'id $Username' -> $idOut" "INFO"
    if ($idOut -notmatch "\bwheel\b") {
        throw "El usuario '$Username' no quedó en el grupo 'wheel' dentro de '$DistroName' (sudo no va a funcionar): $idOut"
    }

    $shellOut = wsl -d $DistroName -- getent passwd $Username 2>&1 | ConvertTo-NativeLastLine
    Write-Log "  'getent passwd $Username' -> $shellOut" "INFO"
    if ($shellOut -notmatch "/usr/bin/zsh$") {
        throw "El shell default de '$Username' en '$DistroName' no quedó en /usr/bin/zsh: $shellOut"
    }
    Write-Log "  Grupo 'wheel' y shell 'zsh' verificados para '$Username' en '$DistroName'." "OK"
}

function Invoke-CachyOSUserProvision {
    # Crea (si no existe) y configura el usuario Linux dentro de la distro: grupo wheel, shell zsh,
    # password, y '[user] default' en wsl.conf. Se usa tanto tras una instalación fresca como cuando
    # la distro ya existía pero es la primera vez que ESTE usuario de Windows la usa (username genérico
    # por dev: la distro puede haber sido provisionada originalmente para otra persona).
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [Parameter(Mandatory)][string]$Username,
        [SecureString]$Password
    )
    if (-not $Password) {
        $Password = Read-Host -AsSecureString "Password para el usuario '$Username' en CachyOS"
    }
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
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

    Write-Log "  Provisión de usuario '$Username' dentro de '$DistroName' (root)" "INFO"
    try {
        $env:CACHYOS_PW = $plainPw
        $env:WSLENV = "CACHYOS_PW"
        $provisionOut = $bashProvision | wsl -d $DistroName -u root -- bash -s -- $Username 2>&1
        $code = $LASTEXITCODE
        $provisionOut | ForEach-Object { Write-Log "    [provision-user] $($_.ToString())" "INFO" }
        Write-Log "  Script de provisión de usuario -> exit code: $code" "INFO"
        if ($code -ne 0) { throw "El script de provisión de usuario terminó con código $code" }
    }
    finally {
        Remove-Item Env:\CACHYOS_PW -ErrorAction SilentlyContinue
        $plainPw = $null
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }

    Invoke-LoggedNative -Prefix "wsl --shutdown" -Command { wsl --shutdown } -IgnoreExitCode
    Start-Sleep -Seconds 3
}

function Step-InstallCachyOS {
    Write-Log "  [1/5] Chequeos previos" "INFO"
    $distroName = Get-CachyDistroName
    $existing = (wsl -l -q 2>$null) | ForEach-Object { $_ -replace "`0","" }
    if (($existing | Where-Object { $_ -ieq "cachyos" }) -and -not $Force) {
        Write-Log "  Distro CachyOS ya existe (nombre registrado: '$distroName'), se omite instalación (usa -Force para re-hacer)." "INFO"
        wsl -d $distroName -- id -u $CachyOSUsername 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Log "  El usuario '$CachyOSUsername' no existe todavía dentro de '$distroName' (la distro fue provisionada para alguien más, o es la primera vez que este perfil de Windows la usa); se crea ahora." "WARN"
            Invoke-CachyOSUserProvision -DistroName $distroName -Username $CachyOSUsername -Password $CachyOSPassword
        }
        Test-CachyOSHealthy -DistroName $distroName -Username $CachyOSUsername
        return
    }

    # wsl --install --from-file (paquetes .wsl) requiere una versión razonablemente reciente del cliente wsl.
    $verRaw = (wsl --version 2>&1) -join "`n"
    Write-Log "  wsl --version actual:`n$verRaw" "INFO"
    $verLine = $verRaw | Select-String "WSL version" | Select-Object -First 1
    if ($verLine) {
        $verStr = ($verLine.ToString() -replace ".*:\s*","").Trim()
        try {
            if ([version]$verStr -lt [version]"2.4.4") {
                Write-Log "  ADVERTENCIA: wsl versión $verStr puede no soportar bien 'wsl --install --from-file' (paquetes .wsl). Corre 'wsl --update' manualmente si esta instalación falla." "WARN"
            }
        } catch { }
    } else {
        Write-Log "  ADVERTENCIA: no se pudo determinar la versión de wsl.exe desde su salida; puede que WSL no esté correctamente instalado." "WARN"
    }

    $downloadDir = Join-Path $env:LOCALAPPDATA "gm-erp2-setup\downloads"
    New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null
    $freeGB = [Math]::Round((Get-PSDrive -Name ($downloadDir.Substring(0,1))).Free / 1073741824, 1)
    Write-Log "  Espacio libre en $($downloadDir.Substring(0,2)): $freeGB GB" "INFO"
    if ($freeGB -lt 10) {
        Write-Log "  ADVERTENCIA: menos de 10 GB libres; la instalación de CachyOS (rootfs + crecimiento del vhdx) puede fallar por espacio." "WARN"
    }

    Write-Log "  [2/5] Descarga y verificación del paquete .wsl" "INFO"
    $release = Invoke-WithRetry -Prefix "GET release dwalleck/cachyos-wsl" -Action {
        Invoke-RestMethod -Uri "https://api.github.com/repos/dwalleck/cachyos-wsl/releases/latest"
    }
    Write-Log "  Release encontrado: $($release.tag_name)" "INFO"
    $asset   = $release.assets | Where-Object { $_.name -eq "cachyos-v3.wsl" }
    $sha256  = $release.assets | Where-Object { $_.name -eq "cachyos-v3.wsl.sha256" }
    if (-not $asset)  { throw "No se encontró asset cachyos-v3.wsl en el release $($release.tag_name)" }
    if (-not $sha256) { throw "No se encontró asset cachyos-v3.wsl.sha256 en el release $($release.tag_name)" }
    $assetSizeMB = [Math]::Round($asset.size / 1048576, 1)
    Write-Log "  Asset: $($asset.name) ($assetSizeMB MB)" "INFO"

    $wslFile = Join-Path $downloadDir "cachyos-v3.wsl"
    $shaFile = Join-Path $downloadDir "cachyos-v3.wsl.sha256"
    Invoke-WithRetry -Prefix "descarga de $($sha256.name)" -Action {
        Invoke-WebRequest -Uri $sha256.browser_download_url -OutFile $shaFile
    } | Out-Null
    $expected = (Get-Content $shaFile).Split(" ")[0].Trim().ToLower()
    Write-Log "  Checksum esperado: $expected" "INFO"

    if ((Test-Path $wslFile) -and ((Get-FileHash $wslFile -Algorithm SHA256).Hash.ToLower() -eq $expected)) {
        Write-Log "  '$($asset.name)' ya está en caché en $wslFile y su checksum coincide; se omite la descarga de $assetSizeMB MB." "OK"
    } else {
        Invoke-WithRetry -Prefix "descarga de $($asset.name)" -MaxAttempts 3 -DelaySeconds 15 -Action {
            Write-Log "  Descargando $($asset.browser_download_url) -> $wslFile" "INFO"
            Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $wslFile
            $downloadedSizeMB = [Math]::Round((Get-Item $wslFile).Length / 1048576, 1)
            Write-Log "  Descarga completa ($downloadedSizeMB MB), verificando checksum..." "INFO"
            $actual = (Get-FileHash $wslFile -Algorithm SHA256).Hash.ToLower()
            Write-Log "  Checksum obtenido:  $actual" "INFO"
            if ($expected -ne $actual) {
                Remove-Item $wslFile -Force -ErrorAction SilentlyContinue
                throw "Checksum mismatch descargando $($asset.name) (release $($release.tag_name)) -- descarga corrupta o interceptada."
            }
        } | Out-Null
        Write-Log "  Checksum verificado ($($release.tag_name))" "OK"
    }

    if ($existing | Where-Object { $_ -ieq "cachyos" }) {
        Write-Log "  Desregistrando distro CachyOS existente ('$distroName') antes de reinstalar (-Force)..." "WARN"
        Invoke-LoggedNative -Prefix "wsl --unregister $distroName" -Command { wsl --unregister $distroName } -IgnoreExitCode
    }

    Write-Log "  [3/5] Instalación (wsl --install --from-file)" "INFO"
    $maxInstallAttempts = 2
    $check = $null
    for ($attempt = 1; $attempt -le $maxInstallAttempts; $attempt++) {
        Invoke-LoggedNative -Prefix "wsl --install --from-file $wslFile (intento $attempt/$maxInstallAttempts)" -Command { wsl --install --from-file $wslFile } -IgnoreExitCode
        Start-Sleep -Seconds 5
        $check = Test-CachyOSRegistered
        if ($check.WslName) { break }
        if ($attempt -lt $maxInstallAttempts) {
            Write-Log "  La distro no quedó registrada en el intento $attempt; se limpia el estado parcial y se reintenta..." "WARN"
            Invoke-LoggedNative -Prefix "wsl --shutdown" -Command { wsl --shutdown } -IgnoreExitCode
            if ($check.RegName) {
                Invoke-LoggedNative -Prefix "wsl --unregister $($check.RegName) (limpieza de instalación parcial)" -Command { wsl --unregister $check.RegName } -IgnoreExitCode
            }
            Start-Sleep -Seconds 5
        }
    }
    if (-not $check.WslName) {
        throw "Tras $maxInstallAttempts intento(s) de 'wsl --install --from-file' la distro NO aparece en 'wsl -l -q'. Revisa el DIAGNÓSTICO impreso arriba (registro/vhdx) y la salida del comando de instalación para la causa raíz."
    }
    $distroName = $check.WslName
    Write-Log "  Distro registrada exitosamente como: '$distroName'" "OK"

    Write-Log "  [4/5] Provisión de usuario dentro de la distro (root)" "INFO"
    Invoke-CachyOSUserProvision -DistroName $distroName -Username $CachyOSUsername -Password $CachyOSPassword

    Write-Log "  [5/5] Verificación final" "INFO"
    Test-CachyOSHealthy -DistroName $distroName -Username $CachyOSUsername
}

function Step-WriteWslConfig {
    $path = Join-Path $env:UserProfile ".wslconfig"
    if (Test-Path $path) {
        $ts = [int](Get-Date -UFormat %s)
        $bak = "$path.bak.$ts"
        Copy-Item $path $bak -Force
        Write-Log "  Backup de .wslconfig existente -> $bak" "INFO"
    } else {
        Write-Log "  No existía .wslconfig previo en $path" "INFO"
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
    Write-Log "  Contenido a escribir:`n$content" "INFO"
    Set-Content -Path $path -Value $content -Encoding ASCII
    Write-Log "  .wslconfig escrito en $path (swap=$WslSwapGB GB a propósito: el swap real va dentro de CachyOS)" "OK"
    Invoke-LoggedNative -Prefix "wsl --shutdown" -Command { wsl --shutdown } -IgnoreExitCode
}

function Step-InstallAlacritty {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "winget no está disponible en este host; instálalo manualmente (App Installer desde Microsoft Store) y reintenta."
    }
    $installed = winget list --id Alacritty.Alacritty -e 2>$null | Select-String "Alacritty"
    $installedBool = [bool]$installed
    Write-Log "  Alacritty ya instalado según winget: $installedBool" "INFO"
    if (-not $installed -or $Force) {
        Invoke-LoggedNative -Prefix "winget install Alacritty.Alacritty" -Command {
            winget install --id Alacritty.Alacritty -e --silent --accept-package-agreements --accept-source-agreements
        }
    }

    # Config real versionada (sazardev/my-alacritty-setup), no una genérica inventada:
    # JetBrainsMono NFM, tema Gruvbox, keybindings de zoom/maximize/shift+enter, etc.
    $tmp = Join-Path $env:TEMP "gm-erp2-alacritty-setup"
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $zipPath = Join-Path $tmp "repo.zip"
    Write-Log "  Descargando config de sazardev/my-alacritty-setup..." "INFO"
    Invoke-WebRequest -Uri "https://github.com/sazardev/my-alacritty-setup/archive/refs/heads/main.zip" -OutFile $zipPath
    Expand-Archive -Path $zipPath -DestinationPath $tmp -Force
    $repoDir = Get-ChildItem $tmp -Directory | Where-Object { $_.Name -like "my-alacritty-setup-*" } | Select-Object -First 1
    if (-not $repoDir) { throw "No se pudo extraer sazardev/my-alacritty-setup" }

    $cfgDir = Join-Path $env:APPDATA "alacritty"
    New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null
    foreach ($f in @("alacritty.toml", "local.toml")) {
        $src = Join-Path $repoDir.FullName $f
        $dst = Join-Path $cfgDir $f
        if (Test-Path $dst) {
            $ts = [int](Get-Date -UFormat %s)
            $bak = "$dst.bak.$ts"
            Copy-Item $dst $bak -Force
            Write-Log "  Backup de $f -> $bak" "INFO"
        }
        Copy-Item $src $dst -Force
        Write-Log "  Copiado $f -> $dst" "INFO"
    }
    $themesSrc = Join-Path $repoDir.FullName "themes"
    if (Test-Path $themesSrc) { Copy-Item $themesSrc $cfgDir -Recurse -Force }

    # el repo asume el nombre de distro "CachyOS"; usamos el nombre REAL con el que quedó
    # registrada (puede no ser exactamente "CachyOS" según el .wsl instalado)
    $distroName = Get-CachyDistroName
    $localTomlPath = Join-Path $cfgDir "local.toml"
    if (Test-Path $localTomlPath) {
        (Get-Content $localTomlPath -Raw) -replace '"CachyOS"', "`"$distroName`"" | Set-Content $localTomlPath -Encoding UTF8
        Write-Log "  local.toml ajustado para usar la distro '$distroName' (detectada en 'wsl -l -q')" "OK"
    } else {
        Write-Log "  ADVERTENCIA: no se encontró local.toml en $cfgDir tras copiar el repo; Alacritty no tendrá shell configurado." "WARN"
    }

    $ver = & alacritty --version 2>$null
    Write-Log "  Alacritty instalado: $ver ; config real de sazardev/my-alacritty-setup en $cfgDir" "OK"
    Write-Log "  Verifica que la fuente 'JetBrainsMono NFM' quedó registrada (ver README del repo para el chequeo con System.Drawing)" "INFO"
}

function Step-InstallClaudeWindows {
    if (-not $InstallClaudeOnWindows) {
        Write-Log "  InstallClaudeOnWindows=false, se omite este paso." "INFO"
        return
    }
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
        Write-Log "  Node.js no encontrado, instalando OpenJS.NodeJS.LTS via winget..." "INFO"
        Invoke-LoggedNative -Prefix "winget install OpenJS.NodeJS.LTS" -Command {
            winget install --id OpenJS.NodeJS.LTS -e --silent --accept-package-agreements --accept-source-agreements
        }
        # refresca PATH de la sesión actual sin reabrir la terminal
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
        Write-Log "  PATH refrescado tras instalar Node.js" "INFO"
    } else {
        Write-Log "  Node.js ya presente: $(node --version 2>$null)" "INFO"
    }
    Invoke-LoggedNative -Prefix "npm install -g @anthropic-ai/claude-code" -Command {
        npm install -g @anthropic-ai/claude-code
    }
    $ver = & claude --version 2>$null
    Write-Log "  Claude Code (Windows nativo): $ver" "OK"
}

function Step-ValidateAll {
    $check = Test-CachyOSRegistered
    $sysState = "N/D (distro no registrada)"
    if ($check.WslName) {
        try {
            $sysState = wsl -d $check.WslName -u root -- systemctl is-system-running 2>&1 | ConvertTo-NativeLastLine
        } catch { $sysState = "error consultando: $($_.Exception.Message)" }
    }
    $report = [ordered]@{
        "wsl --version"          = (wsl --version 2>&1 | Select-Object -First 1)
        "distro (wsl -l -v)"     = ((wsl -l -v 2>&1) -join " | ")
        "distro nombre detectado"= (if ($check.WslName) { $check.WslName } else { "NO REGISTRADA" })
        "distro vhdx en disco"   = $check.VhdExists
        "distro systemd status" = $sysState
        "alacritty --version"    = (& alacritty --version 2>$null)
        "claude --version (win)" = (& claude --version 2>$null)
        ".wslconfig existe"      = (Test-Path (Join-Path $env:UserProfile ".wslconfig"))
    }
    foreach ($k in $report.Keys) { Write-Log ("  {0,-28}: {1}" -f $k, $report[$k]) "INFO" }
    if (-not $check.WslName) {
        Write-Log "  RESULTADO: CachyOS NO está registrada en este momento. Revisa los bloques 'DIAGNÓSTICO' y '[wsl --install]' más arriba en este mismo log para la causa." "ERROR"
    }
}

# ---------- main ----------
Assert-Admin
New-Item -ItemType Directory -Path $Script:LogDir -Force | Out-Null
Write-Log "=== windows-host-setup.ps1 v$Script:Version ===" "INFO"
Write-Log "Log file: $Script:LogFile" "INFO"
$idCheck = [Security.Principal.WindowsIdentity]::GetCurrent()
Write-Log "Identidad del proceso: $($idCheck.Name) (elevado)" "INFO"
Write-Log "Usuario interactivo esperado: $($env:USERDOMAIN)\$($env:USERNAME) | UserProfile: $env:UserProfile" "INFO"
$osVersionString = [System.Environment]::OSVersion.VersionString
Write-Log "Host: $env:COMPUTERNAME | PS: $($PSVersionTable.PSVersion) | OS: $osVersionString" "INFO"
if ($idCheck.Name -notlike "*\$($env:USERNAME)") {
    Write-Log "ADVERTENCIA: la identidad elevada ('$($idCheck.Name)') no coincide con el usuario interactivo ('$($env:USERNAME)'). Si tu Windows pide credenciales de OTRA cuenta admin al elevar, WSL/CachyOS quedará registrado bajo el perfil de esa cuenta y no aparecerá para tu usuario normal." "WARN"
}

# Preflight siempre corre (aunque se use -Only), es puro diagnóstico y no tiene estado idempotente.
Step-Preflight

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
