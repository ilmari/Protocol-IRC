#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2008,2009 -- leonerd@leonerd.org.uk

package Net::Async::IRC::Message;

use strict;
use warnings;

our $VERSION = '0.01';

use Carp;
our @CARP_NOT = qw( Net::Async::IRC );

sub new_from_line
{
   my $class = shift;
   my ( $line ) = @_;

   my $prefix;
   if( $line =~ s/^:([^ ]+) +// ) {
      $prefix = $1;
   }

   my ( $mid, $final ) = split( m/ +:/, $line, 2 );
   my @args = split( m/ +/, $mid );

   push @args, $final if defined $final;

   my $command = shift @args;

   return $class->new( $command, $prefix, @args );
}

sub new
{
   my $class = shift;
   my ( $command, $prefix, @args ) = @_;

   # IRC is case-insensitive for commands, but we'd like them in uppercase
   # to keep things simpler
   $command = uc $command;

   # Less strict checking than RFC 2812 because a lot of servers lately seem
   # to be more flexible than that.

   $command =~ m/^[A-Z]+$/ or $command =~ m/^\d\d\d$/ or
      croak "Command must be just letters or three digits";

   if( defined $prefix ) {
      $prefix =~ m/[ \t\x0d\x0a]/ and 
         croak "Prefix must not contain whitespace";
   }

   foreach ( @args[0 .. $#args-1] ) { # Not the final
      defined or croak "Argument must be defined";
      m/[ \t\x0d\x0a]/ and
         croak "Argument must not contain whitespace";
   }

   if( @args ) {
      defined $args[-1] or croak "Final argument must be defined";
      $args[-1] =~ m/[\x0d\x0a]/ and croak "Final argument must not contain a linefeed";
   }

   my $self = {
      command => $command,
      prefix  => $prefix,
      args    => \@args,
   };

   return bless $self, $class;
}

use overload '""' => "STRING";

sub STRING
{
   my $self = shift;
   my $class = ref $self;
   return $class . "[" . 
                    ( defined $self->{prefix} ? "prefix=$self->{prefix}," : "" ) .
                    "cmd=$self->{command}," . 
                    "args=(" . join( ",", @{ $self->{args} } ) . ")]";
}

sub command
{
   my $self = shift;
   return $self->{command};
}

sub prefix
{
   my $self = shift;
   return defined $self->{prefix} ? $self->{prefix} : "";
}

sub prefix_split
{
   my $self = shift;

   my $prefix = $self->prefix;

   return ( $1, $2, $3 ) if $prefix =~ m/^(.*?)!(.*?)@(.*)$/;

   # $prefix doesn't split into nick!ident@host so presume host only
   return ( undef, undef, $prefix );
}

sub arg
{
   my $self = shift;
   my ( $index ) = @_;
   return $self->{args}[$index];
}

sub args
{
   my $self = shift;
   return @{$self->{args}};
}

sub stream_to_line
{
   my $self = shift;

   my $line = "";
   if( defined $self->{prefix} ) {
      $line .= ":$self->{prefix} ";
   }

   $line .= $self->{command};

   foreach ( @{$self->{args}} ) {
      if( m/ / or m/^:/  ) {
         $line .= " :$_";
      }
      else {
         $line .= " $_";
      }
   }

   return $line;
}

# Argument naming information

# This hash holds HASH refs giving the names of the positional arguments of
# any message. The hash keys store the argument names, and the values store
# an argument index, the string "pn" meaning prefix nick, or "$n~$m" meaning
# an index range. Endpoint can be absent.

my %ARG_NAMES = (
   INVITE  => { inviter_nick => "pn",
                invited_nick => 0,
                target_name  => 1 },
   KICK    => { kicker_nick => "pn",
                target_name => 0,
                kicked_nick => 1,
                text        => 2 },
   MODE    => { target_name => 0,
                modechars   => 1,
                modeargs    => "2.." },
   NICK    => { old_nick => "pn",
                new_nick => 0 },
   NOTICE  => { targets => 0,
                text    => 1 },
   PING    => { text => 0 },
   PONG    => { text => 0 },
   QUIT    => { text => 0 },
   PART    => { target_name => 0,
                text        => 1 },
   PRIVMSG => { targets => 0,
                text    => 1 },
   TOPIC   => { target_name => 0,
                text        => 1 },

   '004' => { serverhost    => 1,
              serverversion => 2,
              usermodes     => 3,
              channelmodes  => 4 }, # MYINFO
   '005' => { isupport => "1..-2",
              text     => -1 },     # ISUPPORT

   301 => { target_name => 1,
            text        => 2 }, # AWAY

   324 => { target_name => 1,
            modechars   => 2,
            modeargs    => "3.." }, # CHANNELMODEIS
   329 => { target_name => 1,
            timestamp   => 2 },    # CHANNELCREATED - extension not in 2812
   331 => { target_name => 1 },    # NOTOPIC
   332 => { target_name => 1,
            text        => 2 },    # TOPIC
   333 => { target_name => 1,
            topic_nick  => 2,
            timestamp   => 3, },   # TOPICSETBY - extension not in 2812

   352 => { target_name => 1,
            user_ident  => 2,
            user_host   => 3,
            user_server => 4,
            user_nick   => 5,
            user_flags  => 6,
            text        => 7, # really "hopcount realname" but can't parse text yet
          }, # WHOREPLY

   353 => { target_name => 2,
            names       => 3 }, # NAMEREPLY
   367 => { target_name => 1,
            mask        => 2,
            by_nick     => 3,
            timestamp   => 4 }, # BANLIST

   441 => { user_nick   => 1,
            target_name => 2 }, # ERR_USERNOTINCHANNEL
   443 => { user_nick   => 1,
            target_name => 2 }, # ERR_USERONCHANNEL
);

# Misc. named commands
$ARG_NAMES{$_} = { target_name => 0 } for qw(
   JOIN LIST NAMES WHO WHOIS WHOWAS
);

# Normal targeted numerics
$ARG_NAMES{$_} = { target_name => 1 } for qw(
   307 311 312 313 314 315 317 318 319 369 387
   331 341
   346 347 348 349
   366 368
   401 402 403 404 405 406 408
   432 433 436 437
   442 444
   467 471 473 474 475 476 477 478
   482
);

# Untargeted numerics with nothing of interest
$ARG_NAMES{$_} = { } for qw(
   376
);

# Untargeted numerics with a simple text message
$ARG_NAMES{$_} = { text => 1 } for qw(
   001 002 003
   305 306
   372 375
);


# TODO: 472 ERR_UNKNOWNMODE: <char> :is unknown mode char to me for <channel>
# How to parse this one??

sub arg_names
{
   # Usage: Class->arg_names($command) or $self->arg_names()
   my $command;

   if( ref $_[0] ) {
      my $self = shift;
      $command = $self->{command};
   }
   else {
      my $class = shift; # ignore
      ( $command ) = @_;
      defined $command or croak 'Usage: '.__PACKAGE__.'->arg_names($command)';
   }

   return $ARG_NAMES{$command};
}

sub named_args
{
   my $self = shift;

   my $argnames = $self->arg_names or return;

   my %named_args;
   foreach my $name ( keys %$argnames ) {
      my $argindex = $argnames->{$name};

      my $value;
      if( $argindex eq "pn" ) {
         ( $value, undef, undef ) = $self->prefix_split;
      }
      elsif( $argindex =~ m/^(-?\d+)?\.\.(-?\d+)?$/ ) {
         my ( $start, $end ) = ( $1, $2 );
         my @args = $self->args;

         defined $start or $start = 0;
         defined $end   or $end = $#args;

         $end += @args if $end < 0;

         $value = [ splice( @args, $start, $end-$start+1 ) ];
      }
      elsif( $argindex =~ m/^-?\d+$/ ) {
         $value = $self->arg( $argindex );
      }
      else {
         die "Unrecognised argument specification $argindex";
      }

      $named_args{$name} = $value;
   }

   return \%named_args;
}

# Keep perl happy; keep Britain tidy
1;
