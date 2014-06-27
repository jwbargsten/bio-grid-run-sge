#Copyright (c) 2010 Joachim Bargsten <code at bargsten dot org>. All rights reserved.

package Bio::Grid::Run::SGE::Util::Blast;

use warnings;
use strict;
use Carp;
use Data::Dumper;
use IO::Prompt::Tiny qw/prompt/;
use Bio::Grid::Run::SGE::Util qw/my_sys INFO my_glob expand_path my_mkdir/;
use Cwd qw/fastcwd/;
use Params::Validate qw(:all);

use base 'Exporter';
our ( @EXPORT, @EXPORT_OK, %EXPORT_TAGS );
# VERSION

@EXPORT      = qw();
%EXPORT_TAGS = ();
@EXPORT_OK   = qw(formatdb);

sub formatdb {
    my ($c) = @_;
    my %c = validate(
        @_,
        {
            db_seq_files => 1,
            db_name   => 1,
            db_type   => 1,
            db_dir    => 1,
            no_prompt => { default => undef },
        }
    );

    INFO( Dumper \%c );
    # formatdb
    my @reference_files = expand_path( @{ $c{db_seq_files} } );

    my @formatdb_cmd = (
        'formatdb', '-i', @reference_files, '-l', $c{db_name} . '.formatdb.log',
        '-p', ( $c{db_type} =~ /^p/i ? 'T' : 'F' ),
        '-o', 'F', '-a', 'F', '-n', $c{db_name},
    );

    INFO( 'formatdb: ', @formatdb_cmd );
    if ( $c{no_prompt} || prompt( "run formatdb? [yn]", 'y' )  eq 'y') {

        my $olddir    = fastcwd;
        my $blast_dir = expand_path( $c{db_dir} );
        my_mkdir($blast_dir) if ( !-e $blast_dir );

        die unless ( -d $blast_dir );

        chdir $blast_dir;
        INFO "creating blast db in " . fastcwd;

        my_sys @formatdb_cmd;

        chdir $olddir;
        return 1;
    } else {
        return;
    }
}

1;

__END__

=head1 NAME

Bio::Grid::Run::SGE::Util::Blast - basic blast utitlity functions for cluster-wide operations

=head1 SYNOPSIS

    use Bio::Grid::Run::SGE::Util::Blast qw(formatdb);

=head1 DESCRIPTION

=head1 OPTIONS

=head1 SUBROUTINES

=over 4

=item B<< formatdb(\%config) >>

formatdb takes the following parameters:

    %config = (
        db_seq_files => 'sequence files used for db creation',
        input_files? => 'is used for db creation if seq_db_files is not defined',
        blast_db_name => 'database name',
        db_type => 'database type',
        blast_db_dir => 'directory for blast database',
        no_prompt => 0, #don't ask any questions, just do it
    )

=back

=head1 SEE ALSO

=head1 AUTHOR

jw bargsten, C<< <joachim.bargsten at wur.nl> >>

=cut
