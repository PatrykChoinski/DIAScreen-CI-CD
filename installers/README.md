# Instalator DIAScreen

Ten katalog jest miejscem docelowym dla pobranego instalatora w trakcie CI
(git-ignored - nic poza tym plikiem nie trafia do repo).

## Skąd workflow bierze plik

Oficjalny instalator Delty `DELTA_IA-OSW_DIAScreen_V1.8.1_SW_202607.exe`
(DIAScreen 1.8.1.19, ~224 MB) jest wgrany jako asset do GitHub Release w tym
repozytorium, tag **`Installers`**. Workflow ściąga go przez
`gh release download` z wbudowanym `GITHUB_TOKEN`.

⚠️ Release i jego assety dziedziczą widoczność repozytorium - w
publicznym repo są publicznie pobieralne.

## Jak jest instalowany

Plik to launcher InstallShield typu "Basic MSI" (w środku MSI DIAScreen).
[`scripts/Install-DIAScreen.ps1`](../scripts/Install-DIAScreen.ps1)
uruchamia go cicho:

```
DELTA_IA-OSW_DIAScreen_V1.8.1_SW_202607.exe /s /v"/qn /norestart /l*v reports\diascreen-install.log"
```

i czeka, aż pojawi się wpis w Uninstall (`DIAScreen*`) z `DIAScreen.exe`
w `InstallLocation` (domyślnie
`C:\Program Files (x86)\Delta Industrial Automation\DIAStudio\DIAScreen 1.8\`).
Log MSI trafia do artefaktu `diascreen-ci-reports`.

## Aktualizacja wersji

1. Pobierz nowy instalator z Delta Download Center.
2. Wgraj go jako asset do Release `Installers`:
   `gh release upload Installers DELTA_IA-OSW_DIAScreen_V<wersja>_SW_<data>.exe --clobber`
3. Zaktualizuj w `.github/workflows/diascreen-ci.yml` `DIASCREEN_VERSION`
   i `DIASCREEN_INSTALLER_ASSET`.
