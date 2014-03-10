#!/usr/bin/env perl
use strict;
use warnings;

use Getopt::Long;
use File::Basename;
use File::Glob ':glob';
use File::HomeDir;
use WWW::Curl::Easy;
use HTML::TokeParser::Simple;
use HTML::TreeBuilder::XPath;
use Try::Tiny;
use MP3::Info;
use IO::Handle;
STDOUT->autoflush(1);

# OPTIMIZE global container
my %config;
my $self = \%config;

# parse options
Getopt::Long::Configure('bundling');
GetOptions(
	'a|all|mp3' => \$self->{'download_files'},
	'i|index:0' => \$self->{'download_files'},
	'p|play:1' => \$self->{'play'},
	'n|news:2' => \$self->{'play'},
	's|search=s@' => \&search, # TODO
	'o|offline' => \$self->{'offline'},
	'd|debug:2' => \$self->{'verbose'},
	'v|verbose:1' => \$self->{'verbose'},
	'h|help|?' => \&help
);

sub help {
  # TODO use help interface of Getopt::Modular (https://metacpan.org/pod/release/DMCBRIDE/Getopt-Modular-0.13/lib/Getopt/Modular.pm)
  print <<"EOF";
This script downloads index and files from freie-radios.net, german political audio news. If called without arguments it only downloads index + info pages.
\t-a --all --mp3\tdownload mp3 files without playing
\t-p --play play\tplay downloaded files without updating
\t-n --news\tupdate index and play youngest entry after downloading
\t-i --index\tonly download index and entry descriptions (default behaviour)
\t-d --debug\tshow all connection status messages
\t-o --offline\toffline mode - no downloading
\t-h --help\tshow this help
EOF
  exit;
}

# parse additional arguments
while(my $arg = shift) {
  # < http://perl-begin.org/tutorials/bad-elements/
  # Some people use "^" and "$" in regular expressions to mean beginning-of-the-string or end-of-the-string.
  # However, they can mean beginning-of-a-line and end-of-a-line respectively using the /m flag which is confusing.
  # It's a good idea to use \A for start-of-string and \z for end-of-string always,
  # and to specify the /m flag if one needs to use "^" and "$" for start/end of a line.
  # \z is the end of the string always. \Z can be the end with an optional trailing newline removed.
  # <mst> damian conway really prefers \A and \Z but damian does such freaking crazy things with regexps
  #   the extra precision can be really important. I still use ^$ for anything not-heinously-complicated
  #   because it's more readable and still unambiguous provided you can see the end of the regexp and the
  #   lack of an 'm' flag. if I have a block that's mixed m// and s/// close together, I'll use the 'm'.
  # "The problem is that when a string is interpolated into a regular expression it is interpolated as a mini-regex,
  # and special characters there behave like they do in a regular expression. So if I input '.*' into the command line
  # in the program above, it will match all lines. This is a special case of code or markup injection."
  #   [http://shlomif-tech.livejournal.com/35301.html] - that's what \Q and \E protect against.
  if ($arg =~ /^play$/) { $self->{'play'}++; }
  elsif ($arg =~ /^news$/) { $self->{'play'} = 2; }
  elsif ($arg =~ /^all$/) { $self->{'download_all'}++; }
  else { die "You requested '$arg' but I don't know what this is.\n"; }
}

check_config();

## main

if ($config{play}) {

  my $dir = "$config{'datadir'}/mp3";
  die "Could not find '$dir'.\n" unless (-d $dir);

  if ($config{'play'} >=2) { # newest

    if ($config{'offline'}) {
      foreach (validate_mp3( qx{ls -1 --sort time $dir/*.mp3} ) ) {
        play_mp3($_);
      }

    } else { # start download and play mp3 in the meantime
      play_and_download($dir);
    }

  } else { # play all files in a row
    foreach (validate_mp3( glob("$dir/*.mp3") )) {
      play_mp3($_);
    }
  }
  exit;
} # /play

$self->{'offline'} and exit;

# if called without arguments we download index + all info pages
fetch_entries(1);
exit 0;

## subs

# OPTIMIZE
sub verbose { if ($config{verbose} ) { print shift; } }
sub debug { if ($config{verbose} >=2) { print shift; } }

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
  $config{'max_downloads'} ||= 1; # used for files
  $config{'retries'} ||= 5;

  # config dif
  mkdir $config{'dir'} unless (-d $config{'dir'});

  unless (-f "$config{'dir'}/config") { # create new config if necessary
    do_config or die "Could not create '$config{'dir'}/config'.\n";
  }

  # read config
  open my $fh, '<', "$config{'dir'}/config" or die "Could not open '$config{'dir'}/config': $!\n";
  while (my $line = <$fh>) { 
    if ($line =~ /^(.+)=(.+)$/) {
      $config{$1} = $2;
    }
  } close $fh;

  # prepare datadir
  mkdir $config{'datadir'} unless (-d $config{'datadir'});
  foreach (qw/html mp3/) {
    unless (-d "$config{'datadir'}/$_") {
      mkdir "$config{'datadir'}/$_" or die "Failed to create '$config{'datadir'}/$_': $!\n";
    }
  }
  if ($config{debug}) {
    foreach (qw/debug play mp3 url dir datadir/) {
      print "$_:\t". (($self->{$_}) ? $self->{$_} : 'undef') ."\n";
    }
  }
  return 1;
}

sub search {
  # TODO search for strings in database
  return;
}

sub play_and_download {
  my $dir = shift || "$config{'datadir'}/mp3";

  do {
    # start playback
    unless ($config{'mp3'}{'playing'}) {
      my @list = validate_mp3(qx{ls -1 --sort time $dir/*.mp3});
      my $index = $config{'mp3'}{'index'} ||0;
      if ($list[$index]) {
        play_mp3($list[$index], 1);
        $config{'mp3'}{'index'}++; # TODO cache this somewhere
      }
    }

    # start next download when slot is available
    while (check_downloads()) { fetch_entry(); }

    # status & timing
    status_line();
    sleep 1;
  } while ($config{'current_entry'} >0);
  # OPTIMIZE this one is similar to fetch_entries()
}

sub play_mp3 {
  my $mp3 = shift || (warn "play_mp3(): no file given.\n" and return);
  unless (-f $mp3) { warn "play_mp3(): $mp3: file not found.\n"; return; }
  my $background = shift||0;
  my $mp3info = get_mp3info($mp3) || die "$@\n";
  my $bg = ($background) ? ' &' : '';
  $config{'mp3'}{'playing'} = basename($mp3);
  $config{'mp3'}{'playtime'} = int($mp3info->{SECS});
  $config{'mp3'}{'starttime'} = time();
  status_line();

  # TODO enable user interaction to skip files
  system "mplayer -really-quiet $mp3 2>/dev/null$bg";

  sleep 1; # give the user a chance to CTRL+C or read the filename if mplayer has issues
  return $mp3;
}

sub validate_mp3 {
  my @list;
  foreach (@_) {
    chomp();
    if (/\/(\d+-\w+-\d+\.mp3)$/) { push @list, $_; }
    else { debug("Bad scheme: $_\n"); }
  }
  return @list;
}

sub update_index {
  my $fn = "$config{'datadir'}/$config{'index'}";

  # update index
  #fetch($config{'url'}, $fn);
  -f $fn or die "Could not find file '$fn'.\n";

  # parse index
  my $tree = HTML::TreeBuilder::XPath->new;
  $tree->parse_file($fn);

  # On the front page we want to find the first numeric link under td of @class="btitel" to find out the youngest entry.
  # xpath: table/tr/td/table/tr/td[@class="btitel"]/a
  # format: <td WIDTH="*" class="btitel"><a href="/62449">&quot;<DC>ber den eigenen K<F6>rper verf<FC>gen&quot; - Sondersendung zu internationalen Frauenkampftag</a></td>        </tr>

  my $a = $tree->findnodes('//td[@class="btitel"]/a')->[0];
  unless($a) { die "Could not find latest entry in $config{'index'}.\n"; }

  if ($a->attr('href') =~ /\/(\d+)$/) {
      $config{'last'} = $1;
      $tree->delete;
      return $1;
  } else { die "update_index(): Bad link format of '". $a->as_trimmed_text .' => '. $a->attr('href') ."'.\n"; }  
}

sub start_download {
  my $url = shift || return;
  my $fn = shift || return;
  my $id = basename($url);
  return if ($config{'downloads'}{$url});

  unless ($url =~ /^http/) { $url = "$config{'url'}$url"; }
  debug "\rStarting download: $url > $fn\n";
  open my $fh, '>', $fn or warn "Could not save '$fn': $!\n" and return;

  # create curl handle
  my $handle = WWW::Curl::Easy->new;
  $handle->setopt(CURLOPT_HEADER,1);
  $handle->setopt(CURLOPT_PRIVATE,$url);
  $handle->setopt(CURLOPT_URL, $url);
  $handle->setopt(CURLOPT_WRITEDATA, $fh);

  # TODO Would be great to check the file size before downloading.

    # Why am I using Curl rather then LWP?
    # I live with a very throttled mobile internet connection and found perl consuming 99% cpu
    # while loading mp3 files with LWP.

    # Thin was much better regarding CPU than LWP though but it broke without clear reason
    # and restarted several megabyte files from the beginning. So I rather hesitate to implement it.
 
    # [LWP] size=342 size=17624626 [Thin] [1] 599 Internal Exception Timed
    # out while waiting for socket to become ready for reading at /usr/share/perl/5.14/HTTP/Tiny.pm line 162

    # I got a nice html graph with NYTProf showing the connection was restarted *lots* of times internally
    # and IO::Socket::SSL ate about half of the 728s in total:
    #   spent 128s (101+27.3) within IO::Socket::SSL::_set_rw_error which was called 2181095 times, avg 59µs/call:
    #    2181091 times (101s+27.3s) by IO::Socket::SSL::generic_read at line 682, avg 59µs/call
    #   spent 418s (68.9+349) within Net::HTTP::Methods::my_read which was called 2182614 times, avg 192µs/call
    #   spent 522s (104+418) within Net::HTTP::Methods::read_entity_body which was called 2182616 times, avg 239µs/call
    # <mst> this comes back to "the internals of LWP are full of crack"

    # from WWW::Curl documentation:
    #   The standard Perl WWW module, LWP should probably be used in most cases to work with HTTP or FTP from Perl.
    #   However, there are some cases where LWP doesn't perform well. One is speed and the other is parallelism.
    #   WWW::Curl is much faster, uses much less CPU cycles and it's capable of non-blocking parallel requests.

  # add handle to pool
  unless ($config{'curlm'}) {
    $config{'curlm'} = WWW::Curl::Multi->new;
  }
  $config{'curlm'}->add_handle($handle);
  $config{'active_downloads'}++;
  status_line();

  # return handle for remote access
  %{$config{'downloads'}{$url}} = ( id => $id, handle => \$handle, file => $fn );
  return $url;
}

sub finish_download {
  my $url = shift||return;
  my $try = shift||0;
  my $curl = ${$config{'downloads'}{$url}{'handle'}};
  my $retcode = $curl->perform;

  # Looking at the results...
  if ($retcode == 0) {
    #my $response_code = $curl->getinfo(CURLINFO_HTTP_CODE);
    #debug("ok[$response_code].\n");

    # letting the curl handle get garbage collected, or we leak memory.
    delete $config{'downloads'}{$url};
    return 1;

  } else {
    my $fn = $config{'downloads'}{$url}{'fn'};

    unless ($try >= $config{'retries'}) {
      debug "\rRetrying download of $url ($retcode ".$curl->strerror($retcode)." ".$curl->errbuf .")\n";
      $config{'downloads'}{$url} = undef;
      start_download($url, $fn);
    }
    return;
  }
}

sub show_downloads {
  my @downloads = keys %{$config{'downloads'}};
  if (@downloads) {
    print "\r[". join(' | ', @downloads) ."]\n";
  }
}

sub check_downloads { # update our curl transfers
  # call this regularly to catch all received packets and send responses in time
  my $max = shift || $config{'max_downloads'};
  $config{'active_downloads'} ||= 0;

  my $active_transfers = ($config{'curlm'}) ? $config{'curlm'}->perform : 0;

  while ($active_transfers != $config{'active_downloads'}) {
    while (my ($url,$return_value) = $config{'curlm'}->info_read) {
      if ($url) {
        finish_download($url);
        $config{'active_downloads'}--;
        status_line();
      }      
    }
  }
  return ($max > $active_transfers ) ? 1 : 0;
}

sub status_line {
  my ($s,$m,$h) = localtime();
  my $time = sprintf "%02i:%02i:%02i", $h, $m, $s;
  $config{'active_downloads'}||=0;
  my $downloads = "$config{'active_downloads'}/$config{'max_downloads'} transfer(s)";
  my $entry = $config{'current_entry'} ? "$config{'current_entry'}/$config{'last'}" : '?';
  my $playing = 'no audio';
  if ($config{'mp3'}{'playing'}) {
    my $resttime = $config{'mp3'}{'playtime'} - (time() - $config{'mp3'}{'starttime'});
    unless ($resttime >0) {
      delete $config{'mp3'}{'playing'};
      delete $config{'mp3'}{'playtime'};
      delete $config{'mp3'}{'starttime'};
    } else {
      $playing = "$config{'mp3'}{'playing'} [${resttime}s]";
    }
  }
  print "\r[$time] $downloads | $entry | $playing";
}

sub fetch {
  my ($url, $fn) = @_;
  defined($url) or die "fetch(): no url supplied.\n";

  my $try = 1;
  do {
    debug "[Curl] ";
    finish_download(start_download($url, $fn), $try) and return 1;

    sleep 1; # give user a chance to cancel when network interface disappeared etc.
    $try++;

  } while ($try <= $config{'retries'});
  print "Giving up for '$url'.\n";
  return;
}

sub save {
  my ($fn, @data) = @_;
  return unless (defined($fn));

  open my $fh, '>', $fn or die "could not write to '$fn': $!\n";
  print $fh @data;
  close $fh;
  return 1;
}

sub parse_entry_html {
  my $file = shift or die "parse(): no or empty filename given\n";
  open my $fh, '<', $file or warn "Could not read '$file': $!\n" and return;
  my @urls;
  my $parser = HTML::TokeParser::Simple->new(handle => $fh);

  while (my $anchor = $parser->get_tag('a')) {
    next unless defined(my $href = $anchor->get_attr('href'));
    next unless ($href =~ /\.mp3$/);
    push @urls, $href;

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

sub fetch_entry {
  # check dir
  my $dir = $config{'datadir'};
  -d $dir or die "Could not find '$dir'.\n";

  unless ($config{'noentry'} && $config{'current_entry'}) {
    # load list of known ids that contain no entry
    if (open my $missing, '<', "$dir/noentry") { 
      /(\d+)/ && $config{'noentry'}{$1}++ while <$missing>; # thanks to tm604!
      close $missing;
    } else { warn "\rCould not open '$dir/noentry': $!\n"; }

    # refresh index
    unless ($config{'last'}) { update_index(); }
    $config{'current_entry'} ||= $config{'last'};
  }

  # if we are lucky there is an index of invalid entries
  while ($config{'noentry'}{ $config{'current_entry'} }) { $config{'current_entry'}--; }

  # what to download?
  my $entry = shift;
  $entry ||= $config{'current_entry'};
  status_line();

  # fetch html
  my $dir = $config{'datadir'};
  my $htmlfile = "$dir/html/$entry.html";

  unless (-f $htmlfile) {
    check_downloads(3) # OPTIMIZE we allow us to have three in parallel ignoring the user defined limit
      and start_download("$config{url}/$entry", $htmlfile) or return;
  }

  # fetch mp3
  if ($config{'download_files'}) {
    foreach my $url (parse_entry_html($htmlfile)) {
      # TODO check if the file is only partially downloaded
      my $fn = basename($url);
      unless (-f "mp3/$fn") {
        check_downloads() and start_download($url, $fn) or return;
      }
    }
  }
  $config{'current_entry'}--;
  return 1;
}

sub fetch_entries {
  my $all = shift;

  do { # start downloads
    # start next download when slot is available
    while (check_downloads()) { fetch_entry(); }

    # status & timing
    status_line();
    sleep 1;
  } while ($all && $config{'current_entry'}>0);

  print "\rSeemes as we downloaded all entries.\n" unless ($config{'current_entry'} >0); 
  return 1;
}
__END__
# Thanks #perl for the hints!
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
# 13. FIXED and bonus points for parsing HTML with regex, of course. Don't parse or modify html with regular expressions! See Mojo::DOM or one of HTML::Parser's subclasses. For a Feb-2014 coverage of main techniques see: http://xrl.us/bqnfh7 . If your response begins with "that's overkill. i only want to..." you are wrong. http://en.wikipedia.org/wiki/Chomsky_hierarchy and http://xrl.us/bf4jh6 for why not to use regex on HTML.

helpful modules for HTML files:
* HTML::TokeParser::Simple - interface to access HTML nodes
* HTML::TreeBuilder - builds a tree representation of HTML documents
* HTML::TreeBuilder::XPath adds the ability to locate nodes in that representation using XPath expressions
* HTML::Strip - rip off any HTML tags to deliver pure text

< http://programming.oreilly.com/2014/02/parsing-html-with-perl-2.html
Both HTML::TokeParser::Simple (based on HTML::PullParser) and HTML::TableExtract (which subclasses HTML::Parser parse a stream rather than loading the entire document to memory and building a tree. 
Mojo::DOM is an excellent module that uses JQuery style selectors to address individual elements http://stackoverflow.com/questions/6715677/mojodom-xpath-question
XML::Twig will also work for some HTML documents, but in general, using an XML parser to parse HTML documents found in the wild is perilious. On the other hand, if you do have well-formed documents, or HTML::Tidy can make them nice, XML::Twig is a joy to use. Unfortunately, it is depressingly too common to find documents pretending to be HTML, using a mish-mash of XML and HTML styles, and doing all sorts of things which browsers can accommodate, but XML parsers cannot.
And, if your purpose is just to clean some wild HTML document, use HTML::Tidy. 
Thanks to others who have built on HTML::Parser, I have never had to write a line of event handler code myself for real work. It is not that they are difficult to write. I do recommend you study the examples bundled with the distribution to see how the underlying machinery works. https://metacpan.org/source/GAAS/HTML-Parser-3.71/eg

Extra reading on regexp magic / time wasting on parsing HTML:
http://stackoverflow.com/questions/4231382/regular-expression-pattern-not-matching-anywhere-in-string/4234582#answer-4234491
http://search.cpan.org/~dconway/Regexp-Grammars-1.033/lib/Regexp/Grammars.pm

# I have an open issue to have use timers for non-blocking downloads with curl, playing audio with mplayer, showing the status of both while beeing to able to access the mplayer interface at the same time. the way to implement that which I know of are fork or threads but I would like to get around both.
# The way to do this is an event driven mechanism: Asynchronous event-driven IO is awesome in Perl with POE (dngor), IO::Async (LeoNerd), IO::Lambda, Reflex, AnyEvent and Coro, among others.


