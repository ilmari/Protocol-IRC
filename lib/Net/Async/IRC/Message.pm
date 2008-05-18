#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2008 -- leonerd@leonerd.org.uk

package Net::Async::IRC::Message;

use strict;

our $VERSION = '0.01';

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

   my $self = {
      command => $command,
      prefix  => $prefix,
      args    => \@args,
   };

   return bless $self, $class;
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

# Keep perl happy; keep Britain tidy
1;
