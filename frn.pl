#!/usr/bin/env perl
use strict;
use warnings;
use LWP::Simple;
use LWP::UserAgent;
use 5.12.1;
use HTTP::Request::Common;
use HTTP::Thin;
use subs qw/debug help parse_options do_config check_config play_all play update_index fetch_all fetch save parse noentry/;
my %config = (url => "http://freie-radios.net", ua => LWP::UserAgent->new);
$config{ua}->timeout(60); # failed try to reduce LWP CPU consumption.
$config{ua}->add_handler( response_header => sub { 
	my($response, $ua, $h) = @_;
        my $size = $response->{'_headers'}{'content-length'};
        debug "size=$size " if ($size);
        $h->cancel; # we only this request to find out file size
	} );
$|=1;

## subs
sub debug {
  print shift if ($config{debug});
}
sub help {
  print "This script downloads index and files from freie-radios.net, german political audio news. If called without arguments it only downloads index + info pages.
\t-a -all mp3\tload all mp3 files
\t-d -debug debug\tshows all connection status messages
\t-p -play play\tplays downloaded files
\t-n -news news\tstarts playing with youngest entries
\t-h -help help\tshow this help\n";
  exit;
}
sub parse_options {
  foreach (@_) { # if called without arguments we only download index + info pages
    # TODO implement parsing for -and to verbosely download audio files and immedidately play them
    if (/-a|-all|mp3/) { $config{mp3}++; } # load all mp3 files
    elsif (/-d|-debug|debug/) { $config{debug}++; } # shows all connection status messages
    elsif (/-n|-news|news/) { $config{play}++; $config{news}++; } # starts playing with youngest entries
    elsif (/-p|-play|play/) { $config{play}++; }
    elsif (/-h|-help|help/) { &help; }
    elsif (/(\d+)/) { push(@{$config{search}}, $1); } # TODO search for strings in database
  }
}
sub do_config {
  $config{'datadir'} ||= '';
  do {
    print "Where should mp3 and html be files saved? Leave empty to store it in $config{'dir'} [$config{'datadir'}] ";
    chomp(my $datadir = <STDIN>);
    unless ($datadir) { $config{'datadir'} = $config{'dir'}; }
    elsif (! -d $datadir) {
      if (mkdir $datadir) { $config{'datadir'} = $datadir; }
      else { warn "Could not create '$datadir': $!\n"; }
    }
  } until ($config{datadir});
  open my $sconfig, '>', "$config{dir}/config" or die "Could not save '$config{dir}/config': $!\n";
  print $sconfig "datadir=$config{datadir}\n";
  close $sconfig;
}
sub check_config {
  $config{'dir'} ||= "$ENV{'HOME'}/.frn";
  $config{'index'} ||= 'index.html'; # TODO better publish this option
  mkdir $config{'dir'} unless (-d $config{'dir'});
  chdir "$config{dir}" || die "chdir $config{dir}: $!\n";
  &do_config unless (-f 'config');
  open my $lconfig, '<', "$config{dir}/config" or die "Could not open '$config{dir}/config': $!\n";
  foreach (<$lconfig>) {
    if (/^(.+)=(.+)$/) {
      $config{$1} = $2;
    }
  } close $lconfig;
  mkdir $config{datadir} unless (-d $config{datadir});
  chdir $config{datadir} or die "Could not access '$config{datadir}': $!\n";
  mkdir "html" unless (-d 'html');
  mkdir "mp3" unless (-d 'mp3');
}
sub play_all {
  # TODO search & grep
  if ($config{news}) {
    my @list = qx{ls --sort time mp3/*.mp3};
    exit unless (@list >0);
    map { chomp; play($_) if (/\.mp3$/); } @list;
  } else {
    my $list = join " ", glob('mp3/*');
    system "mplayer $list" if ($list);
  }
  exit;
}
sub play {
  my $mp3 = shift || die "play(): no file given.\n";
  print "\rPlaying $mp3.. ";
  system "mplayer -really-quiet $mp3 2>/dev/null";
  sleep 1; # give the user a chance the CTRL+C the main process between mplayer calls
}
sub update_index {
  if (1) { #unless (-f $config{index}) { # TODO check only if age > 1d?
    print "Fetching index..";
    save(fetch($config{url}), 'index.html');
  }
  # load index.html
  open my $lindex, '<', $config{'index'} or warn "Could not load '$config{'index'}': $!\n" and return;
  foreach (<$lindex>) {
    if (/class="btitel"><a href="\/(\d+)">/) {
      print "\rLast entry: $1\n";
      close $lindex;
      $config{'last'} = $1;
      return 1;
    }
  } close $lindex;
}
sub fetch {
  my $url = shift||die "fetch(): no url supplied.\n";
  my ($err, $res);
  do {
    debug "\rLoading $url.. ";
    my $req = HTTP::Request->new(GET => $url);
    debug "[LWP] ";
    $res = $config{ua}->request($req);
    debug "[Thin] ";
    $res = HTTP::Thin->new()->request(GET $url);
    unless ($res->is_success) { $err++;
      my $msg = $res->status_line;
      print "[$err] $msg ";
      if ($msg =~ /^599/) { print $res->content; }
      sleep 10;
    }
    else { debug "done.\n"; }
    sleep 1;
  } until ($res->is_success || $err >=5);
  if ($err >=5) { print "Giving up for '$url'.\n"; }
  $res;
}
sub save {
  my $res = shift|| die "save(): called with resource.\n";
  my $file = shift||return; # silently return because of possible failed download
  return unless ($res->is_success);
  open my $fh, "> $file" or die "could not write to '$file': $!\n";
  print $fh $res->as_string;
  close $fh;
  return 1;
}
sub parse {
  my $file = shift||die "parse(): no file given\n";
  open my $fh, '<', $file or warn "Could not read '$file': $!\n" and return;
  my @urls;
  foreach (<$fh>) {
    if (/Beitrag nicht gefunden./ && $file =~ /(\d+)\.html/) { &noentry($1); return; }
    elsif (/<a href="(.+\.mp3)">Download<\/a>/) {
      my $url = $1;
      debug "Found mp3: $1.\n";
      unless ($url =~ /^http/) { $url = "$config{url}$url"; }
      push(@urls,$url);
    } elsif (/<td><h2 class="btitel_restricted">([^<]+)<\/h2><\/td>/) {
      print "$1\n";
    } elsif (/<td colspan="2">([^<]+)<\/td>/) {
      # TODO save something
    }
  } close $fh;
  return @urls;
}
sub noentry {
  # we save the number of parsed html files in 'noentry' when they contain no entry
  # if this file is deleted, all cached html are reparsed on the next run
  # if also the html cache has been deleted, we need to redownload all index files again
  # TODO create db file with titles and mp3 urls
  my $id = shift||warn "failed(): no id given\n" and return;
  open my $noentry, '>> noentry' or die "Could not write to 'noentry': $!\n";
  print $noentry "$id\n";
  close $noentry;
  return 1;
}
sub fetch_all { # retrieve html + mp3
  my $entry = shift || $config{'last'};
  # load list of known ids that contain no entry
  if (open my $missing, "< noentry") { 
    map { $config{noentry}{$1}++ if (/(\d+)/) } <$missing>;
    close $missing;
  } else { warn "Could not open 'failed': $!\n"; }
  while ($entry >0) {
    debug "\r$entry\r";
    if ($config{noentry}{$entry}) { $entry--; next; }
    printf "\r%80s\r", '';
    print "\r$entry.html ";
    my $htmlfile = "html/$entry.html";
    unless (-f $htmlfile) {
      save(fetch("$config{url}/$entry") , $htmlfile);
    }
    if ($config{mp3}) { # should we download mp3 files also?
      foreach my $url (parse($htmlfile)) {
        chomp(my $file = qx{basename $url});
        # TODO check if the file is only partially downloaded
        unless (-f "mp3/$file") {
          print "$url > $file ";
          save(fetch($url), "mp3/$file") && print "\n";
          sleep 1;
        }
      }
    }
    $entry--;
  }
  print "\rSeemes as we downloaded all entries.\n";
  return 1;
}
#end subs

## main
&parse_options(@ARGV);
&check_config;
&play_all if ($config{play});
&update_index || die "Could not find out last entry.\n";
&fetch_all($config{'last'}); # TODO try to run multiple downloads in parallel
exit;
