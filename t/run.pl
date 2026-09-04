#!/usr/bin/perl
# Szenario-Tests fuer 98_GithubExport.pm gegen die FHEM-Attrappe in
# t/FhemStub.pm - ohne FHEM-Installation und ohne echtes GitHub.
#
# Aufruf:  perl t/run.pl
#
# Geprueft wird vor allem das, was im Betrieb weh taete:
#   - was eingesammelt wird (und was NICHT: 98_*, zu grosse Dateien)
#   - dass Token und Passwoerter aus den Log-Auszuegen verschwinden
#   - dass unveraenderte Dateien gar nicht erst hochgeladen werden
#   - dass in ein oeffentliches Repository nichts gepusht wird
#   - dass in keiner Fehlermeldung der Token steht
use strict;
use warnings;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib $FindBin::Bin;

require "$FindBin::Bin/FhemStub.pm";
require "$FindBin::Bin/../FHEM/98_GithubExport.pm";

# Das Nach-GitHub haengt UNTER der Kopfzeilen-Erzeugung: GithubExport_Api mit
# seinen Kopfzeilen, seiner JSON-Kodierung und seiner Fehlerauswertung laeuft
# also mit und wird geprueft. Nur die Leitung selbst ist ausgetauscht - die
# bekommt weiter unten ihren eigenen Test gegen einen echten TLS-Server.
my $ECHT_REQUEST = \&GithubExport_Request;   # fuer den TLS-Test weiter unten
{
    no warnings qw(redefine once);
    *GithubExport_Request = \&main::gh_request;
}

our %defs;
our %attr;
our @LOG;
our @CMD;
our @HTTP;
our @BLOCKING;
our %KEYVALUE;

# Die Testdaten muessen auf die Entschaerfungs-Regeln passen - deshalb werden
# sie ZUSAMMENGESETZT statt als Literal hingeschrieben. Ein erfundener
# Telegram-Token sieht fuer GitHubs Secret Scanning aus wie ein echter, und
# dieses Repo ist oeffentlich: der erste Commit hat prompt einen Alarm
# ausgeloest. Kein Literal in dieser Datei hat das vollstaendige Format mehr,
# erst zur Laufzeit entsteht eines - und das ist genau das, was die Regeln
# treffen muessen.
my $TOKEN    = "gh" . "p_" . ("t" x 30) . "654321";
my $TG_FAKE  = "bot" . "1234567890" . ":" . ("A" x 20) . "bcd";
my $GHP_FAKE = "gh" . "p_" . ("a" x 30) . "123456";
my $URL_FAKE = "https://benutzer:" . "geheim" . '@' . "host/pfad";
my $QS_FAKE  = "http://x/y?token=" . "supergeheim" . "lang123";
my $tests = 0;
my $bad   = 0;

sub ok {
    my ($name, $wahr, $info) = @_;
    $tests++;
    if($wahr) { print "ok   $name\n"; return 1; }
    $bad++;
    print "FEHL $name" . (defined($info) ? "  ($info)" : "") . "\n";
    return 0;
}
sub is {
    my ($n, $ist, $soll) = @_;
    return ok($n, (defined($ist) ? $ist : "") eq $soll,
              "ist '" . (defined($ist) ? $ist : "undef") . "', soll '$soll'");
}
sub like {
    my ($n, $ist, $re) = @_;
    # Das "? 1 : 0" ist Pflicht, nicht Zierde: die Argumentliste eines
    # Sub-Aufrufs ist LISTENkontext, und ein fehlgeschlagener Match liefert
    # dort die leere Liste statt "". Die faellt beim Flatten weg, der
    # Info-Text rutscht auf den Platz des Wahrheitswerts - und ist immer
    # wahr. Jede like()-Zusicherung war damit wirkungslos und meldete "ok",
    # auch wenn der Match danebenlag.
    my $wahr = (defined($ist) && $ist =~ $re) ? 1 : 0;
    return ok($n, $wahr,
              "'" . (defined($ist) ? substr($ist,0,120) : "undef") . "' passt nicht auf $re");
}
sub schreib {
    my ($f, @zeilen) = @_;
    make_path(main::dirname_of($f));
    open(my $fh, ">", $f) or die "$f: $!";
    print $fh join("\n", @zeilen), "\n";
    close($fh);
}
sub dirname_of { my $p = shift; $p =~ s{/[^/]+$}{}; return $p; }
sub datei { my $f = shift; open(my $fh,"<",$f) or return undef; local $/; my $d=<$fh>; close($fh); return $d; }
sub finde { my ($files,$pfad) = @_; foreach (@$files) { return $_ if($_->{path} eq $pfad); } return undef; }

# ------------------------------------------------------------------ Aufbau
my $root;
my $hash;

sub aufbau {
    my (%o) = @_;
    $root = tempdir(CLEANUP => 1);

    schreib("$root/fhem.cfg",
        "attr global statefile ./log/fhem.save",
        "attr global logfile ./log/fhem-%Y-%V.log",
        "define WEB FHEMWEB 8083");
    schreib("$root/log/fhem.save", "setstate d_test on");
    schreib("$root/FHEM/99_myUtils.pm", "package main;", "1;");
    schreib("$root/FHEM/99_mySendUtils.pm", "package main;", "1;");
    schreib("$root/FHEM/98_Fremd.pm", "package main;", "1;");   # darf NICHT mit

    # Aeltere Woche: 10 Zeilen. Neueste Woche: 3 Zeilen - so wie montags.
    schreib("$root/log/fhem-2026-34.log",
        map { "2026.08.2$_ 10:00:00 3: alte zeile $_" } (0..9));
    schreib("$root/log/fhem-2026-35.log",
        "2026.09.03 10:00:01 3: neue zeile 1",
        "2026.09.03 10:00:02 1: ERROR etwas ist kaputt",
        "2026.09.03 10:00:03 3: telegram $TG_FAKE und $QS_FAKE und $URL_FAKE");
    schreib("$root/log/freeze-20260903.log",
        "2026.09.03 10:00:04 1: freeze 1", "2026.09.03 10:00:05 1: freeze 2");
    schreib("$root/log/bewaesserung-2026.log",
        "2026-09-03_10:00:00 bewaesserung remainingTime: 12",
        "2026-09-03_10:00:01 bewaesserung barrelLevel_l: 148",
        "2026-09-03_10:00:02 bewaesserung pauseTimeRemaining: 3",
        "2026-09-03_10:00:03 bewaesserung barrelFull: yes");

    %attr = (
        global => { modpath => $root, statefile => "./log/fhem.save",
                    logfile => "./log/fhem-%Y-%V.log" },
        gh     => { fhemDir => $root, fileLogs => "bewaesserung", %{$o{attr} || {}} },
    );
    $defs{gh} = $hash = { NAME => "gh", TYPE => "GithubExport",
                          OWNER => "o", REPO => "r", FOLDER_DEF => "Main" };
    %KEYVALUE = ("GithubExport_gh" => $TOKEN);
    @LOG = (); @CMD = (); @BLOCKING = ();
    main::gh_reset();
}

sub konfig {
    my (@wish) = @_;
    my ($cfg, $err) = GithubExport_BuildConfig($hash, 0, @wish);
    die "BuildConfig: $err" if($err);
    $cfg->{token} = $TOKEN;
    return $cfg;
}

# ================================================================== Teile lesen
{
    my ($p, $fl, $err) = GithubExport_ParseParts("cfg state modules log freeze", "");
    is("parts: Default cfg",    $p->{cfg},    1);
    is("parts: Default extra",  $p->{extra},  0);
    is("parts: kein filelog",   $p->{filelog}, 0);

    ($p, $fl, $err) = GithubExport_ParseParts("all", "bewaesserung MQTT2_X");
    is("parts: all setzt extra", $p->{extra}, 1);
    is("parts: all nimmt fileLogs mit", join(",", @$fl), "MQTT2_X,bewaesserung");

    ($p, $fl, $err) = GithubExport_ParseParts("all -state -filelog", "bewaesserung");
    is("parts: -state waehlt ab", $p->{state}, 0);
    is("parts: -state laesst cfg", $p->{cfg}, 1);
    is("parts: -filelog leert die Liste", scalar(@$fl), 0);

    ($p, $fl, $err) = GithubExport_ParseParts("log filelog:Bewaesserung", "");
    is("parts: filelog:<name> ohne Attribut", join(",", @$fl), "Bewaesserung");
    ok("parts: Geraetename bleibt gross", $fl->[0] eq "Bewaesserung");

    ($p, $fl, $err) = GithubExport_ParseParts("cfg quatsch", "");
    like("parts: Unbekanntes meldet Fehler", $err, qr/Unbekannter Teil 'quatsch'/);

    ($p, $fl, $err) = GithubExport_ParseParts("-cfg", "");
    like("parts: nichts ausgewaehlt meldet Fehler", $err, qr/Nichts ausgewaehlt/);
}

# ================================================================== Werkzeug
{
    # Die einzige Stelle, die die Formel gegen git prueft:
    #   printf 'hallo\n' | git hash-object --stdin
    is("BlobSha wie git", GithubExport_BlobSha("hallo\n"),
       "4cf5aa5f9a644263dbe3d6e78bcbef45487a802c");
    is("BlobSha leere Datei", GithubExport_BlobSha(""),
       "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391");

    my $s = GithubExport_Sanitize(
        "$TG_FAKE\n$QS_FAKE\n$URL_FAKE\n$GHP_FAKE\n");
    like("Sanitize: Telegram-Token",  $s, qr/bot<TOKEN>/);
    like("Sanitize: token=-Parameter", $s, qr/token=<GEHEIM>/);
    like("Sanitize: URL mit Passwort", $s, qr/<BENUTZER:PASSWORT>\@host/);
    like("Sanitize: GitHub-Token",     $s, qr/ghp_<TOKEN>/);
    ok("Sanitize: nichts Geheimes uebrig",
       $s !~ /geheim/ && $s !~ /A{10}/ && $s !~ /a{10}/ && $s !~ /benutzer/);

    is("Shorten kuerzt", GithubExport_Shorten("abcdefghij", 4), "abcd \xE2\x80\xA6[gekuerzt]");
    is("Shorten laesst kurz",  GithubExport_Shorten("abc", 10), "abc");

    # 20 Bytes schneiden mitten in die erste Zeile - die fliegt dann ganz raus.
    my $cap = GithubExport_Cap("2026.01.01 eins\n2026.01.02 zwei\n", 20, qr/^[0-9]{4}\./);
    is("Cap wirft angebrochene erste Zeile weg", $cap, "2026.01.02 zwei\n");
    is("Cap laesst Kleines in Ruhe",
       GithubExport_Cap("2026.01.01 eins\n", 999, qr/^[0-9]{4}\./), "2026.01.01 eins\n");

    is("Glob ersetzt %Y/%V", GithubExport_Glob("./log/fhem-%Y-%V.log"), "./log/fhem-*-*.log");
    is("CommitMessage Platzhalter",
       GithubExport_CommitMessage({ commitMessage => 'x %f %n %c %b', folder => "Main",
                                    name => "gh", branch => "main", repo => "r" }, 3),
       "x Main gh 3 main");
}

# ================================================================== Einsammeln
{
    aufbau();
    my $cfg = konfig("all");
    my ($files, $warn) = GithubExport_Collect($cfg);
    my %hat = map { $_->{path} => $_ } @$files;

    ok("Collect: fhem.cfg",   exists($hat{"Main/fhem.cfg"}));
    ok("Collect: fhem.save",  exists($hat{"Main/fhem.save"}));
    ok("Collect: 99_myUtils", exists($hat{"Main/FHEM/99_myUtils.pm"}));
    ok("Collect: 99_mySendUtils", exists($hat{"Main/FHEM/99_mySendUtils.pm"}));
    ok("Collect: 98_Fremd bleibt draussen", !exists($hat{"Main/FHEM/98_Fremd.pm"}));
    ok("Collect: tail",       exists($hat{"Main/log/fhem-tail.log"}));
    ok("Collect: fehler",     exists($hat{"Main/log/fhem-fehler.log"}));
    ok("Collect: freeze",     exists($hat{"Main/log/fhem-freeze.log"}));
    ok("Collect: filelog",    exists($hat{"Main/log/bewaesserung-auszug.log"}));

    like("Collect: Ordner steckt im Pfad", $files->[0]{path}, qr{^Main/});

    my $tail = $hat{"Main/log/fhem-tail.log"}{data};
    like("tail: neueste Zeile drin", $tail, qr/neue zeile 1/);
    like("tail: alte Woche wird angehaengt", $tail, qr/alte zeile 9/);
    ok("tail: Token entschaerft",
       $tail !~ /geheim/ && $tail !~ /A{10}/ && $tail !~ /benutzer/);

    my $feh = $hat{"Main/log/fhem-fehler.log"}{data};
    like("fehler: ERROR-Zeile drin", $feh, qr/etwas ist kaputt/);
    ok("fehler: normale Zeile draussen", $feh !~ /neue zeile 1/);

    my $bew = $hat{"Main/log/bewaesserung-auszug.log"}{data};
    like("filelog: Nutzzeile drin", $bew, qr/barrelLevel_l/);
    ok("filelog: Rauschen raus",
       $bew !~ /remainingTime/ && $bew !~ /pauseTimeRemaining/);

    is("Collect: keine Warnung", join("|", @$warn), "");
}

# Zeilendeckel und fehlende Dateien
{
    aufbau(attr => { logLines => 4, modulePattern => "99_* 98_Fremd.pm" });
    my $cfg = konfig("cfg state modules log");
    my ($files, $warn) = GithubExport_Collect($cfg);
    my %hat = map { $_->{path} => $_ } @$files;

    my @z = split(/\n/, $hat{"Main/log/fhem-tail.log"}{data});
    is("logLines deckelt", scalar(@z), 4);
    ok("modulePattern nimmt mehrere Muster", exists($hat{"Main/FHEM/98_Fremd.pm"}));

    unlink("$root/log/fhem.save");
    ($files, $warn) = GithubExport_Collect($cfg);
    like("fehlende Datei gibt eine Warnung", join("|", @$warn), qr/fehlt:.*fhem\.save/);
    ok("fehlende Datei bricht nicht ab", scalar(@$files) > 0);
}

# Auszuege muessen das ENDE der Datei zeigen. Der alte FileLog-Testfall hatte
# VIER Zeilen und lag damit weit unter dem Deckel von 6000 - eine vertauschte
# Leserichtung konnte er gar nicht bemerken. Genau darauf fiel am 04.09. der
# Verdacht, als ein zwei Tage alter Auszug im Repository lag.
{
    aufbau(attr => { logLines => 50, fileLogLines => 50 });
    schreib("$root/log/fhem-2026-35.log",
        map { sprintf("2026.09.03 %02d:%02d:%02d 3: laufzeile %d",
                      ($_/3600)%24, ($_/60)%60, $_%60, $_) } (1..500));
    schreib("$root/log/bewaesserung-2026.log",
        map { sprintf("2026-09-03_%02d:%02d:%02d bewaesserung zeile: %d",
                      ($_/3600)%24, ($_/60)%60, $_%60, $_) } (1..500));

    my ($files) = GithubExport_Collect(konfig("log filelog"));
    my %hat = map { $_->{path} => $_ } @$files;

    my @t = split(/\n/, $hat{"Main/log/fhem-tail.log"}{data});
    is("Tail: genau logLines Zeilen",   scalar(@t), 50);
    like("Tail: juengste Zeile ist drin", $t[-1], qr/laufzeile 500$/);
    like("Tail: Anfang ist abgeschnitten", $t[0],  qr/laufzeile 451$/);

    my @b = split(/\n/, $hat{"Main/log/bewaesserung-auszug.log"}{data});
    is("FileLog: genau fileLogLines Zeilen", scalar(@b), 50);
    like("FileLog: juengste Zeile ist drin", $b[-1], qr/zeile: 500$/);
    like("FileLog: Anfang ist abgeschnitten", $b[0], qr/zeile: 451$/);
}

# Eingestellt, aber nicht ausgewaehlt - das war die eigentliche Ursache:
# attr fileLogs war gesetzt, exportParts enthielt kein "filelog", und das Modul
# schwieg dazu.
{
    aufbau();                                   # fileLogs = bewaesserung
    my (undef, $warn) = GithubExport_Collect(konfig("cfg log"));
    like("Warnung: fileLogs ohne 'filelog'", join(" | ", @$warn),
         qr/fileLogs ist gesetzt.*NICHT gesichert/);

    (undef, $warn) = GithubExport_Collect(konfig("cfg log filelog"));
    ok("keine Warnung, wenn filelog ausgewaehlt ist",
       join(" | ", @$warn) !~ /fileLogs ist gesetzt/);
}
{
    aufbau(attr => { extraFiles => "FHEM/99_myUtils.pm" });
    my (undef, $warn) = GithubExport_Collect(konfig("cfg"));
    like("Warnung: extraFiles ohne 'extra'", join(" | ", @$warn),
         qr/extraFiles ist gesetzt/);
}

# maxFileSize
{
    aufbau(attr => { maxFileSize => 10 });
    my $cfg = konfig("cfg");
    my ($files, $warn) = GithubExport_Collect($cfg);
    is("zu grosse Datei wird uebersprungen", scalar(@$files), 0);
    like("zu grosse Datei warnt", join("|", @$warn), qr/zu gross/);
}

# ================================================================== Push
{
    aufbau();
    my $cfg = konfig("cfg state");
    my ($files) = GithubExport_Collect($cfg);
    my $res = GithubExport_Push($cfg, $files);

    is("Push: ok",            $res->{ok}, 1);
    is("Push: 2 Dateien",     scalar(@{$res->{changed}}), 2);
    is("Push: 2 Blobs",       main::gh_posted_blobs(), 2);
    is("Push: 1 Baum",        main::gh_call("POST", qr{/git/trees$}), 1);
    is("Push: 1 Commit",      main::gh_call("POST", qr{/git/commits$}), 1);
    is("Push: 1 Ref-Update",  main::gh_call("PATCH", qr{/git/refs/heads/main$}), 1);
    is("Push: kurze SHA",     $res->{commit}, "abcdef7");
    like("Push: Commit-Link", $res->{commitUrl}, qr{^https://github\.com/o/r/commit/abcdef});
    is("Push: privat erkannt", $res->{visibility}, "privat");

    my $tree = main::gh_unjson((grep { $_->[1] =~ m{/git/trees$} } @HTTP)[0][2]);
    is("Push: base_tree gesetzt", $tree->{base_tree},
       "2222222222222222222222222222222222222222");
    is("Push: Dateimodus", $tree->{tree}[0]{mode}, "100644");

    my $commit = main::gh_unjson((grep { $_->[1] =~ m{/git/commits$} } @HTTP)[0][2]);
    like("Push: Commit-Text", $commit->{message}, qr/^Update Main - \d{4}-\d{2}-\d{2}/);
    is("Push: Elternteil", $commit->{parents}[0],
       "1111111111111111111111111111111111111111");

    my $hdr = $HTTP[0][3];
    like("Push: Token im Header", $hdr, qr/Authorization: Bearer \Q$TOKEN\E/);
    like("Push: API-Version im Header", $hdr, qr/X-GitHub-Api-Version/);
}

# Unveraendert: kein einziger Blob, kein Commit
{
    aufbau();
    my $cfg = konfig("cfg state");
    my ($files) = GithubExport_Collect($cfg);
    my %blobs = map { $_->{path} => GithubExport_BlobSha($_->{data}) } @$files;
    main::gh_reset(blobs => \%blobs);

    my $res = GithubExport_Push($cfg, $files);
    is("unveraendert: Meldung", $res->{msg}, "unveraendert");
    is("unveraendert: keine Blobs", main::gh_posted_blobs(), 0);
    is("unveraendert: kein Commit", main::gh_call("POST", qr{/git/commits$}), 0);
    is("unveraendert: kein Ref-Update", main::gh_call("PATCH", qr{/git/refs/}), 0);
}

# Eine von zwei Dateien geaendert
{
    aufbau();
    my $cfg = konfig("cfg state");
    my ($files) = GithubExport_Collect($cfg);
    my %blobs = map { $_->{path} => GithubExport_BlobSha($_->{data}) } @$files;
    delete $blobs{"Main/fhem.save"};
    main::gh_reset(blobs => \%blobs);

    my $res = GithubExport_Push($cfg, $files);
    is("teilweise: nur ein Blob", main::gh_posted_blobs(), 1);
    is("teilweise: nur eine Datei im Commit", scalar(@{$res->{changed}}), 1);
    is("teilweise: die richtige", $res->{changed}[0], "Main/fhem.save");
}

# Oeffentliches Repository
{
    aufbau();
    my $cfg = konfig("cfg");
    my ($files) = GithubExport_Collect($cfg);
    main::gh_reset(private => 0);
    my $res = eval { GithubExport_Push($cfg, $files) };
    like("oeffentlich: bricht ab", $@, qr/OEFFENTLICH/);
    is("oeffentlich: nichts hochgeladen", main::gh_posted_blobs(), 0);

    main::gh_reset(private => 0);
    $cfg->{allowPublic} = 1;
    $res = eval { GithubExport_Push($cfg, $files) };
    is("oeffentlich mit allowPublicRepo: laeuft", ($res ? $res->{ok} : 0), 1);
    is("oeffentlich: Sichtbarkeit gemeldet", $res->{visibility}, "oeffentlich");
}

# Fehler von GitHub - und der Token darf nirgends auftauchen
{
    aufbau();
    my $cfg = konfig("cfg");
    my ($files) = GithubExport_Collect($cfg);
    main::gh_reset();
    $main::GH{fail} = [404, "Not Found"];
    eval { GithubExport_Push($cfg, $files) };
    my $err = $@;
    like("Fehler: Code steht drin", $err, qr/404/);
    like("Fehler: Hinweis dabei",   $err, qr/gibt es nicht/);
    ok("Fehler: kein Token im Text", $err !~ /\Q$TOKEN\E/);

    main::gh_reset();
    $main::GH{fail} = [403, "Resource not accessible"];
    eval { GithubExport_Push($cfg, $files) };
    like("403 nennt die Rechte", $@, qr/contents: write/);
}

# ================================================================== Probelauf
{
    aufbau();
    my ($cfg) = GithubExport_BuildConfig($hash, 1, "cfg state");
    $cfg->{token} = $TOKEN;
    my ($files) = GithubExport_Collect($cfg);
    my $res = GithubExport_Probe($cfg, $files);

    is("dryRun: ok", $res->{ok}, 1);
    is("dryRun: nichts hochgeladen", main::gh_posted_blobs(), 0);
    is("dryRun: kein Commit", main::gh_call("POST", qr{/git/commits$}), 0);
    is("dryRun: meldet die Kandidaten", scalar(@{$res->{changed}}), 2);
    is("dryRun: Sichtbarkeit geprueft", $res->{visibility}, "privat");
}

# ================================================================== Kind + Ende
{
    aufbau();
    my $cfg = konfig("cfg");
    require MIME::Base64;
    my $arg = "gh|" . MIME::Base64::encode_base64(GithubExport_JsonEnc($cfg), "");
    my $ret = GithubExport_DoExport($arg);
    like("DoExport: Rueckgabe hat den Namen", $ret, qr/^gh\|/);

    GithubExport_Done($ret);
    is("Done: state", ReadingsVal("gh","state",""), "ok: 1 von 1 Datei(en), abcdef7");
    is("Done: lastCommit", ReadingsVal("gh","lastCommit",""), "abcdef7");
    is("Done: lastError leer", ReadingsVal("gh","lastError","x"), "");
    is("Done: repoVisibility", ReadingsVal("gh","repoVisibility",""), "privat");

    # Fehlerfall
    aufbau();
    main::gh_reset();
    $main::GH{fail} = [401, "Bad credentials"];
    $cfg = konfig("cfg");
    $arg = "gh|" . MIME::Base64::encode_base64(GithubExport_JsonEnc($cfg), "");
    $ret = GithubExport_DoExport($arg);
    GithubExport_Done($ret);
    is("Done: state bei Fehler", ReadingsVal("gh","state",""), "Fehler");
    like("Done: lastError gefuellt", ReadingsVal("gh","lastError",""), qr/401/);
    ok("Done: kein Token im Reading",
       ReadingsVal("gh","lastError","") !~ /\Q$TOKEN\E/);
}

# ================================================================== Start
{
    aufbau();
    delete $KEYVALUE{"GithubExport_gh"};
    my $err = GithubExport_Start($hash, 0);
    like("Start ohne Token meldet das", $err, qr/Kein Token hinterlegt/);
    is("Start ohne Token startet nichts", scalar(@BLOCKING), 0);

    $KEYVALUE{"GithubExport_gh"} = $TOKEN;
    $err = GithubExport_Start($hash, 0);
    is("Start: kein Fehler", $err, "");
    is("Start: ein BlockingCall", scalar(@BLOCKING), 1);
    is("Start: save vorher", join(",", @CMD), "save");

    $hash->{helper}{RUNNING_PID} = 1;
    $err = GithubExport_Start($hash, 0);
    like("Start: zweiter Lauf wird abgelehnt", $err, qr/laeuft schon/);
    delete $hash->{helper}{RUNNING_PID};

    # Ein geglueckter Start hinterlaesst RUNNING_PID (die Attrappe liefert
    # wie BlockingCall eine PID zurueck) - das Geraet gilt danach als
    # beschaeftigt, genau wie im Betrieb. Vor jedem weiteren Fall also
    # aufraeumen, sonst prueft man nur noch "laeuft schon".
    delete $hash->{helper}{RUNNING_PID};
    $attr{gh}{saveBeforeExport} = 0;
    @CMD = ();
    GithubExport_Start($hash, 0);
    is("saveBeforeExport 0 spart das save", scalar(@CMD), 0);

    delete $hash->{helper}{RUNNING_PID};
    $attr{gh}{disable} = 1;
    like("disable blockt", GithubExport_Start($hash, 0), qr/abgeschaltet/);
    $attr{gh}{disable} = 0;

    delete $hash->{helper}{RUNNING_PID};
    $err = GithubExport_Start($hash, 0, "quatsch");
    like("Start reicht Teile-Fehler durch", $err, qr/Unbekannter Teil/);
}

# ================================================================== Klappmenue
# fhem.pl baut die Auswahlliste fuer FHEMWEB aus der Antwort auf "set <dev> ?":
# getAllSets() macht  $a =~ s/.*one of //  und nimmt, was uebrig bleibt. Eine
# Antwort ohne "one of" laesst den ganzen Satz stehen, und FHEMWEB zerlegt ihn
# an Leerzeichen - im Menue standen dann "Unbekannter", "waehle", "aus".
# Der Test macht genau diesen Schnitt nach.
{
    aufbau();
    my $sl = GithubExport_Set($hash, "gh", "?");
    like("set ?: Form", $sl, qr/^Unknown argument .*, choose one of \S/);
    $sl =~ s/.*one of //;
    is("set ?: das steht im Klappmenue",
       join(" ", map { (split(/:/, $_))[0] } split(/\s+/, $sl)),
       "export token deleteToken dryRun stop");

    my $gl = GithubExport_Get($hash, "gh", "?");
    like("get ?: Form", $gl, qr/^Unknown argument .*, choose one of \S/);
    $gl =~ s/.*one of //;
    is("get ?: das steht im Klappmenue",
       join(" ", map { (split(/:/, $_))[0] } split(/\s+/, $gl)),
       "parts token version");

    # Ein unbekannter Befehl muss dieselbe Form haben, sonst steht der
    # Fehlertext als Auswahl im Menue.
    like("set <quatsch>: gleiche Form",
         GithubExport_Set($hash, "gh", "quatsch"),
         qr/^Unknown argument quatsch, choose one of \S/);
}

# ================================================================== Die Leitung
# Der Fehler, der das Modul im Betrieb zu Fall brachte: ein POST mit 1,8 MB
# Rumpf kam zu 16 kB an, GitHub antwortete mit 400 "malformed request".
# IO::Socket::SSL liefert auch auf einem BLOCKIERENDEN Socket nur ein
# TLS-Record je syswrite - wer den Rueckgabewert nicht ansieht, verliert den
# Rest stillschweigend.
#
# Nachstellen laesst sich das nur ueber TLS: auf einer blanken TCP-Verbindung
# blockiert ein Schreibvorgang, bis alles draussen ist, und liefert nie einen
# Teilerfolg. Der Test braucht deshalb einen echten TLS-Server.
{
    my $geht = eval { require IO::Socket::SSL; 1 };
    my $openssl = (system("openssl version >/dev/null 2>&1") == 0);

    if(!$geht || !$openssl) {
        print "HINW Leitungstest uebersprungen (IO::Socket::SSL oder openssl fehlt)\n";
    } else {
        my $dir = tempdir(CLEANUP => 1);
        system("openssl req -x509 -newkey rsa:2048 -keyout $dir/k.pem -out $dir/c.pem "
             . "-days 1 -nodes -subj /CN=localhost >/dev/null 2>&1");

        my $pid = fork();
        die "fork: $!" if(!defined($pid));

        if(!$pid) {                                   # ---- Server
            my $srv = IO::Socket::SSL->new(LocalAddr => "127.0.0.1", LocalPort => 0,
                        Listen => 5, ReuseAddr => 1,
                        SSL_cert_file => "$dir/c.pem", SSL_key_file => "$dir/k.pem");
            exit(1) if(!$srv);
            open(my $fh, ">", "$dir/port") or exit(1);
            print $fh $srv->sockport(); close($fh);

            my $c = $srv->accept();
            exit(1) if(!$c);
            my $kopf = "";
            while($kopf !~ /\r\n\r\n/) {
                my $n = sysread($c, my $b, 1);
                last if(!$n);
                $kopf .= $b;
            }
            my ($cl) = $kopf =~ /Content-Length:\s*(\d+)/i;
            $cl ||= 0;
            my $da = 0;
            # Frist beim Lesen. Ohne sie wartet der Server bei einem
            # abgeschnittenen Rumpf ewig auf den Rest - der Test wuerde dann
            # haengen statt rot zu werden. (Genau so verhaelt sich GitHub, nur
            # gibt es nach 25 Sekunden auf.)
            my $schluss = time() + 5;
            while($da < $cl && time() < $schluss) {
                my $rin = "";
                vec($rin, fileno($c), 1) = 1;
                # Bei TLS koennen entschluesselte Bytes schon im Puffer liegen,
                # die select nicht sieht - deshalb pending() zuerst fragen.
                if(!$c->pending()) {
                    next if(select(my $rout = $rin, undef, undef, 0.5) <= 0);
                }
                my $n = sysread($c, my $b, 65536);
                last if(!defined($n) || $n <= 0);
                $da += $n;
            }
            open($fh, ">", "$dir/ergebnis") or exit(1);
            print $fh "$cl $da"; close($fh);

            my $rumpf = main::gh_json({ sha => "0" x 40 });
            print $c "HTTP/1.1 200 OK\r\nContent-Length: " . length($rumpf)
                   . "\r\nConnection: close\r\n\r\n$rumpf";
            close($c);
            exit(0);
        }

        # ---- Client: selbst signiertes Zertifikat, also Pruefung aus. Das
        # gilt nur fuer diesen Testlauf, das Modul selbst prueft weiterhin.
        IO::Socket::SSL::set_defaults(SSL_verify_mode => 0)
            if(IO::Socket::SSL->can("set_defaults"));

        my $port;
        for (1..100) {
            if(-s "$dir/port") { $port = datei("$dir/port"); last; }
            select(undef, undef, undef, 0.1);
        }

        if(!$port) {
            ok("Leitungstest: Server gestartet", 0, "kein Port");
        } else {
            my $rumpf = "z" x 1_823_437;              # so gross wie die echte fhem.cfg
            my @kopf = ("Host: 127.0.0.1:$port", "Content-Type: application/json",
                        "Content-Length: " . length($rumpf));
            my ($code, $antwort) = eval {
                $ECHT_REQUEST->({ apiUrl => "https://127.0.0.1:$port", httpTimeout => 10 },
                                "POST", "/git/blobs", \@kopf, $rumpf) };
            my $fehler = $@;

            is("Leitung: Status 200", $code, "200");
            ok("Leitung: kein Fehler", !$fehler, $fehler);
            like("Leitung: Antwort ausgewertet", $antwort, qr/"sha"/);

            waitpid($pid, 0);
            my ($soll, $ist) = split(/ /, (datei("$dir/ergebnis") || "0 0"));
            is("Leitung: 1,8 MB kommen VOLLSTAENDIG an", "$ist von $soll",
               length($rumpf) . " von " . length($rumpf));
        }
        kill("TERM", $pid);
        waitpid($pid, 0);
    }
}

# ------------------------------------------------------------------ Ergebnis
print "\n$tests Tests, $bad Fehler\n";
exit($bad ? 1 : 0);
