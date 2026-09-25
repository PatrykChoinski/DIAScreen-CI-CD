<#
.SYNOPSIS
    Silent install of DIAScreen from Delta's installer
    (DELTA_IA-OSW_DIAScreen_V<ver>_SW_<date>.exe - an InstallShield
    "Basic MSI" setup launcher around the DIAScreen MSI).

    /s   - silent setup launcher (no language / welcome dialogs)
    /v"" - arguments passed through to msiexec: /qn (no UI), verbose log.
#>
param(
    [Parameter(Mandatory = $true)][string]$InstallerPath,
    [string]$LogDir = (Join-Path $PSScriptRoot "..\reports"),
    [int]$TimeoutMinutes = 30
)

$ErrorActionPreference = "Stop"

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogDir = (Resolve-Path $LogDir).Path
$msiLog = Join-Path $LogDir "diascreen-install.log"
if ($msiLog -match '\s') { throw "Log path must not contain spaces (it is passed through /v`"...`"): $msiLog" }

$sw = [Diagnostics.Stopwatch]::StartNew()
& (Join-Path $PSScriptRoot "Start-SilentInstall.ps1") -InstallerPath $InstallerPath `
    -ArgumentList @('/s', "/v`"/qn /norestart /l*v $msiLog`"") -TimeoutMinutes $TimeoutMinutes

# The launcher may return before msiexec is done - wait for the product.
$exe = $null
$deadline = (Get-Date).AddMinutes(5)
while ((Get-Date) -lt $deadline) {
    $entry = Get-ItemProperty "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*", "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like "DIAScreen*" -and $_.InstallLocation } | Select-Object -First 1
    if ($entry) {
        $candidate = Join-Path $entry.InstallLocation "DIAScreen.exe"
        if ((Test-Path $candidate) -and -not (Get-Process msiexec -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -ne 0 })) {
            $exe = $candidate; break
        }
    }
    Start-Sleep -Seconds 5
}
if (-not $exe) {
    if (Test-Path $msiLog) { Get-Content $msiLog -Tail 60 | ForEach-Object { Write-Host $_ } }
    throw "DIAScreen was not installed (no DIAScreen.exe / uninstall entry) - see $msiLog."
}
Write-Host ("Installed {0} {1} -> {2} in {3:0} s" -f $entry.DisplayName, $entry.DisplayVersion, $exe, $sw.Elapsed.TotalSeconds)
if ($env:GITHUB_ENV) { "DIASCREEN_EXE=$exe" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8 }
