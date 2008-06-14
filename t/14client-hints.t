#!/usr/bin/perl -w

use strict;

use Test::More tests => 17;
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
      my ( $self, $message, $hints ) = @_;
      push @messages, [ $message, $hints ];
   },
);

ok( defined $irc, 'defined $irc' );

$loop->add( $irc );

my $logged_in = 0;

$irc->login(
   nick => "MyNick",
   user => "me",
   realname => "My real name",
   on_login => sub { $logged_in = 1 },
);

my $serverstream = "";

wait_for_stream { $serverstream =~ m/$CRLF.*$CRLF/ } $S2 => $serverstream;

is( $serverstream, "USER me 0 * :My real name$CRLF" .
                   "NICK MyNick$CRLF", 'Server stream after client login' );

$S2->syswrite( ':irc.example.com 001 MyNick :Welcome to IRC MyNick!me@your.host' . $CRLF );

wait_for { $logged_in };

my $m = shift @messages;

ok( defined $m, '$m defined after server reply' );

my ( $msg, $hints ) = @$m;

ok( $msg->isa( "Net::Async::IRC::Message" ), '$msg isa Net::Async::IRC::Message' );

is( $msg->command, "001",             '$msg->command' );
is( $msg->prefix,  "irc.example.com", '$msg->prefix' );
is_deeply( [ $msg->args ], [ "MyNick", "Welcome to IRC MyNick!me\@your.host" ], '$msg->args' );

is( $hints->{prefix_nick}, undef, '$hints->{prefix_nick} is not defined' );
ok( !$hints->{prefix_is_me},      '$hints->{prefix_is_me} is false' );

$S2->syswrite( ':Someone!theiruser@their.host PRIVMSG MyNick :Their message here' . $CRLF );

wait_for { @messages };

( $msg, $hints ) = @{ shift @messages };

is( $msg->command, "PRIVMSG",                      '$msg->command for PRIVMSG' );
is( $msg->prefix,  'Someone!theiruser@their.host', '$msg->prefix for PRIVMSG' );

is( $hints->{prefix_nick}, "Someone", '$hints->{prefix_nick} for PRIVMSG' );
ok( !$hints->{prefix_is_me},          '$hints->{prefix_is_me} for PRIVMSG' );

$S2->syswrite( ':MyNick!me@your.host PRIVMSG :Hello to me' . $CRLF );

wait_for { @messages };

( $msg, $hints ) = @{ shift @messages };

is( $msg->command, "PRIVMSG",             '$msg->command for PRIVMSG to self' );
is( $msg->prefix,  'MyNick!me@your.host', '$msg->prefix for PRIVMSG to self' );

is( $hints->{prefix_nick}, "MyNick", '$hints->{prefix_nick} for PRIVMSG to self' );
ok( $hints->{prefix_is_me},          '$hints->{prefix_is_me} for PRIVMSG to self' );