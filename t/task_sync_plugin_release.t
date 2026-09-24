use Mojo::Base -strict;
use Test::More;
use Test::Mojo;

use lib 't/lib';
use TestDB qw(reset_db test_app test_pg);

use KohaPluginStore::Model::Plugin;
use KohaPluginStore::Model::PluginVersion;

sub _release {
    my (%overrides) = @_;
    return {
        tag_name     => 'v1.0.0',
        name         => 'v1.0.0',
        published_at => '2026-01-01T00:00:00Z',
        author       => { login => 'octocat', avatar_url => 'https://example.com/a.png' },
        assets       => [ { name => 'plugin.kpz', browser_download_url => 'https://example.com/plugin.kpz' } ],
        %overrides,
    };
}

reset_db();

my $t = test_app();

# This file tests sync_plugin_release's own boundary (it creates a version
# row and enqueues process_plugin_version) -- not process_plugin_version's
# own behaviour, which is task_process_plugin_version.t's job and is fully
# mocked there. Left unstubbed, perform_jobs_in_foreground's dequeue loop
# (Minion.pm: "while (my $job = $worker->register->dequeue(...))") re-queries
# after every job, so it picks up and actually runs the just-enqueued
# process_plugin_version job in the very same foreground pass -- and this
# container has real outbound internet access, so it would make a genuine
# GitHub download attempt against the fixture's placeholder URL and
# immediately overwrite the new version's status away from 'submitted' (its
# very first action, before any download even happens). Overriding the task
# via add_task() again replaces Minion's own name->coderef hash entry
# (Minion.pm's add_task: "$self->tasks->{$name} = $task"), independent of
# Perl sub binding, so it reliably takes effect even though the real handler
# was already registered when the app booted.
$t->app->minion->add_task( process_plugin_version => sub { return } );

subtest 'a new eligible release creates a version and enqueues process_plugin_version' => sub {
    reset_db();
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { repo_url => 'https://github.com/dev/widget' }
    );

    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::fetch_releases = sub { return [ _release() ] };

    $t->app->minion->enqueue( sync_plugin_release => [ $plugin->id ] );
    $t->app->minion->perform_jobs_in_foreground;

    my @versions = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->search( { plugin_id => $plugin->id } );
    is( scalar @versions, 1, 'one version was created' );
    is( $versions[0]->tag_name, 'v1.0.0' );
    is( $versions[0]->status, 'submitted' );

    is( $t->app->minion->jobs( { tasks => ['process_plugin_version'] } )->total, 1, 'process_plugin_version was enqueued for it' );
};

subtest 'an already-submitted tag is skipped, not re-created' => sub {
    reset_db();
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { repo_url => 'https://github.com/dev/widget' }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v1.0.0', status => 'published' }
    );

    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::fetch_releases = sub { return [ _release() ] };

    $t->app->minion->enqueue( sync_plugin_release => [ $plugin->id ] );
    $t->app->minion->perform_jobs_in_foreground;

    my @versions = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->search( { plugin_id => $plugin->id } );
    is( scalar @versions, 1, 'still only the one pre-existing version -- nothing duplicated' );
};

subtest 'a release with no valid .kpz asset is skipped' => sub {
    reset_db();
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { repo_url => 'https://github.com/dev/widget' }
    );

    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::fetch_releases = sub { return [ _release( assets => [] ) ] };

    $t->app->minion->enqueue( sync_plugin_release => [ $plugin->id ] );
    $t->app->minion->perform_jobs_in_foreground;

    my @versions = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->search( { plugin_id => $plugin->id } );
    is( scalar @versions, 0, 'no version was created for a release with no .kpz asset' );
};

subtest 'one release failing to create does not stop a second, genuinely eligible release in the same run' => sub {
    reset_db();
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { repo_url => 'https://github.com/dev/widget' }
    );
    # Pre-existing version with the same tag as one of the two "new" releases
    # below -- its create() will hit plugin_versions_plugin_id_tag_name_key
    # and die, simulating the create-time failure this subtest is about.
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v1.0.0', status => 'published' }
    );

    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::fetch_releases = sub {
        return [ _release( tag_name => 'v1.0.0' ), _release( tag_name => 'v2.0.0', name => 'v2.0.0' ) ];
    };
    # existing_tags() only knows about the real pre-existing row, so
    # new_releases() will (correctly) treat v1.0.0 as new too -- the actual
    # unique-constraint clash is only discovered at create() time, which is
    # exactly the race this subtest exercises.
    *KohaPluginStore::Model::PluginVersion::existing_tags = sub { return {}; };

    $t->app->minion->enqueue( sync_plugin_release => [ $plugin->id ] );
    $t->app->minion->perform_jobs_in_foreground;

    my @versions = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->search( { plugin_id => $plugin->id } );
    is( scalar @versions, 2, 'the original v1.0.0 plus the newly-created v2.0.0 -- the v1.0.0 create failure did not stop v2.0.0' );
    ok( ( grep { $_->tag_name eq 'v2.0.0' } @versions ), 'v2.0.0 was created despite v1.0.0 failing in the same run' );
};

done_testing();
