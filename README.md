# Backup Unite

App personale per unire due backup JW Library schema 16. Esiste in due forme:

- **App web** (questa cartella `docs/`): funziona nel browser, unisce i file in locale e può essere pubblicata su GitHub Pages.
- **App iOS** (progetto Xcode): stesso flusso su iPhone.

Il motore ricostruisce note, evidenziazioni, intervalli, segnalibri, tag, campi di testo, playlist, ordine, marker, media e miniature; rimappa gli ID e valida SQLite, chiavi esterne, hash del database e file collegati prima dell’esportazione.

Come in Library Merger, prima di creare il file vengono individuate le collisioni di note, evidenziazioni, segnalibri e campi compilati. Per ogni collisione puoi scegliere il primo o il secondo backup. Per le note è disponibile anche **Conserva entrambe**.

Prima dell’analisi puoi decidere quali sottolineature usare: **Entrambi**, **1° backup** o **2° backup**.

I backup restano sul dispositivo: l’app web non li invia a un server. Nel browser vengono conservati in IndexedDB; su iPhone nell’archivio dell’app.

## App web

Apri `docs/index.html` da un server locale (non da `file://`, perché il motore SQLite e il worker lo richiedono):

```bash
python3 -m http.server 8080 --directory docs
```

Poi vai su [http://localhost:8080](http://localhost:8080). Scegli due file `.jwlibrary`, tocca **Analizza conflitti**, decidi cosa conservare e scarica il backup verificato.

La pubblicazione su GitHub Pages usa la cartella `docs/` e il workflow in `.github/workflows/pages.yml`.

## App iOS

Aprire `BackupUnite.xcodeproj`, selezionare il proprio iPhone e premere Run. Il progetto richiede iOS 17 o successivo e usa ZIPFoundation 0.9.20, CryptoKit e SQLite di sistema.
