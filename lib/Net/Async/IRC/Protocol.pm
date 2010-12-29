#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2008-2010 -- leonerd@leonerd.org.uk

package Net::Async::IRC::Protocol;

use strict;
use warnings;

our $VERSION = '0.03';

use base qw( IO::Async::Protocol::LineStream );

use Carp;

use IO::Async::Timer::Countdown;

=head1 NAME

C<Net::Async::IRC::Protocol> - send and receive IRC messages

=head1 DESCRIPTION

This subclass of L<IO::Async::Protocol::LineStream> implements an established
IRC connection that has already completed its inital login sequence and is
ready to send and receive IRC messages. It handles base message sending and
receiving, and implements ping timers.

Objects of this type would not normally be constructed directly. For IRC
clients, see L<Net::Async::IRC> which is a subclass of it. All the events,
parameters, and methods documented below are relevant there.

=cut

=head1 CONSTRUCTOR

=cut

=head2 $irc = Net::Async::IRC::Protocol->new( %args )

Returns a new instance of a C<Net::Async::IRC::Protocol> object. This object
represents a connection to a single IRC server. As it is a subclass of
C<IO::Async::Protocol::LineStream> its constructor takes any arguments for
that class, in addition to the parameters named below.

=cut

sub new
{
   my $class = shift;
   my %args = @_;

   my $on_closed = delete $args{on_closed};

   return $class->SUPER::new(
      %args,

      on_closed => sub {
         my ( $self ) = @_;

         my $loop = $self->get_loop;

         $self->{pingtimer}->stop;
         $self->{pongtimer}->stop;

         $on_closed->() if $on_closed;

         $self->{state} = { connected => 0, loggedin => 0 };
      },
   );
}

sub _init
{
   my $self = shift;
   $self->SUPER::_init( @_ );

   my $pingtime = 60;
   my $pongtime = 10;

   $self->{pingtimer} = IO::Async::Timer::Countdown->new(
      delay => $pingtime,

      on_expire => sub {
         my $now = time();

         $self->send_message( "PING", undef, "$now" );

         $self->{ping_send_time} = $now;

         $self->{pongtimer}->start;
      },
   );
   $self->add_child( $self->{pingtimer} );

   $self->{pongtimer} = IO::Async::Timer::Countdown->new(
      delay => $pongtime,

      on_expire => sub {
         $self->{on_ping_timeout}->( $self ) if $self->{on_ping_timeout};
      },
   );
   $self->add_child( $self->{pongtimer} );

   $self->{state} = { connected => 0, loggedin => 0 };
   $self->{isupport} = {};

   # Some initial defaults for isupport-derived values
   $self->{isupport}{channame_re} = qr/^[#&]/;
   $self->{isupport}{prefixflag_re} = qr/^[\@+]/;
   $self->{isupport}{chanmodes_list} = [qw( b k l imnpst )]; # TODO: ov
}

=head1 PARAMETERS

The following named parameters may be passed to C<new> or C<configure>:

=over 8

=item pingtime => NUM

Amount of quiet time, in seconds, after a message is received from the server,
until a C<PING> will be sent to check it is still alive.

=item pongtime => NUM

Timeout, in seconds, after sending a C<PING> message, to wait for a C<PONG>
response.

=item on_ping_timeout => CODE

A CODE reference to invoke if the server fails to respond to a C<PING> message
within the given timeout.

 $on_ping_timeout->( $irc )

=item on_pong_reply => CODE

A CODE reference to invoke when the server successfully sends a C<PONG> in
response of a C<PING> message.

 $on_pong_reply->( $irc, $lag )

Where C<$lag> is the response time in (fractional) seconds.

=back

=cut

sub configure
{
   my $self = shift;
   my %args = @_;

   for (qw( on_ping_timeout on_pong_reply )) {
      $self->{$_} = delete $args{$_} if exists $args{$_};
   }

   if( exists $args{pingtime} ) {
      $self->{pingtimer}->configure( delay => delete $args{pingtime} );
   }

   if( exists $args{pongtime} ) {
      $self->{pongtimer}->configure( delay => delete $args{pongtime} );
   }

   $self->SUPER::configure( %args );
}

sub setup_transport
{
   my $self = shift;
   $self->SUPER::setup_transport( @_ );

   $self->{state}{connected} = 1;
   $self->{pingtimer}->start if $self->{pingtimer} and $self->get_loop;
}

sub teardown_transport
{
   my $self = shift;

   $self->{state} = { connected => 0, loggedin => 0 };
   $self->{pingtimer}->stop if $self->{pingtimer} and $self->get_loop;

   $self->SUPER::teardown_transport( @_ );
}

=head1 METHODS

=cut

=head2 $connect = $irc->is_connected

Returns true if a connection to the server is established. Note that even
after a successful connection, the server may not yet logged in to. See also
the C<is_loggedin> method.

=cut

sub is_connected
{
   my $self = shift;
   return $self->{state}{connected};
}

=head2 $loggedin = $irc->is_loggedin

Returns true if the server has been logged in to.

=cut

sub is_loggedin
{
   my $self = shift;
   return $self->{state}{loggedin};
}

sub on_read_line
{
   my $self = shift;
   my ( $line ) = @_;

   my $message = Net::Async::IRC::Message->new_from_line( $line );

   my $pingtimer = $self->{pingtimer};

   $pingtimer->is_running ? $pingtimer->reset : $pingtimer->start;
   $self->incoming_message( $message );

   return 1;
}

=head2 $irc->send_message( $message )

Sends a message to the server from the given C<Net::Async::IRC::Message>
object.

=head2 $irc->send_message( $command, $prefix, @args )

Sends a message to the server directly from the given arguments.

=cut

sub send_message
{
   my $self = shift;

   $self->is_connected or croak "Cannot send message without being connected";

   my $message;

   if( @_ == 1 ) {
      $message = shift;
   }
   else {
      my ( $command, $prefix, @args ) = @_;

      if( my $encoder = $self->{encoder} ) {
         my $argnames = Net::Async::IRC::Message->arg_names( $command );

         if( defined( my $i = $argnames->{text} ) ) {
            $args[$i] = $encoder->encode( $args[$i] ) if defined $args[$i];
         }
      }

      $message = Net::Async::IRC::Message->new( $command, $prefix, @args );
   }

   $self->write_line( $message->stream_to_line );
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
C<ISUPPORT> settings.

As well as the actual C<ISUPPORT> values set by the server, a number of
derived values are also calculated. Their names are all lowercase and contain
underscores, to distinguish them from the uppercase names without underscores
that the server usually sets.

=over 8

=item prefix_modes => STRING

The mode characters from C<PREFIX> (e.g. C<@%+>)

=item prefix_flags => STRING

The flag characters from C<PREFIX> (e.g. C<ohv>)

=item prefixflag_re => Regexp

A precompiled regexp that matches any of the prefix flags

=item prefix_map_m2f => HASH

A map from mode characters to flag characters

=item prefix_map_f2m => HASH

A map from flag characters to mode characters

=item chanmodes_list => ARRAY

A 4-element array containing the split portions of C<CHANMODES>;

 [ $listmodes, $argmodes, $argsetmodes, $boolmodes ]

=item casemap_1459 => BOOLEAN

True if the C<CASEMAPPING> parameter is not C<ascii>; i.e. it is some form of
RFC 1459 mapping

=item casemap_1459_strict => BOOLEAN

True if the C<CASEMAPPING> parameter is exactly C<strict-rfc1459>

=back

=cut

sub _set_isupport
{
   my $self = shift;
   my ( $isupport ) = @_;

   foreach my $name ( keys %$isupport ) {
      my $value = $isupport->{$name};

      $value = 1 if !defined $value;

      $self->{isupport}{$name} = $value;

      if( $name eq "PREFIX" ) {
         my $prefix = $value;

         my ( $prefix_modes, $prefix_flags ) = $prefix =~ m/^\(([a-z]+)\)(.+)$/;

         $self->{isupport}{prefix_modes} = $prefix_modes;
         $self->{isupport}{prefix_flags} = $prefix_flags;

         $self->{isupport}{prefixflag_re} = qr/[$prefix_flags]/;

         my %prefix_map;
         $prefix_map{substr $prefix_modes, $_, 1} = substr $prefix_flags, $_, 1 for ( 0 .. length($prefix_modes) - 1 );

         $self->{isupport}{prefix_map_m2f} = \%prefix_map;
         $self->{isupport}{prefix_map_f2m} = { reverse %prefix_map };
      }
      elsif( $name eq "CHANMODES" ) {
         $self->{isupport}{chanmodes_list} = [ split( m/,/, $value ) ];
      }
      elsif( $name eq "CASEMAPPING" ) {
         $self->{isupport}{casemap_1459} = ( lc $value ne "ascii" ); # RFC 1459 unless we're told not
         $self->{isupport}{casemap_1459_strict} = ( lc $value eq "strict-rfc1459" );
      }
      elsif( $name eq "CHANTYPES" ) {
         $self->{isupport}{channame_re} = qr/^[$value]/;
      }
   }
}

=head2 $value = $irc->isupport( $key )

Returns an item of information from the server's C<005 ISUPPORT> lines.
Traditionally IRC servers use all-capital names for keys.

=cut

sub isupport
{
   my $self = shift;
   my ( $flag ) = @_;

   return exists $self->{isupport}->{$flag} ? 
                 $self->{isupport}->{$flag} : undef;
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

   my $PREFIX_FLAGS = $self->isupport( "prefix_flags" );

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

   return $self->{isupport}{prefix_map_m2f}{$mode};
}

=head2 $mode = $irc->prefix_flag2mode( $flag )

The inverse of C<prefix_mode2flag>.

=cut

sub prefix_flag2mode
{
   my $self = shift;
   my ( $flag ) = @_;

   return $self->{isupport}{prefix_map_f2m}{$flag};
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

   # Squash the 'capital' [\] into lowercase {|}
   $nick =~ tr/[\\]/{|}/ if $self->{isupport}{casemap_1459};

   # Most RFC 1459 implementations also squash ^ to ~, even though the RFC
   # didn't mention it
   $nick =~ tr/^/~/ unless $self->{isupport}{casemap_1459_strict};

   return lc $nick;
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

   return "channel" if $name =~ $self->{isupport}{channame_re};
   return "user"; # TODO: Perhaps we can be a bit stricter - only check for valid nick chars?
}

# Keep perl happy; keep Britain tidy
1;

__END__

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>
