# Ice 0.12.0-brakedalen.17 (1155)

## Mergegrunnlag

`main` ble først hurtigspolt til `custom-build` på `df3b563`
(`0.12.0-brakedalen.16`, bygg 1154). Deretter ble
`codex/macos27-compatibility` på `740fb0c` slått sammen med en merge-commit.
Begge historikkene beholdes; `custom-build` overskrives ikke.

Konfliktene ble løst mot den felles kildekodebasen `6d74d25`, slik at
macOS 27-koden ble lagt til custom-build uten å erstatte b16-tilpasningene.

## Bevarte tilpasninger og integrasjon

- Automatisering med Wi-Fi/strøm og lagrede plasseringer, inkludert vern mot
  gammel automatisk flytting etter en manuell layoutendring.
- Spacer-innstillinger og eksisterende spacer-kode.
- OneDrive-støtte for flere kontoer og valgt skjerm. Bildebufferen bruker
  fortsatt vindus-ID fremfor tag, siden ulike kontoikoner kan ha samme tag.
- Samordnet bildeinnhenting med avbrudd og generasjoner. En lukket Ice-rad
  skal fortsatt ikke gjenåpnes av en gammel bildeforespørsel.
- Tillatelseslivssyklus, ytelsesstyring og diagnostikk fra b16.
- Eksisterende XCTest-filer og inert Debug-testvert (`ICE_UNIT_TESTING=1`).

På macOS 27 går automatisering via lagrede appseksjoner, og klikk fra både
Ice-raden og søk bruker den nye Accessibility-/MenuBarAgent-banen med valgt
skjerm. Manuell seksjonsendring ugyldiggjør tidligere automasjonsarbeid.
Ice-radens fargeinnhenting bruker en flat systemfarge på macOS 27 og unngår
periodiske forsøk på å hente et menylinjevindu som ikke lenger finnes.

macOS 27 skjuler hele apper. Ved motstridende seksjoner for samme app vinner
den mest synlige, også når et annet ikon fra appen ikke har en regel.
Systemet bestemmer rekkefølgen i den vanlige menylinjen; gamle naboplasseringer
og individuell flytting av Ice-spacere kan derfor ikke brukes på macOS 27.
Spacer-drag må ikke skjule hele Ice-appen. Tidligere macOS beholder sin
eksisterende flyttebane. Lagrede innstillinger slettes ikke av sammenslåingen.

## Verifikasjon

Kontrollert 7. oktober 2026 i Linux-miljøet:

- Swift 6.2: **134 tester i 25 suiter bestått**, inkludert tre nye tester for
  automasjon med flere ikoner/kontoer fra samme app.
- SwiftLint 0.63.2 med SourceKit, `--strict --no-cache`: **0 avvik**.
- Swift-parseren: alle app-, service-, Shared- og XCTest-kilder bestått.
- Plist-, pakkelås-, Xcode-skjema- og shell-syntaks kontrollert.
- `git diff --check`: bestått. Ingen uløste merge-konflikter.
- Alle sju opprinnelige XCTest-filer er byte-identiske med b16. Det samme
  gjelder blant annet automasjonsinnstillinger, spacer-manager,
  bildekoordinator, tillatelsesmanager og testvert/testskjema.

Xcode-bygg, de 59 eksisterende native XCTest-testene og manuell oppstart må
kontrolleres på Mac. Resultatene for b16 i [QA-b16.md](QA-b16.md) gjelder b16
og er ikke en verifikasjon av dette merge-bygget.

## Kontroll i Xcode

1. Bytt til **main** og pull. Om-versjonen skal være
   **0.12.0-brakedalen.17**, bygg **1155**.
2. Bygg og kjør Ice. Kjør også testhandlingen i Ice-skjemaet.
3. Kontroller at automasjonsregler og spacer-innstillinger fortsatt finnes.
   Test Wi-Fi/strøm-regler og manuell endring mellom seksjoner.
4. Åpne begge OneDrive-kontoikonene fra Ice-raden og søk. Kontroller riktig
   konto og skjerm, og at ikonene skjules igjen når popup lukkes.
5. Åpne/lukk Ice-raden raskt flere ganger. Kontroller dvale/oppvåkning,
   lys/mørk modus, utseendeeffekter og CPU med lukket rad.
6. På macOS 27: test klokke, Wi-Fi, batteri, Control Centre, ekstern skjerm
   og kamera-/mikrofonindikator, som beskrevet i [MACOS27.md](../MACOS27.md).
