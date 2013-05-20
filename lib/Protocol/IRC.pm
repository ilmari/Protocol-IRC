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

=head1 MESSAGE HANDLING

Every incoming message causes a sequence of message handling to occur. First,
the message is parsed, and a hash of data about it is created; this is called
the hints hash. The message and this hash are then passed down a sequence of
potential handlers.

Each handler indicates by return value, whether it considers the message to
have been handled. Processing of the message is not interrupted the first time
a handler declares to have handled a message. Instead, the hints hash is marked
to say it has been handled. Later handlers can still inspect the message or its
hints, using this information to decide if they wish to take further action.

A message with a command of C<COMMAND> will try handlers in following places:

=over 4

=item 1.

A method called C<on_message_COMMAND>

 $irc->on_message_COMMAND( $message, \%hints )

=item 2.

A method called C<on_message>

 $irc->on_message( 'COMMAND', $message, \%hints )

=back

=head2 Message Hints

When messages arrive they are passed to the appropriate message handling
method, which the implementation may define. As well as the message, a hash
of extra information derived from or relating to the message is also given.

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

      $self->invoke( "on_message_$command", $message, $hints ) and $hints->{handled} = 1;
      $self->invoke( "on_message", $command, $message, $hints ) and $hints->{handled} = 1;
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

=head1 ISUPPORT-DRIVEN UTILITIES

The following methods are controlled by the server information given in the
C<ISUPPORT> settings. They use the C<isupport> required method to query the
information required.

=cut

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

=head2 $cmp = $irc->cmp_prefix_flags( $lhs, $rhs )

Compares two channel occupant prefix flags, and returns a signed integer to
indicate which of them has higher priviledge, according to the server's
ISUPPORT declaration. Suitable for use in a C<sort()> function or similar.

=cut

sub cmp_prefix_flags
{
   my $self = shift;
   my ( $lhs, $rhs ) = @_;

   return undef unless defined $lhs and defined $rhs;

   # As a special case, compare emptystring as being lower than voice
   return 0 if $lhs eq "" and $rhs eq "";
   return 1 if $rhs eq "";
   return -1 if $lhs eq "";

   my $PREFIX_FLAGS = $self->isupport( 'prefix_flags' );

   ( my $lhs_index = index $PREFIX_FLAGS, $lhs ) > -1 or return undef;
   ( my $rhs_index = index $PREFIX_FLAGS, $rhs ) > -1 or return undef;

   # IRC puts these in greatest-first, so we need to swap the ordering here
   return $rhs_index <=> $lhs_index;
}

=head2 $cmp = $irc->cmp_prefix_modes( $lhs, $rhs )

Similar to C<cmp_prefix_flags>, but compares channel occupant C<MODE> command
flags.

=cut

sub cmp_prefix_modes
{
   my $self = shift;
   my ( $lhs, $rhs ) = @_;

   return undef unless defined $lhs and defined $rhs;

   my $PREFIX_MODES = $self->isupport( "prefix_modes" );

   ( my $lhs_index = index $PREFIX_MODES, $lhs ) > -1 or return undef;
   ( my $rhs_index = index $PREFIX_MODES, $rhs ) > -1 or return undef;

   # IRC puts these in greatest-first, so we need to swap the ordering here
   return $rhs_index <=> $lhs_index;
}

=head2 $flag = $irc->prefix_mode2flag( $mode )

Converts a channel occupant C<MODE> flag (such as C<o>) into a name prefix
flag (such as C<@>).

=cut

sub prefix_mode2flag
{
   my $self = shift;
   my ( $mode ) = @_;

   return $self->isupport( 'prefix_map_m2f' )->{$mode};
}

=head2 $mode = $irc->prefix_flag2mode( $flag )

The inverse of C<prefix_mode2flag>.

=cut

sub prefix_flag2mode
{
   my $self = shift;
   my ( $flag ) = @_;

   return $self->isupport( 'prefix_map_f2m' )->{$flag};
}

=head2 $classification = $irc->classify_name( $name )

Returns C<channel> if the given name matches the pattern of names allowed for
channels according to the server's C<CHANTYPES> C<ISUPPORT>. Returns C<user>
if not.

=cut

sub classify_name
{
   my $self = shift;
   my ( $name ) = @_;

   return "channel" if $name =~ $self->isupport( "channame_re" );
   return "user"; # TODO: Perhaps we can be a bit stricter - only check for valid nick chars?
}

=head1 INTERNAL MESSAGE HANDLING

The following messages are handled internally by C<Protocol::IRC>.

=cut

=head2 PING

C<PING> messages are automatically replied to with C<PONG>.

=cut

sub on_message_PING
{
   my $self = shift;
   my ( $message, $hints ) = @_;

   $self->send_message( "PONG", undef, $message->named_args->{text} );

   return 1;
}

=head1 REQUIRED METHODS

=cut

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

=head2 $result = $irc->invoke( $name, @args )

Optional. If provided, invokes the message handling routine called C<$name>
with the given arguments. A default implementation is provided which simply
attempts to invoke a method of the given name, or return false if no method
of that name exists.

If an implementation does override this method, care should be taken to ensure
that methods are tested for and invoked if present, in addition to any other
work the method wishes to perform, as this is the basis by which derived
message handling works.

=cut

sub invoke
{
   my $self = shift;
   my ( $name, @args ) = @_;
   return unless $self->can( $name );
   return $self->$name( @args );
}

=head2 $value = $irc->isupport( $field )

Should return the value of the given C<ISUPPORT> field.

As well as the all-capitals server-supplied fields, the following fields may
be requested. Their names are all lowercase and contain underscores, to
distinguish them from server-supplied fields.

=over 8

=item prefix_modes => STRING

The mode characters from C<PREFIX> (e.g. C<ohv>)

=item prefix_flags => STRING

The flag characters from C<PREFIX> (e.g. C<@%+>)

=item prefixflag_re => Regexp

A precompiled regexp that matches any of the prefix flags

=item prefix_map_m2f => HASH

A map from mode characters to flag characters

=item prefix_map_f2m => HASH

A map from flag characters to mode characters

=item chanmodes_list => ARRAY

A 4-element array containing the split portions of C<CHANMODES>;

 [ $listmodes, $argmodes, $argsetmodes, $boolmodes ]

=item channame_re => Regexp

A precompiled regexp that matches any string beginning with a channel prefix
character in C<CHANTYPES>.

=back

=cut

sub isupport { croak "Attempted to invoke abstract ->isupport on " . ref $_[0] }

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>

=cut

0x55AA;
