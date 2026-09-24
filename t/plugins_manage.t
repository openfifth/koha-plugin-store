use Mojo::Base -strict;

use Test::More;
use Test::Mojo;

use lib 't/lib';
use TestDB qw(reset_db test_app test_pg);

use KohaPluginStore::Model::Plugin;
use KohaPluginStore::Model::PluginVersion;
use KohaPluginStore::Model::Developer;

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

done_testing();
