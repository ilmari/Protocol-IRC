#!/usr/bin/perl -w

use strict;

use Test::More no_plan => 1;

use Net::Async::IRC;

my $irc = Net::Async::IRC->new(
   on_message => sub { "IGNORE" },
);

ok( defined $irc, 'defined $irc' );
ok( $irc->isa( "Net::Async::IRC" ), '$irc isa Net::Async::IRC' );

is_deeply( [ $irc->split_prefix( 'nick!user@host' ) ],
           [ "nick", "user", "host" ],
           'split nick!user@host' );

is_deeply( [ $irc->split_prefix( 'nick!user@fully.qualified.host' ) ],
           [ "nick", "user", "fully.qualified.host" ],
           'split nick!user@fully.qualified.host' );

is_deeply( [ $irc->split_prefix( 'irc.example.com' ) ],
           [ undef, undef, "irc.example.com" ],
           'split servername' );
