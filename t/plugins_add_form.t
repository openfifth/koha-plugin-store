use Mojo::Base -strict;

use Test::More;
use Test::Mojo;

use lib 't/lib';
use TestDB qw(reset_db test_app test_pg);

use KohaPluginStore::Model::Plugin;
use KohaPluginStore::Model::PluginMaintainer;
use KohaPluginStore::Model::Developer;

reset_db();

my $t = test_app();

$t->app->config->{oauth_mock} = 1;
$t->get_ok('/auth/github');
$t->app->config->{oauth_mock} = 0;

{
    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::fetch_all_repos = sub {
        return [ { full_name => 'octocat/Hello-World', html_url => 'https://github.com/octocat/Hello-World' } ];
    };
}

subtest 'first visit auto-fetches and shows the repo dropdown' => sub {
    $t->get_ok('/new-plugin')
      ->status_is(200)
      ->element_exists('select[name="plugin_repo"]')
      ->element_exists('option[value="https://github.com/octocat/Hello-World"]')
      ->element_exists('form[action="/developer/repos/refresh"]')
      ->element_exists('a[href="https://github.com/settings/applications"]');
};

subtest 'second visit reuses the cache, without calling GitHub again' => sub {
    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::fetch_all_repos = sub { die 'should not be called once cached' };

    $t->get_ok('/new-plugin')
      ->status_is(200)
      ->element_exists('option[value="https://github.com/octocat/Hello-World"]');
};

subtest 'shows a message when the developer has no repos cached' => sub {
    reset_db();
    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::fetch_all_repos = sub { return []; };

    $t->get_ok('/new-plugin')
      ->status_is(200)
      ->element_exists_not('select[name="plugin_repo"]')
      ->text_like( 'p.text-danger' => qr/No public GitHub repositories found/ );
};

subtest 'visiting /new-plugin syncs maintainer status for a repo already listed here' => sub {
    reset_db();
    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    my $owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find(
        { oauth_provider_key => 'github', provider_user_id => 'mock' }
    );
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { repo_url => 'https://github.com/octocat/Hello-World', developer_id => $owner->id }
    );

    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::fetch_all_repos = sub {
        return [ {
            full_name   => 'octocat/Hello-World',
            html_url    => 'https://github.com/octocat/Hello-World',
            permissions => { push => 1 },
        } ];
    };

    $t->get_ok('/new-plugin')->status_is(200);

    my $mockdev = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find(
        { oauth_provider_key => 'github', provider_user_id => 'mock' }
    );
    ok(
        KohaPluginStore::Model::PluginMaintainer->new( pg => test_pg() )->find( { plugin_id => $plugin->id, developer_id => $mockdev->id } ),
        'visiting the page synced maintainer status for the matching repo'
    );

    $t->get_ok('/logout');
};

done_testing();
