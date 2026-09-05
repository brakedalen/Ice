# b16: stabilitet og bakgrunnsarbeid

Versjon: `0.12.0-brakedalen.16`, bygg `1154`.

## Avgrensning

Denne endringen reduserer bakgrunnsarbeid og beskytter asynkrone operasjoner mot utdaterte resultater. OneDrives native visning, valg av skjerm, plassering av popup og eksisterende sikkerhetskontroller for vanlige ikon-/spacerflyttinger skal beholdes. Ingen nye private macOS-API-er innføres. Minimumskravet er fortsatt macOS 14; implementeringen bygges med Xcode 26.6 / macOS 26 SDK.

## Valg og sikkerhetsgrenser

1. Menylinjens utseende: erstatt 1 ms-kontroller med maksimalt 11 kontroller fordelt over omtrent ti sekunder. Alle gjentakelser har pause og avbruddskontroll. Bare delt form trenger menygeometri fra Accessibility; bare hel/delt form trenger bakgrunnsbilder. Vinduer og tilhørende arbeid fjernes når effektene ikke trengs. Forhåndsvisning, lys/mørk modus og skjermbytte er med i vurderingen.
2. Tillatelser: kontroller hvert 30. sekund i bakgrunnen, med tidsmessig toleranse. Manglende tillatelser kontrolleres hvert sekund mens tillatelsesvisningen er åpen eller i inntil 120 sekunder etter en forespørsel. Oppvåkning, aktiv brukerøkt, aktivering av Ice og retur fra Systeminnstillinger utløser også kontroll. Uendrede verdier publiseres ikke på nytt. Både tilbakekalling og ny tillatelse oppdaterer bildebufferens tillatelsesstatus. Samtidige ventere har separate, avbruddsbevisste avslutninger.
3. Fargeinnhenting: lukkede Ice-rader har ingen periodisk bildeinnhenting. En eksplisitt oppdatering rett før visning beholdes for å unngå feil farge i første bilde. Skjermbytte forkaster forrige skjerms fargegrunnlag.
4. Ikonbilder: én eid innhenting om gangen, med sammenslåing av forespørsler. Skjerm-, Space-, layout- og fargeendringer ugyldiggjør eldre resultater. En kansellert brukerforespørsel kan avsluttes uten at en ny systeminnhenting overlapper den gamle. Når siste konsument avbrytes, starter ikke flere delinnhentinger eller reserveforsøk. Et gammelt visningskall får ikke åpne en lukket Ice-rad eller søkeboks igjen.
5. Gjen-skjuling: samlet forsøksbudsjett per midlertidig visning, med pauser på 3, 6, 12, 24 og 30 sekunder. Etter seks mislykkede forsøk suspenderes automatisk flytting. Den logiske originalplasseringen beholdes mens appen lever, slik at en midlertidig synlig plassering ikke lagres som et brukerønske. En ny vanlig midlertidig visning eller flytting i layoutredigereren kan erstatte denne tilstanden. Tilstand fra en avsluttet kildeapp ryddes bort. Et nyere manuelt flytteønske ugyldiggjør en eldre kølagt gjen-skjuling.

Skjermbildefeil bruker fortsatt den eksisterende reservemetoden. ScreenCaptureKit-innhenting kan ikke tvangsavbrytes midt i et systemkall; vi beholder eierskapet frem til kallet returnerer, og avbryter videre arbeid. Dette gir ikke en garanti mot en feil inne i macOS, men hindrer at Ice starter stadig flere parallelle kall.

## Nettgrunnlag

Retningslinjene under er primærkilder. Apples eldre energiveiledning er generell, ikke et nytt API-krav i macOS 26. Aktuell API-tilgjengelighet kontrolleres også mot det installerte macOS 26-SDK-et.

- [Apple: Minimize Timer Usage](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/Timers.html): unngå svært korte tidsgrenser, stopp ubrukte timere og tillat samkjøring av oppvåkninger.
- [Apple: Timer.tolerance](https://developer.apple.com/documentation/foundation/timer/tolerance).
- [Apple: Avoid Extraneous Content Updates](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/UsingEfficientGraphics.html): ikke oppdater usynlig eller uendret innhold unødvendig.
- [Apple: SCScreenshotManager](https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager).
- [Swift: Task cancellation](https://docs.swift.org/swift-book/LanguageGuide/Concurrency.html#Task-Cancellation) og [Apple: Task.cancel](https://developer.apple.com/documentation/swift/task/cancel()): avbrudd er samarbeidende; pågående arbeid må reagere på det.
- [Apple: TaskGroup](https://developer.apple.com/documentation/swift/taskgroup): gruppen venter på barna selv etter avbrudd. Derfor eies systeminnhentingen separat fra den tidsbegrensede UI-venteren.
- [Apple: aktiv brukerøkt](https://developer.apple.com/documentation/appkit/nsworkspace/sessiondidbecomeactivenotification): workspace-varsler observeres på riktig varslingssenter.

## Logg og måling

Loggen ligger fortsatt på `~/Library/Logs/Ice/automation.log`. Eksisterende størrelsesgrense og rotasjon beholdes. Tidsstempelet settes nå når hendelsen oppstår, før den settes i filkøen.

- `SESSION_START`: kontroller b16 / 1154 før sammenligning.
- `APPEARANCE_PANELS`, `APPEARANCE_POLICY`: antall dekorasjonsvinduer og nødvendige ressurser.
- `APPEARANCE_PERF`: antall og samlet varighet for menygeometri/bakgrunnsbilder, normalt maksimalt én oppsummering per minutt per skjerm. En overgang/avslutning kan skrive siste oppsummering tidligere.
- `ICE_BAR_COLOR_PERF`: antall fargeinnhentinger, feil og samlet varighet; ingen egen loggtimer.
- `PERMISSION_CHECK`, `PERMISSION_POLLING`: reelle overganger, kontrollintervall og langsomme kontroller; ikke en logglinje for hver uendret bakgrunnskontroll.
- `CAPTURE_QUEUE`, `CAPTURE_BATCH`: samordning, ugyldiggjøring, varighet og resultat av innhenting. `current=false` betyr at gammelt arbeid ble forkastet, ikke nødvendigvis en feil.
- `TEMP_REHIDE_RETRY_SCHEDULED`, `TEMP_REHIDE_SUSPENDED`, `TEMP_REHIDE_PASS`: mislykkede forsøk, pauser og gjenværende arbeid. Suspensjon skal logges én gang per uttømt forsøkstilstand, ikke gjentas hvert tredje sekund.
- `ENFORCEMENT_PHASE`, `ENFORCEMENT_PASS_END`: felles forespørsels-ID, ventetid før start, ventetid for stabilisering, bufferoppdatering og samlet varighet.
- Eksisterende `CURSOR_HIDE_*`, `MOVE_*` og `OD_NATIVE_REVEAL_*` beholdes for regresjonskontroll.

Loggføringen måler arbeid som faktisk gjøres; den starter ikke egne skjermopptak eller ekstra WindowServer-kontroller for å måle ytelse.

## Automatisert kontroll

Verifisert 5. september 2026 på macOS 26.5.2 med Xcode 26.6:

- Debug testbygg bestått.
- Hele XCTest-pakken: **59 tester bestått, 0 feil**. Inkluderer 40 nye tester og 19 eksisterende regresjonstester.
- Release-bygg bestått for både Apple Silicon og Intel (`arm64`, `x86_64`), uten installasjon eller oppstart. Kodesignering var deaktivert bare for kontrollbygget; prosjektets vanlige signeringsoppsett er uendret.
- SwiftLint 0.65.1, streng kontroll av alle endrede produksjonsfiler: **0 avvik**.
- `git diff --check`: bestått.
- Xcode rapporterte at AppIntents-metadata ble hoppet over fordi målet ikke avhenger av AppIntents. Testverten skrev også systemmeldinger om `com.apple.linkd.autoShortcut`; disse ga ingen testfeil. Reell UI-/WindowServer-belastning etter installasjon er ikke målt i denne runden.

Verifikasjonsartefakter fra denne kjøringen ligger i `/private/tmp/ice-b16-qa.TWedxt/`: `final-tests.log`, `FinalTests.xcresult`, `release-build.log` og `lint.json`. Midlertidige filer kan bli ryddet av macOS; dette dokumentet bevarer konklusjonen.

Nye tester dekker avgrensede oppdateringsplaner, avbrudd, samtidige bildeforespørsler, ugyldiggjøring mellom delinnhentinger, tillatelsesoverganger, samtidige tillatelsesventere og samlet gjen-skjulingsbudsjett. Eksisterende tester for automasjon, trygge flyttekoordinater og musepeker inngår i integrasjonskontrollen.

Testhandlingen i Ice-skjemaet setter `ICE_UNIT_TESTING=1`. Debug-startpunktet velger da en inert testvert uten AppState, statusikoner, migrering eller automasjon. Vanlig Run og Release bruker normal oppstart. For kjøring ved siden av installert Ice brukes i tillegg en separat QA-bundle-ID og midlertidig byggmappe. Ikke kjør Release som unit-testvert: isolasjonen er bevisst Debug-avgrenset.

## Kort manuell regresjonstest

1. Start b16. Åpne begge OneDrive-ikonene vekselvis, lukk dem og kontroller at popup følger riktig skjerm. Test med én og to skjermer.
2. Åpne/lukk Ice-raden og søk raskt flere ganger. En lukket visning skal ikke åpnes igjen av seg selv. Kontroller Alfred/andre vanlige ikoner og at de skjules igjen etter bruk.
3. Bytt mellom ingen form, hel form og delt form. Slå alle effekter av/på, test forhåndsvisning og lys/mørk modus. Bytt app noen ganger, inkludert apper med lik menylengde. Test fullskjerm og tilbake.
4. Flytt et vanlig ikon og en spacer i layoutredigereren. Kontroller Wi-Fi og at en tidligere automatisk operasjon ikke flytter et ikon tilbake etter en manuell flytting.
5. La appen stå med lukket Ice-rad og lukkede innstillinger i to minutter. Gjenta etter at utseendeeffektene er slått av. Oppgi omtrentlige klokkeslett for sammenligning av logg og CPU-måling.
6. Test dvale/oppvåkning og strømtilkobling for automasjon. Tillatelses-testene er automatisert med injiserte verdier; reell tilbakekalling/ny tillatelse i Systeminnstillinger er en separat valgfri test som kan kreve omstart for skjermopptak.

En kort CPU-måling med b16 er ikke tilstrekkelig til å fastslå hvor mye Ice påvirker WindowServer. Sammenlign like skjermoppsett, samme bruk og samme øvrige apper før/etter. Den installerte b15-appen erstattes ikke av byggeverifikasjonen.
