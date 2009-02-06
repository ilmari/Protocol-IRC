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

use Encode qw( find_encoding );

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

         $self->{state} = STATE_UNCONNECTED;
      },
   );

   $self->{state} = defined $self->read_handle ? STATE_CONNECTED : STATE_UNCONNECTED;

   $self->{$_} = $args{$_} for grep m/^on_message/, keys %args;

   $self->{pingtime} = defined $args{pingtime} ? $args{pingtime} : 60;
   $self->{pongtime} = defined $args{pongtime} ? $args{pongtime} : 10;

   $self->{on_ping_timeout} = $args{on_ping_timeout};
   $self->{on_pong_reply}   = $args{on_pong_reply};

   $self->{server_info} = {};
   $self->{isupport} = {};

   # Some initial defaults for isupport-derived values
   $self->{channame_re} = qr/^[#&]/;
   $self->{prefixflag_re} = qr/^[\@+]/;
   $self->{isupport}->{CHANMODES_LIST} = [qw( b k l imnpst )]; # TODO: ov

   $self->set_nick( $args{nick} );

   $self->{user}     = $args{user} || $ENV{LOGNAME} || getpwuid($>);
   $self->{realname} = $args{realname} || "Net::Async::IRC client $VERSION";

   my $encoding = $args{encoding};
   if( defined $encoding ) {
      my $obj = find_encoding( $encoding );
      defined $obj or croak "Cannot handle an encoding of '$encoding'";
      $self->{encoder} = $obj;
   }

   return $self;
}

sub set_handles
{
   my $self = shift;
   $self->SUPER::set_handles( @_ );

   $self->{state} = defined $self->read_handle ? STATE_CONNECTED : STATE_UNCONNECTED;
}

sub state
{
   my $self = shift;
   return $self->{state};
}

# connected does not necessarily mean logged in
sub is_connected
{
   my $self = shift;
   my $state = $self->state;
   return $state == STATE_CONNECTED ||
          $state == STATE_LOGGEDIN;
}

sub is_loggedin
{
   my $self = shift;
   my $state = $self->state;
   return $state == STATE_LOGGEDIN;
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

   my ( $prefix_nick, $prefix_user, $prefix_host ) = $message->prefix_split;

   my $hints = {
      handled => 0,

      prefix_nick  => $prefix_nick,
      prefix_user  => $prefix_user,
      prefix_host  => $prefix_host,
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

sub send_ctcp
{
   my $self = shift;
   my ( $prefix, $target, $verb, $argstr ) = @_;

   $self->send_message( "PRIVMSG", undef, $target, "\001$verb $argstr\001" );
}

sub send_ctcpreply
{
   my $self = shift;
   my ( $prefix, $target, $verb, $argstr ) = @_;

   $self->send_message( "NOTICE", undef, $target, "\001$verb $argstr\001" );
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

sub is_nick_me
{
   my $self = shift;
   my ( $nick ) = @_;

   return $self->casefold_name( $nick ) eq $self->{nick_folded};
}

# ISUPPORT and related

sub server_info
{
   my $self = shift;
   my ( $key ) = @_;

   return $self->{server_info}{$key};
}

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

sub classify_name
{
   my $self = shift;
   my ( $name ) = @_;

   return "channel" if $name =~ $self->{channame_re};
   return "user"; # TODO: Perhaps we can be a bit stricter - only check for valid nick chars?
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

