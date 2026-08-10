use Mojo::Base -strict;

use Test::More;
use Test::Mojo;

use lib 't/lib';
use TestDB qw(reset_db test_pg);

use KohaPluginStore::Model::Developer;

reset_db();

my $t = Test::Mojo->new('KohaPluginStore');
$t->app->pg( test_pg() );

subtest 'anonymous request is rejected' => sub {
    $t->post_ok('/developer/repos/refresh')->status_is(404); # existing #TODO in the app: this should be 401
};

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

subtest 'fetches, caches, and redirects back to the picker' => sub {
    $t->post_ok('/developer/repos/refresh')->status_is(302)->header_is( Location => '/new-plugin' );

    my $developer = KohaPluginStore::Model::Developer->new( pg => test_pg() )
      ->find( { oauth_provider_key => 'github', provider_user_id => 'mock' } );
    is_deeply(
        $developer->cached_repos,
        [ { full_name => 'octocat/Hello-World', html_url => 'https://github.com/octocat/Hello-World' } ],
        'cached_repos persisted'
    );
    ok( $developer->cached_repos_fetched_at, 'cached_repos_fetched_at set' );
};

subtest 'refreshing again replaces the cached list wholesale' => sub {
    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::fetch_all_repos = sub { return []; };

    $t->post_ok('/developer/repos/refresh')->status_is(302);

    my $developer = KohaPluginStore::Model::Developer->new( pg => test_pg() )
      ->find( { oauth_provider_key => 'github', provider_user_id => 'mock' } );
    is_deeply( $developer->cached_repos, [], 'stale entries are gone, not merged with' );
};

done_testing();
