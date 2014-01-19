#!/usr/bin/perl

use strict;
use warnings;

use Test::More;

my $CRLF = "\x0d\x0a"; # because \r\n isn't portable

my @gates;

my $irc = TestIRC->new;
sub write_irc
{
   my $line = $_[0];
   $irc->on_read( $line );
   length $line == 0 or die '$irc failed to read all of the line';
}

write_irc( ':irc.example.com 375 MyNick :- Here is the Message Of The Day -' . $CRLF );
write_irc( ':irc.example.com 372 MyNick :- some more of the message -' . $CRLF );
write_irc( ':irc.example.com 376 MyNick :End of /MOTD command.' . $CRLF );

my ( $kind, $gate, $message, $hints, $data ) = @{ shift @gates };

is( $kind, "done", 'Gate $kind is done' );
is( $gate, "motd", 'Gate $gate is motd' );
is( ref $data, "ARRAY", 'Gate $data is an ARRAY' );

done_testing;

package TestIRC;
use base qw( Protocol::IRC::Client );

sub new { return bless {}, shift }

sub on_gate
{
   my $self = shift;
   push @gates, [ @_ ];
}
