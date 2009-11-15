#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2008,2009 -- leonerd@leonerd.org.uk

package Net::Async::IRC;

use strict;
use warnings;

our $VERSION = '0.01';

use base qw( IO::Async::Stream );

use Carp;

use Socket qw( SOCK_STREAM );
use Time::HiRes qw( time );

use Net::Async::IRC::Message;

use IO::Async::Timer::Countdown;

use constant STATE_UNCONNECTED => 0; # No network connection
use constant STATE_CONNECTING  => 1; # Awaiting network connection
use constant STATE_CONNECTED   => 2; # Socket connected
use constant STATE_LOGGEDIN    => 3; # USER/NICK send, server confirmed login

use Encode qw( find_encoding );

my $CRLF = "\x0d\x0a"; # More portable than \r\n

=head1 NAME

C<Net::Async::IRC> - Asynchronous IRC client

=head1 SYNOPSIS

 TODO

=head1 DESCRIPTION

This object class implements an asynchronous IRC client, for use in programs
based on L<IO::Async>.

This documentation is very much still in a state of TODO; it is being released
now in the hope it is currently somewhat useful, with the intention of putting
more work into both the code and its documentation at some near point in the
future.

=cut

=head1 CONSTRUCTOR

=cut

=head2 $irc = Net::Async::IRC->new( %args )

Returns a new instance of a C<Net::Async::IRC> object. This object represents
a connection to a single IRC server. As it is a subclass of
C<IO::Async::Stream> its constructor takes any arguments for that class, in
addition to the parameters named below.

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

         $self->{state} = STATE_UNCONNECTED;
      },
   );
}

sub _init
{
   my $self = shift;

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

   $self->{pingtimer}->start if defined $self->read_handle;

   $self->{pongtimer} = IO::Async::Timer::Countdown->new(
      delay => $pongtime,

      on_expire => sub {
         $self->{on_ping_timeout}->( $self ) if $self->{on_ping_timeout};
      },
   );
   $self->add_child( $self->{pongtimer} );

   $self->{server_info} = {};
   $self->{isupport} = {};

   # Some initial defaults for isupport-derived values
   $self->{channame_re} = qr/^[#&]/;
   $self->{prefixflag_re} = qr/^[\@+]/;
   $self->{isupport}->{CHANMODES_LIST} = [qw( b k l imnpst )]; # TODO: ov
}

=head1 PARAMETERS

The following named parameters may be passed to C<new> or C<configure>:

=over 8

=item on_message => CODE

A CODE reference to the generic message handler; see C<MESSAGE HANDLING>
below.

=item on_message_* => CODE

Any parameter whose name starts with C<on_message_> can be installed as a
handler for a specific message, in preference to the generic handler. See
C<MESSAGE HANDLING>.

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

=item nick => STRING

=item user => STRING

=item realname => STRING

Connection details. See also C<connect>, C<login>.

If C<user> is not supplied, it will default to either C<$ENV{LOGNAME}> or the
current user's name as supplied by C<getpwuid()>.

If unconnected, changing these properties will set the default values to use
when logging in.

If logged in, changing the C<nick> property is equivalent to calling
C<set_nick>. Changing the other properties will not take effect until the next
login.

=item encoding => STRING

If supplied, sets an encoding to use to encode outgoing messages and decode
incoming messages.

=back

=cut

sub configure
{
   my $self = shift;
   my %args = @_;

   $self->{$_} = delete $args{$_} for grep m/^on_message/, keys %args;

   for (qw( on_ping_timeout on_pong_reply user realname )) {
      $self->{$_} = delete $args{$_} if exists $args{$_};
   }

   if( exists $args{pingtime} ) {
      $self->{pingtimer}->configure( delay => delete $args{pingtime} );
   }

   if( exists $args{pongtime} ) {
      $self->{pongtimer}->configure( delay => delete $args{pongtime} );
   }

   if( exists $args{nick} ) {
      $self->set_nick( delete $args{nick} );
   }

   if( !defined $self->{user} ) {
      $self->{user} = $ENV{LOGNAME} || getpwuid($>);
   }

   if( !defined $self->{realname} ) {
      $self->{realname} = "Net::Async::IRC client $VERSION";
   }

   if( exists $args{encoding} ) {
      my $encoding = delete $args{encoding};
      my $obj = find_encoding( $encoding );
      defined $obj or croak "Cannot handle an encoding of '$encoding'";
      $self->{encoder} = $obj;
   }

   $self->SUPER::configure( %args );

   if( defined $self->read_handle ) {
      $self->{state} = STATE_CONNECTED;
      $self->{pingtimer}->start if $self->{pingtimer} and $self->get_loop;
   }
   else {
      $self->{state} = STATE_UNCONNECTED;
      $self->{pingtimer}->stop if $self->{pingtimer} and $self->get_loop;
   }
}

=head1 METHODS

=cut

sub state
{
   my $self = shift;
   return $self->{state};
}

=head2 $connect = $irc->is_connected

Returns true if a connection to the server is established. Note that even
after a successful connection, the server may not yet logged in to. See also
the C<is_loggedin> method.

=cut

sub is_connected
{
   my $self = shift;
   my $state = $self->state;
   return $state == STATE_CONNECTED ||
          $state == STATE_LOGGEDIN;
}

=head2 $loggedin = $irc->is_loggedin

Returns true if the server has been logged in to.

=cut

sub is_loggedin
{
   my $self = shift;
   my $state = $self->state;
   return $state == STATE_LOGGEDIN;
}

=head2 $irc->connect( %args )

Connects to the IRC server. This method does not perform the complete IRC
login sequence; for that see instead the C<login> method.

=over 8

=item host => STRING

Hostname of the IRC server.

=item service => STRING or NUMBER

Optional. Port number or service name of the IRC server. Defaults to 6667.

=item on_connected => CODE

Continuation to invoke once the connection has been established. Usually used
by the C<login> method to perform the actual login sequence.

 $on_connected->( $irc )

=item on_error => CODE

Continuation to invoke in the case of an error preventing the connection from
taking place.

 $on_error->( $errormsg )

=back

Any other arguments are passed into the underlying C<IO::Async::Loop>
C<connect> method.

=cut

# TODO: Most of this needs to be moved into an abstract Net::Async::Connection role
sub connect
{
   my $self = shift;
   my %args = @_;

   $self->{state} == STATE_UNCONNECTED or croak "Cannot ->connect - not in unconnected state";

   my $loop = $self->get_loop or croak "Cannot ->connect a ".ref($self)." that is not in a Loop";

   my $on_connected = delete $args{on_connected};
   ref $on_connected eq "CODE" or croak "Expected 'on_connected' as CODE reference";

   my $on_error = delete $args{on_error};

   $self->{state} = STATE_CONNECTING;

   $args{service}  ||= "6667";
   $args{socktype} ||= SOCK_STREAM;

   $loop->connect(
      %args,

      on_connected => sub {
         my ( $sock ) = @_;

         $self->set_handle( $sock );

         $on_connected->( $self );
      },

      on_resolve_error => sub {
         my ( $msg ) = @_;
         chomp $msg;

         $self->{state} = STATE_UNCONNECTED;

         if( $args{on_resolve_error} ) {
            $args{on_resolve_error}->( $msg );
         }
         else {
            $on_error->( "Cannot resolve - $msg" );
         }
      },

      on_connect_error => sub {
         $self->{state} = STATE_UNCONNECTED;

         if( $args{on_connect_error} ) {
            $args{on_connect_error}->( @_ );
         }
         else {
            $on_error->( "Cannot connect" );
         }
      },
   );
}

=head2 $irc->login( %args )

Logs in to the IRC network, connecting first using the C<connect> method if
required. Takes the following named arguments:

=over 8

=item nick => STRING

=item user => STRING

=item realname => STRING

IRC connection details. Defaults can be set with the C<new> or C<configure>
methods.

=item pass => STRING

Server password to connect with.

=item on_login => CODE

A continuation to invoke once login is successful.

 $on_login->( $irc )

=back

Any other arguments that are passed, are forwarded to the C<connect> method if
it is required; i.e. if C<login> is invoked when not yet connected to the
server.

=cut

sub login
{
   my $self = shift;
   my %args = @_;

   my $nick     = delete $args{nick} || $self->{nick} or croak "Need a login nick";
   my $user     = delete $args{user} || $self->{user} or croak "Need a login user";
   my $realname = delete $args{realname} || $self->{realname};
   my $pass     = delete $args{pass};

   if( !defined $self->{nick} ) {
      $self->set_nick( $nick );
   }

   my $on_login = delete $args{on_login};
   ref $on_login eq "CODE" or croak "Expected 'on_login' as a CODE reference";

   if( $self->{state} == STATE_CONNECTED ) {
      $self->send_message( "PASS", undef, $pass ) if defined $pass;

      $self->send_message( "USER", undef, $user, "0", "*", $realname );

      $self->send_message( "NICK", undef, $nick );

      $self->{on_login} = $on_login;
   }
   elsif( $self->{state} == STATE_UNCONNECTED ) {
      $self->connect(
         %args,

         on_connected => sub {
            $self->login(
               nick     => $nick,
               user     => $user,
               realname => $realname,
               pass     => $pass,

               on_login => $on_login,
            );
         },
      );
   }
   else {
      croak "Cannot login - bad state $self->{state}";
   }
}

# for IO::Async::Stream
sub on_read
{
   my $self = shift;
   my ( $buffref, $closed ) = @_;

   if( $$buffref =~ s/^(.*)$CRLF// ) {
      my $message = Net::Async::IRC::Message->new_from_line( $1 );

      my $pingtimer = $self->{pingtimer};

      $pingtimer->is_running ? $pingtimer->reset : $pingtimer->start;
      $self->incoming_message( $message );

      return 1;
   }

   return 0;
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

   $self->write( $message->stream_to_line . $CRLF );
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

=head2 $me = $irc->is_nick_me( $nick )

Returns true if the given nick refers to that in use by the connection.

=cut

sub is_nick_me
{
   my $self = shift;
   my ( $nick ) = @_;

   return $self->casefold_name( $nick ) eq $self->{nick_folded};
}

# ISUPPORT and related

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

   return $self->{server_info}{$key};
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

   my $PREFIX_FLAGS = $self->isupport( "PREFIX_FLAGS" );

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

   my $PREFIX_MODES = $self->isupport( "PREFIX_MODES" );

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

   return $self->{isupport}->{PREFIX_MAP_M2F}->{$mode};
}

=head2 $mode = $irc->prefix_flag2mode( $flag )

The inverse of C<prefix_mode2flag>.

=cut

sub prefix_flag2mode
{
   my $self = shift;
   my ( $flag ) = @_;

   return $self->{isupport}->{PREFIX_MAP_F2M}->{$flag};
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
   $nick =~ tr/[\\]/{|}/ if $self->{casemap_1459};

   # Most RFC 1459 implementations also squash ^ to ~, even though the RFC
   # didn't mention it
   $nick =~ tr/^/~/ unless $self->{casemap_1459_strict};

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

   return "channel" if $name =~ $self->{channame_re};
   return "user"; # TODO: Perhaps we can be a bit stricter - only check for valid nick chars?
}

=head2 $nick = $irc->nick

Returns the current nick in use by the connection.

=cut

sub nick
{
   my $self = shift;
   return $self->{nick};
}

=head2 $nick_folded = $irc->nick_folded

Returns the current nick in use by the connection, folded by C<casefold_name>
for convenience.

=cut

sub nick_folded
{
   my $self = shift;
   return $self->{nick_folded};
}

# internal
sub set_nick
{
   my $self = shift;
   ( $self->{nick} ) = @_;
   $self->{nick_folded} = $self->casefold_name( $self->{nick} );
}

=head2 $irc->change_nick( $newnick )

Requests to change the nick. If unconnected, the change happens immediately
to the stored defaults. If logged in, sends a C<NICK> command to the server,
which may suceed or fail at a later point.

=cut

sub change_nick
{
   my $self = shift;
   my ( $newnick ) = @_;

   if( $self->{state} == STATE_UNCONNECTED or $self->{state} == STATE_CONNECTING ) {
      $self->set_nick( $newnick );
   }
   elsif( $self->{state} == STATE_CONNECTED or $self->{state} == STATE_LOGGEDIN ) {
      $self->send_message( "NICK", undef, $newnick );
   }
   else {
      croak "Cannot change_nick - bad state $self->{state}";
   }
}

=head1 MESSAGE HANDLING

TODO

=cut

# Try to run the named method, returning undef if the method doesn't exist
sub _invoke
{
   my $self = shift;
   my $method = shift;

   return $self->{$method}->( $self, @_ ) if $self->{$method};
   return $self->$method( @_ ) if $self->can( $method );
   return undef;
}

sub incoming_message
{
   my $self = shift;
   my ( $message ) = @_;

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

   if( defined $hints->{text} and $self->{encoder} ) {
      $hints->{text} = $self->{encoder}->decode( $hints->{text} );
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

   $self->_invoke( "on_message_$command", $message, $hints ) and $hints->{handled} = 1;
   $self->_invoke( "on_message", $command, $message, $hints ) and $hints->{handled} = 1;
}

#########################
# Prepare hints methods #
#########################

sub prepare_hints_channelmode
{
   my $self = shift;
   my ( $message, $hints ) = @_;

   my ( $listmodes, $argmodes, $argsetmodes, $boolmodes ) = @{ $self->{isupport}->{CHANMODES_LIST} };

   my $modechars = $hints->{modechars};
   my @modeargs = @{ $hints->{modeargs} };

   my @modes; # [] -> { type => $, sense => $, mode => $, arg => $ }

   my $sense = 0;
   foreach my $modechar ( split( m//, $modechars ) ) {
      $sense =  1, next if $modechar eq "+";
      $sense = -1, next if $modechar eq "-";

      my $hasarg;

      my $mode = {
         mode  => $modechar,
         sense => $sense,
      };

      if( index( $listmodes, $modechar ) > -1 ) {
         $mode->{type} = 'list';
         $mode->{value} = shift @modeargs if ( $sense != 0 );
      }
      elsif( index( $argmodes, $modechar ) > -1 ) {
         $mode->{type} = 'value';
         $mode->{value} = shift @modeargs if ( $sense != 0 );
      }
      elsif( index( $argsetmodes, $modechar ) > -1 ) {
         $mode->{type} = 'value';
         $mode->{value} = shift @modeargs if ( $sense > 0 );
      }
      elsif( index( $boolmodes, $modechar ) > -1 ) {
         $mode->{type} = 'bool';
      }
      elsif( my $flag = $self->prefix_mode2flag( $modechar ) ) {
         $mode->{type} = 'occupant';
         $mode->{flag} = $flag;
         $mode->{nick} = shift @modeargs if ( $sense != 0 );
         $mode->{nick_folded} = $self->casefold_name( $mode->{nick} );
      }
      else {
         # TODO: Err... not recognised ... what do I do?
      }

      # TODO: Consider a per-mode event here...

      push @modes, $mode;
   }

   $hints->{modes} = \@modes;
}

sub prepare_hints_MODE
{
   my $self = shift;
   my ( $message, $hints ) = @_;

   if( $hints->{target_type} eq "channel" ) {
      $self->prepare_hints_channelmode( $message, $hints );
   }
}

sub prepare_hints_324 # RPL_CHANNELMODEIS
{
   my $self = shift;
   my ( $message, $hints ) = @_;

   $self->prepare_hints_channelmode( $message, $hints );
}

#################################
# Methods for incremental lists #
#################################

sub build_list
{
   my $self = shift;
   my ( $list, $target, $value ) = @_;

   $target = "" if !defined $target;

   push @{ $self->{buildlist}{$target}{$list} }, $value;
}

sub build_list_from_hints
{
   my $self = shift;
   my ( $list, $hints, @keys ) = @_;

   my %value;
   @value{@keys} = @{$hints}{@keys};

   $self->build_list( $list, $hints->{target_name_folded}, \%value );
}

sub pull_list
{
   my $self = shift;
   my ( $list, $target ) = @_;

   $target = "" if !defined $target;

   return delete $self->{buildlist}{$target}{$list};
}

sub pull_list_and_invoke
{
   my $self = shift;
   my ( $list, $message, $hints ) = @_;

   my $values = $self->pull_list( $list, $hints->{target_name_folded} );

   my %hints = (
      %$hints,
      synthesized => 1,
      $list => $values,
   );

   $self->_invoke( "on_message_$list", $message, \%hints ) and $hints{handled} = 1;
   $self->_invoke( "on_message", $list, $message, \%hints ) and $hints{handled} = 1;

   return $hints{handled};
}

############################
# Message handling methods #
############################

sub on_message_NICK
{
   my $self = shift;
   my ( $message, $hints ) = @_;

   if( $hints->{prefix_is_me} ) {
      $self->set_nick( $hints->{new_nick} );
      return 1;
   }

   return 0;
}

sub on_message_NOTICE
{
   my $self = shift;
   my ( $message, $hints ) = @_;
   return $self->_on_message_text( $message, $hints, 1 );
}

sub on_message_PING
{
   my $self = shift;
   my ( $message, $hints ) = @_;

   $self->send_message( "PONG", undef, $hints->{text} );
   return 1;
}

sub on_message_PONG
{
   my $self = shift;
   my ( $message ) = @_;

   # Protect against spurious PONGs from the server
   return 1 unless $self->{pongtimer}->is_running;

   my $lag = time() - $self->{ping_send_time};

   $self->{current_lag} = $lag;
   $self->{on_pong_reply}->( $self, $lag ) if $self->{on_pong_reply};

   $self->{pongtimer}->stop;

   return 1;
}

sub on_message_PRIVMSG
{
   my $self = shift;
   my ( $message, $hints ) = @_;
   return $self->_on_message_text( $message, $hints, 0 );
}

sub _on_message_text
{
   my $self = shift;
   my ( $message, $hints, $is_notice ) = @_;

   my %hints = (
      %$hints,
      synthesized => 1,
      is_notice => $is_notice,
   );

   # TODO: In client->server messages this might be a comma-separated list
   my $target = delete $hints{targets};

   my $restriction = "";
   while( $target =~ $self->{prefixflag_re} ) {
      $restriction .= substr( $target, 0, 1, "" );
   }

   $hints{target_name} = $target;
   $hints{target_name_folded} = $self->casefold_name( $target );

   my $type = $hints{target_type} = $self->classify_name( $target );

   if( $type eq "channel" ) {
      $hints{restriction} = $restriction;
      $hints{target_is_me} = '';
   }
   elsif( $type eq "user" ) {
      # TODO: user messages probably can't have restrictions. What to do
      # if we got one?
      $hints{target_is_me} = $self->is_nick_me( $target );
   }

   my $text = $hints->{text};

   if( $text =~ m/^\x01(.*)\x01$/ ) {
      ( my $verb, $text ) = split( m/ /, $1, 2 );
      $hints{ctcp_verb} = $verb;
      $hints{ctcp_args} = $text;

      my $ctcptype = $is_notice ? "ctcpreply" : "ctcp";

      $self->_invoke( "on_message_${ctcptype}_$verb", $message, \%hints ) and $hints{handled} = 1;
      $self->_invoke( "on_message_${ctcptype}", $verb, $message, \%hints ) and $hints{handled} = 1;
      $self->_invoke( "on_message", "$ctcptype $verb", $message, \%hints ) and $hints{handled} = 1;
   }
   else {
      $hints{text} = $text;

      $self->_invoke( "on_message_text", $message, \%hints ) and $hints{handled} = 1;
      $self->_invoke( "on_message", "text", $message, \%hints ) and $hints{handled} = 1;
   }

   return $hints{handled};
}

sub on_message_001
{
   my $self = shift;
   my ( $message ) = @_;

   $self->{on_login}->( $self ) if defined $self->{on_login};
   $self->{state} = STATE_LOGGEDIN;
   undef $self->{on_login};

   # Don't eat it
   return 0;
}

sub on_message_004
{
   my $self = shift;
   my ( $message, $hints ) = @_;

   @{$self->{server_info}}{qw( host version usermodes channelmodes )} =
      @{$hints}{qw( serverhost serverversion usermodes channelmodes )};

   return 0;
}

sub on_message_005
{
   my $self = shift;
   my ( $message, $hints ) = @_;

   foreach ( @{ $hints->{isupport} } ) {
      next unless m/^([A-Z]+)(?:=(.*))?$/;
      my ( $name, $value ) = ( $1, $2 );

      $value = 1 if !defined $value;

      $self->{isupport}->{$name} = $value;

      if( $name eq "PREFIX" ) {
         my $prefix = $value;

         my ( $prefix_modes, $prefix_flags ) = $prefix =~ m/^\(([a-z]+)\)(.+)$/;

         $self->{isupport}->{PREFIX_MODES} = $prefix_modes;
         $self->{isupport}->{PREFIX_FLAGS} = $prefix_flags;

         $self->{prefixflag_re} = qr/^[$prefix_flags]/;

         my %prefix_map;
         $prefix_map{substr $prefix_modes, $_, 1} = substr $prefix_flags, $_, 1 for ( 0 .. length($prefix_modes) - 1 );

         $self->{isupport}->{PREFIX_MAP_M2F} = \%prefix_map;
         $self->{isupport}->{PREFIX_MAP_F2M} = { reverse %prefix_map };
      }
      elsif( $name eq "CHANMODES" ) {
         $self->{isupport}->{CHANMODES_LIST} = [ split( m/,/, $value ) ];
      }
      elsif( $name eq "CASEMAPPING" ) {
         $self->{casemap_1459} = ( lc $value ne "ascii" ); # RFC 1459 unless we're told not
         $self->{casemap_1459_strict} = ( lc $value eq "strict-rfc1459" );

         $self->{nick_folded} = $self->casefold_name( $self->{nick} );
      }
      elsif( $name eq "CHANTYPES" ) {
         $self->{channame_re} = qr/^[$value]/;
      }
   }

   return 0;
}

sub on_message_315 # RPL_ENDOFWHO
{
   my $self = shift;
   my ( $message, $hints ) = @_;
   $self->pull_list_and_invoke( "who", $message, $hints );
}

sub on_message_352 # RPL_WHOREPLY
{
   my $self = shift;
   my ( $message, $hints ) = @_;
   $self->build_list_from_hints( "who", $hints,
      qw( user_ident user_host user_server user_nick user_nick_folded user_flags )
   );
   return 1;
}

sub on_message_353 # RPL_NAMES
{
   my $self = shift;
   my ( $message, $hints ) = @_;

   my @names = split( m/ /, $hints->{names} );
   $self->build_list( "names", $hints->{target_name_folded}, $_ ) foreach @names;

   return 1;
}

sub on_message_366 # RPL_ENDOFNAMES
{
   my $self = shift;
   my ( $message, $hints ) = @_;

   my $names = $self->pull_list( "names", $hints->{target_name_folded} );

   my $re = qr/^($self->{prefixflag_re})?(.*)$/;

   my %names;

   foreach my $name ( @$names ) {
      my ( $flag, $nick ) = $name =~ $re or next;

      $flag ||= ''; # make sure it's defined

      $names{ $self->casefold_name( $nick ) } = { nick => $nick, flag => $flag };
   }

   my %hints = (
      %$hints,
      synthesized => 1,
      names => \%names,
   );

   $self->_invoke( "on_message_names", $message, \%hints ) and $hints{handled} = 1;
   $self->_invoke( "on_message", "names", $message, \%hints ) and $hints{handled} = 1;

   return $hints{handled};
}

sub on_message_367 # RPL_BANLIST
{
   my $self = shift;
   my ( $message, $hints ) = @_;
   $self->build_list_from_hints( "bans", $hints,
      qw( mask by_nick by_nick_folded timestamp )
   );
   return 1;
}

sub on_message_368 # RPL_ENDOFBANS
{
   my $self = shift;
   my ( $message, $hints ) = @_;
   $self->pull_list_and_invoke( "bans", $message, $hints );
}

sub on_message_372 # RPL_MOTD
{
   my $self = shift;
   my ( $message, $hints ) = @_;
   $self->build_list( "motd", undef, $hints->{text} );
   return 1;
}

sub on_message_375 # RPL_MOTDSTART
{
   my $self = shift;
   my ( $message, $hints ) = @_;
   $self->build_list( "motd", undef, $hints->{text} );
   return 1;
}

sub on_message_376 # RPL_ENDOFMOTD
{
   my $self = shift;
   my ( $message, $hints ) = @_;
   $self->pull_list_and_invoke( "motd", $message, $hints );
}

# Keep perl happy; keep Britain tidy
1;

__END__

=head1 SEE ALSO

=over 4

=item *

L<http://tools.ietf.org/html/rfc2812> - Internet Relay Chat: Client Protocol

=back

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>

