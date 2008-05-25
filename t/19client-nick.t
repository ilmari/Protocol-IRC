#!/usr/bin/perl -w

use strict;

use IO::Async::Test;
use IO::Async::Loop::IO_Poll;

use Test::More tests => 12;

use IO::Socket::UNIX;
use Socket qw( AF_UNIX SOCK_STREAM PF_UNSPEC );

use Net::Async::IRC;

my $CRLF = "\x0d\x0a"; # because \r\n isn't portable

my $loop = IO::Async::Loop::IO_Poll->new();
testing_loop( $loop );

( my $S1, my $S2 ) = IO::Socket::UNIX->socketpair( AF_UNIX, SOCK_STREAM, PF_UNSPEC ) or
   die "Cannot create socket pair - $!";

my $irc = Net::Async::IRC->new(
   handle => $S1,

   user => "defaultuser",
   realname => "Default Real name",

   nick => "FirstNick",

   on_message => sub { "IGNORE" },
);

$loop->add( $irc );

is( $irc->nick, "FirstNick", 'Initial nick is set' );

ok( $irc->is_nick_me( "FirstNick" ), 'Client recognises initial nick' );
ok( !$irc->is_nick_me( "SomeoneElse" ), 'Client does not recognise other nick' );

my $logged_in = 0;

$irc->login(
   on_login => sub { $logged_in = 1 },
);

my $serverstream = "";

wait_for_stream { $serverstream =~ m/$CRLF.*$CRLF/ } $S2 => $serverstream;

is( $serverstream, "USER defaultuser 0 * :Default Real name$CRLF" . 
                   "NICK FirstNick$CRLF", 'Server stream after login' );

$S2->syswrite( ":irc.example.com 001 FirstNick :Welcome to IRC FirstNick!defaultuser\@your.host.here$CRLF" );

wait_for { $logged_in };

ok( $logged_in, 'Client receives logged in event' );

$irc->change_nick( "SecondNick" );

is( $irc->nick, "FirstNick", 'Nick still old until server confirms' );

ok( $irc->is_nick_me( "FirstNick" ), 'Client recognises still old nick' );
ok( !$irc->is_nick_me( "SecondNick" ), 'Client does not recognise new nick' );

$serverstream = "";

wait_for_stream { $serverstream =~ m/$CRLF/ } $S2 => $serverstream;

is( $serverstream, "NICK SecondNick$CRLF", 'Server stream after NICK command' );

$S2->syswrite( ":FirstNick!defaultuser\@your.host.here NICK SecondNick$CRLF" );

wait_for { not $irc->is_nick_me( "FirstNick" ) };

is( $irc->nick, "SecondNick", 'Object now confirms new nick' );

ok( !$irc->is_nick_me( "FirstNick" ), 'Client no longer recognises old nick' );
ok( $irc->is_nick_me( "SecondNick" ), 'Client now recognises new nick' );
