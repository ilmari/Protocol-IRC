#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2008 -- leonerd@leonerd.org.uk

package Net::Async::IRC;

use strict;

our $VERSION = '0.01';

use base qw( IO::Async::Stream );

use Carp;

use Net::Async::IRC::Message;

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

   $self->{on_message} = $on_message;

   $self->{pingtime} = defined $args{pingtime} ? $args{pingtime} : 60;
   $self->{pongtime} = defined $args{pongtime} ? $args{pongtime} : 10;

   $self->{on_ping_timeout} = $args{on_ping_timeout};
   $self->{on_pong_reply}   = $args{on_pong_reply};

   return $self;
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

