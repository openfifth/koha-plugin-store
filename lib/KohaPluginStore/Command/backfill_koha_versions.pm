package KohaPluginStore::Command::backfill_koha_versions;
use Mojo::Base 'Mojolicious::Command', -signatures;

use KohaPluginStore::Version qw(normalize);

has description => 'Normalize existing koha_min_version values to the canonical form';
has usage       => sub { shift->extract_usage };

sub run ($self, @args) {
    my $pg = $self->app->pg;

    my $rows = $pg->db->query('SELECT id, koha_min_version FROM plugin_versions')->hashes;

    my ( $updated, $skipped ) = ( 0, 0 );
    for my $row (@$rows) {
        my $canonical = normalize( $row->{koha_min_version} );
        unless ($canonical) {
            warn "plugin_versions.id=$row->{id}: could not parse koha_min_version '"
                . ( $row->{koha_min_version} // '(null)' ) . "', leaving unchanged\n";
            $skipped++;
            next;
        }
        next if $canonical eq $row->{koha_min_version};

        $pg->db->query( 'UPDATE plugin_versions SET koha_min_version = ? WHERE id = ?', $canonical, $row->{id} );
        $updated++;
    }

    say "Normalized $updated row(s), skipped $skipped unparseable row(s).";
}

1;

=encoding utf8

=head1 NAME

KohaPluginStore::Command::backfill_koha_versions - Normalize existing koha_min_version values

=head1 SYNOPSIS

  Usage: APPLICATION backfill_koha_versions

=cut
