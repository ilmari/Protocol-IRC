#!/usr/bin/perl -w

use strict;

use IO::Async::Test;
use IO::Async::Loop::IO_Poll;

use Test::More tests => 2;

use IO::Socket::INET;

use Net::Async::IRC;

my $CRLF = "\x0d\x0a"; # because \r\n isn't portable

my $loop = IO::Async::Loop::IO_Poll->new();
testing_loop( $loop );

# Try connect()ing to a socket we've just created
my $listensock = IO::Socket::INET->new( LocalAddr => 'localhost', Listen => 1 ) or
   die "Cannot create listensock - $!";

my $addr = $listensock->sockname;

my $irc = Net::Async::IRC->new(
   on_message => sub { print "MESSAGE\n" },
);

$loop->add( $irc );

my $connected = 0;

$irc->connect(
   addr => [ AF_INET, SOCK_STREAM, 0, $addr ],

   on_error => sub { die "Test died early - $_[0]\n" },

   on_connected => sub {
      $connected = 1;
   },
);

wait_for { $connected };

ok( $connected, 'Client connects to listening socket' );

my $newclient = $listensock->accept;

# Now see if we can send a message
$irc->send_message( "USER", undef, "user", "0", "*", "Real name here" );

my $serverstream = "";

wait_for_stream { $serverstream =~ m/$CRLF/ } $newclient => $serverstream;

is( $serverstream, "USER user 0 * :Real name here$CRLF", 'Server stream after initial client message' );
