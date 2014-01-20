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

# whois
{
   write_irc( ':irc.example.com 311 MyNick UserNick ident host.com * :Real Name Here' . $CRLF );
   write_irc( ':irc.example.com 312 MyNick UserNick irc.example.com :IRC Server for Unit Tests' . $CRLF );
   write_irc( ':irc.example.com 319 MyNick UserNick :#channel #names #here' . $CRLF );
   write_irc( ':irc.example.com 318 MyNick UserNick :End of WHOIS' . $CRLF );

   my ( $kind, $gate, $message, $hints, $data ) = @{ shift @gates };

   is( $kind, "done", 'Gate $kind is done' );
   is( $gate, "whois", 'Gate $gate is whois' );
   is( ref $data, "ARRAY", 'Gate $data is an ARRAY' );

   ( my $command, $message, $hints ) = @{ shift @messages };

   is_deeply( $hints->{whois},
              [
                 { command => "RPL_WHOISUSER", ident => "ident", host => "host.com", flags => "*", realname => "Real Name Here" },
                 { command => "RPL_WHOISSERVER", server => "irc.example.com", serverinfo => "IRC Server for Unit Tests" },
                 { command => "RPL_WHOISCHANNELS", channels => [ "#channel", "#names", "#here" ] },
              ],
              '$hints->{whois}' );
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
