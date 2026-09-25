# CLAUDE.md

Zasady pracy Claude w tym repozytorium.

## Git

- Każdą zmianę wprowadzoną w repo commituj lokalnie (małe, opisowe commity).
- Nigdy nie rób `git push` bez wyraźnego polecenia użytkownika.
- Każdą zmianę odnotuj w [CHANGELOG.md](CHANGELOG.md).

## Projekt

- Jedyny projekt w repo: `PilaJednosuportowaINNER.dpa` (DIAScreen 1.8.1.19,
  panel PAC AX-8). Test pracuje na kopii w `work/` - plik w repo nie może
  być modyfikowany przez pipeline.
- Instalatory leżą w GitHub Release `Installers` (szczegóły w
  `installers/README.md`): baza `..._V1.8.0_SW_202606.exe` (NSIS ->
  layout InstallShield; w CI 7-Zip + `msiexec /qn`), łatka
  `..._V1.8.1_SW_202607.exe` (sama nic nie instaluje) i pakiet serii
  `DIAScreen-Panel-AX-8-Windows_1.0142.5.zip` (normalnie z online Update
  Managera; bez niego projekt AX-8 się nie otwiera).
- Na świeżej maszynie potrzebne też: CodeMeter Runtime (inaczej DIAScreen
  nie startuje), zaufani wydawcy sterowników (inaczej `msiexec /qn` wisi na
  DPInst), zatwierdzenie dialogu "COM Port Setting" HMIManager przy
  symulacji.
- Hasło projektu: zmienna środowiskowa `PROJECT_PASSWORD` (w CI sekret
  `PROJECT_PASSWORD`). Nigdy nie zapisywać go w repo/logach.
- DIAScreen nie ma CLI - sterowanie przez Win32 (`scripts/DiaScreenWin32.ps1`):
  `WM_COMMAND` 50067 = Compile, 50070 = On-line Simulation, 50071 =
  Off-line Simulation (ID z zasobu wstążki `DIAScreen.exe`).
- Użytkownik może mieć otwarty własny DIAScreen - skrypty zamykają tylko
  procesy, które same uruchomiły. Nigdy nie zabijać `DIAScreen`/`HMIApp`
  po samej nazwie.
- Skrypty `.ps1` w ASCII (bez polskich znaków) - Windows PowerShell 5.1 źle
  czyta UTF-8 bez BOM. Test uruchamiany przez `powershell` (5.1), także w CI.
- Pełny opis architektury: `README.md`.
