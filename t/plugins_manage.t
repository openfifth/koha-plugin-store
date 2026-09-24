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

subtest 'an anonymous visitor is redirected/denied' => sub {
    reset_db();
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { name => 'Widget', repo_url => 'https://github.com/dev/widget' }
    );

    $t->get_ok( '/plugins/' . $plugin->slug . '/manage' )->status_is(404);
};

subtest 'a logged-in developer who does not own this plugin gets a 404' => sub {
    reset_db();
    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { name => 'Widget', repo_url => 'https://github.com/dev/widget' }
    );

    $t->get_ok( '/plugins/' . $plugin->slug . '/manage' )->status_is(404);

    $t->get_ok('/logout');
};

subtest 'a different, real logged-in developer (not the owner) gets a 404 for another developer\'s manage page' => sub {
    reset_db();
    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    # Developer A: the mock-OAuth identity, now logged in (the requester).
    my $developer_a = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find(
        { oauth_provider_key => 'github', provider_user_id => 'mock' }
    );

    # Developer B: a second, distinct, real Developer row -- the plugin owner.
    # Not the logged-in session; not a NULL developer_id.
    my $developer_b = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
        { oauth_provider_key => 'github', provider_user_id => 'other-owner-1', username => 'other-owner' }
    );
    isnt( $developer_a->id, $developer_b->id, 'two distinct real developer rows' );

    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'gadget', { name => 'Gadget', repo_url => 'https://github.com/dev/gadget', developer_id => $developer_b->id }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v1.0.0', status => 'submitted' }
    );

    # Developer A is logged in (via the mock OAuth session), developer B owns
    # the plugin -- a real, non-owning developer requesting someone else's
    # manage page must still get a 404.
    $t->get_ok( '/plugins/' . $plugin->slug . '/manage' )->status_is(404);

    $t->get_ok('/logout');
};

subtest 'the owner sees every version regardless of status, plus GitHub-sync section, and triggers a fetch' => sub {
    reset_db();
    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    my $owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find(
        { oauth_provider_key => 'github', provider_user_id => 'mock' }
    );
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { name => 'Widget', repo_url => 'https://github.com/dev/widget', developer_id => $owner->id }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v1.0.0', status => 'published' }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v0.9.0', status => 'changes_requested', certification_tier => 'INCOMPLETE' }
    );

    my $fetch_calls = 0;
    {
        no strict 'refs';
        no warnings 'redefine';
        *KohaPluginStore::GitHub::fetch_releases = sub {
            $fetch_calls++;
            return [
                { name => 'v2.0.0', tag_name => 'v2.0.0', published_at => '2026-01-01', assets => [ { name => 'plugin.kpz' } ] },
                { name => 'v1.0.0', tag_name => 'v1.0.0', published_at => '2025-12-01', assets => [ { name => 'plugin.kpz' } ] },
                { name => 'v0.5.0', tag_name => 'v0.5.0', published_at => '2025-06-01', assets => [] },
            ];
        };
    }

    $t->get_ok( '/plugins/' . $plugin->slug . '/manage' )
      ->status_is(200)
      ->content_like(qr/v1\.0\.0/)
      ->content_like(qr/v0\.9\.0/)
      ->content_like(qr/v2\.0\.0/)
      ->element_exists('form[action="/new-release"]')
      ->element_exists('tr.table-success')
      ->element_exists('tr.table-danger');
    is( $fetch_calls, 1 );

    $t->get_ok('/logout');
};

subtest 'a granted maintainer (not the original owner) can reach the manage page' => sub {
    reset_db();
    my $owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
        { oauth_provider_key => 'github', provider_user_id => 'owner5', username => 'owner5' }
    );
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget5', { repo_url => 'https://github.com/dev/widget5', developer_id => $owner->id }
    );

    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');    # mockdev
    $t->app->config->{oauth_mock} = 0;

    my $mockdev = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find(
        { oauth_provider_key => 'github', provider_user_id => 'mock' }
    );
    KohaPluginStore::Model::PluginMaintainer->new( pg => test_pg() )->grant(
        { plugin_id => $plugin->id, developer_id => $mockdev->id, role => 'maintainer', granted_via => 'github_access' }
    );

    {
        no strict 'refs';
        no warnings 'redefine';
        *KohaPluginStore::GitHub::fetch_releases = sub { return []; };
    }

    $t->get_ok( '/plugins/' . $plugin->slug . '/manage' )->status_is(200);

    $t->get_ok('/logout');
};

subtest 'a maintainer can trigger an immediate release sync' => sub {
    reset_db();
    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    my $owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find(
        { oauth_provider_key => 'github', provider_user_id => 'mock' }
    );
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { repo_url => 'https://github.com/dev/widget', developer_id => $owner->id }
    );

    $t->post_ok( '/plugins/' . $plugin->slug . '/sync-releases' => form => { csrf_token => csrf_token($t) } )
      ->status_is(302);

    # Count jobs per plugin by manually filtering (Minion's args filter isn't supported in this version)
    my %job_count;
    my $all_jobs = $t->app->minion->jobs( { tasks => ['sync_plugin_release'] } );
    while (my $job = $all_jobs->next) {
        my $plugin_id = $job->{args}[0];
        $job_count{$plugin_id}++;
    }
    is( $job_count{ $plugin->id } // 0, 1, 'a sync job was enqueued for this plugin' );

    $t->get_ok('/logout');
};

subtest 'a non-maintainer cannot trigger a sync' => sub {
    reset_db();
    my $real_owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
        { oauth_provider_key => 'github', provider_user_id => 'real-owner', username => 'realowner' }
    );
    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');    # logs in as mockdev, NOT $real_owner
    $t->app->config->{oauth_mock} = 0;

    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { repo_url => 'https://github.com/dev/widget', developer_id => $real_owner->id }
    );

    $t->post_ok( '/plugins/' . $plugin->slug . '/sync-releases' => form => { csrf_token => csrf_token($t) } )
      ->status_is(401);

    is( $t->app->minion->jobs( { tasks => ['sync_plugin_release'] } )->total, 0, 'no job was enqueued' );

    $t->get_ok('/logout');
};

subtest 'a non-maintainer cannot toggle auto-sync' => sub {
    reset_db();
    my $real_owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
        { oauth_provider_key => 'github', provider_user_id => 'real-owner', username => 'realowner' }
    );
    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');    # logs in as mockdev, NOT $real_owner
    $t->app->config->{oauth_mock} = 0;

    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { repo_url => 'https://github.com/dev/widget', developer_id => $real_owner->id }
    );

    $t->post_ok( '/plugins/' . $plugin->slug . '/auto-sync' => form => { auto_sync_releases => 1, csrf_token => csrf_token($t) } )
      ->status_is(401);

    my $reloaded = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->find( { id => $plugin->id } );
    ok( !$reloaded->auto_sync_releases, 'the rejected request did not silently take effect' );

    $t->get_ok('/logout');
};

subtest 'a maintainer posting sync-releases or auto-sync without a valid CSRF token gets 403' => sub {
    reset_db();
    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    my $owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find(
        { oauth_provider_key => 'github', provider_user_id => 'mock' }
    );
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { repo_url => 'https://github.com/dev/widget', developer_id => $owner->id }
    );

    $t->post_ok( '/plugins/' . $plugin->slug . '/sync-releases' => form => {} )
      ->status_is(403);

    is( $t->app->minion->jobs( { tasks => ['sync_plugin_release'] } )->total, 0, 'no job was enqueued without a valid CSRF token' );

    $t->post_ok( '/plugins/' . $plugin->slug . '/auto-sync' => form => { auto_sync_releases => 1 } )
      ->status_is(403);

    my $reloaded = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->find( { id => $plugin->id } );
    ok( !$reloaded->auto_sync_releases, 'auto_sync_releases was not changed without a valid CSRF token' );

    $t->get_ok('/logout');
};

subtest 'a maintainer can toggle auto-sync off' => sub {
    reset_db();
    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    my $owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find(
        { oauth_provider_key => 'github', provider_user_id => 'mock' }
    );
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { repo_url => 'https://github.com/dev/widget', developer_id => $owner->id, auto_sync_releases => 1 }
    );

    # An unchecked HTML checkbox is simply omitted from the submitted form --
    # not sent as auto_sync_releases => 0 -- so the request here carries no
    # auto_sync_releases param at all.
    $t->post_ok( '/plugins/' . $plugin->slug . '/auto-sync' => form => { csrf_token => csrf_token($t) } )
      ->status_is(302);

    my $reloaded = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->find( { id => $plugin->id } );
    ok( !$reloaded->auto_sync_releases, 'auto-sync was turned off' );

    $t->get_ok('/logout');
};

subtest 'a co-maintainer (not the owner) can toggle auto-sync on' => sub {
    reset_db();
    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    my $maintainer_dev = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find(
        { oauth_provider_key => 'github', provider_user_id => 'mock' }
    );
    my $real_owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
        { oauth_provider_key => 'github', provider_user_id => 'real-owner', username => 'realowner' }
    );
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { repo_url => 'https://github.com/dev/widget', developer_id => $real_owner->id }
    );
    KohaPluginStore::Model::PluginMaintainer->new( pg => test_pg() )->grant(
        { plugin_id => $plugin->id, developer_id => $maintainer_dev->id, role => 'maintainer', granted_via => 'github_access' }
    );

    $t->post_ok( '/plugins/' . $plugin->slug . '/auto-sync' => form => { auto_sync_releases => 1, csrf_token => csrf_token($t) } )
      ->status_is(302);

    my $reloaded = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->find( { id => $plugin->id } );
    ok( $reloaded->auto_sync_releases, 'the co-maintainer successfully enabled auto-sync' );

    $t->get_ok('/logout');
};

subtest 'the manage page shows the auto-sync checkbox and sync-now button' => sub {
    reset_db();
    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    my $owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find(
        { oauth_provider_key => 'github', provider_user_id => 'mock' }
    );
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { repo_url => 'https://github.com/dev/widget', developer_id => $owner->id }
    );

    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::fetch_releases = sub { return []; };

    $t->get_ok( '/plugins/' . $plugin->slug . '/manage' )
      ->status_is(200)
      ->element_exists('input[name="auto_sync_releases"]')
      ->element_exists('form[action="/plugins/' . $plugin->slug . '/sync-releases"]');

    $t->get_ok('/logout');
};

subtest 'a maintainer can toggle a plugin private' => sub {
    reset_db();
    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    my $owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find(
        { oauth_provider_key => 'github', provider_user_id => 'mock' }
    );
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { repo_url => 'https://github.com/dev/widget', developer_id => $owner->id }
    );

    $t->post_ok( '/plugins/' . $plugin->slug . '/private' => form => { is_private => 1, csrf_token => csrf_token($t) } )
      ->status_is(302);

    my $reloaded = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->find( { id => $plugin->id } );
    ok( $reloaded->is_private, 'the plugin is now private' );

    $t->get_ok('/logout');
};

subtest 'a maintainer can toggle a plugin back to public' => sub {
    reset_db();
    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    my $owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find(
        { oauth_provider_key => 'github', provider_user_id => 'mock' }
    );
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { repo_url => 'https://github.com/dev/widget', developer_id => $owner->id, is_private => 1 }
    );

    $t->post_ok( '/plugins/' . $plugin->slug . '/private' => form => { csrf_token => csrf_token($t) } )
      ->status_is(302);

    my $reloaded = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->find( { id => $plugin->id } );
    ok( !$reloaded->is_private, 'the plugin is now public -- no is_private param sent matches true unchecked-checkbox behavior' );

    $t->get_ok('/logout');
};

subtest 'a non-maintainer cannot toggle a plugin private' => sub {
    reset_db();
    my $real_owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
        { oauth_provider_key => 'github', provider_user_id => 'real-owner', username => 'realowner' }
    );
    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');    # logs in as mockdev, NOT $real_owner
    $t->app->config->{oauth_mock} = 0;

    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { repo_url => 'https://github.com/dev/widget', developer_id => $real_owner->id }
    );

    $t->post_ok( '/plugins/' . $plugin->slug . '/private' => form => { is_private => 1, csrf_token => csrf_token($t) } )
      ->status_is(401);

    my $reloaded = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->find( { id => $plugin->id } );
    ok( !$reloaded->is_private, 'unchanged' );

    $t->get_ok('/logout');
};

subtest 'a co-maintainer (not the owner) can toggle a plugin private' => sub {
    reset_db();
    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    my $maintainer_dev = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find(
        { oauth_provider_key => 'github', provider_user_id => 'mock' }
    );
    my $real_owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
        { oauth_provider_key => 'github', provider_user_id => 'real-owner', username => 'realowner' }
    );
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { repo_url => 'https://github.com/dev/widget', developer_id => $real_owner->id }
    );
    KohaPluginStore::Model::PluginMaintainer->new( pg => test_pg() )->grant(
        { plugin_id => $plugin->id, developer_id => $maintainer_dev->id, role => 'maintainer', granted_via => 'github_access' }
    );

    $t->post_ok( '/plugins/' . $plugin->slug . '/private' => form => { is_private => 1, csrf_token => csrf_token($t) } )
      ->status_is(302);

    my $reloaded = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->find( { id => $plugin->id } );
    ok( $reloaded->is_private, 'the co-maintainer successfully made it private' );

    $t->get_ok('/logout');
};

done_testing();
