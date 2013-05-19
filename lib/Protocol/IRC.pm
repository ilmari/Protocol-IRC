#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2010-2013 -- leonerd@leonerd.org.uk

package Protocol::IRC;

use strict;
use warnings;

our $VERSION = '0.01';

use Carp;

use Protocol::IRC::Message;

# This should be mixed in MI-style

=head1 NAME

C<Protocol::IRC> - IRC protocol handling

=head2 Message Hints

When messages arrive they are passed to the C<incoming_message> method, which
the implementation must define. As well as the message, a hash of extra
information derived from or relating to the message is also given.

The following keys will be present in any message hint hash:

=over 8

=item handled => BOOL

Initially false. Will be set to true the first time a handler returns a true
value.

=item prefix_nick => STRING

=item prefix_user => STRING

=item prefix_host => STRING

Values split from the message prefix; see the C<Protocol::IRC::Message>
C<prefix_split> method.

=item prefix_name => STRING

Usually the prefix nick, or the hostname in case the nick isn't defined
(usually on server messages).

=item prefix_is_me => BOOL

True if the nick mentioned in the prefix refers to this connection.

=back

Added to this set, will be all the values returned by the message's
C<named_args> method. Some of these values may cause yet more values to be
generated.

If the message type defines a C<target_name>:

=over 8

=item * target_type => STRING

Either C<channel> or C<user>, as returned by C<classify_name>.

=item * target_is_me => BOOL

True if the target name is a user and refers to this connection.

=back

Finally, any key whose name ends in C<_nick> or C<_name> will have a
corresponding key added with C<_folded> suffixed on its name, containing the
value casefolded using C<casefold_name>. This is for the convenience of string
comparisons, hash keys, etc..

=cut

=head1 METHODS

=cut

=head2 $irc->on_read( $buffer )

Informs the protocol implementation that more bytes have been read from the
peer. This method will modify the C<$buffer> directly, and remove from it the
prefix of bytes it has consumed. Any bytes remaining should be stored by the
caller for next time.

Any messages found in the buffer will be passed, in sequence, to the
C<incoming_message> method.

=cut

sub on_read
{
   my $self = shift;
   # buffer in $_[0]

   while( $_[0] =~ s/^(.*)\x0d\x0a// ) {
      my $line = $1;
      my $message = Protocol::IRC::Message->new_from_line( $line );

      my $command = $message->command;

      my ( $prefix_nick, $prefix_user, $prefix_host ) = $message->prefix_split;

      my $hints = {
         handled => 0,

         prefix_nick  => $prefix_nick,
         prefix_user  => $prefix_user,
         prefix_host  => $prefix_host,
         # Most of the time this will be "nick", except for special messages from the server
         prefix_name  => defined $prefix_nick ? $prefix_nick : $prefix_host,
         prefix_is_me => defined $prefix_nick && $self->is_nick_me( $prefix_nick ),
      };

      if( my $named_args = $message->named_args ) {
         $hints->{$_} = $named_args->{$_} for keys %$named_args;
      }

      if( defined $hints->{text} and my $encoder = $self->encoder ) {
         $hints->{text} = $encoder->decode( $hints->{text} );
      }

      if( defined( my $target_name = $hints->{target_name} ) ) {
         $hints->{target_is_me} = $self->is_nick_me( $target_name );

         my $target_type = $self->classify_name( $target_name );
         $hints->{target_type} = $target_type;
      }

      my $prepare_method = "prepare_hints_$command";
      $self->$prepare_method( $message, $hints ) if $self->can( $prepare_method );

      foreach my $k ( grep { m/_nick$/ or m/_name$/ } keys %$hints ) {
         $hints->{"${k}_folded"} = $self->casefold_name( $hints->{$k} );
      }

      $self->incoming_message( $message, $hints );
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

      if( my $encoder = $self->encoder ) {
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

=head2 $name_folded = $irc->casefold_name( $name )

Returns the C<$name>, folded in case according to the server's C<CASEMAPPING>
C<ISUPPORT>. Such a folded name will compare using C<eq> according to whether the
server would consider it the same name.

Useful for use in hash keys or similar.

=cut

sub casefold_name
{
   my $self = shift;
   my ( $nick ) = @_;

   return undef unless defined $nick;

   my $mapping = lc( $self->isupport( "CASEMAPPING" ) || "" );

   # Squash the 'capital' [\] into lowercase {|}
   $nick =~ tr/[\\]/{|}/ if $mapping ne "ascii";

   # Most RFC 1459 implementations also squash ^ to ~, even though the RFC
   # didn't mention it
   $nick =~ tr/^/~/ unless $mapping eq "strict-rfc1459";

   return lc $nick;
}

=head1 REQUIRED METHODS

=cut

=head2 $irc->incoming_message( $message, $hints )

Informs that the given L<Protocol::IRC::Message> has been received, containing
the information in the given hints hash.

=cut

sub incoming_message { croak "Attempted to invoke abstract ->incoming_message on " . ref $_[0] }

=head2 $irc->write( $string )

Requests the byte string to be sent to the peer

=cut

sub write { croak "Attemped to invoke abstract ->write on " . ref $_[0] }

=head2 $encoder = $irc->encoder

Optional. If supplied, returns an L<Encode> object used to encode or decode
the bytes appearing in a C<text> field of a message. If set, all text strings
will be returned, and should be given, as Unicode strings. They will be
encoded or decoded using this object.

=cut

sub encoder { undef }

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>

=cut

0x55AA;
