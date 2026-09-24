use Mojo::Base -strict;
use Test::More;

use lib 't/lib';
use TestDB qw(reset_db test_pg);

use KohaPluginStore::Model::Plugin;
use KohaPluginStore::Model::Developer;
use KohaPluginStore::Model::PluginMaintainer;
use KohaPluginStore::MaintainerSync;

reset_db();

my $developer = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
    { oauth_provider_key => 'github', provider_user_id => 'dev', username => 'dev' }
);

subtest 'maybe_grant_for_repo grants on push permission' => sub {
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { repo_url => 'https://github.com/dev/widget' }
    );
    my $repo = { html_url => 'https://github.com/dev/widget', permissions => { push => 1, admin => 0, pull => 1 } };

    my $row = KohaPluginStore::MaintainerSync::maybe_grant_for_repo( test_pg(), $developer, $plugin, $repo );
    ok( $row, 'granted' );
    is( $row->role, 'maintainer' );
    is( $row->granted_via, 'github_access' );
};

subtest 'maybe_grant_for_repo grants on admin permission' => sub {
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget2', { repo_url => 'https://github.com/dev/widget2' }
    );
    my $repo = { html_url => 'https://github.com/dev/widget2', permissions => { push => 0, admin => 1, pull => 1 } };

    my $row = KohaPluginStore::MaintainerSync::maybe_grant_for_repo( test_pg(), $developer, $plugin, $repo );
    ok( $row, 'granted' );
};

subtest 'maybe_grant_for_repo does not grant on pull-only permission' => sub {
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget3', { repo_url => 'https://github.com/dev/widget3' }
    );
    my $repo = { html_url => 'https://github.com/dev/widget3', permissions => { push => 0, admin => 0, pull => 1 } };

    my $row = KohaPluginStore::MaintainerSync::maybe_grant_for_repo( test_pg(), $developer, $plugin, $repo );
    ok( !$row, 'not granted' );
    ok(
        !KohaPluginStore::Model::PluginMaintainer->new( pg => test_pg() )->find( { plugin_id => $plugin->id, developer_id => $developer->id } ),
        'no row was created'
    );
};

subtest 'maybe_grant_for_repo does not grant when permissions is missing entirely' => sub {
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget4', { repo_url => 'https://github.com/dev/widget4' }
    );
    my $repo = { html_url => 'https://github.com/dev/widget4' };    # no permissions key at all

    my $row = KohaPluginStore::MaintainerSync::maybe_grant_for_repo( test_pg(), $developer, $plugin, $repo );
    ok( !$row, 'not granted, not a crash' );
};

subtest 'sync_from_repo_list grants for every matching repo in the list, skips non-matching ones' => sub {
    reset_db();
    my $dev = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
        { oauth_provider_key => 'github', provider_user_id => 'dev2', username => 'dev2' }
    );
    my $plugin_a = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'plugin-a', { repo_url => 'https://github.com/someone/plugin-a' }
    );
    # plugin-b (below) is intentionally never submitted to this store -- fetch_all_repos can
    # return repos with no corresponding plugin row at all, and that must be a silent no-op.

    my $repos = [
        { html_url => 'https://github.com/someone/plugin-a', permissions => { push => 1 } },
        { html_url => 'https://github.com/someone/plugin-b', permissions => { push => 1 } },
    ];

    KohaPluginStore::MaintainerSync::sync_from_repo_list( test_pg(), $dev, $repos );

    ok(
        KohaPluginStore::Model::PluginMaintainer->new( pg => test_pg() )->find( { plugin_id => $plugin_a->id, developer_id => $dev->id } ),
        'granted for the repo that matches an existing plugin'
    );
};

done_testing();
