#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2010-2013 -- leonerd@leonerd.org.uk

package Protocol::IRC::Client;

use strict;
use warnings;
use 5.010; # //
use base qw( Protocol::IRC );

our $VERSION = '0.01';

use Carp;

=head1 NAME

C<Protocol::IRC::Client> - IRC protocol handling for a client

=cut

=head1 METHODS

=cut

=head2 $value = $irc->isupport( $key )

Returns an item of information from the server's C<005 ISUPPORT> lines.
Traditionally IRC servers use all-capital names for keys.

=cut

# A few hardcoded defaults from RFC 2812
my %ISUPPORT = (
   channame_re => qr/^[#&]/,
   prefixflag_re => qr/^[\@+]/,
   chanmodes_list => [qw( b k l imnpst )], # TODO: ov
);

sub isupport
{
   my $self = shift;
   my ( $field ) = @_;
   return $self->{Protocol_IRC_isupport}->{$field} // $ISUPPORT{$field};
}

sub on_message_RPL_ISUPPORT
{
   my $self = shift;
   my ( $message, $hints ) = @_;

   my $isupport = $self->{Protocol_IRC_isupport} ||= {};

   foreach my $entry ( @{ $hints->{isupport} } ) {
      my ( $name, $value ) = $entry =~ m/^([A-Z]+)(?:=(.*))?$/;

      $value = 1 if !defined $value;

      $isupport->{$name} = $value;

      if( $name eq "PREFIX" ) {
         my $prefix = $value;

         my ( $prefix_modes, $prefix_flags ) = $prefix =~ m/^\(([a-z]+)\)(.+)$/i
            or warn( "Unable to parse PREFIX=$value" ), next;

         $isupport->{prefix_modes} = $prefix_modes;
         $isupport->{prefix_flags} = $prefix_flags;

         $isupport->{prefixflag_re} = qr/[$prefix_flags]/;

         my %prefix_map;
         $prefix_map{substr $prefix_modes, $_, 1} = substr $prefix_flags, $_, 1 for ( 0 .. length($prefix_modes) - 1 );

         $isupport->{prefix_map_m2f} = \%prefix_map;
         $isupport->{prefix_map_f2m} = { reverse %prefix_map };
      }
      elsif( $name eq "CHANMODES" ) {
         $isupport->{chanmodes_list} = [ split( m/,/, $value ) ];
      }
      elsif( $name eq "CASEMAPPING" ) {
         # TODO
         # $self->{nick_folded} = $self->casefold_name( $self->{nick} );
      }
      elsif( $name eq "CHANTYPES" ) {
         $isupport->{channame_re} = qr/^[$value]/;
      }
   }

   return 0;
}

=head2 $info = $irc->server_info( $key )

Returns an item of information from the server's C<004> line. C<$key> should
one of

=over 8

=item * host

=item * version

=item * usermodes

=item * channelmodes

=back

=cut

sub server_info
{
   my $self = shift;
   my ( $key ) = @_;

   return $self->{Protocol_IRC_server_info}{$key};
}

sub on_message_RPL_MYINFO
{
   my $self = shift;
   my ( $message, $hints ) = @_;

   @{$self->{Protocol_IRC_server_info}}{qw( host version usermodes channelmodes )} =
      @{$hints}{qw( serverhost serverversion usermodes channelmodes )};

   return 0;
}

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>

=cut

0x55AA;
