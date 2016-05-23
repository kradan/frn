# catch keypresses (used in 'playback')
#use Term::TermKey qw( FLAG_UTF8 RES_EOF FORMAT_VIM );
#use MP3::Info;

sub playback {
  my @list = validate_mp3(@_);
  $config{'mp3'}{'index'} ||= 0;

  # catch keypresses
  use Term::TermKey qw( FLAG_UTF8 RES_EOF FORMAT_VIM );

  my $tk = Term::TermKey->new(\*STDIN);
 
  # ensure perl and libtermkey agree on Unicode handling
  binmode( STDOUT, ":encoding(UTF-8)" ) if $tk->get_flags & FLAG_UTF8;

  while ($list[ $config{'mp3'}{'index'} ]) {

    # start playback
    unless ($config{'mp3'}{'playing'}) {
      play_mp3($list[ $config{'mp3'}{'index'} ], 1);
    }

    unless ($self->{'offline'}) {
      # start next download when slot is available
      while (check_downloads()) { fetch_entry(); }
    }

    # status & timing
    status_line();
    sleep 1;
  }

  # after playback continue download
  # OPTIMIZE this one is similar to fetch_entries()
  fetch_entries(1) unless ($self->{'offline'});
}

sub play_mp3 {
  my $mp3 = shift || (warn "\rplay_mp3(): no file given.\n" and return);
  unless (-f $mp3) { warn "\rplay_mp3(): $mp3: file not found.\n"; return; }
  my $mp3info = get_mp3info($mp3) || die "$@\n";

  $config{'mp3'}{'playing'} = basename($mp3);
  $config{'mp3'}{'playtime'} = int($mp3info->{SECS});
  $config{'mp3'}{'starttime'} = time();

  unless ($self->{'mplayer_fh'}) {
    open $self->{mplayer_fh}, "| mplayer -slave -nofs -nokeepaspect -input nodefault-bindings:conf=/dev/null -zoom -fixed-vo -really-quiet -loop 0 '$mp3' 2>/dev/null" or warn "\rCould not connect to mplayer: $!\n";
  } else {
    debug "\rPlaying $mp3";
    print {$self->{'mplayer_fh'}} "$mp3\n";
  }

  status_line();
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


1;
