#!/usr/bin/env perl
use strict;
use warnings;
use LWP::Simple;
use LWP::UserAgent;
my %config = (folder => '/home/dk/src/frn', url => "http://freie-radios.net", index => 'index.html', ua => LWP::UserAgent->new);
$config{ua}->timeout(60); # try to reduce CPU consumption
$|=1;
chdir "$config{folder}" || die "cd $config{folder}: $!\n";

# parse options
foreach (@ARGV) {
  if (/mp3/) { $config{mp3}++; }
  elsif (/debug/) { $config{debug}++; }
  elsif (/news/) { $config{play}++; $config{news}++; }
  elsif (/play/) { $config{play}++; }
  elsif (/(\d+)/) { push(@{$config{search}}, $1); }
}

## subs
sub debug {
  print shift if ($config{debug});
}
sub fetch {
  my $url = shift||die "fetch(): no url supplied.\n";
  my ($err, $res);
  do {
    debug "Loading $url.. ";
    my $req = HTTP::Request->new(GET => $url);
    $res = $config{ua}->request($req);
    print ".";
    unless ($res->is_success) { $err++; print "[$err] ". $res->status_line .' '; sleep 10; }
    else { debug " done.\n"; }
    sleep 1;
  } until ($res->is_success || $err >=5);
  $res;
}
sub save {
  my $res = shift||die "save(): called with resource.\n";
  my $file = shift||return; # possible failed download before
  return unless ($res->is_success);
  open INDEX, "> $file" or die "could not write to '$file': $!\n";
  print INDEX $res->as_string;
  close INDEX;
  return 1;
}
sub parse {
  my $file = shift||die "parse(): no file given\n";
  unless (open FILE, '<', $file) { warn "Could not read '$file': $!\n"; return; }
  my @urls;
  foreach (<FILE>) {
    if (/Beitrag nicht gefunden./ && $file =~ /(\d+)\.html/) { failed($1); return; }
    elsif (/<a href="(.+\.mp3)">Download<\/a>/) {
      my $url = $1;
      debug "Found mp3: $1.\n";
      unless ($url =~ /^http/) { $url = "$config{url}$url"; }
      push(@urls,$url);
    }
  } close FILE;
  return @urls;
}
sub failed {
  my $id = shift||die "failed(): no entry\n";
  open FAILED, ">> failed" or die "Could not write to 'failed': $!\n";
  print FAILED "$id\n";
  close FAILED;
  return 1;
}
#end subs

## main
# check folders
mkdir "html" unless (-d 'html');
mkdir "mp3" unless (-d 'mp3');
open MISSING, "< failed";
my @failed = <MISSING>;
close MISSING;

# play files if requested
if ($config{play}) {
  # TODO search & grep
  if ($config{news}) {
    my @list = qx{ls --sort time mp3/*.mp3};
    exit unless (@list >0);
    foreach my $mp3 (@list) {
      chomp ($mp3);
      print "\rPlaying $mp3.. ";
      system "mplayer -really-quiet $mp3 2>/dev/null";
      sleep 1;
    }
  } else {
    my $list = join " ", glob('mp3/*');
    system "mplayer $list" if ($list);
  }
  exit;
}

# update last entry
my @html;
if (1) { #unless (-f $config{index}) { # TODO check age
  print "Fetching index..";
  my $res = fetch($config{url});
  @html = split "\n", $res->as_string;
  save($res);
} else {
  open INDEX, "< $config{index}" or die "Could not load '$config{index}': $!\n";
  @html = <INDEX>;
  close INDEX;
}
my $entry = 0;
foreach (@html) {
  if (/class="btitel"><a href="\/(\d+)">/) {
    print "\rLast entry: $1\n";
    $entry = $1;
    last;
  }
}

# retrieving html + mp3
while ($entry >0) {
  my $htmlfile = "html/$entry.html";
  unless (grep {/$entry/} @failed) {
    print "\r$entry.html ";
    unless (-f $htmlfile) {
      save(fetch("$config{url}/$entry") , $htmlfile);
    }
    if ($config{mp3}) {
      foreach my $url (parse($htmlfile)) {
        chomp(my $file = qx{basename $url});
        unless (-f "mp3/$file") {
          print "$url > $file";
          save(fetch($url), "mp3/$file") && print "\n";
          sleep 1;
	  exit;
        }
      }
    }
  }
  $entry--;
} 
