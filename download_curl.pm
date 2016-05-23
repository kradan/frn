use Try::Tiny;
use WWW::Curl::Easy;

sub start_download {
  my $url = shift || return;
  if ($config{'downloads'}{$url}) { status_line ("already downloading '$url'"); return; };
  unless ($url =~ /^http/) { $url = "$config{'url'}$url"; }
  my $id = basename($url);

  my $fn = shift || return;

  try {
    # create curl handle
    my $handle = WWW::Curl::Easy->new;
    $handle->setopt(CURLOPT_HEADER,1);
    $handle->setopt(CURLOPT_URL, $url);
    $handle->setopt(CURLOPT_PRIVATE,$url);

    open my $fh, '>>', $fn or warn "Could not save '$fn': $!\n" and return;
    $handle->setopt(CURLOPT_WRITEDATA, $fh);

    # add handle to pool
    unless ($config{'curlm'}) {
      $config{'curlm'} = WWW::Curl::Multi->new;
    }
    $config{'curlm'}->add_handle($handle);
    $config{'active_downloads'}++;

    # return handle for remote access
    %{$config{'downloads'}{$url}} = ( id => $id, handle => \$handle, file => $fn );

    status_line ("$url > $fn") if ($self->{'verbose'});
    status_line();
    return $url;

  } catch {
    print "\rCould not start download for '$url': $1\n";
    return;
  }

  # TODO Would be great to check the file size before downloading.

    # Why am I using Curl rather then LWP?
    # I live with a very throttled mobile internet connection and found perl consuming 99% cpu
    # while loading mp3 files with LWP.

    # Thin was much better regarding CPU than LWP but it broke without clear reason
    # and restarted several megabyte files from the beginning. So I rather hesitate to implement it.
 
    # [LWP] size=342 size=17624626 [Thin] [1] 599 Internal Exception Timed out while waiting for socket
    # to become ready for reading at /usr/share/perl/5.14/HTTP/Tiny.pm line 162

    # I got a nice html graph with NYTProf showing the connection was restarted *lots* of times internally
    # and IO::Socket::SSL ate about half of the cpu time:
    #   spent 128s (101+27.3) within IO::Socket::SSL::_set_rw_error which was called 2181095 times, avg 59µs/call:
    #    2181091 times (101s+27.3s) by IO::Socket::SSL::generic_read at line 682, avg 59µs/call
    #   spent 418s (68.9+349) within Net::HTTP::Methods::my_read which was called 2182614 times, avg 192µs/call
    #   spent 522s (104+418) within Net::HTTP::Methods::read_entity_body which was called 2182616 times, avg 239µs/call
    # <mst> this comes back to "the internals of LWP are full of crack"

    # from WWW::Curl documentation:
    #   The standard Perl WWW module, LWP should probably be used in most cases to work with HTTP or FTP from Perl.
    #   However, there are some cases where LWP doesn't perform well. One is speed and the other is parallelism.
    #   WWW::Curl is much faster, uses much less CPU cycles and it's capable of non-blocking parallel requests.

}

sub finish_download {
  my $url = shift||return;
  my $try = shift||0;
  my $curl = ${$config{'downloads'}{$url}{'handle'}};
  return unless $curl;
  my $retcode = $curl->perform;

  # Looking at the results...
  if ($retcode == 0) {
    my $response_code = $curl->getinfo(CURLINFO_HTTP_CODE);
    debug "ok[$response_code].\r";

    # letting the curl handle get garbage collected, or we leak memory.
    delete $config{'downloads'}{$url};
    return 1;

  } else {
    my $fn = $config{'downloads'}{$url}{'fn'};

    unless ($try >= $config{'retries'}) {
      debug "$retcode ".$curl->strerror($retcode)." ".$curl->errbuf ." - retrying download.\n";
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

  if ($active_transfers != $config{'active_downloads'}) {
    while (my ($url,$return_value) = $config{'curlm'}->info_read) {
      if ($url) {
	debug "\rFinishing download of '$url'.. ";
        finish_download($url);
        $config{'active_downloads'}--;
        status_line();
      }      
    }
    # fix counting errors
    $config{'active_downloads'} = $active_transfers if ($active_transfers > $config{'active_downloads'});
  }

  # the calling function usually wants to know if there are empty slots
  return ($max > $active_transfers ) ? 1 : 0;
}

sub save {
  my ($fn, @data) = @_;
  return unless (defined($fn));

  open my $fh, '>', $fn or die "could not write to '$fn': $!\n";
  print {$fh} @data;
  close $fh;
  return 1;
}


1;
