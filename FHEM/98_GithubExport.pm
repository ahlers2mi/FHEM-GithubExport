##############################################################################
#
#     98_GithubExport.pm
#
#     Sichert die FHEM-Konfiguration in ein GitHub-Repository - direkt aus
#     FHEM heraus, ueber die GitHub-API mit einem Token. Kein Shell-Skript,
#     kein installiertes git, kein lokaler Klon.
#
#     Gesichert wird, was man mitgibt:
#       set <name> export cfg state modules log freeze filelog:bewaesserung
#
#     Die laufende Version ist der oberste Eintrag der Aenderungsliste unten;
#     GithubExport_Version() liest sie von dort. Eine zweite, fest
#     verdrahtete Angabe im Kopf wuerde beim Anheben vergessen (die
#     Erfahrung stammt aus 98_Gartenbewaesserung.pm).
#
#     Autor:  ahlers2mi
#     Lizenz: GPL v2 oder hoeher (wie FHEM)
#
##############################################################################
#
# 1.0.0 - 2026-09-03  Erste Fassung. Uebernimmt die Aufgabe von
#                     fhem-backup.sh, aber von innen: Dateien einsammeln,
#                     Log-Auszuege bauen und entschaerfen, alles in EINEM
#                     Commit ueber die Git-Data-API ablegen.
#                     Bewusst anders als das Skript:
#                     - kein lokaler Klon, also auch kein "git pull" und
#                       keine Merge-Konflikte auf dem FHEM-Rechner;
#                     - unveraenderte Dateien werden gar nicht erst
#                       hochgeladen (die Blob-SHA rechnet das Modul selbst
#                       aus und vergleicht sie mit dem Baum im Repo) -
#                       fhem.save ist mehrere MB und aendert sich nicht bei
#                       jedem Lauf;
#                     - der ganze Lauf steckt in einem BlockingCall, FHEM
#                       blockiert also nicht (siehe Freeze-Kapitel der
#                       Projekt-CLAUDE.md);
#                     - allowPublicRepo: in ein oeffentliches Repository
#                       wird nicht gepusht. fhem.cfg und fhem.save enthalten
#                       Zugangsdaten im Klartext.
#
##############################################################################

package main;

use strict;
use warnings;

use POSIX qw(strftime);
use MIME::Base64 qw(encode_base64 decode_base64);
use Digest::SHA qw(sha1_hex);
use File::Basename qw(basename dirname);
use Sys::Hostname qw(hostname);

use vars qw($readingFnAttributes $init_done %defs %attr);

# Die Teile, die man sichern kann. "filelog" ist der einzige mit Argument
# (filelog:<geraet>), weil davon mehrere gemeint sein koennen.
my @GE_PARTS = qw(cfg state modules log freeze filelog extra);

my $GE_ERRPAT = '(error|fehler|warn|timeout|disconnect|reappear|reset|cannot|'
              . 'can.t|failed|refused|please define|no answer|unknown command|'
              . 'not found|PERL WARNING|died|busy)';

# ---------------------------------------------------------------- Version
{
    my $FALLBACK = "1.0.0";
    my $cached;
    sub GithubExport_Version {
        return $cached if(defined($cached));
        $cached = $FALLBACK;
        if(open(my $fh, "<", __FILE__)) {
            my $lines = 0;
            while(my $l = <$fh>) {
                last if(++$lines > 80);
                if($l =~ /^#\s*(\d+\.\d+\.\d+)\s+-\s+\d{4}-\d{2}-\d{2}/) {
                    $cached = $1;      # der oberste Eintrag ist der neueste
                    last;
                }
            }
            close($fh);
        }
        return $cached;
    }
}

# ---------------------------------------------------------------- JSON
# JSON::PP liegt seit Perl 5.14 im Kern; JSON ist der Rueckfall fuer alte
# Installationen. Kein "use", damit ein fehlendes Modul das Laden des
# Moduls nicht verhindert - die Meldung kommt dann im Define.
{
    my $obj;
    sub GithubExport_JsonObj {
        return $obj if($obj);
        foreach my $mod ("JSON::PP", "JSON") {
            next if(!eval "require $mod; 1");
            $obj = $mod->new->utf8->allow_nonref;
            last;
        }
        return $obj;
    }
}
sub GithubExport_JsonEnc { return GithubExport_JsonObj()->encode($_[0]); }
sub GithubExport_JsonDec { return GithubExport_JsonObj()->decode($_[0]); }

# ---------------------------------------------------------------- Initialize
sub GithubExport_Initialize {
    my ($hash) = @_;

    $hash->{DefFn}   = \&GithubExport_Define;
    $hash->{UndefFn} = \&GithubExport_Undef;
    $hash->{SetFn}   = \&GithubExport_Set;
    $hash->{GetFn}   = \&GithubExport_Get;
    $hash->{AttrFn}  = \&GithubExport_Attr;

    $hash->{AttrList} = join(" ",
        "disable:1,0",
        "branch",
        "targetFolder",
        "fhemDir",
        "exportParts",
        "saveBeforeExport:1,0",
        "interval",
        "modulePattern",
        "extraFiles:textField-long",
        "logLines", "logErrorLines", "logFreezeLines",
        "logMaxBytes", "logMaxCols", "logFreezeMaxCols",
        "logErrorPattern",
        "fileLogs", "fileLogLines", "fileLogMaxBytes", "fileLogNoise",
        "sanitize:1,0",
        "allowPublicRepo:1,0",
        "maxFileSize",
        "apiUrl", "httpTimeout", "timeout",
        "commitMessage", "authorName", "authorEmail",
        $readingFnAttributes);
}

# ---------------------------------------------------------------- Define
# define <name> GithubExport <owner>/<repo> [<zielordner>]
sub GithubExport_Define {
    my ($hash, $def) = @_;
    my @a = split('[ \t]+', $def);
    my $name = $a[0];

    return "Usage: define <name> GithubExport <owner>/<repo> [<zielordner>]"
        if(int(@a) < 3 || int(@a) > 4);
    return "Ungueltiges Repository '$a[2]' - erwartet <owner>/<repo>"
        if($a[2] !~ m{^([A-Za-z0-9_.\-]+)/([A-Za-z0-9_.\-]+)$});

    $hash->{OWNER}      = $1;
    $hash->{REPO}       = $2;
    $hash->{FOLDER_DEF} = (defined($a[3]) ? $a[3] : "");
    $hash->{VERSION}    = GithubExport_Version();
    $hash->{FVERSION}   = "98_GithubExport.pm:v" . $hash->{VERSION};

    return "Weder JSON::PP noch JSON ist installiert "
         . "(Debian/Raspbian: apt install libjson-pp-perl)"
        if(!GithubExport_JsonObj());

    RemoveInternalTimer($hash);
    readingsSingleUpdate($hash, "state", "initialized", 0)
        if(!defined($hash->{READINGS}{state}));
    GithubExport_ArmTimer($hash);

    return undef;
}

sub GithubExport_Undef {
    my ($hash, $arg) = @_;
    RemoveInternalTimer($hash);
    BlockingKill($hash->{helper}{RUNNING_PID}) if($hash->{helper}{RUNNING_PID});
    return undef;
}

# ---------------------------------------------------------------- Attr
sub GithubExport_Attr {
    my ($cmd, $name, $aName, $aVal) = @_;
    my $hash = $defs{$name};
    return undef if(!$hash);

    if($cmd eq "set") {
        if($aName =~ /^(interval|logLines|logErrorLines|logFreezeLines|logMaxBytes|
                        logMaxCols|logFreezeMaxCols|fileLogLines|fileLogMaxBytes|
                        maxFileSize|httpTimeout|timeout)$/x) {
            return "$aName braucht eine Zahl >= 0, nicht '$aVal'"
                if(!defined($aVal) || $aVal !~ /^\d+(\.\d+)?$/);
        }
        if($aName eq "exportParts") {
            my (undef, undef, $err) = GithubExport_ParseParts($aVal, "");
            return $err if($err);
        }
        if($aName =~ /^(fileLogNoise|logErrorPattern)$/) {
            return "'$aVal' ist kein gueltiger regulaerer Ausdruck: $@"
                if(!eval { qr/$aVal/; 1 });
        }
    }

    # Der Timer haengt am Attribut - beim Setzen UND beim Loeschen neu stellen.
    # Beim Loeschen steht der alte Wert noch in %attr - deshalb erst danach.
    if($aName eq "interval" || $aName eq "disable") {
        RemoveInternalTimer($hash, "GithubExport_ArmTimerDelayed");
        InternalTimer(gettimeofday()+1, "GithubExport_ArmTimerDelayed", $hash, 0);
    }
    return undef;
}

sub GithubExport_ArmTimerDelayed { GithubExport_ArmTimer($_[0]); }

# ---------------------------------------------------------------- Timer
sub GithubExport_ArmTimer {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    RemoveInternalTimer($hash, "GithubExport_Timer");
    RemoveInternalTimer($hash, "GithubExport_ArmTimerDelayed");

    my $min = AttrVal($name, "interval", 0);
    if(!$min || $min <= 0 || IsDisabled($name)) {
        readingsSingleUpdate($hash, "nextRun", "aus", 1)
            if(ReadingsVal($name, "nextRun", "") ne "aus");
        return;
    }
    my $next = gettimeofday() + $min * 60;
    InternalTimer($next, "GithubExport_Timer", $hash, 0);
    readingsSingleUpdate($hash, "nextRun",
        strftime("%Y-%m-%d %H:%M:%S", localtime($next)), 1);
}

sub GithubExport_Timer {
    my ($hash) = @_;
    GithubExport_ArmTimer($hash);
    return if(IsDisabled($hash->{NAME}));
    my $err = GithubExport_Start($hash, 0);
    Log3($hash->{NAME}, 2, "GithubExport ($hash->{NAME}) $err") if($err);
}

# ---------------------------------------------------------------- Set
sub GithubExport_Set {
    my ($hash, $name, $cmd, @args) = @_;
    my $list = "export token:textField deleteToken:noArg dryRun stop:noArg";

    return "Unbekannter Befehl, waehle eins aus: $list"
        if(!defined($cmd) || $cmd eq "?");

    if($cmd eq "token") {
        my $tok = join(" ", @args);
        $tok =~ s/^\s+|\s+$//g;
        return "Usage: set $name token <github-token>" if($tok eq "");
        my $err = setKeyValue("GithubExport_$name", $tok);
        return $err if($err);
        readingsSingleUpdate($hash, "token", "hinterlegt", 1);
        Log3($name, 3, "GithubExport ($name) Token hinterlegt");
        return undef;
    }

    if($cmd eq "deleteToken") {
        my $err = setKeyValue("GithubExport_$name", undef);
        return $err if($err);
        readingsSingleUpdate($hash, "token", "keiner", 1);
        return undef;
    }

    if($cmd eq "stop") {
        return "Es laeuft gerade nichts" if(!$hash->{helper}{RUNNING_PID});
        BlockingKill($hash->{helper}{RUNNING_PID});
        delete($hash->{helper}{RUNNING_PID});
        readingsSingleUpdate($hash, "state", "abgebrochen", 1);
        return undef;
    }

    if($cmd eq "export" || $cmd eq "dryRun") {
        my $err = GithubExport_Start($hash, ($cmd eq "dryRun" ? 1 : 0), @args);
        return $err if($err);
        return undef;
    }

    return "Unbekannter Befehl $cmd, waehle eins aus: $list";
}

# ---------------------------------------------------------------- Get
sub GithubExport_Get {
    my ($hash, $name, $cmd, @args) = @_;
    my $list = "parts:noArg token:noArg version:noArg";

    return "Unbekannter Befehl, waehle eins aus: $list" if(!defined($cmd));

    if($cmd eq "parts") {
        my $fl = AttrVal($name, "fileLogs", "");
        return
            "cfg      fhem.cfg\n"
          . "state    fhem.save (Pfad aus 'attr global statefile')\n"
          . "modules  " . AttrVal($name, "modulePattern", "99_*.pm")
                        . " aus dem FHEM-Verzeichnis\n"
          . "log      fhem-tail.log + fhem-fehler.log (gekuerzt, entschaerft)\n"
          . "freeze   fhem-freeze.log (neuestes Freezemon-Protokoll)\n"
          . "filelog  FileLog-Auszuege; ohne Argument die aus attr fileLogs"
                    . ($fl ne "" ? " ($fl)" : " (leer)") . ",\n"
          . "         sonst filelog:<geraet>\n"
          . "extra    die Pfade aus attr extraFiles\n"
          . "all      alles davon\n"
          . "\n"
          . "Mit '-' davor abwaehlen, z.B.  set $name export all -state\n"
          . "Ohne Angabe gilt attr exportParts (Default: cfg state modules log freeze)";
    }

    if($cmd eq "token") {
        my $tok = getKeyValue("GithubExport_$name");
        return "kein Token hinterlegt - 'set $name token <github-token>'" if(!$tok);
        return "Token hinterlegt (" . length($tok) . " Zeichen, beginnt mit '"
             . substr($tok, 0, 4) . "')";
    }

    if($cmd eq "version") {
        return "98_GithubExport.pm v" . GithubExport_Version();
    }

    return "Unbekannter Befehl $cmd, waehle eins aus: $list";
}

# ---------------------------------------------------------------- Teile lesen
# Liefert (\%teile, \@filelogs, $fehler).
sub GithubExport_ParseParts {
    my ($spec, $attrFileLogs) = @_;
    my %p = map { $_ => 0 } @GE_PARTS;
    my %fl;
    my @attrFl = grep { /\S/ } split(/[\s,]+/, (defined($attrFileLogs) ? $attrFileLogs : ""));

    foreach my $tok (grep { /\S/ } split(/[\s,]+/, (defined($spec) ? $spec : ""))) {
        my $t   = $tok;
        my $neg = ($t =~ s/^-//) ? 1 : 0;
        my ($k, $arg) = split(/:/, $t, 2);
        $k = lc($k);                       # der Geraetename in $arg bleibt wie er ist

        if($k eq "all") {
            $p{$_} = ($neg ? 0 : 1) foreach (@GE_PARTS);
            if($neg) { %fl = (); } else { $fl{$_} = 1 foreach (@attrFl); }
            next;
        }
        return (undef, undef, "Unbekannter Teil '$tok' - moeglich: "
              . join(" ", @GE_PARTS) . " all (mit '-' davor abwaehlen)")
            if(!exists($p{$k}));

        if($k eq "filelog") {
            my $einer = (defined($arg) && $arg =~ /\S/);
            my @namen = $einer ? ($arg) : @attrFl;
            if($neg) { $einer ? delete($fl{$arg}) : (%fl = ()); }
            else     { $fl{$_} = 1 foreach (@namen); }
            next;
        }
        $p{$k} = ($neg ? 0 : 1);
    }

    $p{filelog} = (scalar(keys %fl) ? 1 : 0);
    my @fl = sort keys %fl;

    return (undef, undef, "Nichts ausgewaehlt - es wuerde keine Datei gesichert")
        if(!grep { $p{$_} } @GE_PARTS);

    return (\%p, \@fl, undef);
}

# ---------------------------------------------------------------- Konfiguration
# Alles, was das Kind braucht, wird HIER im Elternprozess aufgeloest: %attr
# und %defs sind nach dem fork zwar noch da, aber ein Kind, das FHEM-Zustand
# liest, ist eine Fehlerquelle mehr. Das Kind sieht nur noch Pfade und Zahlen.
sub GithubExport_BuildConfig {
    my ($hash, $dry, @wish) = @_;
    my $name = $hash->{NAME};

    my $fhemDir = AttrVal($name, "fhemDir", AttrVal("global", "modpath", "."));
    $fhemDir =~ s{/+$}{};
    $fhemDir = "." if($fhemDir eq "");
    return (undef, "fhemDir '$fhemDir' ist kein Verzeichnis") if(!-d $fhemDir);

    my $folder = AttrVal($name, "targetFolder", $hash->{FOLDER_DEF});
    $folder = hostname() if(!defined($folder) || $folder eq "");
    $folder =~ s{^[\s/]+|[\s/]+$}{}g;
    $folder = "" if($folder eq ".");

    my $spec = join(" ", @wish);
    $spec = AttrVal($name, "exportParts", "cfg state modules log freeze")
        if($spec !~ /\S/);
    my ($parts, $filelogs, $err) =
        GithubExport_ParseParts($spec, AttrVal($name, "fileLogs", ""));
    return (undef, $err) if($err);

    my %cfg = (
        name        => $name,
        dryRun      => ($dry ? 1 : 0),
        owner       => $hash->{OWNER},
        repo        => $hash->{REPO},
        branch      => AttrVal($name, "branch", "main"),
        folder      => $folder,
        fhemDir     => $fhemDir,
        parts       => $parts,
        filelogs    => $filelogs,
        partsSpec   => $spec,

        cfgFile     => "$fhemDir/fhem.cfg",
        stateFile   => GithubExport_Path($fhemDir, AttrVal("global", "statefile", "./log/fhem.save")),
        logPattern  => GithubExport_Path($fhemDir, AttrVal("global", "logfile",   "./log/fhem-%Y-%m.log")),

        modulePattern    => AttrVal($name, "modulePattern", "99_*.pm"),
        extraFiles       => AttrVal($name, "extraFiles", ""),

        logLines         => int(AttrVal($name, "logLines",         600)),
        logErrorLines    => int(AttrVal($name, "logErrorLines",    300)),
        logFreezeLines   => int(AttrVal($name, "logFreezeLines",   400)),
        logMaxBytes      => int(AttrVal($name, "logMaxBytes",      120000)),
        logMaxCols       => int(AttrVal($name, "logMaxCols",       300)),
        logFreezeMaxCols => int(AttrVal($name, "logFreezeMaxCols", 600)),
        logErrorPattern  => AttrVal($name, "logErrorPattern", $GE_ERRPAT),

        fileLogLines     => int(AttrVal($name, "fileLogLines",     6000)),
        fileLogMaxBytes  => int(AttrVal($name, "fileLogMaxBytes",  400000)),
        fileLogNoise     => AttrVal($name, "fileLogNoise", '(remainingTime|pauseTimeRemaining): '),

        sanitize         => AttrVal($name, "sanitize", 1),
        allowPublic      => AttrVal($name, "allowPublicRepo", 0),
        maxFileSize      => int(AttrVal($name, "maxFileSize", 5000000)),

        apiUrl           => AttrVal($name, "apiUrl", "https://api.github.com"),
        httpTimeout      => int(AttrVal($name, "httpTimeout", 60)),
        commitMessage    => AttrVal($name, "commitMessage", 'Update %f - %t'),
        authorName       => AttrVal($name, "authorName", ""),
        authorEmail      => AttrVal($name, "authorEmail", ""),
    );
    $cfg{apiUrl} =~ s{/+$}{};

    return (\%cfg, undef);
}

sub GithubExport_Path {
    my ($base, $p) = @_;
    return $p if($p =~ m{^/});
    $p =~ s{^\./}{};
    return "$base/$p";
}

# ---------------------------------------------------------------- Start
sub GithubExport_Start {
    my ($hash, $dry, @wish) = @_;
    my $name = $hash->{NAME};

    return "$name ist abgeschaltet (attr disable)" if(IsDisabled($name));
    return "Es laeuft schon ein Export"            if($hash->{helper}{RUNNING_PID});

    my $token = getKeyValue("GithubExport_$name");
    return "Kein Token hinterlegt - 'set $name token <github-token>'"
        if(!defined($token) || $token !~ /\S/);

    my ($cfg, $err) = GithubExport_BuildConfig($hash, $dry, @wish);
    return $err if($err);

    # Ohne "save" sichert man den Stand vom letzten Mal: mit
    # "attr global autosave 0" schreibt FHEM von sich aus weder fhem.cfg
    # noch fhem.save.
    if(!$dry && AttrVal($name, "saveBeforeExport", 1)) {
        my $r = AnalyzeCommandChain(undef, "save");
        Log3($name, 2, "GithubExport ($name) save meldet: $r") if($r);
    }

    $cfg->{token} = $token;
    my $arg = "$name|" . encode_base64(GithubExport_JsonEnc($cfg), "");

    $hash->{helper}{RUNNING_PID} = BlockingCall(
        "GithubExport_DoExport", $arg,
        "GithubExport_Done", int(AttrVal($name, "timeout", 300)),
        "GithubExport_Aborted", $hash);

    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, "state", ($dry ? "Probelauf laeuft" : "Export laeuft"));
    readingsBulkUpdate($hash, "lastParts", $cfg->{partsSpec});
    readingsEndUpdate($hash, 1);
    return undef;
}

# ---------------------------------------------------------------- Kind
sub GithubExport_DoExport {
    my ($string) = @_;
    my ($name, $enc) = split(/\|/, $string, 2);
    my $t0 = time();
    my $res;

    eval {
        my $cfg = GithubExport_JsonDec(decode_base64($enc));
        my ($files, $warn) = GithubExport_Collect($cfg);
        die "Keine einzige Datei gefunden - nichts zu sichern\n" if(!@$files);

        if($cfg->{dryRun}) {
            $res = GithubExport_Probe($cfg, $files);
            $res->{warn}  = $warn;
            $res->{files} = [ map { { path => $_->{path},
                                      size => length($_->{data}) } } @$files ];
        } else {
            $res = GithubExport_Push($cfg, $files);
            $res->{warn}  = $warn;
            $res->{files} = [ map { { path => $_->{path},
                                      size => length($_->{data}) } } @$files ];
        }
        1;
    } or do {
        my $e = $@ || "unbekannter Fehler";
        $e =~ s/\s+$//;
        $res = { ok => 0, error => $e };
    };

    $res->{duration} = sprintf("%.1f", time() - $t0);
    return "$name|" . encode_base64(GithubExport_JsonEnc($res), "");
}

# ---------------------------------------------------------------- Einsammeln
sub GithubExport_Collect {
    my ($cfg) = @_;
    my @files;
    my @warn;
    my $pre = ($cfg->{folder} ne "" ? $cfg->{folder} . "/" : "");
    my $p   = $cfg->{parts};

    my $nimm = sub {
        my ($quelle, $ziel) = @_;
        if(!-f $quelle) { push @warn, "fehlt: $quelle"; return; }
        my $size = -s $quelle;
        if($cfg->{maxFileSize} && $size > $cfg->{maxFileSize}) {
            push @warn, sprintf("zu gross (%.1f MB, Grenze %.1f MB): %s",
                                $size/1e6, $cfg->{maxFileSize}/1e6, $quelle);
            return;
        }
        my $data = GithubExport_Slurp($quelle);
        if(!defined($data)) { push @warn, "nicht lesbar: $quelle"; return; }
        push @files, { path => $ziel, data => GithubExport_Bytes($data) };
    };

    my $text = sub {
        my ($ziel, $data) = @_;
        return if(!defined($data) || $data eq "");
        push @files, { path => $ziel, data => GithubExport_Bytes($data) };
    };

    $nimm->($cfg->{cfgFile},   $pre . "fhem.cfg")   if($p->{cfg});
    $nimm->($cfg->{stateFile}, $pre . "fhem.save")  if($p->{state});

    if($p->{modules}) {
        my $n = 0;
        foreach my $muster (grep { /\S/ } split(/[\s,]+/, $cfg->{modulePattern})) {
            foreach my $f (sort glob("$cfg->{fhemDir}/FHEM/$muster")) {
                next if(!-f $f);
                $nimm->($f, $pre . "FHEM/" . basename($f));
                $n++;
            }
        }
        push @warn, "keine Moduldatei zu '$cfg->{modulePattern}' gefunden" if(!$n);
    }

    my @logs = GithubExport_LogFiles($cfg->{logPattern});
    my $logDir = @logs ? dirname($logs[-1]) : dirname($cfg->{logPattern});

    if($p->{log}) {
        if(!@logs) {
            push @warn, "keine Logdatei zu '" . GithubExport_Glob($cfg->{logPattern}) . "'";
        } else {
            # Die zwei neuesten, aelteste zuerst: direkt nach dem Wechsel der
            # Logdatei ist die neue fast leer, dann kommt der Rest aus der
            # vorherigen.
            my @zwei = (@logs >= 2) ? @logs[-2, -1] : @logs;
            my $buf = "";
            $buf .= GithubExport_TailBytes($_, 4 * $cfg->{logMaxBytes}) foreach (@zwei);

            $text->($pre . "log/fhem-tail.log",
                    GithubExport_Fassung($cfg, $buf, $cfg->{logLines},
                                         $cfg->{logMaxCols}, $cfg->{logMaxBytes},
                                         qr/^[0-9]{4}\./));

            $text->($pre . "log/fhem-fehler.log",
                    GithubExport_Fassung($cfg,
                        join("\n", GithubExport_Grep(\@logs, $cfg->{logErrorPattern},
                                                     $cfg->{logErrorLines})),
                        $cfg->{logErrorLines}, $cfg->{logMaxCols},
                        $cfg->{logMaxBytes}, qr/^[0-9]{4}\./));
        }
    }

    if($p->{freeze} && $cfg->{logFreezeLines} > 0) {
        my @fz = sort { (stat($a))[9] <=> (stat($b))[9] } grep { -f $_ }
                 glob("$logDir/freeze-*.log");
        if(!@fz) {
            push @warn, "kein Freezemon-Protokoll in $logDir (attr <fm> fm_logFile)";
        } else {
            $text->($pre . "log/fhem-freeze.log",
                    GithubExport_Fassung($cfg,
                        GithubExport_TailBytes($fz[-1], 4 * $cfg->{logMaxBytes}),
                        $cfg->{logFreezeLines}, $cfg->{logFreezeMaxCols},
                        $cfg->{logMaxBytes}, qr/^[0-9]{4}\./));
        }
    }

    if($p->{filelog}) {
        foreach my $fl (@{$cfg->{filelogs}}) {
            my @tr = sort { (stat($a))[9] <=> (stat($b))[9] } grep { -f $_ }
                     glob("$cfg->{fhemDir}/log/$fl-*.log");
            if(!@tr) {
                push @warn, "FileLog '$fl': keine Datei unter $cfg->{fhemDir}/log/$fl-*.log";
                next;
            }
            my $roh = GithubExport_TailBytes($tr[-1], 8 * $cfg->{fileLogMaxBytes});
            if($cfg->{fileLogNoise} =~ /\S/) {
                my $re = eval { qr/$cfg->{fileLogNoise}/ };
                $roh = join("\n", grep { $_ !~ $re } split(/\n/, $roh, -1)) if($re);
            }
            $text->($pre . "log/$fl-auszug.log",
                    GithubExport_Fassung($cfg, $roh, $cfg->{fileLogLines},
                                         $cfg->{logMaxCols}, $cfg->{fileLogMaxBytes},
                                         qr/^[0-9]{4}-[0-9]{2}-[0-9]{2}_/));
        }
    }

    if($p->{extra}) {
        foreach my $zeile (split(/\n/, $cfg->{extraFiles})) {
            $zeile =~ s/^\s+|\s+$//g;
            next if($zeile eq "" || $zeile =~ /^#/);
            my ($muster, $ziel) = split(/\s*=>\s*/, $zeile, 2);
            my @tr = grep { -f $_ }
                     glob($muster =~ m{^/} ? $muster : "$cfg->{fhemDir}/$muster");
            if(!@tr) { push @warn, "extraFiles: nichts gefunden zu '$muster'"; next; }
            foreach my $f (sort @tr) {
                my $z = $ziel;
                if(!defined($z) || $z !~ /\S/) {
                    $z = $f;
                    if(index($z, "$cfg->{fhemDir}/") == 0) {
                        $z = substr($z, length($cfg->{fhemDir}) + 1);
                    } else {
                        $z = "extra/" . basename($z);
                    }
                }
                $z =~ s{^/+}{};
                $nimm->($f, $pre . $z);
            }
        }
    }

    return (\@files, \@warn);
}

# Ein Log-Auszug in einem Rutsch: letzte N Zeilen, entschaerfen, kuerzen,
# Byte-Deckel, angebrochene erste Zeile weg.
sub GithubExport_Fassung {
    my ($cfg, $roh, $lines, $cols, $maxBytes, $anfang) = @_;
    return "" if(!defined($roh) || $roh eq "");

    my @l = split(/\n/, $roh, -1);
    pop @l if(@l && $l[-1] eq "");
    @l = @l[ -$lines .. -1 ] if($lines > 0 && @l > $lines);

    my $txt = join("\n", map { GithubExport_Shorten($_, $cols) } @l) . "\n";
    $txt = GithubExport_Sanitize($txt) if($cfg->{sanitize});
    return GithubExport_Cap($txt, $maxBytes, $anfang);
}

# ---------------------------------------------------------------- Werkzeug
sub GithubExport_Bytes {
    my ($s) = @_;
    utf8::encode($s) if(utf8::is_utf8($s));   # sonst zaehlt length() Zeichen
    return $s;
}

sub GithubExport_Slurp {
    my ($file) = @_;
    open(my $fh, "<", $file) or return undef;
    binmode($fh);
    local $/ = undef;
    my $d = <$fh>;
    close($fh);
    return defined($d) ? $d : "";
}

# Nur das Ende der Datei lesen. Ein Log kann hundert MB haben - das ganze
# einzulesen, um 600 Zeilen zu behalten, waere Unfug.
sub GithubExport_TailBytes {
    my ($file, $bytes) = @_;
    open(my $fh, "<", $file) or return "";
    binmode($fh);
    my $size = -s $fh;
    if($bytes > 0 && $size > $bytes) {
        seek($fh, $size - $bytes, 0);
        my $weg = <$fh>;                      # angebrochene Zeile verwerfen
    }
    local $/ = undef;
    my $d = <$fh>;
    close($fh);
    return defined($d) ? $d : "";
}

# Wie "grep -hiE ... | tail -n N" ueber alle Logdateien, aber zeilenweise:
# es wird immer nur ein Ringpuffer der letzten N Treffer gehalten.
sub GithubExport_Grep {
    my ($files, $pattern, $lines) = @_;
    my $re = eval { qr/$pattern/i };
    return () if(!$re);
    my @buf;
    foreach my $f (@$files) {
        open(my $fh, "<", $f) or next;
        binmode($fh);
        while(my $l = <$fh>) {
            next if($l !~ $re);
            chomp($l);
            push @buf, $l;
            shift @buf if($lines > 0 && @buf > $lines);
        }
        close($fh);
    }
    return @buf;
}

sub GithubExport_Shorten {
    my ($line, $cols) = @_;
    return $line if(!$cols || length($line) <= $cols);
    return substr($line, 0, $cols) . " \xE2\x80\xA6[gekuerzt]";
}

# Der Byte-Deckel schneidet mitten in einer Zeile ab; eine angebrochene
# erste Zeile (kein Zeitstempel am Anfang) fliegt danach raus.
sub GithubExport_Cap {
    my ($text, $max, $anfang) = @_;
    return $text if(!$max || length($text) <= $max);
    $text = substr($text, length($text) - $max);
    $text =~ s/^[^\n]*\n// if($anfang && $text !~ $anfang);
    return $text;
}

# Token, Passwoerter und Zugangsdaten in URLs raus, bevor etwas ins Repo
# geht. Dieselben Regeln wie in fhem-backup.sh, plus GitHub-Token.
sub GithubExport_Sanitize {
    my ($t) = @_;
    $t =~ s#(bot)[0-9]{6,}:[A-Za-z0-9_\-]{20,}#$1<TOKEN>#g;
    $t =~ s#(gh[pousr]_)[A-Za-z0-9]{20,}#$1<TOKEN>#g;
    $t =~ s#(github_pat_)[A-Za-z0-9_]{20,}#$1<TOKEN>#g;
    $t =~ s#([?&](token|apikey|api_key|apiKey|key|password|passwd|pwd|secret|auth|access_token)=)[^&\s"']+#$1<GEHEIM>#gi;
    $t =~ s#(https?://)[^:/\s]+:[^\@\s]+\@#$1<BENUTZER:PASSWORT>\@#g;
    return $t;
}

# "./log/fhem-%Y-%V.log" -> "./log/fhem-*-*.log"
sub GithubExport_Glob {
    my ($pattern) = @_;
    $pattern =~ s/%[A-Za-z]/*/g;
    return $pattern;
}

sub GithubExport_LogFiles {
    my ($pattern) = @_;
    return sort grep { -f $_ } glob(GithubExport_Glob($pattern));
}

sub GithubExport_BlobSha {
    # Genau die SHA-1, die git dem Blob geben wuerde. Damit laesst sich vorab
    # sagen, ob eine Datei ueberhaupt hochgeladen werden muss.
    my ($data) = @_;
    return sha1_hex("blob " . length($data) . "\0" . $data);
}

sub GithubExport_Scrub {
    my ($cfg, $text) = @_;
    return $text if(!defined($text));
    my $tok = $cfg->{token};
    $text =~ s/\Q$tok\E/<TOKEN>/g if(defined($tok) && $tok ne "");
    return $text;
}

# ---------------------------------------------------------------- GitHub-API
sub GithubExport_Api {
    my ($cfg, $method, $path, $body) = @_;

    my %param = (
        url      => $cfg->{apiUrl} . $path,
        timeout  => $cfg->{httpTimeout},
        method   => $method,
        loglevel => 5,
        hideurl  => 1,
        header   => "Authorization: Bearer $cfg->{token}\r\n"
                  . "Accept: application/vnd.github+json\r\n"
                  . "X-GitHub-Api-Version: 2022-11-28\r\n"
                  . "Content-Type: application/json\r\n"
                  . "User-Agent: FHEM-GithubExport",
    );
    $param{data} = GithubExport_JsonEnc($body) if(defined($body));

    my ($err, $data) = HttpUtils_BlockingGet(\%param);
    my $code = $param{code} || 0;

    die GithubExport_Scrub($cfg, "$method $path: $err") . "\n"
        if(defined($err) && $err ne "");

    if($code < 200 || $code > 299) {
        my $msg = "";
        my $j = eval { GithubExport_JsonDec($data) };
        $msg = " - $j->{message}" if(ref($j) eq "HASH" && $j->{message});
        $msg .= " (Token fehlt das Recht 'contents: write' oder ist abgelaufen)"
            if($code == 401 || $code == 403);
        $msg .= " (Repository, Branch oder Pfad gibt es nicht)" if($code == 404);
        die "GitHub antwortet $code auf $method $path$msg\n";
    }

    return {} if(!defined($data) || $data !~ /\S/);
    return GithubExport_JsonDec($data);
}

# ---------------------------------------------------------------- Push
# Was liegt drueben? Repo (privat?), Branch-Spitze, Basis-Baum und die SHA
# jeder Datei darin. Push und Probelauf brauchen genau dasselbe.
sub GithubExport_Remote {
    my ($cfg) = @_;
    my $base = "/repos/$cfg->{owner}/$cfg->{repo}";

    my $repo = GithubExport_Api($cfg, "GET", $base);
    my %r = (
        base       => $base,
        private    => ($repo->{private} ? 1 : 0),
        visibility => ($repo->{private} ? "privat" : "oeffentlich"),
        defBranch  => ($repo->{default_branch} || ""),
        shas       => {},
    );

    my $ref = GithubExport_Api($cfg, "GET", "$base/git/ref/heads/$cfg->{branch}");
    $r{head} = $ref->{object}{sha};
    die "Branch '$cfg->{branch}' hat keinen Commit\n" if(!$r{head});

    my $commit = GithubExport_Api($cfg, "GET", "$base/git/commits/$r{head}");
    $r{tree} = $commit->{tree}{sha};

    # Der Baum sagt, was sich ueberhaupt geaendert hat. Ist er zu gross und
    # kommt abgeschnitten (truncated), gilt alles als geaendert - der
    # Vergleich der Baum-SHA beim Commit faengt das dann noch ab.
    my $tree = eval { GithubExport_Api($cfg, "GET", "$base/git/trees/$r{tree}?recursive=1") };
    if(ref($tree) eq "HASH" && ref($tree->{tree}) eq "ARRAY") {
        foreach my $e (@{$tree->{tree}}) {
            $r{shas}{$e->{path}} = $e->{sha} if(($e->{type} || "") eq "blob");
        }
    }
    return \%r;
}

# Welche der eingesammelten Dateien unterscheiden sich vom Repo?
sub GithubExport_Diff {
    my ($remote, $files) = @_;
    my @neu;
    foreach my $f (@$files) {
        $f->{sha} = GithubExport_BlobSha($f->{data});
        next if(defined($remote->{shas}{$f->{path}})
                && $remote->{shas}{$f->{path}} eq $f->{sha});
        push @neu, $f;
    }
    return @neu;
}

# Probelauf: alles bis zum Vergleich, aber kein Blob, kein Commit. Damit
# prueft "set <name> dryRun" auch gleich Token, Rechte und Branch.
sub GithubExport_Probe {
    my ($cfg, $files) = @_;
    my $remote = GithubExport_Remote($cfg);
    my @neu = GithubExport_Diff($remote, $files);
    my $bytes = 0;
    $bytes += length($_->{data}) foreach (@neu);

    return {
        ok         => 1,
        dryRun     => 1,
        visibility => $remote->{visibility},
        changed    => [ map { $_->{path} } @neu ],
        bytes      => $bytes,
        msg        => "Probelauf - nichts uebertragen",
    };
}

# Ein Commit ueber die Git-Data-API: Blobs, Baum, Commit, Ref. Alles oder
# nichts - anders als bei der Contents-API, die je Datei einen Commit macht.
sub GithubExport_Push {
    my ($cfg, $files) = @_;

    my $remote = GithubExport_Remote($cfg);
    die "Das Repository $cfg->{owner}/$cfg->{repo} ist OEFFENTLICH. fhem.cfg "
      . "und fhem.save enthalten Zugangsdaten im Klartext. "
      . "Wer das trotzdem will: attr $cfg->{name} allowPublicRepo 1\n"
        if(!$remote->{private} && !$cfg->{allowPublic});

    my $base = $remote->{base};
    my @neu  = GithubExport_Diff($remote, $files);

    return { ok => 1, changed => [], visibility => $remote->{visibility},
             msg => "unveraendert" } if(!@neu);

    my @entries;
    my @changed;
    my $bytes = 0;
    foreach my $f (@neu) {
        my $blob = GithubExport_Api($cfg, "POST", "$base/git/blobs", {
            content  => encode_base64($f->{data}, ""),
            encoding => "base64",
        });
        die "GitHub vergibt fuer $f->{path} eine andere Blob-SHA als errechnet\n"
            if($blob->{sha} && $blob->{sha} ne $f->{sha});

        push @entries, { path => $f->{path}, mode => "100644",
                         type => "blob",     sha  => $blob->{sha} || $f->{sha} };
        push @changed, $f->{path};
        $bytes += length($f->{data});
    }

    my $new = GithubExport_Api($cfg, "POST", "$base/git/trees",
                               { base_tree => $remote->{tree}, tree => \@entries });
    return { ok => 1, changed => [], visibility => $remote->{visibility},
             msg => "unveraendert" }
        if(($new->{sha} || "") eq $remote->{tree});

    my $body = {
        message => GithubExport_CommitMessage($cfg, scalar(@changed)),
        tree    => $new->{sha},
        parents => [ $remote->{head} ],
    };
    if($cfg->{authorName} =~ /\S/ && $cfg->{authorEmail} =~ /\S/) {
        $body->{author} = { name => $cfg->{authorName}, email => $cfg->{authorEmail} };
    }
    my $nc = GithubExport_Api($cfg, "POST", "$base/git/commits", $body);
    GithubExport_Api($cfg, "PATCH", "$base/git/refs/heads/$cfg->{branch}",
                     { sha => $nc->{sha} });

    return {
        ok         => 1,
        changed    => \@changed,
        commit     => substr($nc->{sha}, 0, 7),
        commitUrl  => "https://github.com/$cfg->{owner}/$cfg->{repo}/commit/$nc->{sha}",
        bytes      => $bytes,
        visibility => $remote->{visibility},
        msg        => scalar(@changed) . " Datei(en) uebertragen",
    };
}

sub GithubExport_CommitMessage {
    my ($cfg, $n) = @_;
    my $m = $cfg->{commitMessage};
    $m = 'Update %f - %t' if(!defined($m) || $m !~ /\S/);
    my %r = (
        '%f' => ($cfg->{folder} ne "" ? $cfg->{folder} : $cfg->{repo}),
        '%t' => strftime("%Y-%m-%d %H:%M:%S", localtime(time())),
        '%n' => $cfg->{name},
        '%c' => $n,
        '%b' => $cfg->{branch},
    );
    $m =~ s/(%[ftncb])/$r{$1}/g;
    return $m;
}

# ---------------------------------------------------------------- Ende
sub GithubExport_Done {
    my ($string) = @_;
    my ($name, $enc) = split(/\|/, $string, 2);
    my $hash = $defs{$name};
    return if(!$hash);

    delete($hash->{helper}{RUNNING_PID});

    my $res = eval { GithubExport_JsonDec(decode_base64($enc)) };
    $res = { ok => 0, error => "Antwort des Kindprozesses unlesbar" }
        if(ref($res) ne "HASH");

    my @dateien = @{ $res->{files} || [] };
    my $gesamt  = 0;
    $gesamt += ($_->{size} || 0) foreach (@dateien);

    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, "lastRun",      TimeNow());
    readingsBulkUpdate($hash, "lastDuration", $res->{duration}) if($res->{duration});
    readingsBulkUpdate($hash, "lastWarning",
        join(" | ", @{ $res->{warn} || [] })) if(defined($res->{warn}));
    readingsBulkUpdate($hash, "repoVisibility", $res->{visibility})
        if($res->{visibility});

    if(!$res->{ok}) {
        my $e = $res->{error} || "unbekannter Fehler";
        readingsBulkUpdate($hash, "state",     "Fehler");
        readingsBulkUpdate($hash, "lastError", $e);
        Log3($name, 2, "GithubExport ($name) Fehler: $e");

    } elsif($res->{dryRun}) {
        my %neu = map { $_ => 1 } @{ $res->{changed} || [] };
        readingsBulkUpdate($hash, "state",
            sprintf("Probelauf: %d Datei(en), %d neu/geaendert, %.0f kB",
                    scalar(@dateien), scalar(keys %neu), $gesamt/1024));
        # '*' markiert, was ein echter Export uebertragen wuerde.
        readingsBulkUpdate($hash, "preview", join("\n",
            map { sprintf("%s %s (%.1f kB)", ($neu{$_->{path}} ? "*" : " "),
                          $_->{path}, $_->{size}/1024) } @dateien));
        readingsBulkUpdate($hash, "lastChanged", scalar(keys %neu));
        readingsBulkUpdate($hash, "lastError", "");

    } else {
        my @ch = @{ $res->{changed} || [] };
        readingsBulkUpdate($hash, "lastError",   "");
        readingsBulkUpdate($hash, "lastFiles",   scalar(@dateien));
        readingsBulkUpdate($hash, "lastChanged", scalar(@ch));
        readingsBulkUpdate($hash, "lastChangedFiles",
            substr(join(", ", @ch), 0, 900));
        if(@ch) {
            readingsBulkUpdate($hash, "lastCommit",    $res->{commit});
            readingsBulkUpdate($hash, "lastCommitUrl", $res->{commitUrl});
            readingsBulkUpdate($hash, "lastBytes",     $res->{bytes});
            readingsBulkUpdate($hash, "state",
                sprintf("ok: %d von %d Datei(en), %s", scalar(@ch),
                        scalar(@dateien), $res->{commit}));
            Log3($name, 3, "GithubExport ($name) $res->{commit}: "
                         . join(", ", @ch));
        } else {
            readingsBulkUpdate($hash, "state", "unveraendert");
        }
    }
    readingsEndUpdate($hash, 1);
}

sub GithubExport_Aborted {
    my ($hash) = @_;
    return if(ref($hash) ne "HASH");
    delete($hash->{helper}{RUNNING_PID});
    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, "state",     "Fehler");
    readingsBulkUpdate($hash, "lastError", "Zeit abgelaufen (attr timeout)");
    readingsBulkUpdate($hash, "lastRun",   TimeNow());
    readingsEndUpdate($hash, 1);
    Log3($hash->{NAME}, 2, "GithubExport ($hash->{NAME}) Zeit abgelaufen");
}

1;

=pod
=item helper
=item summary Sichert fhem.cfg, fhem.save, Module und Log-Auszuege per Token nach GitHub
=item summary_DE Sichert fhem.cfg, fhem.save, Module und Log-Auszuege per Token nach GitHub
=begin html

<a name="GithubExport"></a>
<h3>GithubExport</h3>
<ul>
  Sichert die FHEM-Konfiguration in ein GitHub-Repository &ndash; aus FHEM
  heraus, ueber die GitHub-API mit einem Zugriffs-Token. Es braucht
  <b>kein installiertes git</b>, <b>keinen lokalen Klon</b> und kein
  Shell-Skript; der ganze Lauf steckt in einem <code>BlockingCall</code>,
  FHEM blockiert also nicht.
  <br><br>

  Was gesichert wird, gibt man beim Aufruf mit:
  <br><br>
  <code>set myExport export cfg state modules log filelog:bewaesserung</code>
  <br><br>

  Alle Dateien eines Laufs landen in <b>einem</b> Commit. Unveraenderte
  Dateien werden gar nicht erst hochgeladen: das Modul rechnet die
  Blob-SHA jeder Datei selbst aus (dieselbe, die git vergeben wuerde) und
  vergleicht sie mit dem Baum im Repository. Aendert sich nichts, entsteht
  auch kein Commit.
  <br><br>

  <a name="GithubExportdefine"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; GithubExport &lt;owner&gt;/&lt;repo&gt; [&lt;zielordner&gt;]</code>
    <br><br>
    <code>define myExport GithubExport ahlers2mi/FHEM-Instanz Main</code>
    <br><br>
    Der Zielordner ist das Verzeichnis <i>im Repository</i>, unter dem alles
    abgelegt wird (<code>Main/fhem.cfg</code>, <code>Main/FHEM/99_myUtils.pm</code>,
    <code>Main/log/fhem-tail.log</code> &hellip;). Ohne Angabe wird der Hostname
    benutzt; <code>.</code> legt direkt in die Wurzel des Repositorys.
    <br><br>
    Danach einmalig den Token hinterlegen:
    <br>
    <code>set myExport token ghp_&hellip;</code>
    <br><br>
    Der Token wird ueber <code>setKeyValue</code> abgelegt, steht also
    <b>nicht</b> in der <code>fhem.cfg</code>. Ein Fine-grained Token braucht
    fuer das Repository das Recht <b>Contents: Read and write</b>, ein
    klassischer Token den Bereich <code>repo</code>.
  </ul>
  <br>

  <a name="GithubExportset"></a>
  <b>Set</b>
  <ul>
    <li><b>export [&lt;teile&gt;]</b> &ndash; sichert und pusht. Ohne Angabe
        gilt das Attribut <code>exportParts</code>. Moegliche Teile:
        <ul>
          <li><code>cfg</code> &ndash; <code>fhem.cfg</code></li>
          <li><code>state</code> &ndash; <code>fhem.save</code> (Pfad aus
              <code>attr global statefile</code>)</li>
          <li><code>modules</code> &ndash; die eigenen Module aus dem
              FHEM-Verzeichnis (<code>modulePattern</code>, Default
              <code>99_*.pm</code>)</li>
          <li><code>log</code> &ndash; <code>log/fhem-tail.log</code> (die
              letzten Zeilen) und <code>log/fhem-fehler.log</code> (auffaellige
              Zeilen aus allen Logdateien)</li>
          <li><code>freeze</code> &ndash; <code>log/fhem-freeze.log</code>, das
              neueste Freezemon-Protokoll</li>
          <li><code>filelog</code> &ndash; FileLog-Auszuege. Ohne Argument die
              Geraete aus <code>attr fileLogs</code>, sonst gezielt
              <code>filelog:&lt;geraet&gt;</code></li>
          <li><code>extra</code> &ndash; die Pfade aus <code>attr extraFiles</code></li>
          <li><code>all</code> &ndash; alles davon</li>
        </ul>
        Ein vorangestelltes <code>-</code> waehlt ab:
        <code>set myExport export all -state</code>
        </li>
    <li><b>dryRun [&lt;teile&gt;]</b> &ndash; sammelt alles ein und fragt das
        Repository ab, uebertraegt aber nichts. Damit laesst sich pruefen, ob
        Token, Rechte und Branch stimmen und was ein echter Export
        uebertragen wuerde (Reading <code>preview</code>, <code>*</code> =
        wuerde uebertragen).</li>
    <li><b>token &lt;wert&gt;</b> &ndash; Token hinterlegen (setKeyValue).</li>
    <li><b>deleteToken</b> &ndash; Token wieder loeschen.</li>
    <li><b>stop</b> &ndash; einen laufenden Export abbrechen.</li>
  </ul>
  <br>

  <a name="GithubExportget"></a>
  <b>Get</b>
  <ul>
    <li><b>parts</b> &ndash; erklaert die Teile und zeigt, was gerade
        eingestellt ist.</li>
    <li><b>token</b> &ndash; sagt, ob ein Token hinterlegt ist (ohne ihn
        auszugeben).</li>
    <li><b>version</b> &ndash; Version des Moduls.</li>
  </ul>
  <br>

  <a name="GithubExportattr"></a>
  <b>Attribute</b>
  <ul>
    <li><b>branch</b> &ndash; Ziel-Branch (Default <code>main</code>).</li>
    <li><b>targetFolder</b> &ndash; Ordner im Repository; ueberschreibt die
        Angabe aus dem <code>define</code>.</li>
    <li><b>fhemDir</b> &ndash; FHEM-Verzeichnis (Default
        <code>attr global modpath</code>).</li>
    <li><b>exportParts</b> &ndash; was <code>set export</code> ohne Angabe
        sichert (Default <code>cfg state modules log freeze</code>).</li>
    <li><b>interval</b> &ndash; Minuten fuer einen wiederkehrenden Export
        (0 oder nicht gesetzt = aus). Reading <code>nextRun</code>.</li>
    <li><b>saveBeforeExport</b> &ndash; vor dem Export ein FHEM-<code>save</code>
        ausfuehren (Default 1). Mit <code>attr global autosave 0</code>
        schreibt FHEM von sich aus weder <code>fhem.cfg</code> noch
        <code>fhem.save</code> &ndash; ohne <code>save</code> sichert man also
        den Stand vom letzten Mal.</li>
    <li><b>modulePattern</b> &ndash; Suchmuster fuer eigene Module, mehrere
        durch Leerzeichen (Default <code>99_*.pm</code>).</li>
    <li><b>extraFiles</b> &ndash; weitere Dateien, eine je Zeile, relativ zum
        FHEM-Verzeichnis oder absolut. Wildcards erlaubt, ein Ziel im
        Repository laesst sich mit <code>=&gt;</code> angeben:
        <br><code>FHEM/98_Meins.pm</code>
        <br><code>/etc/systemd/system/fhem.service =&gt; system/fhem.service</code></li>
    <li><b>logLines</b> (600), <b>logErrorLines</b> (300),
        <b>logFreezeLines</b> (400) &ndash; Umfang der Log-Auszuege.
        Bewusst klein: diese Dateien aendern sich bei jedem Lauf, jede
        Fassung bleibt als eigener Blob im Repository liegen.</li>
    <li><b>logMaxBytes</b> (120000) &ndash; harte Obergrenze je Auszug.</li>
    <li><b>logMaxCols</b> (300), <b>logFreezeMaxCols</b> (600) &ndash; Laenge
        je Zeile. Eine Freezemon-Meldung listet jeden laufenden Timer auf und
        wird bis zu 20 kB lang; ungekuerzt fressen ein paar solche Zeilen den
        ganzen Auszug.</li>
    <li><b>logErrorPattern</b> &ndash; Suchmuster fuer
        <code>fhem-fehler.log</code> (Perl-Regex, ohne Beachtung der
        Gross-/Kleinschreibung).</li>
    <li><b>fileLogs</b> &ndash; Geraetenamen fuer <code>filelog</code> ohne
        Argument, durch Leerzeichen getrennt (passend zum Dateinamen ohne
        Jahresteil: <code>bewaesserung-2026.log</code> &rarr;
        <code>bewaesserung</code>).</li>
    <li><b>fileLogLines</b> (6000), <b>fileLogMaxBytes</b> (400000) &ndash;
        Umfang der FileLog-Auszuege.</li>
    <li><b>fileLogNoise</b> &ndash; Zeilen, die vorher rausfliegen (Default
        <code>(remainingTime|pauseTimeRemaining): </code>). Countdown-Ticks
        machen in manchen Geraete-Logs 85 % der Zeilen aus und sagen nichts;
        ohne sie reicht derselbe Auszug viel weiter zurueck.</li>
    <li><b>sanitize</b> &ndash; Token, Passwoerter und Zugangsdaten in URLs in
        den Log-Auszuegen ersetzen (Default 1). Betrifft <b>nur</b> die
        Log-Auszuege &ndash; <code>fhem.cfg</code> und <code>fhem.save</code>
        gehen unveraendert ins Repository.</li>
    <li><b>allowPublicRepo</b> &ndash; in ein oeffentliches Repository pushen
        (Default 0, also nein). <code>fhem.cfg</code> und
        <code>fhem.save</code> enthalten Zugangsdaten im Klartext; das Modul
        fragt die Sichtbarkeit vor jedem Push ab und verweigert sonst.</li>
    <li><b>maxFileSize</b> &ndash; Dateien darueber werden uebersprungen
        (Default 5000000 Bytes), mit Hinweis in <code>lastWarning</code>.</li>
    <li><b>commitMessage</b> &ndash; Default <code>Update %f - %t</code>.
        Platzhalter: <code>%f</code> Ordner, <code>%t</code> Zeitpunkt,
        <code>%n</code> Geraetename, <code>%c</code> Anzahl Dateien,
        <code>%b</code> Branch.</li>
    <li><b>authorName</b>, <b>authorEmail</b> &ndash; Autor des Commits. Ohne
        Angabe nimmt GitHub den Besitzer des Tokens.</li>
    <li><b>apiUrl</b> &ndash; Default <code>https://api.github.com</code>
        (fuer GitHub Enterprise anpassen).</li>
    <li><b>httpTimeout</b> (60) &ndash; Sekunden je API-Aufruf.</li>
    <li><b>timeout</b> (300) &ndash; Sekunden, nach denen der ganze Lauf
        abgebrochen wird.</li>
    <li><b>disable</b> &ndash; 1 schaltet Export und Zeitplan ab.</li>
  </ul>
  <br>

  <a name="GithubExportreadings"></a>
  <b>Readings</b>
  <ul>
    <li><b>state</b> &ndash; <code>Export laeuft</code> /
        <code>ok: x von y Datei(en), &lt;sha&gt;</code> /
        <code>unveraendert</code> / <code>Probelauf: &hellip;</code> /
        <code>Fehler</code></li>
    <li><b>lastRun</b>, <b>lastDuration</b> &ndash; Zeitpunkt und Dauer des
        letzten Laufs (Sekunden)</li>
    <li><b>lastCommit</b>, <b>lastCommitUrl</b> &ndash; kurze SHA und Link</li>
    <li><b>lastFiles</b> &ndash; eingesammelte Dateien,
        <b>lastChanged</b> &ndash; davon uebertragene,
        <b>lastChangedFiles</b> &ndash; deren Namen,
        <b>lastBytes</b> &ndash; uebertragene Bytes</li>
    <li><b>lastParts</b> &ndash; womit der Lauf angestossen wurde</li>
    <li><b>lastWarning</b> &ndash; fehlende, zu grosse oder unlesbare Dateien.
        <b>Hier zuerst nachsehen</b>, wenn etwas nicht im Repository
        auftaucht: ein Lauf ist auch dann "ok", wenn einzelne Quellen
        gefehlt haben.</li>
    <li><b>lastError</b> &ndash; Fehlertext des letzten Laufs</li>
    <li><b>preview</b> &ndash; Ergebnis von <code>dryRun</code></li>
    <li><b>repoVisibility</b> &ndash; <code>privat</code> /
        <code>oeffentlich</code></li>
    <li><b>nextRun</b> &ndash; naechster Lauf laut <code>interval</code></li>
    <li><b>token</b> &ndash; <code>hinterlegt</code> / <code>keiner</code>
        (nie der Token selbst)</li>
  </ul>
  <br>

  <b>Beispiel</b>
  <ul>
    <code>
      define myExport GithubExport ahlers2mi/FHEM-Instanz Main<br>
      set myExport token ghp_&hellip;<br>
      attr myExport fileLogs bewaesserung<br>
      attr myExport interval 25<br>
      attr myExport exportParts cfg state modules log freeze<br>
      <br>
      # einmal pruefen, ohne etwas zu uebertragen<br>
      set myExport dryRun all<br>
      <br>
      # einmalig auch die Geraete-Logs mitnehmen<br>
      set myExport export cfg state filelog:bewaesserung<br>
    </code>
  </ul>
</ul>

=end html
=cut
