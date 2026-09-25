# DIAScreen CI/CD

Projekt HMI DIAScreen (`PilaJednosuportowaINNER.dpa`, panel **PAC AX-8**)
wraz z pipeline'em CI, który automatycznie:

1. instaluje DIAScreen 1.8.1.19 na czystym runnerze,
2. otwiera projekt (hasło z sekretu `PROJECT_PASSWORD`) i robi **Compile** -
   test przechodzi przy `Find 0 error(s)!` + `Compilation successful`,
3. uruchamia **On-line Simulation** i przez **30 s** sprawdza, czy emulator
   (`HMIApp.exe`, "PAC AX-8 Emulator ... Online Mode") żyje i odpowiada -
   bez crasha, WerFault i zawieszenia okna.

Wzorowane na [Diadesigner-AX-CI-CD](https://github.com/PatrykChoinski/Diadesigner-AX-CI-CD),
przerobione pod DIAScreen.

## Jak to działa

DIAScreen to aplikacja MFC **bez** interfejsu wiersza poleceń ani
skryptowego - sterujemy nim przez komunikaty Win32, bez myszy i klawiatury
(działa też, gdy ktoś w tym czasie pracuje na komputerze):

| Krok                    | Jak                                                                                       |
|-------------------------|-------------------------------------------------------------------------------------------|
| otwarcie projektu       | `DIAScreen.exe "<kopia>.dpa"` (kopia w `work/` - plik w repo nie jest modyfikowany)       |
| hasło projektu          | dialog "Disable Protection": `WM_SETTEXT` do pola (id 1226) + `BM_CLICK` na OK            |
| Compile                 | `WM_COMMAND 50067` (`ID_COMPILE` z zasobu wstążki `DIAScreen.exe`) do głównego okna       |
| wynik kompilacji        | odczyt okna Output (`SysListView32` id 1208, `LVM_GETITEMTEXTW` z pamięci procesu x86)    |
| On-line Simulation      | `WM_COMMAND 50070` (`ID_ONLINE_EMULATOR`)                                                  |
| obserwacja              | co 1 s: proces emulatora żyje, `IsHungAppWindow` = false, brak `WerFault.exe -p <pid>`    |

Komunikat "TCP Read Error" w emulatorze jest oczekiwany - w trybie Online
emulator próbuje rozmawiać ze sterownikiem, którego na runnerze nie ma.
Test sprawdza, że symulacja działa, nie komunikację z PLC.

Każdy nieznany dialog (np. komunikat błędu) jest logowany z treścią i
zrzutem ekranu; jeśli wisi dłużej niż 20 s - etap pada z jego treścią w
raporcie.

```
windows-latest (hostowany runner GitHub Actions, świeża VM per job, sesja interaktywna)
├── DIAScreen 1.8.1.19 (z GitHub Release "Installers")
└── PAC AX-8 Emulator (HMIApp.exe, On-line Simulation)
```

## Struktura repo

```
PilaJednosuportowaINNER.dpa            - projekt DIAScreen (zaszyfrowany hasłem)
installers/README.md                   - skąd bierze się instalator (GitHub Release "Installers")
scripts/
  DiaScreenWin32.ps1                   - helpery Win32 (okna, dialogi, WM_COMMAND, Output, zrzuty ekranu)
  Invoke-DiaScreenTest.ps1             - cały test: otwarcie + Compile + On-line Simulation 30 s
  Install-DIAScreen.ps1                - cicha instalacja DIAScreen (InstallShield /s /v"/qn")
  Start-SilentInstall.ps1              - uruchomienie instalatora z twardym timeoutem
  Write-Summary.ps1                    - raport Markdown (GitHub Job Summary)
.github/workflows/diascreen-ci.yml     - workflow GitHub Actions (1 job)
reports/                               - raporty JUnit, logi, zrzuty ekranu (git-ignored)
work/                                  - katalog roboczy z kopią projektu (git-ignored)
```

## Raporty

- `junit-build.xml` - *Open project*, *Compile*,
- `junit-test.xml` - *Start On-line Simulation*, *Simulation runs for 30 s*,
- `compile-output.log` - pełna zawartość okna Output po kompilacji,
- `simulation-samples.log` - próbki co 1 s z obserwacji emulatora,
- `01-project-opened.png` ... `04-simulation-end.png` - zrzuty ekranu etapów
  (oraz `failure-*.png` / `*-dialog-*.png` przy problemach),
- `diascreen-install.log` - log MSI instalacji (tylko CI).

Ostatni krok workflow ([`Write-Summary.ps1`](scripts/Write-Summary.ps1))
składa raporty JUnit w **Job Summary** przebiegu; wszystko powyżej jest w
artefakcie `diascreen-ci-reports`.

## Hasło projektu

Projekt jest chroniony hasłem - bez niego DIAScreen pokazuje dialog
"Disable Protection". Hasło podawane jest przez zmienną środowiskową
**`PROJECT_PASSWORD`**:

- w CI - z sekretu repo `PROJECT_PASSWORD` (`gh secret set PROJECT_PASSWORD`),
- lokalnie - ze zmiennej środowiskowej użytkownika `PROJECT_PASSWORD`.

Hasło nigdy nie jest zapisywane w repo ani w logach. Złe hasło kończy etap
Build komunikatem "Project password rejected".

## Uruchomienie lokalne

Wymaga zainstalowanego DIAScreen 1.8.

```powershell
$env:PROJECT_PASSWORD = "..."     # albo trwała zmienna użytkownika PROJECT_PASSWORD
powershell -File .\scripts\Invoke-DiaScreenTest.ps1
```

Skrypt uruchamia **własną** instancję DIAScreen i na końcu zamyka tylko to,
co sam uruchomił (DIAScreen otwarty wcześniej przez użytkownika zostaje).
Emulator nie może już działać (wtedy test od razu kończy się błędem).
`-KeepRunning` zostawia DIAScreen i emulator otwarte.

## GitHub Release - instalator

Instalator (~224 MB) jest za duży na commit (limit 100 MB), więc leży jako
asset GitHub Release w tym repo:

| Release (tag) | Asset                                          |
|---------------|------------------------------------------------|
| `Installers`  | `DELTA_IA-OSW_DIAScreen_V1.8.1_SW_202607.exe`  |

Szczegóły: [`installers/README.md`](installers/README.md).

## Praca z repo

Zasady współpracy z Claude opisane są w [`CLAUDE.md`](CLAUDE.md), historia
zmian w [`CHANGELOG.md`](CHANGELOG.md).
