<#
.SYNOPSIS
    Installs a DIAScreen HMI series ("panel firmware") package the way the
    online Update Manager does, from a zip of its package folder.

    A fresh DIAScreen install only brings the DOP-100 package; opening a
    project for another series (here AX-8(Windows)) stops at "<series> is
    not yet supported. Do you want to enable Update Manager ...". The
    Update Manager installs a series as:

      C:\ProgramData\Delta Industrial Automation\HMI\Panel\<Name>_<Version>\
          PanelInfo.ini ([Package_Info] Series=..., Version=...) + firmware
      C:\ProgramData\Delta Industrial Automation\DIAStudio\DIAScreen 1.8\DOPSoft.ini
          [ENVIRONMENT] <Series>=<Version>

    The zip holds the package folder itself (e.g.
    AX-8-Windows_1.0142.5\PanelInfo.ini + PAC_AX.bin), copied from a
    machine where the Update Manager installed it.
#>
param(
    [Parameter(Mandatory = $true)][string]$ZipPath,
    [string]$PanelRoot = "$env:ProgramData\Delta Industrial Automation\HMI\Panel",
    [string]$DopSoftIni = "$env:ProgramData\Delta Industrial Automation\DIAStudio\DIAScreen 1.8\DOPSoft.ini"
)

$ErrorActionPreference = "Stop"

if (-not ("IniFile" -as [type])) {
    Add-Type -TypeDefinition @"
using System.Runtime.InteropServices;
public static class IniFile {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool WritePrivateProfileString(string section, string key, string value, string path);
}
"@
}

New-Item -ItemType Directory -Force -Path $PanelRoot | Out-Null
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("panelpkg-" + [guid]::NewGuid().ToString("N"))
Expand-Archive -Path $ZipPath -DestinationPath $tmp
try {
    $info = Get-ChildItem -Path $tmp -Filter PanelInfo.ini -Recurse -File | Select-Object -First 1
    if (-not $info) { throw "No PanelInfo.ini in $ZipPath." }
    $text = Get-Content $info.FullName -Raw
    $series = if ($text -match '(?m)^\s*Series\s*=\s*(.+?)\s*$') { $Matches[1] } else { throw "No Series= in $($info.FullName)." }
    $version = if ($text -match '(?m)^\s*Version\s*=\s*(.+?)\s*$') { $Matches[1] } else { throw "No Version= in $($info.FullName)." }

    $target = Join-Path $PanelRoot $info.Directory.Name
    if (Test-Path $target) { Remove-Item $target -Recurse -Force }
    Copy-Item -Path $info.Directory.FullName -Destination $target -Recurse
    $files = @(Get-ChildItem $target -Recurse -File)
    Write-Host ("Panel package '{0}' {1}: {2} file(s), {3:0.0} MB -> {4}" -f $series, $version, $files.Count, (($files | Measure-Object Length -Sum).Sum / 1MB), $target)
} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

New-Item -ItemType Directory -Force -Path (Split-Path $DopSoftIni -Parent) | Out-Null
if (-not [IniFile]::WritePrivateProfileString("ENVIRONMENT", $series, $version, $DopSoftIni)) {
    throw "Could not write [$series] to $DopSoftIni (Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))."
}
Write-Host "Registered in ${DopSoftIni}: $series=$version"
