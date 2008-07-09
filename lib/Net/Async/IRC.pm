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

   $self->{state} = defined $self->read_handle ? STATE_CONNECTED : STATE_UNCONNECTED;

   $self->{$_} = $args{$_} for grep m/^on_message/, keys %args;

   $self->{pingtime} = defined $args{pingtime} ? $args{pingtime} : 60;
   $self->{pongtime} = defined $args{pongtime} ? $args{pongtime} : 10;

   $self->{on_ping_timeout} = $args{on_ping_timeout};
   $self->{on_pong_reply}   = $args{on_pong_reply};

   $self->{isupport} = {};

   # Some initial defaults for isupport-derived values
   $self->{channame_re} = qr/^[#&]/;
   $self->{prefixmode_re} = qr/^[\@+]/;
   $self->{isupport}->{CHANMODES_LIST} = [qw( b k l imnpst )]; # TODO: ov

   $self->set_nick( $args{nick} );

   $self->{user}     = $args{user} || $ENV{LOGNAME} || getpwuid($>);
   $self->{realname} = $args{realname} || "Net::Async::IRC client $VERSION";

   return $self;
}

sub set_handles
{
   my $self = shift;
   $self->SUPER::set_handles( @_ );

   $self->{state} = defined $self->read_handle ? STATE_CONNECTED : STATE_UNCONNECTED;
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

   $self->{state} = STATE_CONNECTING;

   $args{service}  ||= "ircd";
   $args{socktype} ||= SOCK_STREAM;

   $loop->connect(
      %args,

      on_connected => sub {
         my ( $sock ) = @_;

         $self->set_handle( $sock );

         $on_connected->( $self );
      },

      on_resolve_error => sub {
         $self->{state} = STATE_UNCONNECTED;

         $args{on_resolve_error} ? $args{on_resolve_error}->( @_ ) : $on_error->( "Cannot resolve - $_[0]" );
      },

      on_connect_error => sub {
         $self->{state} = STATE_UNCONNECTED;

         $args{on_connect_error} ? $args{on_connect_error}->( @_ ) : $on_error->( "Cannot connect" )
      },
   );
}

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

sub on_read
{
   my $self = shift;
   my ( $buffref, $closed ) = @_;

   if( $$buffref =~ s/^(.*)$CRLF// ) {
      my $message = Net::Async::IRC::Message->new_from_line( $1 );

      $self->_reset_pingtimer;
      $self->incoming_message( $message );

      return 1;
   }

   return 0;
}

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

   my ( $prefix_nick ) = $self->split_prefix( $message->prefix );

   my $hints = {
      handled => 0,

      prefix_nick  => $prefix_nick,
      prefix_is_me => defined $prefix_nick && $self->is_nick_me( $prefix_nick ),
   };

   my $target_name = $message->target_arg;
   if( defined $target_name ) {
      $hints->{target_name}  = $target_name;
      $hints->{target_is_me} = $self->is_nick_me( $target_name );
      $hints->{target_type}  = ( $target_name =~ $self->{channame_re} ) ? "channel" : "user";
   }

   if( my $named_args = $message->named_args ) {
      $hints->{$_} = $named_args->{$_} for keys %$named_args;
   }

   foreach my $k ( grep { m/_nick$/ or m/_name$/ } keys %$hints ) {
      $hints->{"${k}_folded"} = $self->casefold_name( $hints->{$k} );
   }

   $self->_invoke( "on_message_$command", $message, $hints ) and $hints->{handled} = 1;
   $self->_invoke( "on_message", $command, $message, $hints ) and $hints->{handled} = 1;
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
   return 1 unless defined $self->{pongtimer_id};

   my $lag = time() - $self->{ping_send_time};

   $self->{current_lag} = $lag;
   $self->{on_pong_reply}->( $self, $lag ) if $self->{on_pong_reply};

   my $loop = $self->get_loop;

   $loop->cancel_timer( $self->{pongtimer_id} );
   undef $self->{pongtimer_id};

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

   my $target = $hints->{target_name};

   my $restriction = "";
   while( $target =~ $self->{prefixmode_re} ) {
      $restriction .= substr( $target, 0, 1, "" );
   }

   $hints{target_name} = $target;
   $hints{target_name_folded} = $self->casefold_name( $target );

   if( $target =~ $self->{channame_re} ) {
      $hints{restriction} = $restriction;
      $hints{target_type} = "channel";
      $hints{target_is_me} = '';
   }
   else {
      # TODO: user messages probably can't have restrictions. What to do
      # if we got one?
      $hints{target_type} = "user";
      $hints{target_is_me} = $self->is_nick_me( $target );
   }

   my $text = $hints->{text};

   if( $text =~ m/^\x01(.*)\x01$/ ) {
      ( my $verb, $text ) = split( m/ /, $1, 2 );
      $hints{ctcp_verb} = $verb;
      $hints{ctcp_args} = $text;

      $self->_invoke( "on_message_ctcp_$verb", $message, \%hints ) and $hints{handled} = 1;
      $self->_invoke( "on_message_ctcp", $verb, $message, \%hints ) and $hints{handled} = 1;
      $self->_invoke( "on_message", "ctcp $verb", $message, \%hints ) and $hints{handled} = 1;
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

sub on_message_005
{
   my $self = shift;
   my ( $message ) = @_;

   my ( undef, @isupport ) = $message->args;
   pop @isupport; # Text message at the end

   foreach ( @isupport ) {
      next unless m/^([A-Z]+)(?:=(.*))?$/;
      my ( $name, $value ) = ( $1, $2 );

      $value = 1 if !defined $value;

      $self->{isupport}->{$name} = $value;

      if( $name eq "PREFIX" ) {
         my $prefix = $value;

         my ( $prefix_modes, $prefix_flags ) = $prefix =~ m/^\(([a-z]+)\)(.+)$/;

         $self->{isupport}->{PREFIX_MODES} = $prefix_modes;
         $self->{isupport}->{PREFIX_FLAGS} = $prefix_flags;

         $self->{prefixmode_re} = qr/^[$prefix_modes]/;

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

   return 1;
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

sub split_prefix
{
   my $self = shift;
   my ( $prefix ) = @_;

   return ( $1, $2, $3 ) if $prefix =~ m/^(.*?)!(.*?)@(.*)$/;

   # $prefix doesn't split into nick!ident@host so presume host only
   return ( undef, undef, $prefix );
}

sub is_nick_me
{
   my $self = shift;
   my ( $nick ) = @_;

   return $self->casefold_name( $nick ) eq $self->{nick_folded};
}

sub is_prefix_me
{
   my $self = shift;
   my ( $prefix ) = @_;

   my ( $nick, undef, undef ) = $self->split_prefix( $prefix );

   return defined $nick && $self->is_nick_me( $nick );
}

# ISUPPORT and related

sub isupport
{
   my $self = shift;
   my ( $flag ) = @_;

   return exists $self->{isupport}->{$flag} ? 
                 $self->{isupport}->{$flag} : undef;
}

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

sub prefix_mode2flag
{
   my $self = shift;
   my ( $mode ) = @_;

   return $self->{isupport}->{PREFIX_MAP_M2F}->{$mode};
}

sub prefix_flag2mode
{
   my $self = shift;
   my ( $flag ) = @_;

   return $self->{isupport}->{PREFIX_MAP_F2M}->{$flag};
}

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

# Some state accessors
sub nick
{
   my $self = shift;
   return $self->{nick};
}

sub nick_folded
{
   my $self = shift;
   return $self->{nick_folded};
}

# Some state mutators
sub set_nick
{
   my $self = shift;
   ( $self->{nick} ) = @_;
   $self->{nick_folded} = $self->casefold_name( $self->{nick} );
}

# Wrapper for sending command to server
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

