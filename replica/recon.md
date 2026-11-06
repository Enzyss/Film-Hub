# Recon map: Streamyfin (iOS, iPhone)

Scope: il nucleo di un client Jellyfin per iPhone. Collegamento al server, home
con "Continua a guardare" e "Prossimi episodi", librerie di film e serie,
scheda del titolo, player affidabile con ripresa dal punto giusto, ricerca.
For: uso personale (un solo utente, il proprio account su un server Jellyfin).
Niente App Store: l'IPA si compila con GitHub Actions e si firma con iLoader.
Date: 2026-11-06

## Sources

| # | source | URL | notes |
| --- | --- | --- | --- |
| 1 | README di Streamyfin | https://github.com/streamyfin/streamyfin | elenco funzioni, screenshot di home, libreria, scheda; licenza MPL-2.0; player MPV |
| 2 | issue pubbliche: continue watching | https://github.com/streamyfin/streamyfin/issues?q=continue+watching | 80 risultati (issue + PR) |
| 3 | issue #2438 | https://github.com/streamyfin/streamyfin/issues/2438 | l'avanzamento non arriva al server quando la connessione torna |
| 4 | issue pubbliche: freeze | https://github.com/streamyfin/streamyfin/issues?q=freeze | 35 risultati |
| 5 | issue #2412 | https://github.com/streamyfin/streamyfin/issues/2412 | UI bloccata ~10 s su pausa/seek (Android TV) |
| 6 | issue pubbliche: slow loading / resume | https://github.com/streamyfin/streamyfin/issues?q=resume | 281 risultati, quasi tutti PR |
| 7 | API Jellyfin (OpenAPI generata) | https://github.com/jellyfin/jellyfin-sdk-swift | percorsi, parametri e nomi dei campi JSON delle API ufficiali |
| 8 | esperienza diretta dell'utente | il suo iPhone e il suo account | blocchi durante il film, "Continua a guardare" non aggiornato dopo la riapertura, apertura del film lentissima o fallita |

Non raggiunti (bloccati dalla rete della sessione): App Store, streamyfin.app,
jellyfin.org, Reddit. Il codice sorgente di Streamyfin non è stato letto, per
scelta (clean-room).

## Core loop

Apro l'app, vedo subito cosa stavo guardando, tocco e riparte dal secondo
esatto, senza blocchi.

## Pain points dell'utente e causa probabile

Ipotesi tecniche, da confermare durante build e test. Sono l'obiettivo numero
uno del clone.

| # | problema | causa probabile | come lo evitiamo |
| --- | --- | --- | --- |
| P1 | il film si blocca a metà | stallo di rete o buffer non recuperato dal player; il lavoro del player sul thread principale congela l'interfaccia (cfr. #2412) | AVPlayer nativo con HLS; un controllo che, se la riproduzione resta ferma oltre N secondi, ricarica il flusso dalla posizione corrente; niente lavoro pesante sul thread principale |
| P2 | chiudo e riapro, il film non è in "Continua a guardare" | l'avanzamento viene inviato solo alla chiusura del player; se l'app viene chiusa o sospesa quell'invio non parte o fallisce senza nuovi tentativi (cfr. #2438) | invio dell'avanzamento ogni 10 s, a ogni pausa e al passaggio in background; coda locale persistente con nuovi tentativi; la home si ricarica ogni volta che l'app torna in primo piano |
| P3 | aprire un film ci mette una vita, a volte non parte | richieste fatte una dopo l'altra; PlaybackInfo calcolato solo al tocco su Play; immagini troppo grandi | richieste in parallelo, cache in memoria e su disco, PlaybackInfo preparato già all'apertura della scheda, immagini ridimensionate dal server, timeout chiari con "Riprova" |
| P4 | piccoli bug | tracce audio e sottotitoli, prossimo episodio, stato non coerente | test automatici sulla logica (calcolo dei tick, profilo dispositivo, coda di sincronizzazione) e un piano di test manuale per ogni flusso |

## Screens

| ID | screen | route / how to reach | purpose | key components | states seen |
| --- | --- | --- | --- | --- | --- |
| S01 | Collega server | primo avvio | inserire l'URL del server, verifica con /System/Info/Public | campo URL, bottone Continua | vuoto, verifica in corso, errore (URL errato, server irraggiungibile) |
| S02 | Accesso | dopo S01 | utente e password, oppure Quick Connect | campi, bottone, codice Quick Connect | vuoto, caricamento, credenziali errate, in attesa del Quick Connect |
| S03 | Home | tab Home | ripartire subito: Continua a guardare, Prossimi episodi, Aggiunti di recente per libreria | grande banner in alto, file orizzontali di locandine con barra di avanzamento | caricamento (skeleton), pieno, vuoto (nulla da continuare), offline, errore |
| S04 | Librerie | tab Librerie | elenco delle librerie dell'utente (/UserViews) | griglia di riquadri | caricamento, pieno, errore |
| S05 | Contenuto libreria | S04 → libreria | sfogliare film o serie, ordinare | griglia di locandine, ordinamento, scorrimento infinito | caricamento, pieno, vuoto, errore, pagina successiva in caricamento |
| S06 | Scheda film | locandina di un film | trama, durata, anno, voto, Riproduci / Riprendi da hh:mm, segna come visto | sfondo, locandina, bottone Play, tracce audio e sottotitoli, cast | caricamento, pieno, errore |
| S07 | Scheda serie | locandina di una serie | stagioni ed episodi, "Prossimo episodio" | selettore di stagione, lista episodi con avanzamento | caricamento, pieno, stagione vuota, errore |
| S08 | Player | Play da S03, S06 o S07 | guardare | video a schermo intero, controlli, barra di scorrimento, ±10 s, audio e sottotitoli, salta intro (se il server lo fornisce), countdown al prossimo episodio, PiP | preparazione, buffering, in riproduzione, in pausa, errore di rete con nuovo tentativo, fine |
| S09 | Cerca | tab Cerca | trovare film, serie ed episodi | campo di ricerca, risultati raggruppati | vuoto, in digitazione, risultati, nessun risultato, errore |
| S10 | Impostazioni | tab Impostazioni | account, server, qualità massima di streaming, lingua predefinita di audio e sottotitoli, esci | liste e toggle | pieno |

## Flows

```
F01 Primo accesso
    S01 URL -> S02 utente/password -> S03 Home
    happy path clicks: 3 (Continua, campi, Accedi)
    edge: URL senza http(s)://, porta mancante, certificato non valido,
          server lento, password errata, Quick Connect disattivato sul server

F02 Riprendere un film (il core loop)
    S03 "Continua a guardare" -> S08 riparte dal punto salvato
    happy path clicks: 1 (tocco sulla locandina = riprendi subito)
    edge: file non riproducibile direttamente (transcodifica), rete che cade,
          posizione quasi alla fine (si considera visto), app uccisa a metà film

F03 Guardare un film nuovo
    S04 -> S05 -> S06 -> S08
    happy path clicks: 3
    edge: libreria enorme (paginazione), immagine mancante, film senza file

F04 Guardare il prossimo episodio di una serie
    S03 "Prossimi episodi" -> S08 -> countdown -> episodio successivo in S08
    happy path clicks: 1
    edge: ultimo episodio della stagione o della serie, episodi mancanti

F05 Chiudo l'app a metà film e la riapro
    S08 -> app in background o chiusa -> riapro -> S03 mostra il film con la nuova posizione
    happy path clicks: 0 (deve funzionare da solo)
    edge: nessuna rete in quel momento (invio ritentato più tardi), app chiusa
          dal multitasking

F06 Cercare un titolo
    S09 digita -> risultato -> S06/S07 -> S08
    happy path clicks: 3
    edge: nessun risultato, caratteri accentati

F07 Cambiare audio o sottotitoli durante la visione
    S08 -> menu tracce -> scelta
    happy path clicks: 2
    edge: sottotitoli che il player non sa mostrare (PGS: inseriti nel video dal server)
```

## Components

| component | variants | states | used on |
| --- | --- | --- | --- |
| Locandina | verticale (film/serie), orizzontale (episodio, continua) | caricamento, immagine mancante, con barra di avanzamento, con spunta "visto" | S03, S05, S07, S09 |
| Fila orizzontale | con titolo, con "vedi tutto" | caricamento (skeleton), vuota (nascosta) | S03 |
| Banner in evidenza | — | caricamento, pieno | S03 |
| Bottone Play | Riproduci, Riprendi da hh:mm | normale, in preparazione, disabilitato | S06, S07 |
| Lista episodi | — | visto, in corso, non visto | S07 |
| Selettore tracce | audio, sottotitoli | selezionata | S06, S08 |
| Controlli del player | — | visibili, nascosti, buffering | S08 |
| Messaggio di errore | a tutta pagina, banner | con "Riprova" | tutte |
| Barra delle tab | Home, Librerie, Cerca, Impostazioni | selezionata | app |

## Inferred data model

Il modello lo definisce il server Jellyfin: le sue API sono pubbliche e
documentate (fonte 7). Lato app servono solo questi oggetti.

```
ServerAccount  url, serverId, serverName, userId, userName, accessToken, deviceId
               evidence: /System/Info/Public, /Users/AuthenticateByName -> AccessToken, ServerId, User
               confidence: high (API documentata). Il token va nel Keychain.

Item (BaseItemDto)  Id, Name, Type (Movie|Series|Season|Episode|CollectionFolder),
               Overview, ProductionYear, RunTimeTicks, CommunityRating, OfficialRating,
               ImageTags, BackdropImageTags, SeriesId, SeriesName, SeasonId,
               IndexNumber, ParentIndexNumber, UserData, MediaStreams
               evidence: /Items, /Items/{id}, /UserItems/Resume, /Shows/NextUp
               confidence: high

UserData       PlaybackPositionTicks, PlayedPercentage, Played, IsFavorite, LastPlayedDate
               evidence: UserItemDataDto
               confidence: high. 1 secondo = 10.000.000 tick.

PlaybackSession  itemId, mediaSourceId, playSessionId, playMethod
               (DirectPlay|DirectStream|Transcode), streamURL, audioIndex, subtitleIndex
               evidence: POST /Items/{id}/PlaybackInfo -> MediaSources, PlaySessionId, TranscodingUrl
               confidence: high

PendingProgress (locale)  itemId, positionTicks, playSessionId, mediaSourceId,
               isPaused, isStopped, createdAt
               evidence: necessaria per il problema P2; non esiste lato server
               confidence: design nostro
```

Relationships: ServerAccount 1-n Item (visti attraverso l'utente);
Series 1-n Season 1-n Episode; Item 1-1 UserData (per utente);
PlaybackSession -> PendingProgress (n invii, in coda finché il server non conferma).

## Feature matrix

See `features.csv`. Must: 20, should: 10, could: 6, skip: 5.

## Out of scope (cannot or should not be cloned)

- Il catalogo: film e serie appartengono al server a cui l'utente ha accesso.
  L'app li mostra soltanto.
- Il plugin server di Streamyfin e le impostazioni sincronizzate tra utenti.
- L'integrazione con Seerr (richieste di nuovi contenuti): servizio esterno, non nel nucleo.
- Vista delle sessioni del server: funzione da amministratore.
- Musica: esclusa anche in Streamyfin.
- Nome, icona e testi di Streamyfin: il clone ha nome e aspetto propri.

## Size

Screens 10, flows 7, entities 5. Hard parts:
1. Player affidabile: scegliere tra riproduzione diretta, remux e transcodifica
   con il profilo dispositivo giusto, recuperare dagli stalli.
2. Sincronizzazione dell'avanzamento che regge chiusura dell'app e assenza di rete.
3. Compilare e verificare senza Mac: ogni build passa da GitHub Actions,
   quindi i test automatici della logica devono girare anche lì.

Size: M (qualche settimana di lavoro in sessioni brevi) per il nucleo
essenziale. Download offline e Chromecast sono un secondo progetto.
