#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2010-2013 -- leonerd@leonerd.org.uk

package Net::Async::IRC::Protocol;

use strict;
use warnings;

our $VERSION = '0.06';

use base qw( IO::Async::Protocol::Stream Protocol::IRC );

use Carp;

use Protocol::IRC::Message;

use Encode qw( find_encoding );
use Time::HiRes qw( time );

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
represents a IRC connection to a peer. As it is a subclass of
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

         undef $self->{connect_f};
         undef $self->{login_f};
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

   $self->{isupport} = {};

   # Some initial defaults for isupport-derived values
   $self->{isupport}{channame_re} = qr/^[#&]/;
   $self->{isupport}{prefixflag_re} = qr/^[\@+]/;
   $self->{isupport}{chanmodes_list} = [qw( b k l imnpst )]; # TODO: ov
}

# for Protocol::IRC
sub encoder
{
   my $self = shift;
   return $self->{encoder};
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

Amount of quiet time, in seconds, after a message is received from the peer,
until a C<PING> will be sent to check it is still alive.

=item pongtime => NUM

Timeout, in seconds, after sending a C<PING> message, to wait for a C<PONG>
response.

=item on_ping_timeout => CODE

A CODE reference to invoke if the peer fails to respond to a C<PING> message
within the given timeout.

 $on_ping_timeout->( $irc )

=item on_pong_reply => CODE

A CODE reference to invoke when the peer successfully sends a C<PONG> in
response of a C<PING> message.

 $on_pong_reply->( $irc, $lag )

Where C<$lag> is the response time in (fractional) seconds.

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

   for (qw( on_ping_timeout on_pong_reply )) {
      $self->{$_} = delete $args{$_} if exists $args{$_};
   }

   if( exists $args{pingtime} ) {
      $self->{pingtimer}->configure( delay => delete $args{pingtime} );
   }

   if( exists $args{pongtime} ) {
      $self->{pongtimer}->configure( delay => delete $args{pongtime} );
   }

   if( exists $args{encoding} ) {
      my $encoding = delete $args{encoding};
      my $obj = find_encoding( $encoding );
      defined $obj or croak "Cannot handle an encoding of '$encoding'";
      $self->{encoder} = $obj;
   }

   $self->SUPER::configure( %args );
}

sub setup_transport
{
   my $self = shift;
   $self->SUPER::setup_transport( @_ );

   $self->{connect_f} = Future->new->done( $self->transport->read_handle );
   $self->{pingtimer}->start if $self->{pingtimer} and $self->get_loop;
}

sub teardown_transport
{
   my $self = shift;

   undef $self->{connect_f};
   undef $self->{login_f};
   $self->{pingtimer}->stop if $self->{pingtimer} and $self->get_loop;

   $self->SUPER::teardown_transport( @_ );
}

=head1 METHODS

=cut

=head2 $connect = $irc->is_connected

Returns true if a connection to the peer is established. Note that even
after a successful connection, the connection may not yet logged in to. See
also the C<is_loggedin> method.

=cut

sub is_connected
{
   my $self = shift;
   return 0 unless my $connect_f = $self->{connect_f};
   return $connect_f->is_ready and !$connect_f->failure;
}

=head2 $loggedin = $irc->is_loggedin

Returns true if the full login sequence has been performed on the connection
and it is ready to use.

=cut

sub is_loggedin
{
   my $self = shift;
   return 0 unless my $login_f = $self->{login_f};
   return $login_f->is_ready and !$login_f->failure;
}

sub on_read
{
   my $self = shift;
   my ( $buffref, $eof ) = @_;

   my $pingtimer = $self->{pingtimer};

   $pingtimer->is_running ? $pingtimer->reset : $pingtimer->start;

   $self->Protocol::IRC::on_read( $$buffref );
   return 0;
}

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

         my ( $prefix_modes, $prefix_flags ) = $prefix =~ m/^\(([a-z]+)\)(.+)$/i
            or warn( "Unable to parse PREFIX=$value" ), next;

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
         $self->{nick_folded} = $self->casefold_name( $self->{nick} );
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
   return $self->{isupport}{$flag};
}

=head2 $nick = $irc->nick

Returns the current nick in use by the connection.

=cut

sub _set_nick
{
   my $self = shift;
   ( $self->{nick} ) = @_;
   $self->{nick_folded} = $self->casefold_name( $self->{nick} );
}

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

=head1 MESSAGE HANDLING

A message with a command of C<COMMAND> will try handlers in following places:

=over 4

=item 1.

A CODE ref in a parameter called C<on_message_COMMAND>

 $on_message_COMMAND->( $irc, $message, \%hints )

=item 2.

A method called C<on_message_COMMAND>

 $irc->on_message_COMMAND( $message, \%hints )

=item 3.

A CODE ref in a parameter called C<on_message>

 $on_message->( $irc, 'COMMAND', $message, \%hints )

=item 4.

A method called C<on_message>

 $irc->on_message( 'COMMAND', $message, \%hints )

=back

Certain commands are handled internally by methods on the base
C<Net::Async::IRC::Protocol> class itself. These may cause other hints hash
keys to be created, or to invoke other handler methods. These are documented
below.

=cut

sub invoke
{
   my $self = shift;
   my $retref = $self->maybe_invoke_event( @_ ) or return undef;
   return $retref->[0];
}

sub on_message_NOTICE
{
   my $self = shift;
   my ( $message, $hints ) = @_;
   return $self->_on_message_text( $message, $hints, 1 );
}

sub on_message_PONG
{
   my $self = shift;
   my ( $message, $hints ) = @_;

   return 1 unless $self->{pongtimer}->is_running;

   my $lag = time - $self->{ping_send_time};

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

=head2 NOTICE and PRIVMSG

Because C<NOTICE> and C<PRIVMSG> are so similar, they are handled together by
synthesized events called C<text>, C<ctcp> and C<ctcpreply>. Depending on the
contents of the text, and whether it was supplied in a C<PRIVMSG> or a
C<NOTICE>, one of these three events will be created. 

In all cases, the hints hash will contain a C<is_notice> key being true or
false, depending on whether the original messages was a C<NOTICE> or a
C<PRIVMSG>, a C<target_name> key containing the message target name, a
case-folded version of the name in a C<target_name_folded> key, and a
classification of the target type in a C<target_type> key.

For the C<user> target type, it will contain a boolean in C<target_is_me> to
indicate if the target of the message is the user represented by this
connection.

For the C<channel> target type, it will contain a C<restriction> key
containing the channel message restriction, if present.

For normal C<text> messages, it will contain a key C<text> containing the
actual message text.

For either CTCP message type, it will contain keys C<ctcp_verb> and
C<ctcp_args> with the parsed message. The C<ctcp_verb> will contain the first
space-separated token, and C<ctcp_args> will be a string containing the rest
of the line, otherwise unmodified. This type of message is also subject to a
special stage of handler dispatch, involving the CTCP verb string. For
messages with C<VERB> as the verb, the following are tried. C<CTCP> may stand
for either C<ctcp> or C<ctcpreply>.

=over 4

=item 1.

A CODE ref in a parameter called C<on_message_CTCP_VERB>

 $on_message_CTCP_VERB->( $irc, $message, \%hints )

=item 2.

A method called C<on_message_CTCP_VERB>

 $irc->on_message_CTCP_VERB( $message, \%hints )

=item 3.

A CODE ref in a parameter called C<on_message_CTCP>

 $on_message_CTCP->( $irc, 'VERB', $message, \%hints )

=item 4.

A method called C<on_message_CTCP>

 $irc->on_message_CTCP( 'VERB', $message, \%hintss )

=item 5.

A CODE ref in a parameter called C<on_message>

 $on_message->( $irc, 'CTCP VERB', $message, \%hints )

=item 6.

A method called C<on_message>

 $irc->on_message( 'CTCP VERB', $message, \%hints )

=back

=cut

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

   my $prefixflag_re = $self->isupport( 'prefixflag_re' );

   my $restriction = "";
   while( $target =~ m/^$prefixflag_re/ ) {
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

      $self->invoke( "on_message_${ctcptype}_$verb", $message, \%hints ) and $hints{handled} = 1;
      $self->invoke( "on_message_${ctcptype}", $verb, $message, \%hints ) and $hints{handled} = 1;
      $self->invoke( "on_message", "$ctcptype $verb", $message, \%hints ) and $hints{handled} = 1;
   }
   else {
      $hints{text} = $text;

      $self->invoke( "on_message_text", $message, \%hints ) and $hints{handled} = 1;
      $self->invoke( "on_message", "text", $message, \%hints ) and $hints{handled} = 1;
   }

   return $hints{handled};
}

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>

=cut

0x55AA;
