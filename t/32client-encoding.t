#!/usr/bin/perl

use strict;
use warnings;
use utf8;

use Test::More;
use IO::Async::Test;
use IO::Async::Loop;
use IO::Async::Listener;

use Encode qw( encode_utf8 );

use Net::Async::IRC;

my $CRLF = "\x0d\x0a"; # because \r\n isn't portable

my $loop = IO::Async::Loop->new();
testing_loop( $loop );

# plaintext
{
   my $client;
   my $listener = IO::Async::Listener->new(
      on_stream => sub {
         ( undef, $client ) = @_;
      },
   );
   $loop->add( $listener );

   $listener->listen(
      addr => { family => "inet" },
   )->get;

   my $irc = Net::Async::IRC->new(
      user => "defaultuser",
      realname => "Default Real name",

      encoding => "UTF-8",

      on_message => sub { "IGNORE" },

      on_irc_error => sub {},
   );
   $loop->add( $irc );

   $irc->connect(
      addr => {
         family => "inet",
         ip     => $listener->read_handle->sockhost,
         port   => $listener->read_handle->sockport,
      },
   )->get;

   wait_for { $client };
   $client->configure( on_read => sub { 0 } );  # using read futures
   $loop->add( $client );

   $irc->send_message( "PRIVMSG", undef, "target", "Ĉu vi ĉi tio vidas?" );

   my $read_f = $client->read_until( $CRLF );
   wait_for { $read_f->is_ready };

   is( scalar $read_f->get, encode_utf8( "PRIVMSG target :Ĉu vi ĉi tio vidas?$CRLF" ),
      'Stream is encoded' );

   $loop->remove( $irc );
   $loop->remove( $client );
   $loop->remove( $listener );
}

done_testing;
