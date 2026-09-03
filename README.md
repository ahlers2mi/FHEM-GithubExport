# FHEM-GithubExport

`98_GithubExport.pm` sichert die FHEM-Konfiguration in ein GitHub-Repository —
aus FHEM heraus, über die GitHub-API mit einem Zugriffs-Token.

Es braucht **kein installiertes git**, **keinen lokalen Klon** und kein
Shell-Skript. Der ganze Lauf steckt in einem `BlockingCall`, FHEM blockiert
also nicht.

```
define myExport GithubExport ahlers2mi/FHEM-Instanz Main
set myExport token ghp_…
set myExport export cfg state modules log filelog:bewaesserung
```

## Was gesichert wird, gibt man mit

| Teil | Inhalt | Ziel im Repository |
|---|---|---|
| `cfg` | `fhem.cfg` | `<Ordner>/fhem.cfg` |
| `state` | `fhem.save` (Pfad aus `attr global statefile`) | `<Ordner>/fhem.save` |
| `modules` | eigene Module, Default `99_*.pm` | `<Ordner>/FHEM/…` |
| `log` | die letzten Zeilen des laufenden Logs + auffällige Zeilen aus allen Logs | `<Ordner>/log/fhem-tail.log`, `fhem-fehler.log` |
| `freeze` | neuestes Freezemon-Protokoll | `<Ordner>/log/fhem-freeze.log` |
| `filelog` | FileLog-Auszüge, gefiltert und gedeckelt | `<Ordner>/log/<gerät>-auszug.log` |
| `extra` | die Pfade aus `attr extraFiles` | frei wählbar |
| `all` | alles davon | |

Ein vorangestelltes `-` wählt ab: `set myExport export all -state`.
Ohne Angabe gilt `attr exportParts` (Default `cfg state modules log freeze`).

## Wie es arbeitet

Alle Dateien eines Laufs landen in **einem** Commit über die Git-Data-API
(Blobs → Baum → Commit → Ref). Unveränderte Dateien werden **gar nicht erst
hochgeladen**: das Modul rechnet die Blob-SHA jeder Datei selbst aus — dieselbe,
die git vergeben würde — und vergleicht sie mit dem Baum im Repository. Ändert
sich nichts, entsteht auch kein Commit.

Das ist der wesentliche Unterschied zum bisherigen `fhem-backup.sh`: dort musste
ein Klon auf dem FHEM-Rechner liegen, gepullt und gepusht werden. Hier gibt es
weder Klon noch Merge-Konflikt.

## Warum ein eigener HTTP-Client

Das Modul spricht nicht über FHEMs `HttpUtils` mit GitHub, sondern über einen
eigenen kleinen Client. Der Grund ist gemessen, nicht theoretisch: `HttpUtils`
schreibt im blockierenden Zweig den Rumpf mit **einem** `syswrite`, ohne
Schleife und ohne den Rückgabewert anzusehen — und `IO::Socket::SSL` liefert
auch auf einem **blockierenden** Socket nur ein TLS-Record (16384 Bytes) je
Aufruf zurück. Nachgestellt mit einem lokalen TLS-Server und der Größe einer
echten `fhem.cfg`:

```
gewollt 1823437, syswrite lieferte 16384, empfangen 16384
```

GitHub bekam also 16 kB von 1,8 MB angekündigten, wartete auf den Rest und
antwortete nach 25 Sekunden mit `400 We received a malformed request from your
client`. Die GET-Aufrufe liefen die ganze Zeit — sie haben keinen Rumpf; genau
deshalb sah es zuerst nach einem Problem der Blob-Schnittstelle aus.

`GithubExport_Request` schreibt in einer Schleife, bis alles draußen ist (6,4 MB
gehen in rund 390 Runden raus). Zwei Folgen: `attr global proxy` wirkt hier
**nicht**, und das Zertifikat der Gegenstelle wird immer geprüft.

`t/run.pl` schickt dafür 1,8 MB durch einen echten TLS-Server und zählt nach,
was ankommt. Mit einem einzelnen `syswrite` statt der Schleife meldet der Test
`16276 von 1823437`.

## Token

```
set myExport token ghp_…
```

Der Token wird über `setKeyValue` abgelegt, steht also **nicht** in der
`fhem.cfg`. Nötige Rechte:

* Fine-grained Token: für das Repository **Contents: Read and write**
* klassischer Token: Bereich `repo`

`get myExport token` sagt, ob einer hinterlegt ist, ohne ihn auszugeben. In
keiner Fehlermeldung und in keinem Reading taucht er auf.

## Zwei Sicherungen gegen Unfall

* **`allowPublicRepo`** (Default 0): das Modul fragt vor jedem Push die
  Sichtbarkeit des Repositorys ab und verweigert, wenn es öffentlich ist.
  `fhem.cfg` und `fhem.save` enthalten Zugangsdaten im Klartext.
* **`sanitize`** (Default 1): in den Log-Auszügen werden Telegram- und
  GitHub-Token, `?token=`/`?password=`-Parameter und `benutzer:passwort@` in
  URLs ersetzt. Das betrifft nur die Log-Auszüge — `fhem.cfg` und `fhem.save`
  gehen unverändert ins Repository, deshalb der Punkt darüber.

## Probelauf

```
set myExport dryRun all
```

Sammelt alles ein und fragt das Repository ab, überträgt aber nichts. Damit
lässt sich prüfen, ob Token, Rechte und Branch stimmen; Reading `preview` zeigt
die Dateien mit Größe, `*` markiert, was ein echter Export übertragen würde.

## Zeitplan

`attr myExport interval 25` läuft alle 25 Minuten (Reading `nextRun`).
Ein `at` tut es genauso: `define a_export at +*00:25:00 set myExport export`.

Vor dem Export läuft standardmäßig ein FHEM-`save` (`saveBeforeExport`, Default
1). Mit `attr global autosave 0` schreibt FHEM von sich aus weder `fhem.cfg`
noch `fhem.save` — ohne `save` sichert man den Stand vom letzten Mal.

## Wenn etwas nicht im Repository ankommt

Zuerst ins Reading **`lastWarning`** schauen. Ein Lauf ist auch dann `ok`, wenn
einzelne Quellen gefehlt haben, zu groß waren oder sich nicht lesen ließen —
das steht dann dort und nirgends sonst.

## Installation

```
update add https://raw.githubusercontent.com/ahlers2mi/FHEM-GithubExport/refs/heads/main/controls_GithubExport.txt
update all
```

Das setzt voraus, dass **dieses** Repository öffentlich ist (das gesicherte darf
und soll privat sein). Bei einem privaten Repo liefert
`raw.githubusercontent.com` nichts, und `update` meldet still „nothing to do“.

Nach einem Merge fünf Minuten warten: `raw.githubusercontent.com` liefert mit
`cache-control: max-age=300`, bis dahin kommt die vorherige `controls_*.txt`.

## Tests

Laufen ohne FHEM-Installation und ohne echtes GitHub — `t/FhemStub.pm` enthält
ein kleines Nach-GitHub, das jeden API-Aufruf mitschreibt.

```
perl -c FHEM/98_GithubExport.pm
perl t/run.pl
python3 t/cref.py
```

Geprüft wird unter anderem, dass unveränderte Dateien keinen Blob und keinen
Commit erzeugen, dass in ein öffentliches Repository nichts gepusht wird und
dass in keiner Fehlermeldung der Token steht. Die Tests sind gegen mutierte
Fassungen gegengeprüft — ein Test, der nicht rot werden kann, ist wertlos.
