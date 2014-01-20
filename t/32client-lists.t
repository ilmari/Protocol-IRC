#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use IO::Async::Test;
use IO::Async::OS;
use IO::Async::Loop;
use IO::Async::Stream;

use Net::Async::IRC;

my $CRLF = "\x0d\x0a"; # because \r\n isn't portable

my $loop = IO::Async::Loop->new();
testing_loop( $loop );

my ( $S1, $S2 ) = IO::Async::OS->socketpair() or die "Cannot create socket pair - $!";

my @messages;

my $irc = Net::Async::IRC->new(
   handle => $S1,
   on_message => sub {
      my ( $self, $command, $message, $hints ) = @_;
      # Only care about synthesized events, not real ones
      return 0 unless $hints->{synthesized};
      push @messages, [ $command, $message, $hints ];
      return 1;
   },
);

ok( defined $irc, 'defined $irc' );

$loop->add( $irc );

my $login_f = $irc->login(
   nick => "MyNick",
   user => "me",
   realname => "My real name",
);

my $serverstream = "";

wait_for_stream { $serverstream =~ m/$CRLF.*$CRLF/ } $S2 => $serverstream;

is( $serverstream, "USER me 0 * :My real name$CRLF" .
                   "NICK MyNick$CRLF", 'Server stream after client login' );

$S2->syswrite( ':irc.example.com 001 MyNick :Welcome to IRC MyNick!me@your.host' . $CRLF );

wait_for { $login_f->is_ready };
$login_f->get;

# Standard hints
my %HINTS = (
   prefix_nick        => undef,
   prefix_nick_folded => undef,
   prefix_user        => undef,
   prefix_host        => "irc.example.com",
   prefix_name        => "irc.example.com",
   prefix_name_folded => "irc.example.com",
   prefix_is_me       => '',
   synthesized        => 1,
   handled            => 1,
);
my %CHANNEL_HINTS = (
   %HINTS,
   target_name        => '#channel',
   target_name_folded => '#channel',
   target_type        => 'channel',
   target_is_me       => '',
);

# motd list
{
   undef @messages;

   $S2->syswrite( ':irc.example.com 375 MyNick :- Here is the Message Of The Day -' . $CRLF .
                  ':irc.example.com 372 MyNick :- some more of the message -' . $CRLF .
                  ':irc.example.com 376 MyNick :End of /MOTD command.' . $CRLF );

   wait_for { @messages };

   my ( $command, $msg, $hints ) = @{ shift @messages };

   is( $command, "motd", '$command for motd' );

   is_deeply( $hints, { %HINTS,
                        motd => [
                           '- Here is the Message Of The Day -',
                           '- some more of the message -',
                        ] }, '$hints for names' );
}

# names list
{
   undef @messages;

   $S2->syswrite( ':irc.example.com 353 MyNick = #channel :@Some +Users Here' . $CRLF .
                  ':irc.example.com 366 MyNick #channel :End of NAMES list' . $CRLF );

   wait_for { @messages };

   my ( $command, $msg, $hints ) = @{ shift @messages };

   is( $command, "names", '$command for names' );

   is_deeply( $hints, { %CHANNEL_HINTS,
                        names => {
                           some  => { nick => "Some",  flag => '@' },
                           users => { nick => "Users", flag => '+' },
                           here  => { nick => "Here",  flag => '' },
                        } }, '$hints for names' );
}

# bans list
{
   undef @messages;

   $S2->syswrite( ':irc.example.com 367 MyNick #channel a*!a@a.com Banner 12345' . $CRLF .
                  ':irc.example.com 367 MyNick #channel b*!b@b.com Banner 12346' . $CRLF .
                  ':irc.example.com 368 MyNick #channel :End of BANS' . $CRLF );

   wait_for { @messages };

   my ( $command, $msg, $hints ) = @{ shift @messages };

   is( $command, "bans", '$command for bans' );

   is_deeply( $hints, { %CHANNEL_HINTS,
                        bans => [
                           { mask => 'a*!a@a.com', by_nick => "Banner", by_nick_folded => "banner", timestamp => 12345 },
                           { mask => 'b*!b@b.com', by_nick => "Banner", by_nick_folded => "banner", timestamp => 12346 },
                        ] }, '$hints for bans' );
}

# who list
{
   undef @messages;

   $S2->syswrite( ':irc.example.com 352 MyNick #channel ident host.com irc.example.com OtherNick H@ :2 hops Real Name' . $CRLF .
                  ':irc.example.com 315 MyNick #channel :End of WHO' . $CRLF );

   wait_for { @messages };

   my ( $command, $msg, $hints ) = @{ shift @messages };

   is( $command, "who", '$command for who' );

   is_deeply( $hints, { %CHANNEL_HINTS,
                        who => [
                           { user_nick        => "OtherNick",
                             user_nick_folded => "othernick",
                             user_ident       => "ident",
                             user_host        => "host.com",
                             user_server      => "irc.example.com",
                             user_flags       => 'H@', }
                        ] }, '$hints for who' );
}

done_testing;
