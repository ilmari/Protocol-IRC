#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2010-2013 -- leonerd@leonerd.org.uk

package Protocol::IRC;

use strict;
use warnings;

our $VERSION = '0.01';

use Carp;

# This should be mixed in MI-style

=head1 NAME

C<Protocol::IRC> - IRC protocol handling

=cut

=head1 METHODS

=cut

=head2 $irc->on_read( $buffer )

Informs the protocol implementation that more bytes have been read from the
peer. This method will modify the C<$buffer> directly, and remove from it the
prefix of bytes it has consumed. Any bytes remaining should be stored by the
caller for next time.

=cut

sub on_read
{
   my $self = shift;
   # buffer in $_[0]

   while( $_[0] =~ s/^(.*)\x0d\x0a// ) {
      my $line = $1;
      my $message = Protocol::IRC::Message->new_from_line( $line );

      $self->incoming_message( $message );
   }
}

=head2 $irc->send_message( $message )

Sends a message to the peer from the given C<Protocol::IRC::Message>
object.

=head2 $irc->send_message( $command, $prefix, @args )

Sends a message to the peer directly from the given arguments.

=cut

sub send_message
{
   my $self = shift;

   my $message;

   if( @_ == 1 ) {
      $message = shift;
   }
   else {
      my ( $command, $prefix, @args ) = @_;

      if( my $encoder = $self->{encoder} ) {
         my $argnames = Protocol::IRC::Message->arg_names( $command );

         if( defined( my $i = $argnames->{text} ) ) {
            $args[$i] = $encoder->encode( $args[$i] ) if defined $args[$i];
         }
      }

      $message = Protocol::IRC::Message->new( $command, $prefix, @args );
   }

   $self->write( $message->stream_to_line . "\x0d\x0a" );
}

=head2 $irc->send_ctcp( $prefix, $target, $verb, $argstr )

Shortcut to sending a CTCP message. Sends a PRIVMSG to the given target,
containing the given verb and argument string.

=cut

sub send_ctcp
{
   my $self = shift;
   my ( $prefix, $target, $verb, $argstr ) = @_;

   $self->send_message( "PRIVMSG", undef, $target, "\001$verb $argstr\001" );
}

=head2 $irc->send_ctcprely( $prefix, $target, $verb, $argstr )

Shortcut to sending a CTCP reply. As C<send_ctcp> but using a NOTICE instead.

=cut

sub send_ctcpreply
{
   my $self = shift;
   my ( $prefix, $target, $verb, $argstr ) = @_;

   $self->send_message( "NOTICE", undef, $target, "\001$verb $argstr\001" );
}

=head1 REQUIRED METHODS

=cut

=head2 $irc->incoming_message( $message )

=cut

sub incoming_message { croak "Attempted to invoke abstract ->incoming_message on " . ref $_[0] }

=head2 $irc->write( $string )

Requests the byte string to be sent to the peer

=cut

sub write { croak "Attemped to invoke abstract ->write on " . ref $_[0] }

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>

=cut

0x55AA;
