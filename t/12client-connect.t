#!/usr/bin/perl -w

use strict;

use IO::Async::Test;
use IO::Async::Loop::IO_Poll;

use Test::More tests => 4;

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
   user => "defaultuser",
   realname => "Default Real name",

   on_message => sub { "IGNORE" },
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
$irc->send_message( "HELLO", undef, "world" );

my $serverstream = "";

wait_for_stream { $serverstream =~ m/$CRLF/ } $newclient => $serverstream;

is( $serverstream, "HELLO world$CRLF", 'Server stream after initial client message' );

my $logged_in = 0;

$irc->login(
   nick => "MyNick",

   on_login => sub { $logged_in = 1 },
);

$serverstream = "";

wait_for_stream { $serverstream =~ m/$CRLF.*$CRLF/ } $newclient => $serverstream;

is( $serverstream, "USER defaultuser 0 * :Default Real name$CRLF" . 
                   "NICK MyNick$CRLF", 'Server stream after login' );

$newclient->syswrite( ":irc.example.com 001 MyNick :Welcome to IRC MyNick!defaultuser\@your.host.here$CRLF" );

wait_for { $logged_in };

ok( $logged_in, 'Client receives logged in event' );
