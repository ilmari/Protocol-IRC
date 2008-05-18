#!/usr/bin/perl -w

use strict;

use Test::More no_plan => 1;

use Net::Async::IRC::Message;

sub test_line
{
   my $testname = shift;
   my $line = shift;
   my %asserts = @_;

   my $msg = Net::Async::IRC::Message->new_from_line( $line );

   exists $asserts{command} and
      is( $msg->command, $asserts{command}, "$testname command" );

   exists $asserts{prefix} and
      is( $msg->prefix, $asserts{prefix}, "$testname prefix" );

   exists $asserts{args} and
      is_deeply( [ $msg->args ], $asserts{args}, "$testname args" );

   exists $asserts{stream} and
      is( $msg->stream_to_line, $asserts{stream}, "$testname restream" );
}

my $msg = Net::Async::IRC::Message->new( "command", "prefix", "arg1", "arg2" );

ok( defined $msg, 'defined $msg' );
ok( $msg->isa( "Net::Async::IRC::Message" ), '$msg isa Net::Async::IRC::Message' );

is( $msg->command, "command", '$msg->command' );
is( $msg->prefix,  "prefix",  '$msg->prefix' );
is( $msg->arg(0),  "arg1",    '$msg->arg(0)' );
is( $msg->arg(1),  "arg2",    '$msg->arg(1)' );
is_deeply( [ $msg->args ], [qw( arg1 arg2 )], '$msg->args' );

is( $msg->stream_to_line, ":prefix command arg1 arg2", '$msg->stream_to_line' );

test_line "Basic",
   "command",
   command => "command",
   prefix  => "",
   args    => [],
   stream  => "command";

test_line "Prefixed",
   ":someprefix command",
   command => "command",
   prefix  => "someprefix",
   args    => [],
   stream  => ":someprefix command";

test_line "With one arg",
   "JOIN #channel",
   command => "JOIN",
   prefix  => "",
   args    => [ "#channel" ],
   stream  => "JOIN #channel";

test_line "With one arg as :final",
   "WHOIS :Someone",
   command => "WHOIS",
   prefix  => "",
   args    => [ "Someone" ],
   stream  => "WHOIS Someone";

test_line "With two args",
   "JOIN #foo somekey",
   command => "JOIN",
   prefix  => "",
   args    => [ "#foo", "somekey" ],
   stream  => "JOIN #foo somekey";

test_line "With long final",
   "MESSAGE :Here is a long message to say",
   command => "MESSAGE",
   prefix  => "",
   args    => [ "Here is a long message to say" ],
   stream  => "MESSAGE :Here is a long message to say";
