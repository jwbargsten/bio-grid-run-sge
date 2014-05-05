#!/usr/bin/env perl
# created on 2013-12-10

use warnings;
use strict;
use 5.010;

use Bio::Grid::Run::SGE::Log::Analysis;
use Data::Printer;

my $job_name = shift;
my $la       = Bio::Grid::Run::SGE::Log::Analysis->new(
  config_file => '',
  c           => { job_name => $job_name, job_id => $$ }
);
p { %{ $la->c }, msg => \@ARGV };
$la->_report_log(@ARGV);
$la->notify;
