<#
.SYNOPSIS
    End-to-end smoke test of a DIAScreen project, driven through the GUI:

      1. BUILD - opens a copy of the .dpa in DIAScreen (answering the
         "Disable Protection" password prompt with $env:PROJECT_PASSWORD)
         and runs Compile; passes on "Find 0 error(s)!" + "Compilation
         successful" in the Output window.
      2. TEST  - starts On-line Simulation and watches the emulator for
         -ObserveSeconds: it has to stay alive and responsive (no crash,
         no WerFault, no hang) the whole time.

    Writes reports/junit-build.xml, reports/junit-test.xml, the full
    compiler output (compile-output.log) and screenshots of every stage.

    DIAScreen has no command-line/scripting interface, so the ribbon
    commands are sent as WM_COMMAND to its main frame and dialogs are
    handled with plain Win32 messages - no mouse/keyboard input, so it also
    works while the machine is used (only processes started by this script
    are touched and closed).
#>
param(
    [string]$ProjectPath = (Join-Path $PSScriptRoot "..\PilaJednosuportowaINNER.dpa"),
    [string]$DiaScreenExe = "",
    # Fail unless DIAScreen.exe has this product version (e.g. "1.8.1.19" -
    # proves the patch on top of the 1.8 base install was applied).
    [string]$ExpectedVersion = "",
    # Answer to "<series> is not yet supported. Enable Update Manager?".
    [ValidateSet('No', 'Yes')][string]$UpdateManagerAnswer = 'No',
    [int]$ObserveSeconds = 30,
    [int]$OpenTimeoutSeconds = 300,
    [int]$CompileTimeoutSeconds = 900,
    [int]$SimulationStartTimeoutSeconds = 180,
    [string]$ReportsDir = (Join-Path $PSScriptRoot "..\reports"),
    [string]$WorkDir = (Join-Path $PSScriptRoot "..\work"),
    # Leave DIAScreen and the emulator running afterwards (local debugging).
    [switch]$KeepRunning
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "DiaScreenWin32.ps1")

New-Item -ItemType Directory -Force -Path $ReportsDir, $WorkDir | Out-Null
$ReportsDir = (Resolve-Path $ReportsDir).Path
$WorkDir = (Resolve-Path $WorkDir).Path

function Log([string]$Message) { Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $Message) }

function Save-Screenshot([string]$Name) {
    $path = Join-Path $ReportsDir "$Name.png"
    try { [DiaWin32]::Screenshot($path); Log "screenshot: $path" } catch { Log "screenshot failed: $_" }
}

function Write-JUnit {
    param([string]$Path, [string]$Suite, [object[]]$Cases)
    $esc = { param($s) [Security.SecurityElement]::Escape([string]$s) }
    $failures = @($Cases | Where-Object { -not $_.Passed }).Count
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('<?xml version="1.0" encoding="UTF-8"?>')
    $lines.Add(('<testsuite name="{0}" tests="{1}" failures="{2}">' -f (& $esc $Suite), $Cases.Count, $failures))
    foreach ($c in $Cases) {
        $lines.Add(('  <testcase classname="{0}" name="{1}" time="{2:0.00}">' -f (& $esc $Suite), (& $esc $c.Name), $c.Seconds))
        if (-not $c.Passed) { $lines.Add("    <failure>$(& $esc $c.Message)</failure>") }
        elseif ($c.Message) { $lines.Add("    <system-out>$(& $esc $c.Message)</system-out>") }
        $lines.Add('  </testcase>')
    }
    $lines.Add('</testsuite>')
    [IO.File]::WriteAllText($Path, ($lines -join "`n"), (New-Object Text.UTF8Encoding($false)))
}

function New-Case([string]$Name) {
    [pscustomobject]@{ Name = $Name; Passed = $false; Message = ""; Seconds = 0.0; Watch = [Diagnostics.Stopwatch]::StartNew() }
}
function Complete-Case($Case, [bool]$Passed, [string]$Message) {
    $Case.Passed = $Passed; $Case.Message = $Message; $Case.Seconds = $Case.Watch.Elapsed.TotalSeconds
    $mark = if ($Passed) { "PASS" } else { "FAIL" }
    Log "$mark $($Case.Name): $Message"
}

# --- locate DIAScreen -------------------------------------------------------
if (-not $DiaScreenExe) {
    $uninstall = Get-ItemProperty "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*", "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like "DIAScreen*" -and $_.InstallLocation } | Select-Object -First 1
    $candidates = @()
    if ($uninstall) { $candidates += Join-Path $uninstall.InstallLocation "DIAScreen.exe" }
    $candidates += "${env:ProgramFiles(x86)}\Delta Industrial Automation\DIAStudio\DIAScreen 1.8\DIAScreen.exe"
    $DiaScreenExe = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $DiaScreenExe) { throw "DIAScreen.exe not found (checked: $($candidates -join '; ')) - install it first (scripts/Install-DIAScreen.ps1)." }
}
$diaDir = Split-Path $DiaScreenExe -Parent
$emulatorDir = Join-Path $diaDir "ScrEditApp\Emulator"
$diaVersion = (Get-Item $DiaScreenExe).VersionInfo.ProductVersion
Log "DIAScreen: $DiaScreenExe ($diaVersion)"
if ($ExpectedVersion -and $diaVersion -ne $ExpectedVersion) {
    throw "DIAScreen.exe is version $diaVersion, expected $ExpectedVersion."
}

if (-not $env:PROJECT_PASSWORD) {
    Log "WARNING: PROJECT_PASSWORD is not set - a password-protected project cannot be opened."
}

$existingEmu = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($emulatorDir, [StringComparison]::OrdinalIgnoreCase) }
if ($existingEmu) {
    throw "A DIAScreen emulator is already running ($(($existingEmu | ForEach-Object { "$($_.ProcessName) pid $($_.Id)" }) -join ', ')) - close it first."
}

# Work on a copy so the committed project is never modified.
$projectCopy = Join-Path $WorkDir (Split-Path $ProjectPath -Leaf)
Copy-Item -Path $ProjectPath -Destination $projectCopy -Force
Log "Project: $ProjectPath -> $projectCopy"

$buildCases = @()
$testCases = @()
$startedAt = Get-Date
$dia = $null

function Get-MainFrame([int]$ProcessId) {
    # The MDI frame is the top-level window that owns an MDIClient.
    foreach ($h in [DiaWin32]::TopWindows($ProcessId)) {
        if ([DiaWin32]::Children($h) | Where-Object { [DiaWin32]::ClassOf($_) -eq 'MDIClient' }) { return $h }
    }
    return [IntPtr]::Zero
}

function Get-OpenScreenCount([IntPtr]$Frame) {
    $mdi = [DiaWin32]::Children($Frame) | Where-Object { [DiaWin32]::ClassOf($_) -eq 'MDIClient' } | Select-Object -First 1
    if (-not $mdi) { return 0 }
    @([DiaWin32]::Children($mdi) | Where-Object { [DiaWin32]::ClassOf($_) -like 'AfxFrameOrView*' }).Count
}

function Get-OutputList([IntPtr]$Frame) {
    # The Output pane's message list (SysListView32, control id 1208).
    $lv = [DiaWin32]::Children($Frame) | Where-Object { [DiaWin32]::ClassOf($_) -eq 'SysListView32' -and [DiaWin32]::GetDlgCtrlID($_) -eq 1208 } | Select-Object -First 1
    if (-not $lv) { throw "Output window (SysListView32 id 1208) not found in the DIAScreen main frame." }
    $lv
}

try {
    # ===================================================================
    # BUILD
    # ===================================================================
    $case = New-Case "Open project"
    $dia = Start-Process -FilePath $DiaScreenExe -ArgumentList "`"$projectCopy`"" -WorkingDirectory $diaDir -PassThru
    $null = $dia.Handle
    Log "DIAScreen started, pid $($dia.Id)"

    $passwordSent = $false
    $seenDialogs = @{}
    $opened = $false
    $failure = $null
    $deadline = (Get-Date).AddSeconds($OpenTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ($dia.HasExited) { $failure = "DIAScreen exited while opening the project (exit code $($dia.ExitCode))."; break }
        $dialogs = Get-ProcessDialogs $dia.Id
        foreach ($d in $dialogs) {
            $title = [DiaWin32]::Text($d)
            $desc = Get-DialogDescription $d
            if ($title -eq 'Disable Protection') {
                if ($passwordSent) { $failure = "Project password rejected (the 'Disable Protection' prompt came back) - check PROJECT_PASSWORD."; break }
                if (-not $env:PROJECT_PASSWORD) { $failure = "Project is password protected but PROJECT_PASSWORD is not set."; break }
                Log "Password prompt - entering PROJECT_PASSWORD"
                [DiaWin32]::SetText([DiaWin32]::GetDlgItem($d, 1226), $env:PROJECT_PASSWORD)
                Start-Sleep -Milliseconds 300
                [DiaWin32]::Click([DiaWin32]::GetDlgItem($d, 1))   # IDOK
                $passwordSent = $true
                Start-Sleep -Seconds 2
                continue
            }
            if ($desc -match 'is not yet supported\. Do you want to enable .*Update Manager') {
                # A fresh install only has the series packages shipped with
                # the installer; newer ones (e.g. AX-8(Windows) 1.0142.5)
                # come from the online Update Manager. Decline and go on -
                # compile/simulation must work with what is installed.
                $btn = Find-DialogButton $d @($UpdateManagerAnswer)
                if ($btn -ne [IntPtr]::Zero -and -not $seenDialogs.ContainsKey("answered-$d")) {
                    $seenDialogs["answered-$d"] = Get-Date
                    Log "WARNING: $desc -> answering '$UpdateManagerAnswer'"
                    Save-Screenshot "open-update-manager-prompt"
                    [DiaWin32]::Click($btn)
                    if ($UpdateManagerAnswer -eq 'Yes') {
                        # Diagnostics: record what the Update Manager shows.
                        for ($i = 1; $i -le 12; $i++) {
                            Start-Sleep -Seconds 5
                            Save-Screenshot "update-manager-$i"
                            Get-Process | Where-Object { try { $_.StartTime -ge $startedAt -and $_.MainWindowHandle -ne 0 } catch { $false } } | ForEach-Object {
                                foreach ($w in [DiaWin32]::TopWindows($_.Id)) { Log "  [$($_.ProcessName) $($_.Id)] $(Get-DialogDescription $w)" }
                            }
                        }
                    }
                    Start-Sleep -Seconds 2
                    continue
                }
            }
            $key = "$d"
            if (-not $seenDialogs.ContainsKey($key)) {
                $seenDialogs[$key] = Get-Date
                Log "Dialog: $desc"
                Save-Screenshot "open-dialog-$($seenDialogs.Count)"
            } elseif (((Get-Date) - $seenDialogs[$key]).TotalSeconds -gt 20) {
                $failure = "Unexpected dialog while opening the project: $desc"
                break
            }
        }
        if ($failure) { break }
        $frame = Get-MainFrame $dia.Id
        if ($frame -ne [IntPtr]::Zero -and $dialogs.Count -eq 0 -and (Get-OpenScreenCount $frame) -gt 0) { $opened = $true; break }
        Start-Sleep -Seconds 1
    }
    if (-not $opened -and -not $failure) { $failure = "Project did not open within $OpenTimeoutSeconds s." }
    if ($failure) {
        Save-Screenshot "failure-open"
        Complete-Case $case $false $failure
        $buildCases += $case
        throw $failure
    }
    Start-Sleep -Seconds 3   # let the editor settle after loading
    Save-Screenshot "01-project-opened"
    Complete-Case $case $true ("Opened {0} ({1} screen window(s)), password prompt: {2}" -f (Split-Path $projectCopy -Leaf), (Get-OpenScreenCount $frame), $(if ($passwordSent) { "answered" } else { "none" }))
    $buildCases += $case

    # --- Compile ---------------------------------------------------------
    $case = New-Case "Compile"
    $outList = Get-OutputList $frame
    $rowsBefore = [DiaWin32]::ListViewCount($outList)
    Log "Compile (WM_COMMAND $($DiaCmd.Compile)), Output rows before: $rowsBefore"
    [DiaWin32]::Command($frame, $DiaCmd.Compile)

    $summary = $null; $success = $false; $failure = $null; $rows = @(); $seenDialogs = @{}
    $deadline = (Get-Date).AddSeconds($CompileTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        if ($dia.HasExited) { $failure = "DIAScreen exited during compilation (exit code $($dia.ExitCode))."; break }
        foreach ($d in Get-ProcessDialogs $dia.Id) {
            $key = "$d"
            if (-not $seenDialogs.ContainsKey($key)) {
                $seenDialogs[$key] = Get-Date
                Log "Dialog: $(Get-DialogDescription $d)"
                Save-Screenshot "compile-dialog-$($seenDialogs.Count)"
            } elseif (((Get-Date) - $seenDialogs[$key]).TotalSeconds -gt 20) {
                $failure = "Unexpected dialog during compilation: $(Get-DialogDescription $d)"
            }
        }
        if ($failure) { break }
        # Only the tail while polling - every row read is a synchronous
        # message to DIAScreen's UI thread and the summary is at the end.
        $count = [DiaWin32]::ListViewCount($outList)
        $from = if ($count -ge $rowsBefore) { $rowsBefore } else { 0 }
        $new = @([DiaWin32]::ListViewRows($outList, [Math]::Max($from, $count - 10)))
        $summary = $new | Where-Object { $_ -match 'Find\s+(\d+)\s+error\(s\)' } | Select-Object -Last 1
        if ($summary) {
            Start-Sleep -Seconds 1   # "Compilation successful" follows the summary line
            $new = @([DiaWin32]::ListViewRows($outList, [Math]::Max($from, $count - 10)))
            $null = $summary -match 'Find\s+(\d+)\s+error\(s\)'
            $errors = [int]$Matches[1]
            $success = ($errors -eq 0) -and ($new -match 'Compilation successful')
            break
        }
    }
    $rows = @([DiaWin32]::ListViewRows($outList, 0))
    $rows | Set-Content -Path (Join-Path $ReportsDir "compile-output.log") -Encoding UTF8
    Save-Screenshot "02-compiled"
    if (-not $failure -and -not $summary) { $failure = "Compilation did not finish within $CompileTimeoutSeconds s (no 'Find N error(s)' line in Output)." }
    if (-not $failure -and -not $success) {
        $errorLines = @($rows | Select-Object -Skip $from | Where-Object { $_ -match '(?i)error|fail' -and $_ -notmatch '^Find\s' }) | Select-Object -Last 40
        $failure = "$summary`n`nError lines from Output (full log: compile-output.log):`n$($errorLines -join "`n")"
    }
    if ($failure) {
        Complete-Case $case $false $failure
        $buildCases += $case
        throw "Compile failed"
    }
    $tail = @($rows | Select-Object -Last 5) -join "`n"
    Complete-Case $case $true "$summary`n$tail"
    $buildCases += $case
    Write-JUnit (Join-Path $ReportsDir "junit-build.xml") "DIAScreen build" $buildCases
    $buildCases = $null   # written

    # ===================================================================
    # TEST - On-line Simulation
    # ===================================================================
    $case = New-Case "Start On-line Simulation"
    $simCommandAt = Get-Date
    Log "On-line Simulation (WM_COMMAND $($DiaCmd.OnlineSimulation))"
    [DiaWin32]::Command($frame, $DiaCmd.OnlineSimulation)

    $emu = $null; $emuWindow = [IntPtr]::Zero; $failure = $null; $seenDialogs = @{}
    $deadline = (Get-Date).AddSeconds($SimulationStartTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 1
        if ($dia.HasExited) { $failure = "DIAScreen exited while starting the simulation (exit code $($dia.ExitCode))."; break }
        foreach ($d in Get-ProcessDialogs $dia.Id) {
            $key = "$d"
            if (-not $seenDialogs.ContainsKey($key)) {
                $seenDialogs[$key] = Get-Date
                Log "Dialog: $(Get-DialogDescription $d)"
                Save-Screenshot "simulation-dialog-$($seenDialogs.Count)"
            } elseif (((Get-Date) - $seenDialogs[$key]).TotalSeconds -gt 20) {
                $failure = "Unexpected dialog while starting the simulation: $(Get-DialogDescription $d)"
            }
        }
        if ($failure) { break }
        $emuProcs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
            $_.Path -and $_.Path.StartsWith($emulatorDir, [StringComparison]::OrdinalIgnoreCase) })
        # HMIManager asks how to map the HMI's COM ports to the PC's ("COM
        # Port Setting", "Ask me every time" - a Qt dialog). The defaults
        # (COM1->COM1, ...) are fine: nothing is attached on the runner.
        foreach ($p in $emuProcs) {
            foreach ($w in [DiaWin32]::TopWindows($p.Id)) {
                if ([DiaWin32]::Text($w) -ne 'COM Port Setting') { continue }
                if ($seenDialogs.ContainsKey("com-$w") -and ((Get-Date) - $seenDialogs["com-$w"]).TotalSeconds -lt 5) { continue }
                $seenDialogs["com-$w"] = Get-Date
                Save-Screenshot "simulation-com-port-setting"
                $how = if (Invoke-UiaButton $w 'OK') { "UI Automation" } else { "Enter" }
                Log "COM Port Setting dialog ($($p.ProcessName) pid $($p.Id)) -> OK via $how"
            }
        }
        $candidates = $emuProcs | Where-Object { $_.ProcessName -ne 'HMIManager' }
        foreach ($p in $candidates) {
            $w = [DiaWin32]::TopWindows($p.Id) | Where-Object { [DiaWin32]::Text($_) -match 'Emulator' } | Select-Object -First 1
            if ($w) { $emu = $p; $emuWindow = $w; break }
        }
        if ($emu) { break }
    }
    if (-not $failure -and -not $emu) { $failure = "Emulator window did not appear within $SimulationStartTimeoutSeconds s." }
    if ($failure) {
        Save-Screenshot "failure-simulation-start"
        Complete-Case $case $false $failure
        $testCases += $case
        throw $failure
    }
    $null = $emu.Handle
    $emuTitle = [DiaWin32]::Text($emuWindow)
    Log "Emulator: $($emu.ProcessName) pid $($emu.Id) - '$emuTitle'"
    if ($emuTitle -notmatch 'Online') {
        Complete-Case $case $false "Emulator started, but not in Online mode: '$emuTitle'"
        $testCases += $case
        throw "Not online"
    }
    Complete-Case $case $true ("{0} (pid {1}, {2}) started {3:0.0} s after the command" -f $emuTitle, $emu.Id, $emu.Path, ((Get-Date) - $simCommandAt).TotalSeconds)
    $testCases += $case
    Start-Sleep -Seconds 3
    Save-Screenshot "03-simulation-started"

    # --- Observe -----------------------------------------------------------
    $case = New-Case "Simulation runs for $ObserveSeconds s"
    $failure = $null
    $samples = New-Object System.Collections.Generic.List[string]
    $prevHung = $false
    $observe = [Diagnostics.Stopwatch]::StartNew()
    while ($observe.Elapsed.TotalSeconds -lt $ObserveSeconds) {
        Start-Sleep -Seconds 1
        $s = [int][Math]::Floor($observe.Elapsed.TotalSeconds)
        $emu.Refresh()
        if ($emu.HasExited) { $failure = "Emulator exited after $s s (exit code $($emu.ExitCode))."; break }
        if ($dia.HasExited) { $failure = "DIAScreen exited after $s s (exit code $($dia.ExitCode))."; break }
        $wer = Get-CimInstance Win32_Process -Filter "Name='WerFault.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -match "-p\s+($($emu.Id)|$($dia.Id))\b" }
        if ($wer) { $failure = "Windows Error Reporting caught a crash after $s s: $($wer.CommandLine)"; break }
        $hung = [DiaWin32]::IsHungAppWindow($emuWindow)
        $title = [DiaWin32]::Text($emuWindow)
        $samples.Add(("{0,3}s  responding={1}  cpu={2:0.0}s  ws={3:0}MB  '{4}'" -f $s, (-not $hung), $emu.TotalProcessorTime.TotalSeconds, ($emu.WorkingSet64 / 1MB), $title))
        if ($hung) {
            # One missed sample is tolerated (the emulator can be briefly busy), two in a row fail.
            if ($prevHung) { $failure = "Emulator window stopped responding (hung) at $s s."; break }
        }
        $prevHung = $hung
    }
    Save-Screenshot "04-simulation-end"
    $samples | Set-Content -Path (Join-Path $ReportsDir "simulation-samples.log") -Encoding UTF8
    if ($failure) {
        Complete-Case $case $false "$failure`n`n$($samples -join "`n")"
    } else {
        Complete-Case $case $true "Emulator alive and responding for $([int]$observe.Elapsed.TotalSeconds) s ($($samples.Count) samples).`n$(@($samples | Select-Object -Last 3) -join "`n")"
    }
    $testCases += $case
}
catch {
    Log "ERROR: $_"
    if ($null -ne $buildCases -and $buildCases.Count -eq 0) {
        $c = New-Case "Open project"; Complete-Case $c $false "$_"; $buildCases += $c
    }
}
finally {
    if ($null -ne $buildCases -and $buildCases.Count -gt 0) {
        Write-JUnit (Join-Path $ReportsDir "junit-build.xml") "DIAScreen build" $buildCases
    }
    if ($testCases.Count -gt 0) {
        Write-JUnit (Join-Path $ReportsDir "junit-test.xml") "DIAScreen On-line Simulation" $testCases
    }
    if (-not $KeepRunning) {
        # Only what this run started: our DIAScreen and emulator processes
        # created after $startedAt (another DIAScreen the user has open is
        # left alone).
        $mine = Get-Process -ErrorAction SilentlyContinue | Where-Object {
            $_.Path -and $_.Path.StartsWith($diaDir, [StringComparison]::OrdinalIgnoreCase) -and
            ($_.Id -eq $dia.Id -or ($_.StartTime -ge $startedAt -and $_.Path.StartsWith($emulatorDir, [StringComparison]::OrdinalIgnoreCase))) }
        foreach ($p in $mine) {
            Log "Closing $($p.ProcessName) pid $($p.Id)"
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        }
    }
}

$all = @()
foreach ($f in "junit-build.xml", "junit-test.xml") {
    $p = Join-Path $ReportsDir $f
    if (Test-Path $p) { $all += ([xml](Get-Content $p -Raw)).testsuite }
}
$failed = @($all | Where-Object { [int]$_.failures -gt 0 }).Count -gt 0
if ($failed -or $all.Count -lt 2) { Log "RESULT: FAILED"; exit 1 }
Log "RESULT: PASSED"
exit 0
