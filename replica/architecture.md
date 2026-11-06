# Architecture: Film Hub (client Jellyfin personale per iPhone, sul modello del nucleo di Streamyfin)

Nome di lavoro "Film Hub", come la repo. Il nome definitivo arriva con
replica-brand, se serve.

## Stack

Niente backend nostro: il backend è il server Jellyfin dell'utente. L'app parla
solo con le sue API pubbliche, con l'account dell'utente.

| layer | choice | why |
| --- | --- | --- |
| app | Swift 5.10+, SwiftUI, iOS 17+ | nativo: il player più fluido, PiP e background audio di sistema, `@Observable` e `NavigationStack` |
| player 1 | AVPlayer (AVKit) | file compatibili (MP4/MOV, H.264/HEVC, AAC/AC3/EAC3): hardware decoding, PiP, controlli di sistema |
| player 2 | MobileVLCKit 3.6 (CocoaPods, ufficiale VideoLAN) | MKV, DTS, PGS e tutto il resto in riproduzione diretta, senza chiedere transcodifiche al server |
| rete | URLSession + async/await | nessuna dipendenza; timeout espliciti su ogni chiamata |
| logica condivisa | Swift package locale `JellyCore` | API client, modelli, scelta del player, coda dell'avanzamento: testabile con `swift test` senza simulatore |
| dati locali | Keychain (token); file JSON in Application Support (coda avanzamento, cache home) | pochi dati, nessun database serve |
| immagini | `URLCache` da 300 MB su disco + `NSCache` in memoria | P3: le locandine non si riscaricano |
| progetto Xcode | XcodeGen (`project.yml`) | niente `.pbxproj` scritto a mano: il progetto si genera nella CI |
| build | GitHub Actions `macos-15`: test di JellyCore, `xcodegen`, `pod install`, `xcodebuild archive` senza firma, IPA come artifact | nessun Mac necessario; l'IPA si firma con iLoader |

## Schema

Non c'è un database: libreria, avanzamenti e stato "visto" vivono sul server
Jellyfin. Tables: 0. Access rules: quelle del server (ogni chiamata porta il
token dell'utente).

Persistenza locale, tutta per utente e server:

```
Keychain   service "filmhub", account "<serverId>:<userId>"
           -> accessToken

account.json   { serverURL, serverId, serverName, userId, userName, deviceId }
               deviceId: UUID generato una volta e mai cambiato
               (Jellyfin lega le sessioni al dispositivo)

pending-progress.json   [ { itemId, mediaSourceId?, playSessionId?, positionTicks,
                            runTimeTicks?, isPaused, finished, recordedAt } ]
               - una sola voce per itemId: vince la più recente (recordedAt)
               - rimossa solo quando il server risponde 2xx

home-cache.json   ultima home caricata (resume, nextUp, latest per libreria),
               mostrata subito all'avvio e poi aggiornata
```

## API

Tutte del server Jellyfin (10.9+), percorsi verificati sulle specifiche OpenAPI
ufficiali (jellyfin-sdk-swift). JSON in PascalCase. 1 s = 10.000.000 tick.

Header su ogni chiamata:
`Authorization: MediaBrowser Client="Film Hub", Device="iPhone", DeviceId="<uuid>", Version="<ver>", Token="<token>"`
(senza `Token` prima del login).

| method path | does | who | input | output | flow |
| --- | --- | --- | --- | --- | --- |
| GET /System/Info/Public | verifica l'URL, nome e versione del server | chiunque | — | ServerName, Version, Id | F01 |
| POST /Users/AuthenticateByName | accesso | chiunque | { Username, Pw } | AccessToken, User, ServerId | F01 |
| GET /QuickConnect/Enabled, POST /QuickConnect/Initiate, GET /QuickConnect/Connect?secret=, POST /Users/AuthenticateWithQuickConnect | accesso con codice | chiunque | Secret | Code, Authenticated, AccessToken | F01 (should) |
| GET /UserItems/Resume | Continua a guardare | utente | userId, limit, fields, enableUserData, mediaTypes=Video | items con UserData | F02, F05 |
| GET /Shows/NextUp | Prossimi episodi | utente | userId, limit, fields, enableResumable=false | items | F04 |
| GET /UserViews | librerie | utente | userId | viste (CollectionType) | S04 |
| GET /Items/Latest | aggiunti di recente | utente | userId, parentId, limit | [items] | S03 |
| GET /Items | griglia libreria, ricerca | utente | userId, parentId, includeItemTypes, recursive, sortBy, sortOrder, startIndex, limit=60, fields, searchTerm | items, TotalRecordCount | F03, F06 |
| GET /Items/{id} | scheda | utente | userId | item completo con MediaSources e MediaStreams | F03 |
| GET /Shows/{id}/Seasons, GET /Shows/{id}/Episodes | stagioni, episodi | utente | userId, seasonId, fields | items | F04 |
| POST /Items/{id}/PlaybackInfo | sceglie come riprodurre | utente | userId, mediaSourceId, audio/subtitle index, startTimeTicks; body con DeviceProfile | MediaSources (SupportsDirectPlay, TranscodingUrl…), PlaySessionId | F02-F04 |
| GET /Videos/{id}/stream?static=true&mediaSourceId=&api_key= | file originale (diretta) | utente | — | byte del file, con Range | player |
| GET {TranscodingUrl} | flusso HLS dal server (solo come ultima risorsa) | utente | — | m3u8 | player |
| GET /Videos/{id}/{msId}/Subtitles/{index}/0/Stream.vtt | sottotitoli testuali per AVPlayer | utente | — | WebVTT | F07 |
| GET /MediaSegments/{id} | intro e titoli di coda | utente | includeSegmentTypes | StartTicks, EndTicks, Type | should |
| POST /Sessions/Playing | inizio visione | utente | PlaybackStateInfo | 204 | F02 |
| POST /Sessions/Playing/Progress | avanzamento (ogni 10 s, pausa, background) | utente | PositionTicks, IsPaused, PlaySessionId, PlayMethod… | 204 | F05 |
| POST /Sessions/Playing/Stopped | fine visione | utente | PositionTicks, PlaySessionId | 204 | F05 |
| POST /UserItems/{id}/UserData | non usato: 403 per utenti non admin sul server dell utente (vedi server-test.md) | — | — | — | — |
| POST/DELETE /UserPlayedItems/{id} | segna visto / non visto | utente | — | UserData | should |
| GET /Items/{id}/Images/{Primary\|Backdrop\|Thumb}?fillWidth=&quality=85&tag= | immagini ridimensionate | utente | — | jpeg/webp | tutte |

Webhooks in: nessuno. Webhooks out: nessuno.
Jobs (nell'app):
- `ProgressReporter`: ogni 10 s durante la visione, a ogni pausa, seek e uscita.
- `ProgressQueue.flush()`: all'avvio, al ritorno in primo piano, quando la rete
  torna (NWPathMonitor), dopo ogni invio riuscito.
- Ricarica della home: all'avvio, al ritorno in primo piano, alla chiusura del player.

## Scelta del player (il cuore di P1 e P3)

`PlaybackDecider` in JellyCore, puro e testato:

1. Chiede PlaybackInfo con un DeviceProfile "AVPlayer" (DirectPlay: mp4, m4v,
   mov con h264/hevc e aac/ac3/eac3/mp3/alac/flac; sottotitoli esterni vtt/srt).
2. Se la sorgente è riproducibile in diretta dal profilo AVPlayer → **AVPlayer**
   sul file originale (`static=true`).
3. Altrimenti (MKV, AVI, DTS, TrueHD, PGS…) → **VLC** sul file originale. Nessun
   lavoro per il server.
4. Se VLC fallisce l'apertura e il server offre `TranscodingUrl` → **AVPlayer su
   HLS** come ultima risorsa, con messaggio "riprodotto convertito dal server".
5. Impostazione "Player": Automatico / Sempre VLC / Preferisci Apple.

## The parts that bite

- **Avanzamento (P2)**: una chiusura dal multitasking non lascia tempo per una
  chiamata di rete. Per questo l'avanzamento si salva *prima* in coda locale
  (scrittura su file, istantanea) e poi si invia. Se l'invio non parte, ci pensa
  il flush al prossimo avvio, che reinvia la posizione come `/Sessions/Playing/Stopped` (provato sul server reale). Al passaggio in
  background si usa `beginBackgroundTask` per completare l'invio.
- **Idempotenza**: gli invii sono "l'ultima posizione vince", quindi ripeterli
  è innocuo. La coda tiene una voce per titolo, la più recente; un invio vecchio
  non sovrascrive mai una posizione più recente.
- **Stalli (P1)**: AVPlayer: se `timeControlStatus` resta in attesa oltre 12 s
  con la rete attiva, o arriva `playbackStalled`/`failedToPlayToEndTime`, si
  ricrea l'`AVPlayerItem` alla stessa posizione (massimo 3 tentativi, poi errore
  con "Riprova"). VLC: stessa regola su stato `buffering` o `error`.
- **Thread principale**: niente chiamate VLC o di rete sincrone sul main thread
  (la causa di #2412 in Streamyfin). Il player VLC vive in un oggetto dedicato.
- **Tempi di apertura (P3)**: scheda = `async let` di item + stagioni/episodi;
  PlaybackInfo preparato appena la scheda appare e riusato al tocco su Play
  (valido 60 s). Home dalla cache, poi aggiornata. Timeout: 15 s sulle API,
  30 s sull'apertura del flusso.
- **Certificati e URL**: l'utente può scrivere l'URL senza `https://` o con lo
  slash finale; si normalizza. HTTP in chiaro consentito
  (`NSAllowsArbitraryLoads`) perché molti server personali non hanno HTTPS.
- **Token**: solo nel Keychain, mai nei log. Nell'URL del flusso va come
  `api_key` perché i player non possono mandare header personalizzati.
- **Librerie enormi** (milioni di titoli): sempre paginate (`limit=60`),
  `enableTotalRecordCount` solo dove serve, campi richiesti al minimo.
- **Firma**: con un Apple ID gratuito iLoader firma per 7 giorni; poi va
  rifirmata. Nessuna capability a pagamento (niente iCloud, niente push).
- **Rate limit, GDPR, multi-tenant, fusi orari**: non si applicano (un utente,
  nessun dato nostro). Le date dal server sono ISO 8601 in UTC.

## Layout della repo

```
ios/
  project.yml              XcodeGen
  Podfile                  MobileVLCKit
  App/                     SwiftUI: schermate S01-S10, player, Info.plist
  JellyCore/               Swift package: API, modelli, PlaybackDecider,
                           ProgressQueue, Ticks + Tests/
.github/workflows/ios.yml  test -> build -> FilmHub.ipa (artifact)
replica/                   documenti del metodo Replica
```

## Build order

1. **Vertical slice**: S01, S02, S03 (solo Continua a guardare), S08 con
   AVPlayer e VLC, ProgressReporter + coda. Endpoint: System/Info/Public,
   AuthenticateByName, UserItems/Resume, Items/{id}, PlaybackInfo, stream,
   Sessions/Playing*, UserItems/{id}/UserData. La CI produce la prima IPA.
   Prova del nove: guardo 5 minuti, chiudo l'app dal multitasking, riapro, il
   film è in cima con la posizione giusta.
2. **Must-haves**: S04, S05, S06, S07, S09, Prossimi episodi, Aggiunti di
   recente, scelta audio/sottotitoli, recupero dagli stalli, ricarica home in
   primo piano.
3. **Should-haves**: prossimo episodio con countdown, salta intro (MediaSegments),
   PiP, audio in background, segna come visto, Quick Connect, qualità massima,
   lingue predefinite, cache immagini, trickplay.
4. **Fixes from replica-entrepreneur**: non ancora eseguito.
