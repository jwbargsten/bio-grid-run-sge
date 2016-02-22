package Bio::Grid::Run::SGE::Job;

use Mouse;

use warnings;
use strict;
use Carp;
use Bio::Gonzales::Util::Log;
use Bio::Gonzales::Util qw/sys_fmt/;
use Getopt::Long::Descriptive;
use Bio::Gonzales::Util::Cerial;
use Cwd qw/fastcwd/;
use Scalar::Util qw/blessed/;
use IO::Prompt::Tiny qw/prompt/;
use Data::Dumper;


use 5.010;

our $VERSION = 0.01_01;

has 'log' => ( is => 'rw', lazy_build => 1 );
has [ 'pre_task', 'post_task', 'task', ] => ( is => 'rw' );

has _config => ( is => 'rw', default => sub { {} } );
has _env    => ( is => 'rw', default => sub { {} } );

sub BUILD {
  my $self = shift;

  #task number, 1 based, set it here
  my $task_id = exists( $ENV{SGE_TASK_ID} ) && $ENV{SGE_TASK_ID} ne 'undefined' ? $ENV{SGE_TASK_ID} : 0;
  $self->task_id($task_id);
  $self->config->{job_name} = 'cluster_job';

  $self->job_id( $ENV{JOB_ID} );
  $self->env( "rc_file" => "$ENV{HOME}/.bio-grid-run-sge.conf.yml" );
}

sub task_id { shift->env( "task_id", @_ ); }
sub job_id  { shift->env( "job_id",  @_ ); }

sub _store {
  my ( $self, $name ) = ( shift, shift );

  return $self->$name unless @_;

  return $self->$name->{ $_[0] } unless @_ > 1 || ref $_[0];

  my $values = ref $_[0] ? $_[0] : {@_};
  @{ $self->$name }{ keys %$values } = values %$values;

  return $self->$name;
}

sub config { return shift->_store( '_config', @_ ); }
sub env    { return shift->_store( '_env',    @_ ); }

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
  my $cmd  = sys_fmt(@_);
  return $self->sys_fatal($cmd);
}

sub sys_pipe {
  my $self = shift;

  my $cmd = sys_fmt(@_);
  return $self->sys($cmd);
}

sub sys {
  my $self = shift;

  $self->log->info( join( " ", "EXEC", @_ ) );
  if ( system(@_) == 0 ) {
    return 1;
  } else {
    $self->log->fatal( "SYSTEM " . join( " ", @_ ) . " FAILED: $?" );

    if ( $? == -1 ) {
      $self->log->fatal("failed to execute: $!");
    } elsif ( $? & 127 ) {
      $self->log->fatal(
        sprintf(
          "child died with signal %d, %s coredump\n", ( $? & 127 ), ( $? & 128 ) ? 'with' : 'without'
        )
      );
    } else {
      $self->log->fatal( sprintf( "child exited with value %d\n", $? >> 8 ) );
    }
    return;
  }
}

sub run {
  my $self = shift;

  my $run_args = @_ == 1 && ref $_[0] eq 'HASH' ? $_[0] : {@_};

  confess "main task missing" unless ( $run_args->{task} );

  my ( $opt, $usage ) = describe_options(
    "%c %o [<config_file>] [<arg1> <arg2> ... <argn>]\n" . "%c %o _ [<arg1> <arg2> ... <argn>]",
    [ 'help|h', 'print help message and exit' ],
    [ 'stage=s',   "run post task with job id of previous task", { default => 'master' } ],
    [ 'range|r=s', "run predefined range" ],
    [ 'job_id=s',  "run under this job_id" ],
    [ 'task_id=s', "run under this task id" ],
    [ 'no_prompt', "ask no confirmation stuff for running a job" ],
  );

  usage( $usage, $run_args->{usage} ) if ( $opt->help );

  $self->env->{job_id}  //= $opt->job_id;
  $self->env->{task_id} //= $opt->task_id;
  if ( $opt->range ) {
    my @range = split /[-,]/, $opt->range;

    #one number x: from x to x
    @range = ( @range, @range ) if ( @range == 1 );
    $self->env->{range} = \@range;
  }

  my ( $config_file, $base_dir ) = _Get_config_file( shift @ARGV );
  if ($config_file) {
    chdir($base_dir);
  }
  if ( $opt->stage eq 'master' ) {
    #MASTER

    $self->env( "config_file" => $config_file );

    $self->populate_config();
    $self->config->{no_prompt} = $opt->no_prompt if ( $opt->no_prompt );
    $self->hide_notify_settings;
    $self->set_working_dir;

    # get the configuration. hide notify stuff, because it contains passwords.
    # it gets reread (with passwords) separately in the log analysis

    $self->_run_master($run_args);
    return;
  } else {
    $self->env( "worker_config_file" => $config_file );
  }

  # all other stages have this in commong
  die "no config file given" unless ( -f $config_file );
  my $settings = jslurp($config_file);

  # keep current env settings, only add saved settings, no overwrite
  my $env = $self->env;
  $self->env( { %{ $settings->{env} }, %$env } );
  $self->config( $settings->{config} );

  if ( $opt->stage eq 'worker' ) {
    # WORKER
    Bio::Grid::Run::SGE::Worker->new(
      log    => $self->log,
      task   => $run_args->{task},
      config => $self->config,
      env    => $self->env
    )->run;
  } elsif ( $opt->stage eq 'node_log' ) {
    #NODE LOG
    _run_post_task(  $opt->node_log );
  } elsif ( $opt->stage eq 'post_task' ) {
    #POST TASK
    _run_post_task( $opt->post_task, $run_args->{post_task} );
  }
}

sub populate_config {
  my $self = shift;

  #1. LOAD RC FILE (global conf)
  # global options always get overwritten by local config
  my $rcf = $self->env("rc_file");
  my $conf_rc = $rcf && -f $rcf ? yslurp($rcf) : {};

  my $config_file = $self->env->{config_file};
  # 3. load from config file *.job.yml
  my $conf_job = $config_file && -f $config_file ? yslurp($config_file) : {};

  my %config = ( %$conf_rc, %$conf_job );
  $self->config( \%config );

  # from additional cluster script args
  if ( @ARGV && @ARGV > 0 ) {
    $self->config->{args} //= [];
    push @{ $self->config->{args} }, @ARGV;
  }

  confess "no configuration found, file: $config_file" unless (%config);
}

# hide notify settings, because they may contain passwords
sub hide_notify_settings {
  my $self = shift;

  my $c = $self->config;
  delete $c->{notify} if ( exists( $c->{notify} ) );
  return $self;
}

sub set_working_dir {
  my $self = shift;

  # CHANGE TO THE WORKING DIR

  # we are already in the dir of the config file, if given. (see further up)
  # so relative paths are based on the config file dir
  # if no config file, we are still in the directory from where we started the script
  # policy
  # 1. working dir config entry
  # 2. dir of config file if config file
  # 3. current dir if no config file

  my $c = $self->config;
  my $working_dir = $c->{working_dir} // fastcwd() // '.';

  my $current_dir = fastcwd();
  if ( $working_dir && -d $working_dir ) {
    $c->{working_dir} = File::Spec->rel2abs($working_dir);
    chdir $working_dir;
  }

}

sub _run_master {
  my ( $self, $run_args ) = @_;

  my $c = $self->config;

  my $master
    = Bio::Grid::Run::SGE::Master->new( config => $self->config, log => $self->log, env => $self->env );

  #initiate master
  if ( $run_args->{pre_task} && ref $run_args->{pre_task} eq 'CODE' ) {
    $self->log->info("RUNNING CUSTOM PRE TASK");
    $run_args->{pre_task}->($master);
  }

  $self->log->info( "CONFIGURATION:", $master->to_string );
  if ( $c->{no_prompt} || prompt( "run job? [yn]", 'y' ) eq 'y' ) {
    $master->run;
  }
}

sub _run_post_task {
  my ( $self, $post_task ) = @_;

  # create all summary files and restart scripts
  my $log = Bio::Grid::Run::SGE::Log::Analysis->new(
    config => $self->config,
    env    => $self->env,
    log    => $self->log
  );
  $log->analyse;
  $log->write;
  $log->notify;

  # run post task, if desired
  $post_task->()
    if ( $post_task && !$self->config->{no_post_task} );
}

sub usage {
  my $usage        = shift;
  my $custom_usage = shift;
  print "STANDARD USAGE INFO OF Bio::Grid::Run::SGE\n";
  print( $usage->text );
  if ($custom_usage) {
    print "\n\nCLUSTER SCRIPT USAGE INFO\n";
    my $script_usage = ref $custom_usage eq 'CODE' ? $custom_usage->() : $custom_usage;
    print $script_usage;
  }
  exit;
}

sub _Get_config_file {
  my $config_file = shift;

  return unless ( $config_file && $config_file ne '_' && -e $config_file );
  #this is either the original yaml config or a serialized config object
  $config_file = File::Spec->rel2abs($config_file);
  my $base_dir = ( File::Spec->splitpath($config_file) )[1];
  # if config file supplied, do change to conf file directory
  return $config_file, $base_dir;
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

