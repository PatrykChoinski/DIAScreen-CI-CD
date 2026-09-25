# Instalatory DIAScreen

Ten katalog jest miejscem docelowym dla pobranych instalatorów w trakcie CI
(git-ignored - nic poza tym plikiem nie trafia do repo).

## Skąd workflow bierze pliki

Oficjalne instalatory Delty są wgrane jako assety do GitHub Release w tym
repozytorium, tag **`Installers`**. Workflow ściąga je przez
`gh release download` z wbudowanym `GITHUB_TOKEN`:

| Asset                                          | Co to jest                                  | Rozmiar  |
|------------------------------------------------|---------------------------------------------|----------|
| `DELTA_IA-OSW_DIAScreen_V1.8.0_SW_202606.exe`  | DIAScreen 1.8.0.12 - pełna instalacja (baza) | ~1,7 GB  |
| `DELTA_IA-OSW_DIAScreen_V1.8.1_SW_202607.exe`  | DIAScreen 1.8.1.19 **Patch** - tylko łatka na istniejące 1.8 | ~224 MB |

Łatka 1.8.1 sama niczego nie instaluje (na czystej maszynie kończy się bez
efektu), dlatego najpierw instalowana jest baza 1.8, potem łatka.

⚠️ Release i jego assety dziedziczą widoczność repozytorium - w
publicznym repo są publicznie pobieralne.

## Jak są instalowane

[`scripts/Install-DIAScreen.ps1`](../scripts/Install-DIAScreen.ps1):

1. **Baza 1.8** - instalator to wrapper NSIS wokół nieskompresowanego
   layoutu InstallShield (`DIAScreen 1.8.exe`, `DIAScreen 1.8.msi`,
   `Setup.ini`, `ISSetupPrerequisites\...` - VC++, .NET 4.7.2, CodeMeter,
   GeneralPackage, DIAStudioTool). Normalnie rozpakowuje się do
   `%TEMP%\DIAScreen` i startuje interaktywnie; w CI rozpakowujemy go 7-Zipem
   do `work\diascreen-base` i uruchamiamy launcher InstallShield cicho:

   ```
   "DIAScreen 1.8.exe" /s /debuglog"reports\diascreen-setup-base.log" /v"/qn /norestart /l*v reports\diascreen-install-base.log"
   ```

2. **Łatka 1.8.1** - launcher InstallShield, te same parametry
   (logi `diascreen-*-patch.log`).

Na końcu skrypt sprawdza wpis w Uninstall (`DIAScreen*`) i
`DIAScreen.exe` w `InstallLocation` (domyślnie
`C:\Program Files (x86)\Delta Industrial Automation\DIAStudio\DIAScreen 1.8\`),
a test (`-ExpectedVersion`) - że `DIAScreen.exe` ma wersję z łatki
(`DIASCREEN_VERSION` w workflow). Logi trafiają do artefaktu
`diascreen-ci-reports`.

## Aktualizacja wersji

1. Pobierz nowy instalator (bazę i/lub łatkę) z Delta Download Center.
2. Wgraj go jako asset do Release `Installers`:
   `gh release upload Installers <plik>.exe --clobber`
3. Zaktualizuj w `.github/workflows/diascreen-ci.yml` `DIASCREEN_VERSION`,
   `DIASCREEN_BASE_ASSET` i `DIASCREEN_PATCH_ASSET`.
