use Mojo::Base -strict;

use Test::More;
use Test::Mojo;

use lib 't/lib';
use TestDB qw(reset_db test_app test_pg);
use KohaPluginStore::Model::Developer;
use KohaPluginStore::Model::Plugin;
use KohaPluginStore::Model::PluginMaintainer;

reset_db();

my $t = test_app();

$t->app->config->{oauth_mock} = 1;
$t->get_ok('/auth/github');
$t->app->config->{oauth_mock} = 0;

subtest 'shows the welcome-back header and the submit/bulk-submit nav buttons' => sub {
    $t->get_ok('/my-plugins')
      ->status_is(200)
      ->content_like(qr/Welcome back, mockdev/i)
      ->element_exists('a[href="/new-plugin"]')
      ->element_exists('a[href="/new-plugin/bulk"]')
      ->content_like(qr/Submit a new plugin/i)
      ->content_like(qr/Bulk submit plugins/i);
};

subtest 'shows an empty state when the developer has no plugins yet' => sub {
    $t->get_ok('/my-plugins')
      ->status_is(200)
      ->content_like(qr/don't have any plugins yet/i);
};

subtest 'lists the developer\'s own plugins once they have one' => sub {
    my $owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find(
        { oauth_provider_key => 'github', provider_user_id => 'mock' }
    );
    KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { name => 'Widget', repo_url => 'https://github.com/dev/widget', developer_id => $owner->id }
    );

    $t->get_ok('/my-plugins')
      ->status_is(200)
      ->content_like(qr/Widget/)
      ->content_unlike(qr/don't have any plugins yet/i);
};

subtest 'lists a plugin the developer maintains but does not own' => sub {
    reset_db();
    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    my $mockdev = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find(
        { oauth_provider_key => 'github', provider_user_id => 'mock' }
    );
    my $other_owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
        { oauth_provider_key => 'github', provider_user_id => 'other-owner', username => 'other-owner' }
    );
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'shared-widget', { name => 'Shared Widget', repo_url => 'https://github.com/dev/shared-widget', developer_id => $other_owner->id }
    );
    KohaPluginStore::Model::PluginMaintainer->new( pg => test_pg() )->grant(
        { plugin_id => $plugin->id, developer_id => $mockdev->id, role => 'maintainer', granted_via => 'github_access' }
    );

    $t->get_ok('/my-plugins')->status_is(200)->content_like(qr/Shared Widget/);
};

subtest 'a private plugin is badged as private in the my-plugins list' => sub {
    reset_db();
    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    my $owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find(
        { oauth_provider_key => 'github', provider_user_id => 'mock' }
    );
    KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'secret-widget', { name => 'SecretWidget', repo_url => 'https://github.com/dev/secret-widget', developer_id => $owner->id, is_private => 1 }
    );

    $t->get_ok('/my-plugins')
      ->status_is(200)
      ->content_like(qr/SecretWidget/)
      ->content_like(qr/Private/);

    $t->get_ok('/logout');
};

done_testing();
