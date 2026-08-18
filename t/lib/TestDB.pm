package TestDB;

use Modern::Perl;
use Exporter 'import';
use Mojo::Pg;
use Test::Mojo;

our @EXPORT_OK = qw(reset_db test_pg test_app);

my $DSN = $ENV{KOHA_PLUGIN_STORE_TEST_DSN}
    || 'postgresql://koha_plugin_store:koha_plugin_store@127.0.0.1:55432/koha_plugin_store';

my $PG = Mojo::Pg->new($DSN);

sub test_pg {
    return $PG;
}

sub reset_db {
    $PG->db->query(
        'TRUNCATE plugin_versions, plugins, developers, plugin_contributors, minion_jobs, minion_locks, minion_schedules, minion_workers RESTART IDENTITY CASCADE'
    );
}

# Builds a Test::Mojo app pointed at the test database -- for *everything*,
# not just $c->pg. KohaPluginStore::startup registers the Minion plugin
# against $self->pg *before* a test gets a chance to override it, so Minion's
# own backend connection is a separate, independent reference that a plain
# $t->app->pg(test_pg()) never touches. Left unfixed, every job-processing
# test silently runs against whatever's in the developer's own
# koha_plugin_store.conf, not the test database -- and if that also happens
# to be a real, populated Postgres with an actual Minion worker attached
# (e.g. a docker dev environment), tests race against it for real jobs.
sub test_app {
    my ($class) = @_;
    $class //= 'KohaPluginStore';

    my $t = Test::Mojo->new($class);
    $t->app->pg( test_pg() );
    $t->app->minion->backend->pg( test_pg() );
    return $t;
}

1;
