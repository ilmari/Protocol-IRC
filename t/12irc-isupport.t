#!/usr/bin/perl -w

use strict;

use Test::More tests => 26;

use Net::Async::IRC::Protocol;

my $irc = Net::Async::IRC::Protocol->new;

ok( defined $irc, 'defined $irc' );

$irc->_set_isupport( {
   MAXCHANNELS => "10",
   NICKLEN     => "30",
   PREFIX      => "(ohv)@%+",
   CASEMAPPING => "rfc1459",
   CHANMODES   => "beI,k,l,imnpsta",
   CHANTYPES   => "#&",
} );

is( $irc->isupport( "MAXCHANNELS" ), "10", 'ISUPPORT MAXCHANNELS is 10' );

is( $irc->isupport( "PREFIX" ), "(ohv)\@\%+", 'ISUPPORT PREFIX is (ohv)@%+' );

is( $irc->isupport( "CHANMODES" ), "beI,k,l,imnpsta", 'ISUPPORT CHANMODES is beI,k,l,imnpsta' );

is( $irc->isupport( "CHANTYPES" ), "#&", 'ISUPPORT CHANTYPES is #&' );

# Now the generated ones from PREFIX
is( $irc->isupport( "prefix_modes" ), "ohv", 'ISUPPORT PREFIX_MODES is ohv' );
is( $irc->isupport( "prefix_flags" ), "\@\%+", 'ISUPPORT PREFIX_FLAGS is @%+' );

is( $irc->prefix_mode2flag( "o" ), "\@", 'prefix_mode2flag o -> @' );
is( $irc->prefix_flag2mode( "\@" ), "o", 'prefix_flag2mode @ -> o' );

is( $irc->cmp_prefix_flags( "\@", "\%" ),  1,    'cmp_prefix_flags @ % -> 1' );
is( $irc->cmp_prefix_flags( "\%", "\@" ), -1,    'cmp_prefix_flags % @ -> -1' );
is( $irc->cmp_prefix_flags( "\%", "\%" ),  0,    'cmp_prefix_flags % % -> 0' );
is( $irc->cmp_prefix_flags( "\%", "\$" ), undef, 'cmp_prefix_flags % $ -> undef' );

is( $irc->cmp_prefix_modes( "o", "h" ),  1,    'cmp_prefix_modes o h -> 1' );
is( $irc->cmp_prefix_modes( "h", "o" ), -1,    'cmp_prefix_modes h o -> -1' );
is( $irc->cmp_prefix_modes( "h", "h" ),  0,    'cmp_prefix_modes h h -> 0' );
is( $irc->cmp_prefix_modes( "h", "b" ), undef, 'cmp_prefix_modes h b -> undef' );

is( $irc->casefold_name( "NAME" ),      "name",      'casefold_name NAME' );
is( $irc->casefold_name( "FOO[AWAY]" ), "foo{away}", 'casefold_name FOO[AWAY]' );
is( $irc->casefold_name( "user^name" ), "user~name", 'casefold_name user^name' );

is( $irc->classify_name( "UserName"   ), "user",    'classify_name UserName' );
is( $irc->classify_name( "#somewhere" ), "channel", 'classify_name #somewhere' );

## CHEATING
$irc->_set_isupport( { CASEMAPPING => "strict-rfc1459" } );
## END CHEATING

is( $irc->casefold_name( "FOO[AWAY]" ), "foo{away}", 'casefold_name FOO[AWAY] under strict' );
is( $irc->casefold_name( "user^name" ), "user^name", 'casefold_name user^name under strict' );

## CHEATING
$irc->_set_isupport( { CASEMAPPING => "ascii" } );
## END CHEATING

is( $irc->casefold_name( "FOO[AWAY]" ), "foo[away]", 'casefold_name FOO[AWAY] under ascii' );

# Now the generated ones from CHANMODES
is_deeply( $irc->isupport( "chanmodes_list" ), [qw( beI k l imnpsta )], 'ISUPPORT chanmodes_list is [qw( beI k l imnpsta )]' );
