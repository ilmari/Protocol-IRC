#!/usr/bin/perl -w

use strict;

use Test::More tests => 19;
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
      my ( $self, $message ) = @_;
      push @messages, $message;
   },
);

ok( defined $irc, 'defined $irc' );

$loop->add( $irc );

$irc->login(
   nick => "Nick",
   user => "user",
   realname => "realname",

   on_login => sub { "IGNORE" },
);

my $serverstream = "";

wait_for_stream { $serverstream =~ m/$CRLF.*$CRLF/ } $S2 => $serverstream;

$S2->syswrite( ':irc.example.com 001 YourNameHere :Welcome to IRC YourNameHere!me@your.host' . $CRLF );

$S2->syswrite( ':irc.example.com 005 YourNameHere NAMESX MAXCHANNELS=10 NICKLEN=30 PREFIX=(ohv)@%+ CASEMAPPING=rfc1459 :are supported by this server' . $CRLF );

wait_for { defined $irc->ISUPPORT( "NAMESX" ) };

is( $irc->ISUPPORT( "NAMESX" ), 1, 'ISUPPORT NAMESX is true' );

is( $irc->ISUPPORT( "MAXCHANNELS" ), "10", 'ISUPPORT MAXCHANNELS is 10' );

is( $irc->ISUPPORT( "PREFIX" ), "(ohv)\@\%+", 'ISUPPORT PREFIX is (ohv)@%+' );

# Now the generated ones from PREFIX
is( $irc->ISUPPORT( "PREFIX_MODES" ), "ohv", 'ISUPPORT PREFIX_MODES is ohv' );
is( $irc->ISUPPORT( "PREFIX_FLAGS" ), "\@\%+", 'ISUPPORT PREFIX_FLAGS is @%+' );

is( $irc->prefix_mode2flag( "o" ), "\@", 'prefix_mode2flag o -> @' );
is( $irc->prefix_flag2mode( "\@" ), "o", 'prefix_flag2mode @ -> o' );

is( $irc->cmp_prefix_flags( "\@", "\%" ),  1,    'cmp_prefix_flags @ % -> 1' );
is( $irc->cmp_prefix_flags( "\%", "\@" ), -1,    'cmp_prefix_flags % @ -> -1' );
is( $irc->cmp_prefix_flags( "\%", "\%" ),  0,    'cmp_prefix_flags % % -> 0' );
is( $irc->cmp_prefix_flags( "\%", "\$" ), undef, 'cmp_prefix_flags % $ -> undef' );

is( $irc->cmp_prefix_modes( "o", "h" ),  1,    'cmp_prefix_modes o h -> 1' );
is( $irc->cmp_prefix_modes( "h", "o" ), -1,    'cmp_prefix_modes h o -> -1' );
is( $irc->cmp_prefix_modes( "h", "h" ),  0,    'cmp_prefix_modes h h -> 0' );
is( $irc->cmp_prefix_modes( "h", "b" ), undef, 'cmp_prefix_modes h b -> undef' );

is( $irc->casefold_name( "NAME" ),      "name",      'casefold_name NAME' );
is( $irc->casefold_name( "FOO[AWAY]" ), "foo{away}", 'casefold_name FOO[AWAY]' );

## MASSIVE CHEATING
$irc->{casemap_1459} = 0;
## END MASSIVE CHEATING

is( $irc->casefold_name( "FOO[AWAY]" ), "foo[away]", 'casefold_name FOO[AWAY] without RFC1459' );
