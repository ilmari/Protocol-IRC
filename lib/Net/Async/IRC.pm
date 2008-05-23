#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2008 -- leonerd@leonerd.org.uk

package Net::Async::IRC;

use strict;

our $VERSION = '0.01';

use base qw( IO::Async::Stream );

use Carp;

use Socket qw( SOCK_STREAM );

use Net::Async::IRC::Message;

use constant STATE_UNCONNECTED => 0; # No network connection
use constant STATE_CONNECTING  => 1; # Awaiting network connection
use constant STATE_CONNECTED   => 2; # Socket connected
use constant STATE_LOGGEDIN    => 3; # USER/NICK send, server confirmed login

BEGIN {
   if ( eval { Time::HiRes::time(); 1 } ) {
      Time::HiRes->import( qw( time ) );
   }
}

my $CRLF = "\x0d\x0a"; # More portable than \r\n

=head1 NAME

C<Net::Async::IRC> - Asynchronous IRC client

=head1 SYNOPSIS

 TODO

=head1 DESCRIPTION

TODO

=cut

=head1 CONSTRUCTOR

=cut

=head2 $irc = Net::Async::IRC->new( %args )

TODO

=cut

sub new
{
   my $class = shift;
   my %args = @_;

   my $on_message = delete $args{on_message} || $class->can( "on_message" ) or
      croak "Expected either an 'on_message' callback or to be a subclass that can ->on_message";

   my $on_closed = delete $args{on_closed};

   my $self = $class->SUPER::new(
      %args,

      on_closed => sub {
         my ( $self ) = @_;

         my $loop = $self->get_loop;

         if( defined $self->{pingtimer_id} ) {
            $loop->cancel_timer( $self->{pingtimer_id} );
            undef $self->{pingtimer_id};
         }

         if( defined $self->{pongtimer_id} ) {
            $loop->cancel_timer( $self->{pongtimer_id} );
            undef $self->{pongtimer_id};
         }

         $on_closed->() if $on_closed;
      },
   );

   $self->{state} = STATE_UNCONNECTED;

   $self->{on_message} = $on_message;

   $self->{pingtime} = defined $args{pingtime} ? $args{pingtime} : 60;
   $self->{pongtime} = defined $args{pongtime} ? $args{pongtime} : 10;

   $self->{on_ping_timeout} = $args{on_ping_timeout};
   $self->{on_pong_reply}   = $args{on_pong_reply};

   return $self;
}

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
   ref $on_error eq "CODE" or croak "Expected 'on_error' as CODE reference";

   $self->{state} = STATE_CONNECTING;

   $args{service}  ||= "ircd";
   $args{socktype} ||= SOCK_STREAM;

   $loop->connect(
      %args,

      on_connected => sub {
         my ( $sock ) = @_;

         $self->set_handle( $sock );
         $self->{state} = STATE_CONNECTED;

         $on_connected->( $self );
      },

      on_resolve_error => sub {
         $self->{state} = STATE_UNCONNECTED;
         $on_error->( "Cannot resolve - $_[0]" );
      },

      on_connect_error => sub {
         $self->{state} = STATE_UNCONNECTED;
         $on_error->( "Cannot connect" )
      },
   );
}

sub login
{
   my $self = shift;
   my %args = @_;

   my $nick     = delete $args{nick} or croak "Need a login nick";
   my $user     = delete $args{user} || $ENV{LOGNAME} || getpwuid($>) or croak "Need a login user";
   my $realname = delete $args{realname} || "Net::Async::IRC client $VERSION";
   my $pass     = delete $args{pass};

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

sub on_read
{
   my $self = shift;
   my ( $buffref, $closed ) = @_;

   if( $$buffref =~ s/^(.*)$CRLF// ) {
      my $message = Net::Async::IRC::Message->new_from_line( $1 );

      $self->_reset_pingtimer;

      # Handle PING directly
      if( $message->command eq "PING" ) {
         $self->send_message( "PONG", undef, $message->arg(0) );
         return 1;
      }

      if( $message->command eq "PONG" ) {
         # Protect against spurious PONGs from the server
         return unless defined $self->{pongtimer_id};

         my $lag = time() - $self->{ping_send_time};

         $self->{current_lag} = $lag;
         $self->{on_pong_reply}->( $self, $lag ) if $self->{on_pong_reply};

         my $loop = $self->get_loop;

         $loop->cancel_timer( $self->{pongtimer_id} );
         undef $self->{pongtimer_id};

         return 1;
      }

      if( $message->command eq "001" ) {
         $self->{on_login}->( $self ) if defined $self->{on_login};
         $self->{state} = STATE_LOGGEDIN;
         undef $self->{on_login};
         # Don't eat it
      }

      $self->{on_message}->( $self, $message );
      return 1;
   }

   return 0;
}

sub send_message
{
   my $self = shift;

   my $message;

   if( @_ == 1 ) {
      $message = shift;
   }
   else {
      my ( $command, $prefix, @args ) = @_;
      $message = Net::Async::IRC::Message->new( $command, $prefix, @args );
   }

   $self->write( $message->stream_to_line . $CRLF );
}

sub _reset_pingtimer
{
   my $self = shift;

   my $loop = $self->get_loop or return;

   # Manage the PING timer
   if( defined $self->{pingtimer_id} ) {
      $loop->cancel_timer( $self->{pingtimer_id} );
   }

   $self->{pingtimer_id} = $loop->enqueue_timer(
      delay => $self->{pingtime},

      code  => sub {
         undef $self->{pingtimer_id};

         my $now = time();

         $self->send_message( "PING", undef, "$now" );

         $self->{ping_send_time} = $now;

         $self->{pongtimer_id} = $loop->enqueue_timer(
            delay => $self->{pongtime},
            code  => sub {
               undef $self->{pongtimer_id};

               $self->{on_ping_timeout}->( $self ) if defined $self->{on_ping_timeout};
            },
         );
      },
   );
}

# Keep perl happy; keep Britain tidy
1;

__END__

=head1 SEE ALSO

=over 4

=item *

L<RFC 2812|http://tools.ietf.org/html/rfc2812> - Internet Relay Chat: Client Protocol

=back

=head1 AUTHOR

Paul Evans E<lt>leonerd@leonerd.org.ukE<gt>

