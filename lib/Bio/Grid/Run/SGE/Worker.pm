package Bio::Grid::Run::SGE::Worker;

use warnings;
use strict;
use Mouse;
use 5.010;
use Storable;
use Data::Dumper;
use Carp;
use File::Spec::Functions;
use File::Spec;
use Bio::Grid::Run::SGE::Index;
use Net::Domain qw(hostfqdn);
use IO::Handle;

use Cwd qw/fastcwd/;

# VERSION

has [qw/config env/] => ( is => 'rw', required => 1 );
has [qw/task/] => ( is => 'rw', required => 1 );
has [qw/range _part_size/] => ( is => 'rw' );
has log => (is => 'rw', required => 1);

has log_fh => ( is => 'rw' );

has [qw/iterator/] => ( is => 'rw', lazy_build => 1 );

sub BUILD {
  my ( $self, $args ) = @_;


  my $conf = $self->config;
  my $env = $self->env;

  confess "task is no code reference" unless ( $self->task && ref $self->task eq 'CODE' );

  confess "given range is not in the correct format"
    if ( $env->{range} && @{ $env->{range} } < 2 );

  $self->_determine_range;

  my $log_file = catfile( $conf->{log_dir}, sprintf( "%s.l%d.%d", $env->{job_name_save}, $env->{job_id}, $env->{task_id} ) );
  $self->log->info($log_file);
  open my $log_fh, '>', $log_file or confess "Can't open filehandle: $!";
  $self->log_fh($log_fh);

  $self->_log_current_settings;
}

sub _build_iterator {
  my ($self) = @_;
  my $c = $self->config;

  my @indices;

  for my $in ( @{ $c->{input} } ) {
    push @indices, Bio::Grid::Run::SGE::Index->new( %{$in} );
    $self->log_status( "index_file: " . $in->{idx_file} );
  }

  # create iterator
  my $iter = Bio::Grid::Run::SGE::Iterator->new( mode => $c->{mode}, indices => \@indices );
  return $iter;
}

sub _determine_range {
  my ($self) = @_;
  my $conf      = $self->config;
  my $env = $self->env;
  my $id = $env->{task_id};

  my ( $num_comb, $parts ) = ( $env->{num_comb}, $conf->{parts} );

  $env->{part_size} = 1;
  if ( $env->{range} ) {
    #we ran before (and failed) and now somebody restarts us with a given range

    return;
  }

  #make everyting 0 based
  $id--;

  unless ($parts) {
    $env->{range} =  [ $id, $id ];
    return;
  }
  my $part_size = int( $num_comb / $parts );

  my $rest = $num_comb % $parts;

  my $from = $part_size * $id;
  my $to   = $from + $part_size - 1;

  $env->{range} = [ $from, $to ];
  if ( $id < $rest ) {
    #do sth extra
    push @{ $env->{range}}, ( $part_size * $parts ) + $id;
  }

  return;
}

sub run {
  my ($self) = @_;

  my $iter = $self->iterator;
  my $c    = $self->config;

  chdir $c->{working_dir};
  #log something
  $self->log_status( "cwd: " . fastcwd() );
  $self->log_status( "cmd: " . join( " ", @{ $c->{cmd} } ) );
  $self->log_status("run.begin");

  #time the whole stuff
  my $time_start = time;
  $self->log_status( "comp.begin: " . localtime($time_start) );

  # create task iterator
  my $next_task = $self->_create_task_iterator();

  # adjust config for main task
  $c->{part_size} = $self->_part_size;
  $c->{job_id}    = $self->job_id . "." . $self->id;
  $c->{nslots}    = $ENV{NSLOTS} // 1;

  while ( my $task_params = $next_task->() ) {
    my $infiles       = $task_params->{infiles};
    my $result_prefix = $task_params->{result_prefix};
    my $task_id       = $task_params->{task_id};
    # some input files are generated by us, some are original files
    my $infile_is_temp = $task_params->{is_temp};

    #stop time per task
    my $task_time = time;

    #RUN TASK
    my $return_status = $self->task->( $c, $result_prefix, @{$infiles} );
    unless ($return_status) {
      $self->log_status( "comp.task.exit.error:: $task_id " . join( "#\0#", @$infiles, $result_prefix ) );
    } elsif ( $return_status < 0 ) {
      $self->log_status("comp.task.exit.skip:: $task_id");
    } else {
      $self->log_status("comp.task.exit.success:: $task_id");
    }

    for ( my $i = 0; $i < @$infiles; $i++ ) {
      # delete the file only, if it was created by us.
      next unless ( $infile_is_temp->[$i] );

      my $infile = $infiles->[$i];
      next if ( $ENV{DEBUG} );
      $self->log_status("comp.task.file.delete:: $task_id $infile");
      unlink $infile;
    }

    $task_time = time - $task_time;
    $self->log_status(
      "comp.task.time:: $task_id " . sprintf( "%dd %dh %dm %ds", ( gmtime($task_time) )[ 7, 2, 1, 0 ] ) );

  }

  my $time_end = time;
  $self->log_status( "comp.end: " . localtime($time_end) );
  $self->log_status(
    "comp.time: "
      . sprintf(
      "%dd %dh %dm %ds (%d)",
      ( gmtime( $time_end - $time_start ) )[ 7, 2, 1, 0 ],
      $time_end - $time_start
      )
  );

  $self->log_status("run.end");
}

#0-based ranges

sub _create_task_iterator {
  my ($self) = @_;
  my $c      = $self->config;
  my $iter   = $self->iterator;

  $iter->start( $self->range );
  my $num_infiles = @{ $iter->indices };

  return sub {
    my $task_id = $iter->peek_comb_idx;

    return
      unless ( defined($task_id) );

    my $comb = $iter->next_comb;

    return unless ($comb);

    my @infiles;
    my @is_temp_file;
    my @infile_fhs;
    die "different number of combinations than indices...????!!!" if ( $num_infiles != @$comb );
    for ( my $i = 0; $i < @$comb; $i++ ) {
      my $idx_type        = $iter->indices->[$i]->type;
      my $infile_template = catfile( $c->{tmp_dir},
        sprintf( "worker.j%d.%d.t%d.i%d.tmp", $self->job_id, $self->id, $task_id, $i ) );

      if ( $idx_type && $idx_type eq 'direct' ) {
        push @infiles,      $comb->[$i];
        push @is_temp_file, 0;
      } else {
        open my $in_fh, '>', $infile_template or confess "Can't open filehandle: $!";
        print $in_fh $comb->[$i];
        $in_fh->close;
        push @infiles,      $infile_template;
        push @is_temp_file, 1;
      }
    }

    my $result_prefix = catfile( $c->{result_dir},
      sprintf( "%s.j%d.%d.t%d", $c->{job_name}, $self->job_id, $self->id, $task_id ) );

    return {
      infiles       => \@infiles,
      is_temp       => \@is_temp_file,
      result_prefix => $result_prefix,
      task_id       => $task_id
    };
  };
}

sub _log_current_settings {
  my ($self) = @_;

  $self->log_status( "init: " . localtime(time) );
  $self->log_status( "task_id: " . $self->id );
  $self->log_status( "job_id: " . $self->job_id );
  $self->log_status( "job_cmd: " . $self->config->{job_cmd} );
  $self->log_status( "hostname: " . hostfqdn() );

  $self->log_status("err: $ENV{SGE_STDERR_PATH}");
  $self->log_status("out: $ENV{SGE_STDOUT_PATH}");

  #@range = ( from, to, extra_element)
  #extra element caused by modulo leftover
  $self->log_status("sge_task_id:  $ENV{SGE_TASK_ID}");
  $self->log_status( "range: (" . join( ",", @{ $self->range } ) . ")" );
}

sub log_status {
  my ($self) = shift;
  my $log_fh = $self->log_fh;

  print $log_fh join( " ", @_ ), "\n";
  $log_fh->flush;

  return;
}

sub log {
  my ($self) = shift;

  print STDERR join( " ", @_ ), "\n";
}

1;

__END__

=head1 NAME

Bio::Grid::Run::SGE::Worker - Run the cluster script

=head1 SYNOPSIS


=head1 DESCRIPTION

This class runs the cluster script for a specific interval and gives some log output.

=head1 METHODS

=head1 SEE ALSO

L<Bio::Grid::Run::SGE>

=head1 AUTHOR

jw bargsten, C<< <joachim.bargsten at wur.nl> >>

=cut

