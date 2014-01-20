#!/usr/bin/perl

use strict;
use warnings;

use Test::More;

my $CRLF = "\x0d\x0a"; # because \r\n isn't portable

my @gates;
my @messages;

my $irc = TestIRC->new;
sub write_irc
{
   my $line = $_[0];
   $irc->on_read( $line );
   length $line == 0 or die '$irc failed to read all of the line';
}

# motd
{
   write_irc( ':irc.example.com 375 MyNick :- Here is the Message Of The Day -' . $CRLF );
   write_irc( ':irc.example.com 372 MyNick :- some more of the message -' . $CRLF );
   write_irc( ':irc.example.com 376 MyNick :End of /MOTD command.' . $CRLF );

   my ( $kind, $gate, $message, $hints, $data ) = @{ shift @gates };

   is( $kind, "done", 'Gate $kind is done' );
   is( $gate, "motd", 'Gate $gate is motd' );
   is( ref $data, "ARRAY", 'Gate $data is an ARRAY' );

   ( my $command, $message, $hints ) = @{ shift @messages };

   is_deeply( $hints->{motd},
              [
                 '- Here is the Message Of The Day -',
                 '- some more of the message -',
              ],
              '$hints->{motd}' );
}

# names
{
   write_irc( ':irc.example.com 353 MyNick = #channel :@Some +Users Here' . $CRLF );
   write_irc( ':irc.example.com 366 MyNick #channel :End of NAMES list' . $CRLF );

   my ( $kind, $gate, $message, $hints, $data ) = @{ shift @gates };

   is( $kind, "done", 'Gate $kind is done' );
   is( $gate, "names", 'Gate $gate is names' );
   is( ref $data, "ARRAY", 'Gate $data is an ARRAY' );

   ( my $command, $message, $hints ) = @{ shift @messages };

   is_deeply( $hints->{names},
              {
                 some  => { nick => "Some",  flag => '@' },
                 users => { nick => "Users", flag => '+' },
                 here  => { nick => "Here",  flag => '' },
              },
              '$hints->{names}' );
}

# bans
{
   write_irc( ':irc.example.com 367 MyNick #channel a*!a@a.com Banner 12345' . $CRLF );
   write_irc( ':irc.example.com 367 MyNick #channel b*!b@b.com Banner 12346' . $CRLF );
   write_irc( ':irc.example.com 368 MyNick #channel :End of BANS' . $CRLF );

   my ( $kind, $gate, $message, $hints, $data ) = @{ shift @gates };

   is( $kind, "done", 'Gate $kind is done' );
   is( $gate, "bans", 'Gate $gate is bans' );
   is( ref $data, "ARRAY", 'Gate $data is an ARRAY' );

   ( my $command, $message, $hints ) = @{ shift @messages };

   is_deeply( $hints->{bans},
              [
                 { mask => 'a*!a@a.com', by_nick => "Banner", by_nick_folded => "banner", timestamp => 12345 },
                 { mask => 'b*!b@b.com', by_nick => "Banner", by_nick_folded => "banner", timestamp => 12346 },
              ],
              '$hints->{bans}' );
}

# who
{
   write_irc( ':irc.example.com 352 MyNick #channel ident host.com irc.example.com OtherNick H@ :2 hops Real Name' . $CRLF );
   write_irc( ':irc.example.com 315 MyNick #channel :End of WHO' . $CRLF );

   my ( $kind, $gate, $message, $hints, $data ) = @{ shift @gates };

   is( $kind, "done", 'Gate $kind is done' );
   is( $gate, "who", 'Gate $gate is who' );
   is( ref $data, "ARRAY", 'Gate $data is an ARRAY' );

   ( my $command, $message, $hints ) = @{ shift @messages };

   is_deeply( $hints->{who},
              [
                 { user_nick        => "OtherNick",
                   user_nick_folded => "othernick",
                   user_ident       => "ident",
                   user_host        => "host.com",
                   user_server      => "irc.example.com",
                   user_flags       => 'H@', }
              ],
              '$hints->{who}' );
}

done_testing;

package TestIRC;
use base qw( Protocol::IRC::Client );

sub new { return bless {}, shift }

sub nick { "MyNick" }

sub on_message
{
   my $self = shift;
   my ( $command, $message, $hints ) = @_;
   return 0 unless $hints->{synthesized};
   push @messages, [ $command, $message, $hints ];
   return 1;
}

sub on_gate
{
   my $self = shift;
   push @gates, [ @_ ];
}
