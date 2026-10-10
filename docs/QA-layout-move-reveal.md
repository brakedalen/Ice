# Layoutflytting: midlertidig native visning

## Versjonsgrunnlag

- Installert app og undersøkt logg: **b16 / 1154**, commit `df3b563`.
- Feilrettingsbranch: `codex/fix-layout-move-reveal`, fra **b17 / 1155**,
  commit `7fa4a38`. macOS 27-integrasjonen fra main beholdes.
- Maskin: macOS **26.7.1**, Apple Silicon. Kontrollverktøy: Xcode **27.0**.
- Appen i `/Applications` er ikke erstattet eller startet fra feilrettingsbranchen.

## Bekreftet feilsted og begrensning i diagnosen

Loggen viser samme feil ved forskjellige mål, både et vanlig ikon i Hidden,
et ikon i Always-Hidden og Always-Hidden-skillepunktet:

`LAYOUT_MOVE_PREFLIGHT_FAILED sourceStable=true targetStable=false`

Kilde- og målvindu finnes fortsatt. `EventError.unsafeLayoutMove` kommer fra
kontrollen før syntetisk draing. Det er derfor ikke en feil i hvilken app
mouse-up sendes til. En flytting mellom to allerede synlige ikoner lyktes.

Koden inneholder to konkrete feil i denne midlertidige visningen:

1. `noDivider` setter skillepunktene til **null bredde** selv når layouteditoren
   trenger dem som synlige flyttemål. Markøren på 3 punkter var tidligere bare
   aktivert av en virkelig Command-drag i menylinjen. Draing i layouteditoren
   aktiverer ikke det flagget.
2. Inputmonitorene stoppes først etter preflight. Tidligere planlagt smart
   rehide, hover, fokus-rehide eller tidsstyrt rehide kan endre seksjonene mens
   preflight venter. Loggen har også en feil med `restored=false`, som viser
   at noen hadde endret tilstanden under transaksjonen.

Disse svakhetene er rettet. Den eksisterende loggen registrerer ikke målrammen
og seksjonstilstandene ved timeout, så den beviser **ikke** hvilken svakhet
eller eventuell plassmangel som forklarer hvert enkelt forsøk. Ny diagnostikk
logger dette. En full menylinje/notch kan fremdeles gjøre et mål usynlig.
Fiksen skal ikke omgå denne sikkerhetsgrensen.

## Endringen

- Native layoutflytting reserverer en midlertidig 3-punkts markør også når
  brukeren har valgt ingen skilletegn. Den kollapses igjen etter transaksjonen.
  Begge overganger oppdaterer statusikonet.
- Inputmonitorene pauses gjennom hele reveal, preflight og flytting. Eksisterende
  nesting av stop/start beholdes og gjenopprettes med `defer` også ved feil.
- Forsinkede smart-/hover-/fokus-handlinger forkastes hvis en layoutflytting
  har begynt eller sluttet siden de ble planlagt.
- Tidsstyrt rehide pauses ved reveal og startes igjen for fortsatt synlige
  seksjoner etter at transaksjonen er avsluttet. Gamle timerhandlinger forkastes.
- Seksjonenes show/hide og native cachepublisering får samme eierskapsvern.
  Cachegrunnlag fra før en manuell flytting får ikke håndheve gammel dividerorden.
- Ved preflight-feil logges aktuell geometri, on-screen-status, skjermtreff og
  seksjonstilstander. Ingen ekstra polling eller nye private API-er innføres.
- Kravet om et stabilt, faktisk synlig mål og sikre koordinater før mouse-up
  er beholdt. `MenuBarMoveSafety` og selve drahendelsene er uendret.

## Nettgrunnlag og macOS 27

[Apple: NSStatusItem.length](https://developer.apple.com/documentation/appkit/nsstatusitem/length)
beskriver at egenskapen angir plassen som allokeres til statusikonet.
En positiv, midlertidig bredde er derfor nødvendig for et synlig skillepunkt.

[Apple: NSStatusItem.isVisible](https://developer.apple.com/documentation/appkit/nsstatusitem/isvisible)
presiserer at egenskapen kan være true selv når plassmangel skjuler ikonet.
Derfor beholdes den faktiske WindowServer-kontrollen; bare `isVisible` er
ikke tilstrekkelig for å godkjenne flytting.

[Upstream PR #995](https://github.com/jordanbaird/Ice/pull/995) dokumenterer
at macOS 27 bruker MenuBarAgent og lagrede appseksjoner, ikke separate
ikonvinduer. Den eksisterende availability-grenen i layouteditoren beholdes.
Den midlertidige native markøren aktiveres ikke på macOS 27. macOS 27 støtter
seksjonsendringer per app; fysisk rekkefølge i menylinjen bestemmes av systemet.

SDK 27-kontrollen avdekket dessuten en eksisterende byggfeil i b17-pakken:
`ItemHitTest27.Item: Equatable` trenger CoreGraphics-overlegget for CGRect på
Darwin. En betinget `import CoreGraphics` retter dette og beholder Linux-støtten.

Disse kildene bekrefter API-premissene og OS-skillet, ikke at feilrettingen
allerede er funksjonstestet på begge operativsystemene.

## Utført verifikasjon, 10. oktober 2026

- **8 nye XCTest-tester bestått**, 0 feil. Faktisk produksjonsfil
  `MenuBarLayoutMovePolicy.swift` ble kompilert som en isolert, testbar modul;
  testfilen ble kjørt som en selvstendig XCTest-bundle uten AppState/statusikoner.
  Dette er ikke hele appens testpakke.
- **134 tester i 25 suiter bestått** i `IceMacOS27Core`, kompilert med macOS 27
  SDK og kjørt på macOS 26.7.1. Etter CoreGraphics-importen bygger pakken på Mac.
- Swift-parseren: alle endrede Swift-kilder bestått.
- SwiftLint 0.65.1, `--strict --no-cache`: **0 avvik** i endrede produksjonsfiler.
  Testfilen følger eksisterende IceTests-headerkonvensjon.
- `git diff --check`: bestått.
- **Full appbygging og de eksisterende 59 app-testene er ikke kjørt ferdig.**
  `xcodebuild` stopper med exit 69 fordi Xcode-lisensen ikke er godkjent.
  Full kontroll må kjøres etter at brukeren har godkjent lisensen i Xcode.
- Ingen vellykket manuell flytting med det nye bygget er bekreftet.
- Ingen kjøring på en faktisk macOS 27-maskin er utført.

Midlertidige kontrollartefakter ligger i `/private/tmp/`:
`ice-layout-policy-tests.log`, `ice-layout-fix-spm-tests.log`,
`ice-layout-fix-lint.log` og `ice-layout-fix-tests.log`.

## Gjenstående godkjenningskontroll

1. Kjør Debug-testhandlingen med `ICE_UNIT_TESTING=1`, isolert QA-bundle-ID
   og separat DerivedData, slik [QA-b16.md](QA-b16.md) beskriver. Bygg Release
   for arm64 og x86_64 uten installasjon.
2. På macOS 26: prøv Visible → Hidden → Always-Hidden → Visible med et vanlig
   ikon og en spacer, med ingen skilletegn og chevron. Kontroller også en
   seksjon som opprinnelig var vist, begge hovertilstander og alle rehidevalg.
3. Kontroller at `PREFLIGHT_READY`, `MOVE_SUCCESS` og `restored=true` følger
   hverandre. Ved fortsatt feil brukes de nye målrammene til å skille mellom
   null bredde, feil skjerm, forsvunnet vindu, ustabil layout og plassmangel.
4. Ved full menylinje/notch skal flytting avvises trygt når målet faktisk ikke
   er synlig. Ingen systemikoner skal fjernes eller slippes utenfor menylinjen.
5. Test avbrudd/feil: monitorer, originaltilstander, markørbredde og tidsstyrt
   rehide skal gjenopprettes. Test dvale/skjermbytte og to skjermer.
6. På macOS 27: kontroller lagrede appseksjoner og regresjonspunktene i
   [MACOS27.md](../MACOS27.md), spesielt seksjonsdrag, systemklikk og flere
   ikoner fra samme app. Native draing skal ikke bli valgt på macOS 27.

## Nye loggfunn kl. 17:43 og andre retting

Klokkeslett her er Oslo-tid (loggens tid er UTC). Den kjørende prosessen er
`/Applications/Ice.app`, vanlig **b17 / 1155**. Verken den utvidede diagnostikken
eller `MenuBarLayoutMovePolicy` fra første feilretting finnes i dette bygget.
Å oppdatere til vanlig b17 installerer altså ikke feilrettingsbranchen.

Det nyeste Magnet → Wi-Fi-forsøket viser:

- Preflight består: kilde x=1394, mål x=728, begge 25 × 39 punkter.
- Draingen sendes.
- Etterkontrollen kaster `missingItemBounds`, mens feilrapporten samtidig
  bekrefter `sourceExists=true targetExists=true`.
- Etter gjen-skjuling blir Magnet registrert i Always-Hidden.

Koden forklarer den uriktige «mangler»-feilen: `visibleLayout` kalte
`getMenuBarItems(on: displayID, ...)`. Den funksjonen **legger automatisk til
`.onScreen`** når en skjerm-ID er gitt. Et ikon som faller ut av den synlige
listen under macOS' relayout blir dermed behandlet som et forsvunnet vindu.
Den tidligere rettingen av reveal alene dekket ikke denne etterkontrollen.

Etterkontrollen bruker nå den eksisterende, felles lesingen av **to konkrete
vindus-ID-er i én snapshot**, inkludert skjulte vinduer. Det kreves riktig
nabokant på riktig side; eksisterende vinduer i feil posisjon godtas ikke.
Layoutflytting krever også 200 ms sammenhengende korrekt plassering før den
meldes ferdig. Intern flytting beholder sin umiddelbare posisjonskontroll.
Alle sikkerhetskrav før nye drahendelser beholdes. macOS 27-seksjonsdrag bruker
fortsatt sin separate lagrede app-layout.

[Apple: CGWindowListCreateDescriptionFromArray](https://developer.apple.com/documentation/coregraphics/cgwindowlistcreatedescriptionfromarray(_:))
beskriver oppslag med konkrete vindus-ID-er og at faktisk fjernede vinduer
utelates. Dette er API-et den eksisterende snapshot-lesingen bruker.

Fem nye regresjonstester dekker et korrekt dropp som forsvinner fra den
synlige listen, feil plassering og stabiliseringsintervallet. Sammen med de
åtte første testene er disse kjørt isolert mot de faktiske produksjonsfilene
`MenuBarMoveSafety` og `MenuBarLayoutMovePolicy`: **13 bestått, 0 feil**.
Swift-parseren og streng SwiftLint på de endrede produksjonsfilene bestod.

Et bygg med begge rettingene logger `policy=native-bounds-v2` i
`LAYOUT_MOVE_REVEAL_START`. Det gjør det mulig å kontrollere at den kjørende
appen faktisk inneholder feilrettingene, selv om versjonsnummeret er b17.
Full appbygging og manuell funksjonskontroll er fortsatt nødvendig.

En branch-avgrenset GitHub Actions-jobb bygger og tester både på `macos-26`
og `xcode-27`. Den bruker den inerte Debug-testverten og lager en usignert
universell Release-app med begge rettingene. Den krever ingen signeringsnøkler.
macOS 27-runneren er beskrevet i
[GitHubs offisielle runner-kunngjøring](https://github.com/actions/runner-images/issues/14404).
Resultatene må leses før bygget kan regnes som verifisert.
