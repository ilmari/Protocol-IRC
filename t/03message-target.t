#!/usr/bin/perl -w

use strict;

use Test::More tests => 10;
use Test::Exception;

use Net::Async::IRC::Message;

sub test_target
{
   my $testname = shift;
   my $line = shift;
   my %asserts = @_;

   my $msg = Net::Async::IRC::Message->new_from_line( $line );

   exists $asserts{is} and
      is( ( $msg->is_targeted ? 0 : 1 ), ( $asserts{is} ? 0 : 1 ), "$testname is_targeted" );

   exists $asserts{target} and
      is( $msg->target_arg, $asserts{target}, "$testname target" );
}

test_target "001",
   ":server 001 :Welcome to IRC",
   is     => 0,
   target => undef;

test_target "PING",
   ":server PING 1234",
   is     => 0,
   target => undef;

test_target "332 RPL_TOPIC",
   ":server 332 YourNick #channame :Some topic here",
   is     => 1,
   target => "#channame";

test_target "PRIVMSG",
   ":server PRIVMSG YourNick :A message",
   is     => 1,
   target => "YourNick";

test_target "353 RPL_NAMREPLY",
   ":server 353 YourNick * #channel :+user1 +user2 nobody \@oper",
   is     => 1,
   target => "#channel";
