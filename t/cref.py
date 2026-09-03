#!/usr/bin/env python3
"""Haelt Code und commandref gegeneinander - statisch, ohne FHEM.

Geprueft wird:
  1. jeder set-/get-Befehl aus der Auswahlliste steht auch in der commandref
  2. jedes Attribut aus AttrList steht in der commandref
  3. jeder davon hat einen Anker <a id="GithubExport-<set|get|attr>-<name>">.
     Daran haengt die Hilfe, die FHEMWEB einblendet, sobald man im Klappmenue
     etwas auswaehlt: fhemweb.js holt per "help <Modul>" die commandref, sucht
     genau diese id und zeigt das umgebende <li>. Fehlt der Anker, bleibt die
     Hilfe einfach leer - ohne Fehlermeldung, man merkt es nur, wenn man
     hinschaut.
  4. der erste Anker der commandref ist das Modul selbst. fhemweb.js liest
     ihn als "mtype" und baut daraus die gesuchte id; steht dort etwas
     anderes, findet es keinen einzigen Eintrag mehr.
  5. der Rueckfallwert von GithubExport_Version() passt zum obersten Eintrag
     der Aenderungsliste (die Version wird von dort gelesen; faellt die Datei
     mal aus, greift der Rueckfall - und der war in einem Nachbarmodul
     zweimal veraltet)

Aufruf:  python3 t/cref.py
"""
import re
import sys
from pathlib import Path

QUELLE = Path(__file__).resolve().parent.parent / "FHEM" / "98_GithubExport.pm"
text = QUELLE.read_text(encoding="utf-8", errors="replace")
cref = text[text.index("=begin html"):]
fehler = []

# --- 4. erster Anker = Modulname ----------------------------------------------
erster = re.search(r'<a id="([^"]+)"', cref)
if not erster:
    fehler.append("commandref hat keinen <a id=...>-Anker")
elif erster.group(1) != "GithubExport":
    fehler.append("erster Anker ist '%s', muss 'GithubExport' sein (fhemweb.js "
                  "liest ihn als mtype)" % erster.group(1))

# --- 1./3. set / get -------------------------------------------------------
for art in ("Set", "Get"):
    m = re.search(r'sub GithubExport_%s \{.*?my \$list = "([^"]+)"' % art, text, re.S)
    if not m:
        fehler.append("Auswahlliste fuer %s nicht gefunden" % art)
        continue

    for eintrag in m.group(1).split():
        befehl = eintrag.split(":")[0]
        if not re.search(r"<b>%s\b" % re.escape(befehl), cref):
            fehler.append("%s-Befehl '%s' fehlt in der commandref" % (art.lower(), befehl))
        anker = 'id="GithubExport-%s-%s"' % (art.lower(), befehl)
        if anker not in cref:
            fehler.append("%s-Befehl '%s' hat keinen Hilfe-Anker (%s)"
                          % (art.lower(), befehl, anker))

# --- 2. Attribute -------------------------------------------------------------
m = re.search(r"\$hash->\{AttrList\} = join\(\" \",(.*?)\$readingFnAttributes\);", text, re.S)
if not m:
    fehler.append("AttrList nicht gefunden")
else:
    for a in re.findall(r'"([A-Za-z][A-Za-z0-9]*)(?::[^"]*)?"', m.group(1)):
        if not re.search(r"<b>%s</b>" % re.escape(a), cref):
            fehler.append("Attribut '%s' fehlt in der commandref" % a)
        anker = 'id="GithubExport-attr-%s"' % a
        if anker not in cref:
            fehler.append("Attribut '%s' hat keinen Hilfe-Anker (%s)" % (a, anker))

# --- 5. Version ---------------------------------------------------------------
oben = re.search(r"^# (\d+\.\d+\.\d+) - \d{4}-\d{2}-\d{2}", text, re.M)
rueck = re.search(r'my \$FALLBACK = "([\d.]+)"', text)
if not oben or not rueck:
    fehler.append("Version oder Rueckfallwert nicht gefunden")
elif oben.group(1) != rueck.group(1):
    fehler.append("Rueckfallwert %s passt nicht zur Aenderungsliste %s"
                  % (rueck.group(1), oben.group(1)))

for f in fehler:
    print("FEHL " + f)
print("%d Befund(e)" % len(fehler))
sys.exit(1 if fehler else 0)
