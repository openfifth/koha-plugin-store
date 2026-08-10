package TestDB;

use Modern::Perl;
use Exporter 'import';
use Mojo::Pg;

our @EXPORT_OK = qw(reset_db test_pg);

my $DSN = $ENV{KOHA_PLUGIN_STORE_TEST_DSN}
    || 'postgresql://koha_plugin_store:koha_plugin_store@127.0.0.1:55432/koha_plugin_store';

my $PG = Mojo::Pg->new($DSN);

sub test_pg {
    return $PG;
}

sub reset_db {
    $PG->db->query(
        'TRUNCATE plugin_versions, plugins, developers, plugin_contributors RESTART IDENTITY CASCADE'
    );
}

1;
