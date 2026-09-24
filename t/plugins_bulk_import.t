use Mojo::Base -strict;

use Test::More;
use Test::Mojo;

use lib 't/lib';
use TestDB qw(reset_db test_app test_pg);
use CsrfHelper qw(csrf_token);
use KohaPluginStore::Model::Plugin;
use KohaPluginStore::Model::PluginVersion;
use KohaPluginStore::Model::Developer;
use KohaPluginStore::Model::PluginMaintainer;

reset_db();

my $t = test_app();

$t->app->config->{oauth_mock} = 1;
$t->get_ok('/auth/github');
$t->app->config->{oauth_mock} = 0;

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

subtest 'GET /new-plugin/bulk shows a checkbox per cached repo, with a filter input' => sub {
    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::fetch_all_repos = sub {
        return [
            { full_name => 'martin/koha_plugin_foo', html_url => 'https://github.com/martin/koha_plugin_foo' },
            { full_name => 'martin/unrelated-repo',  html_url => 'https://github.com/martin/unrelated-repo' },
        ];
    };

    $t->get_ok('/new-plugin/bulk')
      ->status_is(200)
      ->element_exists('#repo_filter')
      ->element_exists('#select_all_visible')
      ->element_exists('input[type="checkbox"][name="plugin_repos"][value="https://github.com/martin/koha_plugin_foo"]')
      ->element_exists('input[type="checkbox"][name="plugin_repos"][value="https://github.com/martin/unrelated-repo"]');
};

subtest 'a repo not owned by the developer is reported as an error, not created' => sub {
    reset_db();
    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::fetch_all_repos = sub { return []; };

    $t->post_ok(
        '/new-plugin/bulk' => form => {
            plugin_repos => 'https://github.com/someoneelse/widget',
            csrf_token   => csrf_token($t),
        }
    )
      ->status_is(200)
      ->content_like(qr/Not in your list/);

    is(
        KohaPluginStore::Model::Plugin->new( pg => test_pg() )->find( { repo_url => 'https://github.com/someoneelse/widget' } ),
        undef,
        'no plugin row was created'
    );
};

subtest 'a new repo with an eligible release is submitted' => sub {
    reset_db();
    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::fetch_all_repos = sub {
        return [ { full_name => 'octocat/koha_plugin_foo', html_url => 'https://github.com/octocat/koha_plugin_foo' } ];
    };
    *KohaPluginStore::GitHub::fetch_releases = sub { return [ _release() ] };

    $t->post_ok(
        '/new-plugin/bulk' => form => {
            plugin_repos => 'https://github.com/octocat/koha_plugin_foo',
            csrf_token   => csrf_token($t),
        }
    )
      ->status_is(200)
      ->content_like(qr/Submitted/);

    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->find( { repo_url => 'https://github.com/octocat/koha_plugin_foo' } );
    ok( $plugin, 'a plugin row was created' );

    my $version = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->find( { plugin_id => $plugin->id } );
    is( $version->tag_name, 'v1.0.0', 'the eligible release was recorded' );
    is( $version->status,   'submitted' );

    is( $t->app->minion->jobs( { tasks => ['process_plugin_version'] } )->total, 1, 'a job was enqueued' );
};

subtest 'a repo with no release containing exactly one .kpz asset is skipped, not created' => sub {
    reset_db();
    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::fetch_all_repos = sub {
        return [ { full_name => 'octocat/no-assets', html_url => 'https://github.com/octocat/no-assets' } ];
    };
    *KohaPluginStore::GitHub::fetch_releases = sub { return [ _release( assets => [] ) ] };

    $t->post_ok(
        '/new-plugin/bulk' => form => {
            plugin_repos => 'https://github.com/octocat/no-assets',
            csrf_token   => csrf_token($t),
        }
    )
      ->status_is(200)
      ->content_like(qr/No release with exactly one/);

    is(
        KohaPluginStore::Model::Plugin->new( pg => test_pg() )->find( { repo_url => 'https://github.com/octocat/no-assets' } ),
        undef,
        'no plugin row was created'
    );
};

subtest 'an already-submitted repo with a new eligible release gets synced onto the existing plugin, not duplicated' => sub {
    reset_db();
    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    my $owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find(
        { oauth_provider_key => 'github', provider_user_id => 'mock' }
    );
    my $existing_plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'koha_plugin_bar', { repo_url => 'https://github.com/octocat/koha_plugin_bar', developer_id => $owner->id }
    );
    KohaPluginStore::Model::PluginMaintainer->new( pg => test_pg() )->grant(
        { plugin_id => $existing_plugin->id, developer_id => $owner->id, role => 'owner', granted_via => 'creator' }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $existing_plugin->id, tag_name => 'v1.0.0', status => 'published' }
    );

    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::fetch_all_repos = sub {
        return [ { full_name => 'octocat/koha_plugin_bar', html_url => 'https://github.com/octocat/koha_plugin_bar' } ];
    };
    *KohaPluginStore::GitHub::fetch_releases = sub {
        return [ _release( tag_name => 'v2.0.0', name => 'v2.0.0' ), _release( tag_name => 'v1.0.0', name => 'v1.0.0' ) ];
    };

    $t->post_ok(
        '/new-plugin/bulk' => form => {
            plugin_repos => 'https://github.com/octocat/koha_plugin_bar',
            csrf_token   => csrf_token($t),
        }
    )
      ->status_is(200)
      ->content_like(qr/Synced new release v2\.0\.0/);

    my @plugins = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->search( { repo_url => 'https://github.com/octocat/koha_plugin_bar' } );
    is( scalar @plugins, 1, 'still only one plugin row for this repo' );

    my @versions = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->search( { plugin_id => $existing_plugin->id } );
    is( scalar @versions, 2, 'the new release was added as a second version' );
};

subtest 'an already-submitted repo with nothing new is reported as up to date' => sub {
    reset_db();
    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    my $owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find(
        { oauth_provider_key => 'github', provider_user_id => 'mock' }
    );
    my $existing_plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'koha_plugin_baz', { repo_url => 'https://github.com/octocat/koha_plugin_baz', developer_id => $owner->id }
    );
    KohaPluginStore::Model::PluginMaintainer->new( pg => test_pg() )->grant(
        { plugin_id => $existing_plugin->id, developer_id => $owner->id, role => 'owner', granted_via => 'creator' }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $existing_plugin->id, tag_name => 'v1.0.0', status => 'published' }
    );

    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::fetch_all_repos = sub {
        return [ { full_name => 'octocat/koha_plugin_baz', html_url => 'https://github.com/octocat/koha_plugin_baz' } ];
    };
    *KohaPluginStore::GitHub::fetch_releases = sub { return [ _release( tag_name => 'v1.0.0', name => 'v1.0.0' ) ] };

    $t->post_ok(
        '/new-plugin/bulk' => form => {
            plugin_repos => 'https://github.com/octocat/koha_plugin_baz',
            csrf_token   => csrf_token($t),
        }
    )
      ->status_is(200)
      ->content_like(qr/No new release since the last import/);

    my @versions = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->search( { plugin_id => $existing_plugin->id } );
    is( scalar @versions, 1, 'no duplicate version was created' );
};

subtest 'multiple selected repos are each processed independently' => sub {
    reset_db();
    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::fetch_all_repos = sub {
        return [
            { full_name => 'octocat/koha_plugin_one', html_url => 'https://github.com/octocat/koha_plugin_one' },
            { full_name => 'octocat/koha_plugin_two', html_url => 'https://github.com/octocat/koha_plugin_two' },
        ];
    };
    *KohaPluginStore::GitHub::fetch_releases = sub { return [ _release() ] };

    $t->post_ok(
        '/new-plugin/bulk' => form => {
            plugin_repos => [
                'https://github.com/octocat/koha_plugin_one',
                'https://github.com/octocat/koha_plugin_two',
            ],
            csrf_token => csrf_token($t),
        }
    )->status_is(200);

    ok( KohaPluginStore::Model::Plugin->new( pg => test_pg() )->find( { repo_url => 'https://github.com/octocat/koha_plugin_one' } ), 'first repo submitted' );
    ok( KohaPluginStore::Model::Plugin->new( pg => test_pg() )->find( { repo_url => 'https://github.com/octocat/koha_plugin_two' } ), 'second repo submitted' );
};

subtest 'missing csrf token is rejected' => sub {
    reset_db();
    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    $t->post_ok( '/new-plugin/bulk' => form => { plugin_repos => 'https://github.com/octocat/koha_plugin_foo' } )
      ->status_is(403);
};

subtest 'a repo already submitted by someone else is folded in as a maintainer when GitHub confirms real access' => sub {
    reset_db();
    my $original_owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
        { oauth_provider_key => 'github', provider_user_id => 'original3', username => 'original3' }
    );
    my $existing_plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'koha_plugin_shared', { repo_url => 'https://github.com/octocat/koha_plugin_shared', developer_id => $original_owner->id }
    );
    KohaPluginStore::Model::PluginMaintainer->new( pg => test_pg() )->grant(
        { plugin_id => $existing_plugin->id, developer_id => $original_owner->id, role => 'owner', granted_via => 'creator' }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $existing_plugin->id, tag_name => 'v1.0.0', status => 'published' }
    );

    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');    # mockdev -- a different developer than $original_owner
    $t->app->config->{oauth_mock} = 0;

    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::fetch_all_repos = sub {
        return [ {
            full_name   => 'octocat/koha_plugin_shared',
            html_url    => 'https://github.com/octocat/koha_plugin_shared',
            permissions => { push => 1 },
        } ];
    };
    *KohaPluginStore::GitHub::fetch_releases = sub {
        return [ _release( tag_name => 'v2.0.0', name => 'v2.0.0' ) ];
    };

    $t->post_ok(
        '/new-plugin/bulk' => form => {
            plugin_repos => 'https://github.com/octocat/koha_plugin_shared',
            csrf_token   => csrf_token($t),
        }
    )
      ->status_is(200)
      ->content_like(qr/Synced new release v2\.0\.0/);

    my @plugins = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->search( { repo_url => 'https://github.com/octocat/koha_plugin_shared' } );
    is( scalar @plugins, 1, 'still only one plugin row' );

    my $mockdev = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find( { oauth_provider_key => 'github', provider_user_id => 'mock' } );
    ok(
        KohaPluginStore::Model::PluginMaintainer->new( pg => test_pg() )->find( { plugin_id => $existing_plugin->id, developer_id => $mockdev->id } ),
        'the submitter was granted maintainer status'
    );

    $t->get_ok('/logout');
};

subtest 'a repo already submitted by someone else, with no real GitHub access, is reported as an error' => sub {
    reset_db();
    my $original_owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
        { oauth_provider_key => 'github', provider_user_id => 'original4', username => 'original4' }
    );
    KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'koha_plugin_locked', { repo_url => 'https://github.com/octocat/koha_plugin_locked', developer_id => $original_owner->id }
    );

    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::fetch_all_repos = sub {
        return [ {
            full_name   => 'octocat/koha_plugin_locked',
            html_url    => 'https://github.com/octocat/koha_plugin_locked',
            permissions => { pull => 1 },    # read-only -- must not grant
        } ];
    };

    $t->post_ok(
        '/new-plugin/bulk' => form => {
            plugin_repos => 'https://github.com/octocat/koha_plugin_locked',
            csrf_token   => csrf_token($t),
        }
    )
      ->status_is(200)
      ->content_like(qr/Not in your list/);

    $t->get_ok('/logout');
};

done_testing();
