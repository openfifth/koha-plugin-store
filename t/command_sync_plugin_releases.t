use Mojo::Base -strict;
use Test::More;

use lib 't/lib';
use TestDB qw(reset_db test_app test_pg);

use KohaPluginStore::Command::sync_plugin_releases;
use KohaPluginStore::Model::Plugin;

reset_db();

# test_app() (not a bare KohaPluginStore->new) is required here, not just for
# convenience -- it's the only helper that also repoints Minion's own backend
# connection at the test database (see TestDB.pm's own comment on test_app).
# A bare KohaPluginStore->new + ->pg(test_pg()) leaves $app->minion silently
# talking to the real dev database, since Minion's backend is a separate
# connection registered at startup(), independent of $app->pg.
my $t = test_app();

my $opted_in_a = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
    'widget-a', { repo_url => 'https://github.com/dev/widget-a', auto_sync_releases => 1 }
);
my $opted_in_b = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
    'widget-b', { repo_url => 'https://github.com/dev/widget-b', auto_sync_releases => 1 }
);
my $opted_out = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
    'widget-c', { repo_url => 'https://github.com/dev/widget-c' }
);

KohaPluginStore::Command::sync_plugin_releases->new( app => $t->app )->run;

# Count jobs per plugin by manually filtering (Minion's args filter isn't supported in this version)
my %job_count;
my $all_jobs = $t->app->minion->jobs( { tasks => ['sync_plugin_release'] } );
while (my $job = $all_jobs->next) {
    my $plugin_id = $job->{args}[0];
    $job_count{$plugin_id}++;
}

is( $job_count{ $opted_in_a->id } // 0, 1, 'a job was enqueued for opted-in plugin A' );
is( $job_count{ $opted_in_b->id } // 0, 1, 'a job was enqueued for opted-in plugin B' );
is( $job_count{ $opted_out->id } // 0, 0, 'no job was enqueued for the opted-out plugin' );
is( $t->app->minion->jobs( { tasks => ['sync_plugin_release'] } )->total, 2, 'exactly two jobs total -- one per opted-in plugin, not one per plugin in the catalog' );

done_testing();
