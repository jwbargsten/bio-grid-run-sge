#!/usr/bin/env perl
#Copyright (c) 2010 Joachim Bargsten <code at bargsten dot org>. All rights reserved.

use warnings;
use strict;

use Carp;

use Bio::Grid::Run::SGE;

run_job(
    {
        config => {
            idx_format => 'General',
            record_sep => '^>',
        },

        task => \&do_worker_stuff
    }
);

sub do_worker_stuff {
    my ( $c, $result_prefix, $seq_file ) = @_;

    job->log->info("Running $seq_file -> $result_prefix");

    sleep 10;
    open my $seq_fh, '<', $seq_file      or confess "Can't open filehandle: $!";
    open my $res_fh, '>', $result_prefix or confess "Can't open filehandle: $!";
    while (<$seq_fh>) {
        chomp;
        if(/^>/) {
            print $res_fh uc($_) . " job_id_" . $c->{job_id} . "\n";
        } else {
            print $res_fh uc($_) . " AGCTNNN\n";
        }
    }
    $res_fh->close;
    $seq_fh->close;
    return job->sys("cp $seq_file $result_prefix.orig");
}
