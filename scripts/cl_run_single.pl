#!/usr/bin/env perl

use warnings;
use strict;

use Carp;

use Bio::Grid::Run::SGE;
use Bio::Grid::Run::SGE::Master;
use Data::Dumper;
use File::Slurp;

run_job(
    {
        task => sub {
            my ( $c, $result_prefix, $cmd_in_file ) = @_;

            my $cmd = (read_file($cmd_in_file))[0];
            chomp $cmd;
            INFO("running $cmd");
            my $success = my_sys_non_fatal($cmd);

            return $success;
        },
    }
);

1;

