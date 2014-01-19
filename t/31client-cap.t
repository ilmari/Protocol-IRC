#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use IO::Async::Test;
use IO::Async::Loop;
use IO::Async::Stream;

use Net::Async::IRC;

my $CRLF = "\x0d\x0a"; # because \r\n isn't portable

my $loop = IO::Async::Loop->new();
testing_loop( $loop );

my ( $S1, $S2 ) = IO::Async::OS->socketpair() or die "Cannot create socket pair - $!";

# Normal CAP login
{
   my $irc = Net::Async::IRC->new(
      handle => $S1,
      use_cap => 1,
   );
   $loop->add( $irc );

   my $login_f = $irc->login(
      nick => "MyNick",
      user => "me",
      realname => "My real name",
   );

   my $serverstream = "";
   wait_for_stream { $serverstream =~ m/(?:.*$CRLF){3}/ } $S2 => $serverstream;

   is( $serverstream, "CAP LS$CRLF" .
                      "USER me 0 * :My real name$CRLF" .
                      "NICK MyNick$CRLF", 'Server stream negotiates CAP' );
   $serverstream = "";

   $S2->syswrite( ':irc.example.com CAP * LS :multi-prefix sasl' . $CRLF );

   wait_for_stream { $serverstream =~ m/.*$CRLF/ } $S2 => $serverstream;

   is( $serverstream, "CAP END$CRLF", 'Client finishes CAP' );

   is_deeply( $irc->caps_supported,
              { 'multi-prefix' => 1,
                'sasl'         => 1 },
              '$irc->caps_supported' );

   ok( $irc->cap_supported( "multi-prefix" ), '$irc->cap_supported' );

   $S2->syswrite( ':irc.example.com 001 MyNick :Welcome to IRC MyNick!me@your.host' . $CRLF );

   wait_for { $login_f->is_ready };
   $login_f->get;
}

done_testing;
