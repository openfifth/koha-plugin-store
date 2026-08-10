use Mojo::Base -strict;

use Test::More;
use Test::Mojo;

use lib 't/lib';
use TestDB qw(reset_db test_app test_pg);

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

done_testing();
