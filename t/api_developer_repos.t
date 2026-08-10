use Mojo::Base -strict;

use Test::More;
use Test::Mojo;

use lib 't/lib';
use TestDB qw(reset_db test_app test_pg);

use KohaPluginStore::Model::Developer;

reset_db();

my $t = test_app();

subtest 'anonymous request is rejected' => sub {
    $t->get_ok('/api/v1/developer/repos')->status_is(401);
};

{
    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::fetch_all_repos = sub { return []; };
}

subtest 'logged-in developer with nothing cached yet gets an empty list' => sub {
    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    $t->get_ok('/api/v1/developer/repos')->status_is(200)->json_is( '/repos' => [] );
};

subtest 'returns whatever is cached, without calling GitHub again' => sub {
    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::fetch_all_repos = sub { die 'should not be called' };

    my $developer = KohaPluginStore::Model::Developer->new( pg => test_pg() )
      ->find( { oauth_provider_key => 'github', provider_user_id => 'mock' } );
    $developer->refresh_cached_repos(
        [ { full_name => 'octocat/Hello-World', html_url => 'https://github.com/octocat/Hello-World' } ] );

    $t->get_ok('/api/v1/developer/repos')
      ->status_is(200)
      ->json_is( '/repos/0/full_name' => 'octocat/Hello-World' )
      ->json_is( '/repos/0/html_url'  => 'https://github.com/octocat/Hello-World' );
};

done_testing();
