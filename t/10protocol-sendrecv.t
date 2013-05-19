#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Fatal;

my $CRLF = "\x0d\x0a"; # because \r\n isn't portable

my $written = "";
my @messages;

my $irc = TestIRC->new;

$irc->send_message( "USER", undef, "me", "0", "*", "My real name" );
is( $written, "USER me 0 * :My real name$CRLF", 'Written stream after ->send_message' );

my $buffer = ':irc.example.com 001 YourNameHere :Welcome to IRC YourNameHere!me@your.host' . $CRLF;
$irc->on_read( $buffer );
is( length $buffer, 0, '->on_read consumes the entire line' );

is( scalar @messages, 1, 'Received 1 message after server reply' );
my $msg = shift @messages;

isa_ok( $msg, "Protocol::IRC::Message", '$msg isa Protocol::IRC::Message' );

is( $msg->command, "001",             '$msg->command' );
is( $msg->prefix,  "irc.example.com", '$msg->prefix' );
is_deeply( [ $msg->args ], [ "YourNameHere", "Welcome to IRC YourNameHere!me\@your.host" ], '$msg->args' );

done_testing;

package TestIRC;
use base qw( Protocol::IRC );

sub new { return bless [], shift }

sub write { $written .= $_[1] }

sub incoming_message { push @messages, $_[1] }

sub isupport
{
   return "ascii" if $_[1] eq "CASEMAPPING";
}
