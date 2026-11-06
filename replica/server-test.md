# Test sul server reale

Data: 2026-11-06. Server: Jellyfin 12.2.0 dietro Cloudflare. Account dell'utente
(non amministratore). Le richieste sono le stesse dell'app, fatte con uno
script. Credenziali e token non sono salvati nel progetto.

## Risultati

| prova | risultato |
| --- | --- |
| /System/Info/Public | ok, 0,7 s |
| login (AuthenticateByName) | ok, 1,1 s |
| criteri dell'utente | riproduzione, remux e transcodifica consentiti; nessun limite di bitrate; 4 sessioni |
| Continua a guardare (/UserItems/Resume) | ok, 30 titoli, 1,2 s |
| Prossimi episodi (/Shows/NextUp) | ok, 1,2 s |
| librerie (/UserViews) | 19 librerie (Film 28k, Serie TV 171k episodi, Anime 46k…) |
| latenza per richiesta | **~0,5–1,2 s anche per risposte minime**: le richieste vanno fatte in parallelo, mai una dopo l'altra |
| /Items con `fields=MediaSources` su 25 titoli | **4,5 s**: le griglie non devono chiedere MediaSources |
| PlaybackInfo con il profilo Apple | ok, 0,5–0,8 s; per gli MKV propone HLS (motivo: ContainerNotSupported) |
| flusso diretto (static=true) | 206 con Range in 1–2 s; salto a metà file in 2–3 s |
| velocità di invio del server | 66–90 Mbit/s |
| Cloudflare | blocca lo user agent di Python; accetta quelli di VLC, AVPlayer, URLSession e uno vuoto |
| avanzamento dal vivo (Playing/Progress, senza Stopped) | ok: il titolo è primo in Continua a guardare con la posizione giusta |
| POST /UserItems/{id}/UserData | **403 "User is not allowed to update this item user data"** (anche il percorso vecchio e anche il GET) |
| solo /Sessions/Playing/Stopped con sessione nuova | ok: aggiorna la posizione e Continua a guardare |

## Campione di 100 file (Film, Film 4K, Serie TV, Anime)

- Contenitori: mkv 88, mp4 9, avi 2, mov 1 → **90 su 100 vanno a VLC**, 10 al player Apple.
- Video: hevc SDR 39, h264 37, hevc HDR10 11, Dolby Vision 8, HDR10+ 1, mpeg4 2, av1 1.
- Audio: ac3 76, eac3 41, aac 41, **dts 34**, mp3 6, flac 4, truehd 2.
- Sottotitoli: subrip 119, **PGS 64**, ass 43, dvdsub 3.
- Bitrate: fino a **68 Mbit/s** nei 4K.

## Cosa cambia nell'app

1. **Coda offline**: le posizioni rimaste si reinviano come "Stopped" (provato), non
   più con UserData (vietato su questo server). Fatto.
2. **Velocità**: niente catene di richieste; griglie con pochi campi; PlaybackInfo
   preparato all'apertura della scheda.
3. **Blocchi sui 4K**: un file da 68 Mbit/s si blocca su qualsiasi app se la rete
   del telefono è più lenta. Serve un'opzione di qualità con transcodifica
   automatica quando la rete non basta (il server la consente).
4. **HDR e Dolby Vision in MKV**: VLC 3 li mostra senza HDR vero. Alternativa da
   valutare: remux del server in HLS (copia senza ricodifica) verso il player Apple.

## Apertura di un titolo nuovo (2026-11-06)

Misurato a passaggi in sequenza su 6 MKV mai visti: PlaybackInfo 0,5 s, inizio
file 1-1,5 s, indice in fondo al file ~2,4 s, primo buffer ~1 s → **3-5,6 s**.
HLS del server (riserva): master + playlist + init + primo segmento ≈ **3,5 s**.
`mediaSourceId` coincide con l'id del titolo in 100 file su 100.

Cambi nell'app:
- dopo 15 s senza immagine si passa da solo al modo successivo (prima 30 s);
  dopo 6 s compare "Il server ci sta mettendo un po'…": mai schermo nero muto;
- VLC con 1,5 s di buffer iniziale invece di 3 s, e riconnessione HTTP automatica;
- il riquadro del player mostra il tempo di apertura (es. "VLC · 4,2 s").
