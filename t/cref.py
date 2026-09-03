#!/usr/bin/env python3
"""Haelt Code und commandref gegeneinander - statisch, ohne FHEM.

Geprueft wird:
  1. jeder set-/get-Befehl aus der Auswahlliste steht auch in der commandref
  2. jedes Attribut aus AttrList steht in der commandref
  3. der Rueckfallwert von GithubExport_Version() passt zum obersten Eintrag
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

# --- 1. set / get -------------------------------------------------------------
for art in ("Set", "Get"):
    m = re.search(r'sub GithubExport_%s \{.*?my \$list = "([^"]+)"' % art, text, re.S)
    if not m:
        fehler.append("Auswahlliste fuer %s nicht gefunden" % art)
        continue
    for eintrag in m.group(1).split():
        befehl = eintrag.split(":")[0]
        if not re.search(r"<b>%s\b" % re.escape(befehl), cref):
            fehler.append("%s-Befehl '%s' fehlt in der commandref" % (art.lower(), befehl))

# --- 2. Attribute -------------------------------------------------------------
m = re.search(r"\$hash->\{AttrList\} = join\(\" \",(.*?)\$readingFnAttributes\);", text, re.S)
if not m:
    fehler.append("AttrList nicht gefunden")
else:
    for a in re.findall(r'"([A-Za-z][A-Za-z0-9]*)(?::[^"]*)?"', m.group(1)):
        if not re.search(r"<b>%s</b>" % re.escape(a), cref):
            fehler.append("Attribut '%s' fehlt in der commandref" % a)

# --- 3. Version ---------------------------------------------------------------
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
