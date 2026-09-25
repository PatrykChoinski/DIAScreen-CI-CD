# Changelog

## 2026-09-25 (2)

### Naprawione
- CI: instalacja kończyła się bez efektu - `DELTA_IA-OSW_DIAScreen_V1.8.1_SW_202607.exe`
  to łatka ("DIAScreen 1.8.1.19 Patch") na istniejące DIAScreen 1.8, nie
  pełny instalator. Teraz najpierw instalowana jest baza
  `DELTA_IA-OSW_DIAScreen_V1.8.0_SW_202606.exe` (1.8.0.12, dodana do
  Release `Installers`), potem łatka.
- Baza to wrapper NSIS wokół layoutu InstallShield - rozpakowywana 7-Zipem,
  a `DIAScreen 1.8.msi` instalowane bezpośrednio przez `msiexec /qn`
  (launcher `DIAScreen 1.8.exe /s` wisiał na CI > 20 min). Z
  prerekwizytów launchera doinstalowywany tylko VC++ 2013 x86.
- `msiexec /qn` wisiał w akcji `InstallUSBDriver` - DPInst instalujący
  sterowniki (Delta HMI USB, wirtualny port szeregowy, TAP) czekał na monit
  "Czy chcesz zainstalować to oprogramowanie urządzenia?" (bezpieczny
  pulpit, niewidoczny na CI). Przed instalacją certyfikaty sygnatariuszy
  katalogów `*.cat` z paczki są dodawane do `LocalMachine\TrustedPublisher`.
- Łatka "znikała" po 4 s bez efektu - launcher InstallShield uruchamia
  swoją kopię z `%TEMP%` bez czekania i od razu kończy się kodem 0; teraz
  czekamy także na tę kopię.
- Baza instalowana do `INSTALLDIR=...\DIAStudio\DIAScreen 1.8` (jak przy
  instalacji interaktywnej; domyślny katalog MSI przy `/qn` to sam
  `DIAStudio\`).
- Każdy instalator działa pod watchdogiem: co minutę lista okien/dialogów
  drzewa procesów instalatora + zrzut ekranu (`install-*.png`), po
  timeoucie (15 min) drzewo procesów jest zabijane.
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
