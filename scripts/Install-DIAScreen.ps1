<#
.SYNOPSIS
    Silent install of DIAScreen from Delta's installers: the base release
    (DIAScreen 1.8) followed by the patch on top of it
    (DELTA_IA-OSW_DIAScreen_V1.8.1_SW_202607.exe = "DIAScreen 1.8.1.19
    Patch" - it only updates an existing 1.8 install, on its own it
    installs nothing).

    The base installer is an NSIS wrapper around an uncompressed
    InstallShield layout ("DIAScreen 1.8.exe" + "DIAScreen 1.8.msi" +
    ISSetupPrerequisites\...) that it normally extracts to
    %TEMP%\DIAScreen and runs interactively - so the layout is extracted
    with 7-Zip and its InstallShield launcher is run directly. The patch is
    an InstallShield launcher itself. Both run as:
    /s   - silent setup launcher (no language / welcome dialogs;
           prerequisites - VC++, .NET 4.7.2, CodeMeter - install silently)
    /v"" - arguments passed through to msiexec: /qn (no UI), verbose log.
#>
param(
    [Parameter(Mandatory = $true)][string]$BaseInstallerPath,
    [string]$PatchInstallerPath = "",
    [string]$LogDir = (Join-Path $PSScriptRoot "..\reports"),
    # Where the base installer's InstallShield layout is extracted to.
    [string]$ExtractDir = (Join-Path $PSScriptRoot "..\work\diascreen-base"),
    [int]$TimeoutMinutes = 30
)

$ErrorActionPreference = "Stop"

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogDir = (Resolve-Path $LogDir).Path
if ($LogDir -match '\s') { throw "Log directory must not contain spaces (it is passed through /v`"...`"): $LogDir" }

function Get-DiaScreenEntry {
    Get-ItemProperty "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*", "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like "DIAScreen*" -and $_.InstallLocation } | Select-Object -First 1
}

function Wait-MsiIdle {
    # The setup launcher can return before its msiexec client is done.
    $deadline = (Get-Date).AddMinutes(10)
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-Process msiexec -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -ne 0 })) { return }
        Start-Sleep -Seconds 5
    }
    Write-Host "WARNING: msiexec still running after 10 min"
}

function Invoke-Setup([string]$Path, [string]$Name) {
    if (-not (Test-Path $Path)) { throw "Installer not found: $Path" }
    $msiLog = Join-Path $LogDir "diascreen-install-$Name.log"
    $setupLog = Join-Path $LogDir "diascreen-setup-$Name.log"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    & (Join-Path $PSScriptRoot "Start-SilentInstall.ps1") -InstallerPath $Path `
        -ArgumentList @('/s', "/debuglog`"$setupLog`"", "/v`"/qn /norestart /l*v $msiLog`"") -TimeoutMinutes $TimeoutMinutes
    Wait-MsiIdle
    Write-Host ("{0}: done in {1:0} s (logs: {2}, {3})" -f $Name, $sw.Elapsed.TotalSeconds, $msiLog, $setupLog)
    if (Test-Path $msiLog) {
        Get-Content $msiLog | Select-String -Pattern 'Installation success or error status|Product: .*--|Return value 3' | Select-Object -Last 5 | ForEach-Object { Write-Host "  $($_.Line)" }
    }
}

function Expand-BaseLayout([string]$Path) {
    $sevenZip = (Get-Command 7z -ErrorAction SilentlyContinue).Source
    if (-not $sevenZip) { $sevenZip = "$env:ProgramFiles\7-Zip\7z.exe" }
    if (-not (Test-Path $sevenZip)) { throw "7-Zip not found (needed to unpack the NSIS base installer)." }
    New-Item -ItemType Directory -Force -Path $ExtractDir | Out-Null
    $sw = [Diagnostics.Stopwatch]::StartNew()
    & $sevenZip x $Path "-o$ExtractDir" -y -bso0 -bsp0
    if ($LASTEXITCODE -ne 0) { throw "7-Zip failed to unpack $Path (exit $LASTEXITCODE)." }
    # NSIS keeps the payload under "_" ($INSTDIR); the launcher sits next to Setup.ini.
    $setupIni = Get-ChildItem -Path $ExtractDir -Filter Setup.ini -Recurse -File | Select-Object -First 1
    if (-not $setupIni) { throw "No Setup.ini in the unpacked base installer ($ExtractDir) - not the expected InstallShield layout." }
    $launcher = Get-ChildItem -Path $setupIni.DirectoryName -Filter "DIAScreen*.exe" -File | Select-Object -First 1
    if (-not $launcher) { throw "No DIAScreen*.exe launcher next to $($setupIni.FullName)." }
    Write-Host ("Unpacked base installer in {0:0} s -> {1}" -f $sw.Elapsed.TotalSeconds, $launcher.FullName)
    $launcher.FullName
}

Invoke-Setup (Expand-BaseLayout $BaseInstallerPath) "base"
$entry = Get-DiaScreenEntry
if (-not $entry) { throw "Base DIAScreen install failed (no uninstall entry) - see $LogDir\diascreen-install-base.log." }
Write-Host "Base: $($entry.DisplayName) $($entry.DisplayVersion) -> $($entry.InstallLocation)"

if ($PatchInstallerPath) {
    Invoke-Setup $PatchInstallerPath "patch"
    $entry = Get-DiaScreenEntry
}

$exe = Join-Path $entry.InstallLocation "DIAScreen.exe"
if (-not (Test-Path $exe)) { throw "DIAScreen.exe not found in $($entry.InstallLocation)." }
$fileVersion = (Get-Item $exe).VersionInfo.ProductVersion
Write-Host ("Installed {0} {1}, DIAScreen.exe {2} -> {3}" -f $entry.DisplayName, $entry.DisplayVersion, $fileVersion, $exe)
if ($env:GITHUB_ENV) { "DIASCREEN_EXE=$exe" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8 }
