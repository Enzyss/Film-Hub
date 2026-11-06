# Build log

Stile: tema scuro leggero (`ios/App/Support/Theme.swift`), senza un passaggio
completo di replica-design, come concordato con l'utente.

Verifica: non c'è un Mac. Ogni push compila su GitHub Actions (test di
JellyCore, poi archivio dell'app). Gli screenshot per replica-diff si potranno
fare solo dall'iPhone dell'utente.

| ID | data | stato | cosa manca | più difficile del previsto |
| --- | --- | --- | --- | --- |
| S01 Collega server | 2026-11-06 | done | — | indirizzo senza schema: si provano https e http, l'ordine dipende da IP/porta |
| S02 Accesso | 2026-11-06 | partial | Quick Connect | — |
| S03 Home | 2026-11-06 | partial | aggiunti di recente, banner in evidenza, schede (tocco = riproduci subito) | — |
| S04 Librerie | — | stub | tutto | — |
| S05 Contenuto libreria | — | todo | tutto | — |
| S06 Scheda film | — | todo | tutto | — |
| S07 Scheda serie | — | todo | tutto | — |
| S08 Player | 2026-11-06 | partial | tracce audio/sottotitoli, prossimo episodio, PiP, salta intro | due motori con un'unica logica: lo stato si legge a intervalli invece che dai callback, per evitare differenze tra Apple e VLC |
| S09 Cerca | — | stub | tutto | — |
| S10 Impostazioni | 2026-11-06 | partial | qualità, lingue | — |

Note:
- Jellyfin non mette un titolo in "Continua a guardare" se è stato visto meno
  del 5% o se dura meno di 5 minuti (impostazioni predefinite del server). Non
  è un bug dell'app: va detto all'utente.
- Il percorso dell'avanzamento è: disco → server. Se l'app viene chiusa dal
  multitasking si perdono al massimo 10 secondi.
- 2026-11-06: prima build su GitHub Actions riuscita (run 1): 23 test di
  JellyCore verdi, MobileVLCKit 3.7.5 collegato, IPA da 16 MB.
