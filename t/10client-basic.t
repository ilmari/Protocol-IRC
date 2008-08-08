#!/usr/bin/perl -w

use strict;

use Test::More tests => 10;
use IO::Async::Test;
use IO::Async::Loop::IO_Poll;
use IO::Async::Stream;

use IO::Socket::UNIX;
use Socket qw( AF_UNIX SOCK_STREAM PF_UNSPEC );

use Net::Async::IRC;

my $CRLF = "\x0d\x0a"; # because \r\n isn't portable

my $loop = IO::Async::Loop::IO_Poll->new();
testing_loop( $loop );

( my $S1, my $S2 ) = IO::Socket::UNIX->socketpair( AF_UNIX, SOCK_STREAM, PF_UNSPEC ) or
   die "Cannot create socket pair - $!";

my @messages;

my $irc = Net::Async::IRC->new(
   handle => $S1,
   on_message => sub {
      my ( $self, $command, $message, $hints ) = @_;
      push @messages, [ $command, $message, $hints ];
   },
);

ok( defined $irc, 'defined $irc' );

$loop->add( $irc );

$irc->send_message( "USER", undef, "me", "0", "*", "My real name" );

my $serverstream = "";

wait_for_stream { $serverstream =~ m/$CRLF/ } $S2 => $serverstream;

is( $serverstream, "USER me 0 * :My real name$CRLF", 'Server stream after initial client message' );

$S2->syswrite( ':irc.example.com 001 YourNameHere :Welcome to IRC YourNameHere!me@your.host' . $CRLF );

wait_for { @messages > 0 };

my $m = shift @messages;

ok( defined $m, '$m defined after server reply' );

my ( $command, $msg, $hints ) = @$m;

is( $command, "001", '$command' );

isa_ok( $msg, "Net::Async::IRC::Message", '$msg isa Net::Async::IRC::Message' );

is( $msg->command, "001",             '$msg->command' );
is( $msg->prefix,  "irc.example.com", '$msg->prefix' );
is_deeply( [ $msg->args ], [ "YourNameHere", "Welcome to IRC YourNameHere!me\@your.host" ], '$msg->args' );

is( $hints->{prefix_nick}, undef, '$hints->{prefix_nick} is not defined' );

$S2->syswrite( ":irc.example.com PING pingarg$CRLF" );

$serverstream = "";

wait_for_stream { $serverstream =~ m/$CRLF/ } $S2 => $serverstream;

is( $serverstream, "PONG pingarg$CRLF", 'Client replies PING with PONG' );
