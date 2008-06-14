#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2008 -- leonerd@leonerd.org.uk

package Net::Async::IRC::Message;

use strict;

our $VERSION = '0.01';

use Carp;

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
      m/[ \t\x0d\x0a]/ and
         croak "Argument must not contain whitespace";
   }

   exists $args[-1] and
      $args[-1] =~ m/[\x0d\x0a]/ and
         croak "Final argument must not contain a linefeed";

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

sub arg
{
   my $self = shift;
   my ( $index ) = @_;
   my @args = @{$self->{args}};

   if( $index >= 0 && $index < scalar @args ) {
      return $args[$index];
   }
   elsif( $index == -1 ) {
      return $args[$#args];
   }
   else {
      return undef;
   }
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

   foreach my $a ( @{$self->{args}} ) {
      if( $a =~ m/ / ) {
         $line .= " :$a";
      }
      else {
         $line .= " $a";
      }
   }

   return $line;
}

# Targeting information

# This hash holds the argument number for the 'target' of any message type

my %TARGET_ARG;

# Named commands
$TARGET_ARG{$_} = 0 for qw(
   INVITE JOIN KICK LIST MODE NAMES NOTICE PART PRIVMSG TOPIC WHO WHOIS WHOWAS
);

# Normal targeted numerics
$TARGET_ARG{$_} = 1 for qw(
   301
   311 312 313 314 317 318 319 369
   324 331 332 341
   346 347 348 349 367 368
   352 315
   366
   401 402 403 404 405 406 408
   432 433 436 437
   442 444
   467 471 473 474 475 476 477 478
   482
);

# 353 RPL_NAMREPLY is weird
$TARGET_ARG{353} = 2;

# 441 ERR_USERNOTINCHANNEL: <nick> <channel> so we'll target channel
$TARGET_ARG{441} = 2;
# 443 ERR_USERONCHANNEL: <nick> <channel> so we'll target channel
$TARGET_ARG{443} = 2;

# TODO: 472 ERR_UNKNOWNMODE: <char> :is unknown mode char to me for <channel>
# How to parse this one??

sub target_arg_index
{
   my $self = shift;

   if( exists $TARGET_ARG{$self->{command}} ) {
      return $TARGET_ARG{$self->{command}};
   }
   else {
      return undef;
   }
}

sub is_targeted
{
   my $self = shift;
   return defined $self->target_arg_index;
}

sub target_arg
{
   my $self = shift;
   my $index = $self->target_arg_index;
   return defined $index ? $self->arg( $index ) : undef;
}

# Keep perl happy; keep Britain tidy
1;
