<#
.SYNOPSIS
    Silent install of DIAScreen from Delta's installers: the base release
    (DIAScreen 1.8) followed by the patch on top of it
    (DELTA_IA-OSW_DIAScreen_V1.8.1_SW_202607.exe = "DIAScreen 1.8.1.19
    Patch" - it only updates an existing 1.8 install, on its own it
    installs nothing).

    Base: an NSIS wrapper around an uncompressed InstallShield layout
    ("DIAScreen 1.8.exe" launcher + "DIAScreen 1.8.msi" + 1033.mst +
    ISSetupPrerequisites\...). The wrapper and the InstallShield launcher
    are both interactive (the launcher's /s hangs on CI), so the layout is
    unpacked with 7-Zip and the MSI is installed with msiexec directly. Of
    the launcher's prerequisites only VC++ 2013 and CodeMeter Runtime
    (DIAScreen will not start without it) are installed - the hosted
    runner already has .NET 4.8 and VC++ 2015-2022; GeneralPackage and
    DIAStudioTool are not needed to compile/simulate.

    Patch: an InstallShield launcher, run with /s /v"/qn".

    Every installer runs under a watchdog: once a minute it logs the
    windows/dialogs of the installer's process tree and takes a
    screenshot, and on timeout kills the tree - so a hang shows what it
    was waiting for instead of eating the job's time limit.
#>
param(
    [Parameter(Mandatory = $true)][string]$BaseInstallerPath,
    [string]$PatchInstallerPath = "",
    [string]$LogDir = (Join-Path $PSScriptRoot "..\reports"),
    # Where the base installer's InstallShield layout is extracted to.
    [string]$ExtractDir = (Join-Path $PSScriptRoot "..\work\diascreen-base"),
    [int]$TimeoutMinutes = 15
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "DiaScreenWin32.ps1")

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogDir = (Resolve-Path $LogDir).Path

function Log([string]$Message) { Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $Message) }

function Get-DiaScreenEntry {
    Get-ItemProperty "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*", "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like "DIAScreen*" -and $_.InstallLocation } | Select-Object -First 1
}

function Get-ProcessTree([int]$RootId) {
    $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    $ids = New-Object System.Collections.Generic.List[int]
    $ids.Add($RootId)
    for ($i = 0; $i -lt $ids.Count; $i++) {
        foreach ($p in $all) { if ($p.ParentProcessId -eq $ids[$i] -and -not $ids.Contains([int]$p.ProcessId)) { $ids.Add([int]$p.ProcessId) } }
    }
    $all | Where-Object { $ids.Contains([int]$_.ProcessId) }
}

function Write-InstallerState([int]$RootId, [string]$Tag) {
    $tree = @(Get-ProcessTree $RootId)
    # msiexec does the actual work in its own (service-launched) processes,
    # and custom actions start their tools (e.g. DPInst) under those.
    foreach ($m in @(Get-CimInstance Win32_Process -Filter "Name='msiexec.exe'" -ErrorAction SilentlyContinue)) {
        $tree += @(Get-ProcessTree $m.ProcessId | Where-Object { $tree.ProcessId -notcontains $_.ProcessId })
    }
    foreach ($p in $tree) {
        Log ("  pid {0} (parent {1}) {2}" -f $p.ProcessId, $p.ParentProcessId, $(if ($p.CommandLine) { $p.CommandLine } else { $p.Name }))
        foreach ($h in [DiaWin32]::TopWindows([uint32]$p.ProcessId)) {
            Log "    window: $(Get-DialogDescription $h)"
        }
    }
    try { [DiaWin32]::Screenshot((Join-Path $LogDir "install-$Tag.png")) } catch { Log "  screenshot failed: $_" }
}

function Invoke-Installer {
    param([string]$Name, [string]$FilePath, [string]$Arguments, [int]$Minutes = $TimeoutMinutes, [int[]]$SuccessCodes = @(0, 3010, 3011))
    Log "[$Name] $FilePath $Arguments"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $proc = Start-Process -FilePath $FilePath -ArgumentList $Arguments -PassThru
    $null = $proc.Handle   # keep ExitCode available (Windows PowerShell 5.1)
    $minute = 0
    while (-not $proc.WaitForExit(60000)) {
        $minute++
        Log "[$Name] still running after $minute min:"
        Write-InstallerState $proc.Id "$Name-$minute"
        if ($minute -ge $Minutes) {
            Get-ProcessTree $proc.Id | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
            throw "[$Name] did not finish within $Minutes min - see the window list above and reports/install-$Name-*.png."
        }
    }
    Log ("[{0}] exit code {1} after {2:0} s" -f $Name, $proc.ExitCode, $sw.Elapsed.TotalSeconds)
    if ($SuccessCodes -notcontains $proc.ExitCode) { throw "[$Name] failed with exit code $($proc.ExitCode)." }

    # An InstallShield launcher "relaunches setup from temp" (a copy of
    # itself under %TEMP%\{GUID}, started without waiting) and exits right
    # away - the real work happens in that copy, so wait for it too.
    $exeName = [IO.Path]::GetFileNameWithoutExtension($FilePath)
    if ($exeName -ne 'msiexec') {
        $deadline = $sw.Elapsed.TotalMinutes + $Minutes
        while ($copies = @(Get-Process -Name $exeName -ErrorAction SilentlyContinue)) {
            if ($sw.Elapsed.TotalMinutes -ge $deadline) {
                $copies | ForEach-Object { Get-ProcessTree $_.Id | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } }
                throw "[$Name] relaunched setup did not finish within $Minutes min."
            }
            $minute++
            Log "[$Name] relaunched copy still running (pid $($copies.Id -join ', ')):"
            Write-InstallerState $copies[0].Id "$Name-$minute"
            $null = $copies[0].WaitForExit(60000)
        }
        Log ("[{0}] relaunched setup done after {1:0} s" -f $Name, $sw.Elapsed.TotalSeconds)
    }
}

function Wait-MsiIdle {
    # A setup launcher can return before its msiexec client is done.
    $deadline = (Get-Date).AddMinutes(5)
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-Process msiexec -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -ne 0 })) { return }
        Start-Sleep -Seconds 5
    }
    Log "WARNING: msiexec still running after 5 min"
}

function Show-MsiResult([string]$MsiLog) {
    if (-not (Test-Path $MsiLog)) { Log "  (no MSI log at $MsiLog)"; return }
    Get-Content $MsiLog | Select-String -Pattern 'Installation success or error status|Product: .* --|Return value 3|Error \d{4}' |
        Select-Object -Last 8 | ForEach-Object { Log "  $($_.Line.Trim())" }
}

# --- Base 1.8 ------------------------------------------------------------------
$sevenZip = (Get-Command 7z -ErrorAction SilentlyContinue).Source
if (-not $sevenZip) { $sevenZip = "$env:ProgramFiles\7-Zip\7z.exe" }
if (-not (Test-Path $sevenZip)) { throw "7-Zip not found (needed to unpack the NSIS base installer)." }
New-Item -ItemType Directory -Force -Path $ExtractDir | Out-Null
$sw = [Diagnostics.Stopwatch]::StartNew()
& $sevenZip x $BaseInstallerPath "-o$ExtractDir" -y -bso0 -bsp0
if ($LASTEXITCODE -ne 0) { throw "7-Zip failed to unpack $BaseInstallerPath (exit $LASTEXITCODE)." }
$setupIni = Get-ChildItem -Path $ExtractDir -Filter Setup.ini -Recurse -File | Select-Object -First 1
if (-not $setupIni) { throw "No Setup.ini in the unpacked base installer ($ExtractDir) - not the expected InstallShield layout." }
$layout = $setupIni.DirectoryName
$msi = Get-ChildItem -Path $layout -Filter "DIAScreen*.msi" -File | Select-Object -First 1
if (-not $msi) { throw "No DIAScreen*.msi in $layout." }
Log ("Unpacked base installer in {0:0} s -> {1}" -f $sw.Elapsed.TotalSeconds, $msi.FullName)

# The MSI's InstallUSBDriver custom action runs DPInst for the bundled
# drivers (Delta HMI USB, virtual serial, TAP). Their catalogs are properly
# signed, but Windows still asks "Would you like to install this device
# software?" for a publisher that is not in TrustedPublisher - on the
# secure desktop, invisible and unanswerable on CI, so msiexec /qn hangs
# forever. Trusting the catalogs' signers up front skips that prompt.
$store = New-Object System.Security.Cryptography.X509Certificates.X509Store("TrustedPublisher", "LocalMachine")
$store.Open("ReadWrite")
try {
    $signers = @{}
    foreach ($cat in Get-ChildItem -Path $layout -Recurse -Filter *.cat -File) {
        $cert = (Get-AuthenticodeSignature $cat.FullName).SignerCertificate
        if ($cert -and -not $signers.ContainsKey($cert.Thumbprint)) { $signers[$cert.Thumbprint] = $cert }
    }
    foreach ($cert in $signers.Values) {
        $store.Add($cert)
        Log "Trusted driver publisher: $($cert.Subject.Split(',')[0]) ($($cert.Thumbprint))"
    }
} finally { $store.Close() }

$vc2013 = Get-ChildItem -Path (Join-Path $layout "ISSetupPrerequisites") -Recurse -Filter "vcredist_x86_12*.exe" -File -ErrorAction SilentlyContinue | Select-Object -First 1
if ($vc2013) {
    # 1638 = a newer/same version is already installed.
    Invoke-Installer -Name "vcredist2013-x86" -FilePath $vc2013.FullName -Arguments "/install /quiet /norestart" -Minutes 5 -SuccessCodes @(0, 1638, 3010)
}

# DIAScreen refuses to start without CodeMeter ("CodeMeter component can't
# be started properly"). Same silent switch as in Diadesigner-AX-CI-CD.
if (-not (Get-Service -Name "CodeMeter.exe" -ErrorAction SilentlyContinue)) {
    $cm = Get-ChildItem -Path (Join-Path $layout "ISSetupPrerequisites") -Recurse -Filter "CodeMeterRuntime*.exe" -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cm) { throw "CodeMeterRuntime*.exe not found in $layout\ISSetupPrerequisites." }
    Invoke-Installer -Name "codemeter" -FilePath $cm.FullName -Arguments '/ComponentArgs "*":"/qn /norestart"' -Minutes 10
}
$cmService = Get-Service -Name "CodeMeter.exe" -ErrorAction SilentlyContinue
if (-not $cmService) { throw "CodeMeter service (CodeMeter.exe) is missing after installing CodeMeter Runtime." }
if ($cmService.Status -ne 'Running') { Start-Service -Name "CodeMeter.exe" }
Log "CodeMeter service: $((Get-Service -Name 'CodeMeter.exe').Status)"

$baseLog = Join-Path $LogDir "diascreen-install-base.log"
$mst = Join-Path $layout "1033.mst"
# INSTALLDIR as the interactive setup picks it (its UI sequence, skipped by
# /qn, appends "DIAScreen 1.8"; the MSI default is the DIAStudio folder).
# No trailing backslash: '\"' would escape the closing quote on the msiexec
# command line (MSI appends the backslash to directory properties itself).
$installDir = "${env:ProgramFiles(x86)}\Delta Industrial Automation\DIAStudio\DIAScreen 1.8"
$props = "INSTALLDIR=`"$installDir`" SETUPEXEDIR=`"$layout`" REBOOT=ReallySuppress"
if (Test-Path $mst) { $props = "TRANSFORMS=`"$mst`" $props" }
Invoke-Installer -Name "base" -FilePath "msiexec.exe" -Arguments "/i `"$($msi.FullName)`" $props /qn /norestart /l*v `"$baseLog`""
Show-MsiResult $baseLog
$entry = Get-DiaScreenEntry
if (-not $entry) { throw "Base DIAScreen install failed (no uninstall entry) - see $baseLog." }
Log "Base: $($entry.DisplayName) $($entry.DisplayVersion) -> $($entry.InstallLocation)"

# --- Patch 1.8.1 ---------------------------------------------------------------
if ($PatchInstallerPath) {
    $patchLog = Join-Path $LogDir "diascreen-install-patch.log"
    $setupLog = Join-Path $LogDir "diascreen-setup-patch.log"
    if ($patchLog -match '\s') { throw "Log path must not contain spaces (it is passed through /v`"...`"): $patchLog" }
    Invoke-Installer -Name "patch" -FilePath (Resolve-Path $PatchInstallerPath).Path `
        -Arguments "/s /debuglog`"$setupLog`" /v`"/qn /norestart /l*v $patchLog`""
    Wait-MsiIdle
    Show-MsiResult $patchLog
    $entry = Get-DiaScreenEntry
}

$exe = Join-Path $entry.InstallLocation "DIAScreen.exe"
if (-not (Test-Path $exe)) { throw "DIAScreen.exe not found in $($entry.InstallLocation)." }
$fileVersion = (Get-Item $exe).VersionInfo.ProductVersion
Log ("Installed {0} {1}, DIAScreen.exe {2} -> {3}" -f $entry.DisplayName, $entry.DisplayVersion, $fileVersion, $exe)
if ($env:GITHUB_ENV) { "DIASCREEN_EXE=$exe" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8 }
