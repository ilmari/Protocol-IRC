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

   my $on_message = delete $args{on_message} or $class->can( "on_message" ) or
      croak "Expected either an 'on_message' callback or to be a subclass that can ->on_message";

   my $self = $class->SUPER::new( %args );

   $self->{on_message} = $on_message;

   return $self;
}

sub on_read
{
   my $self = shift;
   my ( $buffref, $closed ) = @_;

   if( $$buffref =~ s/^(.*)$CRLF// ) {
      my $message = Net::Async::IRC::Message->new_from_line( $1 );
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

