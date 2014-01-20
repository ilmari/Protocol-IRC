#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2008-2014 -- leonerd@leonerd.org.uk

package Net::Async::IRC;

use strict;
use warnings;

our $VERSION = '0.07';

# We need to use C3 MRO to make the ->isupport etc.. methods work properly
use mro 'c3';
use base qw( Net::Async::IRC::Protocol Protocol::IRC::Client );

use Carp;

use Socket qw( SOCK_STREAM );

=head1 NAME

C<Net::Async::IRC> - use IRC with C<IO::Async>

=head1 SYNOPSIS

 use IO::Async::Loop;
 use Net::Async::IRC;

 my $loop = IO::Async::Loop->new;

 my $irc = Net::Async::IRC->new(
    on_message_text => sub {
       my ( $self, $message, $hints ) = @_;

       print "$hints->{prefix_name} says: $hints->{text}\n";
    },
 );

 $loop->add( $irc );

 $irc->login(
    nick => "MyName",
    host => "irc.example.org",
 )->get;

 $irc->send_message( "PRIVMSG", undef, "YourName", "Hello world!" );

 $loop->loop_forever;

=head1 DESCRIPTION

This object class implements an asynchronous IRC client, for use in programs
based on L<IO::Async>.

This documentation is very much still in a state of TODO; it is being released
now in the hope it is currently somewhat useful, with the intention of putting
more work into both the code and its documentation at some near point in the
future.

=cut

sub _init
{
   my $self = shift;
   $self->SUPER::_init( @_ );
}

=head1 PARAMETERS

The following named parameters may be passed to C<new> or C<configure>:

=over 8

=item nick => STRING

=item user => STRING

=item realname => STRING

Connection details. See also C<connect>, C<login>.

If C<user> is not supplied, it will default to either C<$ENV{LOGNAME}> or the
current user's name as supplied by C<getpwuid()>.

If unconnected, changing these properties will set the default values to use
when logging in.

If logged in, changing the C<nick> property is equivalent to calling
C<change_nick>. Changing the other properties will not take effect until the
next login.

=item use_caps => ARRAY of STRING

Attempts to negotiate IRC v3.1 CAP at connect time. The array gives the names
of capabilities which will be requested, if the server supports them.

=back

=cut

sub configure
{
   my $self = shift;
   my %args = @_;

   for (qw( user realname use_caps )) {
      $self->{$_} = delete $args{$_} if exists $args{$_};
   }

   if( exists $args{nick} ) {
      $self->_set_nick( delete $args{nick} );
   }

   if( !defined $self->{user} ) {
      $self->{user} = $ENV{LOGNAME} || getpwuid($>);
   }

   if( !defined $self->{realname} ) {
      $self->{realname} = "Net::Async::IRC client $VERSION";
   }

   $self->SUPER::configure( %args );
}

=head1 METHODS

=cut

=head2 $irc->connect( %args ) ==> $irc

Connects to the IRC server. This method does not perform the complete IRC
login sequence; for that see instead the C<login> method.

=over 8

=item host => STRING

Hostname of the IRC server.

=item service => STRING or NUMBER

Optional. Port number or service name of the IRC server. Defaults to 6667.

=back

Any other arguments are passed into the underlying C<IO::Async::Loop>
C<connect> method.

=head2 $irc->connect( %args )

The following additional arguments are used to provide continuations when not
returning a Future.

=over 8

=item on_connected => CODE

Continuation to invoke once the connection has been established. Usually used
by the C<login> method to perform the actual login sequence.

 $on_connected->( $irc )

=item on_error => CODE

Continuation to invoke in the case of an error preventing the connection from
taking place.

 $on_error->( $errormsg )

=back

=cut

# TODO: Most of this needs to be moved into an abstract Net::Async::Connection role
sub connect
{
   my $self = shift;
   my %args = @_;

   # Largely for unit testing
   return $self->{connect_f} ||= Future->new->done( $self ) if
      $self->read_handle;

   my $on_error = delete $args{on_error};

   $args{service} ||= "6667";

   return $self->{connect_f} ||= $self->SUPER::connect(
      %args,

      on_resolve_error => sub {
         my ( $msg ) = @_;
         chomp $msg;

         if( $args{on_resolve_error} ) {
            $args{on_resolve_error}->( $msg );
         }
         elsif( $on_error ) {
            $on_error->( "Cannot resolve - $msg" );
         }
      },

      on_connect_error => sub {
         if( $args{on_connect_error} ) {
            $args{on_connect_error}->( @_ );
         }
         elsif( $on_error ) {
            $on_error->( "Cannot connect" );
         }
      },
   )->on_fail( sub { undef $self->{connect_f} } );
}

=head2 $irc->login( %args ) ==> $irc

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

=back

Any other arguments that are passed, are forwarded to the C<connect> method if
it is required; i.e. if C<login> is invoked when not yet connected to the
server.

=head2 $irc->login( %args )

The following additional arguments are used to provide continuations when not
returning a Future.

=over 8

=item on_login => CODE

A continuation to invoke once login is successful.

 $on_login->( $irc )

=back

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
      $self->_set_nick( $nick );
   }

   my $on_login = delete $args{on_login};
   !defined $on_login or ref $on_login eq "CODE" or 
      croak "Expected 'on_login' to be a CODE reference";

   return $self->{login_f} ||= $self->connect( %args )->then( sub {
      $self->send_message( "CAP", undef, "LS" ) if $self->{use_caps};

      $self->send_message( "PASS", undef, $pass ) if defined $pass;
      $self->send_message( "USER", undef, $user, "0", "*", $realname );
      $self->send_message( "NICK", undef, $nick );

      my $f = $self->loop->new_future;

      $self->{on_login} = sub {
         $f->done;
         goto &$on_login if $on_login;
      };

      return $f;
   })->on_fail( sub { undef $self->{login_f} } );
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

   if( !$self->is_connected ) {
      $self->_set_nick( $newnick );
   }
   else {
      $self->send_message( "NICK", undef, $newnick );
   }
}

############################
# Message handling methods #
############################

sub _invoke_synthetic
{
   my $self = shift;
   my ( $command, $message, $hints, @morehints ) = @_;

   my %hints = (
      %$hints,
      synthesized => 1,
      @morehints,
   );

   $self->invoke( "on_message_$command", $message, \%hints ) and $hints{handled} = 1;
   $self->invoke( "on_message", $command, $message, \%hints ) and $hints{handled} = 1;

   return $hints{handled};
}

=head1 IRC v3.1 CAPABILITIES

The following methods relate to IRC v3.1 capabilities negotiations.

=cut

sub on_message_cap_LS
{
   my $self = shift;
   my ( $message, $hints ) = @_;

   my $supported = $self->{caps_supported} = $hints->{caps};

   my @request = grep { $supported->{$_} } @{$self->{use_caps}};

   if( @request ) {
      $self->{caps_enabled} = { map { $_ => undef } @request };
      $self->send_message( "CAP", undef, "REQ", join( " ", @request ) );
   }
   else {
      $self->send_message( "CAP", undef, "END" );
   }

   return 1;
}

*on_message_cap_ACK = *on_message_cap_NAK = \&_on_message_cap_reply;
sub _on_message_cap_reply
{
   my $self = shift;
   my ( $message, $hints ) = @_;
   my $ack = $hints->{verb} eq "ACK";

   $self->{caps_enabled}{$_} = $ack for keys %{ $hints->{caps} };

   # Are any outstanding
   !defined and return 1 for values %{ $self->{caps_enabled} };

   $self->send_message( "CAP", undef, "END" );
   return 1;
}

=head2 $caps = $irc->caps_supported

Returns a HASH whose keys give the capabilities listed by the server as
supported in its C<CAP LS> response. If the server ignored the C<CAP>
negotiation then this method returns C<undef>.

=cut

sub caps_supported
{
   my $self = shift;
   return $self->{caps_supported};
}

=head2 $supported = $irc->cap_supported( $cap )

Returns a boolean indicating if the server supports the named capability.

=cut

sub cap_supported
{
   my $self = shift;
   my ( $cap ) = @_;
   return !!$self->{caps_supported}{$cap};
}

=head2 $caps = $irc->caps_enabled

Returns a HASH whose keys give the capabilities successfully enabled by the
server as part of the C<CAP REQ> login sequence. If the server ignored the
C<CAP> negotiation then this method returns C<undef>.

=cut

sub caps_enabled
{
   my $self = shift;
   return $self->{caps_enabled};
}

=head2 $enabled = $irc->cap_enabled( $cap )

Returns a boolean indicating if the client successfully enabled the named
capability.

=cut

sub cap_enabled
{
   my $self = shift;
   my ( $cap ) = @_;
   return !!$self->{caps_enabled}{$cap};
}

=head1 MESSAGE HANDLING

=cut

sub on_message_NICK
{
   my $self = shift;
   my ( $message, $hints ) = @_;

   if( $hints->{prefix_is_me} ) {
      $self->_set_nick( $hints->{new_nick} );
      return 1;
   }

   return 0;
}

sub on_message_RPL_WELCOME
{
   my $self = shift;
   my ( $message ) = @_;

   $self->{on_login}->( $self ) if defined $self->{on_login};
   undef $self->{on_login};

   # Don't eat it
   return 0;
}

=head2 RPL_WHOREPLY and RPL_ENDOFWHO

These messages will be collected up, per channel, and formed into a single
synthesized event called C<who>.

Its hints hash will contain an extra key, C<who>, which will be an ARRAY ref
containing the lines of the WHO reply. Each line will be a HASH reference
containing:

=over 8

=item user_ident

=item user_host

=item user_server

=item user_nick

=item user_nick_folded

=item user_flags

=back

=cut

sub on_gate_done_who
{
   my $self = shift;
   my ( $message, $hints, $data ) = @_;

   my @who = map {
      my $b = $_;
      +{ map { $_ => $b->{$_} } qw( user_ident user_host user_server user_nick user_nick_folded user_flags ) }
   } @$data;

   $self->_invoke_synthetic( "who", $message, $hints,
      who => \@who,
   );
}

=head2 RPL_NAMEREPLY and RPL_ENDOFNAMES

These messages will be collected up, per channel, and formed into a single
synthesized event called C<names>.

Its hints hash will contain an extra key, C<names>, which will be an ARRAY ref
containing the usernames in the channel. Each will be a HASH reference
containing:

=over 8

=item nick

=item flag

=back

=cut

sub on_gate_done_names
{
   my $self = shift;
   my ( $message, $hints, $data ) = @_;

   my @names = map { @{ $_->{names} } } @$data;

   my $prefixflag_re = $self->isupport( 'prefixflag_re' );
   my $re = qr/^($prefixflag_re)?(.*)$/;

   my %names;

   foreach my $name ( @names ) {
      my ( $flag, $nick ) = $name =~ $re or next;

      $flag ||= ''; # make sure it's defined

      $names{ $self->casefold_name( $nick ) } = { nick => $nick, flag => $flag };
   }

   $self->_invoke_synthetic( "names", $message, $hints,
      names => \%names,
   );
}

=head2 RPL_BANLIST and RPL_ENDOFBANS

These messages will be collected up, per channel, and formed into a single
synthesized event called C<bans>.

Its hints hash will contain an extra key, C<bans>, which will be an ARRAY ref
containing the ban lines. Each line will be a HASH reference containing:

=over 8

=item mask

User mask of the ban

=item by_nick

=item by_nick_folded

Nickname of the user who set the ban

=item timestamp

UNIX timestamp the ban was created

=back

=cut

sub on_gate_done_bans
{
   my $self = shift;
   my ( $message, $hints, $data ) = @_;

   my @bans = map {
      my $b = $_;
      +{ map { $_ => $b->{$_} } qw( mask by_nick by_nick_folded timestamp ) }
   } @$data;

   $self->_invoke_synthetic( "bans", $message, $hints,
      bans => \@bans,
   );
}

=head2 RPL_MOTD, RPL_MOTDSTART and RPL_ENDOFMOTD

These messages will be collected up into a synthesized event called C<motd>.

Its hints hash will contain an extra key, C<motd>, which will be an ARRAY ref
containing the lines of the MOTD.

=cut

sub on_gate_done_motd
{
   my $self = shift;
   my ( $message, $hints, $data ) = @_;

   $self->_invoke_synthetic( "motd", $message, $hints,
      motd => [ map { $_->{text} } @$data ],
   );
}

=head1 SEE ALSO

=over 4

=item *

L<http://tools.ietf.org/html/rfc2812> - Internet Relay Chat: Client Protocol

=back

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>

=cut

0x55AA;
