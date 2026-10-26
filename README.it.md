# t2-suspend-fix

**Sospensione affidabile e risveglio veloce per i Mac con chip Apple T2 su Linux.**

[English](README.md)

Sui Mac con chip T2 (2018–2020) la sospensione spesso manda in crisi il
sistema: al risveglio smettono di funzionare tastiera, trackpad, Touch Bar,
Wi-Fi o Bluetooth, il sistema può bloccarsi, e molti finiscono per
disattivare del tutto la sospensione. `t2-suspend-fix` è un piccolo hook di
`systemd-sleep` che interviene sulle cause reali, più uno strumento di
diagnostica per vedere cosa succede sul proprio Mac.

## Problemi risolti

- Tastiera, trackpad, Touch Bar e audio morti al risveglio, o sistema che si
  blocca dopo qualche tentativo di sospensione
- Wi-Fi e Bluetooth che non funzionano dopo il risveglio
- Risveglio che richiede più di 10 secondi
- Touch Bar spenta dopo il risveglio, o che mostra per un attimo i tasti di
  base prima che parta `tiny-dfr`
- Schermo che resta nero all'apertura del coperchio finché non si preme un
  tasto (GNOME)
- Retroilluminazione della tastiera spenta e
  [wluma](https://github.com/max-baz/wluma) che smette di funzionare dopo il
  risveglio

## Perché succede

Queste sono le cause trovate analizzando i log del kernel di un
MacBookPro15,4. Il chip T2 si è rivelato *non* essere il colpevole: il suo
driver lo sospende e lo risveglia correttamente.

| Problema | Causa |
|---|---|
| Dispositivi del T2 morti, sistema bloccato | Il driver Wi-Fi Broadcom (`brcmfmac`) fallisce la sospensione (`pci_pm_suspend returns -5`): la sospensione viene annullata e ritentata ogni pochi secondi. Dopo qualche decina di tentativi annullati il T2 smette di rispondere (`t2bce_dma: command queue timeout`). |
| Wi-Fi / Bluetooth spariti | Wi-Fi e Bluetooth sono due funzioni dello stesso chip Broadcom: gestirne solo una lascia l'altra in uno stato rotto. |
| Risveglio di ~12 s | Il bridge e il controller Thunderbolt 3 di Intel impiegano ~10,5 s a risvegliarsi, anche senza nulla collegato. |
| Touch Bar spenta o che lampeggia | Al risveglio il T2 ricollega la Touch Bar: systemd ferma `tiny-dfr` (`BindsTo=`) e non lo riavvia, mentre il driver della retroilluminazione la accende a piena luminosità con i tasti di base. |
| Schermo nero all'apertura del coperchio | Da systemd 256 le sessioni utente vengono congelate durante la sospensione e GNOME perde l'evento di apertura del coperchio. |

## Cosa fa

Prima della sospensione (`pre`):

1. Scarica i driver Broadcom di Bluetooth e Wi-Fi (rilevati automaticamente).
2. Se alle porte USB-C non è collegato nulla, rimuove dal bus il ramo PCI del
   Thunderbolt (rilevato automaticamente, supporta più controller).
3. Scarica il driver della retroilluminazione della Touch Bar (solo se
   `tiny-dfr` è in esecuzione).

Al risveglio (`post`, il più breve possibile):

1. Riscopre il ramo Thunderbolt (~50 ms).
2. Ricarica il driver della retroilluminazione della Touch Bar con
   `brightness=0` e riavvia `tiny-dfr` appena i suoi dispositivi sono pronti.

Poi, in background:

1. Ricarica Wi-Fi e Bluetooth.
2. Ripristina la retroilluminazione della tastiera e riavvia servizi utente
   come `wluma`.

Installa anche due file di configurazione per systemd: solo sospensione S3
(`deep`), e sessioni utente non congelate durante la sospensione.

Il driver del T2 (`apple-bce` / `t2bce`) **non** viene scaricato: le versioni
recenti salvano e ripristinano lo stato del T2 da sole, ed era proprio
scaricarlo a creare problemi.

Misure su un MacBookPro15,4:

| | Prima | Dopo |
|---|---|---|
| Risveglio dei dispositivi nel kernel | ~11 s | ~1 s |
| Apertura coperchio → schermo acceso | ~12 s | ~2–3 s |
| Funzionante al risveglio | incostante | tastiera, trackpad, Touch Bar, audio, webcam, Wi-Fi, Bluetooth, USB-C |

## Compatibilità

**Testato su:** MacBookPro15,4 (13" 2019, due porte Thunderbolt), Ubuntu
26.04, kernel 7.2 (t2linux, driver `t2bce`), systemd 259, GNOME.

**Dovrebbe funzionare** su tutti i Mac T2, perché tutto viene rilevato
automaticamente invece di essere scritto a mano: MacBookPro15,x e 16,x,
MacBookAir8,x e 9,1, Macmini8,1, iMac20,x, iMacPro1,1, MacPro7,1. Questi
modelli non sono ancora stati provati: [segnala](#segnalare-problemi) come
funziona sul tuo.

Dopo l'installazione esegui `sudo t2-suspend-diag` per vedere cosa viene
rilevato sul tuo Mac. I passaggi che non servono (niente Touch Bar, niente
bridge Thunderbolt, Thunderbolt integrato nella CPU, Bluetooth su UART, ...)
vengono saltati.

**Requisiti**

- Un kernel Linux con supporto T2, vedi [t2linux](https://wiki.t2linux.org)
- systemd (consigliato 256 o successivo)
- Facoltativo: [tiny-dfr](https://github.com/AsahiLinux/tiny-dfr) per la
  Touch Bar

## Installazione

```bash
git clone https://github.com/cairolidavide/t2-suspend-fix.git
cd t2-suspend-fix
sudo ./install.sh
```

Opzioni:

| Opzione | Effetto |
|---|---|
| `--lid` | Sospende alla chiusura del coperchio (aggiunge un file in `logind.conf.d`; con un monitor esterno collegato il coperchio viene ignorato) |
| `--bluetooth-autoenable` | Accende il Bluetooth all'avvio (`AutoEnable=true` in `/etc/bluetooth/main.conf`) |
| `--force` | Installa anche se non viene rilevato un chip T2 |

L'installer salva una copia di ogni file che sostituisce in
`/var/lib/t2-suspend-fix/`, riattiva `sleep.target` e `suspend.target` se li
avevi disattivati (mask), e avvisa se ci sono altri hook di sospensione che
toccano gli stessi driver. Se in passato hai seguito guide che scaricano
`apple-bce` o `brcmfmac` prima della sospensione, rimuovi quegli hook:
entrano in conflitto con questo.

Poi provalo:

```bash
systemctl suspend          # risveglia con un tasto o aprendo il coperchio
sudo t2-suspend-diag       # controlla cosa è successo
```

### File installati

| File | Funzione |
|---|---|
| `/usr/lib/systemd/system-sleep/t2-suspend-fix` | L'hook di sospensione |
| `/etc/t2-suspend-fix.conf` | Impostazioni |
| `/usr/local/bin/t2-suspend-diag` | Strumento di diagnostica |
| `/etc/systemd/sleep.conf.d/t2-suspend-fix.conf` | `MemorySleepMode=deep` |
| `/etc/systemd/system/systemd-suspend.service.d/t2-suspend-fix.conf` | Non congelare le sessioni utente |
| `/etc/systemd/logind.conf.d/t2-suspend-fix-lid.conf` | Coperchio → sospensione (solo con `--lid`) |

Non c'è niente da abilitare: `systemd-sleep` esegue l'hook a ogni
sospensione, e tutto resta attivo dopo riavvii e aggiornamenti.

## Configurazione

Modifica `/etc/t2-suspend-fix.conf`; le modifiche valgono dalla sospensione
successiva.

| Impostazione | Predefinito | Significato |
|---|---|---|
| `RELOAD_WIFI_BT` | `yes` | Scarica e ricarica i driver Broadcom di Wi-Fi e Bluetooth |
| `FAST_THUNDERBOLT_RESUME` | `auto` | Rimuove e riscopre il ramo Thunderbolt se le porte USB-C non sono in uso (`no` per disattivare) |
| `TOUCHBAR_FIX` | `auto` | Tiene spenta la Touch Bar finché `tiny-dfr` non è pronto (`no` per disattivare) |
| `RESTORE_KBD_BACKLIGHT` | `yes` | Ripristina la luminosità della tastiera |
| `RESTART_USER_SERVICES` | `wluma.service` | Servizi utente da riavviare dopo il risveglio, se attivi |

## Diagnostica

```bash
sudo t2-suspend-diag              # report del sistema e ultimo ciclo di sospensione
sudo t2-suspend-diag --trace      # misura ogni dispositivo durante il ciclo successivo
sudo t2-suspend-diag --slowest    # dopo la sospensione: i dispositivi più lenti
journalctl -b -t t2-suspend-fix   # il registro dell'hook
```

`--trace` attiva `pm_print_times` del kernel fino al prossimo riavvio. È così
che è stato trovato il ritardo del Thunderbolt:

```
pcieport 0000:03:00.0: PM: pci_pm_resume_noirq returned 0 after 7214919 usecs
thunderbolt 0000:05:00.0: PM: pci_pm_resume_noirq returned 0 after 3369536 usecs
```

## Risoluzione dei problemi

**Il risveglio è ancora lento (~12 s).** C'era qualcosa collegato a una porta
USB-C (disco, hub, adattatore, monitor esterno), quindi il ramo Thunderbolt è
stato lasciato al suo posto per non scollegarlo. Nel registro trovi
`USB-C in use ..., keeping Thunderbolt (slow resume)`.

**Wi-Fi o Bluetooth assenti dopo il risveglio.** Cerca errori con
`journalctl -b -t t2-suspend-fix`. Per riattivarli senza riavviare:
`sudo modprobe brcmfmac; sudo modprobe hci_bcm4377`.

**Porte USB-C non funzionanti dopo il risveglio.** Riscopri il bus PCI con
`echo 1 | sudo tee /sys/bus/pci/rescan` e apri una segnalazione con l'output
di `sudo t2-suspend-diag`.

**Schermo nero all'apertura del coperchio.** Controlla che esista
`/etc/systemd/system/systemd-suspend.service.d/t2-suspend-fix.conf` ed esegui
`sudo systemctl daemon-reload`.

**Bluetooth spento a ogni avvio.** Installa con `--bluetooth-autoenable`. Se
resta spento, systemd-rfkill potrebbe averlo salvato come bloccato: esegui una
volta `rfkill unblock bluetooth`.

**La sospensione non avviene proprio.** Controlla che `sleep.target` e
`suspend.target` non siano disattivati:
`systemctl is-enabled suspend.target`.

## Limiti noti

- Al risveglio la Touch Bar si accende circa mezzo secondo dopo lo schermo:
  `tiny-dfr` deve ripartire da zero perché il T2 ricrea il dispositivo, e gli
  servono ~0,4–0,6 s per caricare font e icone.
- Circa 1 s del tempo di risveglio rimasto è speso dal kernel per
  risincronizzare le variabili EFI (`efivarfs: resyncing variable state`), che
  sul firmware T2 è lento. Non si evita smontando efivarfs, perché gli
  ambienti isolati delle app snap ne mantengono una copia montata.
- Con un dispositivo USB-C collegato il risveglio resta lento (vedi sopra).
- L'ibernazione non è stata testata.

## Disinstallazione

```bash
sudo ./uninstall.sh
```

Rimuove tutti i file installati e ripristina l'impostazione `AutoEnable` del
Bluetooth. Il tuo `/etc/t2-suspend-fix.conf` e le copie di backup in
`/var/lib/t2-suspend-fix/` vengono mantenuti; lo script ti dice come
cancellarli.

## Segnalare problemi

Apri una issue indicando:

- l'output di `sudo t2-suspend-diag`
- cosa non funziona dopo il risveglio
- se il risveglio è lento: l'output di `sudo t2-suspend-diag --slowest` dopo
  un ciclo tracciato

Sono benvenute anche le segnalazioni di funzionamento su modelli diversi dal
MacBookPro15,4.

## Ringraziamenti

- La community [t2linux](https://t2linux.org) per i driver del kernel che
  permettono di usare Linux sui Mac T2
- [tiny-dfr](https://github.com/AsahiLinux/tiny-dfr) per il demone della Touch
  Bar

## Licenza

[MIT](LICENSE)
