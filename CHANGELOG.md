# Changelog

## 2026-09-25

### Dodane
- Pipeline CI dla DIAScreen 1.8.1.19 (`.github/workflows/diascreen-ci.yml`),
  wzorowany na [Diadesigner-AX-CI-CD](https://github.com/PatrykChoinski/Diadesigner-AX-CI-CD):
  1 job na `windows-latest` - cicha instalacja DIAScreen z GitHub Release
  `Installers`, otwarcie `PilaJednosuportowaINNER.dpa` (hasło z sekretu
  `PROJECT_PASSWORD`), Compile i 30 s On-line Simulation.
- `Invoke-DiaScreenTest.ps1` + `DiaScreenWin32.ps1` - sterowanie DIAScreen
  przez Win32 (`WM_COMMAND` z ID wstążki, dialog hasła, odczyt okna Output
  z pamięci procesu), raporty JUnit, zrzuty ekranu każdego etapu.
- `Install-DIAScreen.ps1` - cicha instalacja launchera InstallShield
  (`/s /v"/qn"`) z logiem MSI.
- `Write-Summary.ps1` - raport w Job Summary.
