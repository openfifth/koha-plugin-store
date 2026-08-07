use Mojo::Base -strict;

use Test::More;
use Test::Mojo;

use lib 't/lib';
use TestDB qw(reset_db test_pg);

reset_db();

my $t = Test::Mojo->new('KohaPluginStore');
$t->app->pg( test_pg() );

$t->app->config->{oauth_mock} = 1;
$t->get_ok('/auth/github');
$t->app->config->{oauth_mock} = 0;

{
    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::fetch_public_repos = sub {
        return [ { full_name => 'octocat/Hello-World', html_url => 'https://github.com/octocat/Hello-World' } ];
    };
}

subtest 'shows a repo dropdown populated from the developer\'s GitHub repos' => sub {
    $t->get_ok('/new-plugin')
      ->status_is(200)
      ->element_exists('select[name="plugin_repo"]')
      ->element_exists('option[value="https://github.com/octocat/Hello-World"]');
};

{
    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::fetch_public_repos = sub { return []; };
}

subtest 'shows a message when the developer has no public repos' => sub {
    $t->get_ok('/new-plugin')
      ->status_is(200)
      ->element_exists_not('select[name="plugin_repo"]')
      ->text_like( 'p.text-danger' => qr/No public GitHub repositories found/ );
};

done_testing();
