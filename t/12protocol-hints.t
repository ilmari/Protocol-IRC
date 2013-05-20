#!/usr/bin/perl

use strict;
use warnings;

use Test::More;

my $CRLF = "\x0d\x0a"; # because \r\n isn't portable

my @messages;

my $irc = TestIRC->new;
sub write_irc
{
   my $line = $_[0];
   $irc->on_read( $line );
   length $line == 0 or die '$irc failed to read all of the line';
}

write_irc( ':irc.example.com 001 MyNick :Welcome to IRC MyNick!me@your.host' . $CRLF );

my $m = shift @messages;

ok( defined $m, '$m defined after server reply' );

my ( $command, $msg, $hints ) = @$m;

is( $command, "001", '$command' );

isa_ok( $msg, "Protocol::IRC::Message", '$msg isa Protocol::IRC::Message' );

is( $msg->command, "001",             '$msg->command for 001' );
is( $msg->prefix,  "irc.example.com", '$msg->prefix for 001' );
is_deeply( [ $msg->args ], [ "MyNick", "Welcome to IRC MyNick!me\@your.host" ], '$msg->args for 001' );

is_deeply( $hints,
           { prefix_nick        => undef,
             prefix_nick_folded => undef,
             prefix_user        => undef,
             prefix_host        => "irc.example.com",
             prefix_name        => "irc.example.com",
             prefix_name_folded => "irc.example.com",
             prefix_is_me       => '',
             text               => "Welcome to IRC MyNick!me\@your.host",
             handled            => 1 },
           '$hints for 001' );

write_irc( ':Someone!theiruser@their.host PRIVMSG MyNick :Their message here' . $CRLF );

( $command, $msg, $hints ) = @{ shift @messages };

is( $msg->command, "PRIVMSG",                      '$msg->command for PRIVMSG' );
is( $msg->prefix,  'Someone!theiruser@their.host', '$msg->prefix for PRIVMSG' );

is_deeply( $hints,
           { prefix_nick        => "Someone",
             prefix_nick_folded => "someone",
             prefix_user        => "theiruser",
             prefix_host        => "their.host",
             prefix_name        => "Someone",
             prefix_name_folded => "someone",
             prefix_is_me       => '',
             targets            => "MyNick",
             text               => "Their message here",
             handled            => 1 },
           '$hints for PRIVMSG' );

write_irc( ':MyNick!me@your.host PRIVMSG MyNick :Hello to me' . $CRLF );

( $command, $msg, $hints ) = @{ shift @messages };

is( $msg->command, "PRIVMSG",             '$msg->command for PRIVMSG to self' );
is( $msg->prefix,  'MyNick!me@your.host', '$msg->prefix for PRIVMSG to self' );

is_deeply( $hints,
           { prefix_nick        => "MyNick",
             prefix_nick_folded => "mynick",
             prefix_user        => "me",
             prefix_host        => "your.host",
             prefix_name        => "MyNick",
             prefix_name_folded => "mynick",
             prefix_is_me       => 1,
             targets            => "MyNick",
             text               => "Hello to me",
             handled            => 1 },
           '$hints for PRIVMSG to self' );

write_irc( ':Someone!theiruser@their.host TOPIC #channel :Message of the day' . $CRLF );

( $command, $msg, $hints ) = @{ shift @messages };

is( $msg->command, "TOPIC",                        '$msg->command for TOPIC' );
is( $msg->prefix,  'Someone!theiruser@their.host', '$msg->prefix for TOPIC' );

is_deeply( $hints,
           { prefix_nick        => "Someone",
             prefix_nick_folded => "someone",
             prefix_user        => "theiruser",
             prefix_host        => "their.host",
             prefix_name        => "Someone",
             prefix_name_folded => "someone",
             prefix_is_me       => '',
             target_name        => "#channel",
             target_name_folded => "#channel",
             target_is_me       => '',
             target_type        => "channel",
             text               => "Message of the day",
             handled            => 1 },
           '$hints for TOPIC' );

write_irc( ':Someone!theiruser@their.host NOTICE #channel :Please ignore me' . $CRLF );

( $command, $msg, $hints ) = @{ shift @messages };

is( $msg->command, "NOTICE",                       '$msg->command for NOTICE' );
is( $msg->prefix,  'Someone!theiruser@their.host', '$msg->prefix for NOTICE' );

is_deeply( $hints,
           { prefix_nick        => "Someone",
             prefix_nick_folded => "someone",
             prefix_user        => "theiruser",
             prefix_host        => "their.host",
             prefix_name        => "Someone",
             prefix_name_folded => "someone",
             prefix_is_me       => '',
             targets            => "#channel",
             text               => "Please ignore me",
             handled            => 0 },
           '$hints for NOTICE' );

write_irc( ':Someone!theiruser@their.host NICK NewName' . $CRLF );

( $command, $msg, $hints ) = @{ shift @messages };

is( $msg->command, "NICK",                         '$msg->command for NICK' );
is( $msg->prefix,  'Someone!theiruser@their.host', '$msg->prefix for NICK' );

is_deeply( $hints,
           { prefix_nick        => "Someone",
             prefix_nick_folded => "someone",
             prefix_user        => "theiruser",
             prefix_host        => "their.host",
             prefix_name        => "Someone",
             prefix_name_folded => "someone",
             prefix_is_me       => '',
             old_nick           => "Someone",
             old_nick_folded    => "someone",
             new_nick           => "NewName",
             new_nick_folded    => "newname",
             handled            => 1 },
           '$hints for NICK' );

done_testing;

package TestIRC;
use base qw( Protocol::IRC );

sub new { return bless [], shift }

my %isupport;
BEGIN {
   %isupport = (
      CHANTYPES   => "#&",
         channame_re => qr/^[#&]/,
   );
}
sub isupport { return $isupport{$_[1]} }

sub nick { return "MyNick" }

sub on_message
{
   my $self = shift;
   my ( $command, $message, $hints ) = @_;
   # Only care about real events, not synthesized ones
   return 0 if $hints->{synthesized};
   push @messages, [ $command, $message, $hints ];
   return $command ne "NOTICE";
}
