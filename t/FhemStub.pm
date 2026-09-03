# FHEM-Attrappe fuer die Tests unter t/ - genug, damit 98_GithubExport.pm
# laeuft, ohne eine FHEM-Installation zu brauchen.
#
# gh_request ist hier ein kleines Nach-GitHub: es beantwortet die Aufrufe der
# Git-Data-API aus einem Zustand im Speicher und schreibt jeden Aufruf mit.
# Damit laesst sich pruefen, WAS das Modul hochlaedt - und vor allem, was es
# NICHT hochlaedt. Eingehaengt wird es in run.pl anstelle von
# GithubExport_Request, also unterhalb der Kopfzeilen-Erzeugung: die wird damit
# mitgeprueft.
package main;

use strict;
use warnings;
use Digest::SHA qw(sha1_hex);

our %defs;
our %attr;
our %modules;
our $init_done = 1;
our $readingFnAttributes = "event-on-change-reading";
our $NOW = 1_700_000_000;

our @LOG;          # [level, text]
our @TIMER;        # [zeit, funktion]
our %KEYVALUE;     # setKeyValue/getKeyValue
our @CMD;          # AnalyzeCommandChain

# --- Nach-GitHub -------------------------------------------------------------
our @HTTP;         # [method, url, data]  - jeder Aufruf
our %GH;           # Zustand des erfundenen Repositorys

sub gh_reset {
    my (%o) = @_;
    @HTTP = ();
    %GH = (
        private => (exists($o{private}) ? $o{private} : 1),
        head    => "1111111111111111111111111111111111111111",
        tree    => "2222222222222222222222222222222222222222",
        blobs   => ($o{blobs} || {}),      # pfad => sha
        newTree => "3333333333333333333333333333333333333333",
        commit  => "abcdef7890123456789012345678901234567890",
        fail    => $o{fail},               # [code, text] statt Antwort
        truncated => ($o{truncated} ? 1 : 0),
    );
}

sub gh_blob_sha { return sha1_hex("blob " . length($_[0]) . "\0" . $_[0]); }

sub gh_posted_blobs {
    return scalar(grep { $_->[0] eq "POST" && $_->[1] =~ m{/git/blobs$} } @HTTP);
}
sub gh_call {
    my ($method, $re) = @_;
    return scalar(grep { $_->[0] eq $method && $_->[1] =~ $re } @HTTP);
}

sub gh_request {
    my ($cfg, $m, $u, $kopf, $data) = @_;
    push @HTTP, [$m, $u, $data, join("\r\n", @$kopf)];

    return ($GH{fail}[0], main::gh_json({ message => $GH{fail}[1] })) if($GH{fail});

    my $r;
    if   ($u =~ m{/repos/[^/]+/[^/]+$})            { $r = { private => $GH{private}, default_branch => "main" }; }
    elsif($u =~ m{/git/ref/heads/})                { $r = { object => { sha => $GH{head} } }; }
    elsif($u =~ m{/git/commits/})                  { $r = { tree => { sha => $GH{tree} } }; }
    elsif($u =~ m{/git/trees/\w+\?recursive})      {
        $r = { truncated => ($GH{truncated} ? JSON::PP::true() : JSON::PP::false()),
               tree => [ map { { path => $_, type => "blob", sha => $GH{blobs}{$_} } }
                         sort keys %{$GH{blobs}} ] };
        $r->{tree} = [] if($GH{truncated});
    }
    elsif($m eq "POST" && $u =~ m{/git/blobs$})    {
        my $j = main::gh_unjson($data);
        require MIME::Base64;
        $r = { sha => gh_blob_sha(MIME::Base64::decode_base64($j->{content})) };
    }
    elsif($m eq "POST" && $u =~ m{/git/trees$})    { $r = { sha => $GH{newTree} }; }
    elsif($m eq "POST" && $u =~ m{/git/commits$})  { $r = { sha => $GH{commit} }; }
    elsif($m eq "PATCH" && $u =~ m{/git/refs/})    { $r = { ref => "refs/heads/main" }; }
    else { return (404, main::gh_json({ message => "Not Found" })); }

    return (200, main::gh_json($r));
}

{
    my $j;
    sub gh_j { require JSON::PP; $j ||= JSON::PP->new->utf8->allow_nonref; return $j; }
}
sub gh_json   { return gh_j()->encode($_[0]); }
sub gh_unjson { return gh_j()->decode($_[0]); }

# --- FHEM-Grundfunktionen -----------------------------------------------------
BEGIN { *CORE::GLOBAL::time = sub { return $main::NOW; }; }
sub gettimeofday { return $NOW; }
sub TimeNow { return "2026-09-03 12:00:00"; }

sub Log3 { my ($n, $l, $t) = @_; push @LOG, [$l, $t]; return undef; }

sub AttrVal {
    my ($d, $a, $def) = @_;
    return (defined($attr{$d}) && defined($attr{$d}{$a})) ? $attr{$d}{$a} : $def;
}
sub ReadingsVal {
    my ($d, $r, $def) = @_;
    return (defined($defs{$d}) && defined($defs{$d}{READINGS}{$r}))
        ? $defs{$d}{READINGS}{$r}{VAL} : $def;
}
sub IsDisabled { my ($n) = @_; return AttrVal($n, "disable", 0) ? 1 : 0; }

sub readingsBeginUpdate { return 1; }
sub readingsEndUpdate   { return 1; }
sub readingsBulkUpdate {
    my ($hash, $r, $v) = @_;
    $hash->{READINGS}{$r}{VAL} = $v;
    return 1;
}
sub readingsSingleUpdate { return readingsBulkUpdate(@_); }

sub InternalTimer { my ($t, $f, $h) = @_; push @TIMER, [$t, $f]; return 1; }
sub RemoveInternalTimer {
    my ($h, $f) = @_;
    @TIMER = grep { defined($f) ? $_->[1] ne $f : 0 } @TIMER;
    return 1;
}

sub setKeyValue { my ($k, $v) = @_; defined($v) ? ($KEYVALUE{$k} = $v) : delete($KEYVALUE{$k}); return undef; }
sub getKeyValue { my ($k) = @_; return $KEYVALUE{$k}; }

sub AnalyzeCommandChain { my ($cl, $c) = @_; push @CMD, $c; return undef; }

our @BLOCKING;   # [fn, arg, finish]
sub BlockingCall {
    my ($fn, $arg, $finish, $to, $abort, $aarg) = @_;
    push @BLOCKING, [$fn, $arg, $finish];
    return { pid => 4711 };
}
sub BlockingKill { return 1; }

1;
