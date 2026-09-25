# Changelog

## 2026-09-25 (2)

### Naprawione
- CI: instalacja kończyła się bez efektu - `DELTA_IA-OSW_DIAScreen_V1.8.1_SW_202607.exe`
  to łatka ("DIAScreen 1.8.1.19 Patch") na istniejące DIAScreen 1.8, nie
  pełny instalator. Teraz najpierw instalowana jest baza
  `DELTA_IA-OSW_DIAScreen_V1.8.0_SW_202606.exe` (1.8.0.12, dodana do
  Release `Installers`), potem łatka.
- Baza to wrapper NSIS wokół layoutu InstallShield - rozpakowywana 7-Zipem,
  launcher `DIAScreen 1.8.exe` uruchamiany cicho (`/s /v"/qn"`), logi MSI i
  launchera (`/debuglog`) w raportach.
- Test sprawdza wersję `DIAScreen.exe` (`-ExpectedVersion`, w CI
  `DIASCREEN_VERSION` = 1.8.1.19) - czy łatka się nałożyła.

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
