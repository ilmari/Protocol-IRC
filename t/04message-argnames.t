#!/usr/bin/perl -w

use strict;

use Test::More tests => 6;
use Test::Exception;

use Net::Async::IRC::Message;

sub test_argnames
{
   my $testname = shift;
   my $line = shift;
   my %asserts = @_;

   my $msg = Net::Async::IRC::Message->new_from_line( $line );

   exists $asserts{names} and
      is_deeply( $msg->arg_names, $asserts{names}, "$testname arg_names" );

   exists $asserts{args} and
      is_deeply( $msg->named_args, $asserts{args}, "$testname named_args" );
}

test_argnames "PING",
   ":server PING 1234",
   names => [ "text" ],
   args  => { text => "1234" };

test_argnames "PRIVMSG",
   ":TheirNick!user\@server PRIVMSG YourNick :A message",
   names => [ undef, "text" ],
   args  => { text => "A message" };

test_argnames "PART",
   ":TheirNick!user\@server PART #somechannel :A leaving message",
   names => [ "channel_name", "text" ],
   args  => { channel_name => "#somechannel", text => "A leaving message" };