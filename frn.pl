#!/usr/bin/env perl
use strict;
use warnings;

use Getopt::Long;
use File::HomeDir;
use File::Basename;
use WWW::Curl::Easy;

# parse options & load config
$|=1;
my %config;
my $self = \%config;
Getopt::Long::Configure('bundling');
GetOptions('mp3|a|all' => \$self->{mp3}, 'debug|d|v' => \$self->{debug}, 'p|play' => \$self->{play}, 'n|news:2' => \$self->{play},
		'search|s=s@' => \&search, 'help|h|?' => \&help);
check_config();
show_config() if ($config{debug});

## main
play_all() if ($config{play});

# if called without arguments we only download index + info pages
update_index() || die "Could not find out last entry.\n";
fetch_all($config{'last'}); # TODO evaluate return value
exit 0;

## subs
sub debug { print shift if ($config{debug}); }
sub help {
  # TODO use help interface of Getopt::Modular (https://metacpan.org/pod/release/DMCBRIDE/Getopt-Modular-0.13/lib/Getopt/Modular.pm)
  print "This script downloads index and files from freie-radios.net, german political audio news. If called without arguments it only downloads index + info pages.
\t-a -all mp3\tload all mp3 files
\t-d -debug debug\tshows all connection status messages
\t-p -play play\tplays downloaded files
\t-n -news news\tstarts playing with youngest entries
\t-h -help help\tshow this help\n";
  exit;
}
sub do_config {
  $config{'datadir'} ||= '';
  do {
    print "Where to save mp3 and html files? Leave empty to store it in $config{'dir'} [$config{'data'}] ";
    chomp(my $datadir = <STDIN>);
    unless ($datadir) { $config{'datadir'} = $config{'dir'}; }
    elsif (! -d $datadir) {
      if (mkdir $datadir) { $config{'datadir'} = $datadir; }
      else { warn "Could not create '$datadir': $!\n"; }
    }
  } until ($config{'datadir'});
  open my $fh, '>', "$config{'dir'}/config" or die "Could not save '$config{'dir'}/config': $!\n";
  print $fh "datadir=$config{'datadir'}\n";
  close $fh;
  return 1;
}

sub check_config {
  # set default options - TODO publish in the README
  $config{'dir'} ||= home().'/.frn';
  $config{'url'} = "http://www.freie-radios.net";
  $config{'index'} ||= 'index.html';

  # config dif
  mkdir $config{'dir'} unless (-d $config{'dir'});

  unless (-f "$config{'dir'}/config") { # create new config if necessary
    do_config or die "Could not create '$config{'dir'}/config'.\n";
  }

  # read config
  open my $fh, '<', "$config{dir}/config" or die "Could not open '$config{dir}/config': $!\n";
  foreach (<$fh>) { 
    if (/^(.+)=(.+)$/) {
      $config{$1} = $2;
    }
  } close $fh;

  # prepare datadir
  mkdir $config{datadir} unless (-d $config{datadir});
  foreach (qw/html mp3/) {
    unless (-d "$config{datadir}/$_") {
      mkdir "$config{datadir}/$_" or die "Failed to create '$config{datadir}/$_': $!\n";
    }
  }
}

sub show_config {
  map { print "$_:\t". (($self->{$_}) ? $self->{$_} : 'undef') ."\n"; } qw/debug play mp3 url dir datadir/;
}

sub search {
  # TODO search for strings in database
}

sub play_all {
  # TODO search & grep
  my $dir = "$config{'datadir'}/mp3";
  die "Could not find '$dir'.\n" unless (-d $dir);
  my @list = ($config{news}) ? qx{ls -1 --sort time $dir/*.mp3} : glob("$dir/*.mp3");
  foreach (@list) {
    chomp();
    if (/\/(\d+-\w+-\d+\.mp3)$/) { play_mp3($_); }
    else { debug("Bad scheme: $_\n"); }
  }
  exit;
}

sub play_mp3 {
  my $mp3 = shift;# || warn "play_mp3(): no file given.\n" and return;
  print "\rPlaying $mp3 ";
  system "mplayer -really-quiet $mp3 2>/dev/null"; print "\n";
  sleep 1; # give the user a chance to CTRL+C or read the filename if mplayer has issues
}

sub update_index {
  #unless (-f $config{index}) { # TODO fetch only if age > 1d?
    print "Refreshing index ";
    fetch($config{'url'}, $config{'index'});
  #}

  # load index.html
  open my $fh, '<', $config{'index'} or warn "Could not load '$config{'index'}': $!\n" and return;
  foreach (<$fh>) {
    if (/class="btitel"><a href="\/(\d+)">/) {
      print "\rLatest entry: $1\n";
      close $fh;
      $config{'last'} = $1;
      return 1;
    }
  } close $fh;
  die "Could not find latest entry in $config{'index'}.\n";
}

sub fetch {
  my ($url, $fn) = @_;
  defined($url) or die "fetch(): no url supplied.\n";

  my ($try);
  do {

    debug "[Curl] ";
    my $curl = WWW::Curl::Easy->new;
    $curl->setopt(CURLOPT_HEADER,1);
    $curl->setopt(CURLOPT_URL, $url);

    # A filehandle, reference to a scalar or reference to a typeglob can be used here.
    my $response;
    $curl->setopt(CURLOPT_WRITEDATA,\$response);

    # Starts the actual request
    my $retcode = $curl->perform;

    # Looking at the results...
    if ($retcode == 0) {

      #my $response_code = $curl->getinfo(CURLINFO_HTTP_CODE);
      debug("ok.\n");

      if ($fn) { return save($fn, $response); }
      else { return $response; }

    } else {
      # Error code, type of error, error message
      print("[$try] $retcode ".$curl->strerror($retcode)." ".$curl->errbuf."\n");
    }

    sleep 1; # give user a chance to cancel when network interface disappeared etc.
  } while ($try <=5);

  if ($try >=5) { print "Giving up for '$url'.\n"; }
}

sub save {
  my ($fn, @data) = @_;
  return unless (defined($fn));

  open my $fh, '>', $fn or die "could not write to '$fn': $!\n";
  print $fh @data;
  close $fh;
}

sub parse {
  my $file = shift or die "parse(): no or empty filename given\n";
  open my $fh, '<', $file or warn "Could not read '$file': $!\n" and return;
  my @urls;

  foreach (<$fh>) {
    if (/Beitrag nicht gefunden./ && $file =~ /(\d+)\.html/) { noentry($1); return; }
    elsif (/<a href="(.+\.mp3)">Download<\/a>/) {
      my $url = $1;
      debug "Found mp3: $1.\n";
      unless ($url =~ /^http/) { $url = "$config{url}$url"; }
      push(@urls,$url);
    } elsif (/<td><h2 class="btitel_restricted">([^<]+)<\/h2><\/td>/) {
      print "$1\n";
      # TODO add to db
    } elsif (/<td colspan="2">([^<]+)<\/td>/) {
      # TODO add to db
    }
  } close $fh;
  return @urls;
}

sub noentry {
  # We save the number of parsed html files in 'noentry' when they contain no entry.
  # If this file is deleted, all cached html files are reparsed on the next run.
  # If also the html cache has been deleted, we need to redownload all index files again.
  # TODO create db file with titles, descriptions and mp3 urls.
  my $id = shift or warn "failed(): no id given\n" and return;
  return unless ($id =~ /(\d+)/);
  open my $fh, '>> noentry' or die "Could not write to 'noentry': $!\n";
  print $fh "$1\n";
  close $fh;
  return 1;
}

sub fetch_all { # retrieve html + mp3
  my $entry = shift // $config{'last'};

  # load list of known ids that contain no entry
  if (open my $missing, '< noentry') { 
    /(\d+)/ && $config{noentry}{$1}++ while <$missing>; # thanks to tm604!
    close $missing;
  } else { warn "\rCould not open 'failed': $!\n"; }

  # start downloads
  while ($entry >0) {
    if ($config{noentry}{$entry}) { $entry--; next; } # is handy if html cache got lost

    print "\r$entry ";
    my $htmlfile = "html/$entry.html";
    # TODO try to run multiple downloads in parallel
    fetch("$config{url}/$entry" , $htmlfile) unless (-f $htmlfile);

    if ($config{mp3}) { # should we download mp3 files also?
      foreach my $url (parse($htmlfile)) {
        my $fn = basename($url);
        # TODO check if the file is only partially downloaded
        unless (-f "mp3/$fn") {
          print "$url > $fn ";
          fetch($url, "mp3/$fn");
          print "\n";
          sleep 1;
        }
      }
    } $entry--;
  }

  print "\rSeemes as we downloaded all entries.\n"; 1;
}
__END__
# Thanks #perl for the good hints!
# 0. http://perl-begin.org/tutorials/bad-elements/
# 1. FIXED if code needs to be read bottom up, it may improve from a re-arrangement
# 2. you need more empty lines. some of the lines are too long. there should be some empty lines inside subroutines too. separating paragraphs.
# 3. FIXED don't call subs with &. pretty sure everyone agrees that 'use subs' is obsolete, and call subs without &. you don't need use subs either. it actually does nothing if you always call subs with parenthesis. composing into subs is fine, even if they're each called just once. if there's an obvious partial problem that can be solved independently, that's a strong invitation to make it a reasonably named sub
# 4. FIXED you have a global %config variable. Maybe you want a class. that's not needed and I'm sure he doesn't want a class for such a script. the "ua" does not belong in %config. mst: I tend to use methods on an object so the config is in $self
# 5. FIXED sub parse_options ==> this should be done using Getopt::Long
# 6. FIXED how much do you trust these MP3s? you're trusting that they aren't named `rm -rf ~`, for a start
# 7. FIXED might also want to fix those 2-arg opens and the map-with-side-effects. for the latter, I'd suggest something like /(\d+)/ && $config{noentry}{$1}++ while <$missing>; perhaps
# 8. FIXED you don't need line 83, the maps on lines 84+86 should be for loops instead
# 9. FIXED if you're working with config/data paths, there's a few modules which may help - File::HomeDir, for example (same for reading/saving config files)
# 10. FIXED also Perl has File::Basename, no need to get the shell to do it for you
# 11. FIXED it's not a good idea to chdir
# 12. FIXED plus that HTTP::Thin / LWP::UserAgent / LWP::Simple trifecta of HTTP modules may cause a raised eyebrow for the next person to be maintaining this code
