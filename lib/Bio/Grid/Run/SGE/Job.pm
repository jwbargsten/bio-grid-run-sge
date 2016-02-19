package Bio::Grid::Run::SGE::Job;

use Mouse;

use warnings;
use strict;
use Carp;
use Bio::Gonzales::Util::Log;
use Bio::Gonzales::Util qw/sys_fmt/;

use 5.010;

our $VERSION = 0.01_01;

has 'log' => (is => 'rw', lazy_build => 1);

sub _build_log {
  return Bio::Gonzales::Util::Log->new();
}

sub sys_fatal {
  my $self = shift;
  
  $self->log->info( join( " ", "EXEC", @_ ) );
  system(@_) == 0 or confess "system " . join( " ", @_ ) . " FAILED: $? ## $!";
}

sub sys_pipe_fatal {
  my $self = shift;
  my $cmd = sys_fmt(@_);
  return $self->sys_fatal($cmd);
}

sub sys_pipe {
  my $self = shift;
  
  my $cmd = sys_fmt(@_);
  return $self->sys($cmd);
}

sub sys {
  my $self = shift;

  $self->log->info(join( " ", "EXEC", @_ ) );
  if ( system(@_) == 0 ) {
    return 1;
  } else {
    $self->log->fatal( "SYSTEM " . join( " ", @_ ) . " FAILED: $?" );

    if ( $? == -1 ) {
      $self->log->fatal("failed to execute: $!");
    } elsif ( $? & 127 ) {
      $self->log->fatal(sprintf("child died with signal %d, %s coredump\n", ( $? & 127 ), ( $? & 128 ) ? 'with' : 'without'));
    } else {
      $self->log->fatal(sprintf("child exited with value %d\n", $? >> 8));
    }
    return;
  }
}

__PACKAGE__->meta->make_immutable();

__END__
=item B<< my_sys(@command) >>

=item B<< my_sys($command) >>

Runs command eiter as array or as simple string (see also L<system>) and dies
if something goes wrong.

=item B<< my_sys_non_fatal(@command) >>

=item B<< my_sys_non_fatal($command) >>

Runs command eiter as array or as simple string (see also L<system>) and gives
a warning message if something goes wrong.

It returns C<undef> is something went wrong and C<1/true> if the exit code of
the program was ok.

